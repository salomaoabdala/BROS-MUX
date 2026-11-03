// BROS-MUX — Sync Viewer
// Shows the reference (the video's own audio) and a track's waveforms before/after alignment, the offset measured
// along the film, the strongest hits of the mix to check by eye, and a manual nudge.

import SwiftUI

struct WaveEnvelope {
    var mins: [Float] = []
    var maxs: [Float] = []
    var isEmpty: Bool { mins.isEmpty }
}

/// One point measured along the film, and whether the sync engine trusted it
struct SyncSample {
    let point: SyncEngine.Point
    let used: Bool
}

enum WaveData {
    /// min/max per drawn column, normalized to the window's own peak (the stereo master and the 5.1 mix differ in level)
    static func envelope(_ s: [Float], columns: Int) -> WaveEnvelope {
        guard !s.isEmpty, columns > 0 else { return WaveEnvelope() }
        var peak: Float = 0
        for v in s { peak = max(peak, abs(v)) }
        let g: Float = peak > 1e-6 ? 1 / peak : 1
        var mins = [Float](repeating: 0, count: columns), maxs = [Float](repeating: 0, count: columns)
        let per = Double(s.count) / Double(columns)
        for c in 0..<columns {
            let a = min(s.count - 1, Int(Double(c) * per)), b = min(s.count, max(a + 1, Int(Double(c + 1) * per)))
            var lo: Float = 0, hi: Float = 0
            for i in a..<b { lo = min(lo, s[i]); hi = max(hi, s[i]) }
            mins[c] = lo * g; maxs[c] = hi * g
        }
        return WaveEnvelope(mins: mins, maxs: maxs)
    }

    /// Mono audio window starting at `start` seconds (a negative start reads as leading silence)
    static func window(_ src: SyncEngine.Source, start: Double, length: Double, rate: Int) -> [Float] {
        let n = max(1, Int(length * Double(rate)))
        var out = [Float](repeating: 0, count: n)
        let from = max(0, start)
        let lead = Int(((from - start) * Double(rate)).rounded())
        guard from < src.duration, lead < n else { return out }
        let d = SyncEngine.decode(src, from: from, length: length - (from - start), rate: rate)
        let m = min(d.count, n - lead)
        if m > 0 { for i in 0..<m { out[lead + i] = d[i] } }
        return out
    }

    /// The strongest sudden hits of a track (seconds, in time order) — the best places to check sync by eye
    static func beats(_ src: SyncEngine.Source, count: Int = 20, spacing: Double = 30) -> [Double] {
        let rate = 1000, hop = 10                         // 10 ms frames
        let x = SyncEngine.decode(src, from: 0, length: src.duration, rate: rate)
        let nF = x.count / hop
        guard nF > 300 else { return [] }
        var db = [Float](repeating: -120, count: nF)
        for f in 0..<nF {
            var e: Float = 0
            for i in 0..<hop { let v = x[f * hop + i]; e += v * v }
            db[f] = 10 * log10(e / Float(hop) + 1e-12)
        }
        let loud = db.sorted()[Int(Double(nF) * 0.9)]     // the hit itself is among the loudest 10% of the film
        let back = 30                                     // compared with the 300 ms before it
        var score = [Float](repeating: 0, count: nF)
        for f in back..<nF where db[f] >= loud {
            var before: Float = -120
            for k in (f - back)..<(f - 3) { before = max(before, db[k]) }
            score[f] = db[f] - before
        }
        let gap = Int(spacing * Double(rate)) / hop
        func pick(_ minRise: Float) -> [Int] {
            var picked: [Int] = []
            for f in (0..<nF).filter({ score[$0] >= minRise }).sorted(by: { score[$0] > score[$1] }) where picked.count < count {
                if picked.allSatisfy({ abs($0 - f) >= gap }) { picked.append(f) }
            }
            return picked
        }
        var picked = pick(12)
        if picked.count < count / 2 { picked = pick(6) }
        // the onset: the biggest single 10 ms jump in the 100 ms before the loudest frame
        return picked.map { f -> Double in
            var onset = f, jump: Float = -1000
            for k in max(1, f - 10)...f where db[k] - db[k - 1] > jump { jump = db[k] - db[k - 1]; onset = k }
            return Double(onset * hop) / Double(rate)
        }.sorted()
    }

    /// Which measured points the engine trusted (same rules as SyncEngine.measure)
    static func classify(_ pts: [SyncEngine.Point]) -> [SyncSample] {
        func reliable(_ p: SyncEngine.Point) -> Bool { p.corr >= 0.45 && p.corr >= p.second * 1.3 }
        let med = Fmt.median(pts.filter(reliable).map(\.lag))
        return pts.map { SyncSample(point: $0, used: reliable($0) && abs($0.lag - med) <= 0.004) }
    }

    static func span(_ s: Double) -> String { abs(s) >= 1 ? String(format: "%.3f s", abs(s)) : String(format: "%.1f ms", abs(s) * 1000) }
}

// MARK: - Model

@Observable
final class SyncViewerModel: Identifiable {
    let project: Project
    var targetID: UUID
    var center: Double = 60                // seconds, on the picture (reference) timeline
    var halfWidth: Double = 0.25           // seconds shown on each side of the playhead
    var after = true                       // the track as it will be muxed (trimmed) or as delivered
    var overlay = false
    var nudge = 0                          // samples added to the head trim (preview until applied)
    var refEnv = WaveEnvelope()
    var candEnv = WaveEnvelope()
    var loading = false
    var beats: [Double] = []
    var findingBeats = false
    var measuring = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var userMoved = false
    static let columns = 1500

    init(project: Project, target: Track) {
        self.project = project
        targetID = target.id
        center = max(10, (project.reference?.duration ?? target.duration) * 0.25)
    }

    var reference: Track? { project.reference }
    var targets: [Track] { project.tracks.filter { $0.kind == .audio && $0.include && $0.id != project.syncReferenceID } }
    var target: Track? { project.tracks.first { $0.id == targetID } }
    var isDolby: Bool { target?.codecKey == "eac3" }
    var sampleRate: Double { let s = target?.sampleRate ?? 0; return s > 0 ? s : 48000 }
    var fps: Double { project.videoTrack?.mi?.d("FrameRate") ?? 24 }
    var fpsText: String { String(format: fps.truncatingRemainder(dividingBy: 1) == 0 ? "%.0f" : "%.3f", fps) }
    var duration: Double { reference?.duration ?? target?.duration ?? 0 }
    var frameSamples: Int { Int((sampleRate / fps).rounded()) }
    /// length of each window the engine measured (same formula as SyncEngine.measure)
    var measureWindow: Double { min(30, max(4, min(reference?.duration ?? 0, target?.duration ?? 0) / 8)) }

    /// samples removed from the head of the track (negative = the sound starts later), nudge preview included
    var cut: Int { (target?.trimStart ?? 0) + nudge }
    /// what is really applied: E-AC-3 is cut only on whole 1536-sample Dolby frames, rounded down (as JobRunner does);
    /// a delay (negative) is a start delay in the container, so it needs no rounding
    func effective(_ c: Int) -> Int { isDolby && c > 0 ? c / 1536 * 1536 : c }
    var effectiveCut: Int { effective(cut) }
    var baseEffectiveCut: Int { effective(target?.trimStart ?? 0) }
    /// how late the reference is vs its own picture (s) — set in the Sync panel
    var refOffset: Double { project.referenceOffset }
    /// after muxing, how late (+) or early (−) the track's sound is vs the picture, in ms
    var residualMs: Double? { target?.syncLag.map { ($0 + refOffset - Double(effectiveCut) / sampleRate) * 1000 } }
    /// where the sound under the playhead sits in the lower lane, relative to the playhead (s, + = later)
    var marker: Double? { target?.syncLag.map { $0 - (after ? Double(effectiveCut) / sampleRate : 0) } }

    static func source(_ t: Track) -> SyncEngine.Source { .init(url: t.url, index: t.streamIndex, duration: t.duration, channels: t.channels) }

    /// what to draw, captured on the main thread so the decoding never reads the live model
    private struct WindowJob { let ref: SyncEngine.Source; let cand: SyncEngine.Source; let start: Double; let length: Double; let shift: Double; let rate: Int }

    private func job() -> WindowJob? {
        guard let ref = reference, let tgt = target else { return nil }
        return WindowJob(ref: Self.source(ref), cand: Self.source(tgt), start: center - halfWidth, length: halfWidth * 2,
                         shift: after ? Double(effectiveCut) / sampleRate : 0, rate: halfWidth <= 1 ? 48000 : 8000)
    }

    /// both windows are decoded at the same time (the reference sits in the big video file)
    private static func render(_ j: WindowJob) -> (WaveEnvelope, WaveEnvelope) {
        var r: [Float] = [], c: [Float] = []
        let group = DispatchGroup()
        DispatchQueue.global(qos: .userInitiated).async(group: group) { r = WaveData.window(j.ref, start: j.start, length: j.length, rate: j.rate) }
        c = WaveData.window(j.cand, start: j.start + j.shift, length: j.length, rate: j.rate)
        group.wait()
        return (WaveData.envelope(r, columns: columns), WaveData.envelope(c, columns: columns))
    }

    func reload() {
        generation += 1
        let g = generation
        guard let j = job() else { return }
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Self.render(j)
            DispatchQueue.main.async {
                guard g == self.generation else { return }
                self.refEnv = r.0; self.candEnv = r.1; self.loading = false
            }
        }
    }

    /// synchronous version (command line / screenshots)
    func reloadNow() { if let j = job() { (refEnv, candEnv) = Self.render(j) } }

    /// Hits are found on a standalone audio track (much faster to read than the big video file), mapped to picture time
    private func beatSource() -> (src: SyncEngine.Source, lag: Double)? {
        guard let t = targets.first(where: { $0.wav != nil }) ?? targets.first else { return nil }
        return (Self.source(t), t.syncLag ?? Double(t.trimStart) / max(1, t.sampleRate))
    }

    /// hits already found per source file (in the file's own time), so reopening the viewer is instant — main thread only
    private static var beatCache: [String: [Double]] = [:]

    func findBeats() {
        guard beats.isEmpty, !findingBeats, let b = beatSource() else { return }
        let key = "\(b.src.url.path)#\(b.src.index)"
        if let raw = Self.beatCache[key] { show(raw, lag: b.lag); return }
        findingBeats = true
        DispatchQueue.global(qos: .utility).async {
            let raw = WaveData.beats(b.src)
            DispatchQueue.main.async { Self.beatCache[key] = raw; self.findingBeats = false; self.show(raw, lag: b.lag) }
        }
    }

    /// hits in picture time; until the person moves, the viewer goes to the one closest to where it opened
    private func show(_ raw: [Double], lag: Double) {
        beats = raw.map { $0 - lag }.filter { $0 > 1 }
        if !userMoved, let near = beats.min(by: { abs($0 - center) < abs($1 - center) }) { jump(to: near, byUser: false) }
    }

    func findBeatsNow() { if let b = beatSource() { beats = WaveData.beats(b.src).map { $0 - b.lag }.filter { $0 > 1 } } }

    func jump(to t: Double, byUser: Bool = true) {
        if byUser { userMoved = true }
        center = max(halfWidth, min(t, duration - halfWidth))
        reload()
    }

    func moved() { userMoved = true; reload() }

    /// ◀ (sound earlier) = cut more, ▶ (sound later) = cut less, then (below zero) a start delay: silence written at the
    /// head for PCM, an edit-list delay in the container for Dolby — either way the sound itself is never touched
    func nudge(by samples: Int) {
        nudge += samples
        reload()
    }

    func measure() {
        guard let ref = reference, let t = target, !measuring else { return }
        measuring = true
        DispatchQueue.global(qos: .userInitiated).async {
            let res = Project.align(reference: ref, targets: [t], cancel: CancelFlag(), offset: self.refOffset) { _, _ in }
            DispatchQueue.main.async {
                if let r = res.first, let i = self.project.tracks.firstIndex(where: { $0.id == r.id }) {
                    if let s = r.samples { self.project.tracks[i].trimStart = s }
                    self.project.tracks[i].syncApplied = r.samples != nil
                    self.project.tracks[i].syncNote = r.note
                    self.project.tracks[i].syncLag = r.lag
                    self.project.tracks[i].syncPoints = r.points
                }
                self.nudge = 0; self.measuring = false; self.reload()
            }
        }
    }

    func applyNudge() {
        guard nudge != 0, let i = project.tracks.firstIndex(where: { $0.id == targetID }) else { return }
        let ms = Double(effectiveCut - baseEffectiveCut) / sampleRate * 1000
        project.tracks[i].trimStart += nudge
        project.tracks[i].syncNote = (project.tracks[i].syncNote ?? "") +
            String(format: " · manual nudge: sound %.2f ms %@", abs(ms), ms >= 0 ? "earlier" : "later")
        nudge = 0
        reload()
    }
}

// MARK: - Views

struct SyncViewerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: SyncViewerModel
    var standalone = false               // rendered for a screenshot (no Done button, no background loading)

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Sync Viewer", subtitle: model.target.map { "\($0.title) · \($0.url.lastPathComponent)" }) {
                if model.targets.count > 1 {
                    Picker("", selection: $model.targetID) {
                        ForEach(model.targets) { t in
                            Text(model.targets.count > 4 ? "\(t.title) · \(t.url.lastPathComponent)" : t.title).tag(t.id)
                        }
                    }
                    .headerPickerStyle(count: model.targets.count).labelsHidden().frame(maxWidth: 420)
                    .onChange(of: model.targetID) { model.nudge = 0; model.reload() }
                }
                if model.measuring { ProgressView().controlSize(.small); Text("Measuring…").foregroundStyle(.secondary) }
                else { Button("Measure Again") { model.measure() }.disabled(model.reference == nil || model.project.busy) }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: DS.gap) {
                    GroupBox { verdict }.groupBoxStyle(.inset)
                    Text("How it syncs: BROS-MUX lines up the real waveforms. It slides the track's waveform against the reference (the video's own audio) over 30-second windows and finds the position where the two shapes match best — cross-correlation, the precise version of lining waveforms up by eye — at 15 points spread evenly over the whole film (film length ÷ 15), down to a single sample (1/48,000 s). Points in repetitive music, where the match is ambiguous, are ignored; the median of the points that agree is used.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
                    GroupBox { OffsetChart(model: model).frame(height: 200) }.groupBoxStyle(.inset)
                    GroupBox("Waveforms") {
                        VStack(alignment: .leading, spacing: 10) {
                            waveformControls
                            WaveLanes(ref: model.refEnv, cand: model.candEnv, overlay: model.overlay, halfWidth: model.halfWidth, fps: model.fps,
                                      refLabel: "REFERENCE · \(model.reference?.title ?? "") (the video's audio)",
                                      candLabel: "\(model.target?.title ?? "") · \(model.after ? "after alignment (as muxed)" : "before alignment (as delivered)")",
                                      marker: model.marker, markerLabel: markerLabel)
                                .frame(height: 300)
                                .background(DS.scope, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            HStack(spacing: 10) {
                                Text("Where").foregroundStyle(.secondary)
                                Slider(value: $model.center, in: 0...max(model.duration, 1), onEditingChanged: { editing in if !editing { model.moved() } })
                                Button { step(-1) } label: { Image(systemName: "backward.end.fill") }.help("Previous hit").disabled(model.beats.isEmpty)
                                Button { step(1) } label: { Image(systemName: "forward.end.fill") }.help("Next hit").disabled(model.beats.isEmpty)
                            }
                            HStack(spacing: 8) {
                                Text(model.findingBeats ? "Finding the strongest hits of the mix…" : "Strongest hits").font(.subheadline).foregroundStyle(.secondary)
                                if model.findingBeats { ProgressView().controlSize(.mini) }
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 6) {
                                        ForEach(Array(model.beats.enumerated()), id: \.offset) { i, b in
                                            Button("\(i + 1) · \(Fmt.duration(b).dropLast(4))") { model.halfWidth = min(model.halfWidth, 0.25); model.jump(to: b) }
                                                .buttonStyle(.bordered).controlSize(.small)
                                                .tint(abs(b - model.center) < 0.01 ? Color.accentColor : nil)
                                        }
                                    }
                                }
                            }
                            nudge
                        }
                    }
                    .groupBoxStyle(.inset)
                }
                .padding(.horizontal, 20).padding(.vertical, 8)
            }
            if !standalone {
                SheetButtons {
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(width: DS.sheet(1240, standalone ? 1010 : 960).width, height: DS.sheet(1240, standalone ? 1010 : 960).height)
        .onAppear { if !standalone { model.reload(); model.findBeats() } }
    }

    // what will happen, in words
    var verdict: some View {
        let sr = model.sampleRate
        return VStack(alignment: .leading, spacing: 6) {
            if let t = model.target, let lag = t.syncLag {
                Text(String(format: "Measured by waveform: “%@” is %.3f s %@ than the video's audio (%@ samples = %.2f frames at %@ fps).",
                            t.title, abs(lag), lag >= 0 ? "LATER" : "EARLIER", Fmt.int(Int((abs(lag) * sr).rounded())), abs(lag) * model.fps, model.fpsText))
                    .font(.headline)
                Text(moveText).fixedSize(horizontal: false, vertical: true)
                if let r = model.residualMs {
                    let ok = r <= 45 && r >= -15
                    Label {
                        Text(residualText(r)).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(ok ? Color.green : Color.orange)
                    }
                }
            } else {
                Text("Not measured yet — press “Measure Again” (or “Align Tracks” in the Sync section).").font(.headline)
            }
            if model.refOffset != 0 {
                Label {
                    Text(String(format: "The reference (the video's own audio) is %.1f ms late vs its picture, so the track is placed %.1f ms before it — in sync with the picture.",
                                model.refOffset * 1000, model.refOffset * 1000)).fixedSize(horizontal: false, vertical: true)
                } icon: { Image(systemName: "film").foregroundStyle(.orange) }
            }
            if model.nudge != 0 {
                let moved = Double(model.effectiveCut - model.baseEffectiveCut) / sr
                Label {
                    Text(String(format: "Manual nudge (preview): sound %.2f ms %@ (%.2f frame) — shown below; press Apply to keep it.",
                                abs(moved) * 1000, moved >= 0 ? "earlier" : "later", abs(moved) * model.fps))
                } icon: { Image(systemName: "hand.point.up.left.fill").foregroundStyle(Color.accentColor) }
            }
        }
        .padding(.vertical, 2)
    }

    var moveText: String {
        let c = model.effectiveCut
        let s = Double(abs(c)) / model.sampleRate
        let unit = model.isDolby ? String(format: " (%d Dolby frames of 32 ms)", abs(c) / 1536) : " (\(Fmt.int(abs(c))) samples)"
        if c > 0 { return String(format: "BROS-MUX removes %.3f s%@ from its head → its sound moves %.3f s EARLIER and lines up with the picture.", s, unit, s) }
        if c < 0 && model.isDolby { return String(format: "BROS-MUX makes it start %.3f s later with a start delay in the container (edit list — no Dolby frame is touched) → its sound moves %.3f s LATER and lines up with the picture.", s, s) }
        if c < 0 { return String(format: "BROS-MUX adds %.3f s of silence%@ at its head → its sound moves %.3f s LATER and lines up with the picture.", s, unit, s) }
        return "Nothing to trim — the track already starts with the picture."
    }

    func residualText(_ r: Double) -> String {
        if abs(r) < 0.05 { return "After the trim: exact sync (0.00 ms)." }
        var s = String(format: "After the trim: the sound is %.1f ms %@ (%.2f frame).", abs(r), r > 0 ? "late" : "early", abs(r) / 1000 * model.fps)
        if model.isDolby { s += r > 0 ? " Dolby audio can only be cut on whole 32 ms frames, rounded so the sound is late, never early." : " Dolby audio can only be cut on whole 32 ms frames; ▶ makes it start later (a start delay in the container)." }
        if r <= 45 && r >= -15 { s += " Well inside what viewers can notice (ITU-R BT.1359: 45 ms early / 125 ms late)." }
        return s
    }

    var waveformControls: some View {
        HStack(spacing: 14) {
            Picker("", selection: $model.after) {
                Text("Before alignment").tag(false)
                Text("After alignment (as muxed)").tag(true)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 380)
            .onChange(of: model.after) {
                // before alignment the same sound sits far from the playhead: zoom out so it's in view
                if !model.after, let m = model.marker, abs(m) + 0.3 > model.halfWidth { model.halfWidth = abs(m) + 0.3 > 1 ? 3 : 1 }
                model.reload()
            }
            Picker("", selection: $model.halfWidth) {
                Text("±3 s").tag(3.0); Text("±1 s").tag(1.0); Text("±250 ms").tag(0.25); Text("±50 ms").tag(0.05)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 300)
            .onChange(of: model.halfWidth) { model.reload() }
            Toggle("Overlay", isOn: $model.overlay)
            Spacer()
            if model.loading { ProgressView().controlSize(.small) }
            Text("Playhead \(Fmt.duration(model.center))").font(.system(.callout, design: .monospaced))
        }
    }

    var nudge: some View {
        HStack(spacing: 8) {
            Text("Nudge").foregroundStyle(.secondary)
            if model.isDolby {
                Button("◀ 1 Dolby frame (32 ms)") { model.nudge(by: 1536) }.help("Sound earlier by one Dolby frame")
                Button("1 Dolby frame (32 ms) ▶") { model.nudge(by: -1536) }.help("Sound later by one Dolby frame (below zero: a start delay in the container, no frame touched)")
            } else {
                Button("◀ 1 frame") { model.nudge(by: model.frameSamples) }.help("Sound earlier by one video frame")
                Button("◀ 1 ms") { model.nudge(by: Int(model.sampleRate / 1000)) }.help("Sound earlier by 1 ms")
                Button("1 ms ▶") { model.nudge(by: -Int(model.sampleRate / 1000)) }.help("Sound later by 1 ms")
                Button("1 frame ▶") { model.nudge(by: -model.frameSamples) }.help("Sound later by one video frame")
            }
            Button("Reset") { model.nudge = 0; model.reload() }.disabled(model.nudge == 0)
            Button("Apply") { model.applyNudge() }.buttonStyle(.borderedProminent).disabled(model.nudge == 0)
            Spacer()
            Text("◀ moves the sound earlier · ▶ later · the original audio is never changed, only where it starts")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    var markerLabel: String {
        guard let m = model.marker else { return "" }
        if !model.after { return "same sound, \(WaveData.span(m)) \(m > 0 ? "later" : "earlier") → BROS-MUX moves it to the playhead" }
        if model.refOffset != 0, let r = model.residualMs {
            return "\(WaveData.span(m)) \(m > 0 ? "after" : "before") the reference = " + (abs(r) < 0.05 ? "in sync with the picture" : String(format: "%.1f ms %@ vs the picture", abs(r), r > 0 ? "late" : "early"))
        }
        return "\(WaveData.span(m)) \(m > 0 ? "late" : "early")" + (model.isDolby && model.nudge == 0 ? " (Dolby frame rounding)" : "")
    }

    func step(_ dir: Int) {
        let b = model.beats
        guard let first = b.first, let last = b.last else { return }
        let next = dir > 0 ? b.first { $0 > model.center + 0.01 } ?? first : b.last { $0 < model.center - 0.01 } ?? last
        model.halfWidth = min(model.halfWidth, 0.25)
        model.jump(to: next)
    }
}

/// Two waveform lanes (or one overlaid) with a playhead, a ruler in ms and a one-frame grid
struct WaveLanes: View {
    let ref: WaveEnvelope
    let cand: WaveEnvelope
    let overlay: Bool
    let halfWidth: Double
    let fps: Double
    let refLabel: String
    let candLabel: String
    let marker: Double?
    let markerLabel: String

    var body: some View {
        Canvas { ctx, size in
            let ruler: CGFloat = 26
            let lanes = overlay ? 1 : 2
            let laneH = (size.height - ruler) / CGFloat(lanes)
            let cx = size.width / 2
            let refColor = Color(red: 0.35, green: 0.68, blue: 1.0)
            let candColor = overlay ? Color(red: 1.0, green: 0.6, blue: 0.2) : Color(red: 0.8, green: 0.5, blue: 1.0)
            let markColor = Color(red: 1.0, green: 0.83, blue: 0.25)
            func x(_ s: Double) -> CGFloat { cx + CGFloat(s / halfWidth) * size.width / 2 }

            // one-frame grid (when zoomed in enough to see frames)
            let totalS = halfWidth * 2
            if totalS <= 2.1 {
                let frame = 1 / fps
                var f = -(halfWidth / frame).rounded(.down) * frame
                while f <= halfWidth {
                    ctx.stroke(Path { $0.move(to: CGPoint(x: x(f), y: 0)); $0.addLine(to: CGPoint(x: x(f), y: size.height - ruler)) },
                               with: .color(.white.opacity(0.07)), lineWidth: 1)
                    f += frame
                }
            }
            func draw(_ env: WaveEnvelope, lane: Int, color: Color, label: String, labelY: CGFloat) {
                let mid = laneH * (CGFloat(lane) + 0.5)
                ctx.stroke(Path { $0.move(to: CGPoint(x: 0, y: mid)); $0.addLine(to: CGPoint(x: size.width, y: mid)) },
                           with: .color(.white.opacity(0.12)), lineWidth: 1)
                if !env.isEmpty {
                    let amp = laneH * 0.42, n = env.mins.count
                    var p = Path()
                    for c in 0..<n {
                        let px = (CGFloat(c) + 0.5) / CGFloat(n) * size.width
                        p.move(to: CGPoint(x: px, y: mid - CGFloat(env.maxs[c]) * amp))
                        p.addLine(to: CGPoint(x: px, y: mid - CGFloat(env.mins[c]) * amp + 0.6))
                    }
                    ctx.stroke(p, with: .color(color.opacity(overlay ? 0.8 : 1)), lineWidth: max(1, size.width / CGFloat(n)))
                }
                ctx.draw(Text(label).font(.caption.weight(.semibold)).foregroundColor(color), at: CGPoint(x: 10, y: labelY), anchor: .topLeading)
            }
            draw(ref, lane: 0, color: refColor, label: refLabel, labelY: 8)
            draw(cand, lane: overlay ? 0 : 1, color: candColor, label: candLabel, labelY: overlay ? 26 : laneH + 8)

            // where the playhead's sound is in the lower lane, with an arrow to the playhead
            func badge(_ str: String, at p: CGPoint, anchor: UnitPoint, color: Color? = nil) {
                let t = ctx.resolve(color.map { Text(str).font(.caption2).foregroundColor($0) }
                                    ?? Text(str).font(.caption.weight(.semibold)).foregroundColor(markColor))
                let sz = t.measure(in: CGSize(width: size.width, height: 40))
                let r = CGRect(x: p.x - anchor.x * sz.width, y: p.y - anchor.y * sz.height, width: sz.width, height: sz.height).insetBy(dx: -5, dy: -2)
                ctx.fill(Path(roundedRect: r, cornerRadius: 4), with: .color(DS.scope.opacity(0.88)))
                ctx.draw(t, at: p, anchor: anchor)
            }
            if let m = marker, abs(m) >= 0.0005 {
                let top = overlay ? 0 : laneH, bottom = overlay ? laneH : 2 * laneH
                let ay = bottom - 20
                if abs(m) <= halfWidth {
                    let mx = x(m)
                    ctx.stroke(Path { $0.move(to: CGPoint(x: mx, y: top + 26)); $0.addLine(to: CGPoint(x: mx, y: bottom - 4)) },
                               with: .color(markColor), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    let d: CGFloat = mx > cx ? 1 : -1
                    var a = Path()
                    a.move(to: CGPoint(x: mx, y: ay)); a.addLine(to: CGPoint(x: cx, y: ay))
                    if abs(mx - cx) > 12 {
                        a.move(to: CGPoint(x: cx + d * 8, y: ay - 5)); a.addLine(to: CGPoint(x: cx, y: ay)); a.addLine(to: CGPoint(x: cx + d * 8, y: ay + 5))
                    }
                    ctx.stroke(a, with: .color(markColor), lineWidth: 1.5)
                    let wide = abs(mx - cx) > 360
                    badge(markerLabel, at: CGPoint(x: wide ? (mx + cx) / 2 : mx + d * 8, y: ay - 8),
                          anchor: wide ? .bottom : (mx > cx ? .bottomLeading : .bottomTrailing))
                } else {
                    badge(m > 0 ? "\(markerLabel)  ▶ off screen" : "◀ off screen  \(markerLabel)",
                          at: CGPoint(x: m > 0 ? size.width - 12 : 12, y: ay), anchor: m > 0 ? .trailing : .leading)
                }
            }

            // playhead
            ctx.stroke(Path { $0.move(to: CGPoint(x: cx, y: 0)); $0.addLine(to: CGPoint(x: cx, y: size.height - ruler)) },
                       with: .color(.red), lineWidth: 1.5)
            // ruler
            let y0 = size.height - ruler
            ctx.fill(Path(CGRect(x: 0, y: y0, width: size.width, height: ruler)), with: .color(.black.opacity(0.35)))
            let totalMs = totalS * 1000
            let stepMs = [5.0, 10, 20, 50, 100, 200, 250, 500, 1000, 2000].first { totalMs / $0 <= 12 } ?? 1000
            var t = -(halfWidth * 1000 / stepMs).rounded(.down) * stepMs
            while t <= halfWidth * 1000 + 0.001 {
                let tx = x(t / 1000)
                ctx.stroke(Path { $0.move(to: CGPoint(x: tx, y: y0)); $0.addLine(to: CGPoint(x: tx, y: y0 + 6)) },
                           with: .color(.white.opacity(0.6)), lineWidth: 1)
                let label = t == 0 ? "0" : abs(t) >= 1000 ? String(format: "%+.1f s", t / 1000) : String(format: "%+.0f ms", t)
                if tx > 30 && tx < size.width - 30 {          // edge labels would be clipped
                    ctx.draw(Text(label).font(.system(.caption2, design: .monospaced)).foregroundColor(.white.opacity(0.75)),
                             at: CGPoint(x: tx, y: y0 + 8), anchor: .top)
                }
                t += stepMs
            }
            if totalS <= 2.1 {
                badge(String(format: "grid = 1 frame (%.1f ms)", 1000 / fps), at: CGPoint(x: size.width - 10, y: 8), anchor: .topTrailing,
                      color: .white.opacity(0.55))
            }
        }
    }
}

/// Offset measured at each point of the film, relative to what BROS-MUX applies
struct OffsetChart: View {
    let model: SyncViewerModel

    var body: some View {
        let pts = WaveData.classify(model.target?.syncPoints ?? [])
        let applied = Double(model.effectiveCut) / model.sampleRate - model.refOffset    // points at 0 = in sync with the picture
        let usedMs = pts.filter(\.used).map { ($0.point.lag - applied) * 1000 }
        let span = max(2.0, (usedMs.map(abs).max() ?? 0) * 1.6)          // ms shown above/below the line
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                Text("Offset measured along the film (after the trim)").font(.headline)
                Spacer()
                Label("used", systemImage: "circle.fill").foregroundStyle(.green).font(.caption)
                Label("ignored (ambiguous)", systemImage: "circle").foregroundStyle(.secondary).font(.caption)
                Text("+ = sound late · − = early · click a point to view it").font(.caption).foregroundStyle(.secondary)
            }
            GeometryReader { geo in plot(geo.size, pts: pts, applied: applied, span: span) }
            Text(footer(pts, applied: applied)).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    /// how the measured windows are spread over the film
    func footer(_ pts: [SyncSample], applied: Double) -> String {
        guard let first = pts.first, let last = pts.last else { return " " }
        func mmss(_ t: Double) -> String { String(format: "%02d:%02d", Int(t) / 60, Int(t) % 60) }
        let win = model.measureWindow
        let every = pts.count > 1 ? (last.point.time - first.point.time) / Double(pts.count - 1) : 0
        return String(format: "%d windows of %.0f s spread evenly over the whole film — one every %@ (from %@ to %@) · %d of %d agree · applied offset %+.6f s",
                      pts.count, win, every >= 60 ? "\(Int(every) / 60) min \(String(format: "%02d", Int(every) % 60)) s" : String(format: "%.0f s", every),
                      mmss(first.point.time), mmss(last.point.time + win), pts.filter(\.used).count, pts.count, applied)
    }

    func plot(_ size: CGSize, pts: [SyncSample], applied: Double, span: Double) -> some View {
        let dur = max(model.duration, 1)
        let left: CGFloat = 74, right: CGFloat = 10, bottom: CGFloat = 16
        let plotH = size.height - bottom
        func x(_ t: Double) -> CGFloat { left + CGFloat(t / dur) * (size.width - left - right) }
        func y(_ ms: Double) -> CGFloat { plotH / 2 - CGFloat(max(-span, min(span, ms)) / span) * (plotH / 2 - 10) }
        let center = model.center, win = model.measureWindow
        return ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in
                for (v, label) in [(span, String(format: "+%.1f ms", span)), (0, "applied"), (-span, String(format: "−%.1f ms", span))] {
                    ctx.stroke(Path { $0.move(to: CGPoint(x: left, y: y(v))); $0.addLine(to: CGPoint(x: size.width - right, y: y(v))) },
                               with: .color(v == 0 ? Color.accentColor.opacity(0.6) : Color.secondary.opacity(0.25)), lineWidth: v == 0 ? 1.5 : 1)
                    ctx.draw(Text(label).font(.system(.caption2, design: .monospaced)).foregroundColor(.secondary), at: CGPoint(x: 0, y: y(v)), anchor: .leading)
                }
                // minutes along the bottom
                let step = [60.0, 120, 300, 600, 900, 1200, 1800].first { dur / $0 <= 8 } ?? 3600
                var t = 0.0
                while t <= dur {
                    let edge = x(t) > size.width - 24
                    ctx.draw(Text("\(Int(t / 60)) min").font(.caption2).foregroundColor(.secondary),
                             at: CGPoint(x: edge ? size.width : x(t), y: size.height), anchor: edge ? .bottomTrailing : .bottom)
                    t += step
                }
                // playhead
                ctx.stroke(Path { $0.move(to: CGPoint(x: x(center), y: 0)); $0.addLine(to: CGPoint(x: x(center), y: plotH)) },
                           with: .color(.red.opacity(0.6)), lineWidth: 1)
                for s in pts {
                    let d = (s.point.lag - applied) * 1000
                    let px = x(s.point.time + win / 2), py = y(d)
                    // the stretch of film this point compared
                    ctx.stroke(Path { $0.move(to: CGPoint(x: x(s.point.time), y: py)); $0.addLine(to: CGPoint(x: x(s.point.time + win), y: py)) },
                               with: .color((s.used ? Color.green : Color.secondary).opacity(0.45)), lineWidth: 4)
                    let rect = CGRect(x: px - 5, y: py - 5, width: 10, height: 10)
                    if s.used { ctx.fill(Path(ellipseIn: rect), with: .color(.green)) }
                    else { ctx.stroke(Path(ellipseIn: rect), with: .color(.secondary), lineWidth: 1.5) }
                    if abs(d) > span {
                        ctx.draw(Text(String(format: "%+.0f ms", d)).font(.caption2).foregroundColor(.secondary),
                                 at: CGPoint(x: px, y: d > 0 ? py + 8 : py - 8), anchor: d > 0 ? .top : .bottom)
                    }
                }
                if pts.isEmpty {
                    ctx.draw(Text("No measurement yet").foregroundColor(.secondary), at: CGPoint(x: size.width / 2, y: plotH / 2), anchor: .center)
                }
            }
            Color.clear.contentShape(Rectangle())
                .onTapGesture { loc in
                    let t = Double((loc.x - left) / (size.width - left - right)) * dur
                    if let nearest = pts.min(by: { abs($0.point.time + win / 2 - t) < abs($1.point.time + win / 2 - t) }) {
                        model.jump(to: nearest.point.time + win / 2)          // the middle of that measured window
                    }
                }
        }
    }
}
