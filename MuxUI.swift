// BROS-MUX — the old Mux screen and its sheets (the Audio tab's owner restyles or retires them). The window moved to
// Shell.swift, the seals to Cryo.swift, the output/result pieces to DeliveryParts.swift.
// Pure interface: the engine (probing, trimming, MP4Box, verification, sync) lives in BrosMux.swift.

import SwiftUI
import AppKit

// MARK: - Mux screen

struct MuxContent: View {
    @Environment(Project.self) private var project
    let targeted: Bool

    var hasResult: Bool {
        switch project.state { case .done, .failed, .cancelled: return true; default: return false }
    }

    var body: some View {
        VStack(spacing: 0) {
            TabStrip.mux
            if project.hdr.encode { ReencodeBanner() }
            if project.tracks.isEmpty && project.loadingCount == 0 {
                NoticeStack(tab: .audio, hasResult: hasResult)
                    .padding(.horizontal, DS.margin).padding(.top, DS.gap)
                EmptyDropView(targeted: targeted, title: "Drop your files here",
                              subtitle: "ProRes or H.264 video · IMF packages (HDR, Dolby Vision) · WAV/PCM audio · Dolby Atmos E-AC-3 JOC or TrueHD · SRT/VTT subtitles")
            } else {
                TrackListView(hasResult: hasResult)
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
        .animation(.snappy(duration: 0.25), value: hasResult)
    }
}

/// Missing tools, what went wrong with the files (this tab's notices only), and the result of the last mux.
/// Nothing at all when there is nothing to say.
struct NoticeStack: View {
    @Environment(Project.self) private var project
    let tab: AppMode
    let hasResult: Bool

    var body: some View {
        let notices = project.notices(for: tab)
        if !Tools.missing.isEmpty || !notices.isEmpty || hasResult {
            VStack(spacing: DS.rowGap) {
                if !Tools.missing.isEmpty {
                    NoticeRow(text: "Missing tools (\(Tools.missing.joined(separator: ", "))). Run: brew install gpac media-info", level: .fail)
                }
                ForEach(notices) { n in NoticeRow(text: n.text, level: n.level) }
                ResultBanner()
            }
        }
    }
}

/// Empty state: symbol, one line, one action — and the drop target highlight
struct EmptyDropView: View {
    @Environment(Project.self) private var project
    let targeted: Bool
    let title: String
    let subtitle: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "square.and.arrow.down.on.square")
        } description: {
            Text(subtitle).frame(maxWidth: 520)
        } actions: {
            Button("Choose Files…") { project.openPanel() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if targeted {
                RoundedRectangle(cornerRadius: DS.radius, style: .continuous)
                    .fill(Color.accentColor.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: DS.radius, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 2))
                    .padding(DS.margin)
            }
        }
    }
}

struct TrackListView: View {
    @Environment(Project.self) private var project
    let hasResult: Bool

    var body: some View {
        @Bindable var project = project
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Tracks in the final file").font(.headline)
                Text("\(project.includedCount) of \(project.tracks.count) selected · drag to reorder").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                if project.encodePlan != nil {
                    Label {
                        Text("Picture re-encoded for playback · audio and subtitles 1:1 (bit-exact)")
                    } icon: { Image(systemName: "sun.max.fill").foregroundStyle(.orange) }
                    .font(.subheadline).foregroundStyle(.secondary)
                } else {
                    Label {
                        Text("No re-encoding — 1:1 copy of the original quality")
                    } icon: { Image(systemName: "checkmark.seal.fill").foregroundStyle(.green) }
                    .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, DS.margin).padding(.vertical, 10)
            // One scrolling area for everything: the notices used to sit above the list and, with many files, left it
            // no height at all. The list itself is never disabled — a disabled list does not scroll on the Mac — so
            // while files are read or the mux runs only the rows' controls are off (see TrackRow).
            GeometryReader { geo in
                ScrollViewReader { proxy in
                    List {
                        NoticeStack(tab: .audio, hasResult: hasResult)
                            .id("notices")
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 4, leading: DS.margin, bottom: DS.rowGap, trailing: DS.margin))
                        if !project.busy && project.groupCandidates.count >= 2 {
                            GroupOffer()
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 0, leading: DS.margin, bottom: DS.rowGap, trailing: DS.margin))
                        }
                        ForEach($project.tracks) { $t in
                            TrackRow(track: $t, compact: geo.size.width < 990, narrow: geo.size.width < 640)
                        }
                        .onMove { project.tracks.move(fromOffsets: $0, toOffset: $1) }
                        .moveDisabled(project.busy)
                        if project.loadingCount > 0 {
                            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading files…").foregroundStyle(.secondary) }
                                .padding(.vertical, 6)
                        }
                    }
                    .listStyle(.inset)
                    .onChange(of: hasResult) { _, now in
                        if now { withAnimation { proxy.scrollTo("notices", anchor: .top) } }
                    }
                }
            }
        }
    }
}

/// Mono PCM tracks still on their own: offer to make them one multichannel track (MonoGroup.swift)
struct GroupOffer: View {
    @Environment(Project.self) private var project

    var body: some View {
        let c = project.groupCandidates
        let problem = Track.groupProblem(c)
        let color: Color = problem == nil ? .accentColor : .orange
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "rectangle.split.3x1").foregroundStyle(color).padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(c.count) mono PCM tracks on their own").font(.callout.weight(.semibold))
                Text(problem.map { "Not grouped: \($0)." } ?? "Together they are one \(Probe.channelText(c.count, nil)) sound: one sync offset for all of them, one \(Probe.channelText(c.count, nil)) PCM track in the final file.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if problem == nil {
                Button("Group into one track") { project.makeGroup(c.map(\.id)) }
                    .help("Treat these mono tracks as one multichannel sound")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.radius, style: .continuous).fill(color.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: DS.radius, style: .continuous).strokeBorder(color.opacity(0.22), lineWidth: 1))
    }
}

struct TrackRow: View {
    @Environment(Project.self) private var project
    @Binding var track: Track
    @State private var showChannels = false
    /// Narrow list: the fields go under the description. Decided once per list width, not measured per row.
    var compact = false
    /// Narrowest list (inspector open at the window's minimum width): the fields in two rows
    var narrow = false

    var isReference: Bool { project.syncReferenceID == track.id }

    var body: some View {
        Group {
            if compact {
                HStack(alignment: .top, spacing: 12) {
                    leading
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(alignment: .top) { info; Spacer(minLength: 8); remove }
                        fields
                    }
                }
            } else {
                HStack(alignment: .top, spacing: 12) {
                    leading
                    info.frame(minWidth: 280, alignment: .leading)
                    Spacer(minLength: 24)
                    fields.fixedSize()
                    remove
                }
            }
        }
        .disabled(project.busy)
        .padding(.vertical, 8)
        .opacity(track.include ? 1 : 0.55)
        .listRowSeparator(.visible)
    }

    var leading: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: $track.include).toggleStyle(.checkbox).labelsHidden()
                .help("Include this track in the final file")
            IconTile(symbol: isReference ? "metronome" : track.kind.icon, color: isReference ? .accentColor : track.kind.color)
                .padding(.top, 1)
        }
    }

    var info: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(track.codecName).font(.headline)
                ForEach(Array(track.badges.enumerated()), id: \.offset) { _, b in Chip(text: b) }
                if isReference { Chip(text: "Sync reference", tint: .accentColor) }
                if track.kind == .video {
                    Chip(text: project.hdr.encode ? "RE-ENCODE → HEVC 10-bit" : "COPY · bit-exact", tint: project.hdr.encode ? .orange : nil)
                        .help(project.hdr.encode ? "The picture is re-encoded (the Mux tab's one exception, for Dolby Vision / HDR10+)" : "The picture is copied bit for bit")
                }
            }
            if !track.details.isEmpty { Text(track.details).font(.subheadline).foregroundStyle(.secondary) }
            Text("\(track.url.lastPathComponent) · \(track.imfSegments.isEmpty ? track.sourceLabel : "IMF picture")")
                .font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            if track.isGroup {
                Text(track.groupMembersText).font(.caption).foregroundStyle(.tertiary).lineLimit(2).truncationMode(.middle)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Label { Text(track.groupChannelsText).fixedSize(horizontal: false, vertical: true) } icon: {
                        Image(systemName: track.listening ? "ear" : "rectangle.split.3x1")
                    }
                    .font(.caption).foregroundStyle(track.listening || track.sourceOrder?.isComplete == true ? Color.secondary : Color.orange)
                    Button("Channels…") { showChannels = true }.controlSize(.small)
                        .help("Which mono \(track.fromVideoFile ? "stream" : "file") is which channel, the order they are written in, or ungroup them")
                }
                .sheet(isPresented: $showChannels) { ChannelOrderSheet(track: $track, onUngroup: { project.ungroup(track.id) }) }
            }
            if let first = track.imfSegments.first {
                let frames = track.imfSegments.reduce(0) { $0 + $1.frames }
                Label("The CPL uses " + (track.imfSegments.count == 1 && first.repeatCount == 1
                      ? "frames \(Fmt.int(first.entryPoint))…\(Fmt.int(first.entryPoint + first.duration - 1)) of this MXF"
                      : "\(track.imfSegments.count) stretches of MXF") + " · \(Fmt.int(frames)) frames · \(Fmt.duration(Double(frames) / max(first.editRate.value, 1)))",
                      systemImage: "film.stack").font(.caption).foregroundStyle(.secondary)
            }
            if track.include, let p = project.planText(for: track) {
                Label { Text(p) } icon: { Image(systemName: "scissors").foregroundStyle(Color.accentColor) }
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let n = track.syncNote, track.include {
                Label(n, systemImage: n.hasPrefix("Not") ? "exclamationmark.triangle.fill" : "metronome")
                    .font(.caption).foregroundStyle(n.hasPrefix("Not") ? .orange : .secondary)
            }
            ForEach(Array((track.warnings + project.containerWarnings(track)).enumerated()), id: \.offset) { _, w in
                Label(w, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
            }
        }
    }

    var fields: some View {
        Group {
            if narrow {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .bottom, spacing: 12) { nameField; if track.kind != .timecode { languageField } }
                    if track.kind != .timecode { HStack(alignment: .bottom, spacing: 12) { trimField; defaultField } }
                }
            } else {
                HStack(alignment: .bottom, spacing: 12) {
                    nameField
                    if track.kind == .timecode {
                        Color.clear.frame(width: 150 + 96 + 64 + 24, height: 1)
                    } else {
                        languageField; trimField; defaultField
                    }
                }
            }
        }
        .controlSize(.small)
        .disabled(!track.include)
    }

    var nameField: some View {
        field("Track name", width: 170) {
            TextField("Name", text: $track.title).textFieldStyle(.roundedBorder)
        }
    }

    var languageField: some View {
        field("Language", width: 150) {
            Picker("", selection: $track.language) {
                ForEach(languageOptions, id: \.0) { Text($0.1).tag($0.0) }
            }
            .labelsHidden()
        }
    }

    var trimField: some View {
        field("Head trim (ms)", width: 96) {
            if track.canTrim {
                TextField("0", value: $track.trimStartMs, format: .number.precision(.fractionLength(0...3)))
                    .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                    .help("How much to cut from the start to sync (negative makes it start later: silence written at the head for PCM, a start delay in the container for Dolby E-AC-3). Filled in by “Align”.")
            } else {
                Text("—").foregroundStyle(.tertiary).frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    var defaultField: some View {
        field("Default", width: 64) {
            Toggle("On", isOn: $track.enabled).toggleStyle(.checkbox)
                .help("Track enabled by default in players")
        }
    }

    var remove: some View {
        Button { project.remove(track.id) } label: { Image(systemName: "xmark.circle.fill").imageScale(.large) }
            .buttonStyle(.borderless).foregroundStyle(.tertiary).help("Remove from the list")
    }

    func field<C: View>(_ label: String, width: CGFloat, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
            content().frame(width: width, height: 22, alignment: .leading)
        }
    }

    var languageOptions: [(String, String)] {
        var l = Languages.list
        if !l.contains(where: { $0.0 == track.language }) { l.insert((track.language, track.language.uppercased()), at: 0) }
        return l
    }
}

// MARK: - Inspector of the Mux screen

struct MuxInspector: View {
    @Environment(Project.self) private var project

    var body: some View {
        Form {
            if project.audioTracks.count >= 2 { SyncPanel() }
            if project.hdrRelevant { HDRPanel() }
            OutputSection()
            if !project.included.isEmpty {
                AcademySection()
                SummarySections()
            }
        }
        .formStyle(.grouped)
    }
}

/// Sync: pick the reference track (e.g. the video's stereo) and align the others to it
struct SyncPanel: View {
    @Environment(Project.self) private var project
    @State private var viewer: SyncViewerModel?
    @State private var picture: PictureSyncModel?

    var viewerTargets: [Track] { project.tracks.filter { $0.kind == .audio && $0.include && $0.id != project.syncReferenceID } }
    func openViewer() { if let t = viewerTargets.first { viewer = SyncViewerModel(project: project, target: t) } }

    var lateText: String {
        let f = project.referenceLateFrames
        if f == 0 { return "in sync with its picture" }
        return "\(Int(abs(f))) frame\(abs(f) == 1 ? "" : "s") \(f > 0 ? "late" : "early") vs its picture"
    }

    var body: some View {
        @Bindable var project = project
        Section {
            Picker("Reference", selection: $project.syncReferenceID) {
                Text("None").tag(UUID?.none)
                ForEach(project.audioTracks) { t in
                    Text("\(t.title) · \(t.url.lastPathComponent) · \(t.sourceLabel)").tag(UUID?.some(t.id))
                }
            }
            .disabled(project.busy)
            .help("Follow the reference audio — usually the video's own stereo. The other tracks are lined up with it; the reference itself is not muxed.")

            Stepper(value: $project.referenceLateFrames, in: -12...12, step: 1) {
                LabeledContent("The reference is") {
                    Text(lateText)
                        .fontWeight(project.referenceLateFrames == 0 ? .regular : .semibold)
                        .foregroundStyle(project.referenceLateFrames == 0 ? Color.primary : Color.orange)
                        .multilineTextAlignment(.trailing)
                }
            }
            .disabled(project.busy)
            .help("If the video's own audio isn't in sync with its picture, enter by how many frames it's late — the alignment then follows the picture. “Picture Check…” measures this for you (hard cuts in the image vs sound hits) and can fill it in.")
            if project.referenceLateFrames != 0 {
                Text(String(format: "The tracks follow the picture: %.1f ms is added to every trim.", project.referenceOffset * 1000))
                    .font(.caption).foregroundStyle(.secondary)
            }

            Toggle("Audio ends with the video", isOn: $project.matchVideoEnd)
                .help("Trims the audio tails so they end on the last video frame")
                .disabled(project.busy)

            if project.aligning {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: project.alignProgress)
                    HStack {
                        Text(project.alignStage).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Button("Stop") { project.cancelAlign() }.controlSize(.small)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Button { project.autoAlign() } label: { Label("Align Tracks to Reference", systemImage: "waveform.badge.magnifyingglass") }
                        .buttonStyle(.borderedProminent)
                        .disabled(project.reference == nil || project.busy)
                        .help("Finds each track's exact offset against the reference by cross-correlation and fills in the head trims")
                    HStack(spacing: 8) {
                    Button("Sync Viewer…") { openViewer() }
                        .help("See both waveforms before/after alignment, the strongest hits of the mix and the offset along the film")
                        .disabled(project.reference == nil || project.busy || viewerTargets.isEmpty)
                    Button("Picture Check…") { picture = PictureSyncModel(project: project, target: viewerTargets.first) }
                        .help("Checks the sound against the picture itself: hard cuts in the image vs sound hits, with the frames around a cut, the waveform under them and a looping preview — tells how late the reference is vs its picture")
                        .disabled(project.videoTrack == nil || project.busy || (project.reference == nil && viewerTargets.isEmpty))
                    }
                }
                .sheet(item: $viewer) { SyncViewerSheet(model: $0) }
                .sheet(item: $picture) { PictureSyncSheet(model: $0) }
            }

            ForEach(Array(project.alignLines.enumerated()), id: \.offset) { _, l in
                let bad = l.contains("not aligned") || l.hasPrefix("Check at least")
                Label {
                    Text(l).font(.caption).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: bad ? "exclamationmark.triangle.fill" : "checkmark.circle.fill").foregroundStyle(bad ? Color.orange : Color.green)
                }
            }
            ForEach(viewerTargets) { t in SyncLights(track: t) }
        } header: {
            Text("Sync")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                Text("Lines up the waveforms: slides each track's waveform against the reference's (cross-correlation) at 15 points spread evenly over the film and finds the exact offset, down to one sample. Trimming is lossless and exact: sample exact for PCM; Atmos (E-AC-3) is cut in whole 32 ms Dolby frames and the rest of the trim is a start delay in the container, so no frame is touched; a track that has to start later gets silence at the head (PCM) or a start delay in the container (Atmos). The reference itself is not muxed. The audio is lined up with audio; “Picture Check…” lines it up with the image (hard cuts vs sound hits), and the same check runs on the muxed file.")
                if !viewerTargets.isEmpty {
                    Text("* Tolerance: the sound may be at most 15 ms early or 45 ms late vs the picture (ATSC IS-191, the broadcast limit; viewers start to notice at about 45 ms early / 125 ms late, ITU-R BT.1359).")
                }
            }
        }
    }
}

/// One track's sync as a traffic light: as delivered → as it will be muxed, against the tolerance (*)
struct SyncLights: View {
    @Environment(Project.self) private var project
    let track: Track
    static let early = -15.0, late = 45.0
    static func ok(_ ms: Double) -> Bool { ms >= early && ms <= late }

    var body: some View {
        let sr = track.sampleRate > 0 ? track.sampleRate : 48000
        let applied = project.plan(for: track).map { Double($0.cut - $0.pad) } ?? Double(track.trimStart)   // samples, as it will be muxed
        let before = track.syncLag.map { ($0 + project.referenceOffset) * 1000 }
        let after = track.syncLag.map { ($0 + project.referenceOffset - applied / sr) * 1000 }
        let meter = project.alignmentMeter(for: track)
        VStack(alignment: .leading, spacing: 3) {
            Text(track.title).font(.subheadline.weight(.semibold)).lineLimit(1)
            HStack(spacing: 6) { light(before); Text(text(before, "as delivered")).font(.caption) }
            HStack(spacing: 6) { light(after); Text(text(after, "as muxed")).font(.caption) }
            if let a = after, !Self.ok(a) {
                Text(a < Self.early ? (track.isPCM || track.codecKey == "eac3" ? "Early: nudge it later in the Sync Viewer." : "Early: a compressed track can't be delayed without re-encoding.") : "Still late: nudge it in the Sync Viewer.")
                    .font(.caption).foregroundStyle(.red)
            }
            if let m = meter {   // the alignment meter: how much of the film this trim aligns, and where it drifts (updates as the trim is typed)
                HStack(spacing: 6) { light(m.drifts.first.map { $0.residual * 1000 } ?? 0); Text("Alignment meter: " + m.summary).font(.caption) }   // red on the first stretch out of sync (signed: an early one is red too)
                    .help(m.lines.joined(separator: "\n") + "\n" + m.note)
            }
        }
    }
    func light(_ ms: Double?) -> some View {
        Circle().fill(ms == nil ? Color.secondary.opacity(0.4) : Self.ok(ms!) ? Color.green : Color.red).frame(width: 9, height: 9)
            .accessibilityHidden(true)
    }
    func text(_ ms: Double?, _ what: String) -> String {
        guard let ms else { return "\(what): not measured" }
        if abs(ms) < 0.05 { return "\(what): exact sync" }
        return String(format: "%@: %.1f ms %@ (%.2f fr) %@", what, abs(ms), ms > 0 ? "late" : "early", abs(ms) / 1000 * max(1, project.videoFPS.value), Self.ok(ms) ? "✓ inside the tolerance*" : "✗ outside the tolerance*")
    }
}

// MARK: - Sheets

struct QualitySheet: View {
    @Environment(Project.self) private var project
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var project = project
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "checkmark.seal.fill").font(.largeTitle).foregroundStyle(.green).symbolRenderingMode(.hierarchical)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Quality: original, no re-encoding").font(.title2.weight(.semibold))
                    Text("BROS-MUX never renders — it copies each track's data as is (passthrough). That's why there's no bitrate or quality setting like in Resolve: what goes in is exactly what comes out. Sync trims only remove whole samples/frames from the head and tail.")
                        .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 6)
            Form {
                Section {
                    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                        GridRow {
                            ForEach(["Track", "Codec", "Bitrate", "Sample rate / size", "Bits", "Channels", "Process"], id: \.self) {
                                Text($0).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            }
                        }
                        Divider().gridCellUnsizedAxes(.horizontal)
                        ForEach(project.included) { t in
                            GridRow {
                                Label(t.title, systemImage: t.kind.icon).lineLimit(1)
                                Text(t.codecName).lineLimit(1)
                                Text(t.bitRate > 0 ? Fmt.bitrate(t.bitRate) : "—").monospacedDigit()
                                Text(t.kind == .audio ? Fmt.hz(t.sampleRate) : (t.details.components(separatedBy: " · ").first ?? "—"))
                                Text(t.bitDepth > 0 ? "\(t.bitDepth)-bit" : "—")
                                Text(t.channels > 0 ? "\(t.channels)" : "—")
                                if project.planText(for: t) != nil {
                                    Label { Text(t.channelPermutation != nil ? "1:1 copy + trim + reorder" : "1:1 copy + trim") } icon: { Image(systemName: "scissors").foregroundStyle(Color.accentColor) }
                                } else if t.channelPermutation != nil {
                                    Label { Text("1:1 copy + reorder") } icon: { Image(systemName: "arrow.left.arrow.right").foregroundStyle(Color.accentColor) }
                                } else {
                                    Label { Text("1:1 copy") } icon: { Image(systemName: "equal.circle.fill").foregroundStyle(.green) }
                                }
                            }
                        }
                    }
                } header: {
                    Text("Tracks")
                }
                Section {
                    Toggle(isOn: $project.writeChannelMap) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Write channel labels on PCM tracks (L R C LFE Ls Rs) — required by the Academy")
                            Text("Only writes the channel labels into the file header; the audio itself is untouched.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    ForEach($project.tracks) { $t in
                        if t.include && t.isPCM {
                            Picker(t.title, selection: $t.channelMap) {
                                ForEach(ChannelMap.allCases) { Text($0.label).tag($0) }
                            }
                            .disabled(!project.writeChannelMap)
                        }
                        if t.include && t.canReorder { ChannelOrderRow(track: $t) }
                    }
                    Toggle(isOn: $project.fixColorTag) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Tag the video as BT.709 (fixes Resolve's “Rec.709-A / Gamma 2.4” tag)")
                            Text("Changes only the container's color tag — the pixels stay identical. The Academy requires ITU-R BT.709 transfer (no exceptions); QuickTime Player on a Mac may show the image slightly brighter.")
                                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Toggle("Only the first audio track is enabled by default", isOn: $project.disableExtraAudio)
                    Toggle("Verify audio bit for bit after muxing (recommended)", isOn: $project.verifyAudio)
                    Toggle("Verify video bit for bit (slower: hashes the whole video again)", isOn: $project.verifyVideo)
                    Toggle("Check the sound against the picture after muxing (hard cuts vs sound hits, about a minute)", isOn: $project.pictureCheck)
                    Picker(selection: $project.interleaveMs) {
                        Text("250 ms").tag(250); Text("500 ms (default)").tag(500); Text("1000 ms").tag(1000)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Audio/video interleave")
                            Text("How blocks are laid out in the file — doesn't affect quality.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Advanced")
                }
                Section {
                    LabeledContent("Estimated size") { Text("\(Fmt.bytes(project.estimatedSize)) · needs ~\(Fmt.bytes(project.estimatedSize * 2)) free while muxing") }
                    if let free = project.freeSpace {
                        LabeledContent("Free on the destination") {
                            Text(Fmt.bytes(free)).foregroundStyle(free < project.estimatedSize * 2 ? Color.red : Color.primary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            SheetButtons {
                Button("OK") { dismiss() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .frame(width: 900, height: 760)
    }
}
