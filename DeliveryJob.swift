// BROS-MUX Beta 2.0.0 — the job file (.bmjob, JSON, schemaVersion 1): everything a Delivery needs, frozen.
// Schema: PLANO-BETA-2.0.0.md ("Arquivo de job"). Wave 0: the schema and the contract's signatures with the simplest
// bodies; the Delivery owner (D) writes capture/rebuild/canonicalText/writeText for real.

import Foundation

struct DeliveryJob: Codable {
    var schemaVersion = 1
    var id: UUID; var name: String; var created: Date; var app: String          // AppInfo.name
    var sources: [SourceFile]          // every input: picture, audio, IMF ASSETMAP/CPL/MXF, DV XML, HDR10+ JSON
    struct SourceFile: Codable { var path: String; var size: Int64; var modified: Date }   // fingerprint
    var tracks: [TrackIntent]          // in `project.tracks` order (= output order for included)
    struct TrackIntent: Codable {
        var key: StreamKey             // path + stream index(es); a mono group = its members, sorted
        var kind: String               // TrackKind raw
        var grouped: Bool              // made with makeGroup (members in key.streams)
        var include: Bool; var title: String; var language: String; var enabled: Bool
        var trimStart: Int; var syncApplied: Bool
        var channelMap: String?; var channelTarget: [String]?; var channelRoles: [String]?   // raw values
        var delivery: String           // AudioDelivery raw
    }
    var embeddedAudioAnswer: [StreamKey: Bool]
    var syncReference: StreamKey?
    var referenceLateFrames: Double
    var matchVideoEnd: Bool, verifyAudio: Bool, verifyVideo: Bool, fixColorTag: Bool,
        writeChannelMap: Bool, disableExtraAudio: Bool, interleaveMs: Int, pictureCheck: Bool
    var video: VideoIntent
    struct VideoIntent: Codable {
        var choice: String             // "copy" | "hevcHDR" | "transcode"
        var transcode: VideoTranscodeSettings?
        var dvSource: String?; var hdr10plusJSON: String?; var imf: String?
        var dolbyVision: Bool; var hdr10plus: Bool
        var quality: String; var speed: String; var rateMode: String; var bitratePreset: String
        var customMbps: Int?; var customMaxMbps: Int?; var qualityFloor: Bool; var convertGamut: Bool
        var mastering: String?; var maxCLL: Int; var maxFALL: Int
    }
    var container: String; var output: String
    var overwrite: String              // "keepBoth" (default) | "replace"

    /// The project as it is now (wave 0: a direct copy of the fields; D refines it)
    static func capture(_ project: Project) -> DeliveryJob {
        let hdr = project.hdr
        func source(_ path: String) -> SourceFile {
            let a = try? FileManager.default.attributesOfItem(atPath: path)
            return SourceFile(path: path, size: (a?[.size] as? NSNumber)?.int64Value ?? 0, modified: (a?[.modificationDate] as? Date) ?? .distantPast)
        }
        let dvPath: String? = {
            switch hdr.dvSource {
            case .xml(let u)?: return u.path
            case .isxd(let parts)?: return parts.first?.file.path
            case nil: return nil
            }
        }()
        var paths: [String] = []
        for p in project.tracks.map(\.url.path) + [dvPath, hdr.hdr10plusJSON?.path].compactMap({ $0 }) where !paths.contains(p) { paths.append(p) }
        let choice: String
        switch project.video.choice(project) {
        case .copy: choice = "copy"
        case .hevcHDR: choice = "hevcHDR"
        case .transcode: choice = "transcode"
        }
        return DeliveryJob(
            id: UUID(), name: project.outputURL?.deletingPathExtension().lastPathComponent ?? "Delivery", created: Date(), app: AppInfo.name,
            sources: paths.map(source),
            tracks: project.tracks.map { t in
                TrackIntent(key: project.key(of: t), kind: t.kind.rawValue, grouped: t.isGroup, include: t.include, title: t.title,
                            language: t.language, enabled: t.enabled, trimStart: t.trimStart, syncApplied: t.syncApplied,
                            channelMap: t.channelMap.rawValue, channelTarget: t.channelTarget?.roles.map(\.rawValue),
                            channelRoles: t.channelRoles?.map(\.rawValue), delivery: t.delivery.rawValue)
            },
            embeddedAudioAnswer: project.embeddedAudioAnswer,
            syncReference: project.reference.map { project.key(of: $0) },
            referenceLateFrames: project.referenceLateFrames,
            matchVideoEnd: project.matchVideoEnd, verifyAudio: project.verifyAudio, verifyVideo: project.verifyVideo, fixColorTag: project.fixColorTag,
            writeChannelMap: project.writeChannelMap, disableExtraAudio: project.disableExtraAudio, interleaveMs: project.interleaveMs, pictureCheck: project.pictureCheck,
            video: VideoIntent(choice: choice, transcode: project.video.transcode, dvSource: dvPath, hdr10plusJSON: hdr.hdr10plusJSON?.path,
                               imf: hdr.imf?.cpl.path, dolbyVision: hdr.dolbyVision, hdr10plus: hdr.hdr10plus,
                               quality: hdr.quality.rawValue, speed: hdr.speed.rawValue, rateMode: hdr.rateMode.rawValue, bitratePreset: hdr.bitratePreset.rawValue,
                               customMbps: hdr.customMbps, customMaxMbps: hdr.customMaxMbps, qualityFloor: hdr.qualityFloor, convertGamut: hdr.convertGamut,
                               mastering: hdr.mastering.text, maxCLL: hdr.maxCLL, maxFALL: hdr.maxFALL),
            container: project.container.rawValue, output: project.outputURL?.path ?? "", overwrite: "keepBoth")
    }

    /// Rebuilds the project from the job, synchronously, in the order of the plan (wave 0: not implemented)
    func rebuild(into project: Project) throws -> [String] {
        throw AppError("Rebuilding a project from a job file isn't implemented yet.")
    }

    /// The text both sides of START must agree on (wave 0: the command preview only)
    static func canonicalText(_ project: Project) -> String { project.commandPreview }

    /// The readable .job.txt (wave 0: not implemented)
    func writeText(to url: URL) throws {
        throw AppError("Writing the readable job text isn't implemented yet.")
    }
}
