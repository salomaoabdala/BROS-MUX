// BROS-MUX Beta 2.0.0 — the Delivery engine: what a job does (prepare), what stops it (preflight), the run itself
// (two-step picture, audio pre-steps, the bit-exact mux, the checks after writing, Render QC, the report), the detached
// worker (--job-file) with the files the window follows, and the queue the window keeps.
//
// The render never runs inside the window: START saves the job and launches `BROS-MUX --job-file X.bmjob` on its own
// (launchd, run once), which writes ~/Library/Application Support/BROS-MUX Beta/Jobs/<id>/progress.json etc.

import Foundation
import Observation
import AppKit
import UniformTypeIdentifiers

enum DeliveryState: String, Codable { case queued, running, done, warning, failed, cancelled }

/// The last progress of a running job (progress.json)
struct DeliverySnapshot: Codable, Equatable {
    var stage: JobProgress.Stage?; var title: String; var stageFraction: Double; var overall: Double
    var frame: Int?; var totalFrames: Int?; var fpsAverage: Double?; var bitrateKbps: Double?
    var bytesWritten: Int64?; var bytesTotal: Int64?; var stageIndex: Int; var stageCount: Int
    var stagesDone: [JobProgress.Stage]; var started: Date; var updated: Date
}

struct DeliveryItem: Identifiable {
    let id: UUID; var job: DeliveryJob; var jobFile: URL; var state: DeliveryState
    var snapshot: DeliverySnapshot?; var findings: [String]; var resultLines: [String]; var output: URL?
}

/// One line of "BEFORE YOU START", with the tab that fixes it
struct DeliveryPreflightItem: Identifiable { let id = UUID(); var level: CheckLevel; var text: String; var tab: AppMode? }

// MARK: - Files

enum DeliveryPaths {
    static var jobs: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("BROS-MUX Beta/Jobs", isDirectory: true)
    }
    static func folder(_ id: UUID) -> URL { jobs.appendingPathComponent(id.uuidString, isDirectory: true) }
    static var queue: URL { jobs.appendingPathComponent("queue.json") }
    static func progress(_ id: UUID) -> URL { folder(id).appendingPathComponent("progress.json") }
    static func info(_ id: UUID) -> URL { folder(id).appendingPathComponent("info.json") }
    static func findings(_ id: UUID) -> URL { folder(id).appendingPathComponent("findings.log") }
    static func history(_ id: UUID) -> URL { folder(id).appendingPathComponent("history.csv") }
    static func result(_ id: UUID) -> URL { folder(id).appendingPathComponent("result.json") }
    static func report(_ id: UUID) -> URL { folder(id).appendingPathComponent("report.txt") }
    static func cancel(_ id: UUID) -> URL { folder(id).appendingPathComponent("cancel") }
    static func pid(_ id: UUID) -> URL { folder(id).appendingPathComponent("pid") }
    static func log(_ id: UUID) -> URL { folder(id).appendingPathComponent("worker.log") }
    static func jobFile(_ id: UUID) -> URL { folder(id).appendingPathComponent("job.bmjob") }
    static func jobText(_ id: UUID) -> URL { folder(id).appendingPathComponent("job.txt") }

    static func ensure(_ id: UUID) throws { try FileManager.default.createDirectory(at: folder(id), withIntermediateDirectories: true) }

    /// A name that doesn't exist yet next to `url` (name, name_2, name_3…)
    static func unique(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent(), base = url.deletingPathExtension().lastPathComponent, ext = url.pathExtension
        var n = 2
        while true {
            let u = dir.appendingPathComponent("\(base)_\(n)").appendingPathExtension(ext)
            if !fm.fileExists(atPath: u.path) { return u }
            n += 1
        }
    }

    static func writeJSON<T: Encodable>(_ v: T, to url: URL) {
        if let d = try? DeliveryJob.encoder.encode(v) { try? d.write(to: url, options: .atomic) }
    }
    static func readJSON<T: Decodable>(_ t: T.Type, _ url: URL) -> T? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? DeliveryJob.decoder.decode(t, from: d)
    }
    static func alive(_ pid: Int32) -> Bool { pid > 0 && (kill(pid, 0) == 0 || errno == EPERM) }
    static func readPID(_ id: UUID) -> Int32? { (try? String(contentsOf: pid(id), encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) } }
}

/// What the worker says about the job it runs (info.json): what to follow, and the stages with their times
struct DeliveryWorkerInfo: Codable {
    struct Segment: Codable { var file: String; var start: Int; var count: Int }
    struct Stage: Codable { var stage: JobProgress.Stage; var title: String; var weight: Double; var started: Date?; var ended: Date? }
    var id: UUID; var pid: Int32; var label: String?; var name: String
    var output: String; var workFolder: String?; var started: Date
    var picture: String?; var pictureIndex: Int; var fps: Double; var frames: Int; var startTimecode: String?
    var segments: [Segment]
    var encodes: Bool                  // a picture is encoded (frames / fps page) — otherwise MB written / MB/s
    var bytesTotal: Int64
    var stages: [Stage]
}

/// The end of a job (result.json)
struct DeliveryResultFile: Codable {
    var id: UUID; var state: DeliveryState; var lines: [String]; var output: String?
    var academy: String?; var zidoo: String?; var academyChecks: [String]; var zidooChecks: [String]
    var renderQC: String?; var seconds: Double; var report: String?; var finished: Date
}

/// One job of the window's queue (queue.json)
struct DeliveryQueueEntry: Codable {
    var id: UUID; var jobFile: String; var state: DeliveryState; var launched: Bool; var label: String?; var autoStart: Bool
    var blockers: [String]?
}

extension AcademyLevel {
    var deliveryKey: String { switch self { case .notApproved: return "notApproved"; case .accepted: return "accepted"; case .preferred: return "preferred" } }
    init?(deliveryKey k: String) { switch k { case "notApproved": self = .notApproved; case "accepted": self = .accepted; case "preferred": self = .preferred; default: return nil } }
}
extension ZidooLevel {
    var deliveryKey: String { switch self { case .plays: return "plays"; case .likely: return "likely"; case .noPlay: return "noPlay" } }
    init?(deliveryKey k: String) { switch k { case "plays": self = .plays; case "likely": self = .likely; case "noPlay": self = .noPlay; default: return nil } }
}

// MARK: - The frozen job

/// An audio track transcoded before the mux (AAC / PCM 24-bit); the mux then copies the result bit for bit
struct DeliveryAudioStep {
    var index: Int                     // in spec.tracks
    var track: Track                   // the original (the sync reference stays the original too)
    var plan: TrimPlan?                // what JobRunner would have applied to it
    var to: AudioDelivery
}

/// Everything one Delivery runs, frozen when it is prepared; nothing reads the Project after this
struct DeliveryExecution {
    var job: DeliveryJob
    var spec: JobSpec                  // the mux as asked (the step-1 picture and the transcoded audio are swapped in at run time)
    var step1: TranscodePlan?          // .transcode: the picture is transcoded first, then copied bit for bit
    var audioSteps: [DeliveryAudioStep]
    var output: URL                    // resolved now: "keep both" gives an existing name a _2
    var overwrite: String
    var commandPreview: String         // every command: [the step-1 ffmpeg] + the mux's own preview
    var muxCommand: String             // the mux's preview (Project.commandPreview, as --job prints it)
    var tracks: [Track]                // every track of the project (for the report's roles)
    var referenceID: UUID?
    var alignLines: [String]
    var frames: Int
    var fps: Double
    var startTimecode: String?
    var estimatedBytes: Double
    var pictureText: String            // "Picture: COPY · bit-exact (ProRes 4444)" / "TRANSCODED …"
}

enum DeliveryEngine {
    /// The step-1 picture plan of a `.transcode` choice: the Video tab's plan, or (until it has one) the same
    /// destination built from the old Transcode tables — SDR only, audio left out, MOV
    static func step1Plan(_ project: Project) -> TranscodePlan? {
        guard case .transcode(let s) = project.video.choice(project) else { return nil }
        if var p = project.video.transcodePlan(project: project) { p.audio = .none; p.container = .mov; return p }
        guard project.hdr.imf == nil, let v = project.videoTrack, let src = v.source,
              let preset = TranscodePreset(rawValue: s.preset), preset != .hevcDolbyVision, preset != .custom else { return nil }
        var p = TranscodeModel.plan(source: src, preset: preset, resolution: OutputResolution(rawValue: s.resolution) ?? .same, toneMap: s.toneMap,
                                    container: .mov, quality: s.quality.flatMap(HDRSettings.Quality.init(rawValue:)),
                                    speed: s.speed.flatMap(HDRSettings.Speed.init(rawValue:)), audio: AudioPlan.none, dv: nil, hdr10plus: nil, mi: v.mi)
        p.audio = .none; p.container = .mov
        p.segments = [.init(file: v.url, start: 0, count: project.videoFrames)]
        p.frames = project.videoFrames; p.fps = project.videoFPS
        return p
    }

    static func transcodesAnything(_ project: Project) -> Bool {
        project.video.choice(project) != .copy || project.outputAudio.contains { $0.delivery != .copy }
    }

    /// Bytes of the final file: the mux estimate with the step-1 picture in place of the source picture
    static func estimatedFinalBytes(_ project: Project) -> Double {
        guard let spec = project.jobSpec else { return 0 }
        let step1 = step1Plan(project)
        return spec.tracks.reduce(0.0) { sum, t in
            if t.kind == .video, let p = step1 { return sum + p.estimatedBytes }
            if t.kind == .audio, t.delivery == .aac, t.duration > 0 { return sum + Double(t.channels > 2 ? 640_000 : 256_000) / 8 * t.duration }
            if t.kind == .audio, t.delivery == .pcm24, t.sampleRate > 0 { return sum + Double(t.channels * 3) * t.sampleRate * t.duration }
            return sum + JobRunner.estimatedBytes(t, plan: spec.plans[t.id], encode: spec.videoEncode)
        }
    }

    /// Temporary space on the destination drive besides the final file and MP4Box's copy: the step-1 picture and the transcoded audio
    static func estimatedTempBytes(_ project: Project) -> Double {
        var b = step1Plan(project)?.estimatedBytes ?? 0
        for t in project.outputAudio where t.delivery != .copy {
            b += t.delivery == .aac ? Double(t.channels > 2 ? 640_000 : 256_000) / 8 * t.duration : Double(t.channels * 3) * t.sampleRate * t.duration
        }
        return b
    }

    // MARK: preflight

    /// What stops (✕) or needs a confirmation (⚠) before START, each with the tab that fixes it
    static func preflight(_ project: Project, overwrite: String) -> [DeliveryPreflightItem] {
        var out: [DeliveryPreflightItem] = []
        func add(_ l: CheckLevel, _ t: String, _ tab: AppMode?) { out.append(DeliveryPreflightItem(level: l, text: t, tab: tab)) }
        if project.tracks.isEmpty { add(.fail, "Nothing to deliver yet: add the picture on the Video tab.", .video); return out }
        if !Tools.missing.isEmpty { add(.fail, "Missing tools: \(Tools.missing.joined(separator: ", ")). Run: brew install gpac media-info", nil) }
        if project.videoSource == nil { add(.warn, "There's no picture: the file will hold only the sound.", .video) }
        if project.loadingCount > 0 { add(.fail, "Still reading the files — wait a moment.", nil) }
        if project.aligning { add(.fail, "Still lining the audio up with the picture — wait for it to finish.", .audio) }
        guard let spec = project.jobSpec, let output = project.outputURL else {
            add(.fail, "Choose where the file will be written (THE FILE THAT WILL BE WRITTEN → Folder).", .delivery); return out
        }
        let step1 = step1Plan(project)

        // the chain: metadata left out ?? HDR problem ?? the mux's own validation ?? the step-1 transcode's validation
        let validationSpec: JobSpec? = {
            guard step1 != nil else { return spec }
            var v = spec; v.tracks.removeAll { $0.kind == .video }; v.videoEncode = nil
            return v.tracks.isEmpty ? nil : v
        }()
        var chain: (String, AppMode?)? = project.metadataNotEmbedded.map { ($0, .video) } ?? project.hdrProblem.map { ($0, .video) }
        if chain == nil, let v = validationSpec, let p = JobRunner.validate(v) { chain = (p, tabFor(p, project)) }
        if chain == nil, case .transcode = project.video.choice(project) {
            if project.hdr.imf != nil { chain = ("An IMF picture can only go to HEVC: choose the HEVC transcode on the Video tab.", .video) }
            else if let p = step1 {
                let probe = output.deletingLastPathComponent().appendingPathComponent(".BROS-MUX-step-1.mov")
                if let e = TranscodeRunner.validate(p, output: probe) { chain = (e, .video) }
            } else { chain = ("The picture's transcode can't be planned — open the Video tab and choose the destination again.", .video) }
        }
        if let c = chain { add(.fail, c.0, c.1) }

        // decisions nobody has taken
        for t in project.pendingAudioDecisions {
            add(.fail, "“\(t.title)” came inside the video: use it in the delivery, or not? Nothing is decided for you.", .audio)
        }
        if project.video.decisionPending { add(.fail, "The picture can't carry what you added: decide on the Video tab (transcode it, or deliver without the metadata).", .video) }
        for c in metadataChecks(project) where c.level == .fail { add(.fail, "\(c.title): \(c.detail)", .video) }

        // what can't go into this container as it is
        for t in project.outputAudio {
            if t.delivery != .copy {
                if let p = AudioTranscode.problem(t, to: t.delivery) { add(.fail, "“\(t.title)” can't be \(t.delivery.label): \(p)", .audio) }
            } else if let r = project.audioConversionReason(t) {
                add(.fail, "“\(t.title)” can't go into \(project.container.rawValue.uppercased()) as it is: \(r)", .audio)
            }
        }
        if let v = project.videoTrack, step1 == nil, spec.videoEncode == nil {
            for w in project.containerWarnings(v) where !w.hasPrefix("MXF") { add(.warn, w, .video) }
        }
        for t in project.included where t.kind == .subtitle || t.kind == .timecode {
            for w in project.containerWarnings(t) { add(.warn, "“\(t.title)”: \(w)", t.kind == .subtitle ? .subtitles : .delivery) }
        }

        // the mix lined up with the picture
        if let ref = project.reference {
            for t in project.outputAudio where t.id != ref.id && !t.syncApplied {
                add(.warn, "“\(t.title)” isn't lined up with the picture yet (Line up with the picture, on the Audio tab).", .audio)
            }
        } else if project.videoSource != nil, project.outputAudio.count > 0 {
            add(.info, "No sync reference: the sync check after writing is skipped (the picture check still runs).", .audio)
        }

        // free space: temp + 2 × the final file + 1 GB, all on the destination drive
        let final = estimatedFinalBytes(project), temp = estimatedTempBytes(project)
        let need = temp + 2 * final + 1_000_000_000
        if let free = Tools.freeSpace(at: output.deletingLastPathComponent()) {
            if free < need { add(.fail, "Not enough free space on the destination drive: about \(Fmt.bytes(need)) is needed while writing (the file will be ~\(Fmt.bytes(final))) and \(Fmt.bytes(free)) is free.", .delivery) }
            else { add(.ok, "Free space: about \(Fmt.bytes(need)) is needed while writing, \(Fmt.bytes(free)) is free.", nil) }
        }

        // an existing file of that name
        if FileManager.default.fileExists(atPath: output.path) {
            if overwrite == "replace" { add(.warn, "\(output.lastPathComponent) already exists and will be REPLACED at the very end (only if every check passes).", .delivery) }
            else { add(.info, "\(output.lastPathComponent) already exists: both are kept — this one will be \(DeliveryPaths.unique(output).lastPathComponent).", .delivery) }
        }
        return out
    }

    /// The Dolby Vision / HDR10+ analysis: the Video tab's lines, or (in the render process, where no tab made them)
    /// the same analysis made from the metadata already read
    static func metadataChecks(_ project: Project) -> [MetadataCheck] {
        if !project.video.checks.isEmpty { return project.video.checks }
        guard project.video.choice(project) == .hevcHDR else { return [] }
        let hdr = project.hdr, src = project.videoTrack?.source, frames = project.videoFrames, fps = project.videoFPS.value
        var out: [MetadataCheck] = []
        if hdr.dvSource != nil && hdr.dolbyVision { out += MetadataAnalysis.dolbyVision(hdr, picture: src, frames: frames, fps: fps, letterbox: project.video.letterbox) }
        if hdr.hdr10plusJSON != nil && hdr.hdr10plus { out += MetadataAnalysis.hdr10Plus(hdr, picture: src, frames: frames, fps: fps) }
        return out
    }

    /// Which tab fixes a JobRunner.validate message
    static func tabFor(_ message: String, _ project: Project) -> AppMode? {
        if project.outputAudio.contains(where: { message.contains("“\($0.title)”") }) { return .audio }
        if message.contains("picture") || message.contains("MXF master") { return .video }
        return .delivery
    }

    // MARK: prepare

    /// The job as it will run, frozen (the same function serves START's check and the detached worker)
    static func prepare(_ project: Project, job: DeliveryJob) -> DeliveryExecution? {
        guard var spec = project.jobSpec else { return nil }
        let output = job.overwrite == "replace" ? spec.output : DeliveryPaths.unique(spec.output)
        spec.output = output
        let step1 = step1Plan(project)
        if step1 != nil { spec.verifyVideo = true; spec.fixColorTag = false; spec.videoEncode = nil }
        var audio: [DeliveryAudioStep] = []
        for (i, t) in spec.tracks.enumerated() where t.kind == .audio && t.delivery != .copy {
            audio.append(DeliveryAudioStep(index: i, track: t, plan: spec.plans[t.id], to: t.delivery))
        }
        let v = project.videoTrack
        let pictureText: String
        if let p = step1 { pictureText = "Picture: TRANSCODED in step 1 (\(p.source.codecName) → \(p.outputCodecName)), then copied bit for bit into the final file" }
        else if let e = spec.videoEncode { pictureText = "Picture: RE-ENCODED (= transcode) (\(e.source.codecName) → \(e.outputCodecName)) · \(e.formats)" }
        else { pictureText = v.map { "Picture: COPY · bit-exact (\($0.codecName))" } ?? "Picture: none" }
        let preview: String = {
            var s = project.commandPreview
            if let p = step1 { s = "ffmpeg " + quote(Transcode.arguments(p, concat: nil, output: output.deletingLastPathComponent().appendingPathComponent(".BROS-MUX-tmp/video.mov"), elementary: false)) + "\n" + s }
            return s
        }()
        return DeliveryExecution(job: job, spec: spec, step1: step1, audioSteps: audio, output: output, overwrite: job.overwrite,
                                 commandPreview: preview, muxCommand: project.commandPreview, tracks: project.tracks, referenceID: project.reference?.id, alignLines: project.alignLines,
                                 frames: project.videoFrames, fps: project.videoFPS.value, startTimecode: v?.source?.timecode,
                                 estimatedBytes: estimatedFinalBytes(project), pictureText: pictureText)
    }

    static func quote(_ a: [String]) -> String { a.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ") }

    // MARK: stages

    /// The stages of the whole Delivery with their weight (estimated seconds on this Mac): the engine's own plan when
    /// it gives one, otherwise estimated here from the same plans
    static func plannedStages(_ x: DeliveryExecution) -> [(stage: JobProgress.Stage, title: String, weight: Double)] {
        plannedStages(spec: x.spec, step1: x.step1, audio: x.audioSteps.map(\.track), frames: x.frames, bytes: x.estimatedBytes)
    }

    /// Rough time of the whole Delivery on this Mac (the sum of the stage estimates), before it is prepared
    static func estimatedSeconds(_ project: Project) -> Double? {
        guard var spec = project.jobSpec else { return nil }
        let step1 = step1Plan(project)
        if step1 != nil { spec.verifyVideo = true; spec.fixColorTag = false; spec.videoEncode = nil }
        let audio = project.outputAudio.filter { $0.delivery != .copy }
        return plannedStages(spec: spec, step1: step1, audio: audio, frames: project.videoFrames, bytes: estimatedFinalBytes(project)).reduce(0) { $0 + $1.weight }
    }

    static func plannedStages(spec: JobSpec, step1: TranscodePlan?, audio: [Track], frames: Int, bytes: Double) -> [(stage: JobProgress.Stage, title: String, weight: Double)] {
        var s: [(JobProgress.Stage, String, Double)] = []
        if let p = step1 {
            let engine = TranscodeRunner.plannedStages(p, runQC: false, runVMAF: false)
            if !engine.isEmpty { s += engine.map { ($0.stage, title($0.stage, step1: true), $0.weight) } }
            else {
                if p.video.rate?.mode == .average && p.encoder == "libx265" {
                    s.append((.pass1, "Step 1 · pass 1 of 2", p.estimatedSeconds * 0.4)); s.append((.pass2, "Step 1 · pass 2 of 2", p.estimatedSeconds))
                } else { s.append((.transcodeVideo, "Step 1 · transcoding the picture", p.estimatedSeconds)) }
                s.append((.checkResult, "Step 1 · checking the picture", 5 + Double(p.frames) / 2000))
            }
        }
        if !audio.isEmpty {
            s.append((.transcodeAudio, "Transcoding the audio", audio.reduce(0.0) { $0 + max(5, $1.duration / 25) }))
        }
        var mux = spec
        if step1 != nil { mux.verifyVideo = true }
        let engine = JobRunner.plannedStages(mux)
        if !engine.isEmpty { s += engine.map { ($0.stage, title($0.stage, step1: false), $0.weight) } }
        else { s += fallbackJobStages(mux, bytes: bytes).map { ($0.0, title($0.0, step1: false), $0.1) } }
        if step1 != nil || !audio.isEmpty { s.append((.checkResult, "Checking what was transcoded", 10 + Double(audio.count) * 20)) }
        s.append((.renderQC, "Render QC", 10 + Double(max(frames, 1)) / 150))
        s.append((.finalize, "Writing the report", 2))
        return s.map { (stage: $0.0, title: $0.1, weight: max($0.2, 0.5)) }
    }

    static func title(_ st: JobProgress.Stage, step1: Bool) -> String {
        guard step1 else { return st.title }
        switch st {
        case .pass1: return "Step 1 · pass 1 of 2"
        case .pass2: return "Step 1 · pass 2 of 2"
        case .encode, .transcodeVideo: return "Step 1 · transcoding the picture"
        case .checkResult: return "Step 1 · checking the picture"
        default: return "Step 1 · " + st.title.lowercased()
        }
    }

    static func fallbackJobStages(_ spec: JobSpec, bytes: Double) -> [(JobProgress.Stage, Double)] {
        var s: [(JobProgress.Stage, Double)] = []
        if let e = spec.videoEncode {
            if e.hdr?.dolbyVision != nil { s.append((.readMetadata, 30)) }
            if e.video.rate?.mode == .average && e.encoder == "libx265" { s.append((.pass1, e.estimatedSeconds * 0.4)); s.append((.pass2, e.estimatedSeconds)) }
            else { s.append((.encode, e.estimatedSeconds)) }
            if e.hdr?.hdr10plus != nil { s.append((.injectHDR10Plus, 10 + e.estimatedBytes / 400_000_000)) }
            if e.hdr?.dolbyVision != nil { s.append((.injectDV, 10 + e.estimatedBytes / 300_000_000)) }
        }
        let groups = spec.tracks.filter { $0.isGroup && spec.plans[$0.id] != nil }
        if !groups.isEmpty { s.append((.interleave, groups.reduce(0.0) { $0 + JobRunner.estimatedBytes($1, plan: spec.plans[$1.id]) } / 250_000_000 + 2)) }
        let trims = spec.tracks.filter { !$0.isGroup && $0.kind == .audio && spec.plans[$0.id] != nil }
        if !trims.isEmpty { s.append((.trim, trims.reduce(0.0) { $0 + JobRunner.estimatedBytes($1, plan: spec.plans[$1.id]) } / 300_000_000 + 2)) }
        s.append((.mux, bytes / 300_000_000 + 3))
        if spec.isMKV { s.append((.mkv, bytes / 400_000_000 + 2)) }
        if spec.isMOV { s.append((.headers, 1)) }
        if spec.videoEncode != nil { s.append((.verifyPicture, 40)) }
        var verified = 0.0
        for t in spec.tracks where (t.kind == .audio && spec.verifyAudio) || (t.kind == .video && spec.verifyVideo && spec.videoEncode == nil) {
            verified += JobRunner.estimatedBytes(t, plan: spec.plans[t.id])
        }
        if verified > 0 { s.append((.verifyBits, verified / 500_000_000 + 2)) }
        let audios = spec.tracks.filter { $0.kind == .audio }.count
        if spec.reference != nil && audios > 0 { s.append((.sync, Double(audios) * 12)) }
        if spec.pictureCheck && audios > 0 { s.append((.picture, 25 + Double(audios) * 12)) }
        s.append((.academy, 8))
        return s
    }

    /// The stage a progress text belongs to, when the engine gives only text
    static func stage(of t: String, phase: DeliveryRun.Phase) -> JobProgress.Stage? {
        switch phase {
        case .step1:
            if t.hasPrefix("Pass 1 of 2") { return .pass1 }
            if t.hasPrefix("Pass 2 of 2") { return .pass2 }
            if t.hasPrefix("Encoding") { return .transcodeVideo }
            if t.hasPrefix("Checking") || t.hasPrefix("Render QC") { return .checkResult }
            return nil
        case .audio: return .transcodeAudio
        case .mux:
            if t.contains("metadata back") || t.hasPrefix("Checking the encoded picture") { return .verifyPicture }
            if t.hasPrefix("Reading the Dolby Vision") { return .readMetadata }
            if t.hasPrefix("Pass 1 of 2") { return .pass1 }
            if t.hasPrefix("Pass 2 of 2") { return .pass2 }
            if t.hasPrefix("Encoding the picture") { return .encode }
            if t.hasPrefix("Adding the HDR10+") { return .injectHDR10Plus }
            if t.hasPrefix("Adding the Dolby Vision") { return .injectDV }
            if t.hasPrefix("Interleaving") { return .interleave }
            if t.hasPrefix("Trimming") || t.hasPrefix("Reordering") { return .trim }
            if t.hasPrefix("MP4Box") { return .mux }
            if t.hasPrefix("Copying the streams into Matroska") { return .mkv }
            if t.hasPrefix("Writing headers") { return .headers }
            if t.hasPrefix("Verifying bit for bit") { return .verifyBits }
            if t.hasPrefix("Checking sync") { return .sync }
            if t.hasPrefix("Checking the sound against the picture") { return .picture }
            if t.hasPrefix("Checking the final file against the Academy") { return .academy }
            return nil
        case .after:
            if t.hasPrefix("Render QC") { return .renderQC }
            if t.hasPrefix("Writing the report") { return .finalize }
            return .checkResult
        }
    }

    /// "…: frame 1,234 of 5,678 · 11.4 fps · …" (Transcode.encode's text)
    static func frameNumbers(_ t: String) -> (frame: Int, total: Int, fps: Double)? {
        guard let r = t.range(of: #"frame ([\d,]+) of ([\d,]+) · ([\d.]+) fps"#, options: .regularExpression) else { return nil }
        let parts = t[r].split(separator: " ")
        guard parts.count >= 5, let f = Int(parts[1].replacingOccurrences(of: ",", with: "")), let n = Int(parts[3].replacingOccurrences(of: ",", with: "")), let fps = Double(parts[5]) else { return nil }
        return (f, n, fps)
    }
}

// MARK: - The run

struct DeliveryOutcome {
    var state: DeliveryState
    var lines: [String]
    var output: URL?
    var inspection: InspectionData?
    var qc: RenderQC.Report?
    var qcLine: String?
    var steps: [(title: String, command: String?, lines: [String])]
    var started: Date
    var seconds: Double
}

/// Runs one prepared Delivery: [step 1: the picture transcoded] → [the audio transcoded] → the bit-exact mux →
/// the checks of what was transcoded → Render QC. Blocking: call it off the main thread.
final class DeliveryRun {
    enum Phase { case step1, audio, mux, after }
    let x: DeliveryExecution
    let cancel = CancelFlag()
    var onStage: (String, Double, Phase) -> Void = { _, _, _ in }
    var onProgress: (JobProgress, Phase) -> Void = { _, _ in }
    var onFinding: (String) -> Void = { _ in }
    var onLog: (String) -> Void = { _ in }
    var onWorkFolder: (URL) -> Void = { _ in }
    private let lock = NSLock()
    private var mux: JobRunner?
    private var transcoder: TranscodeRunner?

    init(_ x: DeliveryExecution) { self.x = x }

    func requestCancel() {
        cancel.set()
        lock.lock(); let m = mux, t = transcoder; lock.unlock()
        m?.requestCancel(); t?.requestCancel()
    }

    func run() -> DeliveryOutcome {
        let started = Date()
        let fm = FileManager.default
        var steps: [(title: String, command: String?, lines: [String])] = []
        func end(_ state: DeliveryState, _ lines: [String], output: URL? = nil, inspection: InspectionData? = nil, qc: RenderQC.Report? = nil, qcLine: String? = nil) -> DeliveryOutcome {
            DeliveryOutcome(state: state, lines: lines, output: output, inspection: inspection, qc: qc, qcLine: qcLine, steps: steps, started: started, seconds: Date().timeIntervalSince(started))
        }
        let cancelled = { end(.cancelled, ["Cancelled — nothing was written to the destination."]) }
        var spec = x.spec
        let dir = x.output.deletingLastPathComponent()

        // our own work folder on the destination drive (the step-1 picture, the transcoded audio), gone on any exit;
        // a .lock with our pid keeps another BROS-MUX's clean-up away while it is in use
        var work: URL?
        var keepAlive: DispatchSourceTimer?
        if x.step1 != nil || !x.audioSteps.isEmpty {
            let w = dir.appendingPathComponent(".BROS-MUX-tmp-\(UUID().uuidString)", isDirectory: true)
            do { try fm.createDirectory(at: w, withIntermediateDirectories: false) }
            catch { return end(.failed, ["Couldn't create the temporary folder: \(error.localizedDescription)"]) }
            try? "\(getpid())\n".write(to: w.appendingPathComponent(".lock"), atomically: true, encoding: .utf8)
            let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            t.schedule(deadline: .now() + 600, repeating: 600)
            t.setEventHandler {
                try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: w.path)
                try? fm.setAttributes([.modificationDate: Date()], ofItemAtPath: w.appendingPathComponent(".lock").path)
            }
            t.resume()
            keepAlive = t
            work = w
            onWorkFolder(w)
        }
        defer {
            keepAlive?.cancel()
            if let work { try? fm.removeItem(at: work) }
        }

        // 1. the picture, transcoded on its own (no audio), then muxed like any copied picture
        var pictureLine: String?
        if let plan = x.step1, let work {
            if cancel.isSet { return cancelled() }
            var p = plan; p.audio = .none; p.container = .mov
            let made = work.appendingPathComponent("video.mov")
            let r = TranscodeRunner(plan: p, output: made, runQC: false, runVMAF: false)
            r.onStage = { [weak self] s, f in self?.onStage(s, f, .step1) }
            r.onLog = { [weak self] in self?.onLog($0) }
            r.onProgress = { [weak self] pr in self?.onProgress(pr, .step1) }
            r.onFinding = { [weak self] in self?.onFinding($0) }
            r.onWorkFolder = { [weak self] in self?.onWorkFolder($0) }
            lock.lock(); transcoder = r; lock.unlock()
            if cancel.isSet { return cancelled() }
            let res = r.run()
            lock.lock(); transcoder = nil; lock.unlock()
            if res.state == .cancelled || cancel.isSet { return cancelled() }
            steps.append(("The picture, transcoded (\(p.source.codecName) → \(p.outputCodecName))",
                          "ffmpeg " + DeliveryEngine.quote(Transcode.arguments(p, concat: nil, output: made, elementary: false)), res.lines))
            guard res.state != .failed, let file = res.output else {
                return end(.failed, ["Step 1 — the transcode of the picture — failed; nothing was written to the destination:"] + res.lines)
            }
            guard var v = Probe.tracks(for: file).tracks.first(where: { $0.kind == .video }), let i = spec.tracks.firstIndex(where: { $0.kind == .video }) else {
                return end(.failed, ["Step 1 made a picture that can't be read back (\(file.lastPathComponent)); nothing was written to the destination."])
            }
            let original = spec.tracks[i]
            v.include = true; v.title = original.title; v.language = original.language; v.enabled = original.enabled
            spec.tracks[i] = v
            spec.verifyVideo = true; spec.fixColorTag = false; spec.videoEncode = nil
            pictureLine = "Picture: TRANSCODED in step 1 (\(p.source.codecName) → \(p.outputCodecName)), then copied bit for bit into the final file"
        }

        // 2. the audio to transcode, from the very bytes the mux would have copied (trim and channel order applied)
        var transcoded: [(original: Track, made: Track, step: DeliveryAudioStep)] = []
        for (n, a) in x.audioSteps.enumerated() {
            if cancel.isSet { return cancelled() }
            guard let work else { break }
            let what = DeliveryReport.audioRole(a.track, a.to)
            do {
                let url = try AudioTranscode.prepare(a.track, plan: a.plan, to: a.to, folder: work, index: n, cancel: cancel) { [weak self] p in
                    self?.onStage("Transcoding “\(a.track.title)” → \(what) (\(n + 1) of \(self?.x.audioSteps.count ?? 0))…", p, .audio)
                }
                guard var t = Probe.tracks(for: url).tracks.first(where: { $0.kind == .audio }) else {
                    return end(.failed, ["“\(a.track.title)”: the transcoded audio can't be read back; nothing was written to the destination."])
                }
                t.include = true; t.title = a.track.title; t.language = a.track.language; t.enabled = a.track.enabled
                t.channelMap = a.track.channelMap
                t.channelRoles = a.track.channelPermutation != nil ? a.track.channelTarget?.roles : a.track.channelRoles
                t.channelTarget = nil
                t.delivery = .copy
                spec.plans[a.track.id] = nil
                spec.tracks[a.index] = t
                transcoded.append((a.track, t, a))
                let line = "“\(a.track.title)”: TRANSCODED → \(what) in a step before the mux (from \(a.track.codecName) \(Probe.channelText(a.track.channels, a.track.channelLayout))) — level, channels, order and sync unchanged, checked after writing"
                steps.append(("Audio · “\(a.track.title)” → \(what)", nil, [line]))
                onFinding(line)
            } catch is Cancelled {
                return cancelled()
            } catch {
                return end(.failed, ["“\(a.track.title)” couldn't be transcoded to \(what): \(error.localizedDescription) — nothing was written to the destination."])
            }
        }
        if let bad = spec.tracks.first(where: { $0.kind == .audio && $0.delivery != .copy }) {
            return end(.failed, ["“\(bad.title)” would reach the mux as \(bad.delivery.label) — the mux only copies. Nothing was written."])
        }

        // 3. the bit-exact mux
        if cancel.isSet { return cancelled() }
        let r = JobRunner(spec)
        r.onStage = { [weak self] s, f in self?.onStage(s, f, .mux) }
        r.onLog = { [weak self] in self?.onLog($0) }
        r.onProgress = { [weak self] p in self?.onProgress(p, .mux) }
        r.onFinding = { [weak self] in self?.onFinding($0) }
        r.onWorkFolder = { [weak self] in self?.onWorkFolder($0) }
        lock.lock(); mux = r; lock.unlock()
        if cancel.isSet { return cancelled() }
        let res = r.run()
        lock.lock(); mux = nil; lock.unlock()
        if res.state == .cancelled || cancel.isSet { return cancelled() }
        var lines = res.lines
        // what the engine says, said for what it was: the step-1 picture and the transcoded audio are copies of what step 1 made
        if let pictureLine, let i = lines.firstIndex(where: { $0.hasPrefix("Picture: bit-exact copy") }) { lines[i] = pictureLine }
        for i in lines.indices {
            if pictureLine != nil, lines[i].hasPrefix("Video “"), lines[i].contains(": bit-identical ✓") {
                lines[i] = lines[i].replacingOccurrences(of: ": bit-identical ✓", with: ": bit-identical to the picture made in step 1 ✓")
            }
            for t in transcoded where lines[i].hasPrefix("Audio “\(t.original.title)”: bit-identical ✓") {
                lines[i] = "Audio “\(t.original.title)”: identical to the \(t.step.to == .aac ? "AAC" : "PCM 24-bit") made in step 1" + (t.step.to == .aac ? " (the AAC itself is lossy)" : "") + " ✓"
            }
        }
        steps.append(("The mux (every track copied bit for bit)", x.muxCommand, lines))
        lines.forEach(onFinding)
        guard let out = res.output else { return end(.failed, lines) }
        var ok = res.state != .failed, warn = res.state == .warning
        var after: [String] = []

        // 4. the checks of what was transcoded, on the final file
        if let plan = x.step1 {
            onStage("Checking the final file (frames, colour, timecode)…", 0, .after)
            let mi = MediaInfo.tracks(out)
            let streams = Probe.raw(out)?.streams ?? []
            if let v = mi.first(where: { $0.type == "Video" }), let vs = streams.first(where: { $0.codec_type == "video" && $0.disposition?["attached_pic"] != 1 }) {
                let frames = Int(v["FrameCount"] ?? "") ?? Int(vs.nb_frames ?? "") ?? -1
                let fOK = frames == plan.frames
                after.append("Frames in the final file: \(Fmt.int(frames)) (source \(Fmt.int(plan.frames))) \(fOK ? "✓" : "✗")")
                if !fOK { ok = false }
                var cOK = true
                after += Transcode.colourLines(v, expected: plan.outputColor, ok: &cOK)
                if !cOK { ok = false }
                if x.spec.isMKV {
                    after.append("Timecode: MKV has no timecode track")
                } else {
                    let tcs = streams.filter { $0.codec_type == "data" && $0.codec_tag_string == "tmcd" }
                    let tc = tcs.first?.tags?["timecode"] ?? vs.tags?["timecode"]
                    let wanted = x.spec.tracks.contains { $0.kind == .timecode } ? plan.source.timecode : nil
                    if tcs.count > 1 { after.append("Timecode: \(tcs.count) timecode tracks in the final file — only the source's should be there ✗"); ok = false }
                    else if let want = wanted {
                        let same = tc == want
                        after.append("Timecode: \(tc ?? "none") (source \(want)), one track \(same ? "✓" : "✗")"); if !same { ok = false }
                    } else { after.append("Timecode: \(tcs.isEmpty ? "none, as in the source" : "\(tc ?? "?") — the source has none ⚠")"); if !tcs.isEmpty { warn = true } }
                }
            } else { after.append("Couldn't read the picture back from the final file ✗"); ok = false }
            onStage("Checking the final file (frames, colour, timecode)…", 1, .after)
        }
        let audioOrdinals = spec.tracks.indices.filter { spec.tracks[$0].kind == .audio }
        for (n, t) in transcoded.enumerated() {
            if cancel.isSet { return cancelled() }
            onStage("Checking “\(t.original.title)” after the transcode (\(n + 1) of \(transcoded.count))…", Double(n) / Double(max(transcoded.count, 1)), .after)
            let ord = audioOrdinals.firstIndex(of: t.step.index) ?? 0
            let v = AudioTranscode.verify(final: out, audioOrdinal: ord, source: t.original, plan: t.step.plan, to: t.step.to)
            if v.isEmpty { after.append("⚠ “\(t.original.title)”: the transcoded audio couldn't be checked against the source"); warn = true }
            after += v
            if v.contains(where: { $0.contains("✗") }) { ok = false }
        }
        after.forEach(onFinding)

        // 5. Render QC, a stage of every job
        if cancel.isSet { return cancelled() }
        onStage("Render QC: reading every frame of the final file…", 0, .after)
        let rep = RenderQC.run(url: out, cancel: cancel, sync: !spec.pictureCheck) { [weak self] s, p in self?.onStage("Render QC: " + s, p, .after) }
        if cancel.isSet { return cancelled() }
        var qcLine: String?
        if let rep {
            if rep.findings.isEmpty { qcLine = "Render QC: no render faults found in \(Fmt.int(rep.framesAnalysed)) frames ✓" }
            else {
                qcLine = "Render QC: \(rep.errors) error(s), \(rep.warnings) warning(s), \(rep.findings.count - rep.errors - rep.warnings) note(s) in \(Fmt.int(rep.framesAnalysed)) frames" + (rep.errors > 0 ? " ✗" : rep.warnings > 0 ? " ⚠" : "")
                if rep.errors > 0 { ok = false } else if rep.warnings > 0 { warn = true }
            }
            after.append(qcLine!)
            onFinding(qcLine!)
            for f in rep.findings.prefix(8) {
                let l = "   \(f.severity == .error ? "ERROR" : f.severity == .warning ? "warning" : "note") \(RenderQC.timecode(frame: f.frame, fps: rep.info.fps, start: rep.info.startTimecode)) \(f.kind.rawValue): \(f.detail)"
                after.append(l); onFinding(l)
            }
        } else { qcLine = "⚠ Render QC couldn't read the final file"; after.append(qcLine!); onFinding(qcLine!); warn = true }
        if !after.isEmpty { steps.append(("After writing", nil, after)) }

        let state: DeliveryState = !ok ? .failed : warn ? .warning : .done
        return end(state, lines + after, output: out, inspection: res.inspection, qc: rep, qcLine: qcLine)
    }
}

// MARK: - The report

enum DeliveryReport {
    /// "AAC 640 Kbps" / "AAC 256 Kbps" / "PCM 24-bit"
    static func audioRole(_ t: Track, _ to: AudioDelivery) -> String {
        switch to {
        case .aac: return "AAC \(t.channels > 2 ? 640 : 256) Kbps"
        case .pcm24: return "PCM 24-bit"
        case .copy: return "COPY · bit-exact"
        }
    }

    static func role(_ t: Track, in x: DeliveryExecution) -> String {
        let ref = x.referenceID == t.id
        if !t.include { return ref ? "SYNC REFERENCE · not in the file" : "not in the file" }
        if t.kind == .audio && t.delivery != .copy { return "TRANSCODED → \(audioRole(t, t.delivery)) (step 1)" + (ref ? " · SYNC REFERENCE" : "") }
        if t.kind == .video {
            if let p = x.step1 { return "TRANSCODED → \(p.outputCodecName) (step 1), then MUXED" }
            if let e = x.spec.videoEncode { return "RE-ENCODED (= transcode) → \(e.outputCodecName) · \(e.formats)" }
        }
        return ref ? "MUXED · SYNC REFERENCE" : "MUXED"
    }

    /// "HOW THIS FILE WAS MADE": every step and every command, written next to the file
    static func text(_ x: DeliveryExecution, _ o: DeliveryOutcome, jobFile: URL?) -> String {
        var s = "=== HOW THIS FILE WAS MADE (\(AppInfo.name)) ===\n"
        s += "Output: \(o.output?.path ?? x.output.path + " (not written)")\n"
        s += "Made: \(Date().formatted(date: .abbreviated, time: .standard)) · \(Fmt.hm(o.seconds)) · result: \(o.state.rawValue.uppercased())\n"
        s += "Job: \(x.job.name) · \(x.job.id.uuidString)" + (jobFile.map { " · \($0.path)" } ?? "") + "\n\n"
        s += "WHAT THIS DELIVERY DID\n• \(x.pictureText)\n"
        for t in x.spec.tracks where t.kind == .audio {
            s += "• Audio “\(t.title)”: " + (t.delivery == .copy ? "COPY · bit-exact" : "TRANSCODE → \(audioRole(t, t.delivery)) — level, channels, order and sync unchanged") + "\n"
        }
        s += "\nSOURCES AND WHERE EACH WENT\n"
        for t in x.tracks {
            s += "• [\(role(t, in: x))] \(t.kind.label): \(t.codecName) · \(t.details) · from \(t.url.path) (\(t.sourceLabel))\n"
        }
        s += "\nFINGERPRINTS (the job refused to run if a source had changed)\n"
        for f in x.job.sources { s += "• \(f.path) · \(Fmt.int(Int(f.size))) bytes · \(DeliveryJob.stamp(f.modified))\n" }
        if !x.alignLines.isEmpty { s += "\nSYNC ALIGNMENT (measured against the reference)\n" + x.alignLines.map { "• " + $0 }.joined(separator: "\n") + "\n" }
        for (n, st) in o.steps.enumerated() {
            s += "\nSTEP \(n + 1) · \(st.title.uppercased())\n"
            if let c = st.command { s += "Command: \(c)\n" }
            s += st.lines.map { "• " + $0.replacingOccurrences(of: "Picture: RE-ENCODED (", with: "Picture: RE-ENCODED (= transcode) (") }.joined(separator: "\n") + "\n"
        }
        s += "\nCOMMANDS (for reference)\n\(x.commandPreview)\n\n"
        if let out = o.output, let insp = o.inspection { s += Inspection.textReport(out, insp) }
        return s
    }
}

// MARK: - The worker's files

/// Writes what the window follows while a job renders: progress.json (1–4 Hz, atomic), info.json (the stages and
/// their times), history.csv (frames over time, for the fps), findings.log
final class DeliveryProgressWriter {
    let id: UUID
    private let lock = NSLock()
    private var info: DeliveryWorkerInfo
    private var stageIndex = 0
    private var stageFraction = 0.0
    private var overall = 0.0
    private var title = "Starting…"
    private var frame: Int?, total: Int?, fps: Double?, bitrate: Double?
    private var bytesWritten: Int64?
    private var lastEngineProgress = Date.distantPast
    private var lastWrite = Date.distantPast
    private var lastHistory = Date.distantPast
    private var findings: Set<String> = []
    private var heartbeat: DispatchSourceTimer?
    private var dirty = true
    private let started = Date()
    private var watched: [URL] = []
    private let outputFolder: URL

    init(_ x: DeliveryExecution, label: String?) {
        id = x.job.id
        outputFolder = x.output.deletingLastPathComponent()
        let plan = DeliveryEngine.plannedStages(x)
        let v = x.tracks.first { $0.kind == .video && $0.include }
        let segs: [DeliveryWorkerInfo.Segment] = x.spec.videoEncode?.segments.map { .init(file: $0.file.path, start: $0.start, count: $0.count) }
            ?? x.step1?.segments.map { .init(file: $0.file.path, start: $0.start, count: $0.count) } ?? []
        info = DeliveryWorkerInfo(id: x.job.id, pid: getpid(), label: label, name: x.job.name, output: x.output.path, workFolder: nil, started: started,
                                  picture: v?.url.path, pictureIndex: v?.streamIndex ?? 0, fps: x.fps, frames: x.frames, startTimecode: x.startTimecode,
                                  segments: segs, encodes: x.step1 != nil || x.spec.videoEncode != nil, bytesTotal: Int64(x.estimatedBytes),
                                  stages: plan.map { .init(stage: $0.stage, title: $0.title, weight: $0.weight, started: nil, ended: nil) })
        if !info.stages.isEmpty { info.stages[0].started = started }
        try? DeliveryPaths.ensure(id)
        try? FileManager.default.removeItem(at: DeliveryPaths.findings(id))
        try? FileManager.default.removeItem(at: DeliveryPaths.history(id))
        try? FileManager.default.removeItem(at: DeliveryPaths.result(id))
        DeliveryPaths.writeJSON(info, to: DeliveryPaths.info(id))
        write(force: true)
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in self?.beat() }
        t.resume()
        heartbeat = t
    }

    func stop() { heartbeat?.cancel(); heartbeat = nil }

    /// Text progress from a runner (onStage)
    func stage(_ text: String, _ fraction: Double, _ phase: DeliveryRun.Phase) {
        lock.lock(); defer { lock.unlock() }
        title = text.hasSuffix("…") ? String(text.dropLast()) : text
        if phase == .step1 && !title.hasPrefix("Step 1") { title = "Step 1 · " + title }
        if Date().timeIntervalSince(lastEngineProgress) > 2 {
            if let st = DeliveryEngine.stage(of: text, phase: phase) { advance(to: st) }
            stageFraction = max(0, min(1, fraction))
            if let n = DeliveryEngine.frameNumbers(text) { frame = n.frame; total = n.total; fps = n.fps }
            else if !isEncodeStage { frame = nil; total = nil; fps = nil }
        }
        recompute()
    }

    /// Structured progress from a runner (onProgress, when the engine gives it)
    func progress(_ p: JobProgress, _ phase: DeliveryRun.Phase) {
        lock.lock(); defer { lock.unlock() }
        lastEngineProgress = Date()
        advance(to: p.stage)
        stageFraction = max(0, min(1, p.fraction))
        if !p.title.isEmpty { title = phase == .step1 && !p.title.hasPrefix("Step 1") ? "Step 1 · " + p.title : p.title }
        frame = p.frame; total = p.totalFrames; fps = p.fps; bitrate = p.bitrateKbps
        if let b = p.outBytes { bytesWritten = b }
        recompute()
    }

    func finding(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        guard !line.isEmpty, findings.insert(line).inserted else { return }
        append(line + "\n", to: DeliveryPaths.findings(id))
    }

    func workFolder(_ u: URL) {
        lock.lock(); defer { lock.unlock() }
        watched.append(u)
        info.workFolder = u.path
        DeliveryPaths.writeJSON(info, to: DeliveryPaths.info(id))
    }

    func finish(_ o: DeliveryOutcome) {
        lock.lock()
        for l in o.lines where findings.insert(l).inserted { append(l + "\n", to: DeliveryPaths.findings(id)) }
        let now = Date()
        for i in info.stages.indices where info.stages[i].ended == nil && info.stages[i].started != nil { info.stages[i].ended = now }
        if o.state == .done || o.state == .warning { stageIndex = max(0, info.stages.count - 1); stageFraction = 1; overall = 1 }
        DeliveryPaths.writeJSON(info, to: DeliveryPaths.info(id))
        lock.unlock()
        write(force: true)
        stop()
    }

    // MARK: inside the lock

    private var isEncodeStage: Bool {
        guard stageIndex < info.stages.count else { return false }
        return [.pass1, .pass2, .encode, .transcodeVideo].contains(info.stages[stageIndex].stage)
    }

    private func advance(to st: JobProgress.Stage) {
        guard let j = info.stages.indices.first(where: { $0 >= stageIndex && info.stages[$0].stage == st }), j != stageIndex else { return }
        let now = Date()
        for k in stageIndex..<j {
            if info.stages[k].started == nil { info.stages[k].started = now }
            info.stages[k].ended = now
        }
        stageIndex = j
        info.stages[j].started = now
        stageFraction = 0
        frame = nil; total = nil; fps = nil; bitrate = nil
        DeliveryPaths.writeJSON(info, to: DeliveryPaths.info(id))
    }

    private func recompute() {
        let w = info.stages.map(\.weight)
        let sum = max(w.reduce(0, +), 0.001)
        let done = w.prefix(stageIndex).reduce(0, +)
        let cur = stageIndex < w.count ? w[stageIndex] * stageFraction : 0
        overall = max(overall, min(0.999, (done + cur) / sum))      // never goes back
        dirty = true
        if Date().timeIntervalSince(lastWrite) >= 0.25 { writeLocked() }
    }

    private func snapshot() -> DeliverySnapshot {
        DeliverySnapshot(stage: stageIndex < info.stages.count ? info.stages[stageIndex].stage : nil, title: title, stageFraction: stageFraction, overall: overall,
                         frame: frame, totalFrames: total, fpsAverage: fps, bitrateKbps: bitrate,
                         bytesWritten: bytesWritten, bytesTotal: info.bytesTotal, stageIndex: stageIndex, stageCount: info.stages.count,
                         stagesDone: Array(info.stages.prefix(stageIndex).map(\.stage)), started: started, updated: Date())
    }

    private func writeLocked() {
        DeliveryPaths.writeJSON(snapshot(), to: DeliveryPaths.progress(id))
        lastWrite = Date(); dirty = false
        if let f = frame, Date().timeIntervalSince(lastHistory) >= 5 {
            lastHistory = Date()
            let st = stageIndex < info.stages.count ? info.stages[stageIndex].stage.rawValue : ""
            append(String(format: "%.3f,%d,%@\n", Date().timeIntervalSince1970, f, st), to: DeliveryPaths.history(id))
        }
    }

    private func write(force: Bool) {
        lock.lock(); defer { lock.unlock() }
        if force || dirty { writeLocked() }
    }

    /// once a second: what was written so far (the temporary folders on the destination drive), and the heartbeat
    private func beat() {
        let bytes = currentBytes()
        lock.lock()
        if let bytes, lastEngineProgress.timeIntervalSinceNow < -2 || bytesWritten == nil { bytesWritten = bytes }
        writeLocked()
        lock.unlock()
    }

    private func currentBytes() -> Int64? {
        let fm = FileManager.default
        let dir = outputFolder
        // the newest temporary folder made since the job started is the one being written
        let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey], options: [])) ?? []
        let temps = items.filter { $0.lastPathComponent.hasPrefix(".BROS-MUX-tmp-") }
            .compactMap { u -> (URL, Date)? in (try? u.resourceValues(forKeys: [.creationDateKey]).creationDate).map { (u, $0) } }
            .filter { $0.1 >= started.addingTimeInterval(-2) }
        guard let newest = temps.max(by: { $0.1 < $1.1 }) else { return nil }
        return Int64(SystemMonitor.folderBytes(newest.0))
    }

    private func append(_ s: String, to url: URL) {
        let d = Data(s.utf8)
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(d); try? h.close() }
        else { try? d.write(to: url) }
    }
}

// MARK: - The detached worker: --job-file

/// --job-file A.bmjob [B.bmjob…] [--dry-run]: rebuilds each job from its file, checks it, and runs it
/// (also: --job-file --capture OUT.bmjob <the --job arguments> saves a job made from the command line)
enum DeliveryCLI {
    static func run(_ args: [String]) -> Int32 {
        setvbuf(stdout, nil, _IOLBF, 0)
        if args.first == "--capture" { return capture(Array(args.dropFirst())) }
        var files: [String] = [], dry = false, detached = false, label: String?
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--dry-run": dry = true
            case "--detached": detached = true
            case "--label": i += 1; label = i < args.count ? args[i] : nil
            default: if !args[i].hasPrefix("--") { files.append(args[i]) }
            }
            i += 1
        }
        guard !files.isEmpty else {
            print("usage: --job-file A.bmjob [B.bmjob…] [--dry-run]   ·   --job-file --capture OUT.bmjob -o DEST.mov [--video V] [--add A]… (the --job arguments)")
            return 2
        }
        // the window's queue: every job of this worker says who runs it, before the first one starts
        if detached {
            for f in files { if let j = try? DeliveryJob.load(URL(fileURLWithPath: f)) { try? DeliveryPaths.ensure(j.id); try? "\(getpid())\n".write(to: DeliveryPaths.pid(j.id), atomically: true, encoding: .utf8) } }
        }
        var code: Int32 = 0
        for f in files {
            let c = runOne(URL(fileURLWithPath: f), dry: dry, detached: detached, label: label)
            code = max(code, c)
        }
        if detached, let label {
            // run once: take the job out of launchd now that it's over (KeepAlive is off, this only tidies the list)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            p.arguments = ["bootout", "gui/\(getuid())/\(label)"]
            try? p.run()
            Thread.sleep(forTimeInterval: 2)
        }
        return code
    }

    static func symbol(_ l: CheckLevel) -> String { switch l { case .ok: return "✓"; case .warn: return "⚠"; case .fail: return "✕"; case .info: return "·" } }

    static func runOne(_ url: URL, dry: Bool, detached: Bool, label: String?) -> Int32 {
        print("\nJOB FILE: \(url.path)")
        let job: DeliveryJob
        do { job = try DeliveryJob.load(url) } catch { print("ERROR:", error.localizedDescription); return 2 }
        print("JOB: \(job.name) · \(job.id.uuidString) · saved \(DeliveryJob.stamp(job.created)) by \(job.app)")
        let id = job.id
        func fail(_ lines: [String], _ state: DeliveryState = .failed) {
            guard !dry else { return }
            try? DeliveryPaths.ensure(id)
            DeliveryPaths.writeJSON(DeliveryResultFile(id: id, state: state, lines: lines, output: nil, academy: nil, zidoo: nil, academyChecks: [], zidooChecks: [],
                                                       renderQC: nil, seconds: 0, report: nil, finished: Date()), to: DeliveryPaths.result(id))
        }
        if detached {
            // run once: a job already finished is never run again, a job cancelled while it waited is skipped
            if FileManager.default.fileExists(atPath: DeliveryPaths.result(id).path) { print("Already finished (\(DeliveryPaths.result(id).path)) — not run again."); return 0 }
            if FileManager.default.fileExists(atPath: DeliveryPaths.cancel(id).path) { print("Cancelled before it started."); fail(["Cancelled before it started — nothing was written."], .cancelled); return 1 }
        }
        let project = Project()
        let warnings: [String]
        do { warnings = try job.rebuild(into: project) } catch {
            let m = error.localizedDescription
            print(m)
            fail([m])
            return m.hasPrefix("SOURCE CHANGED") ? 3 : 1
        }
        warnings.forEach { print("NOTE:", $0) }
        let checks = DeliveryEngine.preflight(project, overwrite: job.overwrite)
        print("\nBEFORE YOU START:")
        checks.forEach { print("  \(symbol($0.level)) \($0.text)") }
        let blockers = checks.filter { $0.level == .fail }
        if dry {
            print("\nCANONICAL:\n" + DeliveryJob.canonicalText(project))
            print("\nCOMMAND: \(project.commandPreview)\n")
            return blockers.isEmpty ? 0 : 1
        }
        guard blockers.isEmpty else {
            print("\nCan't start: \(blockers.count) to fix.")
            fail(["Can't start:"] + blockers.map(\.text))
            return 1
        }
        guard let x = DeliveryEngine.prepare(project, job: job) else { print("No destination."); fail(["No destination."]); return 1 }
        print("\nCOMMAND: \(project.commandPreview)\n")
        if x.output != project.outputURL { print("NOTE: \(project.outputURL?.lastPathComponent ?? "") exists — writing \(x.output.lastPathComponent) (keep both)") }

        let writer = DeliveryProgressWriter(x, label: label)
        let run = DeliveryRun(x)
        var lastPrint = Date.distantPast
        let printLock = NSLock()
        run.onStage = { s, p, phase in
            writer.stage(s, p, phase)
            printLock.lock(); defer { printLock.unlock() }
            if Date().timeIntervalSince(lastPrint) > 10 { print(String(format: "  … %@ %3.0f%%", s, max(0, p) * 100)); lastPrint = Date() }
        }
        run.onProgress = { p, phase in writer.progress(p, phase) }
        run.onFinding = { writer.finding($0) }
        run.onWorkFolder = { writer.workFolder($0) }
        // Cancel from the window: a file, looked at every quarter of a second
        let watcher = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        watcher.schedule(deadline: .now() + 0.25, repeating: 0.25)
        watcher.setEventHandler { if FileManager.default.fileExists(atPath: DeliveryPaths.cancel(id).path), !run.cancel.isSet { print("Cancel asked."); run.requestCancel() } }
        watcher.resume()
        let o = run.run()
        watcher.cancel()

        // the report next to the file (and in the job's folder), then the result
        if o.output != nil { writer.stage("Writing the report…", 0, .after) }
        let report = DeliveryReport.text(x, o, jobFile: url)
        var reportPath: String?
        try? report.write(to: DeliveryPaths.report(id), atomically: true, encoding: .utf8)
        if let out = o.output {
            let r = out.deletingLastPathComponent().appendingPathComponent(out.deletingPathExtension().lastPathComponent + "_REPORT.txt")
            if (try? report.write(to: r, atomically: true, encoding: .utf8)) != nil { reportPath = r.path }
        }
        writer.finish(o)
        let insp = o.inspection
        DeliveryPaths.writeJSON(DeliveryResultFile(id: id, state: o.state, lines: o.lines, output: o.output?.path,
                                                   academy: insp?.level?.deliveryKey, zidoo: insp?.zidooLevel?.deliveryKey,
                                                   academyChecks: insp?.checks.filter { $0.level != .ok }.map { "\($0.level.text) \($0.title): \($0.detail)" } ?? [],
                                                   zidooChecks: insp?.zidooChecks.filter { $0.level != .ok }.map { "\($0.level.text) \($0.title): \($0.detail)" } ?? [],
                                                   renderQC: o.qcLine, seconds: o.seconds, report: reportPath ?? DeliveryPaths.report(id).path, finished: Date()),
                                to: DeliveryPaths.result(id))
        print(String(format: "\nRESULT (%.0f s): %@", o.seconds, o.state.rawValue))
        o.lines.forEach { print("  •", $0) }
        if let l = insp?.level { print("\nACADEMY SEAL (verified): \(l.emoji) \(l.title)") }
        if let z = insp?.zidooLevel { print("ZIDOO: \(z.emoji) \(z.title)") }
        if let reportPath { print("\nreport:", reportPath) }
        switch o.state {
        case .done, .warning: return 0
        default: return 1
        }
    }

    /// --capture OUT.bmjob <the --job arguments>: the project the command line builds, saved as a job (the answer to
    /// "use the audio inside the video?" is the command line's own rule: no, it is the sync reference)
    static func capture(_ args: [String]) -> Int32 {
        guard let path = args.first, path.hasSuffix(".bmjob") else { print("usage: --job-file --capture OUT.bmjob -o DEST.mov|mp4|mkv [--video V] [--add A]… (the --job arguments)"); return 2 }
        // capture-only choices the --job arguments can't express: the picture's transcode (--to P), the picture kept as
        // it is although HDR metadata is loaded (--video-copy) and the audio delivery of every included track (--audio-delivery)
        var rest = Array(args.dropFirst()), to: String?, audioDelivery: AudioDelivery?, videoCopy = false
        if let i = rest.firstIndex(of: "--to"), i + 1 < rest.count { to = rest[i + 1]; rest.removeSubrange(i...i + 1) }
        if let i = rest.firstIndex(of: "--audio-delivery"), i + 1 < rest.count { audioDelivery = AudioDelivery(rawValue: rest[i + 1]); rest.removeSubrange(i...i + 1) }
        if let i = rest.firstIndex(of: "--video-copy") { videoCopy = true; rest.remove(at: i) }
        let a = CLIArgs(rest)
        guard let o = a.output else { print("an explicit -o DEST is required"); return 2 }
        let project = buildProject(a, output: o)
        for t in project.embeddedAudio where project.embeddedAudioAnswer[project.key(of: t)] == nil { project.embeddedAudioAnswer[project.key(of: t)] = t.include }
        if project.hdr.encode { project.video.choose(.hevcHDR, project: project) }
        if videoCopy { project.video.choose(.copy, project: project) }
        if let to, let p = TranscodePreset.named(to) { project.video.choose(.transcode(VideoTranscodeSettings(preset: p.rawValue)), project: project) }
        if let audioDelivery { for i in project.tracks.indices where project.tracks[i].kind == .audio && project.tracks[i].include { project.tracks[i].delivery = audioDelivery } }
        let job = DeliveryJob.capture(project)
        let url = URL(fileURLWithPath: path)
        do {
            try job.write(to: url)
            try job.writeText(to: url.deletingPathExtension().appendingPathExtension("job.txt"))
        } catch { print("ERROR:", error.localizedDescription); return 1 }
        print("JOB: \(job.name) · \(job.id.uuidString)")
        print("saved: \(url.path)")
        print("\nCANONICAL:\n" + DeliveryJob.canonicalText(project))
        return 0
    }
}

// MARK: - The window's queue

struct DeliveryRefusal: Equatable {
    var title: String
    var lines: [String]
    var diff: String? = nil
}

@Observable final class DeliveryQueue {
    static let shared = DeliveryQueue()
    var items: [DeliveryItem] = []
    var current: DeliveryItem? { items.first { $0.state == .running } }
    var isRunning: Bool { current != nil }
    var overall: Double? { current?.snapshot?.overall }

    /// "keepBoth" (default) | "replace": what happens to an existing file of the same name
    var overwrite: String = DeliveryQueue.overwriteDefault { didSet { UserDefaults.standard.set(overwrite, forKey: "DeliveryOverwrite") } }
    static var overwriteDefault: String { UserDefaults.standard.string(forKey: "DeliveryOverwrite") ?? "keepBoth" }
    /// What the queue is doing for the window right now ("Checking the job file…")
    var busy: String? = nil
    /// Why START / ADD TO QUEUE / Open refused (shown on the Delivery tab until dismissed)
    var refusal: DeliveryRefusal? = nil
    var saveSheetShown = false
    /// The results, by job (academy / zidoo levels, the report)
    var results: [UUID: DeliveryResultFile] = [:]
    /// Jobs a worker has been launched for, jobs that wait for the current render, jobs that can't start as they are
    var launched: Set<UUID> = []
    var autoStart: Set<UUID> = []
    var blockers: [UUID: [String]] = [:]
    /// The result the person closed on the Delivery tab
    var dismissedResult: UUID? = nil

    @ObservationIgnored private var labels: [UUID: String] = [:]
    @ObservationIgnored private var launchedAt: [UUID: Date] = [:]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var restored = false
    @ObservationIgnored private var demo = false

    static var isSnapshot: Bool { CommandLine.arguments.dropFirst().first == "--snapshot" }

    func preflight(_ project: Project) -> [DeliveryPreflightItem] { DeliveryEngine.preflight(project, overwrite: overwrite) }

    var queued: [DeliveryItem] { items.filter { $0.state == .queued } }
    var finished: [DeliveryItem] { items.filter { [.done, .warning, .failed, .cancelled].contains($0.state) } }
    var lastResult: DeliveryItem? {
        let last = finished.max { (results[$0.id]?.finished ?? .distantPast) < (results[$1.id]?.finished ?? .distantPast) }
        return last.flatMap { $0.id == dismissedResult ? nil : $0 }
    }
    func isWaitingInWorker(_ id: UUID) -> Bool { launched.contains(id) && items.first { $0.id == id }?.state == .queued }

    // MARK: START · ADD TO QUEUE

    func startNow(from project: Project) { submit(project, start: true) }
    func enqueue(from project: Project) { submit(project, start: false) }

    private func submit(_ project: Project, start: Bool) {
        guard busy == nil else { return }
        restoreIfNeeded()
        refusal = nil
        let checks = preflight(project)
        let fails = checks.filter { $0.level == .fail }
        if !fails.isEmpty {
            refusal = DeliveryRefusal(title: "Can't \(start ? "start" : "queue") yet — \(fails.count) to fix", lines: fails.map(\.text))
            return
        }
        let warns = checks.filter { $0.level == .warn }
        if !warns.isEmpty && !Self.isSnapshot {
            let a = NSAlert()
            a.messageText = warns.count == 1 ? "One thing to confirm before you \(start ? "start" : "queue it")" : "\(warns.count) things to confirm before you \(start ? "start" : "queue it")"
            a.informativeText = warns.map { "⚠ " + $0.text }.joined(separator: "\n\n")
            a.addButton(withTitle: start ? "Start Anyway" : "Add Anyway"); a.addButton(withTitle: "Cancel")
            if a.runModal() != .alertFirstButtonReturn { return }
        }
        var captured = DeliveryJob.capture(project)
        captured.overwrite = overwrite
        let job = captured
        let live = DeliveryJob.canonicalText(project)
        let id = job.id
        do {
            try DeliveryPaths.ensure(id)
            try job.write(to: DeliveryPaths.jobFile(id))
            try job.writeText(to: DeliveryPaths.jobText(id))
        } catch {
            refusal = DeliveryRefusal(title: "Couldn't save the job", lines: [error.localizedDescription]); return
        }
        // what the render will use, made from the saved file as the render will: it must say exactly the same
        let hdr = project.hdr
        let dv: (summary: DolbyVisionMeta.Summary?, problem: String?, xml: URL?)? = hdr.dvSource != nil && !hdr.dvChecking ? (hdr.dvSummary, hdr.dvProblem, hdr.dvXMLReady) : nil
        let output = project.outputURL
        busy = "Checking the job file…"
        DispatchQueue.global(qos: .userInitiated).async {
            var problem: String?, diff: String?
            do {
                let saved = try DeliveryJob.load(DeliveryPaths.jobFile(id))
                let scratch = Project()
                var pre = DeliveryJob.Prefetch()
                pre.dolbyVision = dv
                for p in saved.probePaths { pre.probes[p] = Probe.tracks(for: URL(fileURLWithPath: p)) }
                _ = try saved.rebuild(into: scratch, prefetched: pre)
                let rebuilt = DeliveryJob.canonicalText(scratch)
                if rebuilt != live { problem = "The job made from the saved file isn't the same as the window's — nothing was started."; diff = DeliveryDiff.text(live, rebuilt) }
            } catch { problem = error.localizedDescription }
            DispatchQueue.main.async {
                self.busy = nil
                if let problem {
                    self.refusal = DeliveryRefusal(title: "Not started: the saved job doesn't match", lines: [problem], diff: diff)
                    try? FileManager.default.removeItem(at: DeliveryPaths.folder(id))
                    return
                }
                // the job also goes next to the file it makes
                if let out = output {
                    let base = out.deletingLastPathComponent().appendingPathComponent(out.deletingPathExtension().lastPathComponent)
                    let side = DeliveryPaths.unique(base.appendingPathExtension("bmjob"))
                    try? job.write(to: side)
                    try? job.writeText(to: side.deletingPathExtension().appendingPathExtension("job.txt"))
                }
                self.items.append(DeliveryItem(id: id, job: job, jobFile: DeliveryPaths.jobFile(id), state: .queued, snapshot: nil, findings: [], resultLines: [], output: nil))
                if start {
                    if self.isRunning || !self.launched.subtracting(self.finished.map(\.id)).isEmpty { self.autoStart.insert(id) }
                    else { self.launch([id]) }
                }
                self.saveQueue()
            }
        }
    }

    /// Several pictures at once: one job per picture with the window's settings (picture plan, container, checks).
    /// Audio from other files and Dolby Vision / HDR10+ files belong to one film and don't carry over.
    func enqueueBatch(_ pictures: [URL], template project: Project) {
        guard busy == nil, !pictures.isEmpty else { return }
        restoreIfNeeded()
        let t = DeliveryBatchTemplate(project, overwrite: overwrite)
        busy = "Making \(pictures.count) deliveries…"
        DispatchQueue.global(qos: .userInitiated).async {
            var made: [(DeliveryItem, [String])] = []
            var notes: [String] = []
            for pic in pictures {
                let (p, note) = t.project(for: pic)
                if let note { notes.append(note) }
                var job = DeliveryJob.capture(p)
                job.overwrite = t.overwrite
                let fails = DeliveryEngine.preflight(p, overwrite: t.overwrite).filter { $0.level == .fail }.map(\.text)
                do {
                    try DeliveryPaths.ensure(job.id)
                    try job.write(to: DeliveryPaths.jobFile(job.id))
                    try job.writeText(to: DeliveryPaths.jobText(job.id))
                } catch { notes.append("\(pic.lastPathComponent): \(error.localizedDescription)"); continue }
                made.append((DeliveryItem(id: job.id, job: job, jobFile: DeliveryPaths.jobFile(job.id), state: .queued, snapshot: nil, findings: [], resultLines: fails, output: nil), fails))
            }
            DispatchQueue.main.async {
                self.busy = nil
                for (item, fails) in made {
                    self.items.append(item)
                    if !fails.isEmpty { self.blockers[item.id] = fails }
                }
                if !notes.isEmpty { self.refusal = DeliveryRefusal(title: "\(made.count) deliveries added to the queue", lines: notes) }
                self.saveQueue()
            }
        }
    }

    /// Starts every job waiting in the queue, in order, in one render process
    func startQueue() {
        restoreIfNeeded()
        let ids = items.filter { $0.state == .queued && !launched.contains($0.id) && blockers[$0.id] == nil }.map(\.id)
        guard !ids.isEmpty else { return }
        if isRunning { autoStart.formUnion(ids); saveQueue(); return }
        launch(ids)
    }

    func cancel(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        if launched.contains(id) {
            try? Data().write(to: DeliveryPaths.cancel(id))
            if items[i].state == .queued { items[i].state = .cancelled; items[i].resultLines = ["Cancelled before it started — nothing was written."] }
        } else if items[i].state == .queued {
            items[i].state = .cancelled
            items[i].resultLines = ["Cancelled before it started — nothing was written."]
            autoStart.remove(id)
        }
        saveQueue()
    }

    func remove(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].state != .running else { return }
        if launched.contains(id) && items[i].state == .queued { try? Data().write(to: DeliveryPaths.cancel(id)) }
        let wasLaunched = launched.contains(id)
        items.remove(at: i)
        autoStart.remove(id); blockers[id] = nil; results[id] = nil
        if !wasLaunched { try? FileManager.default.removeItem(at: DeliveryPaths.folder(id)) }
        saveQueue()
    }

    // MARK: job files

    func saveWithPanel(from project: Project) {
        let p = NSSavePanel()
        p.allowedContentTypes = [UTType(filenameExtension: "bmjob") ?? .json]
        p.canCreateDirectories = true
        let name = project.outputURL?.deletingPathExtension().lastPathComponent ?? "Delivery"
        p.nameFieldStringValue = name + ".bmjob"
        if let dir = project.outputURL?.deletingLastPathComponent() { p.directoryURL = dir }
        p.message = "Save the job: a .bmjob for BROS-MUX and a readable .job.txt next to it"
        guard p.runModal() == .OK, let u = p.url else { return }
        var job = DeliveryJob.capture(project)
        job.overwrite = overwrite
        do {
            try job.write(to: u)
            try job.writeText(to: u.deletingPathExtension().appendingPathExtension("job.txt"))
            project.post("Job saved: \(u.lastPathComponent) (and \(u.deletingPathExtension().lastPathComponent).job.txt)", tab: .delivery, level: .ok)
        } catch {
            refusal = DeliveryRefusal(title: "Couldn't save the job", lines: [error.localizedDescription])
        }
    }

    /// Opens a .bmjob in the window: the project is rebuilt from it (the heavy reads off the main thread)
    func load(_ url: URL, into project: Project) {
        guard busy == nil else { return }
        if project.busy {
            refusal = DeliveryRefusal(title: "Can't open \(url.lastPathComponent) now", lines: ["The window is still reading files or lining the audio up — open the job again when it's done."])
            return
        }
        busy = "Reading \(url.lastPathComponent)…"
        refusal = nil
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let job = try DeliveryJob.load(url)
                let pre = try job.prefetch()
                DispatchQueue.main.async {
                    self.busy = nil
                    project.clear()
                    do {
                        let warnings = try job.rebuild(into: project, prefetched: pre)
                        project.mode = .delivery
                        project.post("Job “\(job.name)” opened from \(url.lastPathComponent): the window holds it now — check it and START.", tab: .delivery, level: .ok)
                        warnings.forEach { project.post($0, tab: .delivery, level: .warn) }
                    } catch {
                        self.refusal = DeliveryRefusal(title: "Can't open \(url.lastPathComponent)", lines: [error.localizedDescription])
                    }
                }
            } catch {
                DispatchQueue.main.async { self.busy = nil; self.refusal = DeliveryRefusal(title: "Can't open \(url.lastPathComponent)", lines: [error.localizedDescription]) }
            }
        }
    }

    // MARK: the render process

    /// One render process for these jobs, in order, outside the app (launchd, run once: KeepAlive off — never
    /// `launchctl submit`, which starts the program again after it ends), awake while it runs (caffeinate -i)
    private func launch(_ ids: [UUID]) {
        guard let first = ids.first else { return }
        guard let exe = Bundle.main.executablePath else { refusal = DeliveryRefusal(title: "Can't start the render", lines: ["The app's own program wasn't found."]); return }
        let label = "com.abdalabrothers.brosmux.beta.job.\(first.uuidString)"
        let folder = DeliveryPaths.folder(first)
        let plist = folder.appendingPathComponent("launch.plist")
        let files = ids.compactMap { id in items.first { $0.id == id }?.jobFile.path }
        let dict: [String: Any] = [
            "Label": label,
            "ProgramArguments": ["/usr/bin/caffeinate", "-i", exe, "--job-file"] + files + ["--detached", "--label", label],
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Interactive",
            "StandardOutPath": DeliveryPaths.log(first).path,
            "StandardErrorPath": DeliveryPaths.log(first).path,
        ]
        do {
            try DeliveryPaths.ensure(first)
            let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
            try data.write(to: plist, options: .atomic)
        } catch { refusal = DeliveryRefusal(title: "Can't start the render", lines: [error.localizedDescription]); return }
        let r = Tools.runAll("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plist.path])
        guard r.status == 0 else {
            refusal = DeliveryRefusal(title: "Can't start the render", lines: ["launchctl bootstrap ended with code \(r.status): \(r.text.trimmingCharacters(in: .whitespacesAndNewlines))"]); return
        }
        for id in ids { launched.insert(id); labels[id] = label; launchedAt[id] = Date(); autoStart.remove(id) }
        saveQueue()
        startPolling()
    }

    private func startPolling() {
        guard timer == nil, !demo else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }

    /// Reads what the render processes wrote: running → progress; finished → result; gone without a result → failed
    private func poll() {
        var changed = false
        for i in items.indices where launched.contains(items[i].id) && [.queued, .running].contains(items[i].state) {
            let id = items[i].id
            if let r = DeliveryPaths.readJSON(DeliveryResultFile.self, DeliveryPaths.result(id)) {
                items[i].state = r.state; items[i].resultLines = r.lines; items[i].output = r.output.map { URL(fileURLWithPath: $0) }
                items[i].findings = Self.readLines(DeliveryPaths.findings(id))
                results[id] = r
                changed = true
                continue
            }
            let pid = DeliveryPaths.readPID(id)
            let alive = pid.map(DeliveryPaths.alive) ?? false
            if let s = DeliveryPaths.readJSON(DeliverySnapshot.self, DeliveryPaths.progress(id)), alive {
                if items[i].state != .running { items[i].state = .running; changed = true }
                // the window redraws on every change: the queue keeps only what moved (the render page reads the monitor)
                let old = items[i].snapshot
                if old == nil || old!.stageIndex != s.stageIndex || abs(old!.overall - s.overall) >= 0.001 || old!.title != s.title && s.frame == nil { items[i].snapshot = s }
                let f = Self.readLines(DeliveryPaths.findings(id))
                if f != items[i].findings { items[i].findings = f }
            } else if (pid != nil && !alive) || (pid == nil && Date().timeIntervalSince(launchedAt[id] ?? .distantPast) > 60) {
                items[i].state = .failed
                items[i].resultLines = ["The render process stopped before finishing — see \(logFile(id).path)."]
                changed = true
            }
        }
        // the jobs waiting for the render that just ended
        if !isRunning, !autoStart.isEmpty, launched.subtracting(finished.map(\.id)).isEmpty {
            let next = items.filter { autoStart.contains($0.id) && $0.state == .queued }.map(\.id)
            if !next.isEmpty { launch(next) }
        }
        if EffectsGovernor.shared.calm != isRunning { EffectsGovernor.shared.calm = isRunning }
        DeliveryMonitor.shared.follow(current)
        if changed { saveQueue() }
        let open = items.contains { launched.contains($0.id) && [.queued, .running].contains($0.state) }
        if !open { timer?.invalidate(); timer = nil; bootoutFinished() }
    }

    /// The render process's log: in the folder of the first job it was launched for
    func logFile(_ id: UUID) -> URL {
        if let l = labels[id], let first = UUID(uuidString: String(l.split(separator: ".").last ?? "")) { return DeliveryPaths.log(first) }
        return DeliveryPaths.log(id)
    }

    private func bootoutFinished() {
        let done = Set(labels.values)
        for l in done { _ = Tools.runAll("/bin/launchctl", ["bootout", "gui/\(getuid())/\(l)"]) }
        labels = [:]
    }

    static func readLines(_ u: URL) -> [String] {
        ((try? String(contentsOf: u, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    // MARK: queue.json

    private func saveQueue() {
        guard !demo else { return }
        let entries = items.map { DeliveryQueueEntry(id: $0.id, jobFile: $0.jobFile.path, state: $0.state, launched: launched.contains($0.id), label: labels[$0.id],
                                                     autoStart: autoStart.contains($0.id), blockers: blockers[$0.id]) }
        try? FileManager.default.createDirectory(at: DeliveryPaths.jobs, withIntermediateDirectories: true)
        DeliveryPaths.writeJSON(entries, to: DeliveryPaths.queue)
    }

    private func restoreIfNeeded() { if !restored { restoreAtLaunch() } }

    /// The queue as it was: queued jobs wait again; jobs that ran while the app was closed show their result
    func restoreAtLaunch() {
        guard !restored, !demo else { return }
        restored = true
        // a snapshot never shows the person's own queue (QC compares snapshots), unless asked with --restore-queue
        if Self.isSnapshot && !CommandLine.arguments.contains("--restore-queue") { return }
        guard let entries = DeliveryPaths.readJSON([DeliveryQueueEntry].self, DeliveryPaths.queue) else { return }
        for e in entries where !items.contains(where: { $0.id == e.id }) {
            guard let job = try? DeliveryJob.load(URL(fileURLWithPath: e.jobFile)) else { continue }
            var item = DeliveryItem(id: e.id, job: job, jobFile: URL(fileURLWithPath: e.jobFile), state: e.state, snapshot: nil, findings: [], resultLines: e.blockers ?? [], output: nil)
            if let r = DeliveryPaths.readJSON(DeliveryResultFile.self, DeliveryPaths.result(e.id)) {
                item.state = r.state; item.resultLines = r.lines; item.output = r.output.map { URL(fileURLWithPath: $0) }; results[e.id] = r
                item.findings = Self.readLines(DeliveryPaths.findings(e.id))
            } else if e.state == .running && !e.launched { item.state = .queued }
            items.append(item)
            if e.launched { launched.insert(e.id); launchedAt[e.id] = Date(); if let l = e.label { labels[e.id] = l } }
            if e.autoStart { autoStart.insert(e.id) }
            if let b = e.blockers, !b.isEmpty { blockers[e.id] = b }
        }
        if items.contains(where: { launched.contains($0.id) && [.queued, .running].contains($0.state) }) || !autoStart.isEmpty { startPolling() }
    }

    // MARK: demo (snapshots)

    /// A realistic running 2-pass Dolby Vision job (2DIE4-like numbers, about 42 %) for the snapshots
    func loadDemoRunningJob() {
        demo = true
        restored = true
        timer?.invalidate(); timer = nil
        items.removeAll { $0.job.name.hasPrefix("2DIE4") }
        let id = UUID(uuidString: "D3A0D3A0-0000-4000-8000-000000000042")!
        let started = Date().addingTimeInterval(-(2 * 3600 + 5 * 60 + 13) - 3725)
        let job = DeliveryJob(id: id, name: "2DIE4_UHD_DV_HDR", created: started, app: AppInfo.name, sources: [], tracks: [], embeddedAudioAnswer: [:], syncReference: nil,
                              referenceLateFrames: 0, matchVideoEnd: true, verifyAudio: true, verifyVideo: false, fixColorTag: false, writeChannelMap: true,
                              disableExtraAudio: false, interleaveMs: 500, pictureCheck: true,
                              video: .init(choice: "hevcHDR", transcode: nil, dvSource: "/Volumes/A018/2DIE4/2DIE4_UHD_P3D65_PR444_51_20260212.xml", hdr10plusJSON: nil, imf: nil,
                                           dolbyVision: true, hdr10plus: false, quality: "maximum", speed: "slow", rateMode: "average", bitratePreset: "kaleidescapeCinematic",
                                           customMbps: 110, customMaxMbps: 160, qualityFloor: false, convertGamut: true, mastering: "P3-D65;max=1000;min=0.0001", maxCLL: 1000, maxFALL: 400),
                              container: "mkv", output: "/Volumes/A018/H265/2DIE4_UHD_DV_HDR.mkv", overwrite: "keepBoth")
        let total = 129_600, frame = 54_211
        let snap = DeliverySnapshot(stage: .pass2, title: "Pass 2 of 2: encoding the picture (x265 slow, 2-pass average 110 Mbps (peak 160 Mbps))",
                                    stageFraction: Double(frame) / Double(total), overall: 0.42, frame: frame, totalFrames: total, fpsAverage: 4.9, bitrateKbps: 104_200,
                                    bytesWritten: 52_400_000_000, bytesTotal: 118_000_000_000, stageIndex: 2, stageCount: 10,
                                    stagesDone: [.readMetadata, .pass1], started: started, updated: Date())
        let findings = ["Dolby Vision 8.1 metadata: 129,600 frames · 385 shots · L1 + L2 + L5 + L6 + L8 + L9 · CM v4.0",
                        "Picture: HEVC Main 10 4:2:0 PQ / BT.2020 — P3-D65 → BT.2020, converted in linear light",
                        "Pass 1 of 2: 129,600 frames in 2 h 05 min (11.5 fps typical) ✓",
                        "The first ~4,200 frames (black and credits) ran at 38 fps — the average is above the real pace ⚠"]
        items.append(DeliveryItem(id: id, job: job, jobFile: DeliveryPaths.jobFile(id), state: .running, snapshot: snap, findings: findings, resultLines: [], output: nil))
        let q = UUID(uuidString: "D3A0D3A0-0000-4000-8000-000000000043")!
        var next = job
        next.id = q; next.name = "2DIE4_UHD_SDR_PR422HQ"; next.output = "/Volumes/A018/2DIE4/2DIE4_UHD_SDR_PR422HQ.mov"; next.container = "mov"; next.video.choice = "transcode"
        items.append(DeliveryItem(id: q, job: next, jobFile: DeliveryPaths.jobFile(q), state: .queued, snapshot: nil, findings: [], resultLines: [], output: nil))
        launched = [id]
        autoStart = [q]
        EffectsGovernor.shared.calm = true
        DeliveryMonitor.shared.loadDemo(item: items[items.count - 2])
    }
}

/// The window's settings for a batch of pictures (read on the main thread, used off it)
struct DeliveryBatchTemplate {
    var overwrite: String
    var container: Container
    var choice: VideoPlanModel.Choice
    var folder: URL?
    var pictureFolder: URL?
    var suffix: String
    var answers: [Int: Bool]          // embedded audio, by stream index of the template's picture
    var matchVideoEnd, verifyAudio, verifyVideo, fixColorTag, writeChannelMap, disableExtraAudio, pictureCheck: Bool
    var interleaveMs: Int
    var quality: HDRSettings.Quality, speed: HDRSettings.Speed, rateMode: HDRSettings.RateMode, bitratePreset: HDRSettings.BitratePreset
    var customMbps: Int, customMaxMbps: Int, qualityFloor: Bool, convertGamut: Bool
    var hadMetadata: Bool

    init(_ p: Project, overwrite: String) {
        self.overwrite = overwrite
        container = p.container; choice = p.video.choice(p)
        folder = p.outputFolder; pictureFolder = p.videoSource?.url.deletingLastPathComponent()
        let pictureBase = p.videoSource.map { Fmt.academyName($0.url.deletingPathExtension().lastPathComponent) } ?? ""
        let outBase = p.outputURL?.deletingPathExtension().lastPathComponent ?? ""
        suffix = !pictureBase.isEmpty && outBase.hasPrefix(pictureBase) ? String(outBase.dropFirst(pictureBase.count)) : "_MUX"
        var a: [Int: Bool] = [:]
        for t in p.embeddedAudio { if let v = p.embeddedAudioAnswer[p.key(of: t)] { for s in p.key(of: t).streams { a[s] = v } } }
        answers = a
        matchVideoEnd = p.matchVideoEnd; verifyAudio = p.verifyAudio; verifyVideo = p.verifyVideo; fixColorTag = p.fixColorTag
        writeChannelMap = p.writeChannelMap; disableExtraAudio = p.disableExtraAudio; pictureCheck = p.pictureCheck; interleaveMs = p.interleaveMs
        let h = p.hdr
        quality = h.quality; speed = h.speed; rateMode = h.rateMode; bitratePreset = h.bitratePreset
        customMbps = h.customMbps; customMaxMbps = h.customMaxMbps; qualityFloor = h.qualityFloor; convertGamut = h.convertGamut
        hadMetadata = h.dvSource != nil || h.hdr10plusJSON != nil
    }

    /// The project one picture gets: its own streams (its sound answered as in the window, by stream), the window's settings
    func project(for picture: URL) -> (Project, String?) {
        let p = Project()
        let r = Probe.tracks(for: picture)
        p.insert(r.tracks)
        for set in Project.groupSets(p.groupCandidates) { p.makeGroup(set.map(\.id), listen: false) }
        for t in p.embeddedAudio {
            let streams = p.key(of: t).streams
            if let v = streams.compactMap({ answers[$0] }).first { p.setEmbeddedAudio(t.id, use: v) }
        }
        p.matchVideoEnd = matchVideoEnd; p.verifyAudio = verifyAudio; p.verifyVideo = verifyVideo; p.fixColorTag = fixColorTag
        p.writeChannelMap = writeChannelMap; p.disableExtraAudio = disableExtraAudio; p.pictureCheck = pictureCheck; p.interleaveMs = interleaveMs
        let h = p.hdr
        h.quality = quality; h.speed = speed; h.rateMode = rateMode; h.bitratePreset = bitratePreset
        h.customMbps = customMbps; h.customMaxMbps = customMaxMbps; h.qualityFloor = qualityFloor; h.convertGamut = convertGamut
        p.video.choose(choice, project: p)
        if p.container != container { p.container = container }
        let dir = (folder == pictureFolder ? nil : folder) ?? picture.deletingLastPathComponent()
        let base = Fmt.academyName(picture.deletingPathExtension().lastPathComponent) + suffix
        p.setOutput(DeliveryPaths.unique(dir.appendingPathComponent(base).appendingPathExtension(container.rawValue)))
        var note: String? = r.error.map { "\(picture.lastPathComponent): \($0)" }
        if hadMetadata, choice == .hevcHDR { note = (note.map { $0 + " · " } ?? "") + "\(picture.lastPathComponent): HDR10 only — the window's Dolby Vision / HDR10+ file belongs to its own film." }
        return (p, note)
    }
}

/// Lines only in one of two texts (the START refusal)
enum DeliveryDiff {
    static func text(_ a: String, _ b: String) -> String {
        let la = a.components(separatedBy: "\n"), lb = b.components(separatedBy: "\n")
        let sa = Set(la), sb = Set(lb)
        let gone = la.filter { !sb.contains($0) }.prefix(20).map { "− window:  " + $0 }
        let new = lb.filter { !sa.contains($0) }.prefix(20).map { "+ saved:   " + $0 }
        return (gone + new).joined(separator: "\n")
    }
}
