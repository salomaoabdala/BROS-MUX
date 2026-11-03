// BROS-MUX — system monitor shown while a job runs: CPU, GPU, memory, disk throughput, free space, elapsed/remaining.
// Sampled once a second from the kernel (host statistics, IOKit), nothing is polled from the child processes.

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

    var running: Bool { timer != nil }
    var elapsed: TimeInterval { started.map { Date().timeIntervalSince($0) } ?? 0 }

    func start(watching folder: URL?) {
        stop()
        watch = folder; started = Date(); written = 0; writtenRate = 0; lastWritten = nil; lastCPU = nil; lastDisk = nil
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.sample() }
    }
    func stop() { timer?.invalidate(); timer = nil }

    private func sample() {
        cpu = Self.cpuLoad(&lastCPU)
        gpu = Self.gpuUtilization()
        memUsed = Self.memoryUsed()
        let (r, w) = Self.diskRates(&lastDisk)
        readRate = r; writeRate = w
        if let f = watch {
            free = Tools.freeSpace(at: f)
            let b = Self.folderBytes(f)
            if let l = lastWritten, Date().timeIntervalSince(l.at) > 0 { writtenRate = max(0, (b - l.bytes) / Date().timeIntervalSince(l.at)) }
            lastWritten = (b, Date()); written = b
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
        .onAppear { mon.start(watching: folder) }
        .onDisappear { mon.stop() }
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
