// BROS-MUX — Abdala Brothers
// A GUI for MP4Box (GPAC): muxes video, audio (PCM, Dolby Atmos E-AC-3 JOC, TrueHD...) and subtitles into MOV/MP4/MKV
// with no re-encoding, aligns audio to a reference track, verifies bit for bit and checks the result
// against the Academy Screening Room technical specifications. HDR playback versions (Dolby Vision, HDR10+) from
// IMF/ProRes masters re-encode the picture only — see HDR.swift.

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Observation
import Accelerate
import AVFoundation

// MARK: - Utilities

struct AppError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}
struct Cancelled: Error {}

/// Cancellation signal read by worker threads
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

enum Tools {
    static func find(_ name: String) -> String? {
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"] {
            let path = dir + "/" + name
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }
    static let mp4box = find("MP4Box")
    static let ffprobe = find("ffprobe")
    static let ffmpeg = find("ffmpeg")
    static let mediainfo = find("mediainfo")
    static var missing: [String] {
        [("MP4Box", mp4box), ("ffprobe", ffprobe), ("ffmpeg", ffmpeg), ("mediainfo", mediainfo)].filter { $0.1 == nil }.map(\.0)
    }

    /// Runs a program and returns stdout (or stderr). Reads everything before waiting so large outputs can't block.
    static func runSync(_ exe: String, _ args: [String], stderr: Bool = false) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        let out = Pipe()
        if stderr { p.standardError = out; p.standardOutput = FileHandle.nullDevice }
        else { p.standardOutput = out; p.standardError = FileHandle.nullDevice }
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        try? out.fileHandleForReading.close()
        return data
    }

    /// Runs a program that the cancel flag can interrupt; returns stdout or stderr (nil if cancelled or failed)
    static func runCancellable(_ exe: String, _ args: [String], cancel: CancelFlag, stderr: Bool = false) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        if stderr { p.standardError = pipe; p.standardOutput = FileHandle.nullDevice }
        else { p.standardOutput = pipe; p.standardError = FileHandle.nullDevice }
        let lock = NSLock()
        var data = Data()
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty { lock.lock(); data.append(d); lock.unlock() }
        }
        do { try p.run() } catch { pipe.fileHandleForReading.readabilityHandler = nil; return nil }
        while p.isRunning {
            if cancel.isSet { p.terminate() }
            Thread.sleep(forTimeInterval: 0.2)
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        let rest = pipe.fileHandleForReading.readDataToEndOfFile()
        try? pipe.fileHandleForReading.close()
        lock.lock(); data.append(rest); lock.unlock()
        guard !cancel.isSet, p.terminationReason == .exit, p.terminationStatus == 0 else { return nil }
        return data
    }

    /// ffmpeg writing to a pipe (read in blocks)
    static func ffmpegPipe(_ args: [String]) throws -> (Process, FileHandle) {
        guard let ffmpeg else { throw AppError("ffmpeg not found") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = ["-nostdin", "-v", "error"] + args
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try p.run()
        return (p, pipe.fileHandleForReading)
    }

    /// Stops a pipe process for good: terminate, close our end (unblocks a writer stuck on a full pipe), reap it
    static func stop(_ p: Process, _ h: FileHandle?) {
        if p.isRunning { p.terminate() }
        try? h?.close()
        p.waitUntilExit()
    }

    /// Same file on disk? (compares the file identifier — catches case differences, links, etc.)
    static func sameFile(_ a: URL, _ b: URL) -> Bool {
        if let x = try? a.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
           let y = try? b.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier,
           x.isEqual(y) { return true }
        return a.resolvingSymlinksInPath().standardizedFileURL.path.lowercased() ==
               b.resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
    }

    /// Free space ("important usage" reads 0 on HFS+/exFAT drives — take the larger of the two values)
    static func freeSpace(at dir: URL) -> Double? {
        guard let v = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]) else { return nil }
        let m = max(Double(v.volumeAvailableCapacityForImportantUsage ?? 0), Double(v.volumeAvailableCapacity ?? 0))
        return m > 0 ? m : nil
    }
}

enum Fmt {
    static func bitrate(_ bps: Double) -> String {
        if bps >= 1_000_000 { return String(format: "%.1f Mbps", bps / 1_000_000) }
        return String(format: "%.0f Kbps", bps / 1000)
    }
    static func bytes(_ b: Double) -> String {
        let f = ByteCountFormatter(); f.countStyle = .file
        return f.string(fromByteCount: Int64(b))
    }
    static func duration(_ s: Double) -> String {
        let h = Int(s) / 3600, m = Int(s) / 60 % 60
        let sec = s - Double(h * 3600 + m * 60)
        return String(format: "%02d:%02d:%06.3f", h, m, sec)
    }
    static func hz(_ v: Double) -> String {
        v.truncatingRemainder(dividingBy: 1000) == 0 ? String(format: "%.0f kHz", v / 1000) : String(format: "%.1f kHz", v / 1000)
    }
    static func ms(_ v: Double) -> String { String(format: "%+.2f ms", v) }
    static func int(_ n: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.locale = Locale(identifier: "en_US")
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }
    /// Track names: ASCII only (MP4Box stores accents garbled), no ':' (option separator) and no '+'
    /// (MP4Box glues the next option onto the name: "DD+ 5.1" became "DD+ 5.1#group=1")
    static func ascii(_ s: String) -> String {
        let folded = (s.applyingTransform(.stripDiacritics, reverse: false) ?? s)
            .replacingOccurrences(of: "DD+", with: "DDP").replacingOccurrences(of: "+", with: " plus ")
        return String(folded.unicodeScalars.filter { $0.isASCII && $0 != ":" && $0.value >= 32 }.map(Character.init))
    }
    /// Characters the Academy accepts in file names: [A-Za-z0-9._-]
    static func academyName(_ s: String) -> String {
        let a = ascii(s).replacingOccurrences(of: " ", with: "_")
        return String(a.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0) ? Character($0) : "_" })
    }
    static func median(_ v: [Double]) -> Double {
        let s = v.sorted(); guard !s.isEmpty else { return 0 }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}

extension Data {
    func be16(_ o: Int) -> UInt16 { self[startIndex + o ..< startIndex + o + 2].reduce(0) { $0 << 8 | UInt16($1) } }
    func be32(_ o: Int) -> UInt32 { self[startIndex + o ..< startIndex + o + 4].reduce(0) { $0 << 8 | UInt32($1) } }
    func be64(_ o: Int) -> UInt64 { self[startIndex + o ..< startIndex + o + 8].reduce(0) { $0 << 8 | UInt64($1) } }
    func le16(_ o: Int) -> Int { Int(self[startIndex + o]) | Int(self[startIndex + o + 1]) << 8 }
    func le32(_ o: Int) -> Int { (0..<4).reduce(0) { $0 | Int(self[startIndex + o + $1]) << (8 * $1) } }
    func le64(_ o: Int) -> Int { (0..<8).reduce(0) { $0 | Int(self[startIndex + o + $1]) << (8 * $1) } }
    func fourcc(_ o: Int) -> String { String(decoding: self[startIndex + o ..< startIndex + o + 4], as: UTF8.self) }
    mutating func setBE32(_ o: Int, _ v: UInt32) {
        for i in 0..<4 { self[startIndex + o + i] = UInt8(truncatingIfNeeded: v >> (24 - 8 * UInt32(i))) }
    }
    mutating func appendBE16(_ v: UInt16) { append(UInt8(v >> 8)); append(UInt8(v & 0xFF)) }
    mutating func appendBE32(_ v: UInt32) { for i in 0..<4 { append(UInt8(truncatingIfNeeded: v >> (24 - 8 * UInt32(i)))) } }
    mutating func appendBE64(_ v: UInt64) { for i in 0..<8 { append(UInt8(truncatingIfNeeded: v >> (56 - 8 * UInt64(i)))) } }
    mutating func appendLE32(_ v: Int) { for i in 0..<4 { append(UInt8(truncatingIfNeeded: v >> (8 * i))) } }
    mutating func appendLE64(_ v: Int) { for i in 0..<8 { append(UInt8(truncatingIfNeeded: v >> (8 * i))) } }
    mutating func appendASCII(_ s: String) { append(contentsOf: Array(s.utf8)) }
}

// MARK: - MediaInfo

struct MITrack {
    let type: String
    var f: [String: String]
    subscript(_ k: String) -> String? { f[k] }
    func d(_ k: String) -> Double? { f[k].flatMap(Double.init) }
}

enum MediaInfo {
    static func tracks(_ u: URL) -> [MITrack] {
        guard let mi = Tools.mediainfo, let d = Tools.runSync(mi, ["--Output=JSON", u.path]),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let media = j["media"] as? [String: Any], let arr = media["track"] as? [[String: Any]] else { return [] }
        return arr.map { t in
            var f: [String: String] = [:]
            for (k, v) in t {
                if let s = v as? String { f[k] = s }
                else if k == "extra", let e = v as? [String: Any] { for (k2, v2) in e { if let s = v2 as? String { f[k2] = s } } }
            }
            return MITrack(type: f["@type"] ?? "", f: f)
        }
    }
    static func text(_ u: URL) -> String {
        Tools.mediainfo.flatMap { Tools.runSync($0, [u.path]) }.map { String(decoding: $0, as: UTF8.self) } ?? "mediainfo not found"
    }
}

// MARK: - Reading the sources (ffprobe)

struct ProbeOutput: Decodable { let streams: [ProbeStream]?; let format: ProbeFormat? }
struct ProbeFormat: Decodable { let format_name: String?; let duration: String?; let size: String? }
struct ProbeStream: Decodable {
    let index: Int
    let id: String?
    let codec_type: String?
    let codec_name: String?
    let profile: String?
    let codec_tag_string: String?
    let width: Int?
    let height: Int?
    let r_frame_rate: String?
    let avg_frame_rate: String?
    let pix_fmt: String?
    let bits_per_raw_sample: String?
    let bits_per_sample: Int?
    let sample_rate: String?
    let channels: Int?
    let channel_layout: String?
    let bit_rate: String?
    let duration: String?
    let tags: [String: String]?
    let disposition: [String: Int]?
    // colour and geometry (Transcode.swift reads them)
    let color_range: String?
    let color_space: String?
    let color_transfer: String?
    let color_primaries: String?
    let field_order: String?
    let sample_aspect_ratio: String?
    let nb_frames: String?
    let chroma_location: String?
}

enum TrackKind: String {
    case video, audio, subtitle, timecode, other

    var icon: String {
        switch self {
        case .video: return "film.fill"
        case .audio: return "waveform"
        case .subtitle: return "captions.bubble.fill"
        case .timecode: return "clock.fill"
        case .other: return "questionmark.square.dashed"
        }
    }
    var color: Color {
        switch self {
        case .video: return .blue
        case .audio: return .purple
        case .subtitle: return .teal
        case .timecode: return .orange
        case .other: return .gray
        }
    }
    var label: String {
        switch self {
        case .video: return "Video"
        case .audio: return "Audio"
        case .subtitle: return "Subtitle"
        case .timecode: return "Timecode"
        case .other: return "Other"
        }
    }
    var probeType: String {
        switch self {
        case .video: return "video"
        case .audio: return "audio"
        case .subtitle: return "subtitle"
        case .timecode, .other: return "data"
        }
    }
}

/// Channel label (QuickTime 'chan') written into PCM tracks
enum ChannelMap: String, CaseIterable, Identifiable {
    case auto, s51, stereo, s71, none
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Automatic (from source layout)"
        case .s51: return "5.1 · L R C LFE Ls Rs"
        case .stereo: return "Stereo · L R"
        case .s71: return "7.1 · L R C LFE Ls Rs Lrs Rrs"
        case .none: return "Don't write"
        }
    }
    /// Apple AudioChannelLayoutTag. Automatic only labels when the source declares the layout (5.1 or stereo).
    func tag(channels: Int, layout: String?) -> UInt32? {
        switch self {
        case .auto:
            let l = (layout ?? "").lowercased()
            if channels == 6 && ["5.1", "5.1(side)"].contains(l) { return 0x0079_0006 }
            if channels == 2 && l == "stereo" { return 0x0065_0002 }
            return nil
        case .s51: return channels == 6 ? 0x0079_0006 : nil      // MPEG_5_1_A
        case .stereo: return channels == 2 ? 0x0065_0002 : nil   // Stereo
        case .s71: return channels == 8 ? 0x0080_0008 : nil      // MPEG_7_1_C (L R C LFE Ls Rs Rls Rrs)
        case .none: return nil
        }
    }
    static func layoutName(_ tag: UInt32) -> String {
        ChannelOrder.layoutName(tag) ?? String(tag, radix: 16)
    }
}

struct Track: Identifiable {
    let id = UUID()
    let url: URL
    let selector: String?        // e.g. "#trackID=2"
    let streamIndex: Int         // ffprobe index in the source file
    let kind: TrackKind
    let codecKey: String         // ffprobe codec_name
    let codecName: String        // friendly name
    let details: String
    let badges: [String]
    let warnings: [String]
    let sourceLabel: String
    let isAtmos: Bool
    let channels: Int
    let sampleRate: Double
    let bitDepth: Int
    let bitRate: Double
    let duration: Double
    let wav: WavInfo?            // PCM coming from a WAV only
    let channelLayout: String?   // layout declared by the source (ffprobe), e.g. "5.1"
    let fromVideoFile: Bool      // audio embedded in a file that also has video
    let mi: MITrack?             // MediaInfo for this stream (for the summary and the Academy prediction)
    var include: Bool
    var language: String
    var title: String
    var enabled = true
    var channelMap: ChannelMap = .auto
    /// Channel identification (ChannelID): the role of each source channel, in file order, and how sure the engine was
    var channelRoles: [ChannelRole]? = nil
    var channelConfidence: Double? = nil
    var channelReport: String? = nil
    /// The order the channels are written in (nil = as in the source). PCM from a WAV only: samples are permuted, never touched.
    var channelTarget: ChannelOrder? = nil
    /// Sync offset in samples of this track: > 0 trims the head, < 0 delays it (PCM: silence written at the head;
    /// E-AC-3: a start delay in the container's edit list — the Dolby frames are never touched)
    var trimStart = 0
    var syncNote: String?
    var syncLag: Double?                       // measured offset vs the reference (s); > 0 = this track is late
    var syncApplied = false                    // the trim was set from that measurement (a track that couldn't be trimmed stays false)
    var syncPoints: [SyncEngine.Point] = []    // every point measured along the film (for the Sync Viewer)
    var imfSegments: [IMFResource] = []        // picture of an IMF package: the stretches of MXF the CPL uses
    /// Several mono PCM sounds handled as one multichannel track (MonoGroup.swift): the members, in file order
    var members: [Track] = []
    var groupBPS = 0                           // bytes one sample of one channel takes
    var groupTotal = 0                         // samples of the shortest member (the group's length)
    var rolesSource: String? = nil             // where the group's channel roles came from (file labels, names, listening, by hand)
    var listening = false                      // the group is being listened to in the background (ChannelID)
    var isGroup: Bool { !members.isEmpty }
    /// Video: the picture as the file describes it (codec, bits, chroma, colour tags…) for the Transcode engine
    var source: SourceVideo? = nil

    var isPCM: Bool { codecKey.hasPrefix("pcm_") }
    var canReorder: Bool { kind == .audio && isPCM && (wav != nil || isGroup) && channels >= 2 }
    var sourceOrder: ChannelOrder? { channelRoles.map { ChannelOrder(roles: $0) } }
    /// Output channel k takes source channel permutation[k]; nil when nothing changes
    var channelPermutation: [Int]? {
        guard canReorder, let target = channelTarget, let src = sourceOrder, target.count == channels else { return nil }
        return target.permutation(from: src)
    }
    /// The layout tag to label the output with: the chosen order when the channels are reordered, else the picker's choice
    func outputLayoutTag(writeLabels: Bool) -> UInt32? {
        guard writeLabels, isPCM else { return nil }
        if channelPermutation != nil { return channelTarget?.layoutTag }           // permuted data: only the written order may label it
        if channelMap == .auto, let src = sourceOrder, src.isComplete, src.count == channels { return src.layoutTag }   // roles heard or set by hand beat the declared mask
        return channelMap.tag(channels: channels, layout: channelLayout)
    }
    var blockAlign: Int { wav?.blockAlign ?? (isGroup ? channels * groupBPS : max(1, channels * max(bitDepth, 8) / 8)) }
    var totalSamples: Int {
        if isGroup { return groupTotal }
        if let wav { return wav.dataSize / max(1, wav.blockAlign) }
        return Int((duration * sampleRate).rounded())
    }
    /// Trim/align with no re-encode: PCM from WAV (sample exact) and E-AC-3 (per Dolby frame)
    var canTrim: Bool { kind == .audio && ((isPCM && (wav != nil || isGroup)) || codecKey == "eac3") }
    var trimStartMs: Double {
        get { sampleRate > 0 ? Double(trimStart) * 1000 / sampleRate : 0 }
        set { trimStart = sampleRate > 0 ? Int((newValue * sampleRate / 1000).rounded()) : 0 }
    }
    /// Audio quality in plain words
    var quality: (text: String, lossless: Bool) {
        if isPCM { return ("Lossless · uncompressed PCM", true) }
        switch codecKey {
        case "truehd", "mlp", "alac", "flac": return ("Lossless · compressed", true)
        case "eac3", "ac3", "aac", "mp3", "opus", "dts", "ac4": return ("Lossy · compressed", false)
        default: return ("—", false)
        }
    }
}

enum Probe {
    static let languageAliases = ["fre": "fra", "ger": "deu", "chi": "zho", "dut": "nld", "cze": "ces",
                                  "gre": "ell", "per": "fas", "rum": "ron", "slo": "slk", "pt": "por",
                                  "en": "eng", "es": "spa", "fr": "fra", "de": "deu", "it": "ita", "ja": "jpn"]

    static func raw(_ url: URL) -> ProbeOutput? {
        guard let ffprobe = Tools.ffprobe,
              let data = Tools.runSync(ffprobe, ["-v", "error", "-print_format", "json",
                                                 "-show_streams", "-show_format", url.path]) else { return nil }
        return try? JSONDecoder().decode(ProbeOutput.self, from: data)
    }

    static func tracks(for url: URL) -> (tracks: [Track], error: String?) {
        guard Tools.ffprobe != nil else { return ([], "ffprobe not found") }
        guard let probe = raw(url), let streams = probe.streams, !streams.isEmpty
        else { return ([], "Couldn't read “\(url.lastPathComponent)” — unrecognized format.") }

        let format = probe.format?.format_name ?? ""
        let isISO = format.contains("mov") || format.contains("mp4")
        let isTS = format.contains("mpegts")
        let multi = streams.count > 1
        let fileDuration = Double(probe.format?.duration ?? "") ?? 0
        let hasVideo = streams.contains { $0.codec_type == "video" && $0.disposition?["attached_pic"] != 1 }

        // MediaInfo for the same file, matched by type order (Video/Audio/Text/Other)
        var miByType: [String: [MITrack]] = [:]
        for t in MediaInfo.tracks(url) { miByType[t.type, default: []].append(t) }
        var counters: [String: Int] = [:]
        func nextMI(_ type: String) -> MITrack? {
            let i = counters[type, default: 0]; counters[type] = i + 1
            let list = miByType[type] ?? []
            return i < list.count ? list[i] : nil
        }

        var result: [Track] = []
        for s in streams {
            var selector: String? = nil
            if isISO, let idHex = s.id, let tid = Int(idHex.replacingOccurrences(of: "0x", with: ""), radix: 16) {
                selector = "#trackID=\(tid)"
            } else if isTS, let idHex = s.id, let pid = Int(idHex.replacingOccurrences(of: "0x", with: ""), radix: 16) {
                selector = "#\(pid)"             // MPEG-TS: MP4Box uses the PID as the ID
            } else if multi {
                selector = "#\(s.index + 1)"
            }
            var miType: String?
            switch s.codec_type {
            case "video" where s.disposition?["attached_pic"] != 1: miType = "Video"
            case "audio": miType = "Audio"
            case "subtitle": miType = "Text"
            case "data" where s.codec_tag_string == "tmcd": miType = "Other"
            default: miType = nil
            }
            let mi = miType.flatMap(nextMI)
            if let t = makeTrack(s, url: url, selector: selector, multi: multi, format: format,
                                 fileDuration: fileDuration, hasVideo: hasVideo, mi: mi) {
                result.append(t)
            }
        }
        return (result, nil)
    }

    static func fps(_ s: String?) -> String? {
        guard let s, s != "0/0" else { return nil }
        let parts = s.split(separator: "/").compactMap { Double($0) }
        guard parts.count == 2, parts[1] > 0 else { return nil }
        var str = String(format: "%.3f", parts[0] / parts[1])
        while str.hasSuffix("0") { str.removeLast() }
        if str.hasSuffix(".") { str.removeLast() }
        return str
    }

    static func channelText(_ n: Int, _ layout: String?) -> String {
        if let layout, !layout.isEmpty, layout != "unknown" {
            let base = layout.components(separatedBy: "(").first ?? layout
            switch base {
            case "mono": return "Mono"
            case "stereo": return "Stereo"
            default: return base
            }
        }
        switch n {
        case 1: return "Mono"
        case 2: return "Stereo"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return "\(n) channels"
        }
    }

    static func proresName(_ tag: String?, _ profile: String?) -> String {
        switch tag ?? "" {
        case "apco": return "Apple ProRes 422 Proxy"
        case "apcs": return "Apple ProRes 422 LT"
        case "apcn": return "Apple ProRes 422"
        case "apch": return "Apple ProRes 422 HQ"
        case "ap4h": return "Apple ProRes 4444"
        case "ap4x": return "Apple ProRes 4444 XQ"
        default:
            let p = (profile ?? "").lowercased()
            if p.contains("xq") { return "Apple ProRes 4444 XQ" }
            if p.contains("4444") { return "Apple ProRes 4444" }
            if p.contains("hq") { return "Apple ProRes 422 HQ" }
            if p.contains("lt") { return "Apple ProRes 422 LT" }
            if p.contains("proxy") { return "Apple ProRes 422 Proxy" }
            return "Apple ProRes"
        }
    }

    static func makeTrack(_ s: ProbeStream, url: URL, selector: String?, multi: Bool, format: String,
                          fileDuration: Double, hasVideo: Bool, mi: MITrack?) -> Track? {
        let codec = s.codec_name ?? "?"
        let tags = s.tags ?? [:]
        var lang = (tags["language"] ?? "und").lowercased()
        lang = languageAliases[lang] ?? lang
        let srcTitle = cleanTitle(tags["title"] ?? tags["handler_name"])
        let sourceLabel = multi ? "stream \(s.index + 1)" : "whole file"
        var badges: [String] = []
        var warnings: [String] = []
        var include = true
        let bitRate = Double(s.bit_rate ?? "") ?? mi?.d("BitRate") ?? 0
        let duration = Double(s.duration ?? "") ?? fileDuration
        let rawBits = Int(s.bits_per_raw_sample ?? "") ?? 0
        let bits = rawBits > 0 ? rawBits : (s.bits_per_sample ?? Int(mi?["BitDepth"] ?? "") ?? 0)
        let fromVideo = hasVideo && s.codec_type != "video"

        func make(_ kind: TrackKind, _ name: String, _ details: String, atmos: Bool = false, title: String,
                  enabled: Bool = true, channels: Int = 0, sampleRate: Double = 0, wav: WavInfo? = nil) -> Track {
            Track(url: url, selector: selector, streamIndex: s.index, kind: kind, codecKey: codec, codecName: name,
                  details: details, badges: badges, warnings: warnings, sourceLabel: sourceLabel, isAtmos: atmos,
                  channels: channels, sampleRate: sampleRate, bitDepth: bits, bitRate: bitRate, duration: duration,
                  wav: wav, channelLayout: s.channel_layout, fromVideoFile: fromVideo, mi: mi, include: include,
                  language: lang, title: Fmt.ascii(title), enabled: enabled)
        }

        switch s.codec_type {
        case "video":
            if s.disposition?["attached_pic"] == 1 { return nil }
            let name: String
            switch codec {
            case "prores": name = proresName(s.codec_tag_string, s.profile)
            case "h264": name = "H.264 / AVC"
            case "hevc": name = "HEVC / H.265"
            case "av1": name = "AV1"
            case "dnxhd": name = "Avid DNxHD/HR"
            case "mjpeg": name = "Motion JPEG"
            default: name = codec.uppercased()
            }
            var d: [String] = []
            if let w = s.width, let h = s.height { d.append("\(w)×\(h)") }
            if let f = fps(s.avg_frame_rate) ?? fps(s.r_frame_rate) { d.append("\(f) fps") }
            if bits > 0 { d.append("\(bits)-bit") }
            if bitRate > 0 { d.append(Fmt.bitrate(bitRate)) }
            if duration > 0 { d.append(Fmt.duration(duration)) }
            if let tc = tags["timecode"] { d.append("TC \(tc)") }
            let hdr = mi?["HDR_Format"] ?? ""
            let transfer = mi?["transfer_characteristics"] ?? ""
            if hdr.contains("Dolby Vision") { badges.append("Dolby Vision") }
            if hdr.contains("2094") { badges.append("HDR10+") }
            if transfer == "PQ" || transfer.contains("2084") { badges.append(hdr.contains("2086") ? "HDR10" : "HDR · PQ") }
            else if transfer == "HLG" { badges.append("HLG") }
            if codec == "dnxhd" { warnings.append("DNxHD/HR may not be accepted by MP4Box.") }
            if codec == "hevc" { warnings.append("The Academy does not accept HEVC — only ProRes 422 HQ or H.264.") }
            var t = make(.video, name, d.joined(separator: " · "), title: srcTitle ?? "Video")
            t.source = SourceVideo(stream: s, mi: mi, url: url, fallbackDuration: duration)
            return t

        case "audio":
            let ch = s.channels ?? 0
            let chText = channelText(ch, s.channel_layout)
            let profile = s.profile ?? ""
            let atmos = profile.localizedCaseInsensitiveContains("atmos") || (mi?["Format_Commercial_IfAny"] ?? "").contains("Atmos")
            var name: String
            var short: String
            switch codec {
            case let c where c.hasPrefix("pcm_"):
                name = bits > 0 ? "PCM \(bits)-bit" : "PCM"
                if c.contains("f32") || c.contains("f64") { name += " float" }
                short = "PCM"
            case "eac3": name = atmos ? "Dolby Digital Plus · Atmos (E-AC-3 JOC)" : "Dolby Digital Plus (E-AC-3)"; short = "DDP"
            case "ac3": name = "Dolby Digital (AC-3)"; short = "DD"
            case "truehd", "mlp": name = atmos ? "Dolby TrueHD · Atmos" : "Dolby TrueHD"; short = "TrueHD"
            case "ac4": name = "Dolby AC-4"; short = "AC-4"
            case "aac": name = "AAC"; short = "AAC"
            case "alac": name = "Apple Lossless"; short = "ALAC"
            case "flac": name = "FLAC"; short = "FLAC"
            case "opus": name = "Opus"; short = "Opus"
            case "mp3": name = "MP3"; short = "MP3"
            case "dts": name = "DTS"; short = "DTS"
            default: name = codec.uppercased(); short = name
            }
            if atmos { badges.append("Dolby Atmos") }
            badges.append(chText)
            let sr = Double(s.sample_rate ?? "") ?? 0
            var d: [String] = []
            if sr > 0 { d.append(Fmt.hz(sr)) }
            d.append(ch == 1 ? "1 channel" : "\(ch) channels")
            if bitRate > 0 { d.append(Fmt.bitrate(bitRate) + (mi?["BitRate_Mode"] == "CBR" ? " CBR" : "")) }
            if duration > 0 { d.append(Fmt.duration(duration)) }

            // WAV: MP4Box imports chunks that follow 'data' as audio (e.g. Pro Tools 'regn' markers)
            let isWAV = codec.hasPrefix("pcm_") && format.contains("wav")
            let wav = isWAV ? WavInfo.read(url) : nil
            if isWAV && wav == nil { warnings.append("Couldn't parse this WAV's structure — sync trimming unavailable.") }
            if wav?.hasTrailingChunks == true { badges.append("WAV protected") }
            if wav?.headerSizeIgnored == true {
                warnings.append("This WAV's header has a wrong audio size (common above 4 GB) — using the audio up to the end of the file. Check the duration.")
            }
            if codec.hasPrefix("pcm_") && ch > 16 {
                // an ADM BWF Dolby Atmos master (beds + objects): no player plays it, but it's a fine sync reference
                name = "Dolby Atmos master · ADM BWF"; short = "Atmos ADM master"
                badges.insert("ADM master", at: 0)
                include = false
                warnings.append("Dolby Atmos master (ADM BWF, \(ch) channels) — players can't play it. It can be the sync reference; for playback add a Dolby encode of it (E-AC-3 JOC, or TrueHD Atmos).")
            } else if codec.hasPrefix("pcm_") && ch > 8 && format.contains("wav") {
                warnings.append("A \(ch)-channel WAV may be an ADM BWF (Atmos) master. MP4Box can't convert ADM — for Atmos use .ec3/.mp4 (DD+ JOC).")
            }
            if codec == "truehd" { warnings.append("The Academy doesn't accept TrueHD (E-AC-3 JOC only) — it's for home-theater versions (MKV).") }
            if codec == "dts" { warnings.append("DTS isn't reliably supported in MOV/MP4.") }
            let defaultTitle = atmos ? "Dolby Atmos (DDP JOC)" : "\(short) \(chText)"
            return make(.audio, name, d.joined(separator: " · "), atmos: atmos, title: srcTitle ?? defaultTitle,
                        channels: ch, sampleRate: sr, wav: wav)

        case "subtitle":
            let name: String
            switch codec {
            case "subrip": name = "SRT subtitles"
            case "webvtt": name = "WebVTT subtitles"
            case "mov_text": name = "QuickTime text (tx3g)"
            case "ttml": name = "TTML subtitles"
            case "ass", "ssa": name = "ASS/SSA subtitles"; warnings.append("ASS/SSA loses its styling — convert to SRT if it fails.")
            case "hdmv_pgs_subtitle", "dvd_subtitle", "dvb_subtitle":
                name = "Image subtitles (\(codec))"
                warnings.append("Image-based subtitles (PGS/VobSub) aren't supported in MOV/MP4.")
                include = false
            default: name = "Subtitles (\(codec))"
            }
            let forced = s.disposition?["forced"] == 1
            if forced { badges.append("Forced") }
            // subtitles start disabled (optional in the player), except forced ones
            return make(.subtitle, name, url.pathExtension.uppercased(),
                        title: srcTitle ?? (lang == "und" ? "Subtitles" : Languages.name(lang)), enabled: forced)

        case "data" where s.codec_tag_string == "tmcd":
            return make(.timecode, "Timecode (QuickTime)", tags["timecode"].map { "Starts at \($0)" } ?? "", title: "Timecode")

        default:
            include = false
            warnings.append("Data/metadata stream — unchecked by default.")
            return make(.other, "Data stream (\(s.codec_tag_string ?? codec))", "", title: srcTitle ?? "")
        }
    }

    static func cleanTitle(_ t: String?) -> String? {
        guard let t = t?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
        let junk = ["handler", "core media", "apple ", "gpac", "iso media", "mainconcept", "l-smash", "lavf", ":lang="]
        if junk.contains(where: { t.lowercased().contains($0) }) { return nil }
        return t
    }
}

enum Languages {
    static let list: [(String, String)] = [
        ("eng", "English"), ("por", "Portuguese"), ("spa", "Spanish"), ("fra", "French"),
        ("deu", "German"), ("ita", "Italian"), ("jpn", "Japanese"), ("kor", "Korean"),
        ("zho", "Chinese"), ("rus", "Russian"), ("ara", "Arabic"), ("hin", "Hindi"),
        ("nld", "Dutch"), ("pol", "Polish"), ("tur", "Turkish"), ("heb", "Hebrew"),
        ("swe", "Swedish"), ("dan", "Danish"), ("nor", "Norwegian"), ("fin", "Finnish"),
        ("zxx", "No language (M&E)"), ("und", "Undetermined"),
    ]
    static func name(_ code: String) -> String { list.first { $0.0 == code }?.1 ?? code.uppercased() }
}

// MARK: - WAV (structure parsing and sample-exact trimmed copy)

struct WavInfo {
    let dataStart: Int
    let dataSize: Int      // rounded down to whole samples
    let fileSize: Int
    let fmt: Data          // 'fmt ' chunk payload
    let blockAlign: Int
    let headerSizeIgnored: Bool   // the header's 'data' size made no sense (e.g. WAV > 4 GB) — we use up to EOF
    var dataEnd: Int { dataStart + dataSize }
    var hasTrailingChunks: Bool { dataEnd < fileSize }
    var bitsPerSample: Int { fmt.count >= 16 ? fmt.le16(14) : 0 }
    /// 8-bit PCM is unsigned: silence is 0x80
    var silenceByte: UInt8 { bitsPerSample == 8 ? 0x80 : 0 }

    static func read(_ url: URL) -> WavInfo? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        guard let end = try? fh.seekToEnd(), let fileSize = Int(exactly: end) else { return nil }
        guard (try? fh.seek(toOffset: 0)) != nil else { return nil }
        let head = fh.readData(ofLength: 12)
        guard head.count == 12, ["RIFF", "RF64", "BW64"].contains(head.fourcc(0)), head.fourcc(8) == "WAVE" else { return nil }
        var fmt: Data?
        var ds64DataSize: Int?
        var o = 12
        while o + 8 <= fileSize {
            guard (try? fh.seek(toOffset: UInt64(o))) != nil else { return nil }
            let h = fh.readData(ofLength: 8)
            guard h.count == 8 else { return nil }
            let id = h.fourcc(0)
            let size = h.le32(4)
            switch id {
            case "ds64":
                let d = fh.readData(ofLength: min(size, 28))
                if d.count >= 16 { let v = d.le64(8); if v > 0 && v < fileSize { ds64DataSize = v } }
            case "fmt ":
                guard size >= 16, size < 1 << 16 else { return nil }
                let d = fh.readData(ofLength: size)
                guard d.count == size else { return nil }
                fmt = d
            case "data":
                guard let f = fmt else { return nil }
                let ba = f.le16(12)
                guard ba > 0 else { return nil }
                let start = o + 8
                let toEOF = fileSize - start
                var s = size
                var ignored = false
                if s == 0xFFFF_FFFF, let d = ds64DataSize { s = d }
                // nonsense size (0, 0xFFFFFFFF without ds64, bigger than the file) or chunks after it that don't add up
                // exactly to EOF (a size that wrapped around in a WAV > 4 GB): use the audio up to EOF
                if s <= 0 || s == 0xFFFF_FFFF || s > toEOF || (s < toEOF && !trailingChunksValid(fh, from: start + s + (s & 1), fileSize: fileSize)) {
                    ignored = s != toEOF
                    s = toEOF
                }
                s -= s % ba
                guard s > 0 else { return nil }
                return WavInfo(dataStart: start, dataSize: s, fileSize: fileSize, fmt: f, blockAlign: ba, headerSizeIgnored: ignored)
            default: break
            }
            guard size >= 0, size <= fileSize else { return nil }
            o += 8 + size + (size & 1)
        }
        return nil
    }

    /// Do the chunks after the audio have readable names and end exactly at EOF?
    private static func trailingChunksValid(_ fh: FileHandle, from start: Int, fileSize: Int) -> Bool {
        var o = start, count = 0
        while o + 8 <= fileSize {
            guard (try? fh.seek(toOffset: UInt64(o))) != nil else { return false }
            let h = fh.readData(ofLength: 8)
            guard h.count == 8 else { return false }
            let printable = h.prefix(4).allSatisfy { $0 >= 0x20 && $0 < 0x7F }
            let size = h.le32(4)
            guard printable, size >= 0, o + 8 + size <= fileSize else { return false }
            o += 8 + size + (size & 1)
            count += 1
            if count > 10_000 { return false }
        }
        return count > 0 && fileSize - o < 8 && o <= fileSize + 1
    }

    /// Writes a new WAV: ['pad' samples of silence] + samples [cut, cut+keep) copied byte for byte from the source.
    /// `order`: output channel k takes source channel order[k] (a permutation); the samples themselves are copied as they are
    static func writeTrimmed(_ info: WavInfo, from src: URL, to dst: URL, pad: Int, cut: Int, keep: Int, order: [Int]? = nil,
                             cancel: CancelFlag, progress: (Double) -> Void) throws {
        let ba = info.blockAlign
        guard pad >= 0, cut >= 0, keep > 0, (cut + keep) * ba <= info.dataSize else { throw AppError("Trim is outside the source audio.") }
        let map = try order.map { try byteMap($0, blockAlign: ba) }
        let dataBytes = (pad + keep) * ba
        let fmtChunk = 8 + info.fmt.count + (info.fmt.count & 1)
        let total = 12 + fmtChunk + 8 + dataBytes + (dataBytes & 1)
        let rf64 = total + 36 > Int(UInt32.max)
        var h = Data()
        if rf64 {
            h.appendASCII("RF64"); h.appendLE32(0xFFFF_FFFF); h.appendASCII("WAVE")
            h.appendASCII("ds64"); h.appendLE32(28)
            h.appendLE64(total + 36 - 8); h.appendLE64(dataBytes); h.appendLE64(pad + keep); h.appendLE32(0)
        } else {
            h.appendASCII("RIFF"); h.appendLE32(total - 8); h.appendASCII("WAVE")
        }
        h.appendASCII("fmt "); h.appendLE32(info.fmt.count); h.append(info.fmt)
        if info.fmt.count & 1 == 1 { h.append(0) }
        h.appendASCII("data"); h.appendLE32(rf64 ? 0xFFFF_FFFF : dataBytes)

        guard FileManager.default.createFile(atPath: dst.path, contents: nil) else { throw AppError("Couldn't create \(dst.lastPathComponent)") }
        let out = try FileHandle(forWritingTo: dst)
        defer { try? out.close() }
        let input = try FileHandle(forReadingFrom: src)
        defer { try? input.close() }
        try out.write(contentsOf: h)
        let chunk = max(ba, (16 << 20) / ba * ba)          // whole blocks, so a channel permutation never splits a sample
        var padLeft = pad * ba
        while padLeft > 0 {
            let n = min(chunk, padLeft)
            try out.write(contentsOf: Data(repeating: info.silenceByte, count: n))
            padLeft -= n
        }
        try input.seek(toOffset: UInt64(info.dataStart + cut * ba))
        var left = keep * ba, done = 0
        while left > 0 {
            if cancel.isSet { throw Cancelled() }
            let d = input.readData(ofLength: min(chunk, left))
            guard !d.isEmpty else { throw AppError("The source WAV ended earlier than expected.") }
            try out.write(contentsOf: map.map { reorder(d, blockAlign: ba, map: $0) } ?? d)
            left -= d.count; done += d.count
            progress(Double(done) / Double(keep * ba))
        }
        if dataBytes & 1 == 1 { try out.write(contentsOf: Data([0])) }
    }

    /// For a channel permutation, where each byte of an output block comes from in the source block
    static func byteMap(_ order: [Int], blockAlign ba: Int) throws -> [Int] {
        let ch = order.count
        guard ch > 0, ba % ch == 0, Set(order) == Set(0..<ch) else { throw AppError("The channel order doesn't match the track (\(ch) channels, block of \(ba) bytes).") }
        let bps = ba / ch
        return (0..<ba).map { j in order[j / bps] * bps + j % bps }
    }

    /// Permutes the channels of whole blocks; bytes inside each sample are untouched
    static func reorder(_ d: Data, blockAlign ba: Int, map: [Int]) -> Data {
        let n = d.count / ba * ba
        var out = Data(count: n)
        out.withUnsafeMutableBytes { o in d.withUnsafeBytes { i in
            guard let ip = i.bindMemory(to: UInt8.self).baseAddress, let op = o.bindMemory(to: UInt8.self).baseAddress else { return }
            var b = 0
            while b < n {
                for j in 0..<ba { op[b + j] = ip[b + map[j]] }
                b += ba
            }
        } }
        return out
    }
}

// MARK: - E-AC-3 (Dolby Digital Plus / Atmos): frame-level reading, for trimming without re-encoding

final class EAC3Reader {
    private let fh: FileHandle
    private var buf: [UInt8] = []
    private var pos = 0
    private var eof = false
    init(_ fh: FileHandle) { self.fh = fh }

    private func fill(_ n: Int) -> Bool {
        while buf.count - pos < n && !eof {
            if pos > 0 && pos >= buf.count / 2 { buf.removeFirst(pos); pos = 0 }
            let d = fh.readData(ofLength: 1 << 20)
            if d.isEmpty { eof = true } else { buf.append(contentsOf: d) }
        }
        return buf.count - pos >= n
    }

    private struct Header { let independent: Bool; let substream: Int; let size: Int; let samples: Int }

    private func header() throws -> Header? {
        guard fill(6) else {
            if buf.count - pos > 0 { throw AppError("The E-AC-3 stream ends in the middle of a frame.") }
            return nil
        }
        guard buf[pos] == 0x0B, buf[pos + 1] == 0x77 else { throw AppError("Lost sync in the E-AC-3 stream.") }
        let b2 = buf[pos + 2], b3 = buf[pos + 3], b4 = buf[pos + 4], b5 = buf[pos + 5]
        let bsid = Int(b5 >> 3)
        guard bsid > 10 && bsid <= 16 else { throw AppError("The stream isn't E-AC-3 (bsid \(bsid)).") }
        let strmtyp = Int(b2 >> 6), sub = Int((b2 >> 3) & 7)
        let frmsiz = (Int(b2 & 7) << 8) | Int(b3)
        let fscod = Int(b4 >> 6), numblkscod = Int((b4 >> 4) & 3)
        let blocks = fscod == 3 ? 6 : [1, 2, 3, 6][numblkscod]
        return Header(independent: strmtyp != 1, substream: sub, size: (frmsiz + 1) * 2, samples: blocks * 256)
    }

    /// Next access unit: independent frame of substream 0 + the dependent frames that go with it
    func next() throws -> (bytes: [UInt8], samples: Int)? {
        guard let h = try header() else { return nil }
        guard h.independent && h.substream == 0 else { throw AppError("The E-AC-3 stream doesn't start on an independent frame.") }
        guard fill(h.size) else { throw AppError("Incomplete E-AC-3 frame at the end of the stream.") }
        var au = Array(buf[pos ..< pos + h.size]); pos += h.size
        while let g = try header(), !(g.independent && g.substream == 0) {
            guard fill(g.size) else { throw AppError("Incomplete E-AC-3 frame at the end of the stream.") }
            au.append(contentsOf: buf[pos ..< pos + g.size]); pos += g.size
        }
        return (au, h.samples)
    }
}

enum EAC3 {
    struct Slice { let skippedAUs: Int; let skippedSamples: Int; let keptAUs: Int; let keptSamples: Int; let samplesPerAU: Int; let tailAUs: Int }

    static func open(_ url: URL, _ index: Int) throws -> (Process, FileHandle) {
        try Tools.ffmpegPipe(["-i", url.path, "-map", "0:\(index)", "-c", "copy", "-f", "eac3", "-"])
    }

    /// Samples per syncframe of a stream (reads just the first frame)
    static func samplesPerFrame(_ url: URL, _ index: Int) -> Int? {
        guard let (p, h) = try? open(url, index) else { return nil }
        defer { Tools.stop(p, h) }
        return (try? EAC3Reader(h).next())??.samples
    }

    /// Copies the frames covering samples [cut, cut+keep): the head rounds DOWN (sound is never early)
    /// and the tail rounds UP (covers up to the requested end). Frames are copied byte for byte.
    static func slice(_ url: URL, index: Int, cut: Int, keep: Int, to dst: URL,
                      cancel: CancelFlag, progress: (Double) -> Void) throws -> Slice {
        let (p, h) = try open(url, index)
        defer { Tools.stop(p, h) }
        let reader = EAC3Reader(h)
        guard FileManager.default.createFile(atPath: dst.path, contents: nil) else { throw AppError("Couldn't create \(dst.lastPathComponent)") }
        let out = try FileHandle(forWritingTo: dst)
        defer { try? out.close() }
        var skipped = 0, skippedS = 0, kept = 0, keptS = 0, spf = 0, tail = 0
        let end = cut + keep
        var pending = Data()
        while let au = try reader.next() {
            if cancel.isSet { throw Cancelled() }
            spf = au.samples
            if skippedS + au.samples <= cut { skipped += 1; skippedS += au.samples; continue }
            if skippedS + keptS >= end { tail = 1; break }
            pending.append(contentsOf: au.bytes); kept += 1; keptS += au.samples
            if pending.count >= 4 << 20 { try out.write(contentsOf: pending); pending.removeAll(keepingCapacity: true) }
            if kept % 1000 == 0 { progress(Double(skippedS + keptS) / Double(max(1, end))) }
        }
        if tail > 0 { while try reader.next() != nil { tail += 1 } }   // count what's left, for an exact report
        if !pending.isEmpty { try out.write(contentsOf: pending) }
        guard kept > 0 else { throw AppError("Nothing left of the E-AC-3 after trimming.") }
        return Slice(skippedAUs: skipped, skippedSamples: skippedS, keptAUs: kept, keptSamples: keptS, samplesPerAU: spf, tailAUs: tail)
    }
}

// MARK: - Sync: measures the offset between two audio tracks by cross-correlation

enum SyncEngine {
    struct Point { let time: Double; let lag: Double; let corr: Double; let second: Double }
    struct Result {
        let lag: Double?           // seconds; > 0 = the sound happens LATER in the measured track than in the reference
        let points: [Point]
        let inliers: Int
        let valid: Int
        let spreadMs: Double
        let message: String
    }
    struct Source {
        let url: URL; let index: Int; let duration: Double; var channels = 0
        /// A group of mono sounds (MonoGroup.swift): decoded together and summed to one mono signal
        var members: [(url: URL, index: Int)] = []
        var mix: [Int] = []                    // which members go into the sum (empty = all; the LFE is left out when known)
    }

    static func decode(_ s: Source, from start: Double, length: Double, rate: Int) -> [Float] {
        guard let ffmpeg = Tools.ffmpeg, start >= 0, length > 0 else { return [] }
        if !s.members.isEmpty {
            // every mono source is opened at the same instant (a file that holds several members is opened once),
            // merged, converted to float so the sum can't overflow, and summed
            var files: [String] = [], labels: [String] = []
            var args = ["-nostdin", "-v", "error"]
            for m in s.members {
                var k = files.firstIndex(of: m.url.path)
                if k == nil {
                    files.append(m.url.path); k = files.count - 1
                    args += ["-ss", String(format: "%.6f", start), "-t", String(format: "%.6f", length), "-i", m.url.path]
                }
                labels.append("[\(k!):\(m.index)]")
            }
            let mix = s.mix.isEmpty ? Array(s.members.indices) : s.mix
            let graph = labels.joined() + "amerge=inputs=\(s.members.count),aformat=sample_fmts=flt,pan=mono|c0=" + mix.map { "c\($0)" }.joined(separator: "+")
            args += ["-filter_complex", graph, "-ar", "\(rate)", "-f", "f32le", "-"]
            guard let d = Tools.runSync(ffmpeg, args), d.count >= 4 else { return [] }
            return d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
        // many channels (an ADM Atmos master, 7.1.4…) have no standard downmix: they're summed
        let mono = s.channels > 8 ? ["-af", "pan=mono|c0=" + (0..<s.channels).map { "c\($0)" }.joined(separator: "+")] : ["-ac", "1"]
        let args = ["-nostdin", "-v", "error", "-ss", String(format: "%.6f", start), "-t", String(format: "%.6f", length),
                    "-i", s.url.path, "-map", "0:\(s.index)"] + mono + ["-ar", "\(rate)", "-f", "f32le", "-"]
        guard let d = Tools.runSync(ffmpeg, args), d.count >= 4 else { return [] }
        return d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    /// Normalized correlation of 'ref' against every position of 'cand' (cand.count >= ref.count)
    static func correlate(_ ref: [Float], _ cand: [Float]) -> [Double] {
        let L = ref.count, n = cand.count - L + 1
        guard L > 16, n > 0 else { return [] }
        var out = [Float](repeating: 0, count: n)
        cand.withUnsafeBufferPointer { c in
            ref.withUnsafeBufferPointer { r in
                vDSP_conv(c.baseAddress!, 1, r.baseAddress!, 1, &out, 1, vDSP_Length(n), vDSP_Length(L))
            }
        }
        var eRef: Float = 0
        vDSP_svesq(ref, 1, &eRef, vDSP_Length(L))
        var cum = [Double](repeating: 0, count: cand.count + 1)
        for i in 0..<cand.count { cum[i + 1] = cum[i] + Double(cand[i]) * Double(cand[i]) }
        var norm = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let e = cum[i + L] - cum[i]
            norm[i] = (e > 1e-12 && eRef > 1e-12) ? Double(out[i]) / (Double(eRef) * e).squareRoot() : 0
        }
        return norm
    }

    static func peak(_ c: [Double], guardBand g: Int) -> (index: Double, value: Double, second: Double)? {
        guard c.count > 2 else { return nil }
        var best = 0
        for i in 1..<c.count where c[i] > c[best] { best = i }
        var second = 0.0
        for i in 0..<c.count where abs(i - best) > g { second = max(second, c[i]) }
        var frac = 0.0
        if best > 0 && best < c.count - 1 {
            let y0 = c[best - 1], y1 = c[best], y2 = c[best + 1]
            let den = y0 - 2 * y1 + y2
            if den < 0 { frac = max(-0.5, min(0.5, 0.5 * (y0 - y2) / den)) }
        }
        return (Double(best) + frac, c[best], second)
    }

    /// Measures at several points of the film (coarse at 1 kHz, fine at the final rate) and takes the median of reliable points.
    static func measure(ref: Source, cand: Source, rate: Int, maxLag: Double = 60, points nPts: Int = 15,
                        cancel: CancelFlag, progress: (Double) -> Void) -> Result {
        let dur = min(ref.duration, cand.duration)
        let win = min(30.0, max(4.0, dur / 8))
        let lagMax = min(maxLag, max(0.5, dur / 4))
        let lo = lagMax + 0.5, hi = dur - win - lagMax - 0.5
        guard hi > lo, dur > 10 else {
            return Result(lag: nil, points: [], inliers: 0, valid: 0, spreadMs: 0, message: "Tracks are too short to measure sync.")
        }
        let coarse = 1000
        var pts: [Point] = []
        for i in 0..<nPts {
            if cancel.isSet { break }
            let t = nPts == 1 ? (lo + hi) / 2 : lo + (hi - lo) * Double(i) / Double(nPts - 1)
            let r = decode(ref, from: t, length: win, rate: coarse)
            let c = decode(cand, from: t - lagMax, length: win + 2 * lagMax, rate: coarse)
            if r.count > coarse, c.count > r.count, let p = peak(correlate(r, c), guardBand: coarse / 20) {
                pts.append(Point(time: t, lag: p.index / Double(coarse) - lagMax, corr: p.value, second: p.second))
            }
            progress(Double(i + 1) / Double(nPts) * 0.7)
        }
        if cancel.isSet { return Result(lag: nil, points: pts, inliers: 0, valid: 0, spreadMs: 0, message: "Measurement cancelled.") }
        // reliable point: decent correlation and a peak that stands out from the runner-up
        let valid = pts.filter { $0.corr >= 0.45 && $0.corr >= $0.second * 1.3 }
        guard valid.count >= 3 else {
            return Result(lag: nil, points: pts, inliers: 0, valid: valid.count, spreadMs: 0,
                          message: "Not enough similarity between the tracks (\(valid.count) of \(pts.count) reliable points). Are they the same mix/cut?")
        }
        let med = Fmt.median(valid.map(\.lag))
        let inl = valid.filter { abs($0.lag - med) <= 0.004 }
        guard inl.count >= max(3, Int((Double(valid.count) * 0.6).rounded(.up))) else {
            return Result(lag: nil, points: pts, inliers: inl.count, valid: valid.count, spreadMs: 0,
                          message: "Measurements disagree (\(inl.count) of \(valid.count) agree). The tracks may have different edits.")
        }
        // refine at the final rate on the best points
        let half = 0.02, fw = min(8.0, win)
        var fine: [Double] = []
        let best = inl.sorted { $0.corr > $1.corr }.prefix(5)
        for (k, p) in best.enumerated() {
            if cancel.isSet { break }
            let cs = p.time + p.lag - half
            guard cs >= 0 else { continue }
            let r = decode(ref, from: p.time, length: fw, rate: rate)
            let c = decode(cand, from: cs, length: fw + 2 * half, rate: rate)
            if r.count > rate, c.count > r.count, let q = peak(correlate(r, c), guardBand: rate / 500), q.value > 0.3 {
                fine.append(q.index / Double(rate) + p.lag - half)
            }
            progress(0.7 + 0.3 * Double(k + 1) / Double(best.count))
        }
        let values = fine.count >= 2 ? fine : inl.map(\.lag)
        let lag = Fmt.median(values)
        let spread = values.map { abs($0 - lag) * 1000 }.max() ?? 0
        let msg = String(format: "%+.6f s · %d of %d points agree · spread ±%.2f ms", lag, inl.count, pts.count, spread)
        return Result(lag: lag, points: pts, inliers: inl.count, valid: valid.count, spreadMs: spread, message: msg)
    }
}

extension SyncEngine.Source {
    /// The sound of a track: one stream, or every member of a mono group summed (without the LFE, when the roles are known)
    init(_ t: Track) {
        self.init(url: t.url, index: t.streamIndex, duration: t.duration, channels: t.channels)
        if t.isGroup {
            members = t.members.map { ($0.url, $0.streamIndex) }
            if let r = t.channelRoles, r.count == members.count {
                let noLFE = r.indices.filter { r[$0] != .LFE }
                if !noLFE.isEmpty { mix = noLFE }
            }
        }
    }
}

// MARK: - Header fixes written into the file without moving any media (channel labels, Dolby sample entries)

enum MoovPatcher {
    struct Box { let type: String; let offset: Int; let size: Int; let header: Int }

    /// What to fix in one audio track (audio tracks counted in file order)
    struct AudioFix {
        var chanTag: UInt32? = nil          // PCM: write a QuickTime 'chan' with this layout
        var channels: Int
        var sampleRate: Double
        var samplesPerFrame = 1536          // E-AC-3: samples per syncframe (6 blocks)
    }

    static func readBoxes(_ d: Data, from start: Int, to end: Int) -> [Box] {
        var out: [Box] = []
        var o = start
        while o + 8 <= end {
            var size = Int(d.be32(o))
            let type = d.fourcc(o + 4)
            var header = 8
            if size == 1 {
                guard o + 16 <= end, let big = Int(exactly: d.be64(o + 8)) else { break }
                size = big; header = 16
            } else if size == 0 { size = end - o }
            if size < header || o + size > end { break }
            out.append(Box(type: type, offset: o, size: size, header: header))
            o += size
        }
        return out
    }

    static func child(_ d: Data, _ b: Box, _ type: String) -> Box? {
        readBoxes(d, from: b.offset + b.header, to: b.offset + b.size).first { $0.type == type }
    }

    /// QuickTime PCM sound entries (MP4 uses 'ipcm' + 'chnl', which MP4Box already writes)
    static let pcmEntries: Set<String> = ["in24", "in32", "lpcm", "sowt", "twos", "fl32", "fl64", "raw "]

    /// Edits the moov in place, inside the 'free' padding MP4Box leaves after it (-moovpad): nothing in mdat moves.
    /// • PCM tracks: adds a QuickTime 'chan' atom (channel labels).
    /// • E-AC-3 tracks: MP4Box writes them into MOV as a QuickTime v1 sound description that Apple's AVFoundation
    ///   (QuickTime Player, Final Cut, Compressor…) silently ignores. They're rewritten as a v2 sound description with
    ///   the 'dec3' config inside a 'wave' atom — the layout Apple's own tools write. The audio itself is untouched.
    static func patch(_ url: URL, audio: [Int: AudioFix], fixDolby: Bool) throws -> [String] {
        let fh = try FileHandle(forUpdating: url)
        defer { try? fh.close() }
        guard let fileSize = Int(exactly: try fh.seekToEnd()) else { throw AppError("file too large") }

        var top: [Box] = []
        var o = 0
        while o + 8 <= fileSize {
            try fh.seek(toOffset: UInt64(o))
            let h = fh.readData(ofLength: 16)
            guard h.count >= 8 else { break }
            var size = Int(h.be32(0)), header = 8
            if size == 1 { guard h.count == 16, let big = Int(exactly: h.be64(8)) else { break }; size = big; header = 16 }
            else if size == 0 { size = fileSize - o }
            if size < header || o + size > fileSize { break }
            top.append(Box(type: h.fourcc(4), offset: o, size: size, header: header))
            o += size
        }
        guard let mi = top.firstIndex(where: { $0.type == "moov" }) else { throw AppError("moov not found") }
        let moovTop = top[mi]
        guard moovTop.header == 8 else { throw AppError("64-bit moov not supported") }
        guard mi + 1 < top.count, ["free", "skip"].contains(top[mi + 1].type), top[mi + 1].header == 8 else {
            throw AppError("no padding after moov — headers not changed")
        }
        let free = top[mi + 1]
        guard moovTop.size < 512 << 20 else { throw AppError("moov too large") }

        try fh.seek(toOffset: UInt64(moovTop.offset))
        var d = fh.readData(ofLength: moovTop.size)
        guard d.count == moovTop.size else { throw AppError("short read of moov") }
        let moov = Box(type: "moov", offset: 0, size: moovTop.size, header: 8)   // offsets below are relative to d

        struct Edit { let start: Int; let end: Int; let bytes: Data; let ancestors: [Box] }
        var edits: [Edit] = []
        var notes: [String] = []
        /// every box we resize must store its real size in a 32-bit field (not 0 = "to the end", not 64-bit)
        func sane(_ chain: [Box]) -> Bool { chain.allSatisfy { $0.header == 8 && Int(d.be32($0.offset)) == $0.size } }

        var audioOrdinal = 0
        for trak in readBoxes(d, from: 8, to: d.count) where trak.type == "trak" {
            guard let mdia = child(d, trak, "mdia"),
                  let hdlr = child(d, mdia, "hdlr"),
                  hdlr.offset + hdlr.header + 12 <= d.count,
                  d.fourcc(hdlr.offset + hdlr.header + 8) == "soun" else { continue }
            let ordinal = audioOrdinal
            audioOrdinal += 1
            guard let want = audio[ordinal] else { continue }
            let n = "Audio \(ordinal + 1)"
            guard let minf = child(d, mdia, "minf"), let stbl = child(d, minf, "stbl"), let stsd = child(d, stbl, "stsd"),
                  stsd.size >= stsd.header + 8 else { notes.append("\(n): unexpected structure — header not changed"); continue }
            guard let entry = readBoxes(d, from: stsd.offset + stsd.header + 8, to: stsd.offset + stsd.size).first, entry.header == 8 else { continue }
            let parents = [moov, trak, mdia, minf, stbl, stsd]

            if let tag = want.chanTag {
                if !pcmEntries.contains(entry.type) { notes.append("\(n): not QuickTime PCM — channel labels not written") }
                else if entry.size >= 28 && d.be16(entry.offset + 16) <= 1 && Int(d.be16(entry.offset + 24)) != want.channels {
                    notes.append("\(n): \(d.be16(entry.offset + 24)) channels in the file, expected \(want.channels) — channel labels not written")
                } else if d.subdata(in: entry.offset + 8 ..< entry.offset + entry.size).range(of: Data("chan".utf8)) != nil {
                    notes.append("\(n): already had channel labels")
                } else if !sane(parents + [entry]) {
                    notes.append("\(n): unusual box sizes — channel labels not written")
                } else {
                    var chan = Data()
                    chan.appendBE32(24); chan.appendASCII("chan")
                    chan.appendBE32(0); chan.appendBE32(tag); chan.appendBE32(0); chan.appendBE32(0)
                    edits.append(Edit(start: entry.offset + entry.size, end: entry.offset + entry.size, bytes: chan, ancestors: parents + [entry]))
                    notes.append("\(n): channel labels written (\(ChannelMap.layoutName(tag)))")
                }
            }

            if fixDolby && entry.type == "ec-3" {
                let version = Int(d.be16(entry.offset + 16))
                guard let hdrLen = [0: 36, 1: 52, 2: 72][version], entry.size >= hdrLen else {
                    notes.append("\(n): unknown sound description version \(version) — Dolby header not changed"); continue
                }
                let kids = readBoxes(d, from: entry.offset + hdrLen, to: entry.offset + entry.size)
                if version == 2 && kids.contains(where: { $0.type == "wave" }) { continue }     // already Apple's layout
                var config = kids.first { $0.type == "dec3" }.map { d.subdata(in: $0.offset ..< $0.offset + $0.size) }
                if config == nil, let wave = kids.first(where: { $0.type == "wave" }) {
                    config = readBoxes(d, from: wave.offset + 8, to: wave.offset + wave.size).first { $0.type == "dec3" }
                        .map { d.subdata(in: $0.offset ..< $0.offset + $0.size) }
                }
                guard let config else { notes.append("\(n): no 'dec3' found — Dolby header not changed"); continue }
                guard sane(parents) else { notes.append("\(n): unusual box sizes — Dolby header not changed"); continue }
                var e = Data()
                e.appendBE32(0); e.appendASCII("ec-3")                                  // size set below
                e.append(contentsOf: [0, 0, 0, 0, 0, 0])
                e.append(d.subdata(in: entry.offset + 14 ..< entry.offset + 16))           // data reference index
                e.appendBE16(2); e.appendBE16(0); e.appendBE32(0)                          // version 2, revision, vendor
                e.appendBE16(3); e.appendBE16(16); e.appendBE16(0xFFFE); e.appendBE16(0)   // always 3, 16, -2, 0
                e.appendBE32(0x0001_0000); e.appendBE32(72)                                // always 65536, sizeOfStructOnly
                e.appendBE64(want.sampleRate.bitPattern)                                  // audioSampleRate (Float64)
                e.appendBE32(UInt32(want.channels)); e.appendBE32(0x7F00_0000)
                e.appendBE32(0); e.appendBE32(0); e.appendBE32(0)                          // bits/channel, flags, bytes/packet
                e.appendBE32(UInt32(want.samplesPerFrame))                                // frames per packet
                var wave = Data()
                wave.appendBE32(12); wave.appendASCII("frma"); wave.appendASCII("ec-3")
                wave.append(config)
                wave.appendBE32(8); wave.appendBE32(0)                                    // terminator
                e.appendBE32(UInt32(8 + wave.count)); e.appendASCII("wave"); e.append(wave)
                e.setBE32(0, UInt32(e.count))
                edits.append(Edit(start: entry.offset, end: entry.offset + entry.size, bytes: e, ancestors: parents))
                notes.append("\(n): Dolby E-AC-3 header rewritten in Apple's QuickTime layout (v2 + wave) — audio untouched")
            }
        }
        guard !edits.isEmpty else { return notes }

        let delta = edits.reduce(0) { $0 + $1.bytes.count - ($1.end - $1.start) }
        let newFree = free.size - delta
        guard newFree == 0 || newFree >= 8 else { throw AppError("not enough padding after moov") }
        for ed in edits.sorted(by: { $0.start > $1.start }) {
            d.replaceSubrange(ed.start ..< ed.end, with: ed.bytes)
            let dd = ed.bytes.count - (ed.end - ed.start)
            for a in ed.ancestors { d.setBE32(a.offset, UInt32(Int(d.be32(a.offset)) + dd)) }
        }
        var region = d
        if newFree > 0 { region.appendBE32(UInt32(newFree)); region.appendASCII("free") }
        guard region.count <= moovTop.size + free.size else { throw AppError("internal size error") }
        try fh.seek(toOffset: UInt64(moovTop.offset))
        try fh.write(contentsOf: region)
        try fh.synchronize()
        return notes
    }
}

// MARK: - Bit-for-bit verification (source × final file)

protocol ByteSource: AnyObject {
    func read(_ max: Int) throws -> Data      // empty = end
    func finish() throws                      // checks it ended cleanly
}

final class PipeSource: ByteSource {
    let p: Process; let h: FileHandle
    init(_ args: [String]) throws { (p, h) = try Tools.ffmpegPipe(args) }
    func read(_ max: Int) throws -> Data { h.readData(ofLength: max) }
    func finish() throws {
        let leftover = h.readData(ofLength: 1)
        Tools.stop(p, h)
        if !leftover.isEmpty { throw AppError("extra data") }
        if p.terminationReason != .exit || p.terminationStatus != 0 { throw AppError("ffmpeg failed reading the track") }
    }
    func abort() { Tools.stop(p, h) }
}

final class WavRangeSource: ByteSource {
    let fh: FileHandle; var padLeft: Int; var left: Int; let silence: UInt8; let ba: Int; let map: [Int]?
    init(_ url: URL, info: WavInfo, pad: Int, cut: Int, keep: Int, order: [Int]? = nil) throws {
        fh = try FileHandle(forReadingFrom: url)
        try fh.seek(toOffset: UInt64(info.dataStart + cut * info.blockAlign))
        padLeft = pad * info.blockAlign; left = keep * info.blockAlign; silence = info.silenceByte
        ba = info.blockAlign; map = try order.map { try WavInfo.byteMap($0, blockAlign: info.blockAlign) }
    }
    func read(_ max: Int) throws -> Data {
        if padLeft > 0 { let n = min(max, padLeft); padLeft -= n; return Data(repeating: silence, count: n) }
        guard left > 0 else { return Data() }
        let want = map == nil ? min(max, left) : Swift.max(ba, min(max, left) / ba * ba)
        let d = fh.readData(ofLength: want)
        guard !d.isEmpty else { throw AppError("the source WAV ended earlier than expected") }
        left -= d.count
        return map.map { WavInfo.reorder(d, blockAlign: ba, map: $0) } ?? d
    }
    func finish() throws { try? fh.close() }
}

final class EAC3SliceSource: ByteSource {
    let p: Process; let h: FileHandle; let reader: EAC3Reader
    var skip: Int; var keep: Int
    init(_ url: URL, index: Int, skip: Int, keep: Int) throws {
        (p, h) = try EAC3.open(url, index)
        reader = EAC3Reader(h); self.skip = skip; self.keep = keep
    }
    func read(_ max: Int) throws -> Data {
        while skip > 0 { guard try reader.next() != nil else { throw AppError("the source has fewer frames than expected") }; skip -= 1 }
        var out = Data()
        while keep > 0 && out.count < max {
            guard let au = try reader.next() else { throw AppError("the source has fewer frames than expected") }
            out.append(contentsOf: au.bytes); keep -= 1
        }
        return out
    }
    func finish() throws { Tools.stop(p, h) }
}

enum VerifySource {
    case ffmpeg(URL, Int)                                   // whole source track via ffmpeg
    case wav(URL, WavInfo, pad: Int, cut: Int, keep: Int, order: [Int]? = nil)   // bytes read straight from the WAV (channels permuted the same way)
    case eac3(URL, Int, skip: Int, keep: Int)              // source frames, with the same trim
    case group(Track, pad: Int, cut: Int, keep: Int)       // mono sources interleaved into one track: checked channel by channel (MonoGroup.swift)
    case none
}

enum Verifier {
    struct Result { let ok: Bool; let text: String }

    /// Raw formats ffmpeg can write for a codec (only ones that exist — anything else is "not verifiable")
    static func rawFormat(_ codec: String) -> String? {
        let pcm = ["pcm_s16le": "s16le", "pcm_s16be": "s16be", "pcm_s24le": "s24le", "pcm_s24be": "s24be",
                   "pcm_s32le": "s32le", "pcm_s32be": "s32be", "pcm_f32le": "f32le", "pcm_f32be": "f32be",
                   "pcm_f64le": "f64le", "pcm_f64be": "f64be", "pcm_u8": "u8", "pcm_s8": "s8"]
        if let f = pcm[codec] { return f }
        switch codec {
        case "eac3", "ac3", "truehd", "mlp": return codec
        case "aac": return "adts"
        default: return nil
        }
    }

    /// Compares a track's data with the matching track of the final file.
    static func compare(_ t: Track, source: VerifySource, out: URL, outStream: ProbeStream,
                        cancel: CancelFlag, progress: (Double) -> Void) -> Result {
        let name = "\(t.kind.label) “\(t.title)”"
        let outCodec = outStream.codec_name ?? ""
        if t.kind == .video {
            // video: MD5 of all packets on both sides, in parallel; cancel kills both
            guard case .ffmpeg(let url, let idx) = source, let ffmpeg = Tools.ffmpeg else { return Result(ok: true, text: "\(name): verification unavailable") }
            func args(_ u: URL, _ i: Int) -> [String] { ["-nostdin", "-v", "error", "-i", u.path, "-map", "0:\(i)", "-c", "copy", "-f", "streamhash", "-hash", "md5", "-"] }
            var ha: Data?, hb: Data?
            let g = DispatchGroup()
            g.enter(); DispatchQueue.global().async { ha = Tools.runCancellable(ffmpeg, args(url, idx), cancel: cancel); g.leave() }
            g.enter(); DispatchQueue.global().async { hb = Tools.runCancellable(ffmpeg, args(out, outStream.index), cancel: cancel); g.leave() }
            while g.wait(timeout: .now() + 1) == .timedOut { progress(-1) }
            if cancel.isSet { return Result(ok: false, text: "\(name): verification cancelled") }
            func md5(_ d: Data?) -> String { String(String(decoding: d ?? Data(), as: UTF8.self).split(separator: "=").last ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
            let a = md5(ha), b = md5(hb)
            let ok = a.count == 32 && a == b
            return Result(ok: ok, text: ok ? "\(name): bit-identical ✓ (MD5 of all packets \(a.prefix(8))…)" : "\(name): DIFFERENT from the source ✗")
        }
        if case .group(let g, let pad, let cut, let keep) = source {
            return GroupSources.verify(g, pad: pad, cut: cut, keep: keep, out: out, outStream: outStream, cancel: cancel, progress: progress)
        }
        guard let fmt = rawFormat(outCodec) else { return Result(ok: true, text: "\(name): bit-for-bit check not available for \(outCodec)") }
        let src: ByteSource
        do {
            switch source {
            case .ffmpeg(let url, let idx):
                guard let sf = rawFormat(t.codecKey) else { return Result(ok: true, text: "\(name): check not available for \(t.codecKey)") }
                src = try PipeSource(["-i", url.path, "-map", "0:\(idx)", "-c", "copy", "-f", sf, "-"])
            case .wav(let url, let info, let pad, let cut, let keep, let order):
                src = try WavRangeSource(url, info: info, pad: pad, cut: cut, keep: keep, order: order)
            case .eac3(let url, let idx, let skip, let keep):
                src = try EAC3SliceSource(url, index: idx, skip: skip, keep: keep)
            case .none, .group:
                return Result(ok: true, text: "\(name): not verified")
            }
        } catch { return Result(ok: false, text: "\(name): \(error.localizedDescription)") }
        let outSrc: PipeSource
        do { outSrc = try PipeSource(["-i", out.path, "-map", "0:\(outStream.index)", "-c", "copy", "-f", fmt, "-"]) }
        catch { try? src.finish(); return Result(ok: false, text: "\(name): \(error.localizedDescription)") }

        let expected = max(t.bitRate / 8 * t.duration, 1)
        var total = 0
        let chunk = 8 << 20
        do {
            while true {
                if cancel.isSet { outSrc.abort(); try? src.finish(); return Result(ok: false, text: "\(name): verification cancelled") }
                let a = try src.read(chunk)
                if a.isEmpty { break }
                var b = Data()
                while b.count < a.count {
                    let more = try outSrc.read(a.count - b.count)
                    if more.isEmpty { break }
                    b.append(more)
                }
                if b.count < a.count {
                    outSrc.abort(); try? src.finish()
                    return Result(ok: false, text: "\(name): the final file has LESS data (\(Fmt.bytes(Double(total + b.count))) of \(Fmt.bytes(Double(total + a.count)))) ✗")
                }
                if a != b {
                    outSrc.abort(); try? src.finish()
                    return Result(ok: false, text: "\(name): DIFFERENT from the source near \(Fmt.bytes(Double(total))) ✗")
                }
                total += a.count
                progress(min(Double(total) / expected, 1))
            }
            try src.finish()
            do { try outSrc.finish() } catch { return Result(ok: false, text: "\(name): the final file has \(error.localizedDescription) ✗") }
        } catch {
            outSrc.abort(); try? src.finish()
            return Result(ok: false, text: "\(name): \(error.localizedDescription) ✗")
        }
        guard total > 0 else { return Result(ok: false, text: "\(name): no data was read — can't confirm ✗") }
        return Result(ok: true, text: "\(name): bit-identical ✓ (\(Fmt.bytes(Double(total))))")
    }
}

// MARK: - Academy Screening Room specs (https://submissions.oscars.org/technicalspecifications.aspx)

enum CheckLevel {
    case ok, warn, fail, info
    var icon: String { switch self { case .ok: return "checkmark.circle.fill"; case .warn: return "exclamationmark.triangle.fill"; case .fail: return "xmark.octagon.fill"; case .info: return "info.circle.fill" } }
    var color: Color { switch self { case .ok: return .green; case .warn: return .orange; case .fail: return .red; case .info: return .blue } }
    var text: String { switch self { case .ok: return "PASS"; case .warn: return "WARN"; case .fail: return "FAIL"; case .info: return "INFO" } }
}
struct Check: Identifiable { let id = UUID(); let level: CheckLevel; let title: String; let detail: String }

enum AcademyLevel {
    case notApproved, accepted, preferred
    var emoji: String { switch self { case .notApproved: return "🔴"; case .accepted: return "🟡"; case .preferred: return "🟢" } }
    var title: String { switch self { case .notApproved: return "NOT APPROVED BY THE ACADEMY"; case .accepted: return "ACCEPTED SPECS"; case .preferred: return "PREFERRED SPECS" } }
    var color: Color { switch self { case .notApproved: return .red; case .accepted: return Color(red: 0.86, green: 0.62, blue: 0.0); case .preferred: return .green } }
    var explanation: String {
        switch self {
        case .notApproved: return "At least one requirement fails — see the checks."
        case .accepted: return "Meets the Academy's ACCEPTED specs (e.g. H.264). Shortlisted films must later upload ProRes 422 HQ."
        case .preferred: return "Meets the Academy's PREFERRED specs (Apple ProRes 422 HQ, PCM audio)."
        }
    }
}

struct BlackEdges { let head: Double; let tail: Double; let window: Double }

enum Academy {
    static func isAtmos(_ t: MITrack) -> Bool { (t["Format_AdditionalFeatures"] ?? "").contains("JOC") || (t["Format_Commercial_IfAny"] ?? "").contains("Atmos") }
    static func isEAC3JOC(_ t: MITrack) -> Bool { t["Format"] == "E-AC-3" && (t["Format_AdditionalFeatures"] ?? "").contains("JOC") }
    static func isTrueHD(_ t: MITrack) -> Bool { let f = t["Format"] ?? ""; return f.contains("MLP") || f.contains("TrueHD") }

    /// All the checks. `black == nil` and `predicted == true` when evaluating a file that doesn't exist yet.
    static func checks(fileName name: String, _ tracks: [MITrack], black: BlackEdges?, predicted: Bool = false) -> [Check] {
        var c: [Check] = []
        let general = tracks.first { $0.type == "General" }
        let videos = tracks.filter { $0.type == "Video" }
        let audios = tracks.filter { $0.type == "Audio" }
        let hasAtmos = audios.contains(where: isAtmos)

        if name.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil {
            c.append(Check(level: .ok, title: "File name", detail: "Only legal characters ([A-Za-z0-9._-])"))
        } else {
            c.append(Check(level: .fail, title: "File name", detail: "Has spaces/symbols/accents. Suggested: \(Fmt.academyName((name as NSString).deletingPathExtension)).\((name as NSString).pathExtension)"))
        }

        var isProRes = false, isAVC = false
        if let v = videos.first {
            let fmt = v["Format"] ?? "", prof = v["Format_Profile"] ?? ""
            let isQT = (general?["Format_Profile"] ?? "") == "QuickTime"
            isProRes = fmt == "ProRes"; isAVC = fmt == "AVC"
            if isProRes && prof == "422 HQ" && isQT {
                c.append(Check(level: .ok, title: "Video codec", detail: "Apple ProRes 422 HQ (MOV) — PREFERRED"))
            } else if isProRes {
                c.append(Check(level: isQT ? .warn : .fail, title: "Video codec", detail: "ProRes \(prof)\(isQT ? "" : " outside MOV") — the Academy asks for ProRes 422 HQ (MOV)"))
            } else if isAVC {
                c.append(Check(level: .ok, title: "Video codec", detail: "AVC/H.264 \(prof) (\(isQT ? "MOV" : "MP4")) — ACCEPTED"))
            } else {
                c.append(Check(level: .fail, title: "Video codec", detail: "\(fmt) \(prof) is not accepted — use ProRes 422 HQ or H.264"))
            }
            let w = Int(v["Width"] ?? "") ?? 0, h = Int(v["Height"] ?? "") ?? 0
            let uhd = (w == 3840 || w == 4096) && h == 2160
            if uhd { c.append(Check(level: .ok, title: "Resolution", detail: "\(w)×\(h) (\(w == 4096 ? "4K" : "UHD"))")) }
            else if w == 1920 && h == 1080 {
                c.append(Check(level: hasAtmos ? .fail : .ok, title: "Resolution",
                               detail: hasAtmos ? "1920×1080 — ATMOS must be embedded into a UHD video file (3840×2160 or 4096×2160)" : "1920×1080 (HD)"))
            } else { c.append(Check(level: .fail, title: "Resolution", detail: "\(w)×\(h) — the Academy accepts 3840×2160, 4096×2160 or 1920×1080")) }

            let fr = v.d("FrameRate") ?? 0
            let okRates: [Double] = [23.976, 24, 25, 29.97] + (uhd ? [30] : [])
            c.append(Check(level: okRates.contains { abs($0 - fr) < 0.01 } ? .ok : .fail, title: "Frame rate", detail: String(format: "%.3f fps", fr)))
            if !(abs(fr - 23.976) < 0.01 || abs(fr - 29.97) < 0.01) {
                c.append(Check(level: .info, title: "Forensic watermarking", detail: String(format: "%.3f fps — films purchasing forensic watermarking must be 23.976 or 29.97 fps", fr)))
            }
            if let scan = v["ScanType"] {
                c.append(Check(level: scan == "Progressive" ? .ok : .fail, title: "Scan type", detail: scan))
            }
            if v["HDR_Format"] != nil || ["PQ", "HLG", "SMPTE ST 2084"].contains(v["transfer_characteristics"] ?? "") {
                c.append(Check(level: .fail, title: "Dynamic range", detail: "HDR — the Academy requires SDR"))
            }
            for (k, label) in [("colour_primaries", "Color primaries"), ("transfer_characteristics", "Transfer function"), ("matrix_coefficients", "YCbCr matrix")] {
                if let val = v[k] { c.append(Check(level: val == "BT.709" ? .ok : .fail, title: label, detail: val + (val == "BT.709" ? "" : " — must be ITU-R BT.709 (no exceptions)"))) }
                else {
                    let gamma = k == "transfer_characteristics" ? v["Gamma"].map { " (the file only carries “Gamma \($0)”, Resolve's Rec.709-A tag)" } ?? "" : ""
                    c.append(Check(level: .fail, title: label, detail: "not tagged BT.709\(gamma) — must be ITU-R BT.709 (no exceptions)"))
                }
            }
            if let br = v.d("BitRate") {
                if isAVC {
                    if uhd { c.append(Check(level: br >= 75e6 && br <= 125e6 ? .ok : .warn, title: "Video bitrate", detail: "\(Fmt.bitrate(br)) (H.264 UHD: VBR expected between 80 and 120 Mbps)")) }
                    else { c.append(Check(level: br >= 38e6 ? .ok : .warn, title: "Video bitrate", detail: "\(Fmt.bitrate(br)) (H.264 HD: 40 Mbps or higher)")) }
                } else {
                    c.append(Check(level: .info, title: "Video bitrate", detail: "\(Fmt.bitrate(br)) (ProRes 422 HQ: ~\(uhd ? "880" : "220") Mbps expected)"))
                }
            }
            if let b = black {
                for (label, val) in [("Black at head", b.head), ("Black at tail", b.tail)] {
                    if val >= b.window - 0.05 { c.append(Check(level: .fail, title: label, detail: String(format: "%.0f s or more (max 3 s)", b.window))) }
                    else if val >= 0.95 && val <= 3.05 { c.append(Check(level: .ok, title: label, detail: String(format: "%.2f s (1–3 s required)", val))) }
                    else if val > 3.05 { c.append(Check(level: .fail, title: label, detail: String(format: "%.2f s (max 3 s)", val))) }
                    else { c.append(Check(level: .fail, title: label, detail: String(format: "%.2f s — one second of black is required", val))) }
                }
            } else if predicted {
                c.append(Check(level: .info, title: "Black at head/tail", detail: "checked on the final file after muxing (1–3 s required)"))
            }
            if let d = v.d("Duration"), d > 190 * 60 {
                c.append(Check(level: .warn, title: "Running time", detail: "over 190 minutes — the Academy can't forensically watermark it"))
            }
        } else {
            c.append(Check(level: .fail, title: "Video", detail: "No video — the Academy needs a video asset"))
        }

        if audios.isEmpty { c.append(Check(level: .fail, title: "Audio", detail: "No audio track — audio is required for each video file")) }
        for (i, a) in audios.enumerated() {
            let n = "Audio \(i + 1)"
            let sr = a.d("SamplingRate") ?? 0
            let ch = Int(a["Channels"] ?? "") ?? 0
            if a["Format"] == "PCM" {
                let bits = Int(a["BitDepth"] ?? "") ?? 0
                c.append(Check(level: (bits == 16 || bits == 24) && sr == 48000 ? .ok : .fail, title: "\(n) · PCM",
                               detail: "\(bits)-bit · \(Fmt.hz(sr)) · \(ch) ch (lossless 16/24-bit 48 kHz required)"))
                let layout = a["ChannelLayout"] ?? ""
                if layout.isEmpty {
                    c.append(Check(level: ch >= 3 ? .fail : .warn, title: "\(n) · Channel mapping", detail: "No channel labels (unlabeled = “discrete”) — required: L R C LFE Ls Rs"))
                } else if layout == "L R C LFE Ls Rs" || layout == "L R" || layout == "L R C LFE Ls Rs Lt Rt" {
                    c.append(Check(level: .ok, title: "\(n) · Channel mapping", detail: layout))
                } else if ch == 1 || layout == "M" || layout == "C" {
                    c.append(Check(level: .warn, title: "\(n) · Channel mapping", detail: "\(layout) — channels must not be labeled Mono"))
                } else {
                    c.append(Check(level: .warn, title: "\(n) · Channel mapping", detail: "\(layout) — the Academy maps L R C LFE Ls Rs"))
                }
            } else if isTrueHD(a) {
                c.append(Check(level: .fail, title: "\(n) · \(a["Format_Commercial_IfAny"] ?? "TrueHD")", detail: "TrueHD is not accepted — ATMOS must be E-AC-3 JOC"))
            } else if isEAC3JOC(a) {
                c.append(Check(level: .ok, title: "\(n) · Atmos", detail: "\(a["Format_Commercial_IfAny"] ?? "") (E-AC-3 JOC)"))
                c.append(Check(level: a["BitRate_Mode"] == "CBR" ? .ok : .fail, title: "\(n) · Bit rate mode",
                               detail: "\(a["BitRate_Mode"] == "CBR" ? "Constant" : a["BitRate_Mode"] ?? "?") · \(a.d("BitRate").map(Fmt.bitrate) ?? "?") (Constant required)"))
                if let ci = a["ComplexityIndex"] {
                    c.append(Check(level: .ok, title: "\(n) · Complexity Index", detail: "Present (\(ci)) · \(a["NumberOfDynamicObjects"] ?? "?") dynamic objects"))
                } else { c.append(Check(level: .fail, title: "\(n) · Complexity Index", detail: "Missing — must be present")) }
                c.append(Check(level: sr == 48000 ? .ok : .warn, title: "\(n) · Sample rate", detail: Fmt.hz(sr)))
            } else if a["Format"] == "AAC" {
                let br = a.d("BitRate") ?? 0
                if isProRes { c.append(Check(level: .fail, title: "\(n) · AAC", detail: "With ProRes the Academy requires PCM")) }
                else {
                    let good = ((ch == 6 && br >= 630_000) || (ch == 2 && br >= 250_000)) && sr == 48000 && (a["Format_Profile"] ?? "LC").contains("LC")
                    c.append(Check(level: good ? .ok : .warn, title: "\(n) · AAC", detail: "\(Fmt.bitrate(br)) · \(Fmt.hz(sr)) · \(ch) ch (AAC LC 640 Kbps for 5.1 or 256 Kbps for stereo, 48 kHz)"))
                }
            } else {
                c.append(Check(level: .fail, title: "\(n) · \(a["Format_Commercial_IfAny"] ?? a["Format"] ?? "?")",
                               detail: "\(a.d("BitRate").map(Fmt.bitrate) ?? "") · \(Fmt.hz(sr)) · \(ch) ch — not in the Academy's list (PCM, AAC LC, or E-AC-3 JOC for Atmos)"))
            }
        }
        if hasAtmos {
            let first = audios.first.map(isEAC3JOC) ?? false
            let second = audios.count > 1 && audios[1]["Format"] == "PCM" && audios[1]["Channels"] == "6"
            c.append(Check(level: first && second ? .ok : .fail, title: "Atmos track layout",
                           detail: first && second ? "Audio 1 = E-AC-3 JOC Atmos · Audio 2 = 5.1 full mix PCM ✓"
                                                   : "Required: Audio 1 = E-AC-3 JOC Atmos, Audio 2 = 5.1 full mix PCM (16/24-bit 48 kHz)"))
            if audios.count > 2 { c.append(Check(level: .warn, title: "Audio tracks", detail: "\(audios.count) tracks — the Atmos layout is exactly Atmos + 5.1 PCM")) }
        }
        if let vd = videos.first?.d("Duration") {
            for (i, a) in audios.enumerated() {
                guard let ad = a.d("Duration") else { continue }
                let diff = ad - vd
                c.append(Check(level: abs(diff) <= 0.05 ? .ok : abs(diff) <= 0.5 ? .warn : .fail, title: "Audio \(i + 1) vs video length",
                               detail: abs(diff) <= 0.05 ? String(format: "Match (%+.0f ms)", diff * 1000) : String(format: "Audio %@ vs video %@ (%+.3f s)", Fmt.duration(ad), Fmt.duration(vd), diff)))
            }
        }
        if tracks.contains(where: { $0.type == "Text" }) {
            c.append(Check(level: .info, title: "Subtitles", detail: "The Academy wants captions/subtitles as separate WebVTT (.vtt) files, not embedded"))
        }
        c.append(Check(level: .info, title: "Loudness", detail: "-27 LKFS ±2 dialogue-gated and -2 dBTP are requested; the Academy may adjust levels (not part of the seal)"))
        return c
    }

    static func level(_ checks: [Check], _ tracks: [MITrack]) -> AcademyLevel {
        if checks.contains(where: { $0.level == .fail }) { return .notApproved }
        let general = tracks.first { $0.type == "General" }
        let v = tracks.first { $0.type == "Video" }
        let audios = tracks.filter { $0.type == "Audio" }
        let preferredVideo = v?["Format"] == "ProRes" && v?["Format_Profile"] == "422 HQ" && general?["Format_Profile"] == "QuickTime"
        let preferredAudio = !audios.isEmpty && audios.allSatisfy { $0["Format"] == "PCM" || isEAC3JOC($0) }
        if preferredVideo && preferredAudio && !checks.contains(where: { $0.level == .warn }) { return .preferred }
        return .accepted
    }
}

// MARK: - Inspection of an existing file

struct InspectionData {
    var tracks: [MITrack] = []
    var report = ""
    var checks: [Check] = []
    var level: AcademyLevel?
    var loudness: [String] = []
    var zidooChecks: [Check] = []          // where it plays: the screening-room Zidoo (Zidoo.swift)
    var zidooLevel: ZidooLevel?
}

enum Inspection {
    static func analyze(_ u: URL) -> InspectionData {
        let t = MediaInfo.tracks(u)
        let black = blackEdges(u, t)
        var checks = Academy.checks(fileName: u.lastPathComponent, t, black: black)
        let level = t.isEmpty ? nil : Academy.level(checks, t)
        if let qt = quickTimeCheck(u, t) { checks.append(qt) }     // compatibility note, not part of the Academy seal
        let zc = t.isEmpty ? [] : Zidoo.checks(t)
        return InspectionData(tracks: t, report: MediaInfo.text(u), checks: checks, level: level, loudness: [],
                              zidooChecks: zc, zidooLevel: t.isEmpty ? nil : Zidoo.level(zc))
    }

    /// Does Apple's own reader (AVFoundation — QuickTime Player, Final Cut, Compressor) see every track?
    static func quickTimeCheck(_ u: URL, _ tracks: [MITrack]) -> Check? {
        let ext = u.pathExtension.lowercased()
        guard ["mov", "mp4", "m4v", "m4a"].contains(ext) else { return nil }
        final class Box: @unchecked Sendable { var video = 0, audio = 0, playable = false, ok = false }
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            let asset = AVURLAsset(url: u)
            if let p = try? await asset.load(.isPlayable), let ts = try? await asset.load(.tracks) {
                box.playable = p
                box.video = ts.filter { $0.mediaType == .video }.count
                box.audio = ts.filter { $0.mediaType == .audio }.count
                box.ok = true
            }
            sem.signal()
        }
        guard sem.wait(timeout: .now() + 60) == .success, box.ok else {
            return Check(level: .info, title: "Apple QuickTime compatibility", detail: "couldn't be evaluated")
        }
        let wantA = tracks.filter { $0.type == "Audio" }.count, wantV = tracks.filter { $0.type == "Video" }.count
        if box.audio >= wantA && box.video >= wantV && box.playable {
            return Check(level: .ok, title: "Apple QuickTime compatibility", detail: "AVFoundation sees every track (\(box.video) video, \(box.audio) audio) and can play the file")
        }
        var why: [String] = []
        if box.audio < wantA { why.append("ignores \(wantA - box.audio) of \(wantA) audio track(s)") }
        if box.video < wantV { why.append("ignores \(wantV - box.video) of \(wantV) video track(s)") }
        if !box.playable { why.append("says the file isn't playable") }
        return Check(level: .warn, title: "Apple QuickTime compatibility", detail: "AVFoundation " + why.joined(separator: ", ") + " — QuickTime Player / Final Cut won't show them")
    }

    /// Seconds of black at the head and tail of the video (nil = couldn't measure)
    static func blackEdges(_ u: URL, _ tracks: [MITrack]) -> BlackEdges? {
        guard let ffmpeg = Tools.ffmpeg, let v = tracks.first(where: { $0.type == "Video" }), let dur = v.d("Duration"), dur > 20 else { return nil }
        let win = 6.0
        let re = try! NSRegularExpression(pattern: "black_start:([0-9.]+) black_end:([0-9.]+)")
        func segments(_ start: Double) -> [(Double, Double)]? {
            let args = ["-nostdin", "-hide_banner", "-nostats", "-ss", String(format: "%.3f", start), "-t", String(format: "%.3f", win),
                        "-i", u.path, "-map", "0:v:0", "-vf", "blackdetect=d=0.04:pic_th=0.98:pix_th=0.10", "-an", "-f", "null", "-"]
            guard let d = Tools.runSync(ffmpeg, args, stderr: true) else { return nil }
            let s = String(decoding: d, as: UTF8.self)
            return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { m in
                guard let a = Range(m.range(at: 1), in: s), let b = Range(m.range(at: 2), in: s),
                      let x = Double(s[a]), let y = Double(s[b]) else { return nil }
                return (x, y)
            }
        }
        guard let headSegs = segments(0), let tailSegs = segments(dur - win) else { return nil }
        let head = headSegs.first { $0.0 < 0.05 }.map { $0.1 } ?? 0
        let tail = tailSegs.last { $0.1 >= win - 0.1 }.map { win - $0.0 } ?? 0
        return BlackEdges(head: head, tail: tail, window: win)
    }

    /// Loudness and true peak (read-only — changes nothing)
    static func loudness(_ u: URL, _ tracks: [MITrack], cancel: CancelFlag, stage: (String) -> Void) -> [String] {
        guard let ffmpeg = Tools.ffmpeg else { return [] }
        let audios = tracks.filter { $0.type == "Audio" }
        var lines: [String] = []
        for (i, a) in audios.enumerated() {
            if cancel.isSet { break }
            stage("Measuring audio \(i + 1) of \(audios.count)…")
            // ebur128 prints its summary on stderr
            let out = Tools.runCancellable(ffmpeg, ["-nostdin", "-hide_banner", "-nostats", "-i", u.path, "-map", "0:a:\(i)",
                                                    "-af", "ebur128=peak=true", "-f", "null", "-"], cancel: cancel, stderr: true)
            if cancel.isSet { break }
            let text = String(decoding: out ?? Data(), as: UTF8.self)
            let summary = text.components(separatedBy: "Summary:").last ?? ""
            func val(_ key: String) -> Double? {
                guard let r = summary.range(of: "\(key)\\s+(-?[0-9.]+)", options: .regularExpression) else { return nil }
                return Double(summary[r].split(separator: " ").last ?? "")
            }
            let I = val("I:"), peak = val("Peak:")
            let what = Academy.isAtmos(a) ? "Atmos (decoded 5.1 core)" : (a["Format_Commercial_IfAny"] ?? a["Format"] ?? "")
            var line = "Audio \(i + 1) · \(what): "
            if let I { line += String(format: "%.1f LUFS integrated (whole program)", I) } else { line += "not measured" }
            if let peak { line += String(format: " · true peak %.1f dBTP", peak) }
            if let I {
                if I > -25 { line += String(format: " · %.1f LU above the -25 edge of -27 ±2", I + 25) }
                else if I < -29 { line += String(format: " · %.1f LU below the -29 edge of -27 ±2", -29 - I) }
                else { line += " · within -27 ±2" }
            }
            if let peak, peak > -2 { line += String(format: " · peak %.1f dB over -2 dBTP", peak + 2) }
            lines.append(line)
        }
        return lines
    }

    static func textReport(_ u: URL, _ d: InspectionData) -> String {
        var s = "\(AppInfo.name) — File check report (Abdala Brothers)\nFile: \(u.path)\nDate: \(Date().formatted(date: .abbreviated, time: .standard))\n\n"
        if let l = d.level { s += "ACADEMY SPECS SEAL: \(l.emoji) \(l.title)\n\(l.explanation)\n(Based on the Academy Screening Room technical specifications — not an official Academy approval.)\n\n" }
        s += "ACADEMY SCREENING ROOM CHECKS\n"
        for c in d.checks { s += "[\(c.level.text)] \(c.title): \(c.detail)\n" }
        if let z = d.zidooLevel {
            s += "\nZIDOO PLAYBACK: \(z.emoji) \(z.title)\n\(z.explanation)\n(\(Zidoo.caveat))\n"
            for c in d.zidooChecks { s += "[\(c.level.text)] \(c.title): \(c.detail)\n" }
        }
        if !d.loudness.isEmpty {
            s += "\nLOUDNESS (read-only — the mix is never changed)\n"
            for l in d.loudness { s += "• \(l)\n" }
        }
        s += "\nFULL REPORT (MediaInfo)\n" + d.report
        return s
    }
}

// MARK: - Job: prepare → MP4Box → channel map → verify → sync (shared by the window and the command line)

/// How an audio track will be trimmed (in samples of the track)
struct TrimPlan {
    let pad: Int       // samples the sound starts later: silence written at the head (PCM) or an edit-list delay (E-AC-3)
    let cut: Int       // samples cut from the head of the source
    let keep: Int      // samples kept from the source
    let total: Int
    var tail: Int { max(0, total - cut - keep) }
    var isIdentity: Bool { pad == 0 && cut == 0 && tail == 0 }
}

struct JobSpec {
    var tracks: [Track]              // included tracks, in final order
    var plans: [UUID: TrimPlan]
    var output: URL
    var disableExtraAudio: Bool
    var interleaveMs: Int
    var writeChannelMap: Bool
    var verifyAudio: Bool
    var verifyVideo: Bool
    var fixColorTag: Bool
    var isMOV: Bool
    var reference: Track?            // sync reference (for the final check)
    var isMKV = false                // MP4Box writes MP4, then the streams are copied into Matroska
    var referenceOffset = 0.0        // the reference is this late (s) vs its picture: the final check corrects for it
    var videoEncode: TranscodePlan? = nil     // playback version: the picture is re-encoded (Transcode.swift)
    var pictureCheck = true                   // after muxing, check the sound against the picture's hard cuts (PictureSync.swift)
}

enum JobState { case ok, warning, failed, cancelled }
struct JobResult { let state: JobState; let lines: [String]; let output: URL?; var inspection: InspectionData? = nil }

final class JobRunner {
    let spec: JobSpec
    let cancel = CancelFlag()
    var onStage: (String, Double) -> Void = { _, _ in }
    var onLog: (String) -> Void = { _ in }
    private let lock = NSLock()
    private var mp4boxProcess: Process?
    private var encodedRPU: URL?          // the Dolby Vision metadata that went into the picture (to read it back after muxing)

    init(_ spec: JobSpec) { self.spec = spec }

    func requestCancel() {
        cancel.set()
        lock.lock(); let p = mp4boxProcess; lock.unlock()
        if let p, p.isRunning { p.terminate() }
    }

    static func estimatedBytes(_ t: Track, plan: TrimPlan?, encode: TranscodePlan? = nil) -> Double {
        if t.kind == .video, let encode { return encode.estimatedBytes }
        if t.kind == .audio, let plan, t.sampleRate > 0 {
            let seconds = Double(plan.pad + plan.keep) / t.sampleRate
            return t.isPCM ? Double((plan.pad + plan.keep) * t.blockAlign) : t.bitRate / 8 * seconds
        }
        if t.bitRate > 0, t.duration > 0 { return t.bitRate / 8 * t.duration }
        // no bitrate: timecode is a few bytes; subtitles/data are small — never count the whole container file
        let fileSize = Double((try? t.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        switch t.kind {
        case .timecode: return 4096
        case .subtitle, .other: return min(fileSize, 50_000_000)
        case .video, .audio: return fileSize
        }
    }

    /// Problems that prevent starting (nothing has been created yet)
    static func validate(_ spec: JobSpec) -> String? {
        if !Tools.missing.isEmpty { return "Missing tools: \(Tools.missing.joined(separator: ", ")). Run: brew install gpac media-info" }
        if spec.tracks.isEmpty { return "No tracks selected." }
        let out = spec.output
        guard ["mov", "mp4", "mkv"].contains(out.pathExtension.lowercased()) else { return "The output must end in .mov, .mp4 or .mkv." }
        var inputs = spec.tracks.flatMap { [$0.url] + $0.members.map(\.url) }
        if let r = spec.reference { inputs.append(r.url); inputs += r.members.map(\.url) }
        if inputs.contains(where: { Tools.sameFile($0, out) }) {
            return "The output can't be one of the source files — choose another name."
        }
        let dir = out.deletingLastPathComponent()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { return "The destination folder doesn't exist." }
        guard FileManager.default.isWritableFile(atPath: dir.path) else { return "No permission to write to the destination folder." }
        for t in spec.tracks where t.kind == .audio {
            if let p = spec.plans[t.id], !p.isIdentity {
                if !t.canTrim { return "Sync trimming isn't supported for “\(t.title)” (\(t.codecName))" + (t.codecKey == "truehd" ? " — a TrueHD encode can't be cut without re-encoding, so it has to start exactly with the picture." : ".") }
                if p.pad > 0 && !t.isPCM && t.codecKey != "eac3" { return "“\(t.title)” is early and would need silence at the head — for \(t.codecName) that means re-encoding. Offset the other tracks instead." }
            }
        }
        if let e = spec.videoEncode {
            if let p = e.problem { return p }
            if e.frames <= 0 || e.width <= 0 { return "Couldn't read the picture's size and length." }
        } else if let v = spec.tracks.first(where: { $0.kind == .video }), v.url.pathExtension.lowercased() == "mxf" {
            return "The picture is an MXF master — it can't be copied into \(out.pathExtension.uppercased()) as it is. Turn on “Encode the picture for playback” (HDR panel)."
        }
        if let a = spec.tracks.first(where: { $0.kind == .audio && $0.url.pathExtension.lowercased() == "mxf" }) {
            return "“\(a.title)” is audio inside an MXF — add the audio as WAV, E-AC-3 or TrueHD files."
        }
        // space: MP4Box writes a temporary file as big as the output before interleaving (+ the encoded picture, + the MKV copy)
        let outBytes = spec.tracks.reduce(0.0) { $0 + estimatedBytes($1, plan: spec.plans[$1.id], encode: spec.videoEncode) }
        let tempBytes = spec.tracks.reduce(0.0) { sum, t in
            guard let p = spec.plans[t.id], !p.isIdentity || t.channelPermutation != nil || t.isGroup else { return sum }   // a reorder-only track gets a full temp copy too; a mono group is always written out
            return sum + estimatedBytes(t, plan: p)
        }
        let need = outBytes * 2 + tempBytes + (spec.videoEncode?.estimatedBytes ?? 0) * 2 + (spec.isMKV ? outBytes : 0) + 1_000_000_000
        if let free = Tools.freeSpace(at: dir), free < need {
            return "Not enough free space on the destination drive: about \(Fmt.bytes(need)) is needed while muxing (the final file will be ~\(Fmt.bytes(outBytes))) and \(Fmt.bytes(free)) is free. Pick another drive with “Save As…”."
        }
        return nil
    }

    func run() -> JobResult {
        if let problem = Self.validate(spec) { return JobResult(state: .failed, lines: [problem], output: nil) }
        // an encode can take all night: keep the Mac awake until the job ends
        let activity = spec.videoEncode == nil ? nil :
            ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: "BROS-MUX is encoding the picture")
        defer { if let activity { ProcessInfo.processInfo.endActivity(activity) } }
        let fm = FileManager.default
        let out = spec.output
        let dir = out.deletingLastPathComponent()
        Self.removeStaleTemps(in: dir)
        let tmp = dir.appendingPathComponent(".BROS-MUX-tmp-\(UUID().uuidString)", isDirectory: true)
        do { try fm.createDirectory(at: tmp, withIntermediateDirectories: false) }
        catch { return JobResult(state: .failed, lines: ["Couldn't create the temporary folder: \(error.localizedDescription)"], output: nil) }
        // MP4Box mis-parses some characters in paths (a '+' in the folder name made it drop the language/name options of
        // every input inside it), so it only ever sees safe paths: a symlink in the system temp folder → our temp folder,
        // which stays on the destination drive.
        var gpacTmp = tmp
        if !Self.gpacSafe(tmp.path) {
            var link = fm.temporaryDirectory.appendingPathComponent("BROS-MUX-\(UUID().uuidString)")
            if !Self.gpacSafe(link.path) { link = URL(fileURLWithPath: "/private/tmp/BROS-MUX-\(UUID().uuidString)") }
            do { try fm.createSymbolicLink(at: link, withDestinationURL: tmp); gpacTmp = link }
            catch { try? fm.removeItem(at: tmp); return JobResult(state: .failed, lines: ["Couldn't create a safe path for MP4Box: \(error.localizedDescription)"], output: nil) }
        }
        defer {
            if gpacTmp != tmp { try? fm.removeItem(at: gpacTmp) }   // removes only the link
            try? fm.removeItem(at: tmp)
        }
        let outName = "output." + (spec.isMKV ? "mp4" : out.pathExtension.lowercased())
        var tmpOut = tmp.appendingPathComponent(outName)
        let cancelledResult = JobResult(state: .cancelled, lines: ["Cancelled — nothing was written to the destination."], output: nil)

        // 1. prepare inputs (sync trims and safe paths)
        var prepared: [Prepared] = []
        var lines: [String] = []
        do {
            for (i, t) in spec.tracks.enumerated() {
                let p = try prepare(t, index: i, tmp: tmp, gpacTmp: gpacTmp)
                prepared.append(p)
                if let n = p.note { lines.append(n) }
            }
        } catch is Cancelled {
            return cancelledResult
        } catch {
            return JobResult(state: .failed, lines: [error.localizedDescription], output: nil)
        }

        // 2. MP4Box
        let args = Self.arguments(spec, prepared: prepared, tmp: gpacTmp, output: gpacTmp.appendingPathComponent(outName))
        onLog("MP4Box " + args.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ") + "\n")
        let status = runMP4Box(args)
        if cancel.isSet { return cancelledResult }
        guard status == 0, fm.fileExists(atPath: tmpOut.path) else {
            return JobResult(state: .failed, lines: ["MP4Box ended with an error (code \(status)). See the log."], output: nil)
        }
        if spec.isMKV {
            onStage("Copying the streams into Matroska (MKV)…", 0.97)
            let mkv = tmp.appendingPathComponent("output.mkv")
            let args = Self.mkvArguments(spec, from: tmpOut, to: mkv)
            onLog("ffmpeg " + args.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ") + "\n")
            let r = Tools.runAll(Tools.ffmpeg ?? "ffmpeg", args)
            if !r.text.isEmpty { onLog(r.text) }
            guard r.status == 0, fm.fileExists(atPath: mkv.path) else {
                return JobResult(state: .failed, lines: lines + ["Couldn't write the MKV (ffmpeg error \(r.status)). See the log."], output: nil)
            }
            try? fm.removeItem(at: tmpOut)
            tmpOut = mkv
        }

        // 3. post-processing on the temporary file
        var ok = true, warn = false
        if let v = spec.tracks.first(where: { $0.kind == .video }) {
            lines.insert(spec.videoEncode.map { "Picture: RE-ENCODED (\($0.source.codecName) → \($0.outputCodecName))" } ?? "Picture: bit-exact copy (\(v.codecName))", at: 0)
        }
        let outStreams = Probe.raw(tmpOut)?.streams ?? []
        func outStream(for i: Int) -> ProbeStream? {
            let t = spec.tracks[i]
            let k = spec.tracks[..<i].filter { $0.kind == t.kind }.count
            let candidates = outStreams.filter { s in
                s.codec_type == t.kind.probeType && (t.kind != .timecode || s.codec_tag_string == "tmcd") && s.disposition?["attached_pic"] != 1
            }
            return k < candidates.count ? candidates[k] : nil
        }
        if outStreams.filter({ $0.codec_type == "audio" }).count != spec.tracks.filter({ $0.kind == .audio }).count ||
           outStreams.filter({ $0.codec_type == "video" }).count != spec.tracks.filter({ $0.kind == .video }).count {
            lines.append("⚠ The final file's track count doesn't match the request."); ok = false
        }

        if spec.isMOV {
            var fixes: [Int: MoovPatcher.AudioFix] = [:]
            let audioIdx = spec.tracks.indices.filter { spec.tracks[$0].kind == .audio }
            for (ordinal, i) in audioIdx.enumerated() {
                let t = spec.tracks[i]
                var f = MoovPatcher.AudioFix(channels: t.channels, sampleRate: t.sampleRate > 0 ? t.sampleRate : 48000)
                if spec.writeChannelMap && t.isPCM {
                    if let tag = t.outputLayoutTag(writeLabels: true) { f.chanTag = tag }
                    else if t.channelPermutation != nil, let target = t.channelTarget {
                        lines.append("“\(t.title)”: no QuickTime layout tag describes \(target.text) — channel labels not written")
                    } else if t.channelMap != .none {
                        lines.append("⚠ “\(t.title)”: the source doesn't declare a 5.1/stereo layout — pick the channel map in Quality & Advanced"); warn = true
                    }
                }
                if let spf = prepared[i].samplesPerFrame { f.samplesPerFrame = spf }
                fixes[ordinal] = f
            }
            onStage("Writing headers (channel labels, Dolby layout for QuickTime)…", 0)
            do { lines += try MoovPatcher.patch(tmpOut, audio: fixes, fixDolby: true) }
            catch { lines.append("⚠ Header fixes: \(error.localizedDescription)"); warn = true }
        }

        let checks = spec.tracks.indices.filter { i in
            let t = spec.tracks[i]
            return (t.kind == .audio && spec.verifyAudio) || (t.kind == .video && spec.verifyVideo && spec.videoEncode == nil)
        }
        if let e = spec.videoEncode {
            onStage("Checking the encoded picture (frames, Dolby Vision, HDR10, HDR10+)…", 0)
            let r = Transcode.verifyElementary(tmpOut, plan: e, rpu: encodedRPU, tmp: tmp, cancel: cancel) { s, p in self.onStage(s, p) }
            if cancel.isSet { return cancelledResult }
            lines += r.lines
            if !r.ok { ok = false }
        }
        for (n, i) in checks.enumerated() {
            let t = spec.tracks[i]
            guard let s = outStream(for: i) else { lines.append("⚠ \(t.kind.label) “\(t.title)”: track not found in the final file ✗"); ok = false; continue }
            let r = Verifier.compare(t, source: prepared[i].verify, out: tmpOut, outStream: s, cancel: cancel) { p in
                self.onStage("Verifying bit for bit \(n + 1) of \(checks.count): \(t.title)" + (p < 0 ? " (hashing the whole video…)" : ""), max(0, p))
            }
            lines.append(r.text)
            if !r.ok { ok = false }
            if cancel.isSet { return cancelledResult }
        }

        if let ref = spec.reference {
            let audios = spec.tracks.indices.filter { spec.tracks[$0].kind == .audio }
            for (n, i) in audios.enumerated() {
                let t = spec.tracks[i]
                guard let s = outStream(for: i) else { continue }
                let r = SyncEngine.measure(ref: SyncEngine.Source(ref),
                                           cand: .init(url: tmpOut, index: s.index, duration: Double(s.duration ?? "") ?? t.duration, channels: s.channels ?? t.channels),
                                           rate: Int(t.sampleRate > 0 ? t.sampleRate : 48000), maxLag: 10, points: 9,
                                           cancel: cancel) { p in
                    self.onStage("Checking sync \(n + 1) of \(audios.count): \(t.title)", p)
                }
                if cancel.isSet { return cancelledResult }
                if let lag = r.lag {
                    let ms = (lag + spec.referenceOffset) * 1000      // vs the picture
                    // broadcast tolerance (ATSC IS-191): sound up to 15 ms early or 45 ms late
                    let good = ms >= -15 && ms <= 45
                    let how = abs(ms) < 0.05 ? "exact sync" : ms > 0 ? "sound \(String(format: "%.1f", ms)) ms late" : "sound \(String(format: "%.1f", -ms)) ms early"
                    let vs = spec.referenceOffset == 0 ? "vs reference" :
                        String(format: "vs picture (reference measured %+.2f ms, it's %.1f ms late vs its own picture)", lag * 1000, spec.referenceOffset * 1000)
                    lines.append("Sync “\(t.title)” \(vs): \(Fmt.ms(ms)) (\(how)) · \(r.inliers)/\(r.points.count) points \(good ? "✓" : "✗")")
                    if !good { ok = false }
                } else {
                    // no correlation with the reference within ±10 s is worse than a measured error, not milder
                    lines.append("Sync “\(t.title)”: no match with the reference within ±10 s — \(r.message) ✗"); ok = false
                }
            }
        }

        // the sound against the picture itself: hard cuts vs sound hits, over the whole film (PictureSync.swift)
        if spec.pictureCheck, let vs = outStreams.first(where: { $0.codec_type == "video" && $0.disposition?["attached_pic"] != 1 }) {
            let fps = PictureSync.fps(of: outStreams)
            let audios = spec.tracks.indices.filter { spec.tracks[$0].kind == .audio }
            let dur = audios.compactMap { outStream(for: $0).flatMap { Double($0.duration ?? "") } }.min() ?? Double(vs.duration ?? "") ?? 0
            if dur > 10, !audios.isEmpty {
                let segs = PictureSync.segments(duration: dur, points: 24, window: 30)
                let cuts = PictureSync.detectCuts(video: tmpOut, index: vs.index, fps: fps, segments: segs, cancel: cancel) { p in
                    self.onStage("Checking the sound against the picture: finding hard cuts", p)
                }
                if cancel.isSet { return cancelledResult }
                for (n, i) in audios.enumerated() {
                    let t = spec.tracks[i]
                    guard let s = outStream(for: i) else { continue }
                    self.onStage("Checking the sound against the picture \(n + 1) of \(audios.count): \(t.title)", 0.95)
                    let src = SyncEngine.Source(url: tmpOut, index: s.index, duration: Double(s.duration ?? "") ?? dur, channels: s.channels ?? t.channels)
                    let r = PictureSync.match(cuts: cuts, curves: PictureSync.curvesFor(src, segments: segs, shift: 0), fps: fps)
                    if cancel.isSet { return cancelledResult }
                    if let o = r.offset {
                        let ms = o * 1000
                        let good = ms >= -15 && ms <= 45
                        if good && r.confident { lines.append("Picture sync “\(t.title)”: \(r.message) ✓") }
                        else if good { lines.append("⚠ Picture sync “\(t.title)”: \(r.message)"); warn = true }
                        else { lines.append("Picture sync “\(t.title)”: \(r.message) ✗"); ok = false }
                    } else {
                        lines.append("⚠ Picture sync “\(t.title)”: \(r.message)"); warn = true
                    }
                }
            }
        }

        // 4. move to the destination (rename on the same drive). A file that failed its own checks never replaces an
        //    existing delivery: it is kept beside it with a _FAILED name, so what was verified before stays intact.
        var finalOut = out
        if !ok && fm.fileExists(atPath: out.path) {
            let dir = out.deletingLastPathComponent(), base = out.deletingPathExtension().lastPathComponent, ext = out.pathExtension
            var n = 0
            repeat { finalOut = dir.appendingPathComponent(base + "_FAILED" + (n == 0 ? "" : "-\(n)")).appendingPathExtension(ext); n += 1 } while fm.fileExists(atPath: finalOut.path)
            lines.append("A check failed, so the existing \(out.lastPathComponent) was left untouched; this result was saved as \(finalOut.lastPathComponent).")
        }
        do {
            if fm.fileExists(atPath: finalOut.path) { _ = try fm.replaceItemAt(finalOut, withItemAt: tmpOut) }
            else { try fm.moveItem(at: tmpOut, to: finalOut) }
        } catch {
            return JobResult(state: .failed, lines: lines + ["Couldn't move the final file into place: \(error.localizedDescription)"], output: nil)
        }
        onStage("Checking the final file against the Academy specs…", 1)
        let insp = Inspection.analyze(finalOut)
        return JobResult(state: ok ? (warn ? .warning : .ok) : .failed, lines: lines, output: finalOut, inspection: insp)
    }

    struct Prepared {
        let path: String; let selector: String?; let rangeEnd: Int?; let verify: VerifySource; let note: String?
        var samplesPerFrame: Int? = nil       // E-AC-3: samples per syncframe (for the QuickTime header)
        var importOptions: [String] = []      // extra MP4Box options (the encoded picture: frame rate, Dolby Vision, colour)
    }

    /// Characters MP4Box/GPAC reads literally in a path (anything else goes through a symlink)
    static func gpacSafe(_ path: String) -> Bool {
        let ok = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 /._-()")
        return path.unicodeScalars.allSatisfy { ok.contains($0) }
    }

    /// Files are written into `tmp` (on the destination drive); MP4Box gets the same files through `gpacTmp` (safe path).
    private func prepare(_ t: Track, index: Int, tmp: URL, gpacTmp: URL) throws -> Prepared {
        if t.kind == .video, let e = spec.videoEncode {
            let r = try Transcode.encodeElementary(e, tmp: tmp, cancel: cancel, stage: { s, p in self.onStage(s, p) }, log: { self.onLog($0) })
            encodedRPU = r.rpu
            return Prepared(path: gpacTmp.appendingPathComponent(r.hevc.lastPathComponent).path, selector: nil, rangeEnd: nil,
                            verify: .none, note: r.notes.joined(separator: "\n"), importOptions: e.importOptions(mov: spec.isMOV))
        }
        if t.kind == .audio, t.isGroup, let plan = spec.plans[t.id] {
            // several mono sounds → one multichannel WAV, frame by frame, in the order chosen (MonoGroup.swift)
            let dst = tmp.appendingPathComponent("audio\(index).wav")
            let ordered = t.orderedMembers
            let bps = t.groupBPS
            let what = t.fromVideoFile ? "streams" : "files"
            let chText = Probe.channelText(t.channels, nil)
            var sources: [ByteSource] = []
            defer { for s in sources { try? s.finish() } }
            for m in ordered { sources.append(try GroupSources.open(m, as: t.codecKey, bps: bps, pad: plan.pad, cut: plan.cut, keep: plan.keep)) }
            let order = t.channelPermutation != nil ? t.channelTarget : t.sourceOrder
            let fmt = GroupSources.fmtChunk(channels: t.channels, sampleRate: t.sampleRate, bps: bps, validBits: t.bitDepth, float: t.isFloatPCM,
                                            order: order?.isComplete == true ? order : nil)
            try GroupSources.writeInterleaved(sources, bps: bps, frames: plan.pad + plan.keep, fmt: fmt, to: dst, cancel: cancel) { p in
                self.onStage("Interleaving \(t.channels) mono \(what) into one \(chText) track “\(t.title)” (sample exact)…", p)
            }
            let sr = t.sampleRate
            var parts = ["\(t.channels) mono \(what) interleaved into one \(chText) PCM track"]
            if let o = order, o.isComplete { parts.append("channels " + o.text + (t.channelPermutation != nil ? " (reordered from \(t.sourceOrder?.text ?? "the file order"))" : "")) }
            else { parts.append("in file order, no channel labels") }
            if plan.cut > 0 { parts.append("cut \(Fmt.int(plan.cut)) samples (\(String(format: "%.3f", Double(plan.cut) / sr)) s) from the head of every channel") }
            if plan.pad > 0 { parts.append("added \(Fmt.int(plan.pad)) samples of silence at the head of every channel") }
            if plan.tail > 0 { parts.append("\(Fmt.int(plan.tail)) samples (\(String(format: "%.3f", Double(plan.tail) / sr)) s) from the tail") }
            return Prepared(path: gpacTmp.appendingPathComponent(dst.lastPathComponent).path, selector: nil, rangeEnd: nil,
                            verify: .group(t, pad: plan.pad, cut: plan.cut, keep: plan.keep),
                            note: "“\(t.title)”: " + parts.joined(separator: ", ") + " — every sample copied as it is, no re-encoding")
        }
        if t.kind == .audio, let plan = spec.plans[t.id], !plan.isIdentity || t.channelPermutation != nil {
            if t.isPCM, let wav = t.wav {
                let dst = tmp.appendingPathComponent("audio\(index).wav")
                let order = t.channelPermutation
                let what = order == nil ? "Trimming" : plan.isIdentity ? "Reordering the channels of" : "Trimming and reordering"
                try WavInfo.writeTrimmed(wav, from: t.url, to: dst, pad: plan.pad, cut: plan.cut, keep: plan.keep, order: order, cancel: cancel) { p in
                    self.onStage("\(what) “\(t.title)” (PCM, sample exact)…", p)
                }
                let sr = t.sampleRate
                var parts: [String] = []
                if plan.cut > 0 { parts.append("cut \(Fmt.int(plan.cut)) samples (\(String(format: "%.3f", Double(plan.cut) / sr)) s) from the head") }
                if plan.pad > 0 { parts.append("added \(Fmt.int(plan.pad)) samples of silence at the head") }
                if plan.tail > 0 { parts.append("\(Fmt.int(plan.tail)) samples (\(String(format: "%.3f", Double(plan.tail) / sr)) s) from the tail") }
                if let order, let src = t.sourceOrder, let target = t.channelTarget {
                    parts.append("channels reordered \(src.text) → \(target.text) (" + order.enumerated().map { "\($0 + 1)←\($1 + 1)" }.joined(separator: " ") + ")")
                }
                return Prepared(path: gpacTmp.appendingPathComponent(dst.lastPathComponent).path, selector: nil, rangeEnd: nil,
                                verify: .wav(t.url, wav, pad: plan.pad, cut: plan.cut, keep: plan.keep, order: order),
                                note: "“\(t.title)”: " + parts.joined(separator: ", ") + " — sample exact, no re-encoding")
            }
            if t.codecKey == "eac3" {
                let dst = tmp.appendingPathComponent("audio\(index).ec3")
                let s = try EAC3.slice(t.url, index: t.streamIndex, cut: plan.cut, keep: plan.keep, to: dst, cancel: cancel) { p in
                    self.onStage("Trimming “\(t.title)” (Dolby frames, no re-encoding)…", p)
                }
                let sr = t.sampleRate > 0 ? t.sampleRate : 48000
                let residual = Double(plan.cut - s.skippedSamples) / sr * 1000
                let tailFrames = s.tailAUs
                var note = "“\(t.title)”: cut \(s.skippedAUs) Dolby frames (\(String(format: "%.3f", Double(s.skippedSamples) / sr)) s) from the head and \(tailFrames) from the tail — frames copied byte for byte; " +
                    (abs(residual) < 0.01 ? "exact alignment" : String(format: "sound ends up %.1f ms late (Dolby frame boundary = 32 ms; imperceptible)", residual))
                var options: [String] = []
                if plan.pad > 0 {
                    // the sound has to start later: a start delay in the container (an empty edit in the track's edit list) —
                    // the frames themselves are never touched. Without moovts MP4Box quantises the delay to 1/600 s (up to
                    // 1.7 ms early); moovts=-1 computes it in the audio's own clock: exact in MP4/MKV, and in MOV (where
                    // QuickTime makes the movie run at the picture's clock, e.g. 2400/s) rounded to under half a millisecond
                    options.append("delay=\(plan.pad)/\(Int(sr))")
                    options.append("moovts=-1")
                    note = "“\(t.title)”: starts \(String(format: "%.3f", Double(plan.pad) / sr)) s later by a start delay in the container (edit list, no frame touched)" +
                        (tailFrames > 0 ? "; \(tailFrames) Dolby frames cut from the tail" : "") + " — frames copied byte for byte"
                }
                return Prepared(path: gpacTmp.appendingPathComponent(dst.lastPathComponent).path, selector: nil, rangeEnd: nil,
                                verify: .eac3(t.url, t.streamIndex, skip: s.skippedAUs, keep: s.keptAUs), note: note,
                                samplesPerFrame: s.samplesPerAU, importOptions: options)
            }
            throw AppError("Sync trimming isn't supported for “\(t.title)”.")
        }
        var path = t.url.path
        if !Self.gpacSafe(path) {
            let ext = t.url.pathExtension.isEmpty ? "bin" : t.url.pathExtension
            let link = tmp.appendingPathComponent("input\(index).\(ext)")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: t.url)
            path = gpacTmp.appendingPathComponent(link.lastPathComponent).path
        }
        let spf = t.codecKey == "eac3" ? EAC3.samplesPerFrame(t.url, t.streamIndex) : nil
        let verify: VerifySource
        if t.kind == .audio, t.isPCM, let wav = t.wav {
            verify = .wav(t.url, wav, pad: 0, cut: 0, keep: wav.dataSize / wav.blockAlign)
        } else if t.kind == .audio || t.kind == .video {
            verify = .ffmpeg(t.url, t.streamIndex)
        } else { verify = .none }
        let range = t.wav.flatMap { $0.hasTrailingChunks ? $0.dataEnd : nil }
        return Prepared(path: path, selector: t.selector, rangeEnd: range, verify: verify, note: nil, samplesPerFrame: spf)
    }

    static func arguments(_ spec: JobSpec, prepared: [Prepared], tmp: URL, output: URL) -> [String] {
        var args: [String] = []
        var firstAudio = true
        for (t, p) in zip(spec.tracks, prepared) {
            var item = p.path + (p.selector ?? "")
            var opts: [String] = []
            if t.kind != .timecode { opts.append("lang=\(t.language)") }
            let name = Fmt.ascii(t.title).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { opts.append("name=\(name)") }
            var enabled = t.enabled
            if t.kind == .audio {
                opts.append("group=1")      // a single alternate group: players play one audio track at a time
                if spec.disableExtraAudio { enabled = firstAudio }
                firstAudio = false
            }
            if t.kind == .subtitle { opts.append("group=2") }
            opts.append(enabled ? "disable=no" : "disable")   // explicit: MP4Box otherwise keeps the source's flag
            if t.kind == .video && spec.fixColorTag && spec.videoEncode == nil { opts.append("colr=nclc,1,1,1") }
            opts += p.importOptions
            if let end = p.rangeEnd { opts.append("sopt:range=0-\(end)") }   // must be the last option
            for o in opts { item += ":" + o }
            args += ["-add", item]
        }
        args += ["-inter", "\(spec.interleaveMs)", "-moovpad", "4096", "-tmp", tmp.path, "-new", output.path]
        return args
    }

    /// MP4 → MKV, stream copy; names, languages and default flags are written explicitly (timecode has no place in MKV)
    static func mkvArguments(_ spec: JobSpec, from src: URL, to dst: URL) -> [String] {
        var a = ["-nostdin", "-v", "error", "-i", src.path, "-map", "0:v?", "-map", "0:a?", "-map", "0:s?", "-c", "copy", "-c:s", "srt"]
        var count: [TrackKind: Int] = [:]
        var firstAudio = true, defaultAudioGiven = false
        for t in spec.tracks where t.kind == .video || t.kind == .audio || t.kind == .subtitle {
            let k = count[t.kind, default: 0]; count[t.kind] = k + 1
            let s = t.kind == .video ? "v" : t.kind == .audio ? "a" : "s"
            a += ["-metadata:s:\(s):\(k)", "title=\(Fmt.ascii(t.title))", "-metadata:s:\(s):\(k)", "language=\(t.language)"]
            var enabled = t.enabled
            if t.kind == .audio {      // Matroska: one default audio track (the first one that's on)
                if spec.disableExtraAudio { enabled = firstAudio }
                firstAudio = false
                enabled = enabled && !defaultAudioGiven
                if enabled { defaultAudioGiven = true }
            }
            var disp = enabled ? ["default"] : []
            if t.kind == .subtitle && t.badges.contains("Forced") { disp.append("forced") }
            a += ["-disposition:\(s):\(k)", disp.isEmpty ? "0" : disp.joined(separator: "+")]
        }
        return a + ["-y", dst.path]
    }

    private static let ansi = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;]*m")
    private static let prog = try! NSRegularExpression(pattern: "^(.+?): \\|[= ]*\\| \\((\\d+)/100\\)")

    private func runMP4Box(_ args: [String]) -> Int32 {
        guard let mp4box = Tools.mp4box else { return -1 }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: mp4box)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        let n = max(spec.tracks.count, 1)
        var importIndex = 0, lastPct = -1
        var pendingText = ""
        let handle: (String) -> Void = { raw in
            let clean = JobRunner.ansi.stringByReplacingMatches(in: raw, range: NSRange(raw.startIndex..., in: raw), withTemplate: "")
            for line in clean.replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n") {
                let l = line.trimmingCharacters(in: .whitespaces)
                if l.isEmpty { continue }
                if let m = JobRunner.prog.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)),
                   let r1 = Range(m.range(at: 1), in: l), let r2 = Range(m.range(at: 2), in: l), let pct = Int(l[r2]) {
                    if l[r1].hasPrefix("Import") {
                        if pct < lastPct { importIndex = min(importIndex + 1, n - 1) }
                        lastPct = pct
                        self.onStage("MP4Box: copying track \(importIndex + 1) of \(n)", (Double(importIndex) + Double(pct) / 100) / Double(n + 1))
                    } else {
                        lastPct = 101
                        self.onStage("MP4Box: writing the final file", (Double(n) + Double(pct) / 100) / Double(n + 1))
                    }
                } else {
                    self.onLog(l + "\n")
                    if l.contains("Interleaving") || l.hasPrefix("Saving") { self.onStage("MP4Box: interleaving", Double(n) / Double(n + 1)) }
                }
            }
        }
        let queue = DispatchQueue(label: "mp4box.out")
        pipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            guard !d.isEmpty else { return }
            queue.sync {
                pendingText += String(decoding: d, as: UTF8.self)
                if let cut = pendingText.lastIndex(where: { $0 == "\n" || $0 == "\r" }) {
                    let ready = String(pendingText[...cut]); pendingText = String(pendingText[pendingText.index(after: cut)...])
                    handle(ready)
                }
            }
        }
        do { try p.run() } catch { pipe.fileHandleForReading.readabilityHandler = nil; onLog("Couldn't start MP4Box: \(error.localizedDescription)\n"); return -1 }
        lock.lock(); mp4boxProcess = p; lock.unlock()
        if cancel.isSet { p.terminate() }
        p.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        let rest = pipe.fileHandleForReading.readDataToEndOfFile()
        queue.sync {
            pendingText += String(decoding: rest, as: UTF8.self)
            if !pendingText.isEmpty { handle(pendingText + "\n"); pendingText = "" }
        }
        try? pipe.fileHandleForReading.close()
        lock.lock(); mp4boxProcess = nil; lock.unlock()
        return p.terminationReason == .exit ? p.terminationStatus : -2
    }

    /// Deletes old temporary folders (> 24 h) left by an interrupted run
    static func removeStaleTemps(in dir: URL) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey], options: []) else { return }
        for u in items where u.lastPathComponent.hasPrefix(".BROS-MUX-tmp-") {
            if let d = try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               Date().timeIntervalSince(d) > 24 * 3600 { try? fm.removeItem(at: u) }
        }
    }
}

// MARK: - Project (window state)

enum Container: String, CaseIterable, Identifiable {
    case mov, mp4, mkv
    var id: String { rawValue }
    var label: String { switch self { case .mov: return "MOV (QuickTime)"; case .mp4: return "MP4"; case .mkv: return "MKV" } }
}

enum RunState: Equatable {
    case idle, running, done(URL?), failed, cancelled
}

enum AppMode: String, CaseIterable, Identifiable {
    case mux, transcode, inspect, atmos, qc
    var id: String { rawValue }
    var label: String {
        switch self { case .mux: return "Mux"; case .transcode: return "Transcode"; case .inspect: return "File Checker"; case .atmos: return "Atmos Visualizer"; case .qc: return "Render QC" }
    }
    var symbol: String {
        switch self { case .mux: return "square.stack.3d.down.forward"; case .transcode: return "arrow.triangle.2.circlepath"; case .inspect: return "checkmark.seal"; case .atmos: return "cube.transparent"; case .qc: return "checkmark.shield" }
    }
}

@Observable
final class Project {
    var mode: AppMode = .mux { didSet { if mode != .atmos { atmos.pause() } } }
    let inspector = Inspector()
    let atmos = AtmosVisualizer()
    let hdr = HDRSettings()

    var tracks: [Track] = []
    var container: Container = .mov { didSet { fixOutputExtension() } }
    var outputURL: URL?
    var loadingCount = 0
    var notices: [String] = []

    // options
    var disableExtraAudio = false
    var matchVideoEnd = true
    var syncReferenceID: UUID?
    /// How many frames the reference audio (e.g. the video's own stereo) is LATE vs its own picture. The alignment and the
    /// final check then follow the picture instead of that audio. Changing it moves the tracks already aligned.
    var referenceLateFrames = 0.0 {
        didSet {
            let d = (referenceLateFrames - oldValue) / max(videoFPS.value, 1)
            for i in tracks.indices where tracks[i].kind == .audio && tracks[i].syncApplied {
                tracks[i].trimStart += Int((d * tracks[i].sampleRate).rounded())
            }
        }
    }
    var referenceOffset: Double { referenceLateFrames / max(videoFPS.value, 1) }
    var fixColorTag = false
    var writeChannelMap = true
    var verifyAudio = true
    var verifyVideo = false
    var pictureCheck = true
    var interleaveMs = 500

    // run
    var state: RunState = .idle
    var stage = ""
    var progress: Double = 0
    var log = ""
    var resultLines: [String] = []
    var resultState: JobState = .ok
    var resultInspection: InspectionData?

    // alignment
    var aligning = false
    var alignStage = ""
    var alignProgress = 0.0
    var alignLines: [String] = []

    @ObservationIgnored private var runner: JobRunner?
    @ObservationIgnored private var alignCancel: CancelFlag?
    @ObservationIgnored private var userChoseOutput = false
    @ObservationIgnored private var outputSource: URL?

    var included: [Track] { tracks.filter(\.include) }
    var includedCount: Int { included.count }
    var audioTracks: [Track] { tracks.filter { $0.kind == .audio } }
    var reference: Track? { tracks.first { $0.id == syncReferenceID && $0.kind == .audio } }
    var videoTrack: Track? { included.first { $0.kind == .video } }
    var busy: Bool { state == .running || aligning || loadingCount > 0 }

    // MARK: HDR (see HDR.swift)

    var videoFPS: Rational {
        if let imf = hdr.imf, videoTrack?.imfSegments.isEmpty == false { return imf.editRate }
        let mi = videoTrack?.mi
        if let n = mi?["FrameRate_Num"], let d = mi?["FrameRate_Den"], let r = Rational("\(n) \(d)") { return r }
        return Rational(mi?["FrameRate"] ?? "") ?? Rational(24, 1)
    }
    var videoFrames: Int {
        guard let v = videoTrack else { return 0 }
        if !v.imfSegments.isEmpty { return v.imfSegments.reduce(0) { $0 + $1.frames } }
        if let n = v.mi?["FrameCount"].flatMap({ Int($0) }), n > 0 { return n }
        return Int((v.duration * videoFPS.value).rounded())
    }
    var videoDuration: Double { Double(videoFrames) / max(videoFPS.value, 1) }   // the part of the picture that's used (an IMF CPL may use part of the MXF)
    var videoWidth: Int { videoTrack?.mi?["Width"].flatMap { Int($0) } ?? 0 }
    var videoHeight: Int { videoTrack?.mi?["Height"].flatMap { Int($0) } ?? 0 }
    /// An HDR picture, an IMF package or Dolby Vision metadata: the HDR panel shows
    var hdrRelevant: Bool {
        if hdr.imf != nil || hdr.dvSource != nil { return true }
        guard let v = videoTrack else { return false }
        let t = v.mi?["transfer_characteristics"] ?? ""
        return t == "PQ" || t == "HLG" || v.mi?["HDR_Format"] != nil || v.url.pathExtension.lowercased() == "mxf"
    }
    /// What the job will encode (nil = the picture is copied). The Mux tab's one exception: HEVC 10-bit with the source's
    /// own colour and the Dolby Vision / HDR10+ metadata — built on the same TranscodePlan the Transcode tab uses.
    var encodePlan: TranscodePlan? {
        guard hdr.encode, let v = videoTrack, let src = v.source else { return nil }
        var p = TranscodePlan(source: src, video: .hevc(quality: hdr.quality, speed: hdr.speed, rate: hdr.rate))
        p.segments = v.imfSegments.isEmpty
            ? [.init(file: v.url, start: 0, count: videoFrames)]
            : v.imfSegments.flatMap { r in Array(repeating: TranscodePlan.Segment(file: r.file, start: r.entryPoint, count: r.duration), count: r.repeatCount) }
        p.frames = videoFrames; p.fps = videoFPS; p.width = videoWidth; p.height = videoHeight
        p.rgbSource = (v.mi?["ColorSpace"] ?? "").contains("RGB") || src.color.isRGB
        let dv = hdr.dolbyVision ? hdr.dvSource : nil
        p.hdr = HDRMeta(mastering: hdr.mastering, maxCLL: hdr.maxCLL, maxFALL: hdr.maxFALL, dolbyVision: dv,
                        dvXML: dv == nil ? nil : hdr.dvXMLReady, hdr10plus: hdr.hdr10plus ? hdr.hdr10plusJSON : nil)
        p.container = container
        p.audio = .none          // the audio goes through the bit-exact mux path, never through ffmpeg
        return p
    }
    /// Problems with the HDR metadata that stop the job before any encoding
    var hdrProblem: String? {
        guard hdr.encode else { return nil }
        if let c = videoTrack?.source?.color, c.isTagged, !c.isHDR, c.transfer != nil {
            return "The picture is tagged \(SourceColor.name(c.primaries)) / \(SourceColor.name(c.transfer)) (SDR): HDR10 and Dolby Vision metadata can't describe it. Check the source, or make an SDR HEVC in the Transcode tab."
        }
        if hdr.dolbyVision && hdr.dvSource != nil {
            if hdr.dvChecking { return "Still reading the Dolby Vision metadata — try again in a moment." }
            if let p = hdr.dvProblem { return p }
        }
        if hdr.hdr10plus && hdr.hdr10plusJSON != nil {
            if let p = hdr.hdr10plusProblem { return p }
            if let n = hdr.hdr10plusFrames, n >= 0, n != videoFrames { return "The HDR10+ metadata has \(Fmt.int(n)) frames but the picture has \(Fmt.int(videoFrames))." }
        }
        return nil
    }

    struct IMFLoad { var package: IMFPackage?; var tracks: [Track] = []; var notices: [String] = []; var dv: DolbyVisionMeta.Source? }

    /// Reads an IMF package: the picture (MXF), its Dolby Vision metadata track, and what can't be used (IAB, PCM)
    static func readIMF(_ u: URL) -> IMFLoad {
        var r = IMFLoad()
        do {
            let pkg = try IMF.load(u)
            r.package = pkg
            r.notices += pkg.notes
            if let seq = pkg.first(.image), let first = seq.resources.first {
                let probe = Probe.tracks(for: first.file)
                if let e = probe.error { r.notices.append(e) }
                if var v = probe.tracks.first(where: { $0.kind == .video }) {
                    v.imfSegments = seq.resources
                    r.tracks.append(v)
                }
            }
            if let dv = pkg.first(.dolbyVision) {
                r.dv = .isxd(dv.resources.flatMap { res in
                    Array(repeating: DolbyVisionMeta.ISXDPart(file: res.file, entry: res.entryPoint, count: res.duration), count: res.repeatCount)
                })
            }
            let iab = pkg.all(.iab)
            if !iab.isEmpty {
                r.notices.append("The IMF has \(iab.count) IAB audio track\(iab.count == 1 ? "" : "s") — Dolby Atmos in the cinema/IMF format, which no player plays. Add a Dolby encode of the same mix: E-AC-3 JOC (.ec3/.mp4) for Apple and TVs, or TrueHD Atmos (.thd/.mlp/.mka) for home theater.")
            }
            if !pkg.all(.pcm).isEmpty { r.notices.append("The IMF's PCM audio (MXF) isn't imported — add the audio as WAV files.") }
        } catch { r.notices.append(error.localizedDescription) }
        return r
    }

    func applyIMF(_ r: IMFLoad, check: Bool = true) {
        notices += r.notices
        guard let pkg = r.package, !r.tracks.isEmpty else { return }
        tracks.removeAll { $0.kind == .video }          // the IMF picture replaces any other video
        hdr.imf = pkg
        insert(r.tracks)
        hdr.encode = true
        hdr.autoEnabledBy = pkg.cpl
        hdr.autoReason = "An IMF package was added. Its master picture (JPEG 2000 in MXF) plays nowhere, so a playback version is made: HEVC 10-bit" + (r.dv != nil ? " with the package's Dolby Vision metadata." : ".")
        hdr.applySourceMastering(videoTrack?.mi)
        if let dv = r.dv {
            hdr.dvSource = dv; hdr.dolbyVision = true
            if check { hdr.checkDolbyVision(width: videoWidth, height: videoHeight, frames: videoFrames) }
        }
        // the playback file goes next to the package (never inside it), named after the CPL
        if !userChoseOutput {
            outputSource = r.tracks.first?.url
            outputURL = uniqueURL(pkg.folder.deletingLastPathComponent(), Fmt.academyName(pkg.title) + "_DV_HDR", container.rawValue)
        }
    }

    func loadIMF(_ u: URL) {
        loadingCount += 1
        notices.removeAll()
        if case .done = state { state = .idle }
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Self.readIMF(u)
            DispatchQueue.main.async { self.loadingCount -= 1; self.applyIMF(r); self.chooseDefaultReference() }
        }
    }
    var canRun: Bool { Tools.missing.isEmpty && outputURL != nil && includedCount > 0 && !busy }

    // MARK: files

    func add(_ urls: [URL]) {
        if mode == .inspect, let u = urls.first { inspector.load(u); return }
        if mode == .atmos, let u = urls.first { atmos.load(u); return }
        if mode == .qc, let u = urls.first { RenderQCModel.shared.open(u); return }
        if mode == .transcode { TranscodeModel.shared.add(urls); return }
        guard !busy else { return }
        // IMF packages (a folder with an ASSETMAP, or its CPL) are read as one picture
        let imfs = urls.filter { IMF.packageFolder(for: $0) != nil }
        if let u = imfs.first { loadIMF(u) }
        // HDR metadata dropped with the files: a Dolby Vision XML, an HDR10+ JSON
        var metadata: [URL] = []
        for u in urls where !imfs.contains(u) {
            let ext = u.pathExtension.lowercased()
            if ext == "xml", IMF.rootName(u) == "DolbyLabsMDF" {
                hdr.dvSource = .xml(u); hdr.dolbyVision = true; hdr.encode = true; metadata.append(u)
                hdr.autoEnabledBy = u; hdr.autoReason = "Dolby Vision metadata was added. To embed it, the picture has to become HEVC 10-bit, so BROS-MUX turned the re-encoding on by itself." 
                hdr.checkDolbyVision(width: videoWidth, height: videoHeight, frames: videoFrames)
            } else if ext == "json", let n = HDR10Plus.frames(u) {
                hdr.hdr10plusJSON = u; hdr.hdr10plus = true; hdr.hdr10plusFrames = n; hdr.encode = true; metadata.append(u)
                hdr.autoEnabledBy = u; hdr.autoReason = "HDR10+ metadata was added. To embed it, the picture has to become HEVC 10-bit, so BROS-MUX turned the re-encoding on by itself." 
            }
        }
        var files: [URL] = []
        for u in urls where !imfs.contains(u) && !metadata.contains(u) {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue {
                let items = (try? FileManager.default.contentsOfDirectory(at: u, includingPropertiesForKeys: nil)) ?? []
                files += items.filter { !$0.lastPathComponent.hasPrefix(".") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            } else { files.append(u) }
        }
        guard !files.isEmpty else { return }
        loadingCount += 1
        notices.removeAll()
        if case .done = state { state = .idle }
        // read in the order the files were given (predictable result); each file shows up in the list as soon as it
        // has been read, so a long batch is not one long wait in front of an empty list
        DispatchQueue.global(qos: .userInitiated).async {
            for f in files {
                let r = Probe.tracks(for: f)
                DispatchQueue.main.async {
                    if let e = r.error { self.notices.append(e) }
                    self.insert(r.tracks)
                }
            }
            DispatchQueue.main.async {
                self.loadingCount -= 1
                self.autoGroup()
                self.chooseDefaultReference()
            }
        }
    }

    func insert(_ new: [Track]) {
        guard !new.isEmpty else { return }
        // order: video, timecode, Atmos, other standalone audio, audio embedded in the video, subtitles, other
        // (the Academy's Atmos layout: audio 1 = E-AC-3 JOC Atmos, audio 2 = 5.1 PCM)
        func rank(_ t: Track) -> Int {
            switch t.kind {
            case .video: return 0
            case .timecode: return 1
            case .audio: return t.isAtmos ? 2 : (t.fromVideoFile ? 4 : 3)
            case .subtitle: return 5
            case .other: return 6
            }
        }
        for t in new {
            let pos = tracks.lastIndex { rank($0) <= rank(t) }.map { $0 + 1 } ?? 0
            tracks.insert(t, at: pos)
        }
        if let v = new.first(where: { $0.kind == .video }) {
            hdr.applySourceMastering(v.mi)
            if hdr.dvSource != nil && hdr.imf == nil { hdr.checkDolbyVision(width: videoWidth, height: videoHeight, frames: videoFrames) }
        }
        // the default name follows the video (which may be read after the audio) until the user picks "Save As…"
        let video = tracks.first(where: { $0.kind == .video })
        if !userChoseOutput, outputURL == nil || (video != nil && outputSource != video?.url),
           let v = video ?? tracks.first {
            outputSource = v.url
            let base = Fmt.academyName(v.url.deletingPathExtension().lastPathComponent) + "_MUX"
            outputURL = uniqueURL(v.url.deletingLastPathComponent(), base, container.rawValue)
        }
    }

    /// If the video has its own audio (a guide stereo or mono) and there are standalone audio files, the video's audio
    /// becomes the sync reference (and leaves the output). A 5.1 inside the video is a deliverable, not a guide: it stays.
    func chooseDefaultReference() {
        guard reference == nil,
              let ref = tracks.first(where: { $0.kind == .audio && $0.fromVideoFile && $0.channels <= 2 }),
              tracks.contains(where: { $0.kind == .audio && !$0.fromVideoFile }) else { return }
        syncReferenceID = ref.id
        if let i = tracks.firstIndex(where: { $0.id == ref.id }), tracks[i].include {
            tracks[i].include = false
            notices.append("The video's own audio (“\(ref.title)”) is now the sync reference and won't be in the output. Check its box if you want to include it.")
        }
    }

    // MARK: mono sounds as one track (MonoGroup.swift)

    /// Mono PCM tracks still on their own
    var groupCandidates: [Track] { tracks.filter { $0.kind == .audio && $0.isPCM && $0.channels == 1 && !$0.isGroup } }
    /// The sets that would be grouped: the mono streams of each movie file, and all standalone mono files together
    static func groupSets(_ monos: [Track]) -> [[Track]] {
        var sets: [String: [Track]] = [:], order: [String] = []
        for t in monos {
            let k = t.fromVideoFile ? t.url.path : "standalone"
            if sets[k] == nil { order.append(k) }
            sets[k, default: []].append(t)
        }
        return order.compactMap { k in sets[k].flatMap { Track.groupable($0) ? $0 : nil } }
    }
    /// After a batch of files is read: mono sounds that form a standard layout become one track
    func autoGroup() {
        for set in Self.groupSets(groupCandidates) { makeGroup(set.map(\.id)) }
    }
    func makeGroup(_ ids: [UUID]) {
        let members = ids.compactMap { id in tracks.first { $0.id == id } }
        guard members.count >= 2, var g = Track.group(members) else { return }
        let pos = tracks.firstIndex { $0.id == members[0].id } ?? tracks.count
        if let r = syncReferenceID, ids.contains(r) {
            // the reference was one of the monos: a guide stereo stays the reference; a 5.1 is a deliverable and comes back in
            if g.channels <= 2 { syncReferenceID = g.id; g.include = false } else { syncReferenceID = nil }
        }
        tracks.removeAll { t in ids.contains(t.id) }
        tracks.insert(g, at: min(pos, tracks.count))
        let what = g.fromVideoFile ? "mono streams of \(g.url.lastPathComponent)" : "mono files"
        if let roles = g.channelRoles {
            notices.append("\(members.count) \(what) are one \(Probe.channelText(g.channels, nil)) track: \(ChannelOrder(roles: roles).text) (\(g.rolesSource ?? "")). “Channels…” on the track changes or ungroups them.")
        } else {
            notices.append("\(members.count) \(what) are one \(Probe.channelText(g.channels, nil)) track; which is which isn't in the files or their names, so the app is listening to them. “Channels…” on the track changes or ungroups them.")
            listen(to: g.id)
        }
    }
    func ungroup(_ id: UUID) {
        guard let i = tracks.firstIndex(where: { $0.id == id }), tracks[i].isGroup else { return }
        let g = tracks.remove(at: i)
        var members = g.members
        for k in members.indices { members[k].include = g.include; members[k].language = g.language }
        tracks.insert(contentsOf: members, at: i)
        if syncReferenceID == id { syncReferenceID = nil }
    }
    /// Listens to a group in the background (ChannelID over the members) and fills in the roles if nobody set them meanwhile
    func listen(to id: UUID) {
        guard let i = tracks.firstIndex(where: { $0.id == id }), tracks[i].isGroup, !tracks[i].listening else { return }
        tracks[i].listening = true
        let g = tracks[i]
        DispatchQueue.global(qos: .userInitiated).async {
            let r = ChannelID.analyzeGroup(g)
            DispatchQueue.main.async {
                guard let j = self.tracks.firstIndex(where: { $0.id == id }), self.tracks[j].isGroup else { return }
                self.tracks[j].listening = false
                guard self.tracks[j].channelRoles == nil, let r else { return }
                let roles = r.guesses.map(\.role)
                self.tracks[j].channelRoles = roles
                self.tracks[j].channelConfidence = r.overall
                self.tracks[j].channelReport = r.text
                self.tracks[j].rolesSource = "heard"
                let order = ChannelOrder(roles: roles)
                self.tracks[j].channelTarget = order.isComplete ? ChannelOrder.presets(channels: roles.count).first?.order : nil
            }
        }
    }

    func uniqueURL(_ dir: URL, _ base: String, _ ext: String) -> URL {
        var u = dir.appendingPathComponent(base).appendingPathExtension(ext)
        var n = 2
        while FileManager.default.fileExists(atPath: u.path) {
            u = dir.appendingPathComponent("\(base)_\(n)").appendingPathExtension(ext); n += 1
        }
        return u
    }

    private func fixOutputExtension() {
        guard let u = outputURL else { return }
        let base = u.deletingPathExtension()
        outputURL = userChoseOutput ? base.appendingPathExtension(container.rawValue)
                                    : uniqueURL(base.deletingLastPathComponent(), base.lastPathComponent, container.rawValue)
    }

    func remove(_ id: UUID) {
        tracks.removeAll { $0.id == id }
        if syncReferenceID == id { syncReferenceID = nil }
    }

    func clear() {
        guard !busy else { return }
        tracks.removeAll(); outputURL = nil; state = .idle; log = ""; notices = []; resultLines = []; alignLines = []
        referenceLateFrames = 0          // a correction measured on one film must not follow into the next
        resultInspection = nil; userChoseOutput = false; outputSource = nil; syncReferenceID = nil
        hdr.reset()
    }

    func openPanel() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = mode == .mux || mode == .transcode
        p.canChooseDirectories = mode == .mux || mode == .transcode
        p.canChooseFiles = true
        p.message = mode == .mux ? "Choose the video, audio and subtitle files (or an IMF package folder)" : mode == .transcode ? "Choose the files to transcode (a new file is written for each; the originals are never touched)" : mode == .inspect ? "Choose the file to inspect" : mode == .qc ? "Choose the rendered file to check" : "Choose a Dolby Atmos (E-AC-3 JOC) file"
        p.prompt = mode == .mux || mode == .transcode ? "Add" : mode == .inspect ? "Inspect" : mode == .qc ? "Check" : "Visualize"
        if p.runModal() == .OK { add(p.urls) }
    }

    func chooseOutput() {
        let p = NSSavePanel()
        p.allowedContentTypes = [container == .mov ? .quickTimeMovie : container == .mp4 ? .mpeg4Movie : (UTType(filenameExtension: "mkv") ?? .movie)]
        p.canCreateDirectories = true
        p.nameFieldStringValue = outputURL?.lastPathComponent ?? "Output.\(container.rawValue)"
        if let dir = outputURL?.deletingLastPathComponent() { p.directoryURL = dir }
        p.message = "Where should the final file go? (Academy file names: letters, numbers, period, _ and - only)"
        if p.runModal() == .OK, let u = p.url { setOutput(u) }
    }

    /// The destination as folder + name (the Render-style panel edits them separately; the extension follows the container)
    var outputFolder: URL? {
        get { outputURL?.deletingLastPathComponent() }
        set { if let f = newValue { setOutput(f.appendingPathComponent(outputURL?.lastPathComponent ?? "Output.\(container.rawValue)")) } }
    }
    var outputName: String {
        get { outputURL?.deletingPathExtension().lastPathComponent ?? "" }
        set {
            let clean = newValue.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
            guard !clean.isEmpty, let dir = outputURL?.deletingLastPathComponent() else { return }
            setOutput(dir.appendingPathComponent(clean).appendingPathExtension(container.rawValue))
        }
    }
    var outputFree: Double? { outputURL.flatMap { Tools.freeSpace(at: $0.deletingLastPathComponent()) } }
    /// free space needed while muxing: the temp copy and the final file live side by side on the destination drive
    var outputNeeded: Double { estimatedSize * 2 }

    func chooseOutputFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true; p.allowsMultipleSelection = false
        p.prompt = "Choose"
        p.message = "Where should the final file go?"
        if let dir = outputURL?.deletingLastPathComponent() { p.directoryURL = dir }
        if p.runModal() == .OK, let u = p.url { outputFolder = u }
    }

    func setOutput(_ u: URL) {
        userChoseOutput = true
        outputURL = u
        let ext = u.pathExtension.lowercased()
        let c: Container = ext == "mp4" ? .mp4 : ext == "mkv" ? .mkv : .mov
        if c != container { container = c }
    }

    func containerWarnings(_ t: Track) -> [String] {
        if t.kind == .video && t.url.pathExtension.lowercased() == "mxf" && !hdr.encode {
            return ["MXF (master) video can't be copied into MOV/MP4/MKV as it is — turn on “Encode the picture for playback”."]
        }
        let trueHD = t.codecKey == "truehd" || t.codecKey == "mlp"
        switch container {
        case .mp4:
            if t.codecKey == "prores" { return ["ProRes in MP4 isn't standard — the Academy asks for ProRes in MOV."] }
            if t.isPCM { return ["PCM in MP4 has poor compatibility — prefer MOV."] }
            if t.kind == .timecode { return ["QuickTime timecode only works well in MOV."] }
            if trueHD { return ["TrueHD in MP4 plays in few players — MKV is the home-theater standard."] }
        case .mov:
            if trueHD { return ["TrueHD in MOV plays in very few players (never on Apple devices) — use MKV."] }
        case .mkv:
            if t.kind == .timecode { return ["MKV has no timecode track — it will be left out."] }
        }
        return []
    }

    // MARK: sync

    /// Trim plan for an audio track (nil if not audio)
    func plan(for t: Track) -> TrimPlan? {
        guard t.kind == .audio, t.sampleRate > 0 else { return nil }
        let total = t.totalSamples
        let pad = max(0, -t.trimStart)
        let cut = min(max(0, t.trimStart), max(0, total - 1))
        var keep = total - cut
        if matchVideoEnd, t.canTrim, let v = videoTrack, v.duration > 0 {   // (TrueHD can't be cut: it keeps its length)
            let target = Int((Double(videoFrames) / videoFPS.value * t.sampleRate).rounded())   // video length, in samples
            keep = max(1, min(keep, target - pad))
        }
        return TrimPlan(pad: pad, cut: cut, keep: keep, total: total)
    }

    func planText(for t: Track) -> String? {
        guard let p = plan(for: t), !p.isIdentity else { return nil }
        let sr = t.sampleRate
        var parts: [String] = []
        let dolby = t.codecKey == "eac3"
        if p.cut > 0 {
            if dolby {   // only whole 1536-sample frames can be cut, rounded down (as JobRunner does)
                let frames = p.cut / 1536, lateMs = Double(p.cut - frames * 1536) / sr * 1000
                parts.append(String(format: "trims %.3f s from the head (%d whole 32 ms Dolby frames", Double(frames * 1536) / sr, frames) +
                             (lateMs >= 0.05 ? String(format: " → the sound stays %.1f ms late, never early)", lateMs) : ")"))
            } else { parts.append(String(format: "trims %.3f s from the head", Double(p.cut) / sr)) }
        }
        if p.pad > 0 {
            parts.append(dolby ? String(format: "starts %.3f s later (a start delay in the container — no Dolby frame is touched)", Double(p.pad) / sr)
                               : String(format: "adds %.3f s of silence at the head", Double(p.pad) / sr))
        }
        if p.tail > 0 { parts.append(String(format: "trims %.3f s from the tail (ends with the video)", Double(p.tail) / sr)) }
        if videoTrack != nil, matchVideoEnd {
            let len = Double(p.pad + p.keep) / sr
            if len + 0.001 < videoDuration { parts.append(String(format: "ends %.3f s before the video", videoDuration - len)) }
        }
        if dolby && p.cut == 0 { parts.append("in 32 ms Dolby frames") }
        return parts.joined(separator: " · ")
    }

    func autoAlign() {
        guard let ref = reference, !aligning, state != .running else { return }
        let targets = tracks.filter { $0.kind == .audio && $0.include && $0.id != ref.id }
        guard !targets.isEmpty else { alignLines = ["Check at least one audio track (besides the reference) to align."]; return }
        if let i = tracks.firstIndex(where: { $0.id == ref.id }), tracks[i].include { tracks[i].include = false }
        aligning = true; alignLines = []; alignProgress = 0
        let flag = CancelFlag(); alignCancel = flag
        DispatchQueue.global(qos: .userInitiated).async {
            let results = Project.align(reference: ref, targets: targets, cancel: flag, offset: self.referenceOffset) { s, p in
                DispatchQueue.main.async { self.alignStage = s; self.alignProgress = p }
            }
            DispatchQueue.main.async {
                for r in results {
                    if let i = self.tracks.firstIndex(where: { $0.id == r.id }) {
                        if let samples = r.samples { self.tracks[i].trimStart = samples }
                        self.tracks[i].syncApplied = r.samples != nil
                        self.tracks[i].syncNote = r.note
                        self.tracks[i].syncLag = r.lag
                        self.tracks[i].syncPoints = r.points
                    }
                    self.alignLines.append(r.line)
                }
                self.aligning = false; self.alignStage = ""
            }
        }
    }

    func cancelAlign() { alignCancel?.set() }

    struct AlignResult {
        let id: UUID; let samples: Int?; let note: String; let line: String
        var lag: Double? = nil; var points: [SyncEngine.Point] = []
    }

    /// Measures each track against the reference and returns how much to trim (in samples of the track)
    /// `offset`: how late (s) the reference is vs its own picture — added to every trim so the tracks follow the picture
    static func align(reference ref: Track, targets: [Track], cancel: CancelFlag, offset: Double = 0,
                      stage: @escaping (String, Double) -> Void) -> [AlignResult] {
        var out: [AlignResult] = []
        for (n, t) in targets.enumerated() {
            if cancel.isSet { break }
            let sr = Int(t.sampleRate > 0 ? t.sampleRate : 48000)
            let r = SyncEngine.measure(ref: SyncEngine.Source(ref), cand: SyncEngine.Source(t), rate: sr, cancel: cancel) { p in
                stage("Measuring “\(t.title)” (\(n + 1) of \(targets.count))…", p)
            }
            guard let lag = r.lag else {
                out.append(AlignResult(id: t.id, samples: nil, note: "Not aligned: \(r.message)", line: "“\(t.title)”: not aligned — \(r.message)", points: r.points))
                continue
            }
            let samples = Int(((lag + offset) * Double(sr)).rounded())
            if samples < 0 && !t.isPCM && t.codecKey != "eac3" {   // E-AC-3 gets a start delay in the container instead
                let msg = String(format: "the sound is %.1f ms EARLY vs the picture; %@ can't be delayed without re-encoding", -(lag + offset) * 1000, t.codecName)
                out.append(AlignResult(id: t.id, samples: nil, note: "Not aligned: " + msg, line: "“\(t.title)”: not aligned — " + msg, lag: lag, points: r.points))
                continue
            }
            let note = offset == 0
                ? String(format: "Measured %+.6f s vs the reference (%d samples) · %d of %d points agree · spread ±%.2f ms",
                         lag, samples, r.inliers, r.points.count, r.spreadMs)
                : String(format: "Measured %+.6f s vs the reference + %.3f ms because the reference is late vs its picture → trim %+.6f s (%d samples) · %d of %d points agree · spread ±%.2f ms",
                         lag, offset * 1000, lag + offset, samples, r.inliers, r.points.count, r.spreadMs)
            out.append(AlignResult(id: t.id, samples: samples, note: note, line: "“\(t.title)”: " + note, lag: lag, points: r.points))
        }
        return out
    }

    // MARK: summary & Academy prediction

    /// What the output file will look like (MediaInfo-style), built from the sources and the options
    var predictedOutput: [MITrack] {
        guard let spec = jobSpec else { return [] }
        let vDur: Double? = videoTrack == nil ? nil : videoDuration
        var general = MITrack(type: "General", f: ["@type": "General", "Format": container == .mkv ? "Matroska" : "MPEG-4", "Format_Profile": container == .mov ? "QuickTime" : "Base Media"])
        let bytes = estimatedSize
        general.f["FileSize"] = String(bytes)
        if let vDur, vDur > 0 { general.f["Duration"] = String(vDur); general.f["OverallBitRate"] = String(bytes * 8 / vDur) }
        var out = [general]
        for t in spec.tracks {
            var f = t.mi?.f ?? [:]
            switch t.kind {
            case .video:
                f["@type"] = "Video"
                if let e = spec.videoEncode {
                    let c = e.outputColor
                    f["Format"] = "HEVC"; f["Format_Profile"] = "Main 10"; f["BitDepth"] = "10"; f["ChromaSubsampling"] = "4:2:0"; f["ColorSpace"] = "YUV"
                    f["colour_primaries"] = Transcode.miName(c.primaries); f["transfer_characteristics"] = Transcode.miName(c.transfer); f["matrix_coefficients"] = Transcode.miName(c.matrix)
                    f["HDR_Format"] = e.hdr?.formats; f["BitRate"] = String(e.estimatedBytes * 8 / max(e.seconds, 0.001)); f["Gamma"] = nil
                } else if spec.fixColorTag { f["colour_primaries"] = "BT.709"; f["transfer_characteristics"] = "BT.709"; f["matrix_coefficients"] = "BT.709"; f["Gamma"] = nil }
            case .audio:
                f["@type"] = "Audio"
                if t.isPCM {
                    let tag = spec.isMOV ? t.outputLayoutTag(writeLabels: spec.writeChannelMap) : nil
                    f["ChannelLayout"] = tag.map(ChannelMap.layoutName)
                    if let src = t.sourceOrder, let target = t.channelTarget, t.channelPermutation != nil { f["ChannelOrder"] = "\(src.text) → \(target.text)" }
                }
                if let p = spec.plans[t.id], t.sampleRate > 0 {
                    var samples = p.pad + p.keep
                    if t.codecKey == "eac3" {   // frame rounding: head down, tail up (+ the start delay, if any)
                        let spf = 1536
                        let start = (p.cut / spf) * spf
                        samples = p.pad + Int((Double(p.cut + p.keep - start) / Double(spf)).rounded(.up)) * spf
                    }
                    f["Duration"] = String(Double(samples) / t.sampleRate)
                }
                f["Title"] = t.title
            case .subtitle: f["@type"] = "Text"
            case .timecode: f["@type"] = "Other"
            case .other: f["@type"] = "Other"
            }
            out.append(MITrack(type: f["@type"] ?? "", f: f))
        }
        return out
    }

    var predictedChecks: [Check] {
        guard let out = outputURL, !included.isEmpty else { return [] }
        return Academy.checks(fileName: out.lastPathComponent, predictedOutput, black: nil, predicted: true)
    }
    var predictedZidooChecks: [Check] {
        let p = predictedOutput
        return p.isEmpty ? [] : Zidoo.checks(p)
    }
    var predictedZidooLevel: ZidooLevel? { predictedOutput.isEmpty ? nil : Zidoo.level(predictedZidooChecks) }
    var predictedLevel: AcademyLevel? {
        let p = predictedOutput
        guard !p.isEmpty else { return nil }
        return Academy.level(predictedChecks, p)
    }

    // MARK: run

    var jobSpec: JobSpec? {
        guard let out = outputURL else { return nil }
        let inc = included
        var plans: [UUID: TrimPlan] = [:]
        for t in inc where t.kind == .audio { if let p = plan(for: t), t.isGroup || !p.isIdentity || t.channelPermutation != nil { plans[t.id] = p } }
        return JobSpec(tracks: inc, plans: plans, output: out, disableExtraAudio: disableExtraAudio, interleaveMs: interleaveMs,
                       writeChannelMap: writeChannelMap, verifyAudio: verifyAudio, verifyVideo: verifyVideo,
                       fixColorTag: fixColorTag, isMOV: container == .mov, reference: reference,
                       isMKV: container == .mkv, referenceOffset: referenceOffset, videoEncode: encodePlan, pictureCheck: pictureCheck)
    }

    var commandPreview: String {
        guard let spec = jobSpec else { return "" }
        let fake = spec.tracks.map { t -> JobRunner.Prepared in
            if t.kind == .video, let e = spec.videoEncode {
                return JobRunner.Prepared(path: "<HEVC encoded from \(t.url.lastPathComponent)>", selector: nil, rangeEnd: nil, verify: .none, note: nil,
                                          importOptions: e.importOptions(mov: spec.isMOV))
            }
            if t.isGroup {
                return JobRunner.Prepared(path: "<\(t.channels) mono \(t.fromVideoFile ? "streams" : "files") interleaved into one \(Probe.channelText(t.channels, nil)) WAV>", selector: nil, rangeEnd: nil, verify: .none, note: nil)
            }
            return JobRunner.Prepared(path: (spec.plans[t.id].map { $0.isIdentity ? "<channel-reordered temp copy of \(t.url.lastPathComponent)>" : "<trimmed temp copy of \(t.url.lastPathComponent)>" } ?? t.url.path),
                               selector: spec.plans[t.id] != nil ? nil : t.selector,
                               rangeEnd: spec.plans[t.id] != nil ? nil : t.wav.flatMap { $0.hasTrailingChunks ? $0.dataEnd : nil },
                               verify: .none, note: nil)
        }
        let tmp = spec.output.deletingLastPathComponent().appendingPathComponent(".BROS-MUX-tmp")
        let quote: ([String]) -> String = { $0.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ") }
        let mp4 = spec.isMKV ? spec.output.deletingPathExtension().appendingPathExtension("mp4") : spec.output
        var text = "MP4Box " + quote(JobRunner.arguments(spec, prepared: fake, tmp: tmp, output: mp4))
        if let e = spec.videoEncode {
            text = "ffmpeg " + quote(Transcode.arguments(e, concat: nil, output: tmp.appendingPathComponent("video.hevc"), elementary: true)) +
                (e.hdr?.hdr10plus != nil ? "\nhdr10plus_tool inject …" : "") + (e.hdr?.dolbyVision != nil ? "\ndovi_tool generate --xml … -p 8.1 && dovi_tool inject-rpu …" : "") + "\n" + text
        }
        if spec.isMKV { text += "\nffmpeg " + quote(JobRunner.mkvArguments(spec, from: mp4, to: spec.output)) }
        return text
    }

    var estimatedSize: Double {
        guard let spec = jobSpec else { return 0 }
        return spec.tracks.reduce(0) { $0 + JobRunner.estimatedBytes($1, plan: spec.plans[$1.id], encode: spec.videoEncode) }
    }
    var freeSpace: Double? { outputURL.flatMap { Tools.freeSpace(at: $0.deletingLastPathComponent()) } }

    func run() {
        guard canRun, let spec = jobSpec else { return }
        if let problem = hdrProblem ?? JobRunner.validate(spec) {
            resultLines = [problem]; resultState = .failed; state = .failed; return
        }
        if let e = spec.videoEncode, !hdr.confirmSkipped {
            // the Mux tab's one exception, said out loud before hours of encoding
            let a = NSAlert()
            a.messageText = "The picture will be RE-ENCODED"
            a.informativeText = "\(e.source.summary) → \(e.outputCodecName) · \(e.outputBits)-bit \(e.outputChroma) · \(e.formats)\nAbout \(Fmt.hm(e.estimatedSeconds)) of encoding on this Mac (rough; it can run overnight — the Mac won't sleep). The audio stays bit for bit."
            a.showsSuppressionButton = true
            a.suppressionButton?.title = "Don't ask again for this project"
            a.addButton(withTitle: "Re-encode & Mux"); a.addButton(withTitle: "Cancel")
            let r = a.runModal()
            if a.suppressionButton?.state == .on { hdr.confirmSkipped = true }
            if r != .alertFirstButtonReturn { return }
        }
        if FileManager.default.fileExists(atPath: spec.output.path) {
            let a = NSAlert()
            a.messageText = "“\(spec.output.lastPathComponent)” already exists"
            a.informativeText = "Replace it with the new file? (It's only replaced at the very end, if muxing succeeds.)"
            a.addButton(withTitle: "Replace"); a.addButton(withTitle: "Cancel")
            if a.runModal() != .alertFirstButtonReturn { return }
        }
        let r = JobRunner(spec)
        runner = r
        state = .running; progress = 0; stage = "Preparing…"; log = ""; resultLines = []; resultInspection = nil
        r.onStage = { s, p in DispatchQueue.main.async { self.stage = s; self.progress = p } }
        r.onLog = { l in DispatchQueue.main.async { self.log += l } }
        DispatchQueue.global(qos: .userInitiated).async {
            let res = r.run()
            DispatchQueue.main.async {
                self.runner = nil
                self.resultLines = res.lines
                self.resultState = res.state
                self.resultInspection = res.inspection
                switch res.state {
                case .cancelled: self.state = .cancelled
                case .failed where res.output == nil: self.state = .failed
                default: self.state = .done(res.output)
                }
                self.stage = ""
            }
        }
    }

    func cancel() { runner?.requestCancel() }
}

@Observable
final class Inspector {
    var url: URL?
    var data = InspectionData()
    var loading = false
    var measuring = false
    var measureStage = ""
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var measureCancel: CancelFlag?

    func load(_ u: URL) {
        measureCancel?.set()
        generation += 1
        let g = generation
        url = u; loading = true; data = InspectionData(); measuring = false
        DispatchQueue.global(qos: .userInitiated).async {
            let d = Inspection.analyze(u)
            DispatchQueue.main.async { if g == self.generation { self.data = d; self.loading = false } }
        }
    }

    func measureLoudness() {
        guard let u = url, !measuring else { return }
        let g = generation, tracks = data.tracks
        let flag = CancelFlag(); measureCancel = flag
        measuring = true; data.loudness = []
        DispatchQueue.global(qos: .userInitiated).async {
            let lines = Inspection.loudness(u, tracks, cancel: flag) { s in
                DispatchQueue.main.async { if g == self.generation { self.measureStage = s } }
            }
            DispatchQueue.main.async {
                guard g == self.generation else { return }
                self.data.loudness = lines; self.measuring = false; self.measureStage = ""
            }
        }
    }

    func saveReport() {
        guard let u = url else { return }
        let p = NSSavePanel()
        p.allowedContentTypes = [.plainText]
        p.nameFieldStringValue = u.deletingPathExtension().lastPathComponent + "_CHECK.txt"
        p.directoryURL = u.deletingLastPathComponent()
        if p.runModal() == .OK, let dst = p.url {
            try? Inspection.textReport(u, data).write(to: dst, atomically: true, encoding: .utf8)
        }
    }
}

// MARK: - Interface: see Design.swift, MuxUI.swift, CheckerUI.swift

// MARK: - App

struct BrosMuxApp: App {
    @State private var project = Project()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var showWelcome = true

    var body: some Scene {
        // One window, born complete (split view, toolbar, inspector); the welcome is a sheet over it. Swapping the
        // root view for a NavigationSplitView, or opening a second window at launch, left the toolbar, the safe area
        // and the columns half configured — content under the toolbar, no scrolling, an empty sidebar.
        Window(AppInfo.name, id: "main") {
            ContentView()
                .environment(project)
                .frame(minWidth: 1180, minHeight: 720)
                .onAppear { delegate.project = project }
                .sheet(isPresented: $showWelcome) {
                    WelcomeView(onStart: { showWelcome = false }).environment(project)
                }
                .onChange(of: project.tracks.count) { _, n in if n > 0 { showWelcome = false } }   // a file from the Finder skips the welcome
        }
        .defaultSize(width: 1480, height: 940)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Add Files…") { project.openPanel() }.keyboardShortcut("o").disabled(project.mode == .mux && project.busy)
                Button("Clear All") { project.clear() }.keyboardShortcut("n").disabled(project.busy)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var project: Project?
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func application(_ application: NSApplication, open urls: [URL]) { project?.add(urls) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let p = project, p.state == .running || p.aligning else { return .terminateNow }
        let a = NSAlert()
        a.messageText = "A job is still running"
        a.informativeText = "If you quit now it will be cancelled and nothing will be written to the destination."
        a.addButton(withTitle: "Keep Working")
        a.addButton(withTitle: "Cancel Job and Quit")
        if a.runModal() == .alertSecondButtonReturn { p.cancel(); p.cancelAlign(); return .terminateNow }
        return .terminateCancel
    }
}

// MARK: - Command line (uses the same engine as the window)
//
//  --job -o OUT.mov [--video V.mov] [--add A.wav]... [--align] [--lang eng] [--audio-title "Name"]...
//        [--no-match-video] [--verify-video] [--fix-color] [--mp4]
//  --snapshot -o screen.png [same arguments as --job, plus --dest OUT.mov] [--dark] [--wide]   (image of the whole window)
//  --snapshot --inspect FILE -o screen.png [--loudness]                       (image of the inspector)
//  --snapshot --syncviewer -o screen.png --video V --add A --align [--target N] [--before] [--zoom S] [--beat N]
//                                                                             (image of the Sync Viewer)
//  --report FILE -o report.txt [--loudness]                                   (text check report)
//  --job -o OUT.mp4|OUT.mkv --imf IMF_FOLDER --encode [--dv XML|MXF] [--hdr10plus JSON] [--quality …] [--speed …] --add ATMOS.ec3
//                                                                             (HDR playback version: Dolby Vision 8.1 + HDR10 + HDR10+)

struct CLIArgs {
    var output: String?
    var inspect: String?
    var atmos: String?
    var atTime = 0.0
    var dest: String?
    var loudness = false
    var steps: [(String, String)] = []   // ("video"|"add", path)
    var align = false
    var lang: String?
    var audioTitles: [String] = []
    var matchVideo = true
    var verifyVideo = false
    var fixColor = false
    var mp4 = false
    var mkv = false
    var writeReport: String?
    var encode = false
    var dv: String?
    var hdr10plus: String?
    var quality: String?
    var speed: String?
    var rate: String?                    // --rate crf|2pass|cbr
    var mbps: Int?                       // --mbps: the average (2pass) or the constant bitrate (cbr)
    var maxMbps: Int?                    // --max-mbps: the peak of the 2-pass encode
    var floor = true                     // --no-floor turns the quality floor off
    var refLateFrames = 0.0
    var channelOrder: String?            // "--channel-order \"L C R Ls Rs LFE\"": listen to each PCM track and write its channels in this order
    var pictureCheck = true

    init(_ a: [String]) {
        var i = 0
        func next() -> String? { i += 1; return i < a.count ? a[i] : nil }
        while i < a.count {
            switch a[i] {
            case "-o": output = next()
            case "--inspect": inspect = next()
            case "--atmos": atmos = next()
            case "-t": atTime = Double(next() ?? "") ?? 0
            case "--dest": dest = next()
            case "--loudness": loudness = true
            case "--video": if let v = next() { steps.append(("video", v)) }
            case "--add": if let v = next() { steps.append(("add", v)) }
            case "--align": align = true
            case "--lang": lang = next()
            case "--audio-title": if let v = next() { audioTitles.append(v) }
            case "--no-match-video": matchVideo = false
            case "--verify-video": verifyVideo = true
            case "--fix-color": fixColor = true
            case "--mp4": mp4 = true
            case "--mkv": mkv = true
            case "--imf": if let v = next() { steps.append(("imf", v)) }
            case "--encode": encode = true
            case "--dv": dv = next()
            case "--hdr10plus": hdr10plus = next()
            case "--quality": quality = next()
            case "--speed": speed = next()
            case "--rate": rate = next()
            case "--mbps": mbps = Int(next() ?? "")
            case "--max-mbps": maxMbps = Int(next() ?? "")
            case "--no-floor": floor = false
            case "--ref-late-frames": refLateFrames = Double(next() ?? "") ?? 0
            case "--channel-order": channelOrder = next()
            case "--no-picture-check": pictureCheck = false
            case "--write-report": writeReport = next()
            default: break
            }
            i += 1
        }
    }
}

/// Builds the project from the arguments (no window), the same way a person would in the interface
func buildProject(_ a: CLIArgs, output: String?) -> Project {
    let project = Project()
    project.matchVideoEnd = a.matchVideo
    project.verifyVideo = a.verifyVideo
    project.pictureCheck = a.pictureCheck
    project.fixColorTag = a.fixColor
    if a.mp4 { project.container = .mp4 }
    if a.mkv { project.container = .mkv }
    for (kind, path) in a.steps {
        let url = URL(fileURLWithPath: path)
        if kind == "imf" {
            let r = Project.readIMF(url)
            r.notices.forEach { print("NOTE:", $0) }
            project.applyIMF(r, check: false)
            continue
        }
        let r = Probe.tracks(for: url)
        if let e = r.error { print("ERROR:", e) }
        project.insert(r.tracks)
        if kind == "video" {
            for i in project.tracks.indices where project.tracks[i].url.path == url.path && project.tracks[i].kind == .audio {
                project.tracks[i].include = false
                if project.syncReferenceID == nil { project.syncReferenceID = project.tracks[i].id }
            }
        }
    }
    project.autoGroup()
    if let l = a.lang { for i in project.tracks.indices where project.tracks[i].kind == .audio { project.tracks[i].language = l } }
    var titles = a.audioTitles[...]
    for i in project.tracks.indices where project.tracks[i].kind == .audio && project.tracks[i].include {
        if let t = titles.popFirst() { project.tracks[i].title = Fmt.ascii(t) }
    }
    if let o = output { project.setOutput(URL(fileURLWithPath: o)) }
    if a.encode { project.hdr.encode = true }
    if let q = a.quality.flatMap({ HDRSettings.Quality(rawValue: $0) }) { project.hdr.quality = q }
    if let s = a.speed.flatMap({ HDRSettings.Speed(rawValue: $0) }) { project.hdr.speed = s }
    if let r = HDRSettings.Rate.fromCLI(mode: a.rate.flatMap(HDRSettings.RateMode.named), mbps: a.mbps, maxMbps: a.maxMbps, floor: a.floor) {
        project.hdr.rateMode = r.mode; project.hdr.bitratePreset = .custom; project.hdr.customMbps = r.targetMbps; project.hdr.customMaxMbps = r.maxMbps; project.hdr.qualityFloor = r.floor
    }
    if let d = a.dv {
        // like dropping the XML on the window: the re-encoding switches itself on, and says so
        let u = URL(fileURLWithPath: d)
        project.hdr.dvSource = u.pathExtension.lowercased() == "mxf" ? .isxd([.init(file: u, entry: 0, count: project.videoFrames)]) : .xml(u)
        project.hdr.dolbyVision = true
        if !project.hdr.encode {
            project.hdr.encode = true; project.hdr.autoEnabledBy = u
            project.hdr.autoReason = "Dolby Vision metadata was added. To embed it, the picture has to become HEVC 10-bit, so BROS-MUX turned the re-encoding on by itself."
        }
    }
    if let h = a.hdr10plus {
        let u = URL(fileURLWithPath: h)
        project.hdr.hdr10plusJSON = u; project.hdr.hdr10plus = true; project.hdr.hdr10plusFrames = HDR10Plus.frames(u) ?? -1
    }
    if project.hdr.dvSource != nil && project.hdr.encode {
        print("Reading the Dolby Vision metadata…")
        project.hdr.checkDolbyVisionNow(width: project.videoWidth, height: project.videoHeight, frames: project.videoFrames)
        print("  •", project.hdr.dvProblem ?? project.hdr.dvSummary?.line ?? "?")
    }
    project.referenceLateFrames = a.refLateFrames
    if let co = a.channelOrder {
        let tokens = co.split(separator: " ")
        let roles = tokens.compactMap { ChannelRole(rawValue: String($0)) }
        let order = ChannelOrder(roles: roles)
        if roles.count != tokens.count || !order.isComplete {
            print("  • --channel-order “\(co)”: each role must be one of \(ChannelRole.allCases.map(\.rawValue).joined(separator: " ")) and used once — ignored")
        } else {
            for i in project.tracks.indices where project.tracks[i].canReorder {
                let t = project.tracks[i]
                guard roles.count == t.channels, let wav = t.wav else { print("  • “\(t.title)”: --channel-order names \(roles.count) channels, the track has \(t.channels) — skipped"); continue }
                print("Listening to “\(t.title)” to tell its channels apart…")
                guard let r = ChannelID.analyze(url: t.url, info: wav) else { print("  • could not analyse"); continue }
                project.tracks[i].channelRoles = r.guesses.map(\.role)
                project.tracks[i].channelConfidence = r.overall
                project.tracks[i].channelReport = r.text
                guard order.canBeWritten(from: r.detected) else {
                    print(String(format: "  • heard %@ (%.0f%% sure): %@ is not made of those roles — written as it is", r.detected.text, r.overall * 100, co)); continue
                }
                project.tracks[i].channelTarget = order
                print(String(format: "  • heard %@ (%.0f%% sure) → written as %@%@", r.detected.text, r.overall * 100, co,
                             project.tracks[i].channelPermutation == nil ? " (already in that order)" : ""))
            }
        }
    }
    if a.align, let ref = project.reference {
        let targets = project.tracks.filter { $0.kind == .audio && $0.include && $0.id != ref.id }
        print("Aligning \(targets.count) track(s) to the reference “\(ref.title)” (\(ref.url.lastPathComponent))" +
              (a.refLateFrames == 0 ? "…" : String(format: ", which is %g frame(s) late vs its picture…", a.refLateFrames)))
        let results = Project.align(reference: ref, targets: targets, cancel: CancelFlag(), offset: project.referenceOffset) { _, _ in }
        for r in results {
            if let i = project.tracks.firstIndex(where: { $0.id == r.id }) {
                if let s = r.samples { project.tracks[i].trimStart = s }
                project.tracks[i].syncApplied = r.samples != nil
                project.tracks[i].syncLag = r.lag
                project.tracks[i].syncPoints = r.points
                project.tracks[i].syncNote = r.note
            }
            print("  •", r.line)
        }
        project.alignLines = results.map(\.line)
    }
    return project
}

func runJobCLI(_ args: [String]) -> Int32 {
    let a = CLIArgs(args)
    // never fall back to a default destination from the command line — an explicit -o is required
    guard let o = a.output, ["mov", "mp4", "mkv"].contains((o as NSString).pathExtension.lowercased()) else {
        print("usage: --job -o OUT.mov|OUT.mp4|OUT.mkv [--video V | --imf PACKAGE] [--add A]… [--encode --dv XML|MXF --hdr10plus JSON --quality master|maximum|high|compact --speed slow|medium|fast|draft --rate crf|2pass|cbr --mbps N --max-mbps N --no-floor] (an explicit -o is required)"); return 2
    }
    let project = buildProject(a, output: a.output)
    print("\nTRACKS:")
    for t in project.tracks {
        print("  [\(t.include ? "x" : " ")] \(t.kind.label): \(t.codecName) | \(t.badges.joined(separator: ", ")) | \(t.title) | \(t.language)" +
              (project.syncReferenceID == t.id ? " | SYNC REFERENCE" : "") + (project.planText(for: t).map { " | \($0)" } ?? ""))
        for w in t.warnings { print("      ⚠ \(w)") }
    }
    if let l = project.predictedLevel { print("\nPREDICTED ACADEMY SEAL: \(l.emoji) \(l.title)") }
    guard let spec = project.jobSpec else { print("No destination (-o)."); return 2 }
    if let p = project.hdrProblem { print("HDR:", p); return 1 }
    if let e = spec.videoEncode { print("\nENCODE: \(e.formats) · \(Fmt.int(e.frames)) frames @ \(e.fps) · \(e.width)×\(e.height) · \(e.encoder) \(e.video.speed?.preset ?? "") · quality \(e.video.quality?.label ?? "") · colour \(e.outputColor.text)" + (e.hdr.map { " · HDR10 \($0.mastering.text), MaxCLL \($0.maxCLL), MaxFALL \($0.maxFALL)" } ?? "")) }
    print("\nCOMMAND: \(project.commandPreview)\n")
    let runner = JobRunner(spec)
    var lastPrint = Date.distantPast
    let printLock = NSLock()
    runner.onStage = { s, p in
        printLock.lock(); defer { printLock.unlock() }
        if Date().timeIntervalSince(lastPrint) > 10 { print(String(format: "  … %@ %3.0f%%", s, max(0, p) * 100)); lastPrint = Date() }
    }
    let started = Date()
    let r = runner.run()
    print(String(format: "\nRESULT (%.0f s): %@", Date().timeIntervalSince(started), "\(r.state)"))
    r.lines.forEach { print("  •", $0) }
    if var insp = r.inspection {
        if let l = insp.level { print("\nACADEMY SEAL (verified): \(l.emoji) \(l.title)") }
        for c in insp.checks { print("  [\(c.level.text)] \(c.title): \(c.detail)") }
        if let path = a.writeReport, let out = r.output {
            if a.loudness {
                print("\nMeasuring loudness (read-only)…")
                insp.loudness = Inspection.loudness(out, insp.tracks, cancel: CancelFlag()) { print("  …", $0) }
                insp.loudness.forEach { print("  •", $0) }
            }
            var s = "=== HOW THIS FILE WAS MADE (\(AppInfo.name)) ===\n"
            s += "Output: \(out.path)\nMuxed: \(Date().formatted(date: .abbreviated, time: .standard)) · \(String(format: "%.0f", Date().timeIntervalSince(started))) s\n\nSOURCES\n"
            for t in project.tracks {
                let role = project.syncReferenceID == t.id ? "SYNC REFERENCE (not muxed)" : t.include ? "MUXED" : "not muxed"
                s += "• [\(role)] \(t.kind.label): \(t.codecName) · \(t.details) · from \(t.url.path) (\(t.sourceLabel))\n"
            }
            if !project.alignLines.isEmpty { s += "\nSYNC ALIGNMENT (measured against the reference)\n" + project.alignLines.map { "• " + $0 }.joined(separator: "\n") + "\n" }
            s += "\nMUX, VERIFICATION AND SYNC CHECK\n" + r.lines.map { "• " + $0 }.joined(separator: "\n") + "\n\nMP4Box COMMAND\n\(project.commandPreview)\n\n"
            s += Inspection.textReport(out, insp)
            do { try s.write(toFile: path, atomically: true, encoding: .utf8); print("\nreport:", path) } catch { print("ERROR writing the report:", error) }
        }
    }
    return r.state == .ok || r.state == .warning ? 0 : 1
}

func runReportCLI(_ args: [String]) -> Int32 {
    let a = CLIArgs(args)
    guard let f = a.inspect ?? args.first(where: { !$0.hasPrefix("-") }), let o = a.output else { print("usage: --report FILE -o out.txt"); return 2 }
    let u = URL(fileURLWithPath: f)
    var d = Inspection.analyze(u)
    if a.loudness { d.loudness = Inspection.loudness(u, d.tracks, cancel: CancelFlag()) { print("  …", $0) } }
    do { try Inspection.textReport(u, d).write(toFile: o, atomically: true, encoding: .utf8) } catch { print("ERROR:", error); return 1 }
    print("report:", o)
    return 0
}

/// Renders the window to a PNG (for visual checks and documentation)
func snapshot(_ args: [String]) {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let a = CLIArgs(args)
    let quality = args.contains("--quality")
    let out = a.output ?? "snapshot.png"
    func value(_ k: String) -> String? { args.firstIndex(of: k).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
    let project: Project
    let root: AnyView
    var size = NSSize(width: 1480, height: 940)
    var chrome = true                       // the whole window: title bar, toolbar, sidebar, inspector (sheets are drawn alone)
    if let f = a.atmos {
        // Atmos tab with a file loaded (the SceneKit view itself may render blank offscreen)
        project = Project()
        project.mode = .atmos
        let u = URL(fileURLWithPath: f)
        do {
            let r = try AtmosDecoder.decode(u) { _ in }
            project.atmos.url = u
            project.atmos.frames = r.frames
            project.atmos.summary = r.summary
            project.atmos.duration = r.frames.last?.time ?? 0
            project.atmos.setTime(a.atTime)
        } catch { print("ERROR:", error.localizedDescription); project.atmos.url = u; project.atmos.error = error.localizedDescription }
        root = AnyView(ContentView().environment(project))
    } else if args.contains("--syncviewer") {
        // Sync Viewer of one aligned track: [--target N] [--before] [--overlay] [--zoom SECONDS] [--nudge SAMPLES] [--beat N | -t SECONDS]
        func value(_ k: String) -> String? { args.firstIndex(of: k).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        project = buildProject(a, output: a.dest)
        let targets = project.tracks.filter { $0.kind == .audio && $0.include && $0.id != project.syncReferenceID }
        guard !targets.isEmpty else { print("ERROR: no audio track to view (add one besides the reference)"); return }
        let m = SyncViewerModel(project: project, target: targets[min(max(0, Int(value("--target") ?? "") ?? 0), targets.count - 1)])
        m.after = !args.contains("--before")
        m.overlay = args.contains("--overlay")
        if let z = value("--zoom").flatMap(Double.init) { m.halfWidth = z }
        if let n = value("--nudge").flatMap(Int.init) { m.nudge = n }
        if args.contains("--async") {        // the window's own path: background loading, then the hit nearest to where it opened
            m.reload(); m.findBeats()
            let until = Date().addingTimeInterval(180)
            while (m.loading || m.findingBeats) && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
            print(String(format: "async: playhead at %.2f s", m.center))
        } else { m.findBeatsNow() }
        print("hits:", m.beats.map { String(format: "%.2f", $0) }.joined(separator: " "))
        for s in WaveData.classify(m.target?.syncPoints ?? []) {
            print(String(format: "  point %7.1f s  lag %+.6f s  corr %.2f  2nd %.2f  %@", s.point.time, s.point.lag, s.point.corr, s.point.second,
                         s.used ? "used" : "ignored"))
        }
        if let b = value("--beat").flatMap(Int.init), b >= 1, b <= m.beats.count { m.center = m.beats[b - 1]; m.reloadNow() }
        else if a.atTime > 0 { m.center = a.atTime; m.reloadNow() }
        else if !args.contains("--async") { m.reloadNow() }
        chrome = false
        size = NSSize(width: 1240, height: 1000)
        root = AnyView(SyncViewerSheet(model: m, standalone: true))
    } else if args.contains("--welcome") {
        project = Project()
        let view = WelcomeView().environment(project).background(Color(nsColor: .windowBackgroundColor))
        size = NSSize(width: 1040, height: 700)
        EngineStatus.shared.loadVersions()
        let until = Date().addingTimeInterval(20)
        while EngineStatus.shared.versions.isEmpty && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        root = AnyView(view)
    } else if args.contains("--channelsheet") {
        // Channel order sheet of the first PCM track added: --channelsheet --add FILE.wav [--target "L C R Ls Rs LFE"]
        func value(_ k: String) -> String? { args.firstIndex(of: k).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        project = buildProject(a, output: a.dest)
        guard let t = project.tracks.first(where: { $0.canReorder }), let wav = t.wav else { print("ERROR: add a multichannel PCM WAV with --add"); return }
        guard let r = ChannelID.analyze(url: t.url, info: wav) else { print("ERROR: could not analyse"); return }
        print(r.text)
        var track = t
        track.channelRoles = r.guesses.map(\.role); track.channelConfidence = r.overall; track.channelReport = r.text
        if let tv = value("--target") { track.channelTarget = ChannelOrder(roles: tv.split(separator: " ").compactMap { ChannelRole(rawValue: String($0)) }) }
        chrome = false
        size = NSSize(width: 760, height: 1000)
        root = AnyView(ChannelOrderSheet(track: .constant(track), initialReport: r).frame(width: 760, height: 1000, alignment: .top).background(Color(nsColor: .windowBackgroundColor)))
    } else if args.contains("--pictureviewer") {
        // Picture Sync Check: --pictureviewer FILE.mov | --pictureviewer --video V --add A [--align --ref-late-frames N]  [--point N]
        func value(_ k: String) -> String? { args.firstIndex(of: k).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
        project = buildProject(a, output: a.dest)
        let file = value("--pictureviewer").flatMap { $0.hasPrefix("-") ? nil : $0 }
        let made = file.map { PictureSyncModel(project: project, output: URL(fileURLWithPath: $0)) }
            ?? PictureSyncModel(project: project, target: project.tracks.first { $0.kind == .audio && $0.include && $0.id != project.syncReferenceID })
        guard let m = made else { print("ERROR: nothing to check (no video, or the file can't be read)"); return }
        m.measure()
        var until = Date().addingTimeInterval(900)
        while m.measuring && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        if let n = value("--point").flatMap(Int.init), n >= 1, n <= m.points.count { m.select(n - 1) }
        until = Date().addingTimeInterval(60)
        while m.loadingView && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        for l in m.lanes { print("•", l.label, "→", l.result?.message ?? "not measured") }
        print("check points:", m.points.map { Fmt.duration($0.cut) }.joined(separator: " "), "· showing", m.cut.map { Fmt.duration($0) } ?? "-")
        chrome = false
        size = NSSize(width: 1320, height: 1040)
        root = AnyView(PictureSyncSheet(model: m, standalone: true))
    } else if let f = value("--transcode") {
        // Transcode tab with a file in the queue: --snapshot --transcode FILE [--to prores422hq|h264|hevc|hevcdv] -o screen.png
        project = Project()
        project.mode = .transcode
        let m = TranscodeModel.shared
        m.clear()
        if let p = value("--to").flatMap(TranscodePreset.named) { m.preset = p }
        if let r = HDRSettings.Rate.fromCLI(mode: value("--rate").flatMap(HDRSettings.RateMode.named), mbps: value("--mbps").flatMap { Int($0) },
                                           maxMbps: value("--max-mbps").flatMap { Int($0) }, floor: !args.contains("--no-floor")) {
            m.hdr.rateMode = r.mode; m.hdr.bitratePreset = .custom; m.hdr.customMbps = r.targetMbps; m.hdr.customMaxMbps = r.maxMbps; m.hdr.qualityFloor = r.floor
        }
        m.add([URL(fileURLWithPath: f)])
        let until = Date().addingTimeInterval(60)
        while m.loading > 0 && Date() < until { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
        if let item = m.selected, let plan = m.plan(for: item) {
            for r in plan.rows { print("  \(r.changed ? "→" : "=") \(r.id): \(r.from) → \(r.to)") }
            for w in plan.warnings { print("  ⚠ \(w)") }
        }
        root = AnyView(ContentView().environment(project))
    } else if let f = a.inspect {
        project = Project()
        project.mode = .inspect
        let u = URL(fileURLWithPath: f)
        var d = Inspection.analyze(u)
        if a.loudness { d.loudness = Inspection.loudness(u, d.tracks, cancel: CancelFlag()) { _ in } }
        project.inspector.url = u
        project.inspector.data = d
        size = NSSize(width: 1480, height: 1400)
        root = AnyView(ContentView().environment(project))
    } else {
        project = buildProject(a, output: a.dest)
        if quality { size = NSSize(width: 900, height: 760); chrome = false }
        root = quality ? AnyView(QualitySheet().environment(project)) : AnyView(ContentView().environment(project))
    }
    if chrome && args.contains("--wide") { size = NSSize(width: 1900, height: 1000) }
    // a sheet drawn alone needs the window colour behind it (the window provides it in the app)
    let host = NSHostingView(rootView: chrome ? root : AnyView(root.background(Color(nsColor: .windowBackgroundColor))))
    host.sceneBridgingOptions = chrome ? [.toolbars, .title] : []
    host.frame = NSRect(origin: .zero, size: size)
    let win = NSWindow(contentRect: host.frame,
                       styleMask: chrome ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView] : [.titled, .fullSizeContentView],
                       backing: .buffered, defer: false)
    win.appearance = NSAppearance(named: args.contains("--dark") ? .darkAqua : .aqua)
    win.toolbarStyle = .unified
    win.contentView = host
    win.makeKeyAndOrderFront(nil)
    RunLoop.main.run(until: Date().addingTimeInterval(2.0))
    host.layoutSubtreeIfNeeded()
    win.displayIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.6))
    let png: Data?
    if chrome, let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(win.windowNumber), [.boundsIgnoreFraming, .bestResolution]), cg.width > 1 {
        png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])    // the window as it is on screen: title bar, toolbar, sidebar, inspector
    } else {
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        png = rep.representation(using: .png, properties: [:])
    }
    try? png?.write(to: URL(fileURLWithPath: out))
    print("snapshot:", out)
}

/// Command line: the sound against the picture. `--picture FILE.mov` checks a muxed file (every audio track);
/// `--picture --video V --add A… [--align --ref-late-frames N]` checks the project's reference and the first track as it would be muxed.
func pictureCLI(_ args: [String]) -> Int32 {
    setvbuf(stdout, nil, _IOLBF, 0)
    let a = CLIArgs(args)
    func value(_ k: String) -> String? { args.firstIndex(of: k).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
    let points = Int(value("--points") ?? "") ?? 30, window = Double(value("--window") ?? "") ?? 30
    let project = buildProject(a, output: nil)
    let model: PictureSyncModel?
    if let f = args.first, !f.hasPrefix("-") { model = PictureSyncModel(project: project, output: URL(fileURLWithPath: f)) }
    else { model = PictureSyncModel(project: project, target: project.tracks.first { $0.kind == .audio && $0.include && $0.id != project.syncReferenceID }) }
    guard let m = model, !m.lanes.isEmpty else {
        print("usage: --picture FILE.mov | --picture --video V --add A… [--align --ref-late-frames N] [--points N] [--window S]"); return 2
    }
    print("PICTURE: \(m.picture.path) · \(String(format: "%.3f", m.fps)) fps · \(Fmt.duration(m.duration))")
    let segs = PictureSync.segments(duration: m.duration, points: points, window: window)
    let t0 = Date()
    var cuts: [PictureSync.Cut] = []
    let cacheKey = "\(m.picture.path)|\((try? FileManager.default.attributesOfItem(atPath: m.picture.path)[.size]) ?? 0)|\(points)|\(window)|\(PictureSync.bodyFrom)-\(PictureSync.bodyTo)".utf8.reduce(UInt64(5381)) { ($0 &* 33) &+ UInt64($1) }
    let cacheURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("brosmux_cuts_\(cacheKey).txt")
    if args.contains("--cache"), let txt = try? String(contentsOf: cacheURL, encoding: .utf8) {
        for line in txt.split(separator: "\n") {
            let f = line.split(separator: " ")
            if f.count == 3, let t = Double(f[0]), let st = Double(f[1]), let sg = Int(f[2]) { cuts.append(.init(time: t, strength: st, segment: sg)) }
        }
        print("CUTS: \(cuts.count) from the cache")
    }
    if cuts.isEmpty {
        cuts = PictureSync.detectCuts(video: m.picture, index: m.pictureIndex, fps: m.fps, segments: segs, cancel: CancelFlag()) { p in
            if Int(p * 100) % 20 == 0 { print(String(format: "  … cuts %3.0f%%", p * 100)) }
        }
        if args.contains("--cache") { try? cuts.map { "\($0.time) \($0.strength) \($0.segment)" }.joined(separator: "\n").write(to: cacheURL, atomically: true, encoding: .utf8) }
    }
    print(String(format: "CUTS: %d hard cuts in %d windows of %.0f s (%.0f s)", cuts.count, segs.count, segs.first?.length ?? 0, Date().timeIntervalSince(t0)))
    var code: Int32 = 0
    for lane in m.lanes {
        let r = PictureSync.match(cuts: cuts, curves: PictureSync.curvesFor(lane.src, segments: segs, shift: lane.shift), fps: m.fps)
        let ok = r.offset.map { $0 * 1000 >= -15 && $0 * 1000 <= 45 } ?? false
        print("\(ok ? (r.confident ? "✓" : "⚠") : "✗") \(lane.label)" + (lane.shift != 0 ? String(format: " (read %+.3f s later)", lane.shift) : "") + ": \(r.message)")
        for (i, h) in r.points.enumerated() { print(String(format: "     check point %2d: cut %@  hit %+.0f ms (%.0f dB)", i + 1, Fmt.duration(h.cut), (h.onset - h.cut) * 1000, h.rise)) }
        if args.contains("--verbose") {
            print("     groups: " + r.groups.prefix(6).map { String(format: "%+.0f ms (%.1f · %d cuts / %d win)", $0.lag * 1000, $0.value, $0.count, $0.windows) }.joined(separator: " · "))
            for (c, pk) in zip(cuts, r.peaks) {
                print("     cut \(Fmt.duration(c.time)) (×\(Int(c.strength))): " + pk.map { String(format: "%+.0f ms %.0f dB", $0.lag * 1000, $0.rise) }.joined(separator: " · "))
            }
        }
        if !ok { code = 1 }
    }
    return code
}

@main
enum Entry {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        switch args.first {
        case "--job": exit(runJobCLI(Array(args.dropFirst())))
        case "--report": exit(runReportCLI(Array(args.dropFirst())))
        case "--snapshot": snapshot(Array(args.dropFirst()))
        case "--picture": exit(pictureCLI(Array(args.dropFirst())))
        case "--qc": exit(RenderQC.cli(Array(args.dropFirst())))
        case "--channels": exit(ChannelID.cli(Array(args.dropFirst())))
        case "--transcode": exit(TranscodeModel.cli(Array(args.dropFirst())))
        case "--atmos-snapshot": atmosSnapshot(Array(args.dropFirst()))
        default: BrosMuxApp.main()
        }
    }
}
