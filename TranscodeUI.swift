// BROS-MUX Beta 2.0.0 — what is left of the old Transcode tab's views. The tab itself is gone: a transcode is chosen on
// 01 · VIDEO (VideoTab.swift) and run by the Delivery; the engine (Transcode.swift) and the `--transcode` command line
// (TranscodeModel) are unchanged. The Academy prediction of a transcode moved to VideoPrediction (VideoTab.swift).

import SwiftUI
import AppKit

// MARK: - The old Mux tab's banner (kept while the old Mux view still draws it)

/// Shown while the picture is transcoded to HEVC HDR: who chose it, why, and source → destination. "Got it" shrinks it
/// to one line; it never goes away while the encode is on. "Don't transcode" removes the Dolby Vision / HDR10+ and goes
/// back to COPY — through the Video tab's plan, the one writer of the encode.
struct ReencodeBanner: View {
    @Environment(Project.self) private var project

    var body: some View {
        @Bindable var hdr = project.hdr
        let video = project.video
        let plan = project.encodePlan
        let src = project.videoTrack?.source
        let imf = hdr.imf != nil || project.videoTrack?.url.pathExtension.lowercased() == "mxf"
        let from: String = src.map(VideoFormat.sourceShort) ?? "no picture yet"
        let to: String = plan.map { VideoFormat.destinationShort($0, project: project) } ?? "HEVC 10-bit · 4:2:0"
        VideoAmberPanel {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(FileTouch.transcode.word).font(CryoFont.label(12)).tracking(1).foregroundStyle(Cryo.attention)
                if hdr.bannerCollapsed {
                    Text("\(from)  →  \(to)").font(CryoFont.body(12)).foregroundStyle(Cryo.ink2).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if hdr.bannerCollapsed { Button("Details") { hdr.bannerCollapsed = false }.buttonStyle(CryoButtonStyle()) }
            }
            if !hdr.bannerCollapsed {
                Text(video.hevcReason(project) + ".").font(CryoFont.body(12.5)).foregroundStyle(Cryo.ink).fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(from).font(CryoFont.body(12.5).weight(.semibold)).foregroundStyle(Cryo.ink)
                    Image(systemName: "arrow.right").foregroundStyle(Cryo.attention)
                    Text(to).font(CryoFont.body(12.5).weight(.semibold)).foregroundStyle(Cryo.attention)
                }
                .fixedSize(horizontal: false, vertical: true)
                Text("\(plan?.formats ?? hdr.formatsText) · colour \(plan?.outputColor.text ?? "from the source"). The audio stays bit for bit.")
                    .font(CryoFont.body(11)).foregroundStyle(Cryo.ink2).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Got it") { hdr.bannerCollapsed = true }.buttonStyle(CryoButtonStyle())
                    Button("Don't transcode") {
                        video.removeMetadata(project: project, announce: false)
                        video.choose(.copy, project: project)
                    }
                    .buttonStyle(CryoButtonStyle(tint: Cryo.ink2))
                    .disabled(imf || project.busy)
                    .help(imf ? "An IMF / MXF master can't be copied into MOV, MP4 or MKV as it is: the transcode is the only way out (or remove the picture)." : "Removes the Dolby Vision / HDR10+ metadata and copies the picture bit for bit")
                }
            }
        }
        .padding(.horizontal, DS.margin).padding(.top, DS.rowGap)
    }
}
