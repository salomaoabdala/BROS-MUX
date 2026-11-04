// BROS-MUX — the window (sidebar, toolbar, inspector), the Mux screen and its sheets.
// Pure interface: the engine (probing, trimming, MP4Box, verification, sync) lives in BrosMux.swift.

import SwiftUI
import AppKit

// MARK: - Window: sidebar · content · inspector

struct ContentView: View {
    @Environment(Project.self) private var project
    @State private var dropTargeted = false
    @State private var columns = NavigationSplitViewVisibility.all
    @State private var inspectorShown = true

    var body: some View {
        @Bindable var project = project
        NavigationSplitView(columnVisibility: $columns) {
            Sidebar(selection: $project.mode)
        } detail: {
            Group {
                switch project.mode {
                case .mux: MuxContent(targeted: dropTargeted)
                case .transcode: TranscodeView(targeted: dropTargeted)
                case .inspect: InspectorView(targeted: dropTargeted)
                case .atmos: AtmosView(targeted: dropTargeted)
                case .qc: RenderQCView(targeted: dropTargeted)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(project.mode.label)
            .navigationSubtitle(subtitle)
            .toolbar { ModeToolbar(project: project, inspectorShown: $inspectorShown) }
            .inspector(isPresented: inspectorBinding) {
                Group {
                    switch project.mode {
                    case .mux: MuxInspector()
                    case .transcode: TranscodeInspector()
                    case .atmos: AtmosInspector()
                    case .qc: RenderQCInspector()
                    case .inspect: EmptyView()
                    }
                }
                .inspectorColumnWidth(min: 340, ideal: DS.inspectorWidth, max: 600)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard project.mode != .mux || !project.busy else { return false }
            if project.mode == .qc { if let u = urls.first { RenderQCModel.shared.open(u) }; return true }
            project.add(urls); return true
        } isTargeted: { dropTargeted = $0 }
    }

    /// The File Checker has no inspector: everything it knows is on its page
    var inspectorBinding: Binding<Bool> {
        Binding(get: { inspectorShown && project.mode != .inspect }, set: { inspectorShown = $0 })
    }

    var subtitle: String {
        switch project.mode {
        case .mux: return project.outputURL?.lastPathComponent ?? "Abdala Brothers"
        case .transcode: return TranscodeModel.shared.selected?.output.lastPathComponent ?? "Abdala Brothers"
        case .inspect: return project.inspector.url?.lastPathComponent ?? "Abdala Brothers"
        case .atmos: return project.atmos.url?.lastPathComponent ?? "Abdala Brothers"
        case .qc: return RenderQCModel.shared.url?.lastPathComponent ?? "Abdala Brothers"
        }
    }
}

/// The three areas of the app
struct Sidebar: View {
    @Binding var selection: AppMode

    var body: some View {
        List(selection: Binding(get: { Optional(selection) }, set: { if let m = $0 { selection = m } })) {
            ForEach(AppMode.allCases) { m in
                Label(m.label, systemImage: m.symbol).tag(m)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 180, ideal: DS.sidebarWidth, max: 280)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 8) {
                ABMark(color: .secondary).frame(height: 14)
                Text("Abdala Brothers").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Toolbar of the current area: files on the leading side, the primary action and the inspector on the trailing side
struct ModeToolbar: ToolbarContent {
    let project: Project
    @Binding var inspectorShown: Bool

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { if project.mode == .qc { RenderQCModel.shared.pick() } else { project.openPanel() } } label: { Label(project.mode == .mux || project.mode == .transcode ? "Add Files" : "Open File", systemImage: "plus") }
                .help(project.mode == .mux || project.mode == .transcode ? "Add files (⌘O)" : "Open a file (⌘O)")
                .disabled((project.mode == .mux && project.busy) || (project.mode == .transcode && TranscodeModel.shared.busy))
            if project.mode == .mux {
                Button { project.clear() } label: { Label("Clear All", systemImage: "trash") }
                    .help("Start over (⌘N)")
                    .disabled(project.tracks.isEmpty || project.busy)
            }
            if project.mode == .transcode {
                Button { TranscodeModel.shared.clear() } label: { Label("Clear All", systemImage: "trash") }
                    .help("Empty the queue")
                    .disabled(TranscodeModel.shared.items.isEmpty || TranscodeModel.shared.busy)
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            switch project.mode {
            case .mux:
                if project.state == .running {
                    ProgressView().controlSize(.small)
                    Button("Cancel", role: .cancel) { project.cancel() }
                } else {
                    Button { project.run() } label: { Text(project.hdr.encode ? "Re-encode & Mux" : "Mux").padding(.horizontal, 6) }
                        .buttonStyle(.borderedProminent)
                        .tint(project.hdr.encode ? .orange : .accentColor)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!project.canRun)
                        .help(project.hdr.encode ? "Re-encode the picture (HEVC 10-bit) and mux (⌘↩)" : "Create the final file (⌘↩)")
                }
            case .transcode:
                let m = TranscodeModel.shared
                if m.running {
                    ProgressView().controlSize(.small)
                    Button("Cancel", role: .cancel) { m.cancel() }
                } else {
                    let n = m.pending.count
                    Button { m.start() } label: { Text(n > 1 ? "Transcode \(n) files" : "Transcode").padding(.horizontal, 6) }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!m.canRun)
                        .help("Write the new file(s) — the originals are never touched (⌘↩)")
                }
            case .inspect:
                Button { project.inspector.saveReport() } label: { Label("Save Report…", systemImage: "square.and.arrow.down") }
                    .help("Save the check report as a text file")
                    .disabled(project.inspector.url == nil)
                Button { if let u = project.inspector.url { NSWorkspace.shared.activateFileViewerSelecting([u]) } } label: { Label("Show in Finder", systemImage: "folder") }
                    .help("Show the file in the Finder")
                    .disabled(project.inspector.url == nil)
            case .atmos, .qc:
                EmptyView()
            }
            if project.mode != .inspect {
                Button { inspectorShown.toggle() } label: { Label("Inspector", systemImage: "sidebar.trailing") }
                    .help("Show or hide the inspector")
            }
        }
    }
}

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
                NoticeStack(hasResult: hasResult)
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

/// Missing tools, what went wrong with the files, and the result of the last mux. Nothing at all when there is nothing to say.
struct NoticeStack: View {
    @Environment(Project.self) private var project
    let hasResult: Bool

    var body: some View {
        if !Tools.missing.isEmpty || !project.notices.isEmpty || hasResult {
            VStack(spacing: DS.rowGap) {
                if !Tools.missing.isEmpty {
                    NoticeRow(text: "Missing tools (\(Tools.missing.joined(separator: ", "))). Run: brew install gpac media-info", level: .fail)
                }
                ForEach(Array(project.notices.enumerated()), id: \.offset) { _, n in NoticeRow(text: n, level: .warn) }
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
                        NoticeStack(hasResult: hasResult)
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

// MARK: - The Academy seal

/// A stylized award statuette (figure on a base)
struct StatuetteShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let w = r.width, h = r.height, x = r.minX, y = r.minY
        func pt(_ a: CGFloat, _ b: CGFloat) -> CGPoint { CGPoint(x: x + a * w, y: y + b * h) }
        p.addEllipse(in: CGRect(x: x + 0.39 * w, y: y, width: 0.22 * w, height: 0.11 * h))                 // head
        p.addRect(CGRect(x: x + 0.46 * w, y: y + 0.105 * h, width: 0.08 * w, height: 0.03 * h))              // neck
        p.move(to: pt(0.24, 0.15)); p.addLine(to: pt(0.76, 0.15))                                             // shoulders
        p.addQuadCurve(to: pt(0.66, 0.30), control: pt(0.80, 0.22))
        p.addLine(to: pt(0.62, 0.47)); p.addLine(to: pt(0.38, 0.47)); p.addLine(to: pt(0.34, 0.30))
        p.addQuadCurve(to: pt(0.24, 0.15), control: pt(0.20, 0.22)); p.closeSubpath()                      // torso with arms
        p.move(to: pt(0.38, 0.47)); p.addLine(to: pt(0.62, 0.47)); p.addLine(to: pt(0.57, 0.76))
        p.addLine(to: pt(0.43, 0.76)); p.closeSubpath()                                                       // legs
        p.addRoundedRect(in: CGRect(x: x + 0.30 * w, y: y + 0.76 * h, width: 0.40 * w, height: 0.06 * h), cornerSize: CGSize(width: 2, height: 2))
        p.addRoundedRect(in: CGRect(x: x + 0.18 * w, y: y + 0.82 * h, width: 0.64 * w, height: 0.18 * h), cornerSize: CGSize(width: 3, height: 3)) // base
        return p
    }
}

struct AcademySeal: View {
    let level: AcademyLevel?
    let caption: String
    var compact = false

    var body: some View {
        let color = level?.color ?? Color.secondary
        let d: CGFloat = compact ? 48 : 64
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(color.opacity(0.12))
                Circle().strokeBorder(color, lineWidth: 2)
                StatuetteShape()
                    .fill(Color(red: 0.85, green: 0.66, blue: 0.22))
                    .frame(width: d * 0.33, height: d * 0.7)
            }
            .frame(width: d, height: d)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(level?.title ?? "Academy specs: —")
                    .font(compact ? .headline : .title3.weight(.semibold)).foregroundStyle(color)
                Text(level?.explanation ?? "Add a video and audio to evaluate.")
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(caption).font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
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
                Text("Lines up the waveforms: slides each track's waveform against the reference's (cross-correlation) at 15 points spread evenly over the film and finds the exact offset, down to one sample. Trimming is lossless: sample exact for PCM, 32 ms Dolby frames for Atmos (the sound is never early), and a track that has to start later gets silence at the head (PCM) or a start delay in the container (Atmos, no frame touched). The reference itself is not muxed. The audio is lined up with audio; “Picture Check…” lines it up with the image (hard cuts vs sound hits), and the same check runs on the muxed file.")
                if !viewerTargets.isEmpty {
                    Text("* Tolerance: the sound may be at most 15 ms early or 45 ms late vs the picture (ATSC IS-191, the broadcast limit; viewers start to notice at about 45 ms early / 125 ms late, ITU-R BT.1359). Dolby audio is cut in whole 32 ms frames, so up to 32 ms late after the trim is normal and inside the tolerance.")
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
        let cut = track.codecKey == "eac3" && track.trimStart > 0 ? track.trimStart / 1536 * 1536 : track.trimStart
        let before = track.syncLag.map { ($0 + project.referenceOffset) * 1000 }
        let after = track.syncLag.map { ($0 + project.referenceOffset - Double(cut) / sr) * 1000 }
        VStack(alignment: .leading, spacing: 3) {
            Text(track.title).font(.subheadline.weight(.semibold)).lineLimit(1)
            HStack(spacing: 6) { light(before); Text(text(before, "as delivered")).font(.caption) }
            HStack(spacing: 6) { light(after); Text(text(after, "as muxed")).font(.caption) }
            if let a = after, !Self.ok(a) {
                Text(a < Self.early ? (track.isPCM || track.codecKey == "eac3" ? "Early: nudge it later in the Sync Viewer." : "Early: a compressed track can't be delayed without re-encoding.") : "Still late: nudge it in the Sync Viewer.")
                    .font(.caption).foregroundStyle(.red)
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
            .sheet(isPresented: $showQuality) { QualitySheet() }
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
