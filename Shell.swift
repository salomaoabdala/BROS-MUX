// BROS-MUX Beta 2.0.0 — the window: sidebar (WORKFLOW + CHECK A FILE), toolbar, content and inspector per tab.

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
            ShellSidebar(selection: $project.mode)
        } detail: {
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(project.mode.label)
            .navigationSubtitle(subtitle)
            .toolbar { ShellToolbar(project: project, inspectorShown: $inspectorShown) }
            .inspector(isPresented: inspectorBinding) {
                Group {
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
        .dropDestination(for: URL.self) { urls, _ in
            guard !project.mode.isWorkflow || !project.busy else { return false }
            if project.mode == .qc { if let u = urls.first { RenderQCModel.shared.open(u) }; return true }
            project.route(urls); return true
        } isTargeted: { dropTargeted = $0 }
    }

    /// The File Checker has no inspector: everything it knows is on its page
    var inspectorBinding: Binding<Bool> {
        Binding(get: { inspectorShown && project.mode != .inspect }, set: { inspectorShown = $0 })
    }

    var subtitle: String {
        switch project.mode {
        case .video, .audio, .subtitles, .delivery: return project.outputURL?.lastPathComponent ?? "Abdala Brothers"
        case .inspect: return project.inspector.url?.lastPathComponent ?? "Abdala Brothers"
        case .atmos: return project.atmos.url?.lastPathComponent ?? "Abdala Brothers"
        case .qc: return RenderQCModel.shared.url?.lastPathComponent ?? "Abdala Brothers"
        }
    }
}

/// The four steps of the workflow, then the tools that check a file
struct ShellSidebar: View {
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
struct ShellToolbar: ToolbarContent {
    let project: Project
    @Binding var inspectorShown: Bool

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { if project.mode == .qc { RenderQCModel.shared.pick() } else { project.openPanel() } } label: { Label(project.mode.isWorkflow ? "Add Files" : "Open File", systemImage: "plus") }
                .help(project.mode.isWorkflow ? "Add files (⌘O)" : "Open a file (⌘O)")
                .disabled(project.mode.isWorkflow && project.busy)
            if project.mode.isWorkflow {
                Button { project.clear() } label: { Label("Clear All", systemImage: "trash") }
                    .help("Start over (⌘N)")
                    .disabled(project.tracks.isEmpty || project.busy)
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            switch project.mode {
            case .video:
                Button { project.mode = .audio } label: { Text("NEXT: AUDIO →").padding(.horizontal, 6) }
                    .help("Go to step 02 · Audio")
            case .audio, .subtitles:
                Button { project.mode = .delivery } label: { Text("NEXT: DELIVERY →").padding(.horizontal, 6) }
                    .help("Go to step 04 · Delivery")
            case .delivery:
                DeliveryToolbarButtons(project: project)      // the Delivery's own buttons (START DELIVERY holds ⌘↩, not the shell)
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
