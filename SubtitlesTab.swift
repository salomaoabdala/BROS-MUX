// BROS-MUX Beta 2.0.0 — 03 · SUBTITLES: reserved ("coming in a later Beta"); the subtitles found start out of the file.
// Wave 0: the contract's views as placeholders; the Subtitles owner (X) writes the real ones.

import SwiftUI

struct SubtitlesTab: View {
    @Environment(Project.self) private var project
    let targeted: Bool

    static func sidebarLine(project: Project) -> String { "coming later" }

    var body: some View {
        VStack(spacing: 0) {
            CryoStrip(touch: .copy, title: "SUBTITLES", text: "coming in a later Beta")
            CryoDropZone(title: "Subtitles — coming in a later Beta", subtitle: "\(project.subtitleTracks.count) found",
                         systemImage: AppMode.subtitles.symbol, targeted: targeted) { project.openPanel() }
        }
    }
}

struct SubtitlesInspector: View {
    init() {}
    var body: some View {
        Text("Subtitles inspector — coming in a later Beta").foregroundStyle(.secondary).padding()
    }
}
