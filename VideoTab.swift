// BROS-MUX Beta 2.0.0 — 01 · VIDEO: the picture, its metadata and what happens to it.
// Wave 0: the contract's views as placeholders; the Video owner (V) writes the real ones.

import SwiftUI

struct VideoTab: View {
    @Environment(Project.self) private var project
    let targeted: Bool

    var body: some View {
        VStack(spacing: 0) {
            CryoStrip(touch: project.video.touch(project: project), title: "VIDEO", text: project.video.touchText(project: project))
            CryoDropZone(title: project.videoSource.map { $0.url.lastPathComponent } ?? "Drop the picture here",
                         subtitle: "Video tab — coming in wave 1",
                         systemImage: AppMode.video.symbol, targeted: targeted) { project.openPanel() }
        }
    }
}

struct VideoInspector: View {
    init() {}
    var body: some View {
        Text("Video inspector — coming in wave 1").foregroundStyle(.secondary).padding()
    }
}

struct VideoMetadataPopup: View {
    let project: Project
    init(project: Project) { self.project = project }
    var body: some View {
        Text("Metadata analysis — coming in wave 1").padding()
    }
}

struct VideoTranscodeChooser: View {
    let project: Project
    init(project: Project) { self.project = project }
    var body: some View {
        Text("Transcode the picture — coming in wave 1").padding()
    }
}
