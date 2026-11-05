// BROS-MUX — the Transcode tab: the one place where the picture is re-encoded (Transcode.swift is the engine).
// A fixed strip says so at the top; the centre holds the queue and the Source → Destination card of the selected file
// (what changes in orange, what is preserved in grey); the inspector holds the presets and the settings.

import SwiftUI
import AppKit

// MARK: - Content column

struct TranscodeView: View {
    @Environment(Project.self) private var project
    let targeted: Bool

    var body: some View {
        @Bindable var m = TranscodeModel.shared
        VStack(spacing: 0) {
            TabStrip.transcode
            if m.items.isEmpty && m.loading == 0 {
                if !m.notices.isEmpty {
                    VStack(spacing: DS.rowGap) { ForEach(Array(m.notices.enumerated()), id: \.offset) { _, n in NoticeRow(text: n, level: .warn) } }
                        .padding(.horizontal, DS.margin).padding(.top, DS.gap)
                }
                EmptyDropView(targeted: targeted, title: "Drop the files to transcode",
                              subtitle: "ProRes, H.264, HEVC, DNxHD, JPEG 2000… → ProRes 422 HQ for the Academy, ProRes 422, an H.264 review copy, HEVC SDR or HEVC Dolby Vision. Several files make a queue. The originals are never touched.")
            } else {
                queue
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.gap) {
                        ForEach(Array(m.notices.enumerated()), id: \.offset) { _, n in NoticeRow(text: n, level: .warn) }
                        if let item = m.selected { TranscodeCard(item: item) }
                        else { Text("Select a file in the queue.").foregroundStyle(.secondary) }
                    }
                    .padding(DS.margin)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .overlay {
                    if targeted {
                        RoundedRectangle(cornerRadius: DS.radius, style: .continuous)
                            .fill(Color.accentColor.opacity(0.06))
                            .overlay(RoundedRectangle(cornerRadius: DS.radius, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 2))
                            .padding(8).allowsHitTesting(false)
                    }
                }
            }
        }
    }

    /// The files to transcode, one row each (selectable)
    var queue: some View {
        @Bindable var m = TranscodeModel.shared
        return VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Queue").font(.headline)
                Text("\(m.items.count) file\(m.items.count == 1 ? "" : "s") · one new file is written for each").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                if m.loading > 0 { HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Reading…").font(.caption).foregroundStyle(.secondary) } }
            }
            .padding(.horizontal, DS.margin).padding(.vertical, 8)
            List(selection: Binding(get: { m.selectedID }, set: { m.select($0) })) {
                ForEach(m.items) { item in
                    TranscodeItemRow(item: item).tag(item.id)
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 96, idealHeight: CGFloat(min(max(m.items.count, 1), 4)) * 58 + 12, maxHeight: 260)
        }
    }
}

struct TranscodeItemRow: View {
    let item: TranscodeItem
    var m: TranscodeModel { TranscodeModel.shared }

    var body: some View {
        let s = item.source
        HStack(spacing: 12) {
            IconTile(symbol: "film.fill", color: .blue)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(s.url.lastPathComponent).font(.headline).lineLimit(1).truncationMode(.middle)
                    status
                }
                Text("\(s.summary) · \(s.sizeText) · \(s.fpsText) fps · \(Fmt.duration(s.duration))" + (s.isHDR ? " · HDR " + s.color.short : "") + (s.timecode.map { " · TC \($0)" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Text("→ \(item.output.lastPathComponent)").font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if !m.running {
                Button { m.remove(item.id) } label: { Image(systemName: "xmark.circle.fill").imageScale(.large) }
                    .buttonStyle(.borderless).foregroundStyle(.tertiary).help("Remove from the queue")
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder var status: some View {
        switch item.state {
        case .idle:
            if let p = m.problem(for: item) { Chip(text: "Can't start", tint: .red).help(p) } else { Chip(text: "Waiting") }
        case .running: Chip(text: "Transcoding…", tint: .orange)
        case .done: Chip(text: item.problem == nil ? "Done ✓" : "Done, a check failed ✗", tint: item.problem == nil ? .green : .red)
        case .failed: Chip(text: "Failed ✗", tint: .red)
        case .cancelled: Chip(text: "Cancelled")
        }
    }
}

/// Source → Destination of one file, its warnings, and (once done) the result
struct TranscodeCard: View {
    @Environment(Project.self) private var project
    let item: TranscodeItem
    @State private var showLog = false
    var m: TranscodeModel { TranscodeModel.shared }

    var body: some View {
        let plan = m.plan(for: item)
        VStack(alignment: .leading, spacing: DS.gap) {
            GroupBox {
                if let plan {
                    VStack(alignment: .leading, spacing: 8) {
                        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                            GridRow {
                                Text("").gridCellUnsizedAxes(.horizontal)
                                Text("Source").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                Text("")
                                Text("Destination").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            }
                            Divider().gridCellUnsizedAxes(.horizontal)
                            ForEach(plan.rows) { r in
                                GridRow {
                                    Text(r.id).font(.subheadline.weight(.medium))
                                    Text(r.from).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                    Image(systemName: "arrow.right").foregroundStyle(r.changed ? Color.orange : Color(nsColor: .tertiaryLabelColor)).imageScale(.small)
                                    Text(r.to).font(.subheadline.weight(r.changed ? .semibold : .regular)).foregroundStyle(r.changed ? Color.orange : Color.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        HStack(spacing: 14) {
                            Label("changes", systemImage: "circle.fill").foregroundStyle(.orange)
                            Label("preserved", systemImage: "circle.fill").foregroundStyle(.secondary)
                            Spacer()
                            Text("~\(Fmt.bytes(plan.estimatedBytes)) · about \(Fmt.hm(plan.estimatedSeconds)) on this Mac (rough)").foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                } else {
                    Text("Couldn't read this picture.").foregroundStyle(.secondary)
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.orange)
                    Text("\(item.source.url.lastPathComponent)  →  \(item.output.lastPathComponent)").lineLimit(1).truncationMode(.middle)
                }
            }
            .groupBoxStyle(.inset)

            if let plan {
                ForEach(Array(plan.warnings.enumerated()), id: \.offset) { _, w in NoticeRow(text: w, level: .warn) }
                if let p = m.problem(for: item), item.state == .idle { NoticeRow(text: p, level: .fail) }
            }
            result
        }
    }

    @ViewBuilder var result: some View {
        switch item.state {
        case .done(let url):
            let failed = item.problem != nil
            let warned = item.lines.contains { $0.hasPrefix("⚠") || $0.contains(" ⚠") }
            banner(color: failed ? .red : warned ? .orange : .green, icon: failed ? "xmark.octagon.fill" : warned ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
                   title: failed ? "File written, but a check failed" : warned ? "Done, with warnings — \(url?.lastPathComponent ?? "")" : "Done — \(url?.lastPathComponent ?? "")") {
                if let insp = item.inspection {
                    AcademySeal(level: insp.level, caption: "Verified on the transcoded file", compact: true).padding(.top, 6)
                    ZidooSeal(level: insp.zidooLevel, caption: "Read from the transcoded file · " + Zidoo.caveat, compact: true).padding(.top, 6)
                }
                HStack(spacing: 8) {
                    if let url {
                        Button("Inspect Final File") { project.inspector.load(url); project.mode = .inspect }
                        if item.qc != nil { Button("Render QC Report") { RenderQCModel.shared.open(url); project.mode = .qc } }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                    Button("Log") { showLog = true }
                }
                .padding(.top, 6)
            } detail: {
                ForEach(Array(item.lines.enumerated()), id: \.offset) { _, l in
                    Text("• " + l).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                if item.seconds > 0 { Text("Took \(Fmt.hm(item.seconds)).").font(.caption).foregroundStyle(.secondary) }
            }
            .sheet(isPresented: $showLog) { TranscodeLogSheet() }
        case .failed:
            banner(color: .red, icon: "xmark.octagon.fill", title: "That didn't work") {
                Button("Show Full Log") { showLog = true }.padding(.top, 6)
            } detail: {
                ForEach(Array(item.lines.enumerated()), id: \.offset) { _, l in Text(l).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            }
            .sheet(isPresented: $showLog) { TranscodeLogSheet() }
        case .cancelled:
            banner(color: .secondary, icon: "stop.circle.fill", title: "Cancelled — nothing was written to the destination.") { EmptyView() } detail: { EmptyView() }
        default:
            EmptyView()
        }
    }

    func banner<A: View, D: View>(color: Color, icon: String, title: String, @ViewBuilder actions: () -> A, @ViewBuilder detail: () -> D) -> some View {
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

struct TranscodeLogSheet: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(title: "Transcode log") { EmptyView() }
            TerminalBox(text: TranscodeModel.shared.log).padding(.horizontal, 20).padding(.top, 8)
            HStack {
                Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(TranscodeModel.shared.log, forType: .string) }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
            .padding(20)
        }
        .frame(width: 760, height: 480)
    }
}

// MARK: - Inspector column

struct TranscodeInspector: View {
    @Environment(Project.self) private var project

    var body: some View {
        @Bindable var m = TranscodeModel.shared
        let item = m.selected
        let plan = item.flatMap { m.plan(for: $0) }
        Form {
            Section {
                Picker(selection: $m.preset) {
                    ForEach(TranscodePreset.allCases) { Text($0.label).tag($0) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Preset")
                        Text(m.preset.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .disabled(m.busy)
                Picker("Codec", selection: $m.codec) { ForEach(TargetCodec.allCases) { Text($0.label).tag($0) } }
                    .pickerStyle(.segmented).disabled(m.busy)
                if m.codec == .prores {
                    Picker("Profile", selection: $m.proresProfile) { ForEach(ProResProfile.allCases) { Text($0.label).tag($0) } }
                        .disabled(m.busy)
                    Text("ProRes has no quality setting: the profile is the quality. Encoder: " + (Tools.proresEncoder == "prores_videotoolbox" ? "Apple VideoToolbox (the ProRes hardware of the M chips)." : "ffmpeg prores_ks (Apple's VideoToolbox encoder isn't in this ffmpeg)."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    if m.codec == .hevc { RateControlRows(hdr: m.hdr, showsQuality: false, disabled: m.busy) }
                    if m.codec == .h264 || m.hdr.rateMode == .quality {
                        Picker(selection: $m.quality) {
                            ForEach(HDRSettings.Quality.allCases) { Text($0.label).tag($0) }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Quality")
                                Text(m.quality.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .disabled(m.busy)
                    }
                    Picker("Speed", selection: $m.speed) { ForEach(HDRSettings.Speed.allCases) { Text($0.label).tag($0) } }
                        .disabled(m.busy)
                    Text(m.speed == .draft ? "Draft uses the hardware encoder (VideoToolbox): fast, bigger files, not for delivery."
                         : m.codec == .hevc && m.hdr.rateMode != .quality ? "x265 preset \(m.speed.preset), \(m.hdr.rate.text(m.quality))."
                         : "\(m.codec == .h264 ? "x264" : "x265") preset \(m.speed.preset), CRF \(Int(m.codec == .h264 ? m.quality.crf + 2 : m.quality.crf)), up to \(m.quality.maxMbps) Mbps.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if m.codec == .hevc {
                    Toggle("HDR10 metadata (+ Dolby Vision / HDR10+)", isOn: $m.hdrMetadata).disabled(m.busy)
                    if m.hdrMetadata { hdrRows }
                }
            } header: {
                Text("Destination")
            }

            Section {
                Picker("Resolution", selection: $m.resolution) { ForEach(OutputResolution.allCases) { Text($0.label).tag($0) } }
                    .disabled(m.busy)
                if let s = item?.source, s.isHDR {
                    Toggle(isOn: $m.toneMap) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Tone map HDR → SDR (BT.709)")
                            Text(Tools.canToneMap ? "zscale + tonemap (hable): for H.264 review copies and SDR deliveries from an HDR master." : "Not available: this ffmpeg has no zscale filter (libzimg). Install ffmpeg with zimg to tone map.")
                                .font(.caption).foregroundStyle(Tools.canToneMap ? Color.secondary : Color.orange).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .disabled(m.busy)
                }
                if let plan {
                    LabeledContent("Colour written") {
                        Text(plan.outputColor.text).multilineTextAlignment(.trailing).font(.callout)
                            .foregroundStyle(plan.color == .toneMapToSDR ? Color.orange : Color.primary)
                    }
                    Text(plan.colourNote ?? (plan.source.color.isTagged ? "Read from the source and repeated in the output." : "The source carries no colour tags.")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    // a master that isn't BT.2020 going to HDR: the app says so and recommends the conversion
                    if let from = plan.gamutConversion ?? (plan.gamutWarning != nil ? plan.source.color.primaries : nil) {
                        Toggle(isOn: Binding(get: { m.hdr.convertGamut }, set: { m.hdr.convertGamut = $0 })) { Text("Convert \(ColorLUT.label(from)) → BT.2020 (recommended)") }.disabled(m.busy)
                        Text(plan.gamutWarning ?? "HDR10 and Dolby Vision streams are BT.2020: the picture is converted in linear light; the colours don't change.")
                            .font(.caption).foregroundStyle(plan.gamutWarning == nil ? Color.secondary : Color.orange).fixedSize(horizontal: false, vertical: true)
                    }
                }
            } header: {
                Text("Picture")
            }

            Section {
                Picker("Audio", selection: $m.audio) { ForEach(AudioPlan.allCases) { Text($0.label).tag($0) } }
                    .disabled(m.busy)
                if let s = item?.source {
                    Text(s.audio.isEmpty ? "The source has no audio." : s.audio.map(\.text).joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Audio")
            }

            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Format")
                    Picker("Format", selection: $m.container) { ForEach(Container.allCases) { Text($0.label).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden().disabled(m.busy)
                }
                VStack(alignment: .leading, spacing: DS.rowGap) {
                    HStack {
                        Text("Save to")
                        Spacer()
                        Button("Choose Folder…") { m.chooseFolder() }.controlSize(.small).disabled(m.busy)
                    }
                    Label {
                        Text(m.outputFolder?.path ?? (item.map { $0.output.deletingLastPathComponent().path } ?? "Next to each source file"))
                            .font(.caption).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                    } icon: { Image(systemName: "folder").foregroundStyle(.secondary) }
                    if let item {
                        HStack(spacing: 6) {
                            Text("File name")
                            TextField("", text: Binding(get: { item.output.deletingPathExtension().lastPathComponent }, set: { new in
                                let clean = new.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
                                guard !clean.isEmpty, let i = m.items.firstIndex(where: { $0.id == item.id }) else { return }
                                m.items[i].output = item.output.deletingLastPathComponent().appendingPathComponent(clean).appendingPathExtension(m.container.rawValue)
                            }), prompt: Text("File name"))
                            .labelsHidden().textFieldStyle(.roundedBorder).disabled(m.busy)
                            Text(".\(m.container.rawValue)").foregroundStyle(.secondary).monospaced()
                        }
                        .font(.callout)
                    }
                }
                if let plan {
                    LabeledContent("Estimated size") { Text(Fmt.bytes(plan.estimatedBytes)).monospacedDigit() }
                    LabeledContent("Estimated time") { Text(Fmt.hm(plan.estimatedSeconds) + " (rough)").monospacedDigit() }
                    if let item, let free = Tools.freeSpace(at: item.output.deletingLastPathComponent()) {
                        let need = plan.estimatedBytes * (plan.needsInjection ? 3 : 1.3) + 1_000_000_000
                        LabeledContent("Free on that drive") { Text(Fmt.bytes(free)).monospacedDigit().foregroundStyle(free >= need ? Color.primary : Color.red) }
                    }
                }
            } header: {
                Text("Output")
            }

            Section {
                Toggle("Run Render QC on the result (every frame: green/black/repeated frames, dropouts…)", isOn: $m.runQC).disabled(m.busy)
                if Tools.canVMAF {
                    Toggle("VMAF against the source on three short stretches (how close the picture stays)", isOn: $m.runVMAF).disabled(m.busy || (plan?.color == .toneMapToSDR))
                } else {
                    Text("VMAF isn't available (this ffmpeg has no libvmaf).").font(.caption).foregroundStyle(.secondary)
                }
                Text("Always checked: frame count, duration, frame rate, colour tags, timecode and the audio track count against the source; then the Academy and Zidoo seals on the result.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Checks after the transcode")
            }

            if let plan, let item {
                Section {
                    let tracks = TranscodeInspector.predictedTracks(plan, output: item.output)
                    let checks = Academy.checks(fileName: item.output.lastPathComponent, tracks, black: nil, predicted: true)
                    if plan.outputColor.isHDR || plan.hdr != nil {
                        PlaybackRows(dolbyVision: plan.hdr?.dolbyVision != nil, hdr10plus: plan.hdr?.hdr10plus != nil,
                                     atmosDDP: plan.source.audio.contains { $0.codec == "eac3" }, trueHD: plan.source.audio.contains { $0.codec == "truehd" || $0.codec == "mlp" },
                                     mkv: plan.container == .mkv)
                        Text("Not for the Academy: it asks for SDR (ProRes 422 HQ / H.264).").font(.caption).foregroundStyle(.secondary)
                    } else {
                        AcademySeal(level: Academy.level(checks, tracks), caption: "Predicted from the settings · verified on the transcoded file", compact: true)
                        ForEach(Array(checks.filter { $0.level == .fail }.prefix(3).enumerated()), id: \.offset) { _, c in
                            Label { Text("\(c.title): \(c.detail)").font(.caption).fixedSize(horizontal: false, vertical: true) } icon: { Image(systemName: "xmark.octagon.fill").foregroundStyle(.red) }
                        }
                    }
                } header: {
                    Text(plan.outputColor.isHDR || plan.hdr != nil ? "Where it plays" : "Academy specs")
                }
            }

            if m.running {
                Section { RunMonitorView(progress: m.progress, stage: m.stage, folder: item?.output.deletingLastPathComponent()) } header: { Text("Progress") }
            }
            if let plan, let item {
                Section {
                    DisclosureGroup {
                        TerminalBox(text: "ffmpeg " + Transcode.arguments(plan, concat: nil, output: item.output, elementary: plan.needsInjection).map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ") +
                                    (plan.needsInjection ? "\n(then dovi_tool / hdr10plus_tool inject, and MP4Box with the audio copied bit for bit)" : ""), scrolls: false)
                    } label: { Text("ffmpeg command (for reference)").foregroundStyle(.secondary) }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Dolby Vision / HDR10+ / HDR10 rows for an HEVC with HDR metadata
    @ViewBuilder var hdrRows: some View {
        @Bindable var m = TranscodeModel.shared
        @Bindable var hdr = m.hdr
        let src = m.selected?.source
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(get: { hdr.dolbyVision && hdr.dvSource != nil }, set: { hdr.dolbyVision = $0 })) { Text("Dolby Vision 8.1") }
                .toggleStyle(.checkbox).disabled(hdr.dvSource == nil)
            Text(hdr.dvSource?.label ?? "No Dolby Vision metadata (XML from DaVinci Resolve)").font(.caption).lineLimit(1).truncationMode(.middle)
            if let d = hdr.dvChecking ? "Reading…" : hdr.dvProblem ?? hdr.dvSummary?.line, !d.isEmpty {
                Text(d).font(.caption2).foregroundStyle(hdr.dvProblem != nil ? Color.orange : Color.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Button(hdr.dvSource == nil ? "Choose Dolby Vision XML…" : "Change…") {
                hdr.chooseDolbyVision(width: src?.width ?? 0, height: src?.height ?? 0, frames: src?.frames ?? 0)
            }.controlSize(.small)
        }
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(get: { hdr.hdr10plus && hdr.hdr10plusJSON != nil }, set: { hdr.hdr10plus = $0 })) { Text("HDR10+") }
                .toggleStyle(.checkbox).disabled(hdr.hdr10plusJSON == nil)
            Text(hdr.hdr10plusJSON?.lastPathComponent ?? "No HDR10+ metadata").font(.caption).lineLimit(1).truncationMode(.middle)
            Button(hdr.hdr10plusJSON == nil ? "Choose HDR10+ JSON…" : "Change…") { hdr.chooseHDR10Plus(frames: src?.frames ?? 0) }.controlSize(.small)
        }
        VStack(alignment: .leading, spacing: 2) {
            Text("HDR10 (always)")
            Text("\(hdr.mastering.text) · MaxCLL \(hdr.maxCLL) · MaxFALL \(hdr.maxFALL)").font(.caption)
            Text(hdr.masteringSource).font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// MediaInfo-style description of the file that will be written (for the Academy prediction)
    static func predictedTracks(_ p: TranscodePlan, output: URL) -> [MITrack] {
        var general = MITrack(type: "General", f: ["@type": "General", "Format": p.container == .mkv ? "Matroska" : "MPEG-4", "Format_Profile": p.container == .mov ? "QuickTime" : "Base Media"])
        general.f["Duration"] = String(p.seconds)
        general.f["FileSize"] = String(p.estimatedBytes)
        let c = p.outputColor
        var v: [String: String] = ["@type": "Video", "Width": "\(p.outputWidth)", "Height": "\(p.outputHeight)", "FrameRate": String(format: "%.3f", p.fps.value),
                                   "BitDepth": "\(p.outputBits)", "ChromaSubsampling": p.outputChroma, "Duration": String(p.seconds), "ScanType": "Progressive",
                                   "colour_primaries": Transcode.miName(c.primaries), "transfer_characteristics": Transcode.miName(c.transfer), "matrix_coefficients": Transcode.miName(c.matrix),
                                   "BitRate": String(p.estimatedBytes * 8 / max(p.seconds, 0.001))]
        switch p.video {
        case .prores(let pr): v["Format"] = "ProRes"; v["Format_Profile"] = pr.mediaInfoProfile
        case .h264: v["Format"] = "AVC"; v["Format_Profile"] = "High"
        case .hevc: v["Format"] = "HEVC"; v["Format_Profile"] = "Main 10"
        }
        if let h = p.hdr { v["HDR_Format"] = h.formats }
        var out = [general, MITrack(type: "Video", f: v)]
        if p.effectiveAudio != .none {
            for a in p.source.audio {
                var f: [String: String] = ["@type": "Audio", "Channels": "\(a.channels)", "SamplingRate": "\(a.sampleRate)", "Duration": String(p.seconds)]
                switch p.effectiveAudio {
                case .copy:
                    f["Format"] = a.isPCM ? "PCM" : a.codec == "eac3" ? "E-AC-3" : a.codec == "ac3" ? "AC-3" : a.codec == "aac" ? "AAC" : a.codec == "truehd" ? "MLP FBA" : a.codec.uppercased()
                    if a.isPCM { f["BitDepth"] = "\(a.bits)" }
                case .pcm: f["Format"] = "PCM"; f["BitDepth"] = "24"
                case .aac: f["Format"] = "AAC"; f["Format_Profile"] = "LC"; f["BitRate"] = "\(p.aacKbps * 1000)"
                case .none: break
                }
                if a.isPCM || p.effectiveAudio == .pcm, p.container == .mov {
                    let n = a.channels
                    f["ChannelLayout"] = n == 6 ? "L R C LFE Ls Rs" : n == 2 ? "L R" : n == 8 ? "L R C LFE Ls Rs Lrs Rrs" : nil
                }
                out.append(MITrack(type: "Audio", f: f))
            }
        }
        return out
    }
}

// MARK: - The Mux tab's banner: the one exception, said out loud

/// Shown while the Mux tab's re-encoding is on: who turned it on, why, and source → destination. "Got it" shrinks it to one
/// line; it never goes away while the encode is on. "Don't re-encode" removes the Dolby Vision / HDR10+ and turns it off.
struct ReencodeBanner: View {
    @Environment(Project.self) private var project

    var body: some View {
        @Bindable var hdr = project.hdr
        let auto = hdr.autoEnabledBy != nil
        let plan = project.encodePlan
        let src = project.videoTrack?.source
        let imf = hdr.imf != nil || project.videoTrack?.url.pathExtension.lowercased() == "mxf"
        let from: String = src.map { s -> String in
            let rate: String = s.bitRate > 0 ? " · \(Fmt.bitrate(s.bitRate))" : ""
            return "\(s.codecName) · \(s.bitDepth)-bit · \(s.chroma)\(rate)"
        } ?? "no picture yet"
        let to: String = plan.map { p -> String in
            let rate: String = Fmt.bitrate(p.estimatedBytes * 8 / max(p.seconds, 0.001))
            return "\(p.outputCodecName) · \(p.outputBits)-bit · \(p.outputChroma) · ~\(rate)"
        } ?? "HEVC Main 10 · 10-bit · 4:2:0"
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(auto ? "Re-encoding turned on automatically" : "Re-encoding on").font(.headline)
                if hdr.bannerCollapsed {
                    Text("· \(from)  →  \(to)" + (plan.map { " · \($0.formats)" } ?? "")).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if hdr.bannerCollapsed { Button("Details") { hdr.bannerCollapsed = false }.controlSize(.small) }
            }
            if !hdr.bannerCollapsed {
                if auto, let u = hdr.autoEnabledBy {
                    (Text("You added ") + Text(u.lastPathComponent).fontWeight(.semibold) + Text(hdr.autoReason.map { " — \($0)" } ?? ""))
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("The picture is re-encoded to HEVC 10-bit so Dolby Vision, HDR10 and HDR10+ play on TVs and Apple devices.").font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(from).font(.callout.weight(.semibold))
                    Image(systemName: "arrow.right").foregroundStyle(.orange)
                    Text(to).font(.callout.weight(.semibold)).foregroundStyle(.orange)
                }
                .fixedSize(horizontal: false, vertical: true)
                let formats: String = plan?.formats ?? hdr.formatsText
                let colour: String = plan?.outputColor.text ?? "from the source"
                Text("\(formats) · colour \(colour). The audio stays bit for bit.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Got it") { hdr.bannerCollapsed = true }
                    Button("Don't re-encode") {
                        hdr.dolbyVision = false; hdr.dvSource = nil; hdr.dvSummary = nil; hdr.dvProblem = nil; hdr.dvXMLReady = nil
                        hdr.hdr10plus = false; hdr.hdr10plusJSON = nil; hdr.hdr10plusFrames = nil
                        hdr.encode = false; hdr.autoEnabledBy = nil; hdr.autoReason = nil; hdr.bannerCollapsed = false
                    }
                    .disabled(imf || project.busy)
                    .help(imf ? "An IMF / MXF master can't be copied into MOV, MP4 or MKV as it is: the encode is the only way out (or remove the picture)." : "Removes the Dolby Vision / HDR10+ metadata and copies the picture bit for bit")
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.radius, style: .continuous).fill(Color.orange.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: DS.radius, style: .continuous).strokeBorder(Color.orange.opacity(0.5), lineWidth: 1))
        .padding(.horizontal, DS.margin).padding(.top, DS.rowGap)
    }
}
