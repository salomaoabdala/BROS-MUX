// BROS-MUX Beta 2.0.0 — 04 · DELIVERY: before you start, the file that will be written, the queue and the render page.
// Wave 0: the contract's views as placeholders; the Delivery owner (D) writes the real ones. Until then the tab shows
// the old output panel and result, and START runs the old in-app mux.

import SwiftUI
import AppKit

struct DeliveryTab: View {
    @Environment(Project.self) private var project
    let targeted: Bool

    static func sidebarLine(project: Project) -> String {
        if case .running = project.state { return "rendering \(Int(project.progress * 100)) %" }
        return project.outputURL == nil ? "nothing to deliver yet" : "ready"
    }

    var body: some View {
        VStack(spacing: 0) {
            CryoStrip(touch: .mux, title: "DELIVERY", text: "the file is written here — Delivery tab coming in wave 1")
            ScrollView {
                ResultBanner().padding(16)
            }
        }
    }
}

struct DeliveryInspector: View {
    @Environment(Project.self) private var project
    init() {}
    var body: some View {
        Form {
            OutputSection()
            if !project.included.isEmpty {
                AcademySection()
                SummarySections()
            }
        }
        .formStyle(.grouped)
    }
}

/// SAVE JOB… · ADD TO QUEUE · START DELIVERY (⌘↩). Wave 0: START only, running the old in-app mux.
struct DeliveryToolbarButtons: View {
    let project: Project
    init(project: Project) { self.project = project }
    var body: some View {
        if project.state == .running {
            ProgressView().controlSize(.small)
            Button("Cancel", role: .cancel) { project.cancel() }
        } else {
            Button { DeliveryQueue.shared.startNow(from: project) } label: { Text("START DELIVERY").padding(.horizontal, 6) }
                .buttonStyle(.borderedProminent)
                .tint(project.hdr.encode ? .orange : .accentColor)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!project.canRun)
                .help(project.hdr.encode ? "Re-encode the picture (HEVC 10-bit) and mux (⌘↩)" : "Create the final file (⌘↩)")
        }
    }
}

struct SaveJobSheet: View {
    let project: Project
    init(project: Project) { self.project = project }
    var body: some View {
        Text("Save job — coming in wave 1").padding()
    }
}
