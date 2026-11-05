// BROS-MUX Beta 2.0.0 — the window (A · CRYO): the slab, the sidebar (WORKFLOW, a divider, CHECK A FILE, the engine
// LEDs and the AB mark), the toolbar (title, files, NEXT), the content of the tab and its inspector.
// Each tab draws its own strip (CryoStrip); the shell never says what a tab does to the file.

import SwiftUI
import AppKit

// MARK: - Window: sidebar · content · inspector

struct ContentView: View {
    @Environment(Project.self) private var project
    @State private var dropTargeted = false
    @State private var columns = NavigationSplitViewVisibility.all
    @State private var inspectorShown = true
    @State private var windowSize = CGSize(width: 1480, height: 940)

    var body: some View {
        @Bindable var project = project
        NavigationSplitView(columnVisibility: $columns) {
            ShellSidebar(selection: $project.mode)
        } detail: {
            // The tab gets exactly the column's size: a tab whose minimum height is huge (text measured at zero width)
            // can't stretch the window's columns past the window and push the sidebar out of sight
            GeometryReader { g in
                Group {
                    switch project.mode {
                    case .video: VideoTab(targeted: dropTargeted)
                    case .audio: AudioTab(targeted: dropTargeted)
                    case .subtitles: SubtitlesTab(targeted: dropTargeted)
                    case .delivery: DeliveryTab(targeted: dropTargeted)
                    case .inspect: InspectorView(targeted: dropTargeted)
                    case .atmos: AtmosView(targeted: dropTargeted)
                    case .qc: RenderQCView(targeted: dropTargeted)
                    }
                }
                .frame(width: g.size.width, height: g.size.height)
            }
            .navigationTitle(project.mode.label)                 // the window's name (Window menu); the toolbar draws its own title
            .navigationSubtitle(ShellToolbar.subtitle(project))
            .modifier(ShellChrome(project: project, inspectorShown: $inspectorShown))
            .inspector(isPresented: inspectorBinding) {
                ShellInspectorColumn(windowSize: windowSize) {
                    switch project.mode {
                    case .video: VideoInspector()
                    case .audio: AudioInspector()
                    case .subtitles: SubtitlesInspector()
                    case .delivery: DeliveryInspector()
                    case .atmos: AtmosInspector()
                    case .qc: RenderQCInspector()
                    case .inspect: EmptyView()
                    }
                }
                .inspectorColumnWidth(min: 340, ideal: DS.inspectorWidth, max: 600)
            }
        }
        .background(CryoWindowBackground(progress: DeliveryQueue.shared.overall))
        .background {
            GeometryReader { g in
                Color.clear
                    .onAppear { windowSize = g.size }
                    .onChange(of: g.size) { _, s in windowSize = s }
            }
            .ignoresSafeArea()
        }
        .modifier(ShellWindowSlab())
        .background(ShellWindowAccessor(mode: project.mode))
        .frame(minWidth: 1180, minHeight: 720)
        .preferredColorScheme(.dark)
        .tint(Cryo.ice)
        .dropDestination(for: URL.self) { urls, _ in
            guard !project.mode.isWorkflow || !project.busy else { return false }
            if project.mode == .qc { if let u = urls.first { RenderQCModel.shared.open(u) }; return true }   // Render QC opens one file itself
            project.route(urls); return true                                                               // the routing rule (File Checker / Atmos keep their own open there)
        } isTargeted: { dropTargeted = $0 }
    }

    /// The File Checker has no inspector: everything it knows is on its page
    var inspectorBinding: Binding<Bool> {
        Binding(get: { inspectorShown && project.mode != .inspect }, set: { inspectorShown = $0 })
    }
}

/// The toolbar (with its system glass hidden on macOS 26, so the Cryo pieces draw themselves) and no system title where
/// the custom one can replace it
private struct ShellChrome: ViewModifier {
    let project: Project
    @Binding var inspectorShown: Bool

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .toolbar { ShellSpacedToolbar(project: project, inspectorShown: $inspectorShown).sharedBackgroundVisibility(.hidden) }
                .toolbar(removing: .title)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else if #available(macOS 15, *) {
            content
                .toolbar { ShellToolbar(project: project, inspectorShown: $inspectorShown) }
                .toolbar(removing: .title)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        } else {
            content.toolbar { ShellToolbar(project: project, inspectorShown: $inspectorShown) }
        }
    }
}

/// The opaque slab is the window's own background where the system allows it (macOS 15+), so the sidebar and inspector
/// glass sample the slab and nothing else
private struct ShellWindowSlab: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 15, *) { content.containerBackground(Cryo.s0, for: .window) } else { content }
    }
}

/// The title bar shows the slab (no system material band and no separator line over the content), and the window's own
/// colour is the slab's where SwiftUI can't set it (macOS 14)
private struct ShellWindowAccessor: NSViewRepresentable {
    let mode: AppMode                                    // applied again on every tab switch, should the toolbar reset it
    func makeNSView(context: Context) -> NSView { ShellWindowProbe() }
    func updateNSView(_ nsView: NSView, context: Context) { (nsView as? ShellWindowProbe)?.apply() }
}

private final class ShellWindowProbe: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply()
    }
    func apply() {
        guard let w = window else { return }
        if !w.titlebarAppearsTransparent { w.titlebarAppearsTransparent = true }
        if w.titlebarSeparatorStyle != .none { w.titlebarSeparatorStyle = .none }
        w.backgroundColor = NSColor(srgbRed: 0x05 / 255.0, green: 0x08 / 255.0, blue: 0x0C / 255.0, alpha: 1)   // Cryo.s0
    }
}

enum ShellOS {
    /// The system title can be removed from the toolbar (macOS 15+); before that the shell keeps the system title
    static let customTitle = ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0))
}

// MARK: - Sidebar

/// The four steps of the workflow, then (below a divider) the tools that check a file, the engines and the mark
struct ShellSidebar: View {
    @Binding var selection: AppMode
    @Environment(Project.self) private var project
    init(selection: Binding<AppMode>) { _selection = selection }

    var body: some View {
        GeometryReader { g in
            CryoPanel(cornerRadius: 18) {
                VStack(alignment: .leading, spacing: 0) {
                    ShellSectionRule(title: "WORKFLOW")
                        .padding(.horizontal, 6).padding(.bottom, 8)
                    VStack(spacing: 4) {
                        ForEach(AppMode.workflow) { m in
                            ShellWorkflowRow(mode: m, on: selection == m, line: line(m), pending: project.pendingCount(for: m),
                                             metadata: m == .video ? metadataChip : nil) { pick(m) }
                        }
                    }
                    ShellToolsCaption()
                        .padding(.horizontal, 6).padding(.top, 16).padding(.bottom, 8)
                    VStack(spacing: 2) {
                        ForEach(AppMode.tools) { m in
                            ShellToolRow(mode: m, on: selection == m) { pick(m) }
                        }
                    }
                    Spacer(minLength: 12)
                    ShellEngineLEDs()
                    ShellBrand()
                        .padding(.top, 12).padding(.horizontal, 6)
                }
                .padding(.horizontal, 10)
                .padding(.top, max(g.safeAreaInsets.top, 12) + 4)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .ignoresSafeArea(edges: .top)
        }
        .navigationSplitViewColumnWidth(min: 236, ideal: 260, max: 320)
    }

    /// No movement on a tab switch
    func pick(_ m: AppMode) {
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { selection = m }
    }

    func line(_ m: AppMode) -> String {
        switch m {
        case .video: return project.video.sidebarLine(project: project)
        case .audio: return AudioTab.sidebarLine(project: project)
        case .subtitles: return SubtitlesTab.sidebarLine(project: project)
        case .delivery: return DeliveryTab.sidebarLine(project: project)
        case .inspect, .qc, .atmos: return ""
        }
    }

    /// The DV / HDR10+ chip on the Video row: clicking it reopens the analysis
    var metadataChip: ShellMetadataChip.Kind? {
        if project.hdr.dvSource != nil { return .dolbyVision }
        if project.hdr.hdr10plusJSON != nil { return .hdr10Plus }
        return nil
    }
}

/// A caps section title with a cyan rule after it
private struct ShellSectionRule: View {
    let title: String
    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(CryoFont.label(10)).tracking(2.2).foregroundStyle(Cryo.ink3)
                .accessibilityAddTraits(.isHeader)
            Rectangle().fill(LinearGradient(colors: [Cryo.ice.opacity(0.28), .clear], startPoint: .leading, endPoint: .trailing))
                .frame(height: 1)
        }
    }
}

/// The divider between the workflow and the tools, with what the tools are for
private struct ShellToolsCaption: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Rectangle().fill(LinearGradient(colors: [Cryo.ice.opacity(0.05), Cryo.ice.opacity(0.32), Cryo.ice.opacity(0.05)],
                                            startPoint: .leading, endPoint: .trailing))
                .frame(height: 1)
                .accessibilityHidden(true)
            (Text("CHECK A FILE").font(CryoFont.label(10)).tracking(2.2).foregroundColor(Cryo.ink3)
             + Text(" — on its own, or after Delivery").font(CryoFont.body(11)).foregroundColor(Cryo.ink3))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
        }
    }
}

/// The lit capsule behind the active row (engraved acrylic lit from inside); static — nothing moves on a tab switch
private struct ShellCap: View {
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        let s = RoundedRectangle(cornerRadius: 14, style: .continuous)
        let high = contrast == .increased
        s.fill(LinearGradient(colors: [Cryo.ice.opacity(0.10), Cryo.ice.opacity(0.22)], startPoint: .top, endPoint: .bottom)
                .shadow(.inner(color: Cryo.ice.opacity(0.50), radius: 8, y: -8)))
            .overlay(s.strokeBorder(high ? Color.white : Cryo.icePale.opacity(0.38), lineWidth: high ? 2 : 1))
            .overlay(alignment: .top) {
                Rectangle().fill(LinearGradient(colors: [.clear, Color.white.opacity(0.30), .clear], startPoint: .leading, endPoint: .trailing))
                    .frame(height: 1).padding(.horizontal, 12).padding(.top, 1)
            }
            .shadow(color: high ? .clear : Cryo.ice.opacity(0.42), radius: 11)
    }
}

/// A faint plate under a row the pointer is over (no animation)
private struct ShellHover: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Cryo.ice.opacity(0.06))
    }
}

/// The glyph of a tab: engraved, lit cyan from inside when the tab is active
private struct ShellGlyph: View {
    let symbol: String
    let on: Bool
    var size: CGFloat = 15
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .regular))
            .foregroundStyle(on ? Cryo.ice : Cryo.ink3)
            .shadow(color: on ? Cryo.ice.opacity(0.85) : .clear, radius: 3)
            .frame(width: 20, height: 18)
            .accessibilityHidden(true)
    }
}

/// "01 VIDEO", its status line, the DV chip and the amber "1 decision pending" badge
private struct ShellWorkflowRow: View {
    let mode: AppMode
    let on: Bool
    let line: String
    let pending: Int
    let metadata: ShellMetadataChip.Kind?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                ShellGlyph(symbol: mode.symbol, on: on).padding(.top, 1)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(String(format: "%02d", mode.step ?? 0)).font(CryoFont.mono(11))
                            .foregroundStyle(on ? Cryo.ice : Cryo.ink3)
                        Text(mode.label.uppercased()).font(CryoFont.title(12.5)).tracking(1.5)
                            .foregroundStyle(on ? Color.white : Cryo.ink)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        ShellKeyHint(mode: mode, on: on)
                    }
                    if !shownLine.isEmpty {
                        ShellStatusLine(text: shownLine, on: on)
                    }
                    if metadata != nil || pending > 0 {
                        HStack(spacing: 6) {
                            if let metadata { ShellMetadataChip(kind: metadata) }
                            if pending > 0 { ShellPendingBadge(count: pending) }
                        }
                    }
                }
            }
            .padding(.leading, 10).padding(.trailing, 10).padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { if on { ShellCap() } else if hovering { ShellHover() } }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(mode.step ?? 0), \(mode.label)")
        .accessibilityValue(shownLine + (pending > 0 ? ", \(ShellPendingBadge.text(pending))" : ""))
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }

    /// The badge already says "N decision(s) pending": the line doesn't say it twice
    var shownLine: String {
        guard pending > 0 else { return line }
        let parts = line.components(separatedBy: " · ").filter { !($0.contains("pending") && $0.contains("decision")) }
        return parts.joined(separator: " · ")
    }

    var help: String {
        let n = mode.step ?? 0
        return "Step \(String(format: "%02d", n)) · \(mode.label)" + (ShellKeyHint.key(mode).map { " (\($0))" } ?? "")
    }
}

/// One tool below the divider: File Checker, Render QC, Atmos Visualizer
private struct ShellToolRow: View {
    let mode: AppMode
    let on: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ShellGlyph(symbol: mode.symbol, on: on, size: 14)
                Text(mode.label).font(CryoFont.body(13).weight(.medium))
                    .foregroundStyle(on ? Color.white : Cryo.ink2)
                    .lineLimit(1)
                Spacer(minLength: 4)
                ShellKeyHint(mode: mode, on: on)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { if on { ShellCap() } else if hovering { ShellHover() } }
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("\(mode.label) — reads the file, never changes it" + (ShellKeyHint.key(mode).map { " (\($0))" } ?? ""))
        .accessibilityLabel(mode.label)
        .accessibilityAddTraits(on ? [.isSelected] : [])
    }
}

/// The ⌘1…⌘7 hint (the Go menu holds the shortcuts; the row only shows them)
private struct ShellKeyHint: View {
    let mode: AppMode
    let on: Bool
    static func key(_ m: AppMode) -> String? {
        let order = AppMode.workflow + AppMode.tools
        return order.firstIndex(of: m).map { "⌘\($0 + 1)" }
    }
    var body: some View {
        if let k = Self.key(mode) {
            Text(k).font(CryoFont.mono(10)).foregroundStyle(on ? Cryo.ink2 : Cryo.ink3)
                .accessibilityHidden(true)
        }
    }
}

/// The status line of a step; the word TRANSCODE is always amber (it changes the bits), everything else is grey
private struct ShellStatusLine: View {
    let text: String
    let on: Bool
    var body: some View {
        Text(attributed).font(CryoFont.body(11)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
    }
    var attributed: AttributedString {
        var a = AttributedString(text)
        a.foregroundColor = on ? Cryo.ink : Cryo.ink2
        var from = a.startIndex
        while let r = a[from...].range(of: "TRANSCODE") {
            a[r].foregroundColor = Cryo.attention
            from = r.upperBound
        }
        return a
    }
}

/// "1 decision pending": amber, with an icon and the words (never colour alone)
private struct ShellPendingBadge: View {
    let count: Int
    static func text(_ n: Int) -> String { "\(n) decision\(n == 1 ? "" : "s") pending" }
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9, weight: .bold))
            Text(Self.text(count)).font(CryoFont.label(10)).tracking(0.3)
        }
        .foregroundStyle(Cryo.attention)
        .padding(.horizontal, 8).frame(height: 20)
        .background(Capsule().fill(Cryo.attention.opacity(0.13)))
        .overlay(Capsule().strokeBorder(Cryo.attention.opacity(0.45), lineWidth: 1))
        .fixedSize()
    }
}

/// The Dolby Vision / HDR10+ chip of the Video row; it reopens the metadata analysis on the Video tab
struct ShellMetadataChip: View {
    enum Kind { case dolbyVision, hdr10Plus }
    let kind: Kind
    @Environment(Project.self) private var project
    var body: some View {
        Button {
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { project.mode = .video }
            project.video.popup = .metadata(kind == .dolbyVision ? .dolbyVision : .hdr10Plus)
        } label: {
            Group {
                if kind == .dolbyVision { DolbyVisionLogo(height: 12) } else { HDR10PlusLogo(height: 12) }
            }
            .padding(.horizontal, 7).frame(height: 20)
            .background(Capsule().fill(Color.white.opacity(0.06)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help(kind == .dolbyVision ? "Dolby Vision metadata loaded — open the analysis" : "HDR10+ metadata loaded — open the analysis")
    }
}

/// The ten engines as LEDs: lit when found, amber with the install command when missing
private struct ShellEngineLEDs: View {
    @Bindable var status = EngineStatus.shared

    var body: some View {
        let engines = status.engines
        let missing = engines.filter { $0.path == nil }
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text("ENGINES").font(CryoFont.label(10)).tracking(1.6).foregroundStyle(Cryo.ink3)
                Spacer()
                Text("\(engines.count - missing.count) / \(engines.count)").font(CryoFont.mono(10)).foregroundStyle(Cryo.ink3)
            }
            HStack(spacing: 6) {
                ForEach(engines) { e in
                    ShellLED(color: e.path == nil ? Cryo.attention : Cryo.ice)
                        .help(tip(e))
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Engines")
            .accessibilityValue(missing.isEmpty ? "all \(engines.count) found" : "\(missing.count) missing: " + missing.map(\.name).joined(separator: ", "))
            if let m = missing.first {
                VStack(alignment: .leading, spacing: 2) {
                    Label(missing.count == 1 ? "\(m.name) missing" : "\(missing.count) engines missing",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(CryoFont.body(10.5).weight(.semibold))
                    // the recommendation: the command that installs each one (the same command once)
                    ForEach(Array(Set(missing.compactMap(\.install))).sorted(), id: \.self) { cmd in
                        Text(cmd).font(CryoFont.mono(10)).textSelection(.enabled)
                    }
                }
                .foregroundStyle(Cryo.attention)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.black.opacity(0.35)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Cryo.ice.opacity(0.08), lineWidth: 1))
        .onAppear { status.loadVersions() }
    }

    func tip(_ e: Engine) -> String {
        if e.path == nil { return "\(e.name): missing — \(e.install ?? "")" }
        if e.builtIn { return "\(e.name) · macOS" }
        if let v = status.versions[e.id] { return "\(e.name) \(v)" }
        return "\(e.name) · installed"
    }
}

/// One LED (lit from inside; the meaning is in the count and the tooltip beside it)
private struct ShellLED: View {
    let color: Color
    var size: CGFloat = 9
    var body: some View {
        Circle()
            .fill(RadialGradient(stops: [.init(color: .white.opacity(0.95), location: 0), .init(color: color, location: 0.45),
                                         .init(color: color.opacity(0.45), location: 1)],
                                 center: UnitPoint(x: 0.4, y: 0.35), startRadius: 0, endRadius: size * 0.65))
            .frame(width: size, height: size)
            .shadow(color: color.opacity(0.8), radius: 3)
    }
}

/// The AB mark and the house name at the foot of the sidebar
private struct ShellBrand: View {
    var body: some View {
        HStack(spacing: 10) {
            ABMark(color: Cryo.ink3).frame(width: 26, height: 18)
            Text("ABDALA BROTHERS").font(CryoFont.label(10)).tracking(2.4).foregroundStyle(Cryo.ink3)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Toolbar

/// The toolbar of the current tab: files and the title on the leading side, NEXT (or the Delivery's own buttons) and
/// the inspector toggle on the trailing side. ⌘↩ belongs to START DELIVERY alone; the shell never binds it.
struct ShellToolbar: ToolbarContent {
    let project: Project
    @Binding var inspectorShown: Bool
    init(project: Project, inspectorShown: Binding<Bool>) { self.project = project; _inspectorShown = inspectorShown }

    var body: some ToolbarContent {
        ShellToolbarLeading(project: project)
        ShellToolbarTrailing(project: project, inspectorShown: $inspectorShown)
    }

    /// The file the tab is about: what the Delivery will write, or the file a tool has open
    static func subtitle(_ project: Project) -> String {
        switch project.mode {
        case .video, .audio, .subtitles, .delivery:
            return project.outputURL?.lastPathComponent ?? (project.videoSource == nil ? "no picture yet" : "no destination yet")
        case .inspect: return project.inspector.url?.lastPathComponent ?? "no file open"
        case .atmos: return project.atmos.url?.lastPathComponent ?? "no file open"
        case .qc: return RenderQCModel.shared.url?.lastPathComponent ?? "no file open"
        }
    }
}

/// macOS 26: the same toolbar with a flexible space between the title and NEXT (the system title, which used to push
/// the trailing items over, is gone)
@available(macOS 26.0, *)
private struct ShellSpacedToolbar: ToolbarContent {
    let project: Project
    @Binding var inspectorShown: Bool
    var body: some ToolbarContent {
        ShellToolbarLeading(project: project)
        ToolbarSpacer(.flexible)
        ShellToolbarTrailing(project: project, inspectorShown: $inspectorShown)
    }
}

/// Files and the title
private struct ShellToolbarLeading: ToolbarContent {
    let project: Project
    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            ShellFilePill(project: project)
        }
        if ShellOS.customTitle {
            ToolbarItem(placement: .navigation) {
                ShellTitle(mode: project.mode, subtitle: ShellToolbar.subtitle(project))
            }
        }
    }
}

/// NEXT (or the Delivery's own buttons, or the File Checker's report buttons) and the inspector toggle
private struct ShellToolbarTrailing: ToolbarContent {
    let project: Project
    @Binding var inspectorShown: Bool
    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            switch project.mode {
            case .video:
                Button { go(.audio) } label: { Text("NEXT: AUDIO →") }
                    .buttonStyle(CryoGoButtonStyle(.primary))
                    .disabled(project.videoSource == nil)
                    .help(project.videoSource == nil ? "Add the picture first" : "Go to step 02 · Audio (⌘2)")
            case .audio, .subtitles:
                Button { go(.delivery) } label: { Text("NEXT: DELIVERY →") }
                    .buttonStyle(CryoGoButtonStyle(.primary))
                    .help("Go to step 04 · Delivery (⌘4)")
            case .delivery:
                DeliveryToolbarButtons(project: project)      // SAVE JOB… · ADD TO QUEUE · START DELIVERY (START holds ⌘↩, not the shell)
            case .inspect:
                Button { project.inspector.saveReport() } label: { Label("Save Report…", systemImage: "square.and.arrow.down").labelStyle(.titleAndIcon) }
                    .buttonStyle(CryoButtonStyle())
                    .help("Save the check report as a text file")
                    .disabled(project.inspector.url == nil)
                Button { if let u = project.inspector.url { NSWorkspace.shared.activateFileViewerSelecting([u]) } } label: { Label("Show in Finder", systemImage: "folder").labelStyle(.titleAndIcon) }
                    .buttonStyle(CryoButtonStyle())
                    .help("Show the file in the Finder")
                    .disabled(project.inspector.url == nil)
            case .atmos, .qc:
                EmptyView()
            }
            if project.mode != .inspect {
                Button { inspectorShown.toggle() } label: { Image(systemName: "sidebar.trailing") }
                    .buttonStyle(ShellIconButtonStyle(lit: inspectorShown))
                    .help(inspectorShown ? "Hide the inspector" : "Show the inspector")
                    .accessibilityLabel("Inspector")
            }
        }
    }

    /// No movement on a tab switch
    func go(_ m: AppMode) {
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { project.mode = m }
    }
}

/// Add Files / Clear All on the workflow, Open File on a tool, in one glass pill
private struct ShellFilePill: View {
    let project: Project
    var body: some View {
        CryoPanel(cornerRadius: 17) {
            HStack(spacing: 2) {
                Button { if project.mode == .qc { RenderQCModel.shared.pick() } else { project.openPanel() } } label: { Image(systemName: "plus") }
                    .buttonStyle(ShellIconButtonStyle())
                    .help(project.mode.isWorkflow ? "Add Files (⌘O)" : "Open a file (⌘O)")
                    .accessibilityLabel(project.mode.isWorkflow ? "Add Files" : "Open File")
                    .disabled(project.mode.isWorkflow && project.busy)
                if project.mode.isWorkflow {
                    Button { project.clear() } label: { Image(systemName: "trash") }
                        .buttonStyle(ShellIconButtonStyle())
                        .help("Clear All — start over (⌘N)")
                        .accessibilityLabel("Clear All")
                        .disabled(project.tracks.isEmpty || project.busy)
                }
            }
            .padding(3)
        }
        .fixedSize()
    }
}

/// The title of the tab in caps (with its step number) and the file name in mono under it
private struct ShellTitle: View {
    let mode: AppMode
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let s = mode.step {
                    Text(String(format: "%02d", s)).font(CryoFont.mono(12)).foregroundStyle(Cryo.ice)
                }
                Text(mode.label.uppercased()).font(CryoFont.title(17)).tracking(1.2).foregroundStyle(Cryo.ink)
                    .lineLimit(1)
            }
            Text(subtitle).font(CryoFont.mono(11)).foregroundStyle(Cryo.ink2)
                .lineLimit(1).truncationMode(.middle)
        }
        .padding(.leading, 6)
        .frame(maxWidth: 420, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A round icon button (the prototype's .ibtn): grey glyph, a cyan wash on hover, lit cyan when its panel is shown
struct ShellIconButtonStyle: ButtonStyle {
    var lit = false
    func makeBody(configuration: Configuration) -> some View { ShellIconButton(configuration: configuration, lit: lit) }
}

private struct ShellIconButton: View {
    let configuration: ButtonStyleConfiguration
    let lit: Bool
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    var body: some View {
        configuration.label
            .font(.system(size: 14, weight: .regular))
            .foregroundStyle(lit ? Cryo.ice : hovering && enabled ? Color.white : Cryo.ink2)
            .frame(width: 34, height: 28)
            .background(Capsule().fill(Cryo.ice.opacity(configuration.isPressed ? 0.18 : hovering && enabled ? 0.10 : 0)))
            .contentShape(Capsule())
            .opacity(enabled ? 1 : 0.4)
            .onHover { hovering = $0 }
    }
}

// MARK: - Inspector

/// The inspector column in glass, inset from the window edge like the sidebar. The system paints the inspector column
/// with its own material; the column paints the window's slab over it instead, cut from a window-sized slab at the
/// column's place, so the slab (and the edge light that is the Delivery's progress bar) runs on without a seam.
private struct ShellInspectorColumn<Content: View>: View {
    let windowSize: CGSize
    let content: Content
    init(windowSize: CGSize, @ViewBuilder content: () -> Content) { self.windowSize = windowSize; self.content = content() }
    var body: some View {
        CryoPanel(cornerRadius: 20) {
            GeometryReader { g in                       // exactly the panel's size (see the detail column)
                content
                    .frame(width: g.size.width, height: g.size.height, alignment: .top)
            }
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .padding(.leading, 2).padding(.trailing, 10).padding(.bottom, 10)
        .background { ShellSlabCut(windowSize: windowSize) }
    }
}

/// The window's slab, cut at the place of the view that draws it (a column the system would otherwise paint with its
/// own material): a window-sized CryoWindowBackground moved so it lines up with the one behind the whole window
private struct ShellSlabCut: View {
    let windowSize: CGSize
    var body: some View {
        GeometryReader { g in
            let f = g.frame(in: .global)
            CryoWindowBackground(progress: DeliveryQueue.shared.overall)
                .frame(width: max(windowSize.width, f.maxX), height: max(windowSize.height, f.maxY))
                .offset(x: -f.minX, y: -f.minY)
        }
        .clipped()
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
