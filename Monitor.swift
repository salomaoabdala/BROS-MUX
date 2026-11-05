// BROS-MUX — system monitor shown while a job runs: CPU, GPU, memory, disk throughput, free space, elapsed/remaining.
// Sampled once a second from the kernel (host statistics, IOKit), nothing is polled from the child processes.
// DeliveryMonitor (below) follows a detached Delivery render through the files it writes: fps now / typical / average,
// the ETA, the stage timeline and a thumbnail of the frame being encoded.

import SwiftUI
import IOKit
import Darwin

@Observable
final class SystemMonitor {
    static let shared = SystemMonitor()
    var cpu: Double = 0            // 0–1, all cores
    var gpu: Double? = nil         // 0–1 when the GPU reports it
    var memUsed: Double = 0        // bytes
    var memTotal: Double = Double(ProcessInfo.processInfo.physicalMemory)
    var readRate: Double = 0       // bytes/s, every drive
    var writeRate: Double = 0
    var free: Double? = nil        // bytes free on the watched folder's volume
    var written: Double = 0        // bytes in the watched folder (the temp output growing)
    var writtenRate: Double = 0
    var started: Date? = nil
    var watch: URL? = nil
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastCPU: (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?
    @ObservationIgnored private var lastDisk: (read: UInt64, write: UInt64, at: Date)?
    @ObservationIgnored private var lastWritten: (bytes: Double, at: Date)?

    /// A Delivery render owns the monitor (started and stopped per job, not by a view appearing)
    var heldByJob = false
    @ObservationIgnored private var measuring = false

    var running: Bool { timer != nil }
    var elapsed: TimeInterval { started.map { Date().timeIntervalSince($0) } ?? 0 }

    /// `since`: when the job itself started (the elapsed time is the job's, not the view's)
    func start(watching folder: URL?, since: Date? = nil) {
        stop()
        watch = folder; started = since ?? Date(); written = 0; writtenRate = 0; lastWritten = nil; lastCPU = nil; lastDisk = nil
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.sample() }
    }
    func stop() { timer?.invalidate(); timer = nil }

    /// Points the "written" reading at another folder without restarting the clock
    func watch(_ folder: URL?) {
        guard folder != watch else { return }
        watch = folder; written = 0; writtenRate = 0; lastWritten = nil
    }

    private func sample() {
        cpu = Self.cpuLoad(&lastCPU)
        gpu = Self.gpuUtilization()
        memUsed = Self.memoryUsed()
        let (r, w) = Self.diskRates(&lastDisk)
        readRate = r; writeRate = w
        // the watched folder may sit on a slow drive: measured off the main thread, one reading at a time
        guard let f = watch, !measuring else { return }
        measuring = true
        DispatchQueue.global(qos: .utility).async {
            let freeNow = Tools.freeSpace(at: f)
            let b = Self.folderBytes(f)
            DispatchQueue.main.async {
                self.measuring = false
                guard self.watch == f else { return }
                self.free = freeNow
                if let l = self.lastWritten, Date().timeIntervalSince(l.at) > 0 { self.writtenRate = max(0, (b - l.bytes) / Date().timeIntervalSince(l.at)) }
                self.lastWritten = (b, Date()); self.written = b
            }
        }
    }

    // MARK: kernel readings

    static func cpuLoad(_ last: inout (user: UInt64, system: UInt64, idle: UInt64, nice: UInt64)?) -> Double {
        var count = mach_msg_type_number_t(0), n = natural_t(0)
        var info: processor_info_array_t? = nil
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &n, &info, &count) == KERN_SUCCESS, let info else { return 0 }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(count) * vm_size_t(MemoryLayout<integer_t>.size)) }
        var u: UInt64 = 0, s: UInt64 = 0, i: UInt64 = 0, ni: UInt64 = 0
        for c in 0..<Int(n) {
            let b = c * Int(CPU_STATE_MAX)
            u += UInt64(info[b + Int(CPU_STATE_USER)]); s += UInt64(info[b + Int(CPU_STATE_SYSTEM)])
            i += UInt64(info[b + Int(CPU_STATE_IDLE)]); ni += UInt64(info[b + Int(CPU_STATE_NICE)])
        }
        defer { last = (u, s, i, ni) }
        guard let l = last else { return 0 }
        let busy = Double((u - l.user) + (s - l.system) + (ni - l.nice)), total = busy + Double(i - l.idle)
        return total > 0 ? busy / total : 0
    }

    static func memoryUsed() -> Double {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let r = withUnsafeMutablePointer(to: &stats) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count) } }
        guard r == KERN_SUCCESS else { return 0 }
        let page = Double(vm_kernel_page_size)
        return (Double(stats.active_count) + Double(stats.wire_count) + Double(stats.compressor_page_count)) * page
    }

    /// Apple GPUs publish "Device Utilization %" in the IOAccelerator performance statistics
    static func gpuUtilization() -> Double? {
        var it = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &it) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(it) }
        var best: Double? = nil
        var svc = IOIteratorNext(it)
        while svc != 0 {
            if let props = IORegistryEntryCreateCFProperty(svc, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] {
                for key in ["Device Utilization %", "GPU Activity(%)", "Renderer Utilization %"] {
                    if let v = props[key] as? NSNumber { best = max(best ?? 0, v.doubleValue / 100); break }
                }
            }
            IOObjectRelease(svc)
            svc = IOIteratorNext(it)
        }
        return best
    }

    /// Bytes read/written by every block storage driver since boot → rates
    static func diskRates(_ last: inout (read: UInt64, write: UInt64, at: Date)?) -> (Double, Double) {
        var it = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &it) == KERN_SUCCESS else { return (0, 0) }
        defer { IOObjectRelease(it) }
        var read: UInt64 = 0, write: UInt64 = 0
        var svc = IOIteratorNext(it)
        while svc != 0 {
            if let st = IORegistryEntryCreateCFProperty(svc, "Statistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? [String: Any] {
                read += (st["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                write += (st["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            }
            IOObjectRelease(svc)
            svc = IOIteratorNext(it)
        }
        let now = Date()
        defer { last = (read, write, now) }
        guard let l = last, now.timeIntervalSince(l.at) > 0 else { return (0, 0) }
        let dt = now.timeIntervalSince(l.at)
        return (Double(read &- l.read) / dt, Double(write &- l.write) / dt)
    }

    /// Size of the files directly inside a folder and its temp subfolders (the output being written)
    static func folderBytes(_ dir: URL) -> Double {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey], options: [.skipsPackageDescendants]) else { return 0 }
        var total = 0.0, visited = 0
        for case let u as URL in e {
            visited += 1; if visited > 5000 { break }
            if let v = try? u.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true { total += Double(v.fileSize ?? 0) }
        }
        return total
    }
}

/// The strip shown under the progress bar while a job runs
struct RunMonitorView: View {
    let progress: Double
    let stage: String
    let folder: URL?
    @Bindable var mon = SystemMonitor.shared

    var body: some View {
        VStack(alignment: .leading, spacing: DS.rowGap) {
            ProgressView(value: progress)
            HStack {
                Text(stage).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(2)
                Spacer()
                Text(timeText).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            HStack(spacing: DS.gap) {
                gauge("CPU", value: mon.cpu, text: String(format: "%.0f%%", mon.cpu * 100), symbol: "cpu")
                gauge("GPU", value: mon.gpu ?? 0, text: mon.gpu.map { String(format: "%.0f%%", $0 * 100) } ?? "—", symbol: "rectangle.3.group")
                gauge("Memory", value: mon.memTotal > 0 ? mon.memUsed / mon.memTotal : 0, text: "\(Fmt.bytes(mon.memUsed)) of \(Fmt.bytes(mon.memTotal))", symbol: "memorychip")
                VStack(alignment: .leading, spacing: 2) {
                    Label("Disk", systemImage: "internaldrive").font(.caption.weight(.medium))
                    Text("↓ \(Fmt.bytes(mon.readRate))/s · ↑ \(Fmt.bytes(mon.writeRate))/s").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    if mon.written > 0 { Text("written \(Fmt.bytes(mon.written)) · \(Fmt.bytes(mon.writtenRate))/s").font(.caption2).foregroundStyle(.secondary).monospacedDigit() }
                    if let f = mon.free { Text("free \(Fmt.bytes(f))").font(.caption2).foregroundStyle(.secondary).monospacedDigit() }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { if !mon.heldByJob { mon.start(watching: folder) } }
        .onDisappear { if !mon.heldByJob { mon.stop() } }
    }

    var timeText: String {
        let e = mon.elapsed
        guard progress > 0.02, e > 5 else { return elapsedText(e) }
        let remaining = e / progress - e
        return "\(elapsedText(e)) · about \(elapsedText(remaining)) left"
    }
    func elapsedText(_ s: TimeInterval) -> String { s >= 3600 ? String(format: "%d h %02d min", Int(s) / 3600, Int(s) % 3600 / 60) : s >= 60 ? String(format: "%d min %02d s", Int(s) / 60, Int(s) % 60) : String(format: "%.0f s", s) }

    func gauge(_ title: String, value: Double, text: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: symbol).font(.caption.weight(.medium))
            ProgressView(value: min(1, max(0, value))).tint(value > 0.9 ? .orange : .accentColor)
            Text(text).font(.caption2).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Delivery: following a detached render

/// Follows the running Delivery through the files its process writes (Jobs/<id>/): the snapshot 3 times a second,
/// the stages and their times, fps now (90-s window), typical (median over 20 min) and average, the ETA (a range during
/// pass 1 of a 2-pass: pass 2 takes 2–3.5× pass 1), and a thumbnail of the frame being encoded, from the source,
/// every 12 s on a utility queue. It owns the SystemMonitor while the job runs.
@Observable final class DeliveryMonitor {
    static let shared = DeliveryMonitor()
    var jobID: UUID?
    var snapshot: DeliverySnapshot?
    var info: DeliveryWorkerInfo?
    var overall: Double = 0                       // never goes back
    var fpsNow: Double?
    var fpsTypical: Double?
    var fpsAverage: Double?
    var fpsHistory: [Double] = []                 // the sparkline: fps now, every 10 s
    var eta: ClosedRange<Double>?                 // seconds to the end of the whole job
    var thumbnail: CGImage?
    var thumbnailFrame: Int?
    var bytesRate: Double?                        // bytes/s written (a job that only muxes)
    var demo = false

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var samples: [(t: Date, frame: Int, stage: String)] = []
    @ObservationIgnored private var lastHistoryPoint = Date.distantPast
    @ObservationIgnored private var lastThumb = Date.distantPast
    @ObservationIgnored private var thumbBusy = false
    @ObservationIgnored private var lastInfoRead = Date.distantPast
    @ObservationIgnored private var lastBytes: (b: Int64, t: Date)?

    /// Follows this job while it runs; nil (or a finished job) stops following
    func follow(_ item: DeliveryItem?) {
        guard !demo else { return }
        guard let item, item.state == .running else { if jobID != nil { stopFollowing() }; return }
        guard jobID != item.id else { return }
        stopFollowing()
        jobID = item.id
        snapshot = item.snapshot
        overall = item.snapshot?.overall ?? 0
        info = DeliveryPaths.readJSON(DeliveryWorkerInfo.self, DeliveryPaths.info(item.id))
        lastInfoRead = Date()
        samples = Self.readHistory(item.id)
        let mon = SystemMonitor.shared
        mon.heldByJob = true
        mon.start(watching: workFolder, since: info?.started ?? item.snapshot?.started)
        timer = Timer.scheduledTimer(withTimeInterval: 0.33, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }

    func stopFollowing() {
        timer?.invalidate(); timer = nil
        jobID = nil; snapshot = nil; info = nil; overall = 0; fpsNow = nil; fpsTypical = nil; fpsAverage = nil; fpsHistory = []
        eta = nil; thumbnail = nil; thumbnailFrame = nil; bytesRate = nil; samples = []; lastBytes = nil
        lastThumb = .distantPast; lastHistoryPoint = .distantPast
        SystemMonitor.shared.heldByJob = false
        SystemMonitor.shared.stop()
    }

    /// The job's temporary folder once the render says which (never the whole destination folder)
    private var workFolder: URL? { info?.workFolder.map { URL(fileURLWithPath: $0) } }

    private func tick() {
        guard let id = jobID, let s = DeliveryPaths.readJSON(DeliverySnapshot.self, DeliveryPaths.progress(id)) else { return }
        if s.stageIndex != snapshot?.stageIndex || Date().timeIntervalSince(lastInfoRead) > 3 {
            if let i = DeliveryPaths.readJSON(DeliveryWorkerInfo.self, DeliveryPaths.info(id)) { info = i }
            lastInfoRead = Date()
            SystemMonitor.shared.watch(workFolder)
        }
        let previous = snapshot
        snapshot = s
        overall = max(overall, s.overall)
        if let f = s.frame, let st = s.stage {
            if samples.last.map({ $0.frame != f || $0.stage != st.rawValue }) ?? true { samples.append((s.updated, f, st.rawValue)) }
            if samples.count > 2000 { samples.removeFirst(samples.count - 2000) }
        }
        if let b = s.bytesWritten {
            if let l = lastBytes, s.updated.timeIntervalSince(l.t) >= 2 { bytesRate = max(0, Double(b - l.b) / s.updated.timeIntervalSince(l.t)); lastBytes = (b, s.updated) }
            else if lastBytes == nil { lastBytes = (b, s.updated) }
        }
        if previous?.updated != s.updated { compute() }
        thumbnailIfDue()
    }

    // MARK: numbers

    private func compute() {
        guard let s = snapshot else { return }
        let st = s.stage?.rawValue ?? ""
        let cur = samples.filter { $0.stage == st }
        fpsNow = nil; fpsTypical = nil
        if let last = cur.last {
            // now: the frames of the last 90 s (at least 10 s of them)
            let window = cur.filter { last.t.timeIntervalSince($0.t) <= 90 }
            if let first = window.first, last.t.timeIntervalSince(first.t) >= 10, last.frame > first.frame {
                fpsNow = Double(last.frame - first.frame) / last.t.timeIntervalSince(first.t)
            }
            // typical: the median of the pace measured between points at least 55 s apart, over the last 20 minutes
            var rates: [Double] = []
            var prev: (t: Date, frame: Int, stage: String)?
            for p in cur where last.t.timeIntervalSince(p.t) <= 1200 {
                guard let q = prev else { prev = p; continue }
                let dt = p.t.timeIntervalSince(q.t)
                if dt >= 55 { rates.append(Double(p.frame - q.frame) / dt); prev = p }
            }
            if !rates.isEmpty { fpsTypical = Fmt.median(rates) }
        }
        fpsAverage = s.fpsAverage
        if let n = fpsNow, Date().timeIntervalSince(lastHistoryPoint) >= 10 {
            fpsHistory.append(n); lastHistoryPoint = Date()
            if fpsHistory.count > 180 { fpsHistory.removeFirst(fpsHistory.count - 180) }
        }
        eta = Self.eta(s, info: info, fps: fpsTypical ?? fpsNow ?? s.fpsAverage)
    }

    /// Seconds to the end of the job: the frames left at the measured pace, then the stages after it at their estimate.
    /// During pass 1 of a 2-pass the end is a range: pass 2 takes 2 to 3.5 times as long as pass 1.
    static func eta(_ s: DeliverySnapshot, info: DeliveryWorkerInfo?, fps: Double?) -> ClosedRange<Double>? {
        guard let info, s.stageIndex < info.stages.count else { return nil }
        let rest = Array(info.stages.dropFirst(s.stageIndex + 1))
        if let f = s.frame, let n = s.totalFrames, n > 0, let fps, fps > 0 {
            let left = Double(max(0, n - f)) / fps
            if s.stage == .pass1, let p2 = rest.firstIndex(where: { $0.stage == .pass2 }) {
                let inStage = info.stages[s.stageIndex].started.map { Date().timeIntervalSince($0) } ?? 0
                let pass1 = inStage + left
                let other = rest.enumerated().filter { $0.offset != p2 }.reduce(0.0) { $0 + $1.element.weight }
                return (left + 2.0 * pass1 + other)...(left + 3.5 * pass1 + other)
            }
            let other = rest.reduce(0.0) { $0 + $1.weight }
            return (left + other)...(left + other)
        }
        guard s.overall > 0.02 else { return nil }
        let elapsed = s.updated.timeIntervalSince(s.started)
        let left = elapsed * (1 - s.overall) / s.overall
        return left...left
    }

    // MARK: thumbnail

    private func thumbnailIfDue() {
        guard !thumbBusy, Date().timeIntervalSince(lastThumb) >= 12, let s = snapshot, let f = s.frame, let info, info.encodes,
              let (file, local) = Self.sourceFrame(f, info: info) else { return }
        thumbBusy = true; lastThumb = Date()
        let idx = info.pictureIndex, fps = info.fps
        DispatchQueue.global(qos: .utility).async {
            let img = PictureSync.thumbnails(video: file, index: idx, fps: fps, firstFrame: local, count: 1, width: 640, height: 360).first
            DispatchQueue.main.async {
                self.thumbBusy = false
                guard self.jobID == info.id else { return }
                if let img { self.thumbnail = img; self.thumbnailFrame = f }
            }
        }
    }

    /// The source file and the frame inside it (an IMF picture is several track files)
    static func sourceFrame(_ f: Int, info: DeliveryWorkerInfo) -> (URL, Int)? {
        var left = f
        for s in info.segments {
            if left < s.count { return (URL(fileURLWithPath: s.file), s.start + left) }
            left -= s.count
        }
        return info.picture.map { (URL(fileURLWithPath: $0), f) }
    }

    static func readHistory(_ id: UUID) -> [(t: Date, frame: Int, stage: String)] {
        DeliveryQueue.readLines(DeliveryPaths.history(id)).compactMap { l in
            let p = l.split(separator: ",")
            guard p.count >= 3, let t = Double(p[0]), let f = Int(p[1]) else { return nil }
            return (Date(timeIntervalSince1970: t), f, String(p[2]))
        }
    }

    // MARK: demo (snapshots)

    /// A 2DIE4-like render in pass 2 of 2, about 42 % (Dolby Vision, 2-pass 110/160 Mbps, speed slow)
    func loadDemo(item: DeliveryItem) {
        timer?.invalidate(); timer = nil
        demo = true
        jobID = item.id
        let now = Date()
        let readMeta = 31.0, pass1 = 2 * 3600 + 5 * 60 + 13.0
        let p2Elapsed = 6206.0
        let t0 = now.addingTimeInterval(-(readMeta + pass1 + p2Elapsed))
        func st(_ s: JobProgress.Stage, _ title: String, _ w: Double, _ a: Double?, _ b: Double?) -> DeliveryWorkerInfo.Stage {
            .init(stage: s, title: title, weight: w, started: a.map { t0.addingTimeInterval($0) }, ended: b.map { t0.addingTimeInterval($0) })
        }
        let stages = [
            st(.readMetadata, "Reading the metadata", 30, 0, readMeta),
            st(.pass1, "Pass 1 of 2", 11_270, readMeta, readMeta + pass1),
            st(.pass2, "Pass 2 of 2", 28_800, readMeta + pass1, nil),
            st(.injectDV, "Injecting Dolby Vision", 420, nil, nil),
            st(.mux, "Muxing", 410, nil, nil),
            st(.verifyPicture, "Verifying the picture", 40, nil, nil),
            st(.verifyBits, "Verifying bit for bit", 120, nil, nil),
            st(.sync, "Checking the sync", 24, nil, nil),
            st(.picture, "Checking the sound against the picture", 49, nil, nil),
            st(.academy, "Checking the Academy specs", 8, nil, nil),
            st(.renderQC, "Render QC", 874, nil, nil),
            st(.finalize, "Writing the report", 2, nil, nil),
        ]
        info = DeliveryWorkerInfo(id: item.id, pid: 0, label: nil, name: item.job.name, output: item.job.output, workFolder: nil, started: t0,
                                  picture: nil, pictureIndex: 0, fps: 24, frames: 129_600, startTimecode: "01:00:00:00", segments: [], encodes: true,
                                  bytesTotal: 118_000_000_000, stages: stages)
        let frame = 30_412
        var s = item.snapshot ?? DeliverySnapshot(stage: .pass2, title: "", stageFraction: 0, overall: 0, frame: nil, totalFrames: nil, fpsAverage: nil, bitrateKbps: nil,
                                                  bytesWritten: nil, bytesTotal: nil, stageIndex: 2, stageCount: stages.count, stagesDone: [], started: t0, updated: now)
        s.frame = frame; s.totalFrames = 129_600; s.stageIndex = 2; s.stageCount = stages.count; s.stage = .pass2
        s.stageFraction = Double(frame) / 129_600; s.fpsAverage = 4.9; s.bitrateKbps = 104_200; s.started = t0; s.updated = now
        let w = stages.map(\.weight), sum = w.reduce(0, +)
        s.overall = (w[0] + w[1] + w[2] * s.stageFraction) / sum
        s.stagesDone = [.readMetadata, .pass1]
        snapshot = s
        overall = s.overall
        fpsNow = 4.6; fpsTypical = 4.5; fpsAverage = 4.9
        var history: [Double] = []
        for i in 0..<90 {
            let x = Double(i)
            var v: Double = 4.5 + 0.35 * sin(x / 6)
            if i % 7 == 0 { v -= 0.5 }
            if i < 6 { v += 1.2 - x * 0.2 }
            history.append(v)
        }
        fpsHistory = history
        eta = Self.eta(s, info: info, fps: 4.5)
        thumbnail = nil; thumbnailFrame = frame
        let mon = SystemMonitor.shared
        mon.heldByJob = true
        mon.cpu = 0.91; mon.gpu = 0.06; mon.memUsed = 41_000_000_000; mon.memTotal = 64_000_000_000
        mon.readRate = 182_000_000; mon.writeRate = 13_000_000; mon.written = 0; mon.free = 3_100_000_000_000
        mon.started = t0
    }
}
