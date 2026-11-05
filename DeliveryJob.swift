// BROS-MUX Beta 2.0.0 — the job file (.bmjob, JSON, schemaVersion 1): everything a Delivery needs, frozen.
// Schema: PLANO-BETA-2.0.0.md ("Arquivo de job"). capture(_:) reads the window's project; rebuild(into:) makes the same
// project again from the files on disk, synchronously and in the plan's order; canonicalText(_:) is what both sides of
// START must agree on; writeText(to:) is the readable .job.txt next to it.

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
        /// A group's members in the group's own order, one key each (file + stream). Optional addition to schema 1:
        /// mono WAV files grouped together live in different files, which `key` alone can't name.
        var members: [StreamKey]? = nil
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

    // MARK: capture

    /// The project as it is now: every source with its fingerprint, every track's identity and settings, the video plan
    static func capture(_ project: Project) -> DeliveryJob {
        let hdr = project.hdr
        var paths: [String] = []
        func add(_ p: String?) { if let p, !p.isEmpty, !paths.contains(p) { paths.append(p) } }
        if let imf = hdr.imf {
            add(imf.cpl.path)
            add(deliveryAssetMap(in: imf.folder)?.path)
            for seq in imf.sequences where seq.kind == .image || seq.kind == .dolbyVision { for r in seq.resources { add(r.file.path) } }
        }
        for t in project.tracks {
            add(t.url.path)
            for m in t.members { add(m.url.path) }
        }
        let dvPath: String?
        switch hdr.dvSource {
        case .xml(let u)?: dvPath = u.path; add(u.path)
        case .isxd(let parts)?: dvPath = parts.first?.file.path; parts.forEach { add($0.file.path) }
        case nil: dvPath = nil
        }
        add(hdr.hdr10plusJSON?.path)

        let choice: String
        switch project.video.choice(project) {
        case .copy: choice = "copy"
        case .hevcHDR: choice = "hevcHDR"
        case .transcode: choice = "transcode"
        }
        let name = project.outputURL?.deletingPathExtension().lastPathComponent ?? project.videoSource?.url.deletingPathExtension().lastPathComponent ?? "Delivery"
        return DeliveryJob(
            id: UUID(), name: name, created: Date(), app: AppInfo.name,
            sources: paths.map(fingerprint),
            tracks: project.tracks.map { t in
                TrackIntent(key: project.key(of: t), kind: t.kind.rawValue, grouped: t.isGroup, include: t.include, title: t.title,
                            language: t.language, enabled: t.enabled, trimStart: t.trimStart, syncApplied: t.syncApplied,
                            channelMap: t.channelMap.rawValue, channelTarget: t.channelTarget?.roles.map(\.rawValue),
                            channelRoles: t.channelRoles?.map(\.rawValue), delivery: t.delivery.rawValue,
                            members: t.isGroup ? t.members.map { StreamKey(path: $0.url.path, streams: [$0.streamIndex]) } : nil)
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
                               mastering: deliveryMasteringText(hdr.mastering), maxCLL: hdr.maxCLL, maxFALL: hdr.maxFALL),
            container: project.container.rawValue, output: project.outputURL?.path ?? "",
            overwrite: DeliveryQueue.overwriteDefault)
    }

    static func fingerprint(_ path: String) -> SourceFile {
        let a = try? FileManager.default.attributesOfItem(atPath: path)
        return SourceFile(path: path, size: (a?[.size] as? NSNumber)?.int64Value ?? -1, modified: (a?[.modificationDate] as? Date) ?? .distantPast)
    }

    /// The sources that are not as they were when the job was saved ("SOURCE CHANGED: <file> — why")
    func changedSources() -> [String] {
        sources.compactMap { s in
            let now = Self.fingerprint(s.path)
            if now.size < 0 { return "SOURCE CHANGED: \(s.path) — the file is gone" }
            if now.size != s.size { return "SOURCE CHANGED: \(s.path) — its size was \(Fmt.int(Int(s.size))) bytes, now \(Fmt.int(Int(now.size)))" }
            // the JSON keeps milliseconds; the file system has more
            if abs(now.modified.timeIntervalSince(s.modified)) > 0.002 {
                return "SOURCE CHANGED: \(s.path) — modified \(DeliveryJob.stamp(s.modified)), now \(DeliveryJob.stamp(now.modified))"
            }
            return nil
        }
    }

    // MARK: file

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { d, enc in var c = enc.singleValueContainer(); try c.encode(DeliveryJob.isoFormatter.string(from: d)) }
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            let s = try c.decode(String.self)
            if let date = DeliveryJob.isoFormatter.date(from: s) ?? ISO8601DateFormatter().date(from: s) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "not an ISO 8601 date: \(s)")
        }
        return d
    }()
    static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static func stamp(_ d: Date) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f.string(from: d)
    }

    static func load(_ url: URL) throws -> DeliveryJob {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw AppError("Couldn't read the job file \(url.lastPathComponent): \(error.localizedDescription)") }
        let job: DeliveryJob
        do { job = try decoder.decode(DeliveryJob.self, from: data) } catch { throw AppError("\(url.lastPathComponent) isn't a BROS-MUX job file (\(error.localizedDescription)).") }
        guard job.schemaVersion == 1 else { throw AppError("\(url.lastPathComponent) was saved by a newer BROS-MUX (job schema \(job.schemaVersion)); this one reads schema 1.") }
        return job
    }

    func write(to url: URL) throws {
        let data = try Self.encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }

    // MARK: rebuild

    /// The heavy reads of a rebuild (ffprobe/MediaInfo per file, the IMF, the Dolby Vision check), done ahead of time
    /// off the main thread; rebuild(into:prefetched:) then only assembles the project.
    struct Prefetch {
        var probes: [String: (tracks: [Track], error: String?)] = [:]
        var imf: Project.IMFLoad?
        var dolbyVision: (summary: DolbyVisionMeta.Summary?, problem: String?, xml: URL?)?
        var hdr10plusFrames: Int?
    }

    /// The files to read with Probe, in first-appearance order (an IMF picture is read through its CPL instead)
    var probePaths: [String] {
        var out: [String] = []
        let imfPicture = video.imf != nil ? Set(tracks.filter { $0.kind == TrackKind.video.rawValue }.map(\.key.path)) : []
        for t in tracks {
            let paths = t.grouped ? (t.members?.map(\.path) ?? [t.key.path]) : [t.key.path]
            for p in paths where !out.contains(p) && !imfPicture.contains(p) { out.append(p) }
        }
        return out
    }

    func prefetch() throws -> Prefetch {
        if let c = changedSources().first { throw AppError(c) }
        var p = Prefetch()
        for path in probePaths { p.probes[path] = Probe.tracks(for: URL(fileURLWithPath: path)) }
        if let cpl = video.imf { p.imf = Project.readIMF(URL(fileURLWithPath: cpl)) }
        if let j = video.hdr10plusJSON { p.hdr10plusFrames = HDR10Plus.frames(URL(fileURLWithPath: j)) ?? -1 }
        // the Dolby Vision check needs the picture's size and length: a scratch rebuild without it gives them
        if dvSourceValue(frames: 0) != nil {
            let scratch = Project()
            _ = try rebuild(into: scratch, prefetched: p, checkDolbyVision: false)
            if let src = scratch.hdr.dvSource {
                p.dolbyVision = HDRSettings.inspect(src, width: scratch.videoWidth, height: scratch.videoHeight, frames: scratch.videoFrames)
            }
        }
        return p
    }

    /// Rebuilds the project from the job, synchronously, in the order of the plan. Never calls buildProject, add, route,
    /// autoGroup, chooseDefaultReference or a background check. Returns what didn't come back exactly; throws
    /// "SOURCE CHANGED: <file>" when a source isn't the file the job was made from.
    func rebuild(into project: Project) throws -> [String] {
        try rebuild(into: project, prefetched: nil, checkDolbyVision: true)
    }

    func rebuild(into project: Project, prefetched: Prefetch?, checkDolbyVision: Bool = true) throws -> [String] {
        var warnings: [String] = []
        // 1. fingerprints
        if let c = changedSources().first { throw AppError(c) }

        // 2. the files: Probe + insert per source; an IMF through readIMF + applyIMF (no background check)
        if let cpl = video.imf {
            let r = prefetched?.imf ?? Project.readIMF(URL(fileURLWithPath: cpl))
            guard r.package != nil, !r.tracks.isEmpty else { throw AppError("The IMF package \(cpl) can't be read again: \(r.notices.joined(separator: " "))") }
            project.applyIMF(r, check: false)
        }
        for path in probePaths {
            let r = prefetched?.probes[path] ?? Probe.tracks(for: URL(fileURLWithPath: path))
            if let e = r.error { warnings.append("\(URL(fileURLWithPath: path).lastPathComponent): \(e)") }
            project.insert(r.tracks)
        }

        // 3. the groups, with their members in the stored order (no background listening)
        for intent in tracks where intent.grouped {
            let members = intent.members ?? intent.key.streams.map { StreamKey(path: intent.key.path, streams: [$0]) }
            var ids: [UUID] = []
            for m in members {
                guard let t = project.tracks.first(where: { !$0.isGroup && $0.kind == .audio && $0.url.path == m.path && $0.streamIndex == m.streams.first }) else {
                    throw AppError("The job's group “\(intent.title)” can't be rebuilt: stream #\(m.streams.first ?? -1) of \(URL(fileURLWithPath: m.path).lastPathComponent) isn't there any more.")
                }
                ids.append(t.id)
            }
            let before = Set(project.tracks.map(\.id))
            project.makeGroup(ids, listen: false)
            guard project.tracks.contains(where: { $0.isGroup && !before.contains($0.id) }) else {
                throw AppError("The job's group “\(intent.title)” can't be rebuilt: those \(ids.count) mono streams don't make a group any more.")
            }
        }

        // 4. the reference's lateness, before any track is marked aligned (the didSet would move the trims)
        project.restore(referenceLateFrames: referenceLateFrames)

        // 5. the options, then every track's fields in the stored order, the reference and the answers
        project.matchVideoEnd = matchVideoEnd; project.verifyAudio = verifyAudio; project.verifyVideo = verifyVideo
        project.fixColorTag = fixColorTag; project.writeChannelMap = writeChannelMap; project.disableExtraAudio = disableExtraAudio
        project.interleaveMs = interleaveMs; project.pictureCheck = pictureCheck
        func find(_ intent: TrackIntent, in list: [Track]) -> Int? {
            if intent.grouped, let members = intent.members {
                return list.firstIndex { t in t.isGroup && t.members.map { StreamKey(path: $0.url.path, streams: [$0.streamIndex]) } == members }
            }
            return list.firstIndex { t in t.isGroup == intent.grouped && t.kind.rawValue == intent.kind && project.key(of: t) == intent.key }
        }
        var pool = project.tracks
        var ordered: [Track] = []
        for intent in tracks {
            guard let i = find(intent, in: pool) else {
                let what = "\(TrackKind(rawValue: intent.kind)?.label ?? intent.kind) “\(intent.title)” (\(URL(fileURLWithPath: intent.key.path).lastPathComponent) #\(intent.key.streams.map(String.init).joined(separator: ",")))"
                if intent.include { throw AppError("The job's \(what) isn't in the files any more.") }
                warnings.append("\(what) was in the job but isn't in the files any more (it wasn't going into the file).")
                continue
            }
            var t = pool.remove(at: i)
            t.include = intent.include; t.title = intent.title; t.language = intent.language; t.enabled = intent.enabled
            t.trimStart = intent.trimStart; t.syncApplied = intent.syncApplied
            t.channelMap = intent.channelMap.flatMap(ChannelMap.init(rawValue:)) ?? .auto
            t.channelRoles = intent.channelRoles.map { $0.compactMap(ChannelRole.init(rawValue:)) }
            t.channelTarget = intent.channelTarget.map { ChannelOrder(roles: $0.compactMap(ChannelRole.init(rawValue:))) }
            t.delivery = AudioDelivery(rawValue: intent.delivery) ?? .copy
            ordered.append(t)
        }
        for var t in pool {         // streams the job didn't know about stay out of the file, and say so
            t.include = false
            warnings.append("\(t.kind.label) “\(t.title)” (\(t.url.lastPathComponent) #\(t.streamIndex)) wasn't in the job: left out of the file.")
            ordered.append(t)
        }
        project.tracks = ordered
        project.syncReferenceID = syncReference.flatMap { r in project.tracks.first { project.key(of: $0) == r && $0.kind == .audio }?.id }
        if syncReference != nil && project.syncReferenceID == nil { warnings.append("The job's sync reference isn't in the files any more.") }
        project.embeddedAudioAnswer = embeddedAudioAnswer

        // 6. the Dolby Vision / HDR10+ metadata, then the Dolby Vision check (synchronous)
        let hdr = project.hdr
        if video.imf == nil || video.dvSource == nil { hdr.dvSource = dvSourceValue(frames: project.videoFrames) }
        hdr.dolbyVision = video.dolbyVision
        hdr.hdr10plusJSON = video.hdr10plusJSON.map { URL(fileURLWithPath: $0) }
        hdr.hdr10plus = video.hdr10plus
        hdr.hdr10plusFrames = hdr.hdr10plusJSON.map { u in prefetched?.hdr10plusFrames ?? HDR10Plus.frames(u) ?? -1 }
        if hdr.dvSource != nil && checkDolbyVision {
            if let r = prefetched?.dolbyVision { hdr.apply(r) }
            else { hdr.checkDolbyVisionNow(width: project.videoWidth, height: project.videoHeight, frames: project.videoFrames) }
        }

        // 7. the HDR scalars, then hdr.encode from the stored choice (never from "there is an XML")
        if let q = HDRSettings.Quality(rawValue: video.quality) { hdr.quality = q }
        if let s = HDRSettings.Speed(rawValue: video.speed) { hdr.speed = s }
        if let r = HDRSettings.RateMode(rawValue: video.rateMode) { hdr.rateMode = r }
        if let b = HDRSettings.BitratePreset(rawValue: video.bitratePreset) { hdr.bitratePreset = b }
        if let m = video.customMbps { hdr.customMbps = m }
        if let m = video.customMaxMbps { hdr.customMaxMbps = m }
        hdr.qualityFloor = video.qualityFloor
        hdr.convertGamut = video.convertGamut
        if let m = video.mastering.flatMap(deliveryMastering) { hdr.mastering = m }
        hdr.maxCLL = video.maxCLL; hdr.maxFALL = video.maxFALL
        switch video.choice {
        case "copy": project.video.choose(.copy, project: project)
        case "hevcHDR": project.video.choose(.hevcHDR, project: project)
        case "transcode":
            guard let s = video.transcode else { throw AppError("The job says the picture is transcoded, but not to what.") }
            project.video.choose(.transcode(s), project: project)
        default: throw AppError("Unknown picture plan “\(video.choice)” in the job.")
        }

        // 8. the container, then the destination
        if let c = Container(rawValue: container), c != project.container { project.container = c }
        if !output.isEmpty { project.setOutput(URL(fileURLWithPath: output)) }
        return warnings
    }

    func dvSourceValue(frames: Int) -> DolbyVisionMeta.Source? {
        guard let p = video.dvSource else { return nil }
        let u = URL(fileURLWithPath: p)
        return u.pathExtension.lowercased() == "mxf" ? .isxd([.init(file: u, entry: 0, count: frames)]) : .xml(u)
    }

    // MARK: canonical text

    /// What START compares between the window's project and the project rebuilt from the saved file: the command, every
    /// track's identity and flags, the trims, the reference and its offset, the picture plan (+ the step-1 command)
    static func canonicalText(_ project: Project) -> String {
        var s = "COMMAND\n\(project.commandPreview)\n"
        s += "OPTIONS matchVideoEnd=\(project.matchVideoEnd) verifyAudio=\(project.verifyAudio) verifyVideo=\(project.verifyVideo) fixColorTag=\(project.fixColorTag) writeChannelMap=\(project.writeChannelMap) disableExtraAudio=\(project.disableExtraAudio) interleaveMs=\(project.interleaveMs) pictureCheck=\(project.pictureCheck) container=\(project.container.rawValue)\n"
        s += "OUTPUT \(project.outputURL?.path ?? "none")\n"
        s += "TRACKS\n"
        for t in project.tracks {
            let k = project.key(of: t)
            let perm = t.channelPermutation.map { $0.map(String.init).joined(separator: ",") } ?? "none"
            s += "  \(t.kind.rawValue) \(k.path) #\(k.streams.map(String.init).joined(separator: ","))" + (t.isGroup ? " group[" + t.members.map { "\($0.url.lastPathComponent)#\($0.streamIndex)" }.joined(separator: " ") + "]" : "") +
                 " include=\(t.include) title=“\(t.title)” language=\(t.language) enabled=\(t.enabled) permutation=\(perm) trimStart=\(t.trimStart) delivery=\(t.delivery.rawValue)\n"
        }
        s += "PLANS\n"
        for t in project.included where t.kind == .audio {
            if let p = project.plan(for: t) { s += "  \(project.key(of: t).path) #\(project.key(of: t).streams.map(String.init).joined(separator: ",")) pad=\(p.pad) cut=\(p.cut) keep=\(p.keep) total=\(p.total)\n" }
        }
        s += "REFERENCE \(project.reference.map { project.key(of: $0) }.map { "\($0.path) #\($0.streams.map(String.init).joined(separator: ","))" } ?? "none")\n"
        s += String(format: "REFERENCE OFFSET %.9f s\n", project.referenceOffset)
        switch project.video.choice(project) {
        case .copy: s += "VIDEO copy\n"
        case .hevcHDR: s += "VIDEO hevcHDR \(project.hdr.formatsText)\n"
        case .transcode(let v):
            s += "VIDEO transcode preset=\(v.preset) resolution=\(v.resolution) toneMap=\(v.toneMap) quality=\(v.quality ?? "-") speed=\(v.speed ?? "-")\n"
            if let plan = DeliveryEngine.step1Plan(project) {
                s += "STEP 1 ffmpeg " + Transcode.arguments(plan, concat: nil, output: URL(fileURLWithPath: "/BROS-MUX-step-1/video.mov"), elementary: false).joined(separator: " ") + "\n"
            } else { s += "STEP 1 none (no plan)\n" }
        }
        return s
    }

    // MARK: readable text

    /// The readable .job.txt: what is copied, transcoded and left out, and every source with its fingerprint
    func writeText(to url: URL) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    var text: String {
        var s = "\(app) — DELIVERY JOB\n"
        s += "Name: \(name)\nJob: \(id.uuidString)\nSaved: \(Self.stamp(created))\n"
        s += "Output: \(output.isEmpty ? "(not chosen)" : output) · \(container.uppercased())\n"
        s += "If that file already exists: " + (overwrite == "replace" ? "it is REPLACED at the very end (only if every check passes)" : "both are kept — this one gets a _2 name") + "\n\n"

        s += "PICTURE\n"
        let picture = tracks.first { $0.kind == TrackKind.video.rawValue }
        let pictureName = picture.map { URL(fileURLWithPath: $0.key.path).lastPathComponent } ?? (video.imf.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "none")
        switch video.choice {
        case "hevcHDR":
            let formats = ([video.dolbyVision && video.dvSource != nil ? "Dolby Vision 8.1" : nil, "HDR10", video.hdr10plus && video.hdr10plusJSON != nil ? "HDR10+" : nil] as [String?]).compactMap { $0 }.joined(separator: " + ")
            let mode = HDRSettings.RateMode(rawValue: video.rateMode)?.label ?? video.rateMode
            s += "  TRANSCODE → HEVC 10-bit · \(formats) (x265, speed \(video.speed), quality \(video.quality), \(mode)) from \(pictureName)\n"
            if let d = video.dvSource { s += "  Dolby Vision metadata: \(d)\n" }
            if let j = video.hdr10plusJSON { s += "  HDR10+ metadata: \(j)\n" }
            if !video.convertGamut { s += "  Source primaries kept (no BT.2020 conversion)\n" }
        case "transcode":
            let preset = video.transcode.flatMap { TranscodePreset(rawValue: $0.preset)?.label } ?? video.transcode?.preset ?? "?"
            s += "  TRANSCODE → \(preset) in step 1, then copied bit for bit into the final file (from \(pictureName))\n"
        default:
            s += "  COPY · bit-exact — the picture is not touched (\(pictureName))\n"
        }
        if let i = video.imf { s += "  IMF package: \(i)\n" }

        s += "\nIN THE FILE (in this order)\n"
        var audio = 0, subs = 0
        for t in tracks where t.include {
            let kind = TrackKind(rawValue: t.kind) ?? .other
            var label: String
            switch kind {
            case .video: label = "V "
            case .audio: audio += 1; label = "A\(audio)"
            case .subtitle: subs += 1; label = "S\(subs)"
            case .timecode: label = "TC"
            case .other: label = "· "
            }
            let how = kind == .audio ? (AudioDelivery(rawValue: t.delivery)?.label ?? t.delivery) : kind == .video ? (video.choice == "copy" ? "COPY · bit-exact" : "TRANSCODE") : "COPY · bit-exact"
            s += "  \(label)  \(kind.label) “\(t.title)” · \(t.language) · \(sourceText(t)) · \(how)" + (t.trimStart != 0 ? " · head trim \(t.trimStart) samples" : "") +
                 (t.channelTarget.map { " · channels written as \($0.joined(separator: " "))" } ?? "") + (t.enabled ? "" : " · off by default") +
                 (t.key == syncReference ? " · SYNC REFERENCE" : "") + "\n"
        }
        let out = tracks.filter { !$0.include }
        if !out.isEmpty {
            s += "\nLEFT OUT (not in the file)\n"
            for t in out {
                s += "  \(TrackKind(rawValue: t.kind)?.label ?? t.kind) “\(t.title)” · \(sourceText(t))" + (t.key == syncReference ? " · sync reference (lines up the mix, never written)" : "") + "\n"
            }
        }
        s += "\nSYNC\n"
        if let r = syncReference, let t = tracks.first(where: { $0.key == r }) {
            s += "  Reference: “\(t.title)” (\(sourceText(t)))" + (referenceLateFrames != 0 ? String(format: " — %g frame(s) late vs its own picture", referenceLateFrames) : "") + "\n"
        } else { s += "  No sync reference: the sync check after writing is skipped.\n" }
        s += "\nCHECKS AFTER WRITING\n"
        s += "  Audio bit for bit: \(verifyAudio ? "yes" : "no") · Picture bit for bit: \(verifyVideo || video.choice == "transcode" ? "yes" : "no") · Sound vs picture (hard cuts): \(pictureCheck ? "yes" : "no") · Render QC: yes · Academy / Zidoo: yes\n"
        s += "\nSOURCES (fingerprint: size · modified — the job refuses to run if one changes)\n"
        for f in sources { s += "  \(f.path) · \(Fmt.int(Int(f.size))) bytes · \(Self.stamp(f.modified))\n" }
        return s
    }

    private func sourceText(_ t: TrackIntent) -> String {
        if t.grouped, let m = t.members {
            let files = Set(m.map(\.path))
            return files.count == 1 ? "\(m.count) mono streams of \(URL(fileURLWithPath: m[0].path).lastPathComponent) (#\(m.map { String($0.streams.first ?? 0) }.joined(separator: " #")))"
                                    : "\(m.count) mono files (" + m.map { URL(fileURLWithPath: $0.path).lastPathComponent }.joined(separator: ", ") + ")"
        }
        return "\(URL(fileURLWithPath: t.key.path).lastPathComponent) #\(t.key.streams.map(String.init).joined(separator: ","))"
    }
}

// MARK: - helpers (Delivery domain)

/// The IMF's ASSETMAP (a fingerprinted source of an IMF job)
func deliveryAssetMap(in folder: URL) -> URL? {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    return names.first { $0.uppercased().hasPrefix("ASSETMAP") }.map { folder.appendingPathComponent($0) }
}

/// The mastering display as the job stores it: "P3-D65;max=1000;min=0.0001"
func deliveryMasteringText(_ m: MasteringDisplay) -> String {
    "\(m.gamut.rawValue);max=\(m.maxNits);min=\(m.minNits)"
}

func deliveryMastering(_ s: String) -> MasteringDisplay? {
    let parts = s.split(separator: ";").map(String.init)
    guard let g = parts.first.flatMap(MasteringDisplay.Gamut.init(rawValue:)) else { return nil }
    var m = MasteringDisplay(); m.gamut = g
    for p in parts.dropFirst() {
        let kv = p.split(separator: "=", maxSplits: 1).map(String.init)
        guard kv.count == 2, let v = Double(kv[1]) else { continue }
        if kv[0] == "max" { m.maxNits = v } else if kv[0] == "min" { m.minNits = v }
    }
    return m
}
