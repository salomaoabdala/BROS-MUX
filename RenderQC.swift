// BROS-MUX — Render QC tab
// Drop a rendered file (a Resolve export) and it is read frame by frame for the faults a render can hide: green or
// magenta frames, "Media Offline" cards, stray black/white frames, repeated frames, flat bands/lines/blocks, timestamp
// gaps, audio dropouts, clicks and clipping. The engine is in RenderQCEngine.swift; this file is the model, the content
// view (`RenderQCView`), the inspector column (`RenderQCInspector`) and the command line entry (`RenderQC.cli`).

import SwiftUI
import AppKit
import UniformTypeIdentifiers

@Observable
final class RenderQCModel {
    static let shared = RenderQCModel()
    var url: URL?
    var running = false
    var stage = ""
    var progress = 0.0
    var report: RenderQC.Report?
    var elapsed = 0.0
    var error: String?
    var selected: UUID?
    var thumbs: [UUID: [CGImage]] = [:]
    var filter: RenderQC.Severity? = nil          // nil = everything
    @ObservationIgnored private var cancel = CancelFlag()
    @ObservationIgnored private var thumbJobs = Set<UUID>()

    func open(_ u: URL) {
        url = u; report = nil; error = nil; selected = nil; thumbs = [:]
        check()
    }

    func check() {
        guard let u = url, !running else { return }
        running = true; stage = "Opening…"; progress = 0; error = nil; report = nil
        let flag = CancelFlag(); cancel = flag
        let t0 = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            let rep = RenderQC.run(url: u, cancel: flag) { s, p in
                DispatchQueue.main.async { self.stage = s; self.progress = p }
            }
            DispatchQueue.main.async {
                self.elapsed = Date().timeIntervalSince(t0)
                if flag.isSet { self.stage = "Stopped." }
                else if let rep { self.report = rep; self.stage = ""; self.selected = rep.findings.first?.id }
                else { self.error = "This file can't be read as video (no video stream, or ffprobe/ffmpeg missing)." }
                self.running = false
            }
        }
    }

    func stop() { cancel.set() }

    var shown: [RenderQC.Finding] {
        guard let r = report else { return [] }
        return filter.map { f in r.findings.filter { $0.severity == f } } ?? r.findings
    }
    var selectedFinding: RenderQC.Finding? { report?.findings.first { $0.id == selected } }

    /// the frame before, the frame itself and the frame after (loaded once per finding)
    func loadThumbs(_ f: RenderQC.Finding) {
        guard let u = url, let info = report?.info, thumbs[f.id] == nil, !thumbJobs.contains(f.id) else { return }
        thumbJobs.insert(f.id)
        let first = max(0, f.frame - 1)
        DispatchQueue.global(qos: .userInitiated).async {
            let imgs = PictureSync.thumbnails(video: u, index: info.videoIndex, fps: info.fps, firstFrame: first, count: 3, width: 480, height: 270)
            DispatchQueue.main.async { self.thumbs[f.id] = imgs; self.thumbJobs.remove(f.id) }
        }
    }

    func timecode(_ f: RenderQC.Finding) -> String {
        guard let info = report?.info else { return "" }
        return RenderQC.timecode(frame: f.frame, fps: info.fps, start: info.startTimecode)
    }

    func reportText() -> String {
        guard let r = report, let u = url else { return "" }
        let i = r.info
        var lines = ["BROS-MUX — Render QC", "File: \(u.path)",
                     String(format: "%d×%d %@ %@ · %.3f fps · %d frames · %@ · audio: %@", i.width, i.height, i.codec, i.pixFmt, i.fps, r.framesAnalysed,
                            i.startTimecode.map { "start TC \($0)" } ?? "no timecode", i.audioStreams.map { "\($0.codec) \($0.channels) ch \($0.rate) Hz" }.joined(separator: ", ")),
                     String(format: "Checked on %@ in %.0f s", DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short), elapsed), ""]
        lines.append(r.findings.isEmpty ? "No render faults found." : "\(r.errors) error(s), \(r.warnings) warning(s), \(r.findings.count - r.errors - r.warnings) note(s):")
        for f in r.findings {
            lines.append("  \(f.severity == .error ? "ERROR  " : f.severity == .warning ? "WARNING" : "note   ") \(timecode(f)) (frame \(f.frame)) \(f.kind.rawValue): \(f.detail)")
        }
        for n in r.notes { lines.append("note: " + n) }
        return lines.joined(separator: "\n") + "\n"
    }

    func saveReport() {
        let p = NSSavePanel()
        p.allowedContentTypes = [.plainText]
        p.nameFieldStringValue = (url?.deletingPathExtension().lastPathComponent ?? "render") + "_QC.txt"
        if p.runModal() == .OK, let u = p.url { try? reportText().write(to: u, atomically: true, encoding: .utf8) }
    }

    func pick() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie, .data]
        p.allowsMultipleSelection = false
        p.message = "Choose a rendered file to check"
        if p.runModal() == .OK, let u = p.url { open(u) }
    }
}

private func level(_ s: RenderQC.Severity) -> CheckLevel { s == .error ? .fail : s == .warning ? .warn : .info }

// MARK: - Content column

/// The word next to a finding's icon (the same words as the filter and the saved report)
private func word(_ s: RenderQC.Severity) -> String { s == .error ? "ERROR" : s == .warning ? "WARNING" : "NOTE" }

/// A thin progress rail for a read-only check (no glow: Render QC looks for defects in pictures, it must not draw any)
private struct RenderQCRail: View {
    let fraction: Double
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Cryo.s3)
                Capsule().fill(Cryo.ice).frame(width: max(3, g.size.width * CGFloat(max(0, min(1, fraction)))))
            }
        }
        .frame(height: 4)
        .accessibilityElement().accessibilityLabel("Progress").accessibilityValue("\(Int((fraction * 100).rounded())) %")
    }
}

/// The neutral ground around a picture: achromatic black and grey, no ice, no glass, no colour near the frame
private enum RenderQCNeutral {
    static let plate = Color(white: 0.055)
    static let ground = Color.black
    static let ring = Color(white: 0.62, opacity: 0.35)
    static let text = Color(white: 0.80)
    static let dim = Color(white: 0.55)
}

struct RenderQCView: View {
    var targeted = false
    @Bindable var model = RenderQCModel.shared
    @FocusState private var listFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            CryoStrip(touch: .readOnly, title: "RENDER QC",
                      text: "reads every frame and every sample, never changes the file — no reference needed: each frame is compared with its neighbours")
            Group {
                if model.url == nil && !model.running { empty }
                else { findings }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    var empty: some View {
        CryoDropZone(title: "Check a render",
                     subtitle: "Drop a rendered file here — a DaVinci Resolve export, for example. Every frame and every sample is read, and the faults a render can hide are listed with the frames around them: green or magenta frames, “Media Offline” cards, a stray black or white frame, a repeated frame, a flat band or block that lasts one frame, timestamp gaps, audio dropouts, clicks and clipping. A 4K hour takes about ten minutes.",
                     systemImage: AppMode.qc.symbol, targeted: targeted) { model.pick() }
    }

    var findings: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let u = model.url {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(u.lastPathComponent).font(CryoFont.title(15)).foregroundStyle(Cryo.ink).lineLimit(1).truncationMode(.middle)
                    if let i = model.report?.info {
                        Text(String(format: "%d×%d · %@ · %.3f fps", i.width, i.height, i.codec.uppercased(), i.fps))
                            .font(CryoFont.mono(11)).foregroundStyle(Cryo.ink3)
                    }
                    Spacer(minLength: 0)
                }
            }
            if model.running {
                CryoSlot {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(model.stage).font(CryoFont.body(12.5)).foregroundStyle(Cryo.ink).lineLimit(1)
                            Spacer(minLength: 8)
                            Text("\(Int((model.progress * 100).rounded())) %").font(CryoFont.mono(12)).foregroundStyle(Cryo.ink2)
                            Button("Stop") { model.stop() }.buttonStyle(CryoButtonStyle())
                        }
                        RenderQCRail(fraction: model.progress)
                    }
                }
            }
            if let e = model.error { NoticeRow(text: e, level: .fail) }
            if let r = model.report {
                HStack(spacing: 12) {
                    CryoSegmented(selection: $model.filter, options: [
                        (value: RenderQC.Severity?.none, label: "All \(r.findings.count)"),
                        (value: RenderQC.Severity?.some(.error), label: "Errors \(r.errors)"),
                        (value: RenderQC.Severity?.some(.warning), label: "Warnings \(r.warnings)"),
                        (value: RenderQC.Severity?.some(.info), label: "Notes \(r.findings.count - r.errors - r.warnings)"),
                    ])
                    .fixedSize()
                    Spacer(minLength: 8)
                    if !r.findings.isEmpty { Text("↑ ↓ to step through").font(CryoFont.body(11)).foregroundStyle(Cryo.ink3) }
                }
                if model.shown.isEmpty {
                    VStack(spacing: 10) {
                        if r.findings.isEmpty {
                            Image(systemName: "checkmark.seal.fill").font(.system(size: 34)).foregroundStyle(Cryo.pass)
                            ChecksSection.Status(level: .ok)
                            Text("Every frame and every sample passed.").font(CryoFont.body()).foregroundStyle(Cryo.ink2)
                        } else {
                            Image(systemName: "tray").font(.system(size: 30, weight: .light)).foregroundStyle(Cryo.ink3)
                            Text("Nothing in this category.").font(CryoFont.body()).foregroundStyle(Cryo.ink2)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    list
                }
            } else if model.running {
                Spacer(minLength: 0)
            }
        }
        .padding(16)
    }

    /// The findings, one row each: status (icon + word), timecode in mono, frame, what it is
    var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(model.shown) { f in
                        row(f).id(f.id)
                            .contentShape(Rectangle())
                            .onTapGesture { model.selected = f.id; listFocused = true }
                    }
                }
                .padding(.vertical, 2)
            }
            .focusable()
            .focused($listFocused)
            .focusEffectDisabled()
            .onKeyPress(.downArrow) { step(1, proxy); return .handled }
            .onKeyPress(.upArrow) { step(-1, proxy); return .handled }
        }
    }

    func step(_ d: Int, _ proxy: ScrollViewProxy) {
        let s = model.shown
        guard !s.isEmpty else { return }
        let i = s.firstIndex { $0.id == model.selected }.map { max(0, min(s.count - 1, $0 + d)) } ?? 0
        model.selected = s[i].id
        proxy.scrollTo(s[i].id)
    }

    func row(_ f: RenderQC.Finding) -> some View {
        let lv = level(f.severity)
        let on = model.selected == f.id
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            ChecksSection.Status(level: lv, word: word(f.severity)).frame(width: 78, alignment: .leading)
            Text(model.timecode(f)).font(CryoFont.mono(13)).foregroundStyle(Cryo.ink).frame(width: 104, alignment: .leading)
            Text("f \(f.frame)").font(CryoFont.mono(11)).foregroundStyle(Cryo.ink3).frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(f.kind.rawValue + (f.count > 1 ? " · \(f.count) frames" : "")).font(CryoFont.body(13).weight(.medium)).foregroundStyle(Cryo.ink)
                Text(f.detail).font(CryoFont.body(11.5)).foregroundStyle(Cryo.ink2).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(on ? Cryo.s2 : Cryo.s1))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(on ? Cryo.ice.opacity(0.7) : Cryo.s3, lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(on ? [.isSelected, .isButton] : .isButton)
    }
}

// MARK: - Inspector column

struct RenderQCInspector: View {
    @Bindable var model = RenderQCModel.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let r = model.report { summary(r); frames }
                else if let u = model.url {
                    CryoSectionHeader("File")
                    CryoSlot {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(u.lastPathComponent).font(CryoFont.body(13).weight(.medium)).foregroundStyle(Cryo.ink).lineLimit(2)
                            Text(model.running ? model.stage : "Not checked yet.").font(CryoFont.body(12)).foregroundStyle(Cryo.ink2)
                        }
                    }
                } else {
                    CryoSectionHeader("Render QC")
                    Text("Open a rendered file to check it. Render QC only reads it — nothing is written.")
                        .font(CryoFont.body(12.5)).foregroundStyle(Cryo.ink2).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 8) {
                    if model.url != nil && !model.running { Button("Check Again") { model.check() }.buttonStyle(CryoButtonStyle()) }
                    if model.report != nil { Button("Save Report…") { model.saveReport() }.buttonStyle(CryoButtonStyle()) }
                    Spacer(minLength: 0)
                }
            }
            .padding(16)
        }
    }

    func summary(_ r: RenderQC.Report) -> some View {
        let i = r.info
        let ok = r.errors == 0 && r.warnings == 0
        let lv: CheckLevel = ok ? .ok : r.errors > 0 ? .fail : .warn
        return VStack(alignment: .leading, spacing: 8) {
            CryoSectionHeader("Result")
            CryoSlot {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .center, spacing: 10) {
                        Image(systemName: lv.icon).font(.system(size: 22)).foregroundStyle(ChecksSection.color(lv))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(lv.text).font(CryoFont.label(10.5)).tracking(1).foregroundStyle(ChecksSection.color(lv))
                            Text(ok ? "No render faults found" : "\(r.errors) error\(r.errors == 1 ? "" : "s"), \(r.warnings) warning\(r.warnings == 1 ? "" : "s")")
                                .font(CryoFont.title(14)).foregroundStyle(Cryo.ink)
                        }
                    }
                    ChecksSection.Hairline()
                    fact("Picture", String(format: "%d×%d %@ %@ · %.3f fps · %@ frames", i.width, i.height, i.codec.uppercased(), i.pixFmt, i.fps, Fmt.int(r.framesAnalysed)))
                    fact("Timecode", i.startTimecode.map { "starts at \($0)" } ?? "no timecode track")
                    fact("Audio", i.audioStreams.isEmpty ? "no audio" : i.audioStreams.map { "\($0.codec.uppercased()) \($0.channels) ch \($0.rate) Hz" }.joined(separator: " · "))
                    ForEach(r.notes, id: \.self) { NoticeRow(text: $0, level: .info) }
                    Text(String(format: "Checked in %.0f s.", model.elapsed)).font(CryoFont.mono(10.5)).foregroundStyle(Cryo.ink3)
                }
            }
        }
    }

    func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(CryoFont.label(9.5)).tracking(1).foregroundStyle(Cryo.ink3)
            Text(value).font(CryoFont.mono(11.5)).foregroundStyle(Cryo.ink).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The frame before, the finding and the frame after, on a neutral plate: black ground, grey ring, grey labels
    /// outside the picture — nothing coloured, glowing or glassy near the frames, so a colour fault reads as it is
    var frames: some View {
        VStack(alignment: .leading, spacing: 8) {
            CryoSectionHeader("Selected finding")
            if let f = model.selectedFinding {
                let imgs = model.thumbs[f.id] ?? []
                let lv = level(f.severity)
                VStack(alignment: .leading, spacing: 10) {
                    CryoSlot {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                ChecksSection.Status(level: lv, word: word(f.severity))
                                Text(f.kind.rawValue).font(CryoFont.body(13).weight(.semibold)).foregroundStyle(Cryo.ink)
                                Spacer(minLength: 0)
                            }
                            Text(f.detail).font(CryoFont.body(12)).foregroundStyle(Cryo.ink2).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(model.timecode(f)).font(CryoFont.mono(13)).foregroundStyle(Cryo.ink).textSelection(.enabled)
                                Text("frame \(f.frame)" + (f.count > 1 ? " · \(f.count) frames" : "") + String(format: " · %.3f s", f.time))
                                    .font(CryoFont.mono(11)).foregroundStyle(Cryo.ink3)
                            }
                            Button("Copy Timecode") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.timecode(f), forType: .string) }
                                .buttonStyle(CryoButtonStyle())
                        }
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(0..<3, id: \.self) { k in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    if k == 1 { Image(systemName: "arrowtriangle.right.fill").font(.system(size: 8)).foregroundStyle(RenderQCNeutral.text) }
                                    Text(k == 0 ? "frame \(max(0, f.frame - 1)) · before" : k == 1 ? "frame \(f.frame) · the finding" : "frame \(f.frame + 1) · after")
                                        .font(CryoFont.mono(10.5).weight(k == 1 ? .semibold : .regular))
                                        .foregroundStyle(k == 1 ? RenderQCNeutral.text : RenderQCNeutral.dim)
                                }
                                ZStack {
                                    Rectangle().fill(RenderQCNeutral.ground).aspectRatio(16 / 9, contentMode: .fit)
                                    if k < imgs.count { Image(decorative: imgs[k], scale: 1).resizable().aspectRatio(16 / 9, contentMode: .fit) }
                                    else { ProgressView().controlSize(.small) }
                                }
                                .overlay(Rectangle().strokeBorder(RenderQCNeutral.ring, lineWidth: k == 1 ? 1.5 : 1))
                            }
                        }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(RenderQCNeutral.plate))
                    .environment(\.colorScheme, .dark)
                }
                .onAppear { model.loadThumbs(f) }
                .onChange(of: model.selected) { if let f = model.selectedFinding { model.loadThumbs(f) } }
            } else {
                Text("Select a finding to see the frame with the ones before and after it.")
                    .font(CryoFont.body(12.5)).foregroundStyle(Cryo.ink2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Command line

extension RenderQC {
    /// `--qc FILE`: the same check from the Terminal, printed as text (exit 1 when there are errors)
    static func cli(_ args: [String]) -> Int32 {
        setvbuf(stdout, nil, _IOLBF, 0)
        guard let f = args.first, !f.hasPrefix("-") else { print("usage: --qc FILE.mov"); return 2 }
        let t0 = Date()
        var last = -1
        guard let rep = run(url: URL(fileURLWithPath: f), cancel: CancelFlag(), progress: { s, p in
            let pct = Int(p * 100)
            if pct / 10 != last / 10 { print(String(format: "  … %@ %3d%%", s, pct)); last = pct }
        }) else { print("ERROR: can't read the file"); return 2 }
        let i = rep.info
        print(String(format: "FILE: %@ · %dx%d %@ %@ · %.3f fps · %d frames · %@ · audio %@ · %.0f s", f, i.width, i.height, i.codec, i.pixFmt, i.fps, rep.framesAnalysed,
                     i.startTimecode.map { "TC \($0)" } ?? "no timecode", i.audioStreams.map { "\($0.codec) \($0.channels)ch" }.joined(separator: ", "), Date().timeIntervalSince(t0)))
        for n in rep.notes { print("NOTE:", n) }
        print(rep.findings.isEmpty ? "RESULT: no render faults found" : "RESULT: \(rep.errors) error(s), \(rep.warnings) warning(s), \(rep.findings.count - rep.errors - rep.warnings) note(s)")
        for fd in rep.findings {
            print("  \(fd.severity == .error ? "✗" : fd.severity == .warning ? "⚠" : "·") \(timecode(frame: fd.frame, fps: i.fps, start: i.startTimecode)) f\(fd.frame) \(fd.kind.rawValue): \(fd.detail)")
        }
        return rep.errors > 0 ? 1 : 0
    }
}
