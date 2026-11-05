// BROS-MUX Beta 2.0.0 — 04 · DELIVERY: before you start, the file that will be written, the render queue, the render
// page (it follows the detached render process) and the result. The render runs outside the window: the tabs stay
// editable while it runs, because the job that runs is frozen in its file.

import SwiftUI
import AppKit

struct DeliveryTab: View {
    @Environment(Project.self) private var project
    let targeted: Bool

    /// "ready" / "1 to fix" / "rendering 42 %" / "2 in queue"
    static func sidebarLine(project: Project) -> String {
        let q = DeliveryQueue.shared
        if let c = q.current { return "rendering \(Int(((c.snapshot?.overall ?? 0) * 100).rounded(.down))) %" }
        if project.tracks.isEmpty { return q.queued.isEmpty ? "nothing to deliver yet" : "\(q.queued.count) in queue" }
        let fix = q.preflight(project).filter { $0.level == .fail }.count
        if fix > 0 { return "\(fix) to fix" }
        if !q.queued.isEmpty { return "\(q.queued.count) in queue" }
        return "ready"
    }

    var body: some View {
        @Bindable var q = DeliveryQueue.shared
        let checks = q.preflight(project)
        VStack(spacing: 0) {
            strip(checks)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let busy = q.busy {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text(busy).font(CryoFont.body(12)).foregroundStyle(Cryo.ink2) }
                    }
                    if let r = q.refusal { DeliveryRefusalCard(refusal: r) }
                    ForEach(project.notices(for: .delivery)) { n in DeliveryLineRow(level: n.level, text: n.text) }
                    if let run = q.current { DeliveryRunningPage(item: run) }
                    if let done = q.lastResult, q.current == nil {
                        ResultBanner(item: done, onClose: { q.dismissedResult = done.id })
                    }
                    if project.tracks.isEmpty {
                        CryoSlot {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Nothing to deliver yet").font(CryoFont.title(16)).foregroundStyle(Cryo.ink)
                                Text("Start on the Video tab with the picture, line the sound up on the Audio tab, and the file to be written appears here. A saved job (.bmjob) dropped on the window opens here too.")
                                    .font(CryoFont.body(12)).foregroundStyle(Cryo.ink2).fixedSize(horizontal: false, vertical: true)
                                Button("01 · VIDEO →") { project.mode = .video }.buttonStyle(CryoGoButtonStyle(.ghost)).padding(.top, 4)
                            }
                        }
                    } else {
                        DeliveryBeforeYouStart(items: checks)
                        DeliveryFileSection()
                    }
                    if !q.items.isEmpty { DeliveryQueueView() }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .sheet(isPresented: $q.saveSheetShown) { SaveJobSheet(project: project) }
        .onAppear {
            q.restoreAtLaunch()
            // snapshots: the render page without a render (BrosMux's --demo-running does the same once it's wired)
            if DeliveryQueue.isSnapshot, CommandLine.arguments.contains("--demo-running"), q.current == nil { q.loadDemoRunningJob() }
        }
    }

    func strip(_ checks: [DeliveryPreflightItem]) -> some View {
        let fix = checks.filter { $0.level == .fail }.count
        let pending = !project.pendingAudioDecisions.isEmpty || project.video.decisionPending
        let touch: FileTouch = pending ? .pending : DeliveryEngine.transcodesAnything(project) ? .transcode : .mux
        return CryoStrip(touch: touch, title: "DELIVERY", text: stripText(pending: pending)) {
            if !project.tracks.isEmpty {
                if fix > 0 { CryoChip("\(fix) TO FIX", style: .fail) } else { CryoChip("READY", style: .pass) }
            }
        }
    }

    func stripText(pending: Bool) -> String {
        if project.tracks.isEmpty { return "writes the final file — nothing to deliver yet" }
        if pending { return "a decision is open — see BEFORE YOU START; nothing is decided for you" }
        let c = project.container.rawValue.uppercased()
        var parts: [String] = []
        switch project.video.choice(project) {
        case .copy: break
        case .hevcHDR:
            parts.append("TRANSCODE of the picture (\(project.videoTrack?.codecName ?? "picture") → HEVC 10-bit · \(project.hdr.formatsText))")
        case .transcode(let s):
            parts.append("TRANSCODE of the picture (\(project.videoTrack?.codecName ?? "picture") → \(TranscodePreset(rawValue: s.preset)?.label.components(separatedBy: " — ").first ?? s.preset), step 1)")
        }
        let a = project.outputAudio.filter { $0.delivery != .copy }.count
        if a > 0 { parts.append("TRANSCODE of \(a) audio track\(a == 1 ? "" : "s")") }
        if parts.isEmpty { return "every track is copied bit for bit into one new \(c) file — nothing is re-encoded" }
        return "MUX + " + parts.joined(separator: " + ") + " — into one new \(c) file; the rest is copied bit for bit"
    }
}

// MARK: - BEFORE YOU START

struct DeliveryBeforeYouStart: View {
    @Environment(Project.self) private var project
    let items: [DeliveryPreflightItem]

    var body: some View {
        let fix = items.filter { $0.level == .fail }.count, confirm = items.filter { $0.level == .warn }.count
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                CryoSectionHeader("Before you start")
                Spacer()
                Text(fix > 0 ? "\(fix) to fix" + (confirm > 0 ? " · \(confirm) to confirm" : "") : confirm > 0 ? "\(confirm) to confirm" : "ready")
                    .font(CryoFont.label()).tracking(0.8).foregroundStyle(fix > 0 ? Cryo.fail : confirm > 0 ? Cryo.attention : Cryo.pass)
            }
            CryoSlot {
                VStack(alignment: .leading, spacing: 8) {
                    if fix == 0 && confirm == 0 {
                        DeliveryLineRow(level: .ok, text: "Nothing to fix: every decision is taken and the file can be written.")
                    }
                    ForEach(items.sorted { rank($0.level) < rank($1.level) }) { i in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            DeliveryLineRow(level: i.level, text: i.text)
                            Spacer(minLength: 8)
                            if let tab = i.tab, tab != .delivery, i.level == .fail || i.level == .warn {
                                Button("\(tab.label) →") { project.mode = tab }.buttonStyle(CryoButtonStyle())
                                    .help("Fix it on the \(tab.label) tab")
                            }
                        }
                    }
                }
            }
        }
    }

    func rank(_ l: CheckLevel) -> Int { switch l { case .fail: return 0; case .warn: return 1; case .info: return 2; case .ok: return 3 } }
}

// MARK: - THE FILE THAT WILL BE WRITTEN

struct DeliveryFileSection: View {
    @Environment(Project.self) private var project

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CryoSectionHeader("The file that will be written")
            CryoSlot {
                VStack(alignment: .leading, spacing: 14) {
                    OutputSection()
                    Rectangle().fill(Cryo.s3).frame(height: 1)
                    SummarySections()
                    Rectangle().fill(Cryo.s3).frame(height: 1)
                    AcademySection()
                    Rectangle().fill(Cryo.s3).frame(height: 1)
                    estimates
                }
            }
        }
    }

    var estimates: some View {
        let bytes = DeliveryEngine.estimatedFinalBytes(project)
        let seconds = DeliveryEngine.estimatedSeconds(project)
        let free = project.outputFree
        return HStack(alignment: .top, spacing: 16) {
            DeliveryReadout(label: "Size", value: bytes > 0 ? "~" + Fmt.bytes(bytes) : "—", detail: "estimated from the sources")
            DeliveryReadout(label: "Time", value: seconds.map { "~" + Fmt.hm($0) } ?? "—",
                            detail: project.video.choice(project) == .copy ? "copying and checking, on this Mac" : "rough: the encode sets it, on this Mac")
            DeliveryReadout(label: "Free on that drive", value: free.map { Fmt.bytes($0) } ?? "—",
                            detail: "needs ~\(Fmt.bytes(DeliveryEngine.estimatedTempBytes(project) + 2 * bytes + 1_000_000_000)) while writing")
        }
    }
}

// MARK: - The render page

/// Resolve-like: the big %, the stage now and what it does, the stage timeline, frames, the fps, the ETA, the frame
/// being encoded (from the source, neutral surround), what it is finding, and the machine
struct DeliveryRunningPage: View {
    let item: DeliveryItem
    @State private var confirmCancel = false

    var body: some View {
        let m = DeliveryMonitor.shared
        let s = m.snapshot ?? item.snapshot
        let stage = s?.stage
        let encodes = m.info?.encodes ?? (stage.map { [.pass1, .pass2, .encode, .transcodeVideo].contains($0) } ?? false)
        VStack(alignment: .leading, spacing: 8) {
            CryoSectionHeader("Rendering")
            CryoSlot(highlighted: true) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(item.job.name).font(CryoFont.title(16)).foregroundStyle(Cryo.ink).lineLimit(1)
                        Text("→ " + URL(fileURLWithPath: m.info?.output ?? item.job.output).lastPathComponent).font(CryoFont.mono(11)).foregroundStyle(Cryo.ink2).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        Button("CANCEL") { confirmCancel = true }.buttonStyle(CryoGoButtonStyle(.ghost))
                            .help("Stops the render; nothing is written to the destination")
                    }
                    HStack(alignment: .top, spacing: 20) {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text("\(Int((max(m.overall, s?.overall ?? 0) * 100).rounded(.down)))").font(CryoFont.mono(54)).foregroundStyle(Cryo.ink)
                                Text("%").font(CryoFont.mono(26)).foregroundStyle(Cryo.ink2)
                                Text("of the whole job").font(CryoFont.body(11)).foregroundStyle(Cryo.ink3).padding(.leading, 6)
                            }
                            Text(s?.title ?? "Starting…").font(CryoFont.body(13)).foregroundStyle(Cryo.ink).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                            Text(stage.map(Self.explain) ?? "The render process is starting.").font(CryoFont.body(12)).foregroundStyle(Cryo.ink2).fixedSize(horizontal: false, vertical: true)
                            ProgressView(value: max(m.overall, s?.overall ?? 0)).tint(Cryo.ice).padding(.top, 4)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        if encodes { DeliveryThumbnail(image: m.thumbnail, frame: m.thumbnailFrame ?? s?.frame, info: m.info) }
                    }
                    if let info = m.info { DeliveryTimeline(stages: info.stages, current: s?.stageIndex ?? 0, now: s?.updated ?? Date()) }
                    numbers(m, s, encodes: encodes)
                    if !item.findings.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            CryoFieldLabel("What it is finding")
                            ForEach(Array(item.findings.suffix(8).enumerated()), id: \.offset) { _, l in DeliveryLineRow(level: deliveryLevel(of: l), text: l) }
                        }
                    }
                    tubes
                }
            }
        }
        .confirmationDialog("Cancel the render of \(item.job.name)?", isPresented: $confirmCancel) {
            Button("Cancel the Render", role: .destructive) { DeliveryQueue.shared.cancel(item.id) }
            Button("Keep Rendering", role: .cancel) {}
        } message: { Text("Nothing is written to the destination; what was done so far is thrown away.") }
    }

    @ViewBuilder func numbers(_ m: DeliveryMonitor, _ s: DeliverySnapshot?, encodes: Bool) -> some View {
        let fps = m.info?.fps ?? 24
        HStack(alignment: .top, spacing: 16) {
            if let f = s?.frame, let n = s?.totalFrames {
                DeliveryReadout(label: "Frames", value: "\(Fmt.int(f)) / \(Fmt.int(n))", detail: "frame \(Fmt.int(f)) · " + RenderQC.timecode(frame: f, fps: fps, start: m.info?.startTimecode))
                VStack(alignment: .leading, spacing: 3) {
                    CryoFieldLabel("fps")
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(m.fpsNow.map { String(format: "%.1f", $0) } ?? "—").font(CryoFont.mono(14)).foregroundStyle(Cryo.ink)
                        Text("now").font(CryoFont.body(11)).foregroundStyle(Cryo.ink3)
                    }
                    Text("typical \(m.fpsTypical.map { String(format: "%.1f", $0) } ?? "—") · average \((m.fpsAverage ?? s?.fpsAverage).map { String(format: "%.1f", $0) } ?? "—")")
                        .font(CryoFont.body(11)).foregroundStyle(Cryo.ink2)
                    DeliverySparkline(values: m.fpsHistory).frame(height: 22)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                let w = Double(s?.bytesWritten ?? 0), t = Double(s?.bytesTotal ?? m.info?.bytesTotal ?? 0)
                DeliveryReadout(label: "Written", value: "\(Fmt.bytes(w)) / \(Fmt.bytes(t))", detail: t > 0 ? String(format: "%.0f %% of the file", min(1, w / t) * 100) : nil)
                DeliveryReadout(label: "Speed", value: m.bytesRate.map { Fmt.bytes($0) + "/s" } ?? "—", detail: "written to the destination drive")
            }
            DeliveryReadout(label: "Time left", value: etaText(m.eta), detail: finishText(m.eta, elapsed: s.map { Date().timeIntervalSince($0.started) }))
            if encodes {
                DeliveryReadout(label: "Bitrate now", value: s?.bitrateKbps.map { Fmt.bitrate($0 * 1000) } ?? "—", detail: s?.stage == .pass1 ? "pass 1 only measures" : nil)
            }
        }
    }

    var tubes: some View {
        let mon = SystemMonitor.shared
        return HStack(spacing: 14) {
            CryoTube(label: "CPU", value: String(format: "%.0f %%", mon.cpu * 100), fraction: mon.cpu)
            CryoTube(label: "GPU", value: mon.gpu.map { String(format: "%.0f %%", $0 * 100) } ?? "—", fraction: mon.gpu ?? 0)
            CryoTube(label: "RAM", value: "\(Fmt.bytes(mon.memUsed)) of \(Fmt.bytes(mon.memTotal))", fraction: mon.memTotal > 0 ? mon.memUsed / mon.memTotal : 0)
            CryoTube(label: "DISK", value: "↓ \(Fmt.bytes(mon.readRate))/s · ↑ \(Fmt.bytes(mon.writeRate))/s", fraction: min(1, (mon.readRate + mon.writeRate) / 2_000_000_000))
        }
    }

    func etaText(_ e: ClosedRange<Double>?) -> String {
        guard let e else { return "—" }
        if e.upperBound - e.lowerBound < 60 { return "about " + Fmt.hm(e.lowerBound) }
        return Fmt.hm(e.lowerBound) + " – " + Fmt.hm(e.upperBound)
    }

    func finishText(_ e: ClosedRange<Double>?, elapsed: Double?) -> String? {
        let f = DateFormatter(); f.dateFormat = "HH:mm"
        let run = elapsed.map { "running for " + Fmt.hm($0) } ?? ""
        guard let e else { return run.isEmpty ? nil : run }
        let a = f.string(from: Date().addingTimeInterval(e.lowerBound)), b = f.string(from: Date().addingTimeInterval(e.upperBound))
        let fin = a == b ? "finishes about \(a)" : "finishes \(a) – \(b) (pass 2 takes 2–3.5× pass 1)"
        return run.isEmpty ? fin : fin + " · " + run
    }

    /// What each stage does, in one sentence
    static func explain(_ s: JobProgress.Stage) -> String {
        switch s {
        case .readMetadata: return "Reads the Dolby Vision metadata and checks it covers every frame of the picture."
        case .pass1: return "Pass 1 of 2 measures the whole film, so pass 2 knows where the bits are needed. Nothing is written yet."
        case .pass2: return "Pass 2 of 2 encodes the picture, spending the bits where pass 1 said they are needed."
        case .encode: return "The picture is encoded to HEVC 10-bit."
        case .transcodeVideo: return "Step 1: the picture is transcoded on its own; it is copied bit for bit into the final file afterwards."
        case .injectHDR10Plus: return "The HDR10+ metadata is written into the encoded picture, frame by frame."
        case .injectDV: return "The Dolby Vision metadata is written into the encoded picture, frame by frame."
        case .interleave: return "The mono streams become one multichannel track, sample by sample — nothing is re-encoded."
        case .trim: return "The audio is trimmed to line up with the picture, sample exact — nothing is re-encoded."
        case .mux: return "MP4Box copies every track into the new file."
        case .mkv: return "The streams are copied into Matroska (MKV)."
        case .headers: return "The channel labels and the Dolby layout are written into the file's header."
        case .verifyPicture: return "The encoded picture is read back: frames, Dolby Vision, HDR10, HDR10+."
        case .verifyBits: return "Every track of the new file is compared with its source, bit for bit."
        case .sync: return "Each audio track is measured against the sync reference."
        case .picture: return "The sound is checked against the picture's hard cuts, all through the film."
        case .academy: return "The final file is checked against the Academy specs and the Zidoo."
        case .transcodeAudio: return "The audio is transcoded from the exact bytes the mux would have copied (trim and channel order applied)."
        case .checkResult: return "What was transcoded is checked in the final file: frames, colour, timecode, level, channels, sync."
        case .renderQC: return "Every frame of the final file is read, looking for render faults (green, black or frozen frames, clicks…)."
        case .vmaf: return "The picture is compared with the source (VMAF)."
        case .finalize: return "The report “How this file was made” is written next to the file."
        }
    }
}

/// ✓ done (with its time) · ● now (running for) · ○ to come
struct DeliveryTimeline: View {
    let stages: [DeliveryWorkerInfo.Stage]
    let current: Int
    let now: Date                  // the render's last word: the time of the stage running is counted to it

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CryoFieldLabel("Stages")
            DeliveryFlow(spacing: 6) {
                ForEach(Array(stages.enumerated()), id: \.offset) { i, s in
                    HStack(spacing: 5) {
                        Image(systemName: i < current ? "checkmark.circle.fill" : i == current ? "circle.inset.filled" : "circle")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(i < current ? Cryo.pass : i == current ? Cryo.ice : Cryo.ink3)
                        Text(s.title).font(CryoFont.body(11)).foregroundStyle(i <= current ? Cryo.ink : Cryo.ink3)
                        if let t = time(s, i) { Text(t).font(CryoFont.mono(10)).foregroundStyle(Cryo.ink2) }
                        if i < stages.count - 1 { Text("→").font(CryoFont.body(10)).foregroundStyle(Cryo.ink3) }
                    }
                }
            }
        }
    }

    func time(_ s: DeliveryWorkerInfo.Stage, _ i: Int) -> String? {
        guard let a = s.started else { return nil }
        if let b = s.ended, i < current { return Fmt.hm(b.timeIntervalSince(a)) }
        if i == current { return Fmt.hm(max(now, a).timeIntervalSince(a)) }
        return nil
    }
}

/// Lays its children out left to right, wrapping to the next line
struct DeliveryFlow: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width { y += line + spacing; x = 0; line = 0 }
            x += s.width + spacing; line = max(line, s.height); widest = max(widest, x)
        }
        return CGSize(width: min(width, widest), height: y + line)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX { y += line + spacing; x = bounds.minX; line = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; line = max(line, s.height)
        }
    }
}

/// The fps over the last minutes
struct DeliverySparkline: View {
    let values: [Double]
    var body: some View {
        GeometryReader { g in
            if values.count > 1, let hi = values.max(), let lo = values.min() {
                let span = max(hi - lo, 0.001)
                Path { p in
                    for (i, v) in values.enumerated() {
                        let pt = CGPoint(x: g.size.width * CGFloat(i) / CGFloat(values.count - 1), y: g.size.height * CGFloat(1 - (v - lo) / span))
                        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                    }
                }
                .stroke(Cryo.ice.opacity(0.8), lineWidth: 1.2)
            } else {
                Rectangle().fill(Cryo.s3).frame(height: 1).frame(maxHeight: .infinity)
            }
        }
    }
}

/// The frame being encoded, from the source: black ground, a thin grey ring, the timecode on a dark chip — no cyan, no glass
struct DeliveryThumbnail: View {
    let image: CGImage?
    let frame: Int?
    let info: DeliveryWorkerInfo?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Rectangle().fill(Color.black)
            if let image {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
            } else {
                Text("the frame being encoded shows here (every 12 s)").font(CryoFont.body(10)).foregroundStyle(Color(white: 0.55))
                    .multilineTextAlignment(.center).padding(10).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let frame {
                Text(RenderQC.timecode(frame: frame, fps: info?.fps ?? 24, start: info?.startTimecode))
                    .font(CryoFont.mono(10)).foregroundStyle(Color(red: 0.85, green: 0.87, blue: 0.88))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.65)))
                    .padding(6)
            }
        }
        .frame(width: 288, height: 162)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color(red: 0.59, green: 0.63, blue: 0.67).opacity(0.35), lineWidth: 1))
    }
}

// MARK: - The render queue

struct DeliveryQueueView: View {
    @Environment(Project.self) private var project

    var body: some View {
        let q = DeliveryQueue.shared
        let startable = q.items.filter { $0.state == .queued && !q.launched.contains($0.id) && q.blockers[$0.id] == nil && !q.autoStart.contains($0.id) }
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                CryoSectionHeader("Render queue")
                Spacer()
                if !startable.isEmpty {
                    Button(q.isRunning ? "START QUEUE AFTER THIS ONE" : "START QUEUE") { q.startQueue() }.buttonStyle(CryoGoButtonStyle(.primary))
                        .help("Renders every job waiting in the queue, in order, in one render process")
                }
            }
            CryoSlot {
                VStack(alignment: .leading, spacing: 0) {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
                        GridRow {
                            CryoFieldLabel("Job"); CryoFieldLabel("Output"); CryoFieldLabel("State"); CryoFieldLabel("Progress"); Text("")
                        }
                        ForEach(q.items) { it in
                            GridRow(alignment: .center) {
                                Text(it.job.name).font(CryoFont.body(12)).foregroundStyle(Cryo.ink).lineLimit(1)
                                Text(URL(fileURLWithPath: it.output?.path ?? it.job.output).lastPathComponent).font(CryoFont.mono(11)).foregroundStyle(Cryo.ink2).lineLimit(1).truncationMode(.middle)
                                state(it, q)
                                progress(it)
                                actions(it, q)
                            }
                        }
                    }
                }
            }
        }
    }

    func state(_ it: DeliveryItem, _ q: DeliveryQueue) -> some View {
        let (text, style): (String, CryoChip.Style) = {
            switch it.state {
            case .queued:
                if q.blockers[it.id] != nil { return ("NEEDS A DECISION", .fail) }
                if q.isWaitingInWorker(it.id) || q.autoStart.contains(it.id) { return ("NEXT", .lit) }
                return ("QUEUED", .plain)
            case .running: return ("RENDERING", .lit)
            case .done: return ("PASS", .pass)
            case .warning: return ("ATTENTION", .amber)
            case .failed: return ("FAIL", .fail)
            case .cancelled: return ("CANCELLED", .plain)
            }
        }()
        return CryoChip(text, style: style).help(q.blockers[it.id]?.joined(separator: "\n") ?? it.resultLines.first ?? "")
    }

    @ViewBuilder func progress(_ it: DeliveryItem) -> some View {
        if it.state == .running {
            let p = max(DeliveryMonitor.shared.jobID == it.id ? DeliveryMonitor.shared.overall : 0, it.snapshot?.overall ?? 0)
            HStack(spacing: 6) {
                ProgressView(value: p).tint(Cryo.ice).frame(width: 110)
                Text("\(Int((p * 100).rounded(.down))) %").font(CryoFont.mono(11)).foregroundStyle(Cryo.ink)
            }
        } else if let r = DeliveryQueue.shared.results[it.id] {
            Text(Fmt.hm(r.seconds)).font(CryoFont.mono(11)).foregroundStyle(Cryo.ink2)
        } else { Text("—").font(CryoFont.mono(11)).foregroundStyle(Cryo.ink3) }
    }

    func actions(_ it: DeliveryItem, _ q: DeliveryQueue) -> some View {
        HStack(spacing: 6) {
            Button { NSWorkspace.shared.activateFileViewerSelecting([it.jobFile]) } label: { Image(systemName: "doc.text.magnifyingglass") }
                .buttonStyle(.plain).foregroundStyle(Cryo.ink2).help("Show job file")
            Button { q.load(it.jobFile, into: project) } label: { Image(systemName: "arrow.up.forward.app") }
                .buttonStyle(.plain).foregroundStyle(Cryo.ink2).help("Open: the job comes back into the window, to check or change it")
                .disabled(q.busy != nil || project.busy)
            if it.state == .running || q.isWaitingInWorker(it.id) {
                Button { q.cancel(it.id) } label: { Image(systemName: "stop.circle") }.buttonStyle(.plain).foregroundStyle(Cryo.ink2).help("Cancel")
            } else {
                Button { q.remove(it.id) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).foregroundStyle(Cryo.ink2).help("Remove from the queue")
            }
        }
    }
}

/// START / ADD refused: why, and (for a job that didn't come back the same from its file) what differs
struct DeliveryRefusalCard: View {
    let refusal: DeliveryRefusal
    @State private var showDiff = false

    var body: some View {
        CryoSlot {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(refusal.title).font(CryoFont.title(14)).foregroundStyle(Cryo.ink)
                    Spacer()
                    Button { DeliveryQueue.shared.refusal = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(Cryo.ink3).help("Close")
                }
                ForEach(Array(refusal.lines.enumerated()), id: \.offset) { _, l in DeliveryLineRow(level: deliveryLevel(of: l) == .info ? .fail : deliveryLevel(of: l), text: l) }
                if let d = refusal.diff, !d.isEmpty {
                    Button(showDiff ? "Hide the difference" : "Show the difference") { showDiff.toggle() }.buttonStyle(.plain).font(CryoFont.body(11)).foregroundStyle(Cryo.ice)
                    if showDiff { TerminalBox(text: d, scrolls: false) }
                }
            }
        }
    }
}

// MARK: - Inspector

struct DeliveryInspector: View {
    @Environment(Project.self) private var project
    init() {}

    var body: some View {
        @Bindable var project = project
        @Bindable var q = DeliveryQueue.shared
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    CryoSectionHeader("Checks after writing")
                    Toggle(isOn: $project.verifyAudio) { label("Verify the audio bit for bit", "Recommended: every audio track against its source.") }
                    Toggle(isOn: $project.verifyVideo) { label("Verify the picture bit for bit", "Slower: hashes the whole picture again. Always on when the picture is transcoded in step 1.") }
                    Toggle(isOn: $project.pictureCheck) { label("Check the sound against the picture", "Hard cuts against sound hits, through the film (about a minute).") }
                    Text("Render QC and the Academy / Zidoo check always run on the final file.").font(CryoFont.body(11)).foregroundStyle(Cryo.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(CryoToggleStyle())
                .disabled(project.busy)
                VStack(alignment: .leading, spacing: 8) {
                    CryoSectionHeader("Audio / video interleave")
                    CryoSegmented(selection: $project.interleaveMs, options: [(250, "250 ms"), (500, "500 ms"), (1000, "1000 ms")])
                    Text("How the blocks are laid out in the file — doesn't change the quality. 500 ms is the default.").font(CryoFont.body(11)).foregroundStyle(Cryo.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 8) {
                    CryoSectionHeader("If the file already exists")
                    CryoSegmented(selection: $q.overwrite, options: [("keepBoth", "Keep both (_2)"), ("replace", "Replace")])
                    Text(q.overwrite == "replace" ? "The old file is replaced at the very end, and only if every check passes; a file that failed a check is saved beside it as _FAILED."
                                                  : "The new file gets a _2 name; nothing is ever overwritten.")
                        .font(CryoFont.body(11)).foregroundStyle(Cryo.ink3).fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 8) {
                    CryoSectionHeader("Commands (for reference)")
                    let preview: String = {
                        var s = project.commandPreview
                        if let p = DeliveryEngine.step1Plan(project), let out = project.outputURL {
                            s = "ffmpeg " + DeliveryEngine.quote(Transcode.arguments(p, concat: nil, output: out.deletingLastPathComponent().appendingPathComponent(".BROS-MUX-tmp/video.mov"), elementary: false)) + "\n" + s
                        }
                        return s
                    }()
                    TerminalBox(text: preview.isEmpty ? "—" : preview, scrolls: false)
                }
            }
            .padding(16)
        }
    }

    func label(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(CryoFont.body(12)).foregroundStyle(Cryo.ink)
            Text(detail).font(CryoFont.body(11)).foregroundStyle(Cryo.ink3).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Toolbar

/// SAVE JOB… · ADD TO QUEUE · START DELIVERY (⌘↩, amber when anything is transcoded; off with the reason while a ✕ is open)
struct DeliveryToolbarButtons: View {
    let project: Project
    init(project: Project) { self.project = project }

    var body: some View {
        let q = DeliveryQueue.shared
        let fails = q.preflight(project).filter { $0.level == .fail }
        let blocked = !fails.isEmpty || q.busy != nil
        let amber = DeliveryEngine.transcodesAnything(project)
        let reason = fails.isEmpty ? (q.busy ?? "") : fails.map { "✕ " + $0.text }.joined(separator: "\n")
        HStack(spacing: 8) {
            if !fails.isEmpty && !project.tracks.isEmpty {
                Text("\(fails.count) TO FIX").font(CryoFont.label()).tracking(0.8).foregroundStyle(Cryo.fail)
                    .help(reason)
            }
            Button("SAVE JOB…") { q.saveSheetShown = true }
                .buttonStyle(CryoButtonStyle())
                .disabled(project.tracks.isEmpty)
                .help("Save this delivery as a .bmjob (and a readable .job.txt) to run later or elsewhere")
            Button("ADD TO QUEUE") { q.enqueue(from: project) }
                .buttonStyle(CryoButtonStyle())
                .disabled(blocked)
                .help(blocked ? reason : "Save the job and put it in the render queue")
            Button { q.startNow(from: project) } label: {
                HStack(spacing: 6) {
                    if q.busy != nil { ProgressView().controlSize(.mini) }
                    Text(q.isRunning ? "START AFTER THIS ONE" : "START DELIVERY")
                }
            }
            .buttonStyle(CryoGoButtonStyle(amber ? .amber : .primary))
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(blocked)
            .opacity(blocked ? 0.45 : 1)
            .help(blocked ? reason : amber ? "Transcode and write the file (⌘↩) — the render runs on its own; you can keep working" : "Write the file (⌘↩) — the render runs on its own; you can keep working")
        }
    }
}

// MARK: - Save job

struct SaveJobSheet: View {
    let project: Project
    @Environment(\.dismiss) private var dismiss
    init(project: Project) { self.project = project }

    var body: some View {
        let fails = DeliveryQueue.shared.preflight(project).filter { $0.level == .fail }
        let inFile = project.included
        let out = project.tracks.filter { !$0.include }
        VStack(alignment: .leading, spacing: 14) {
            Text("SAVE THE JOB").font(CryoFont.label(12)).tracking(1.2).foregroundStyle(Cryo.ink2)
            Text(project.outputURL?.deletingPathExtension().lastPathComponent ?? "Delivery").font(CryoFont.title(18)).foregroundStyle(Cryo.ink)
            Text("Everything this delivery needs — the files with their fingerprints, the tracks, the sync, the picture plan, the checks — goes into a .bmjob, with a readable .job.txt next to it. Drop the .bmjob on the window to open it again, or run it on its own with BROS-MUX --job-file.")
                .font(CryoFont.body(12)).foregroundStyle(Cryo.ink2).fixedSize(horizontal: false, vertical: true)
            CryoSlot {
                VStack(alignment: .leading, spacing: 6) {
                    DeliveryReadout(label: "Output", value: project.outputURL?.lastPathComponent ?? "—", detail: project.outputFolder?.path)
                    Text("\(inFile.count) stream\(inFile.count == 1 ? "" : "s") in the file · \(out.count) left out · \(project.container.rawValue.uppercased())")
                        .font(CryoFont.body(12)).foregroundStyle(Cryo.ink2)
                    Text(DeliveryEngine.transcodesAnything(project) ? "Transcodes: " + [project.video.choice(project) != .copy ? "the picture" : nil, project.outputAudio.contains { $0.delivery != .copy } ? "audio" : nil].compactMap { $0 }.joined(separator: " and ") : "Copies every stream bit for bit")
                        .font(CryoFont.body(12)).foregroundStyle(DeliveryEngine.transcodesAnything(project) ? Cryo.attention : Cryo.ink2)
                }
            }
            if !fails.isEmpty {
                DeliveryLineRow(level: .warn, text: "It can't start as it is (\(fails.count) to fix) — you can still save it and fix it when you open it again.")
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).buttonStyle(CryoButtonStyle())
                Button("SAVE…") {
                    dismiss()
                    DispatchQueue.main.async { DeliveryQueue.shared.saveWithPanel(from: project) }
                }
                .keyboardShortcut(.defaultAction).buttonStyle(CryoGoButtonStyle(.primary))
            }
        }
        .padding(22)
        .frame(width: 560)
        .background(Cryo.s1)
    }
}
