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

struct RenderQCView: View {
    var targeted = false
    @Bindable var model = RenderQCModel.shared

    var body: some View {
        Group {
            if model.url == nil && !model.running { empty }
            else { findings }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var empty: some View {
        VStack(spacing: DS.gap) {
            IconTile(symbol: "checkmark.shield", color: .accentColor, size: 56)
            Text("Check a render").font(.title2.weight(.semibold))
            Text("Drop a rendered file here — a DaVinci Resolve export, for example. Every frame and every sample is read, and the faults a render can hide are listed with the frames around them: green or magenta frames, “Media Offline” cards, a stray black or white frame, a repeated frame, a flat band or block that lasts one frame, timestamp gaps, audio dropouts, clicks and clipping.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 520).fixedSize(horizontal: false, vertical: true)
            Text("No reference file is needed: each frame is compared with its own neighbours. A 4K hour takes about ten minutes.")
                .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center).frame(maxWidth: 520)
            Button("Choose File…") { model.pick() }.buttonStyle(.borderedProminent).controlSize(.large).padding(.top, 4)
        }
        .padding(DS.margin * 2)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            if targeted {
                RoundedRectangle(cornerRadius: DS.radius + 4, style: .continuous).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 6])).padding(DS.margin)
            }
        }
    }

    var findings: some View {
        VStack(alignment: .leading, spacing: DS.gap) {
            if model.running {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: model.progress)
                    HStack { Text(model.stage).font(.caption).foregroundStyle(.secondary); Spacer(); Button("Stop") { model.stop() }.controlSize(.small) }
                }
                .padding(.horizontal, DS.margin).padding(.top, DS.margin)
            }
            if let e = model.error { NoticeRow(text: e, level: .fail).padding(.horizontal, DS.margin) }
            if let r = model.report {
                HStack(spacing: DS.gap) {
                    Picker("", selection: $model.filter) {
                        Text("All \(r.findings.count)").tag(RenderQC.Severity?.none)
                        Text("Errors \(r.errors)").tag(RenderQC.Severity?.some(.error))
                        Text("Warnings \(r.warnings)").tag(RenderQC.Severity?.some(.warning))
                        Text("Notes \(r.findings.count - r.errors - r.warnings)").tag(RenderQC.Severity?.some(.info))
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 420)
                    Spacer()
                }
                .padding(.horizontal, DS.margin).padding(.top, model.running ? 0 : DS.margin)
                if model.shown.isEmpty {
                    VStack(spacing: DS.rowGap) {
                        Image(systemName: r.findings.isEmpty ? "checkmark.seal.fill" : "tray").font(.system(size: 36)).foregroundStyle(r.findings.isEmpty ? Color.green : Color.secondary)
                        Text(r.findings.isEmpty ? "Every frame and every sample passed." : "Nothing in this category.").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(model.shown, selection: $model.selected) { f in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: level(f.severity).icon).foregroundStyle(level(f.severity).color)
                            Text(model.timecode(f)).font(.system(.body, design: .monospaced)).frame(width: 104, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(f.kind.rawValue).font(.body.weight(.medium))
                                Text(f.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        .padding(.vertical, 2)
                        .tag(f.id)
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                }
            } else if model.running {
                Spacer()
            }
        }
    }
}

// MARK: - Inspector column

struct RenderQCInspector: View {
    @Bindable var model = RenderQCModel.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.gap) {
                if let r = model.report { summary(r); frames }
                else if let u = model.url { GroupBox("File") { KeyValueRow(label: u.lastPathComponent, value: model.running ? model.stage : "Not checked yet.") }.groupBoxStyle(.inset) }
                else { GroupBox("Render QC") { Text("Open a rendered file to check it.").font(.callout).foregroundStyle(.secondary) }.groupBoxStyle(.inset) }
                HStack {
                    if model.url != nil && !model.running { Button("Check Again") { model.check() } }
                    if model.report != nil { Button("Save Report…") { model.saveReport() } }
                    Spacer()
                }
            }
            .padding(DS.margin)
        }
    }

    func summary(_ r: RenderQC.Report) -> some View {
        let i = r.info
        let ok = r.errors == 0 && r.warnings == 0
        let lv: CheckLevel = ok ? .ok : r.errors > 0 ? .fail : .warn
        return GroupBox("Result") {
            VStack(alignment: .leading, spacing: DS.rowGap) {
                HStack(spacing: 10) {
                    Image(systemName: lv.icon).font(.title2).foregroundStyle(lv.color)
                    Text(ok ? "No render faults found" : "\(r.errors) error\(r.errors == 1 ? "" : "s"), \(r.warnings) warning\(r.warnings == 1 ? "" : "s")").font(.headline)
                }
                KeyValueRow(label: "Picture", value: String(format: "%d×%d %@ %@ · %.3f fps · %@ frames", i.width, i.height, i.codec.uppercased(), i.pixFmt, i.fps, Fmt.int(r.framesAnalysed)))
                KeyValueRow(label: "Timecode", value: i.startTimecode.map { "starts at \($0)" } ?? "no timecode track")
                KeyValueRow(label: "Audio", value: i.audioStreams.isEmpty ? "no audio" : i.audioStreams.map { "\($0.codec.uppercased()) \($0.channels) ch \($0.rate) Hz" }.joined(separator: " · "))
                ForEach(r.notes, id: \.self) { NoticeRow(text: $0, level: .info) }
                Text(String(format: "Checked in %.0f s.", model.elapsed)).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .groupBoxStyle(.inset)
    }

    var frames: some View {
        GroupBox("Frames") {
            if let f = model.selectedFinding {
                let imgs = model.thumbs[f.id] ?? []
                VStack(alignment: .leading, spacing: DS.rowGap) {
                    ForEach(0..<3, id: \.self) { k in
                        ZStack(alignment: .bottomLeading) {
                            if k < imgs.count { Image(decorative: imgs[k], scale: 1).resizable().aspectRatio(16 / 9, contentMode: .fit) }
                            else { Rectangle().fill(DS.scope).aspectRatio(16 / 9, contentMode: .fit); ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity) }
                            Text(k == 0 ? "frame \(max(0, f.frame - 1)) · before" : k == 1 ? "frame \(f.frame) · the finding" : "frame \(f.frame + 1) · after")
                                .font(.caption2.weight(.medium)).foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill((k == 1 ? Color.red : Color.black).opacity(0.7))).padding(6)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(k == 1 ? level(f.severity).color : DS.groupStroke, lineWidth: k == 1 ? 2 : 1))
                    }
                    KeyValueRow(label: f.kind.rawValue, value: f.detail, chip: model.timecode(f), chipTint: level(f.severity).color)
                    Button("Copy Timecode") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.timecode(f), forType: .string) }.controlSize(.small)
                }
                .onAppear { model.loadThumbs(f) }
                .onChange(of: model.selected) { if let f = model.selectedFinding { model.loadThumbs(f) } }
            } else {
                Text("Select a finding to see the frame with the ones before and after it.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .groupBoxStyle(.inset)
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
