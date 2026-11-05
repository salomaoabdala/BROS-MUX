// BROS-MUX Beta 2.0.0 — pieces of the Delivery, in Cryo: where the file goes (OutputSection), the checks after writing
// with the predicted Academy / Zidoo seals (AcademySection), the stream plan (SummarySections), the result
// (ResultBanner, fed by a DeliveryItem) and the log (LogSheet). Status colours mean status only: PASS mint + icon +
// word, ATTENTION amber, FAIL red; cyan is identity and light, never "OK".

import SwiftUI
import AppKit

// MARK: - Small pieces

/// The colour of a status (with its icon and word, never alone)
func deliveryColor(_ l: CheckLevel) -> Color {
    switch l {
    case .ok: return Cryo.pass
    case .warn: return Cryo.attention
    case .fail: return Cryo.fail
    case .info: return Cryo.info
    }
}

/// The status of an engine line, read from its ✓ / ⚠ / ✗ (the line itself is never rewritten here)
func deliveryLevel(of line: String) -> CheckLevel {
    if line.contains("✗") || line.contains("✕") || line.contains("FAILED") || line.hasPrefix("   ERROR") { return .fail }
    if line.contains("⚠") || line.hasPrefix("   warning") { return .warn }
    if line.contains("✓") { return .ok }
    return .info
}

/// One line with its status icon (✓ / ⚠ / ✕ lines of the engine, preflight lines)
struct DeliveryLineRow: View {
    let level: CheckLevel
    let text: String
    var mono = false
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: level.icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(deliveryColor(level))
                .frame(width: 14)
                .accessibilityLabel(level.text)
            Text(text).font(mono ? CryoFont.mono(11) : CryoFont.body(12)).foregroundStyle(level == .info ? Cryo.ink2 : Cryo.ink)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }
}

/// A transcode said out loud: opaque, amber, high contrast — source → destination and why
struct DeliveryAmberBox: View {
    let title: String
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 13, weight: .semibold)).foregroundStyle(Cryo.attention)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(CryoFont.label(11)).tracking(0.8).foregroundStyle(Cryo.attention)
                Text(text).font(CryoFont.body(12)).foregroundStyle(Cryo.ink).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(.sRGB, red: 0.16, green: 0.115, blue: 0.055, opacity: 1)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Cryo.attention.opacity(0.7), lineWidth: 1))
    }
}

/// A caps label and a value, side by side (numbers in mono)
struct DeliveryReadout: View {
    let label: String
    let value: String
    var detail: String? = nil
    var big = false
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            CryoFieldLabel(label)
            Text(value).font(CryoFont.mono(big ? 20 : 14)).foregroundStyle(Cryo.ink).lineLimit(1).minimumScaleFactor(0.7)
            if let detail { Text(detail).font(CryoFont.body(11)).foregroundStyle(Cryo.ink2).lineLimit(2).fixedSize(horizontal: false, vertical: true) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension Container {
    /// Where a file in this container plays (the Delivery's container summary)
    var deliveryWhere: String {
        switch self {
        case .mov: return "Academy, Resolve"
        case .mp4: return "TVs, players"
        case .mkv: return "home theater, Zidoo"
        }
    }
}

// MARK: - Output

/// Where the file goes: the container (where it will play) with Change…, the name and the folder
struct OutputSection: View {
    @Environment(Project.self) private var project

    var body: some View {
        @Bindable var project = project
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                CryoFieldLabel("Container").frame(width: 82, alignment: .leading)
                Text(project.container.rawValue.uppercased()).font(CryoFont.title(15)).foregroundStyle(Cryo.ink)
                Text(project.container.deliveryWhere).font(CryoFont.body(12)).foregroundStyle(Cryo.ink2)
                Spacer(minLength: 8)
                Menu {
                    ForEach(Container.allCases) { c in
                        Button { project.container = c } label: {
                            Text("\(c.rawValue.uppercased()) — \(c.deliveryWhere)" + (c == project.container ? "  ✓" : ""))
                        }
                    }
                } label: { Text("Change…") }
                .menuStyle(.borderlessButton).fixedSize()
                .disabled(project.busy)
                .help("Choose where this file will play; every check is done again")
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                CryoFieldLabel("Name").frame(width: 82, alignment: .leading)
                if project.outputURL != nil {
                    TextField("", text: Binding(get: { project.outputName }, set: { project.outputName = $0 }), prompt: Text("File name"))
                        .textFieldStyle(.plain).font(CryoFont.mono(12)).foregroundStyle(Cryo.ink).cryoField()
                        .disabled(project.busy)
                    Text(".\(project.container.rawValue)").font(CryoFont.mono(12)).foregroundStyle(Cryo.ink2)
                } else {
                    Text("Add the picture to name the file").font(CryoFont.body(12)).foregroundStyle(Cryo.ink3)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                CryoFieldLabel("Folder").frame(width: 82, alignment: .leading)
                Text(project.outputFolder?.path ?? "—").font(CryoFont.mono(11)).foregroundStyle(project.outputFolder == nil ? Cryo.ink3 : Cryo.ink2)
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Spacer(minLength: 8)
                Button("Choose…") { project.chooseOutputFolder() }.buttonStyle(CryoButtonStyle())
                    .disabled(project.tracks.isEmpty || project.busy)
            }
        }
    }
}

// MARK: - Checks after writing

/// The checks every Delivery runs on the file it wrote, and the Academy / Zidoo seals predicted from the sources
struct AcademySection: View {
    @Environment(Project.self) private var project

    var body: some View {
        let ref = project.reference
        let twoStep: Bool = { if case .transcode = project.video.choice(project) { return true }; return false }()
        let bits = project.verifyAudio || project.verifyVideo || twoStep
        VStack(alignment: .leading, spacing: 10) {
            CryoFieldLabel("Checks after writing")
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                row(bits, "Bit for bit", bits ? "every copied track against its source" + (twoStep ? ", the picture against the one made in step 1" : "") : "off — turn it on in the inspector")
                row(ref != nil, "Sync", ref.map { "each audio track against “\($0.title)”" } ?? "no sync reference: skipped")
                row(project.pictureCheck, "Sound vs picture", project.pictureCheck ? "hard cuts against sound hits, through the film" : "off — turn it on in the inspector")
                if project.outputAudio.contains(where: { $0.delivery != .copy }) {
                    row(true, "Transcoded audio", "level, channels, order and sync against the source")
                }
                row(true, "Render QC", "every frame of the final file (green, black, frozen frames, clicks…)")
                row(true, "Academy · Zidoo", "read from the final file")
            }
            HStack(alignment: .top, spacing: 24) {
                if !academyHidden, let l = project.predictedLevel {
                    CryoSeal(kind: .academy, passed: l != .notApproved, caption: "Predicted: \(l.title.lowercased())")
                }
                if let z = project.predictedZidooLevel {
                    CryoSeal(kind: .zidoo, passed: z != .noPlay, caption: "Predicted: \(z.title.lowercased())")
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
            if !academyHidden {
                let fails = project.predictedChecks.filter { $0.level == .fail }
                ForEach(Array(fails.prefix(3).enumerated()), id: \.offset) { _, c in
                    DeliveryLineRow(level: .fail, text: "Academy · \(c.title): \(c.detail)")
                }
            }
        }
    }

    /// A playback version (HEVC HDR) or an MKV isn't an Academy screening file
    var academyHidden: Bool { project.video.choice(project) == .hevcHDR || project.container == .mkv }

    @ViewBuilder func row(_ on: Bool, _ title: String, _ detail: String) -> some View {
        GridRow {
            CryoLamp(on ? Cryo.ice : Cryo.s3, size: 7)
            Text(title).font(CryoFont.body(12)).foregroundStyle(on ? Cryo.ink : Cryo.ink3)
            Text(detail).font(CryoFont.body(11)).foregroundStyle(Cryo.ink2).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - The stream plan

/// What goes into the file, stream by stream, on its signal line: straight for COPY, an amber node for TRANSCODE;
/// what stays out is said too ("not in the file · sync reference")
struct SummarySections: View {
    @Environment(Project.self) private var project

    var body: some View {
        let choice = project.video.choice(project)
        VStack(alignment: .leading, spacing: 8) {
            CryoFieldLabel("Streams")
            if let v = project.videoTrack { videoRow(v, choice) }
            ForEach(Array(project.outputAudio.enumerated()), id: \.element.id) { i, a in audioRow(a, slot: i + 1) }
            ForEach(Array(project.tracks.filter { $0.include && $0.kind == .subtitle }.enumerated()), id: \.element.id) { i, s in
                line("S\(i + 1)", .copy, "COPY · bit-exact", "Subtitles “\(s.title)” · \(s.codecName) · \(Languages.name(s.language))")
            }
            ForEach(project.tracks.filter { $0.include && $0.kind == .timecode }) { t in
                if project.container == .mkv { left("TC", "Timecode — MKV has no timecode track: left out") }
                else { line("TC", .copy, "COPY · bit-exact", "Timecode " + (project.videoTrack?.source?.timecode ?? "")) }
            }
            ForEach(project.tracks.filter { !$0.include && $0.kind != .video }) { t in
                left("—", outText(t))
            }
            if case .transcode = choice, let p = DeliveryEngine.step1Plan(project) {
                DeliveryAmberBox(title: "TRANSCODE OF THE PICTURE · STEP 1",
                                 text: "\(p.source.codecName) → \(p.outputCodecName) · \(p.outputBits)-bit \(p.outputChroma) · \(p.outputWidth)×\(p.outputHeight) — you chose it on the Video tab. Step 1 writes the new picture; step 2 copies it bit for bit into this file with the sound.")
                    .padding(.top, 4)
            } else if choice == .hevcHDR, let e = project.encodePlan {
                DeliveryAmberBox(title: "TRANSCODE OF THE PICTURE",
                                 text: "\(e.source.codecName) → \(e.outputCodecName) · \(e.formats) · \(e.outputWidth)×\(e.outputHeight)" +
                                       (project.hdr.dvSource != nil ? " — so the Dolby Vision metadata can go in (the picture as it came can't carry it)." : " — you chose it on the Video tab.") +
                                       (e.colourNote.map { " Colour: \($0)." } ?? ""))
                    .padding(.top, 4)
            }
            let audioT = project.outputAudio.filter { $0.delivery != .copy }
            if !audioT.isEmpty {
                DeliveryAmberBox(title: "TRANSCODE OF THE AUDIO",
                                 text: audioT.map { "“\($0.title)”: \($0.codecName) → \(DeliveryReport.audioRole($0, $0.delivery))" }.joined(separator: " · ") +
                                       " — chosen on the Audio tab. Level, channels, order and sync stay the same, and are checked after writing.")
            }
        }
    }

    func videoRow(_ v: Track, _ choice: VideoPlanModel.Choice) -> some View {
        let desc = [v.codecName, v.mi?["Width"].flatMap { w in v.mi?["Height"].map { "\(w)×\($0)" } }, v.mi?["FrameRate"].map { "\($0) fps" }, v.bitDepth > 0 ? "\(v.bitDepth)-bit" : nil]
            .compactMap { $0 }.joined(separator: " · ")
        switch choice {
        case .copy: return line("V", .copy, "COPY · bit-exact", desc)
        case .hevcHDR: return line("V", .transcode, "TRANSCODE → HEVC 10-bit", desc + " → " + project.hdr.formatsText)
        case .transcode(let s): return line("V", .transcode, "TRANSCODE → " + (TranscodePreset(rawValue: s.preset)?.label.components(separatedBy: " — ").first ?? s.preset), desc + " · step 1, then copied")
        }
    }

    func audioRow(_ a: Track, slot: Int) -> some View {
        var desc = [a.codecName, Probe.channelText(a.channels, a.channelLayout), a.sampleRate > 0 ? Fmt.hz(a.sampleRate) : nil].compactMap { $0 }.joined(separator: " · ")
        desc = "“\(a.title)” · " + desc
        var extra: [String] = []
        if a.id == project.reference?.id { extra.append("sync reference") }
        if project.planText(for: a) != nil { extra.append(a.trimStart != 0 ? String(format: "head trim %.1f ms", a.trimStartMs) : "trimmed to the picture") }
        if a.channelPermutation != nil { extra.append("channels reordered") }
        if a.isGroup { extra.append("\(a.members.count) monos joined") }
        let word = a.delivery == .copy ? "COPY · bit-exact" : "TRANSCODE → " + DeliveryReport.audioRole(a, a.delivery)
        return line("A\(slot)", a.delivery == .copy ? .copy : .transcode, word, desc + (extra.isEmpty ? "" : " · " + extra.joined(separator: " · ")))
    }

    func outText(_ t: Track) -> String {
        let from = project.isEmbedded(t) ? " from the video" : ""
        let ref = t.id == project.reference?.id ? " · sync reference" : ""
        let pending = t.kind == .audio && project.isEmbedded(t) && project.embeddedAudioAnswer[project.key(of: t)] == nil ? " · DECIDE on the Audio tab" : ""
        return "\(t.kind.label) “\(t.title)”\(from) · not in the file\(ref)\(pending)"
    }

    func line(_ label: String, _ touch: FileTouch, _ word: String, _ desc: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(label).font(CryoFont.mono(12)).foregroundStyle(Cryo.ink).frame(width: 28, alignment: .leading)
            CryoSignalLine(touch: touch).frame(width: 64)
            CryoChip(word, style: touch == .transcode ? .amber : .lit)
            Text(desc).font(CryoFont.body(12)).foregroundStyle(Cryo.ink2).lineLimit(2).truncationMode(.middle)
            Spacer(minLength: 0)
        }
    }

    func left(_ label: String, _ desc: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(label).font(CryoFont.mono(12)).foregroundStyle(Cryo.ink3).frame(width: 28, alignment: .leading)
            Rectangle().fill(Cryo.s3).frame(width: 64, height: 1)
            Text(desc).font(CryoFont.body(12)).foregroundStyle(Cryo.ink3).lineLimit(2)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Result

/// The end of a Delivery: the seals read from the final file, what the checks said, and where to go next.
/// Without an item it shows the window's own last run (the old in-window mux).
struct ResultBanner: View {
    @Environment(Project.self) private var project
    var item: DeliveryItem? = nil
    var onClose: (() -> Void)? = nil
    @State private var showLog = false
    @State private var showAll = false

    var body: some View {
        if let m = model {
            CryoSlot {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: m.level.icon).font(.system(size: 18, weight: .semibold)).foregroundStyle(deliveryColor(m.level))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(m.title).font(CryoFont.title(16)).foregroundStyle(Cryo.ink)
                            if let o = m.output { Text(o.path).font(CryoFont.mono(11)).foregroundStyle(Cryo.ink2).lineLimit(1).truncationMode(.middle).textSelection(.enabled) }
                        }
                        Spacer(minLength: 8)
                        Text(m.word).font(CryoFont.label(11)).tracking(1).foregroundStyle(deliveryColor(m.level))
                        if let onClose { Button { onClose() } label: { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(Cryo.ink3).help("Close") }
                    }
                    if m.academy != nil || m.zidoo != nil {
                        HStack(alignment: .top, spacing: 28) {
                            if let a = m.academy { CryoSeal(kind: .academy, passed: a != .notApproved, caption: a.title + " · verified on the final file") }
                            if let z = m.zidoo { CryoSeal(kind: .zidoo, passed: z != .noPlay, caption: z.title + " · " + Zidoo.caveat) }
                            Spacer(minLength: 0)
                        }
                    }
                    let all = m.lines.filter { $0 != m.title && $0 != "Cancelled — nothing was written to the destination." }
                    let lines = showAll ? all : Array(all.prefix(10))
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, l in DeliveryLineRow(level: deliveryLevel(of: l), text: l) }
                        if all.count > 10 {
                            Button(showAll ? "Show fewer" : "Show all \(all.count) lines") { showAll.toggle() }.buttonStyle(.plain).font(CryoFont.body(11)).foregroundStyle(Cryo.ice)
                        }
                    }
                    HStack(spacing: 8) {
                        if let url = m.output, FileManager.default.fileExists(atPath: url.path) {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.buttonStyle(CryoGoButtonStyle(.done))
                            Button("Inspect Final File") { project.inspector.load(url); project.mode = .inspect }.buttonStyle(CryoButtonStyle())
                            Button("Render QC") { RenderQCModel.shared.open(url); project.mode = .qc }.buttonStyle(CryoButtonStyle())
                        }
                        if m.output != nil, let r = m.report, FileManager.default.fileExists(atPath: r.path) {
                            Button("How This File Was Made") { NSWorkspace.shared.open(r) }.buttonStyle(CryoButtonStyle())
                                .help(r.path)
                        }
                        if m.log != nil || m.logURL != nil { Button("Log") { showLog = true }.buttonStyle(CryoButtonStyle()) }
                        Spacer(minLength: 0)
                    }
                }
            }
            .sheet(isPresented: $showLog) { LogSheet(title: "Render log", text: m.logURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? m.log ?? "") }
        }
    }

    struct Model {
        var level: CheckLevel; var word: String; var title: String; var output: URL?; var lines: [String]
        var academy: AcademyLevel?; var zidoo: ZidooLevel?; var report: URL?; var log: String?
        var logURL: URL? = nil
    }

    var model: Model? {
        if let item {
            let r = DeliveryQueue.shared.results[item.id]
            let logURL = DeliveryQueue.shared.logFile(item.id)
            let name = item.output?.lastPathComponent ?? item.job.name
            var m = Model(level: .info, word: "", title: "", output: item.output, lines: item.resultLines,
                          academy: r?.academy.flatMap(AcademyLevel.init(deliveryKey:)), zidoo: r?.zidoo.flatMap(ZidooLevel.init(deliveryKey:)),
                          report: r?.report.map { URL(fileURLWithPath: $0) }, log: nil,
                          logURL: FileManager.default.fileExists(atPath: logURL.path) ? logURL : nil)
            switch item.state {
            case .done: m.level = .ok; m.word = "PASS"; m.title = "Done — \(name)"
            case .warning: m.level = .warn; m.word = "ATTENTION"; m.title = "Written, with warnings — \(name)"
            case .failed:
                m.level = .fail; m.word = "FAIL"
                m.title = item.output != nil ? "Written, but a check failed — \(name)" : "That didn't work — \(item.job.name)"
            case .cancelled: m.level = .info; m.word = "CANCELLED"; m.title = "Cancelled — nothing was written to the destination"
            case .queued, .running: return nil
            }
            if item.job.video.choice == "hevcHDR" || item.job.container == "mkv" { m.academy = nil }
            return m
        }
        switch project.state {
        case .done(let url):
            let s = project.resultState
            let insp = project.resultInspection
            return Model(level: s == .ok ? .ok : s == .warning ? .warn : .fail, word: s == .ok ? "PASS" : s == .warning ? "ATTENTION" : "FAIL",
                         title: s == .ok ? "Done — \(url?.lastPathComponent ?? "")" : s == .warning ? "Written, with warnings" : "Written, but a check failed",
                         output: url, lines: project.resultLines, academy: project.hdr.encode || project.container == .mkv ? nil : insp?.level, zidoo: insp?.zidooLevel,
                         report: nil, log: project.log)
        case .failed:
            return Model(level: .fail, word: "FAIL", title: "That didn't work", output: nil, lines: project.resultLines, academy: nil, zidoo: nil, report: nil, log: project.log)
        case .cancelled:
            return Model(level: .info, word: "CANCELLED", title: "Cancelled — nothing was written to the destination", output: nil, lines: [], academy: nil, zidoo: nil, report: nil, log: nil)
        default:
            return nil
        }
    }
}

// MARK: - Log

struct LogSheet: View {
    @Environment(Project.self) private var project
    @Environment(\.dismiss) private var dismiss
    var title: String = "Log"
    var text: String? = nil

    var body: some View {
        let t = text ?? project.log
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased()).font(CryoFont.label(12)).tracking(1.2).foregroundStyle(Cryo.ink2)
            ScrollView([.vertical, .horizontal]) {
                Text(t.isEmpty ? "—" : t).font(CryoFont.mono(11)).foregroundStyle(Cryo.ink2).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Cryo.s0))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Cryo.s3, lineWidth: 1))
            HStack {
                Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(t, forType: .string) }.buttonStyle(CryoButtonStyle())
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(CryoGoButtonStyle(.primary))
            }
        }
        .padding(20)
        .frame(width: 760, height: 480)
        .background(Cryo.s1)
    }
}
