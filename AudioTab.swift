// BROS-MUX Beta 2.0.0 — 02 · AUDIO: the sound from the video file, your audio, the order and the alignment.
// Wave 0: the contract's views as placeholders; the Audio owner (A) writes the real ones.

import SwiftUI

struct AudioTab: View {
    @Environment(Project.self) private var project
    let targeted: Bool

    static func sidebarLine(project: Project) -> String {
        let n = project.outputAudio.count
        return n == 0 ? "no audio yet" : "\(n) track\(n == 1 ? "" : "s")"
    }

    var body: some View {
        VStack(spacing: 0) {
            CryoStrip(touch: .copy, title: "AUDIO", text: "the sound goes in bit for bit")
            CryoDropZone(title: "Drop your audio here", subtitle: "Audio tab — coming in wave 1",
                         systemImage: AppMode.audio.symbol, targeted: targeted) { project.openPanel() }
        }
    }
}

struct AudioInspector: View {
    init() {}
    var body: some View {
        Text("Audio inspector — coming in wave 1").foregroundStyle(.secondary).padding()
    }
}

/// "This audio came inside the video. Use it in the delivery?"
struct EmbeddedAudioPopover: View {
    let project: Project
    let trackID: UUID
    init(project: Project, trackID: UUID) { self.project = project; self.trackID = trackID }
    var body: some View {
        Text("Use it in the delivery? — coming in wave 1").padding()
    }
}

/// What --quality draws (channel map, disable extra audio, interleave). Wave 0: still the old QualitySheet.
struct AudioOptionsView: View {
    init() {}
    var body: some View { QualitySheet() }
}
