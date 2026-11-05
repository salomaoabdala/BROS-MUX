// BROS-MUX Beta 2.0.0 — the Video tab's plan: COPY, HEVC HDR (Dolby Vision / HDR10+ / HDR10) or an SDR transcode.
// hdr.encode stays the one truth of the HEVC HDR path; choice(_:) is computed from it and choose(_:project:) is its only
// writer. Wave 0: the contract's signatures with the simplest bodies; the Video owner (V) writes the real ones.

import SwiftUI

/// An SDR transcode of the picture (the only destinations `.transcode` can take)
struct VideoTranscodeSettings: Codable, Equatable {
    var preset: String                                // TranscodePreset raw: prores422HQ | prores422 | h264Review | hevcSDR
    var resolution: String = "same"                   // OutputResolution raw
    var toneMap: Bool = false
    var quality: String? = nil                        // HDRSettings.Quality raw (H.264/HEVC)
    var speed: String? = nil                          // HDRSettings.Speed raw
}

/// One destination the picture can go to, with the reason when it can't
struct VideoTargetOption: Identifiable {
    let id: String; let title: String; let detail: String
    let choice: VideoPlanModel.Choice; let problem: String?; let recommended: Bool
}

@Observable final class VideoPlanModel {
    enum Choice: Equatable { case copy, hevcHDR, transcode(VideoTranscodeSettings) }
    enum MetadataKind: Equatable { case dolbyVision, hdr10Plus }
    enum Popup: Equatable { case metadata(MetadataKind), needsTranscode(reason: String) }

    var transcode: VideoTranscodeSettings? = nil      // the only stored half of the choice
    var popup: Popup? = nil
    var decisionPending = false                       // the needs-transcode question was dismissed (Esc)
    var checks: [MetadataCheck] = []
    var letterbox: MetadataAnalysis.Letterbox? = nil

    init() {}

    func choice(_ project: Project) -> Choice {
        if project.hdr.encode { return .hevcHDR }
        return transcode.map { .transcode($0) } ?? .copy
    }

    /// The ONLY writer of hdr.encode / autoEnabledBy / autoReason
    func choose(_ c: Choice, project: Project) {
        switch c {
        case .copy: transcode = nil; project.hdr.encode = false
        case .hevcHDR: transcode = nil; project.hdr.encode = true
        case .transcode(let s): transcode = s; project.hdr.encode = false
        }
        project.hdr.autoEnabledBy = nil
        project.hdr.autoReason = nil
        popup = nil
        decisionPending = false
    }

    func didAddVideo(project: Project) {}
    func didAddMetadata(kind: MetadataKind, url: URL, project: Project) {}
    func removeMetadata(project: Project) {}

    func reset() {
        transcode = nil; popup = nil; decisionPending = false; checks = []; letterbox = nil
    }

    func touch(project: Project) -> FileTouch {
        if decisionPending { return .pending }
        return choice(project) == .copy ? .copy : .transcode
    }

    func touchText(project: Project) -> String {
        switch choice(project) {
        case .copy: return "the picture is not touched"
        case .hevcHDR: return "→ HEVC 10-bit" + (project.hdr.dvSource != nil ? " · Dolby Vision 8.1" : "")
        case .transcode(let s): return "→ " + (TranscodePreset(rawValue: s.preset)?.label ?? s.preset)
        }
    }

    func sidebarLine(project: Project) -> String {
        guard let v = project.videoSource else { return "no picture yet" }
        return v.codecName + " · " + (touch(project: project) == .copy ? "COPY" : "TRANSCODE")
    }

    /// `.transcode` only (SDR), audio .none (wave 0: not built yet)
    func transcodePlan(project: Project) -> TranscodePlan? { nil }

    func legalTargets(project: Project) -> [VideoTargetOption] { [] }
}
