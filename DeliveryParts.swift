// BROS-MUX Beta 2.0.0 — pieces of the Delivery: output, Academy/Zidoo prediction, summary, result banner and log.
// Moved unchanged from MuxUI.swift (the Delivery owner restyles and rebinds them).

import SwiftUI
import AppKit

// MARK: - Result

struct ResultBanner: View {
    @Environment(Project.self) private var project
    @State private var showLog = false
    @State private var pictureModel: PictureSyncModel?

    var body: some View {
        switch project.state {
        case .done(let url):
            let s = project.resultState
            banner(color: s == .ok ? .green : s == .warning ? .orange : .red,
                   icon: s == .ok ? "checkmark.circle.fill" : s == .warning ? "exclamationmark.triangle.fill" : "xmark.octagon.fill",
                   title: s == .ok ? "Done — \(url?.lastPathComponent ?? "")" : s == .warning ? "File created, with warnings" : "File created, but a check failed") {
                if let insp = project.resultInspection {
                    if !project.hdr.encode, project.container != .mkv {
                        AcademySeal(level: insp.level, caption: "Verified on the final file", compact: true).padding(.top, 6)
                    }
                    ZidooSeal(level: insp.zidooLevel, caption: "Read from the final file · " + Zidoo.caveat, compact: true).padding(.top, 6)
                }
                HStack(spacing: 8) {
                    if let url {
                        Button("Inspect Final File") { project.inspector.load(url); project.mode = .inspect }
                        if project.included.contains(where: \.isAtmos) {
                            Button("Visualize Atmos") { project.atmos.load(url); project.mode = .atmos }
                        }
                        Button("Picture Sync Check…") { pictureModel = PictureSyncModel(project: project, output: url) }
                            .help("Frames around a hard cut, the waveform under them and a looping preview of the muxed file")
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                    Button("Log") { showLog = true }
                }
                .padding(.top, 6)
            } detail: {
                ForEach(Array(project.resultLines.enumerated()), id: \.offset) { _, l in
                    Text("• " + l).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
            .sheet(isPresented: $showLog) { LogSheet() }
            .sheet(item: $pictureModel) { PictureSyncSheet(model: $0) }
        case .failed:
            banner(color: .red, icon: "xmark.octagon.fill", title: "That didn't work") {
                Button("Show Full Log") { showLog = true }.padding(.top, 6)
            } detail: {
                ForEach(Array(project.resultLines.enumerated()), id: \.offset) { _, l in
                    Text(l).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
            .sheet(isPresented: $showLog) { LogSheet() }
        case .cancelled:
            banner(color: .secondary, icon: "stop.circle.fill", title: "Cancelled — nothing was written to the destination.") { EmptyView() } detail: { EmptyView() }
        default:
            EmptyView()
        }
    }

    func banner<A: View, D: View>(color: Color, icon: String, title: String,
                                  @ViewBuilder actions: () -> A, @ViewBuilder detail: () -> D) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.title2).foregroundStyle(color).symbolRenderingMode(.hierarchical)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                detail()
                actions()
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.radius, style: .continuous).fill(color.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: DS.radius, style: .continuous).strokeBorder(color.opacity(0.22), lineWidth: 1))
    }
}

/// Output: container, destination, quality options, progress and the command behind it all
struct OutputSection: View {
    @Environment(Project.self) private var project
    @State private var showCommand = false
    @State private var showQuality = false

    var body: some View {
        @Bindable var project = project
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("Format")
                Picker("Format", selection: $project.container) {
                    ForEach(Container.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                .disabled(project.busy)
            }
            // Render-style destination: folder, file name, and whether it fits
            VStack(alignment: .leading, spacing: DS.rowGap) {
                HStack {
                    Text("Save to")
                    Spacer()
                    Button("Choose Folder…") { project.chooseOutputFolder() }.controlSize(.small).disabled(project.tracks.isEmpty || project.busy)
                }
                Label {
                    Text(project.outputFolder?.path ?? "Add files to set the destination")
                        .font(.caption).lineLimit(2).truncationMode(.middle)
                        .foregroundStyle(project.outputFolder == nil ? Color.secondary : Color.primary)
                        .textSelection(.enabled)
                } icon: {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                }
                if project.outputURL != nil {
                    HStack(spacing: 6) {
                        Text("File name")
                        TextField("", text: Binding(get: { project.outputName }, set: { project.outputName = $0 }), prompt: Text("File name"))
                            .labelsHidden().textFieldStyle(.roundedBorder).disabled(project.busy)
                        Text(".\(project.container.rawValue)").foregroundStyle(.secondary).monospaced()
                    }
                    .font(.callout)
                }
            }
            if !project.tracks.isEmpty {
                LabeledContent("Estimated size") { Text(Fmt.bytes(project.estimatedSize)).monospacedDigit() }
                if let free = project.outputFree {
                    let need = project.outputNeeded
                    let fits = free >= need
                    VStack(alignment: .leading, spacing: 4) {
                        LabeledContent("Free on that drive") {
                            Text(Fmt.bytes(free)).monospacedDigit().foregroundStyle(fits ? Color.primary : Color.red)
                        }
                        ProgressView(value: min(1, need / max(free, 1))).tint(fits ? (need / free > 0.8 ? .orange : .green) : .red)
                        Text(fits ? "needs about \(Fmt.bytes(need)) while muxing (temp copy + final file)" : "not enough: about \(Fmt.bytes(need)) is needed while muxing — choose another drive")
                            .font(.caption).foregroundStyle(fits ? Color.secondary : Color.red).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack {
                Button { showQuality = true } label: { Label("Quality & Advanced…", systemImage: "slider.horizontal.3") }
                    .disabled(project.tracks.isEmpty || project.busy)
                Spacer()
            }
            .sheet(isPresented: $showQuality) { AudioOptionsView() }      // wave 0: AudioOptionsView still draws the old QualitySheet
            if project.state == .running {
                RunMonitorView(progress: project.progress, stage: project.stage, folder: project.outputFolder)
            }
            DisclosureGroup(isExpanded: $showCommand) {
                TerminalBox(text: project.commandPreview.isEmpty ? "—" : project.commandPreview, scrolls: false)
            } label: {
                Text(project.hdr.encode ? "Commands (for reference)" : "MP4Box command (for reference)").foregroundStyle(.secondary)
            }
        } header: {
            Text("Output")
        }
    }
}

/// Academy prediction for SDR deliveries; for playback versions, where the file will play
struct AcademySection: View {
    @Environment(Project.self) private var project

    var body: some View {
        if project.hdr.encode || project.container == .mkv {
            Section {
                PlaybackPanel()
            } header: {
                Text("Where it plays")
            }
        } else {
            Section {
                AcademySeal(level: project.predictedLevel, caption: "Predicted from the sources · verified on the final file after muxing", compact: true)
                let fails = project.predictedChecks.filter { $0.level == .fail }
                ForEach(Array(fails.prefix(3).enumerated()), id: \.offset) { _, c in
                    Label {
                        Text("\(c.title): \(c.detail)").font(.caption).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                    }
                }
            } header: {
                Text("Academy specs")
            }
        }
        Section {
            ZidooSeal(level: project.predictedZidooLevel, caption: "Predicted from the sources · " + Zidoo.caveat, compact: true)
            let issues = project.predictedZidooChecks.filter { $0.level == .fail || $0.level == .warn }
            ForEach(Array(issues.prefix(3).enumerated()), id: \.offset) { _, c in
                Label {
                    Text("\(c.title): \(c.detail)").font(.caption).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: c.level.icon).foregroundStyle(c.level.color)
                }
            }
        } header: {
            Text("Zidoo (screening room)")
        }
    }
}

/// What goes in and what comes out, track by track
struct SummarySections: View {
    @Environment(Project.self) private var project

    var body: some View {
        let inc = project.included
        let ref = project.reference
        let audiosOut = inc.filter { $0.kind == .audio }
        let video = inc.first { $0.kind == .video }
        Section {
            if let v = video { KeyValueRow(label: "Video", value: videoLine(v), chip: v.bitDepth > 0 ? "\(v.bitDepth)-bit" : nil) }
            ForEach(Array(project.tracks.filter { $0.kind == .audio && ($0.include || $0.id == ref?.id) }.enumerated()), id: \.offset) { _, a in
                KeyValueRow(label: a.id == ref?.id ? "Reference" : "Audio", value: audioLine(a), chip: a.quality.text, chipTint: a.quality.lossless ? .green : .orange)
            }
        } header: {
            Text("Input")
        }
        Section {
            if video != nil, let e = project.encodePlan {
                KeyValueRow(label: "Video", value: "HEVC Main 10 · \(e.width)×\(e.height) · \(Probe.fps("\(e.fps.num)/\(e.fps.den)") ?? "") fps · 10-bit 4:2:0 · \(e.formats)",
                            chip: "Re-encoded for playback", chipTint: .orange)
                KeyValueRow(label: "Color tags", value: e.outputColor.text + (e.hdr.map { " · HDR10 \($0.mastering.text)" } ?? ""))
            } else if let v = video {
                KeyValueRow(label: "Video", value: videoLine(v), chip: "Identical (no re-encode)", chipTint: .green)
                KeyValueRow(label: "Color tags", value: colorLine(v))
            }
            LabeledContent("Audio tracks") { Text("\(audiosOut.count)") }
            ForEach(Array(audiosOut.enumerated()), id: \.offset) { i, a in
                KeyValueRow(label: "Audio \(i + 1)", value: audioLine(a) + outAudioExtra(a),
                            chip: (project.planText(for: a) != nil ? "Identical + trimmed" : "Identical (bit-exact)") + (a.channelPermutation != nil ? " + reordered" : ""), chipTint: .green)
            }
        } header: {
            Text("Output · \(project.container.rawValue.uppercased()) · ~\(Fmt.bytes(project.estimatedSize))")
        }
    }

    func videoLine(_ v: Track) -> String {
        var parts = [v.codecName + (v.mi?["Format_Profile"].flatMap { v.codecName.contains($0) ? nil : " \($0)" } ?? "")]
        if let w = v.mi?["Width"], let h = v.mi?["Height"] { parts.append("\(w)×\(h)") }
        if let fr = v.mi?["FrameRate"] { parts.append("\(fr) fps") }
        let chroma = v.mi?["ChromaSubsampling"].map { " \($0)" } ?? ""
        if v.bitDepth > 0 { parts.append("\(v.bitDepth)-bit\(chroma)") }
        if v.bitRate > 0 { parts.append(Fmt.bitrate(v.bitRate)) }
        return parts.joined(separator: " · ")
    }
    func audioLine(_ a: Track) -> String {
        var parts = [a.codecName]
        if a.sampleRate > 0 { parts.append(Fmt.hz(a.sampleRate)) }
        if a.bitDepth > 0 && a.isPCM { parts.append("\(a.bitDepth)-bit") }
        parts.append("\(a.channels) ch")
        if a.bitRate > 0 { parts.append(Fmt.bitrate(a.bitRate) + (a.mi?["BitRate_Mode"] == "CBR" ? " CBR" : "")) }
        if let ci = a.mi?["ComplexityIndex"] { parts.append("CI \(ci)") }
        return parts.joined(separator: " · ")
    }
    func outAudioExtra(_ a: Track) -> String {
        guard a.isPCM else { return "" }
        if project.container == .mov, let tag = a.outputLayoutTag(writeLabels: project.writeChannelMap) {
            return " · " + ChannelMap.layoutName(tag)
        }
        return " · no channel labels"
    }
    func colorLine(_ v: Track) -> String {
        if project.fixColorTag { return "BT.709 / BT.709 / BT.709 (tag corrected)" }
        let p = v.mi?["colour_primaries"] ?? "—", t = v.mi?["transfer_characteristics"] ?? (v.mi?["Gamma"].map { "Gamma \($0)" } ?? "—"), m = v.mi?["matrix_coefficients"] ?? "—"
        return "\(p) / \(t) / \(m) (primaries / transfer / matrix)"
    }
}

// MARK: - Sheets

struct LogSheet: View {
    @Environment(Project.self) private var project
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "MP4Box Log") { EmptyView() }
            TerminalBox(text: project.log).padding(.horizontal, 20).padding(.top, 8)
            HStack {
                Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(project.log, forType: .string) }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
            .padding(20)
        }
        .frame(width: 760, height: 480)
    }
}
