// BROS-MUX — Transcode: the ONE place where the picture is re-encoded. Everywhere else the files go in and out bit for bit.
// The engine here (TranscodePlan → ffmpeg arguments → TranscodeRunner) is used by the Transcode tab for ProRes, H.264 and
// HEVC, and by the Mux tab for its single exception: the HEVC 10-bit encode that Dolby Vision / HDR10+ playback versions
// need. The colour of the source (primaries, transfer, matrix, range) is read from the file and repeated in the output —
// nothing is tagged BT.2020/PQ by default any more — unless a tone mapping to SDR is asked for.

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CryptoKit
import Accelerate

// MARK: - What this ffmpeg can do

extension Tools {
    private static func names(_ flag: String) -> Set<String> {
        guard let ffmpeg, let d = runSync(ffmpeg, ["-hide_banner", flag]) else { return [] }
        var out = Set<String>()
        for line in String(decoding: d, as: UTF8.self).components(separatedBy: "\n") {
            // " V....D libx265   libx265 H.265 / HEVC" (encoders), " ... zscale   V->V  …" (filters); the legend lines have "=" second
            let parts = line.trimmingCharacters(in: .whitespaces).split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, parts[1] != "=", parts[0].allSatisfy({ "VASFXBDTSC.|".contains($0) }) else { continue }
            out.insert(String(parts[1]))
        }
        return out
    }
    static let encoders: Set<String> = names("-encoders")
    static let filters: Set<String> = names("-filters")
    static func hasEncoder(_ n: String) -> Bool { encoders.contains(n) }
    static func hasFilter(_ n: String) -> Bool { filters.contains(n) }
    /// The Apple ProRes encoder (VideoToolbox, hardware on the M chips), or ffmpeg's own as a fallback
    static var proresEncoder: String { hasEncoder("prores_videotoolbox") ? "prores_videotoolbox" : "prores_ks" }
    static var aacEncoder: String { hasEncoder("aac_at") ? "aac_at" : "aac" }
    static var canToneMap: Bool { hasFilter("zscale") && hasFilter("tonemap") }
    static var canVMAF: Bool { hasFilter("libvmaf") }
}

// MARK: - The source picture, as the file says it is

/// Colour signalling of a picture (ffprobe names: bt709, bt2020, smpte432, smpte2084, arib-std-b67, bt2020nc, gbr, tv, pc…)
struct SourceColor: Equatable {
    var primaries: String?
    var transfer: String?
    var matrix: String?
    var range: String?
    var isPQ: Bool { transfer == "smpte2084" }
    var isHLG: Bool { transfer == "arib-std-b67" }
    var isHDR: Bool { isPQ || isHLG }
    var isRGB: Bool { matrix == "gbr" || matrix == "rgb" }
    var isTagged: Bool { primaries != nil || transfer != nil || matrix != nil }
    /// primaries and transfer both known (the matrix follows them when it is missing)
    var isComplete: Bool { primaries != nil && transfer != nil }

    static func name(_ v: String?) -> String {
        switch v {
        case nil, "unknown", "reserved": return "untagged"
        case "bt709": return "BT.709"
        case "bt2020": return "BT.2020"
        case "bt2020nc": return "BT.2020 nc"
        case "bt2020c": return "BT.2020 c"
        case "bt2020-10", "bt2020-12": return "BT.2020"
        case "smpte2084": return "PQ"
        case "arib-std-b67": return "HLG"
        case "smpte432": return "Display P3"
        case "smpte431": return "DCI P3"
        case "smpte170m": return "BT.601"
        case "bt470bg": return "BT.601 (625)"
        case "gbr", "rgb": return "RGB"
        case "iec61966-2-1": return "sRGB"
        case "linear": return "Linear"
        case "tv": return "limited"
        case "pc": return "full"
        case .some(let s): return s
        }
    }
    var text: String { "\(Self.name(primaries)) / \(Self.name(transfer)) / \(Self.name(matrix)) · \(Self.name(range ?? "tv")) range" }
    var short: String {
        if isPQ { return (primaries == "smpte432" ? "P3 D65" : Self.name(primaries)) + " · PQ" }
        if isHLG { return Self.name(primaries) + " · HLG" }
        return Self.name(transfer ?? primaries)
    }
    static let bt709 = SourceColor(primaries: "bt709", transfer: "bt709", matrix: "bt709", range: "tv")
    static let bt2020PQ = SourceColor(primaries: "bt2020", transfer: "smpte2084", matrix: "bt2020nc", range: "tv")
}

struct SourceAudio {
    let codec: String; let channels: Int; let layout: String?; let sampleRate: Int; let bits: Int
    var isPCM: Bool { codec.hasPrefix("pcm_") }
    var text: String { "\(codec.hasPrefix("pcm_") ? "PCM \(bits > 0 ? "\(bits)-bit" : "")" : codec.uppercased()) \(Probe.channelText(channels, layout))" }
}

/// Everything the Transcode needs to know about a picture (ffprobe + MediaInfo), frozen when the file is read
struct SourceVideo {
    let url: URL
    let streamIndex: Int
    let codec: String            // ffprobe codec_name
    let codecName: String        // "Apple ProRes 4444", "HEVC", …
    let profile: String?         // "4444", "Main 10", "High"…
    let width: Int
    let height: Int
    let fps: Rational
    let frames: Int
    let duration: Double
    let pixFmt: String
    let bitDepth: Int
    let chroma: String           // "4:4:4", "4:2:2", "4:2:0", "RGB"
    let hasAlpha: Bool
    let color: SourceColor
    let bitRate: Double
    let timecode: String?
    let sar: String?
    let fieldOrder: String?
    let hdrFormat: String?       // MediaInfo HDR_Format (Dolby Vision, HDR10+, …)
    var audio: [SourceAudio] = []
    let mi: MITrack?

    var isHDR: Bool { color.isHDR || (hdrFormat ?? "").contains("2086") || (hdrFormat ?? "").contains("Dolby Vision") }
    var isProRes: Bool { codec == "prores" }
    var sizeText: String { "\(width)×\(height)" }
    var fpsText: String { Probe.fps("\(fps.num)/\(fps.den)") ?? "\(fps.value)" }
    var summary: String {
        var p = [codecName]
        if let profile, !codecName.contains(profile) { p[0] += " \(profile)" }
        p.append("\(bitDepth)-bit \(chroma)" + (hasAlpha ? " + alpha" : ""))
        if bitRate > 0 { p.append(Fmt.bitrate(bitRate)) }
        return p.joined(separator: " · ")
    }

    /// From an ffprobe stream and the MediaInfo of the same picture (no extra process: Probe already ran both)
    init(stream s: ProbeStream, mi: MITrack?, url: URL, fallbackDuration: Double) {
        self.url = url
        streamIndex = s.index
        codec = s.codec_name ?? "?"
        switch codec {
        case "prores": codecName = Probe.proresName(s.codec_tag_string, s.profile)
        case "h264": codecName = "H.264"
        case "hevc": codecName = "HEVC"
        case "av1": codecName = "AV1"
        case "dnxhd": codecName = "DNxHD/HR"
        case "jpeg2000": codecName = "JPEG 2000"
        case "mjpeg": codecName = "Motion JPEG"
        case "vp9": codecName = "VP9"
        default: codecName = codec.uppercased()
        }
        profile = s.profile ?? mi?["Format_Profile"]
        width = s.width ?? Int(mi?["Width"] ?? "") ?? 0
        height = s.height ?? Int(mi?["Height"] ?? "") ?? 0
        if let n = mi?["FrameRate_Num"], let d = mi?["FrameRate_Den"], let r = Rational("\(n) \(d)") { fps = r }
        else if let r = Rational((s.avg_frame_rate ?? s.r_frame_rate ?? "24").replacingOccurrences(of: "/", with: " ")), r.num > 0 { fps = r }
        else { fps = Rational(24, 1) }
        duration = Double(s.duration ?? "") ?? mi?.d("Duration") ?? fallbackDuration
        let declared = Int(s.nb_frames ?? "") ?? Int(mi?["FrameCount"] ?? "") ?? 0
        frames = declared > 0 ? declared : Int((duration * fps.value).rounded())
        pixFmt = s.pix_fmt ?? ""
        let raw = Int(s.bits_per_raw_sample ?? "") ?? 0
        bitDepth = raw > 0 ? raw : (Int(mi?["BitDepth"] ?? "") ?? Self.bits(of: s.pix_fmt ?? ""))
        chroma = Self.chroma(of: s.pix_fmt ?? "", mi: mi)
        hasAlpha = Self.alpha(of: s.pix_fmt ?? "") || (mi?["ColorSpace"] ?? "").hasSuffix("A")
        var c = SourceColor(primaries: Self.tag(s.color_primaries), transfer: Self.tag(s.color_transfer), matrix: Self.tag(s.color_space), range: Self.tag(s.color_range))
        // MediaInfo knows a few tags ffprobe reports as unknown (Resolve's Rec.709-A, P3 D65)
        if c.primaries == nil, let p = mi?["colour_primaries"] { c.primaries = Self.fromMediaInfo(p) }
        if c.transfer == nil, let t = mi?["transfer_characteristics"] { c.transfer = Self.fromMediaInfo(t) }
        if c.matrix == nil, let m = mi?["matrix_coefficients"] { c.matrix = Self.fromMediaInfo(m) }
        if c.range == nil, let r = mi?["colour_range"] { c.range = r.lowercased().hasPrefix("full") ? "pc" : "tv" }
        if (mi?["ColorSpace"] ?? "").hasPrefix("RGB") || (s.pix_fmt ?? "").hasPrefix("gbr") || (s.pix_fmt ?? "").contains("rgb") || (s.pix_fmt ?? "").contains("bgr") { c.matrix = "gbr" }
        color = c
        bitRate = Double(s.bit_rate ?? "") ?? mi?.d("BitRate") ?? 0
        timecode = s.tags?["timecode"]
        sar = s.sample_aspect_ratio
        fieldOrder = s.field_order
        hdrFormat = mi?["HDR_Format"]
        self.mi = mi
    }

    static func tag(_ v: String?) -> String? { guard let v, v != "unknown", v != "reserved", !v.isEmpty else { return nil }; return v }
    static func fromMediaInfo(_ v: String) -> String? {
        switch v {
        case "BT.709": return "bt709"
        case "BT.2020": return "bt2020"
        case "BT.2020 non-constant": return "bt2020nc"
        case "BT.2020 constant": return "bt2020c"
        case "PQ": return "smpte2084"
        case "HLG": return "arib-std-b67"
        case "Display P3": return "smpte432"
        case "DCI P3": return "smpte431"
        case "BT.601 NTSC", "BT.601": return "smpte170m"
        case "BT.601 PAL": return "bt470bg"
        case "sRGB/sYCC": return "iec61966-2-1"
        default: return nil
        }
    }
    static func bits(of pix: String) -> Int {
        if let r = pix.range(of: #"(?<=p|a)(8|9|10|12|14|16)(?=le|be|$)"#, options: .regularExpression) { return Int(pix[r]) ?? 8 }
        if pix.contains("64") { return 16 }
        return 8
    }
    static func chroma(of pix: String, mi: MITrack?) -> String {
        if pix.hasPrefix("gbr") || pix.contains("rgb") || pix.contains("bgr") { return "RGB" }
        if pix.contains("444") { return "4:4:4" }
        if pix.contains("422") { return "4:2:2" }
        if pix.contains("420") || pix.hasPrefix("nv12") || pix.hasPrefix("p010") { return "4:2:0" }
        if let c = mi?["ChromaSubsampling"] { return c }
        return pix.isEmpty ? "?" : pix
    }
    static func alpha(of pix: String) -> Bool { pix.hasPrefix("yuva") || pix.hasPrefix("gbrap") || pix.contains("rgba") || pix.contains("bgra") || pix.contains("argb") || pix.hasPrefix("ayuv") }

    /// Reads a file for the Transcode tab (the picture and the list of its audio streams)
    static func read(_ url: URL) -> SourceVideo? {
        let r = Probe.tracks(for: url)
        guard var v = r.tracks.first(where: { $0.kind == .video })?.source else { return nil }
        v.audio = r.tracks.filter { $0.kind == .audio }.map { SourceAudio(codec: $0.codecKey, channels: $0.channels, layout: $0.channelLayout, sampleRate: Int($0.sampleRate), bits: $0.bitDepth) }
        return v
    }
}

// MARK: - What to make of it

enum ProResProfile: String, CaseIterable, Identifiable {
    case proxy, lt, standard, hq, p4444, xq
    var id: String { rawValue }
    var label: String {
        switch self { case .proxy: return "ProRes 422 Proxy"; case .lt: return "ProRes 422 LT"; case .standard: return "ProRes 422"; case .hq: return "ProRes 422 HQ"; case .p4444: return "ProRes 4444"; case .xq: return "ProRes 4444 XQ" }
    }
    var vtName: String { switch self { case .proxy: return "proxy"; case .lt: return "lt"; case .standard: return "standard"; case .hq: return "hq"; case .p4444: return "4444"; case .xq: return "xq" } }
    var ksProfile: Int { switch self { case .proxy: return 0; case .lt: return 1; case .standard: return 2; case .hq: return 3; case .p4444: return 4; case .xq: return 5 } }
    var is4444: Bool { self == .p4444 || self == .xq }
    var chroma: String { is4444 ? "4:4:4" : "4:2:2" }
    var bits: Int { is4444 ? 12 : 10 }
    var fourcc: String { switch self { case .proxy: return "apco"; case .lt: return "apcs"; case .standard: return "apcn"; case .hq: return "apch"; case .p4444: return "ap4h"; case .xq: return "ap4x" } }
    var mediaInfoProfile: String { switch self { case .proxy: return "422 Proxy"; case .lt: return "422 LT"; case .standard: return "422"; case .hq: return "422 HQ"; case .p4444: return "4444"; case .xq: return "4444 XQ" } }
    /// Apple's data rates (bits per pixel per frame; 3840×2160 at 29.97 fps: Proxy 145, LT 328, 422 471, HQ 707, 4444 1061, XQ 1591 Mbps)
    var bitsPerPixel: Double { switch self { case .proxy: return 0.58; case .lt: return 1.32; case .standard: return 1.89; case .hq: return 2.84; case .p4444: return 4.27; case .xq: return 6.40 } }
}

enum TargetCodec: String, CaseIterable, Identifiable {
    case prores, h264, hevc
    var id: String { rawValue }
    var label: String { switch self { case .prores: return "Apple ProRes"; case .h264: return "H.264"; case .hevc: return "HEVC" } }
}

enum VideoTarget: Equatable {
    case prores(ProResProfile)
    case h264(quality: HDRSettings.Quality, speed: HDRSettings.Speed)
    case hevc(quality: HDRSettings.Quality, speed: HDRSettings.Speed, rate: HDRSettings.Rate = HDRSettings.Rate())
    var codec: TargetCodec { switch self { case .prores: return .prores; case .h264: return .h264; case .hevc: return .hevc } }
    var quality: HDRSettings.Quality? { switch self { case .prores: return nil; case .h264(let q, _): return q; case .hevc(let q, _, _): return q } }
    var speed: HDRSettings.Speed? { switch self { case .prores: return nil; case .h264(_, let s): return s; case .hevc(_, let s, _): return s } }
    /// HEVC: how the bits are spent (CRF, 2-pass average, CBR)
    var rate: HDRSettings.Rate? { if case .hevc(_, _, let r) = self { return r }; return nil }
}

enum ColorPipeline: Equatable {
    case passthrough          // the source's own colour, repeated in the output
    case toneMapToSDR         // HDR (PQ/HLG) → SDR BT.709 (zscale + tonemap)
}

enum AudioPlan: String, CaseIterable, Identifiable {
    case copy, pcm, aac, none
    var id: String { rawValue }
    var label: String { switch self { case .copy: return "Copy (bit for bit)"; case .pcm: return "PCM 24-bit"; case .aac: return "AAC"; case .none: return "No audio" } }
}

enum OutputResolution: String, CaseIterable, Identifiable {
    case same, uhd, hd
    var id: String { rawValue }
    var label: String { switch self { case .same: return "Same as source"; case .uhd: return "UHD (3840 wide)"; case .hd: return "HD (1920 wide)" } }
    var width: Int? { switch self { case .same: return nil; case .uhd: return 3840; case .hd: return 1920 } }
}

/// HDR10 static metadata, and the dynamic metadata injected after the encode (HEVC only)
struct HDRMeta {
    var mastering: MasteringDisplay
    var maxCLL: Int
    var maxFALL: Int
    var dolbyVision: DolbyVisionMeta.Source?
    var dvXML: URL?                    // already checked/rebuilt in the window
    var hdr10plus: URL?
    var formats: String { ((dolbyVision != nil ? ["Dolby Vision 8.1"] : []) + ["HDR10"] + (hdr10plus != nil ? ["HDR10+"] : [])).joined(separator: " + ") }
}

/// Everything a transcode needs (frozen when the job starts). Built by the Transcode tab for any destination, and by the
/// Mux tab for its one exception (HEVC 10-bit with Dolby Vision / HDR10+), always from the same source description.
struct TranscodePlan {
    struct Segment { let file: URL; let start: Int; let count: Int }
    var source: SourceVideo
    var segments: [Segment]            // frames to read, in order (an IMF CPL can splice several track files)
    var frames: Int
    var fps: Rational
    var width: Int
    var height: Int
    var rgbSource: Bool
    var video: VideoTarget
    var color: ColorPipeline = .passthrough
    var hdr: HDRMeta? = nil            // HEVC: HDR10 metadata written; Dolby Vision / HDR10+ injected after the encode
    var audio: AudioPlan = .copy
    var resolution: OutputResolution = .same
    var container: Container = .mov
    var timecode: String? = nil        // written as a QuickTime timecode track (MOV/MP4)
    var convertGamut = true            // HDR: a P3-D65 / BT.709 source is carried in BT.2020, as HDR10 and Dolby Vision expect; off = tagged as it came

    init(source: SourceVideo, video: VideoTarget) {
        self.source = source
        segments = [Segment(file: source.url, start: 0, count: source.frames)]
        frames = source.frames; fps = source.fps; width = source.width; height = source.height
        rgbSource = source.color.isRGB || source.chroma == "RGB"
        self.video = video
        timecode = source.timecode
    }

    var seconds: Double { Double(frames) / max(fps.value, 1) }
    var isDraft: Bool { video.speed == .draft }
    var encoder: String {
        switch video {
        case .prores: return Tools.proresEncoder
        case .h264: return isDraft && Tools.hasEncoder("h264_videotoolbox") ? "h264_videotoolbox" : "libx264"
        case .hevc: return isDraft && Tools.hasEncoder("hevc_videotoolbox") ? "hevc_videotoolbox" : "libx265"
        }
    }
    var usesVideoToolbox: Bool { encoder.hasSuffix("videotoolbox") }
    /// Dolby Vision or HDR10+ to inject: the picture is encoded as an elementary stream and muxed by MP4Box (as the Mux tab does)
    var needsInjection: Bool { hdr?.dolbyVision != nil || hdr?.hdr10plus != nil }

    var outputWidth: Int {
        guard let w = resolution.width, width > 0 else { return width }
        return w
    }
    var outputHeight: Int {
        guard let w = resolution.width, width > 0 else { return height }
        let h = Int((Double(height) * Double(w) / Double(width)).rounded())
        return h + (h & 1)
    }
    var resizes: Bool { outputWidth != width || outputHeight != height }

    /// The colour written: the source's, with the gaps filled the way the destination expects; or BT.709 after a tone map
    var outputColor: SourceColor {
        if color == .toneMapToSDR { return .bt709 }
        if gamutConversion != nil { return .bt2020PQ }
        let src = source.color
        let hdrTarget = video.codec == .hevc && hdr != nil
        let primaries = src.primaries ?? (hdrTarget ? "bt2020" : "bt709")
        let transfer = src.transfer ?? (hdrTarget ? "smpte2084" : "bt709")
        var matrix = src.matrix
        // no matrix, an RGB source, or primaries that had to be assumed: the matrix follows the primaries
        if matrix == nil || src.isRGB || rgbSource || src.primaries == nil { matrix = primaries == "bt2020" ? "bt2020nc" : "bt709" }
        let range = (rgbSource || src.isRGB) ? "tv" : (src.range ?? "tv")
        return SourceColor(primaries: primaries, transfer: transfer, matrix: matrix!, range: range)
    }
    var isBT2020: Bool { outputColor.primaries == "bt2020" }

    /// An HDR (PQ) encode from a source whose primaries aren't BT.2020: the picture is converted in linear light to
    /// BT.2020, the container HDR10 and Dolby Vision are defined in. The source primaries tag, or nil when nothing converts.
    var gamutConversion: String? {
        guard convertGamut, color == .passthrough, video.codec == .hevc, hdr != nil,
              let p = source.color.primaries, p != "bt2020", ColorLUT.primaries(p) != nil,
              (source.color.transfer ?? "smpte2084") == "smpte2084" else { return nil }
        return p
    }
    /// The HDR encode that keeps non-BT.2020 primaries: said out loud, never silent
    var gamutWarning: String? {
        guard color == .passthrough, video.codec == .hevc, hdr != nil, gamutConversion == nil,
              let p = source.color.primaries, p != "bt2020" else { return nil }
        return "The source is \(ColorLUT.label(p)); HDR10 and Dolby Vision streams are BT.2020. The output stays tagged \(outputColor.text) — players that assume BT.2020 will shift the hues. Turn the BT.2020 conversion on (recommended)."
    }
    var colourNote: String? { gamutConversion.map { "\(ColorLUT.label($0)) → BT.2020, converted in linear light; the colours don't change, BT.2020 is the container HDR10 and Dolby Vision expect" } }

    var pixFmt: String {
        switch video {
        case .prores(let p):
            if encoder == "prores_videotoolbox" { return p.is4444 ? "ayuv64le" : "p210le" }
            return p.is4444 ? (source.hasAlpha ? "yuva444p10le" : "yuv444p10le") : "yuv422p10le"
        case .h264: return "yuv420p"
        case .hevc: return encoder == "hevc_videotoolbox" ? "p010le" : "yuv420p10le"
        }
    }
    var outputBits: Int { switch video { case .prores(let p): return p.bits; case .h264: return 8; case .hevc: return 10 } }
    var outputChroma: String { switch video { case .prores(let p): return p.chroma; case .h264, .hevc: return "4:2:0" } }
    var keepsAlpha: Bool { if case .prores(let p) = video { return p.is4444 && source.hasAlpha }; return false }
    var outputCodecName: String {
        switch video {
        case .prores(let p): return "Apple " + p.label
        case .h264: return "H.264 High"
        case .hevc: return "HEVC Main 10"
        }
    }
    var outputCodecShort: String { switch video { case .prores(let p): return p.label; case .h264: return "H.264"; case .hevc: return "HEVC 10-bit" } }
    /// MediaInfo-style profile of the output (for the Academy prediction)
    var outputProfile: String { switch video { case .prores(let p): return p.mediaInfoProfile; case .h264: return "High"; case .hevc: return "Main 10" } }
    var formats: String { hdr?.formats ?? (outputColor.isHDR ? outputColor.short : "SDR") }

    var estimatedBytes: Double {
        let pixels = Double(max(outputWidth * outputHeight, 1))
        switch video {
        case .prores(let p): return p.bitsPerPixel * pixels * fps.value * seconds / 8
        case .h264(let q, _): return q.averageMbps * 1_000_000 / 8 * seconds * pixels / 8_294_400 * 0.85
        case .hevc(let q, _, let r):
            if r.mode != .quality { return Double(r.targetMbps) * 1_000_000 / 8 * seconds }   // the target is the size
            return q.averageMbps * 1_000_000 / 8 * seconds * pixels / 8_294_400
        }
    }
    /// rough frames per second at UHD on this Mac, per encoder
    var fps4K: Double {
        switch video {
        case .prores: return encoder == "prores_videotoolbox" ? 90 : 10
        case .h264(_, let s): return usesVideoToolbox ? 120 : s.fps4K * 2.5
        case .hevc(_, let s, let r): return usesVideoToolbox ? 120 : s.fps4K / (r.mode == .average ? 1.35 : 1)   // 2-pass: a fast first pass on top
        }
    }
    var estimatedSeconds: Double { Double(frames) / (fps4K * 8_294_400 / Double(max(width * height, 1))) }

    /// What the person should know before pressing the button
    var warnings: [String] {
        var w: [String] = []
        let s = source
        if s.hasAlpha && !keepsAlpha { w.append("The alpha channel of the source is discarded (\(outputCodecShort) carries no alpha).") }
        if (s.chroma == "4:4:4" || s.chroma == "RGB") && outputChroma != "4:4:4" { w.append("Colour goes from \(s.chroma) to \(outputChroma): chroma is subsampled.") }
        else if s.chroma == "4:2:2" && outputChroma == "4:2:0" { w.append("Colour goes from 4:2:2 to 4:2:0: chroma is subsampled.") }
        if s.bitDepth > outputBits { w.append("\(s.bitDepth) → \(outputBits) bits" + (outputBits == 8 ? " (dithered): fine for review, not for a master." : ".")) }
        if s.isHDR && video.codec == .h264 && color == .passthrough { w.append("The source is HDR (\(s.color.short)); H.264 players will show it washed out. Turn on the tone mapping to SDR / BT.709.") }
        if s.isHDR && video.codec == .hevc && hdr == nil && color == .passthrough { w.append("The source is HDR (\(s.color.short)): the HEVC keeps its PQ/HLG tags but carries no HDR10 metadata. Choose the Dolby Vision / HDR preset for a proper HDR file.") }
        if !s.isHDR && s.color.isTagged && hdr != nil { w.append("The source is tagged \(s.color.short) (SDR) — HDR10 / Dolby Vision metadata would describe it wrongly.") }
        if let g = gamutWarning { w.append(g) }
        if !s.color.isComplete && color == .passthrough { w.append("The source's colour tags are incomplete (\(s.color.isTagged ? s.color.text : "none")); the output is tagged \(outputColor.text) (\(hdr != nil ? "BT.2020 / PQ, as HDR needs" : "BT.709 assumed")).") }
        if resizes && outputWidth > width { w.append("Upscaling \(s.sizeText) → \(outputWidth)×\(outputHeight): no detail is gained.") }
        if video.codec == .prores && container != .mov { w.append("ProRes belongs in MOV — \(container.rawValue.uppercased()) players rarely open it.") }
        if case .prores(let p) = video, p == .hq, container == .mov, s.isHDR { w.append("ProRes 422 HQ HDR: the Academy wants SDR BT.709 — this is a master copy, not a screening file.") }
        if usesVideoToolbox && video.codec != .prores { w.append("Draft speed uses the hardware encoder (VideoToolbox): fast, bigger files, not for delivery.") }
        if audio == .copy && container == .mp4 && s.audio.contains(where: \.isPCM) { w.append("PCM audio doesn't go into MP4: the audio is encoded to AAC instead (or choose MOV to keep it).") }
        if s.fieldOrder != nil && s.fieldOrder != "progressive" && s.fieldOrder != "unknown" { w.append("Interlaced source (\(s.fieldOrder ?? "")): the field order is kept as it is, no deinterlacing.") }
        return w
    }
    /// What stops the job before it starts
    var problem: String? {
        if Tools.ffmpeg == nil { return "ffmpeg isn't installed. Run: brew install ffmpeg" }
        if frames <= 0 || width <= 0 { return "Couldn't read the picture's size and length." }
        if color == .toneMapToSDR && !Tools.canToneMap { return "Tone mapping needs ffmpeg's zscale and tonemap filters, and this ffmpeg has no zscale (libzimg). Install ffmpeg with zimg (brew reinstall ffmpeg) or keep the HDR colour." }
        if color == .toneMapToSDR && !source.isHDR { return "Tone mapping only applies to an HDR (PQ/HLG) source." }
        if !Tools.hasEncoder(encoder) { return "This ffmpeg has no \(encoder) encoder." }
        if needsInjection && hdr?.dolbyVision != nil && Tools.doviTool == nil { return "dovi_tool isn't installed (needed for Dolby Vision). Run: brew install dovi_tool" }
        if needsInjection && hdr?.hdr10plus != nil && Tools.hdr10plusTool == nil { return "hdr10plus_tool isn't installed (needed for HDR10+). Run: brew install hdr10plus_tool" }
        if needsInjection && container == .mov && video.codec != .hevc { return "Dolby Vision / HDR10+ need HEVC." }
        return nil
    }

    /// The audio that is really written (PCM can't live in MP4)
    var effectiveAudio: AudioPlan {
        if audio == .copy && container == .mp4 && source.audio.contains(where: \.isPCM) { return .aac }
        return audio
    }
    var aacKbps: Int { (source.audio.map(\.channels).max() ?? 2) > 2 ? 640 : 256 }

    /// MP4Box import options for an elementary HEVC stream (the Mux path)
    func importOptions(mov: Bool) -> [String] {
        var o = ["fps=\(fps)"]
        if hdr?.dolbyVision != nil { o.append("dvp=8.1") }
        let c = outputColor
        let p = Self.colrIndex(c.primaries, [("bt709", 1), ("bt470m", 4), ("bt470bg", 5), ("smpte170m", 6), ("smpte240m", 7), ("film", 8), ("bt2020", 9), ("smpte428", 10), ("smpte431", 11), ("smpte432", 12)])
        let t = Self.colrIndex(c.transfer, [("bt709", 1), ("bt470m", 4), ("bt470bg", 5), ("smpte170m", 6), ("smpte240m", 7), ("linear", 8), ("log100", 9), ("log316", 10), ("iec61966-2-4", 11), ("bt1361e", 12), ("iec61966-2-1", 13), ("bt2020-10", 14), ("bt2020-12", 15), ("smpte2084", 16), ("smpte428", 17), ("arib-std-b67", 18)])
        let m = Self.colrIndex(c.matrix, [("gbr", 0), ("bt709", 1), ("fcc", 4), ("bt470bg", 5), ("smpte170m", 6), ("smpte240m", 7), ("ycgco", 8), ("bt2020nc", 9), ("bt2020c", 10), ("smpte2085", 11), ("chroma-derived-nc", 12), ("chroma-derived-c", 13), ("ictcp", 14)])
        o.append(mov ? "colr=nclc,\(p),\(t),\(m)" : "colr=nclx,\(p),\(t),\(m),\(c.range == "pc" ? "yes" : "no")")
        return o
    }
    static func colrIndex(_ name: String?, _ table: [(String, Int)]) -> Int { table.first { $0.0 == name }?.1 ?? 2 }

    /// Source → destination, row by row (what changes is said so)
    struct Row: Identifiable { let id: String; let from: String; let to: String; let changed: Bool }
    var rows: [Row] {
        let s = source
        var r: [Row] = []
        func add(_ id: String, _ from: String, _ to: String) { r.append(Row(id: id, from: from, to: to, changed: from != to)) }
        add("Codec", s.codecName + (s.profile.map { s.codecName.contains($0) ? "" : " \($0)" } ?? ""), outputCodecName)
        add("Bit depth", "\(s.bitDepth)-bit", "\(outputBits)-bit")
        add("Chroma", s.chroma, outputChroma)
        add("Alpha", s.hasAlpha ? "yes" : "none", keepsAlpha ? "kept" : (s.hasAlpha ? "discarded" : "none"))
        add("Resolution", s.sizeText, "\(outputWidth)×\(outputHeight)")
        add("Frame rate", "\(s.fpsText) fps", "\(s.fpsText) fps")
        add("Colour", s.color.isTagged ? s.color.text : "untagged", outputColor.text + (colourNote.map { " — \($0)" } ?? ""))
        add("HDR", s.isHDR ? (s.hdrFormat ?? s.color.short) : "SDR", hdr?.formats ?? (outputColor.isHDR ? outputColor.short + " (no HDR10 metadata)" : "SDR"))
        add("Bitrate", s.bitRate > 0 ? Fmt.bitrate(s.bitRate) : "—", "~" + Fmt.bitrate(estimatedBytes * 8 / max(seconds, 0.001)))
        let a = s.audio.isEmpty ? "none" : s.audio.map(\.text).joined(separator: ", ")
        let aOut: String
        switch effectiveAudio {
        case .copy: aOut = s.audio.isEmpty ? "none" : a + " (bit for bit)"
        case .pcm: aOut = s.audio.isEmpty ? "none" : "PCM 24-bit, " + s.audio.map { Probe.channelText($0.channels, $0.layout) }.joined(separator: ", ")
        case .aac: aOut = s.audio.isEmpty ? "none" : "AAC \(aacKbps) kbps, " + s.audio.map { Probe.channelText($0.channels, $0.layout) }.joined(separator: ", ")
        case .none: aOut = "none"
        }
        add("Audio", a, aOut)
        add("Timecode", s.timecode ?? "none", timecode == nil || container == .mkv ? "none" : timecode!)
        add("Container", s.url.pathExtension.uppercased(), container.rawValue.uppercased())
        return r
    }
}

// MARK: - ffmpeg

enum Transcode {
    /// The ffmpeg command. `elementary`: only the picture, as a raw HEVC stream (the Mux path injects the Dolby Vision /
    /// HDR10+ metadata into it and MP4Box muxes it); otherwise the whole file, audio included, straight into the container.
    /// `pass` / `stats`: the 2-pass average mode runs the command twice — pass 1 writes only the stats file (output discarded), pass 2 reads it.
    static func arguments(_ p: TranscodePlan, concat: URL?, output: URL, elementary: Bool, pass: Int = 0, stats: URL? = nil) -> [String] {
        var a = ["-nostdin", "-v", "error", "-nostats", "-progress", "pipe:1"]
        if let concat { a += ["-f", "concat", "-safe", "0", "-i", concat.path] }
        else if let s = p.segments.first {
            if s.start > 0 { a += ["-ss", String(format: "%.6f", Double(s.start) / p.fps.value)] }
            a += ["-i", s.file.path]
        }
        a += ["-map", "0:v:0", "-frames:v", "\(p.frames)"]
        if elementary {
            a += ["-an", "-sn", "-dn"]
        } else {
            switch p.effectiveAudio {
            case .copy: a += ["-map", "0:a?", "-c:a", "copy"]
            case .pcm: a += ["-map", "0:a?", "-c:a", "pcm_s24le"]
            case .aac: a += ["-map", "0:a?", "-c:a", Tools.aacEncoder, "-b:a", "\(p.aacKbps)k"]
            case .none: a += ["-an"]
            }
            a += ["-sn", "-dn"]
        }
        let c = p.outputColor
        // the filter chain: [tone map] → scale (size, matrix for RGB masters, range, chroma siting) → pixel format
        var chain: [String] = []
        if p.color == .toneMapToSDR {
            chain.append("zscale=t=linear:npl=100,format=gbrpf32le,zscale=p=bt709,tonemap=hable:desat=0,zscale=t=bt709:m=bt709:r=tv")
        }
        if let from = p.gamutConversion {
            // P3-D65 / BT.709 → BT.2020 in linear light: float RGB through the source's own matrix, the LUT, then BT.2020
            // Y'CbCr with UHD chroma siting. A missing LUT makes ffmpeg fail loudly rather than write the wrong colour.
            let lut = (try? ColorLUT.file(from: from))?.path ?? "/BROS-MUX-could-not-write-the-\(from)-to-bt2020-LUT.cube"
            chain.append("scale=in_color_matrix=\(p.source.color.matrix ?? "bt709"):in_range=\(p.source.color.range ?? "tv"):out_range=pc:flags=accurate_rnd+full_chroma_int+full_chroma_inp")
            chain.append("format=gbrpf32le")
            chain.append("lut3d=file=\(ColorLUT.escaped(lut)):interp=tetrahedral")
            var scale: [String] = []
            if p.resizes { scale.append("\(p.outputWidth):\(p.outputHeight)") }
            scale += ["in_range=pc", "out_color_matrix=bt2020", "out_range=tv", "out_h_chr_pos=0:out_v_chr_pos=0", "flags=lanczos+accurate_rnd+full_chroma_int+full_chroma_inp"]
            chain.append("scale=" + scale.joined(separator: ":"))
        } else {
            var scale: [String] = []
            if p.resizes { scale.append("\(p.outputWidth):\(p.outputHeight)") }
            if p.rgbSource && p.color == .passthrough { scale.append("out_color_matrix=\(c.matrix == "bt2020nc" ? "bt2020" : "bt709")") }
            scale.append("out_range=\(c.range ?? "tv")")
            if p.video.codec == .hevc && p.isBT2020 { scale.append("out_h_chr_pos=0:out_v_chr_pos=0") }   // UHD chroma siting (top-left, type 2)
            scale.append("flags=lanczos+accurate_rnd+full_chroma_int+full_chroma_inp")
            chain.append("scale=" + scale.joined(separator: ":"))
        }
        chain.append("format=\(p.pixFmt)")
        // ffmpeg 6.1+ tags the output from the frames, not from -color_* (those are kept for older builds): the frames are
        // stamped with the colour written. x265 takes its colour from its own params, so the Mux path's command stays as it was.
        if p.encoder != "libx265" {
            chain.append("setparams=color_primaries=\(c.primaries ?? "bt709"):color_trc=\(c.transfer ?? "bt709"):colorspace=\(c.matrix ?? "bt709"):range=\(c.range ?? "tv")")
        }
        a += ["-vf", chain.joined(separator: ",")]
        switch p.video {
        case .prores(let profile):
            if p.encoder == "prores_videotoolbox" { a += ["-c:v", "prores_videotoolbox", "-profile:v", profile.vtName, "-allow_sw", "1"] }
            else { a += ["-c:v", "prores_ks", "-profile:v", "\(profile.ksProfile)", "-vendor", "apl0"] }
        case .h264(let q, let s):
            let vbv = q.maxMbps * 1000
            if p.encoder == "h264_videotoolbox" {
                a += ["-c:v", "h264_videotoolbox", "-b:v", "\(Int(q.averageMbps * 1000))k", "-maxrate", "\(vbv)k", "-bufsize", "\(vbv)k", "-profile:v", "high"]
            } else {
                a += ["-c:v", "libx264", "-preset", s.preset, "-crf", String(format: "%.0f", q.crf + 2), "-maxrate", "\(vbv)k", "-bufsize", "\(vbv)k", "-profile:v", "high"]
            }
        case .hevc(let q, let s, let r):
            // Quality (CRF): the arguments of v1.5, untouched. Average / Constant only change the rate-control part.
            let vbv = r.mode == .quality ? q.maxMbps * 1000 : r.maxMbps * 1000
            if p.encoder == "hevc_videotoolbox" {
                let target = r.mode == .quality ? Int(q.averageMbps * 1000) : r.targetMbps * 1000
                a += ["-c:v", "hevc_videotoolbox", "-b:v", "\(target)k", "-maxrate", "\(vbv)k", "-bufsize", "\(vbv)k", "-profile:v", "main10"]
            } else {
                var x265 = ["log-level=error"]
                // Quality switches that follow the preset in x265 (read from the stats header of every preset, 2026-11-04):
                // psy-rdoq and rdoq-level only from slow up, b-intra off in slow (on in medium and slower+), weightb only from
                // slower up. Pinned here so that the preset changes the search effort — the time — and never, in silence, what
                // the encoder is allowed to do for texture, grain, fades and B frames.
                x265 += ["psy-rd=2.0", "psy-rdoq=1.0", "rdoq-level=2", "b-intra=1", "weightb=1"]
                if let h = p.hdr { _ = h; x265 += ["hdr10=1", "hdr10-opt=1"] }
                x265 += ["repeat-headers=1", "aud=1", "hrd=1",
                         "colorprim=\(c.primaries ?? "bt709")", "transfer=\(c.transfer ?? "bt709")", "colormatrix=\(c.matrix ?? "bt709")", "range=\(c.range == "pc" ? "full" : "limited")"]
                if p.isBT2020 { x265.append("chromaloc=2") }
                if let h = p.hdr { x265 += ["master-display=\(h.mastering.x265)", "max-cll=\(h.maxCLL),\(h.maxFALL)"] }
                switch r.mode {
                case .quality:
                    x265 += ["vbv-maxrate=\(vbv)", "vbv-bufsize=\(vbv)", "aq-mode=3", "no-sao=1"]
                    a += ["-c:v", "libx265", "-preset", s.preset, "-crf", String(format: "%.0f", q.crf), "-x265-params", x265.joined(separator: ":")]
                case .average:
                    // ABR at the target with a VBV at the peak; the stats of pass 1 let pass 2 spend the bits where the film needs them
                    x265 += ["vbv-maxrate=\(vbv)", "vbv-bufsize=\(vbv)", "aq-mode=3", "no-sao=1"]
                    if r.floor { x265.append("qpmax=\(HDRSettings.Rate.floorQP)") }
                    if let stats, pass > 0 {
                        x265 += ["pass=\(pass)", "stats=\(stats.path)"]
                        if pass == 1 { x265.append("slow-firstpass=0") }       // the first pass only measures: fast settings
                    }
                    a += ["-c:v", "libx265", "-preset", s.preset, "-b:v", "\(r.targetMbps * 1000)k", "-x265-params", x265.joined(separator: ":")]
                case .constant:
                    // bitrate = VBV = the target, strict-cbr: x265 holds the rate from start to end (no padding bytes, so it still breathes a little)
                    let t = r.targetMbps * 1000
                    x265 += ["vbv-maxrate=\(t)", "vbv-bufsize=\(t)", "strict-cbr=1", "aq-mode=3", "no-sao=1"]
                    if r.floor { x265.append("qpmax=\(HDRSettings.Rate.floorQP)") }
                    a += ["-c:v", "libx265", "-preset", s.preset, "-b:v", "\(t)k", "-x265-params", x265.joined(separator: ":")]
                }
            }
        }
        a += ["-color_primaries", c.primaries ?? "bt709", "-color_trc", c.transfer ?? "bt709", "-colorspace", c.matrix ?? "bt709", "-color_range", c.range ?? "tv"]
        if pass == 1 {
            a += ["-f", "null", "-y", "/dev/null"]        // first pass of two: only the stats file is kept
        } else if elementary {
            a += ["-f", "hevc", "-y", output.path]
        } else {
            if p.video.codec == .hevc && p.container != .mkv { a += ["-tag:v", "hvc1"] }
            if let tc = p.timecode, p.container != .mkv { a += ["-timecode", tc] }
            a += ["-r", "\(p.fps.num)/\(p.fps.den)", "-y", output.path]
        }
        return a
    }

    /// The 2-pass average mode: runs the first pass and returns its stats file (nil when the plan doesn't need one)
    static func twoPassStats(_ p: TranscodePlan, concat: URL?, tmp: URL, cancel: CancelFlag,
                             stage: @escaping (String, Double) -> Void, log: @escaping (String) -> Void,
                             progress: ((JobProgress) -> Void)? = nil) throws -> URL? {
        guard let r = p.video.rate, r.mode == .average, p.encoder == "libx265" else { return nil }
        let stats = tmp.appendingPathComponent("x265.stats")
        let args = arguments(p, concat: concat, output: stats, elementary: true, pass: 1, stats: stats)
        let res = encode(args, frames: p.frames, label: "Pass 1 of 2: measuring the picture (x265, average \(r.targetMbps) Mbps)", cancel: cancel, stage: stage, log: log,
                         progress: relabel(.pass1, progress))
        if cancel.isSet { throw Cancelled() }
        guard res.status == 0, FileManager.default.fileExists(atPath: stats.path) else { throw AppError("The first pass failed (ffmpeg error \(res.status)). See the log.") }
        return stats
    }

    /// Progress line of ffmpeg (-progress pipe:1): "frame=123"
    static func frame(of line: String) -> Int? {
        guard line.hasPrefix("frame=") else { return nil }
        return Int(line.dropFirst(6).trimmingCharacters(in: .whitespaces))
    }

    /// Runs ffmpeg with progress; returns the exit code and the frames encoded
    /// `progress` (Beta 2.0.0, optional): the same -progress blocks as structured data — frame=, fps= (ffmpeg's running
    /// average), bitrate= ("N/A" → nil, as in pass 1), total_size=, speed=, out_time_us= — once per block (at its
    /// "progress=" line), with stage `.encode` (callers re-label it: pass 1, pass 2, transcode). The arguments, the stage
    /// text and `done` (fed by frame(of:)) are exactly what they were.
    static func encode(_ args: [String], frames: Int, label: String, cancel: CancelFlag,
                       stage: @escaping (String, Double) -> Void, log: @escaping (String) -> Void,
                       progress: ((JobProgress) -> Void)? = nil) -> (status: Int32, done: Int) {
        guard let ffmpeg = Tools.ffmpeg else { return (-1, 0) }
        log("ffmpeg " + args.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ") + "\n")
        let started = Date()
        var done = 0
        stage(label + "…", 0)
        var block = JobProgress(stage: .encode, title: label + "…", fraction: 0, frame: 0, totalFrames: frames)
        progress?(block)
        let status = Tools.runStreaming(ffmpeg, args, cancel: cancel, line: { l in
            if let f = frame(of: l) {
                done = f
                let elapsed = Date().timeIntervalSince(started)
                let fps = elapsed > 0 ? Double(f) / elapsed : 0
                let left = fps > 0 ? Double(frames - f) / fps : 0
                let text = "\(label): frame \(Fmt.int(f)) of \(Fmt.int(frames)) · \(String(format: "%.1f", fps)) fps · \(Fmt.hm(left)) left"
                stage(text, Double(f) / Double(max(frames, 1)))
                if progress != nil { block.title = text; block.frame = f; block.fraction = min(1, Double(f) / Double(max(frames, 1))) }
                return
            }
            guard let progress, let eq = l.firstIndex(of: "=") else { return }
            let key = l[..<eq].trimmingCharacters(in: .whitespaces), value = l[l.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "fps": block.fps = Double(value)
            case "bitrate": block.bitrateKbps = value.hasSuffix("kbits/s") ? Double(value.dropLast(7).trimmingCharacters(in: .whitespaces)) : nil
            case "total_size": block.outBytes = Int64(value)
            case "speed": block.speed = value.hasSuffix("x") ? Double(value.dropLast().trimmingCharacters(in: .whitespaces)) : nil
            case "progress": progress(block)
            default: break
            }
        }, log: log)
        return (status, done)
    }

    /// The same progress, re-labelled with the stage the caller is in (nil stays nil: nothing is parsed)
    static func relabel(_ stage: JobProgress.Stage, _ progress: ((JobProgress) -> Void)?) -> ((JobProgress) -> Void)? {
        guard let progress else { return nil }
        return { var p = $0; p.stage = stage; progress(p) }
    }

    /// The Mux path: the picture as an elementary HEVC stream with the Dolby Vision / HDR10+ metadata injected.
    /// Returns the final stream (in `tmp`), the RPU that went in, and notes.
    /// `progress` (Beta 2.0.0, optional): readMetadata → pass1 + pass2 (2-pass) or encode → injectHDR10Plus → injectDV, each
    /// with its fraction inside the stage; the encode passes carry frames, fps, bitrate and bytes written.
    static func encodeElementary(_ p: TranscodePlan, tmp: URL, cancel: CancelFlag,
                                 stage: @escaping (String, Double) -> Void, log: @escaping (String) -> Void,
                                 progress: ((JobProgress) -> Void)? = nil) throws -> (hevc: URL, rpu: URL?, notes: [String]) {
        let fm = FileManager.default
        var notes: [String] = []
        // 1. Dolby Vision metadata → RPU (checked against the frame count before hours of encoding)
        var rpu: URL?
        if let src = p.hdr?.dolbyVision {
            stage("Reading the Dolby Vision metadata…", 0)
            progress?(JobProgress(stage: .readMetadata, title: "Reading the Dolby Vision metadata…", fraction: 0, totalFrames: p.frames))
            var xml = p.hdr?.dvXML
            if xml == nil {
                switch src {
                case .xml(let u): xml = u
                case .isxd(let parts):
                    let x = tmp.appendingPathComponent("DolbyVision_from_IMF.xml")
                    let r = try DolbyVisionMeta.xmlFromISXD(parts, to: x, log: log)
                    log("Dolby Vision metadata rebuilt from the IMF: \(r.frames) frames, \(r.shots) shots\n")
                    xml = x
                }
            }
            guard let xml else { throw AppError("No Dolby Vision metadata.") }
            let r = tmp.appendingPathComponent("DolbyVision.rpu")
            try DolbyVisionMeta.generateRPU(xml: xml, width: p.width, height: p.height, to: r)
            guard let s = DolbyVisionMeta.summary(r) else { throw AppError("dovi_tool couldn't summarize the generated metadata.") }
            guard s.frames == p.frames else {
                throw AppError("The Dolby Vision metadata covers \(Fmt.int(s.frames)) frames but the picture has \(Fmt.int(p.frames)) — they must match frame for frame.")
            }
            notes.append("Dolby Vision 8.1 metadata: " + s.line)
            rpu = r
        }
        if let j = p.hdr?.hdr10plus {
            guard Tools.hdr10plusTool != nil else { throw AppError("hdr10plus_tool isn't installed. Run: brew install hdr10plus_tool") }
            guard let n = HDR10Plus.frames(j) else { throw AppError("“\(j.lastPathComponent)” isn't HDR10+ metadata (no SceneInfo list).") }
            guard n == p.frames else { throw AppError("The HDR10+ metadata has \(Fmt.int(n)) frames but the picture has \(Fmt.int(p.frames)).") }
        }
        if cancel.isSet { throw Cancelled() }

        // 2. picture → HEVC 10-bit (x265)
        var concat: URL?
        if p.segments.count > 1 {
            var list = "ffconcat version 1.0\n"
            for s in p.segments {
                list += "file '\(s.file.path.replacingOccurrences(of: "'", with: "'\\''"))'\n"
                // the concat demuxer compares outpoint with the frame's own timestamp: a 6-decimal rounding up lets one
                // frame too many through, so the points sit a quarter frame after the first frame and half a frame before the end
                list += String(format: "inpoint %.6f\noutpoint %.6f\n", (Double(s.start) + 0.25) / p.fps.value, (Double(s.start + s.count) - 0.5) / p.fps.value)
            }
            let u = tmp.appendingPathComponent("segments.ffconcat")
            try list.write(to: u, atomically: true, encoding: .utf8)
            concat = u
        }
        let base = tmp.appendingPathComponent("video.hevc")
        let started = Date()
        let q = p.video.quality ?? .high, s = p.video.speed ?? .medium, rate = p.video.rate ?? HDRSettings.Rate()
        let stats = try twoPassStats(p, concat: concat, tmp: tmp, cancel: cancel, stage: stage, log: log, progress: progress)
        let args = arguments(p, concat: concat, output: base, elementary: true, pass: stats == nil ? 0 : 2, stats: stats)
        let label = stats == nil ? "Encoding the picture (x265 \(s.preset), \(rate.text(q)))" : "Pass 2 of 2: encoding the picture (x265 \(s.preset), \(rate.text(q)))"
        let r = encode(args, frames: p.frames, label: label, cancel: cancel, stage: stage, log: log, progress: relabel(stats == nil ? .encode : .pass2, progress))
        if cancel.isSet { throw Cancelled() }
        guard r.status == 0, fm.fileExists(atPath: base.path) else { throw AppError("The picture encode failed (ffmpeg error \(r.status)). See the log.") }
        guard r.done == p.frames else { throw AppError("The encode produced \(Fmt.int(r.done)) frames, \(Fmt.int(p.frames)) were expected — the source is shorter than its metadata says.") }
        let c = p.outputColor
        notes.append("Picture: HEVC Main 10 4:2:0 \(c.short) · x265 \(s.preset), \(rate.text(q)) · \(Fmt.int(r.done)) frames in \(Fmt.hm(Date().timeIntervalSince(started)))" +
                     (p.hdr.map { " · HDR10 \($0.mastering.text), MaxCLL \($0.maxCLL), MaxFALL \($0.maxFALL)" } ?? ""))

        // 3. HDR10+ (SEI) and Dolby Vision (RPU NAL units) go into the stream, frame by frame
        var current = base
        if let j = p.hdr?.hdr10plus, let tool = Tools.hdr10plusTool {
            stage("Adding the HDR10+ metadata…", 0.5)
            progress?(JobProgress(stage: .injectHDR10Plus, title: "Adding the HDR10+ metadata…", fraction: 0, totalFrames: p.frames))
            let next = tmp.appendingPathComponent("video.hdr10plus.hevc")
            let rr = Tools.runAll(tool, ["inject", "-i", current.path, "-j", j.path, "-o", next.path])
            log(rr.text)
            guard rr.status == 0, fm.fileExists(atPath: next.path) else { throw AppError("hdr10plus_tool couldn't add the HDR10+ metadata. See the log.") }
            try? fm.removeItem(at: current); current = next
            notes.append("HDR10+ metadata added from \(j.lastPathComponent)")
        }
        if cancel.isSet { throw Cancelled() }
        if let rpu, let tool = Tools.doviTool {
            stage("Adding the Dolby Vision metadata…", 0.8)
            progress?(JobProgress(stage: .injectDV, title: "Adding the Dolby Vision metadata…", fraction: 0, totalFrames: p.frames))
            let next = tmp.appendingPathComponent("video.dv.hevc")
            let rr = Tools.runAll(tool, ["inject-rpu", "-i", current.path, "--rpu-in", rpu.path, "-o", next.path])
            log(rr.text)
            guard rr.status == 0, fm.fileExists(atPath: next.path) else { throw AppError("dovi_tool couldn't add the Dolby Vision metadata. See the log.") }
            try? fm.removeItem(at: current); current = next
        }
        return (current, rpu, notes)
    }

    /// The final file's picture as an Annex-B HEVC stream, piped into a tool (dovi_tool / hdr10plus_tool reading "-")
    static func pipeVideo(_ file: URL, into exe: String, _ args: [String], cancel: CancelFlag) -> (status: Int32, text: String) {
        guard let ffmpeg = Tools.ffmpeg else { return (-1, "ffmpeg not found") }
        let ff = Process(), tool = Process()
        ff.executableURL = URL(fileURLWithPath: ffmpeg)
        ff.arguments = ["-nostdin", "-v", "error", "-i", file.path, "-map", "0:v:0", "-c:v", "copy", "-bsf:v", "hevc_mp4toannexb", "-f", "hevc", "-"]
        tool.executableURL = URL(fileURLWithPath: exe)
        tool.arguments = args
        let video = Pipe(), out = Pipe()
        ff.standardInput = FileHandle.nullDevice; ff.standardOutput = video; ff.standardError = FileHandle.nullDevice
        tool.standardInput = video; tool.standardOutput = out; tool.standardError = out
        let lock = NSLock()
        var text = Data()
        out.fileHandleForReading.readabilityHandler = { h in let d = h.availableData; lock.lock(); text.append(d); lock.unlock() }
        do { try tool.run(); try ff.run() } catch {
            out.fileHandleForReading.readabilityHandler = nil
            return (-1, error.localizedDescription)
        }
        try? video.fileHandleForWriting.close(); try? video.fileHandleForReading.close()   // only the children keep the pipe
        while ff.isRunning || tool.isRunning {
            if cancel.isSet { if ff.isRunning { ff.terminate() }; if tool.isRunning { tool.terminate() } }
            Thread.sleep(forTimeInterval: 0.2)
        }
        out.fileHandleForReading.readabilityHandler = nil
        let rest = out.fileHandleForReading.readDataToEndOfFile()
        lock.lock(); text.append(rest); lock.unlock()
        let ok = ff.terminationStatus == 0 && tool.terminationStatus == 0 && !cancel.isSet
        return (ok ? 0 : max(ff.terminationStatus, tool.terminationStatus, 1), String(decoding: text, as: UTF8.self))
    }

    static func md5(_ u: URL) -> String? {
        guard let d = try? Data(contentsOf: u, options: .alwaysMapped) else { return nil }
        return Insecure.MD5.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }

    /// The Mux path's check of the encoded picture in the final file: frame count and signalling (MediaInfo), then the
    /// metadata read back frame by frame — the Dolby Vision RPU must be byte-identical to the one generated, HDR10+ in every frame.
    static func verifyElementary(_ out: URL, plan: TranscodePlan, rpu: URL?, tmp: URL, cancel: CancelFlag,
                                 stage: (String, Double) -> Void) -> (ok: Bool, lines: [String]) {
        guard let v = MediaInfo.tracks(out).first(where: { $0.type == "Video" }) else { return (false, ["⚠ Video track not found in the final file ✗"]) }
        var ok = true, lines: [String] = []
        let hdr = v["HDR_Format"] ?? ""
        let frames = Int(v["FrameCount"] ?? "") ?? -1
        lines.append("Picture: HEVC \(v["Format_Profile"] ?? "") · \(Fmt.int(frames)) frames (expected \(Fmt.int(plan.frames))) \(frames == plan.frames ? "✓" : "✗")")
        if frames != plan.frames { ok = false }
        lines += colourLines(v, expected: plan.outputColor, ok: &ok)
        func flag(_ name: String, _ present: Bool) {
            lines.append("\(name): \(present ? "signalled" : "MISSING") \(present ? "✓" : "✗")")
            if !present { ok = false }
        }
        if let h = plan.hdr {
            flag("HDR10 (\(plan.outputColor.short) · SMPTE ST 2086 mastering + MaxCLL/MaxFALL)", hdr.contains("2086"))
            if h.dolbyVision != nil { flag("Dolby Vision 8.1 (HDR10-compatible)", hdr.contains("Dolby Vision")) }
            if h.hdr10plus != nil { flag("HDR10+ (SMPTE ST 2094-40)", hdr.contains("2094")) }
        }
        if let rpu, let tool = Tools.doviTool, !cancel.isSet {
            stage("Reading the Dolby Vision metadata back from the final file…", 0.5)
            let back = tmp.appendingPathComponent("readback.rpu")
            let r = pipeVideo(out, into: tool, ["extract-rpu", "-", "-o", back.path], cancel: cancel)
            let same = r.status == 0 && md5(back) != nil && md5(back) == md5(rpu)
            let s = DolbyVisionMeta.summary(back)
            lines.append(same ? "Dolby Vision metadata read back from the file: identical to the generated RPU, all \(Fmt.int(s?.frames ?? 0)) frames (\(Fmt.int(s?.shots ?? 0)) shots) ✓"
                              : "Dolby Vision metadata read back from the file: DIFFERENT from the generated RPU ✗")
            if !same { ok = false }
            try? FileManager.default.removeItem(at: back)
        }
        if let json = plan.hdr?.hdr10plus, let tool = Tools.hdr10plusTool, !cancel.isSet {
            stage("Reading the HDR10+ metadata back from the final file…", 0.8)
            let back = tmp.appendingPathComponent("readback.hdr10plus.json")
            let r = pipeVideo(out, into: tool, ["extract", "-", "-o", back.path], cancel: cancel)
            let n = r.status == 0 ? HDR10Plus.frames(back) : nil
            lines.append("HDR10+ metadata read back from the file: \(n.map { Fmt.int($0) } ?? "none") of \(Fmt.int(plan.frames)) frames (from \(json.lastPathComponent)) \(n == plan.frames ? "✓" : "✗")")
            if n != plan.frames { ok = false }
            try? FileManager.default.removeItem(at: back)
        }
        return (ok, lines)
    }

    /// MediaInfo's name for an ffprobe colour tag
    static func miName(_ name: String?) -> String {
        switch name {
        case "bt709": return "BT.709"
        case "bt2020": return "BT.2020"
        case "bt2020nc": return "BT.2020 non-constant"
        case "bt2020c": return "BT.2020 constant"
        case "smpte2084": return "PQ"
        case "arib-std-b67": return "HLG"
        case "smpte432": return "Display P3"
        case "smpte431": return "DCI P3"
        case "smpte170m": return "BT.601 NTSC"
        case "bt470bg": return "BT.601 PAL"
        case "iec61966-2-1": return "sRGB/sYCC"
        default: return name ?? ""
        }
    }
    /// Colour tags of the written picture against the plan (MediaInfo names)
    static func colourLines(_ v: MITrack, expected c: SourceColor, ok: inout Bool) -> [String] {
        let got = "\(v["colour_primaries"] ?? "—") / \(v["transfer_characteristics"] ?? "—") / \(v["matrix_coefficients"] ?? "—")"
        let want = "\(miName(c.primaries)) / \(miName(c.transfer)) / \(miName(c.matrix))"
        let same = got == want
        if !same { ok = false }
        return ["Colour tags: \(got) (primaries / transfer / matrix)\(same ? " ✓" : " — expected \(want) ✗")"]
    }
}

// MARK: - The job (Transcode tab and command line)

struct TranscodeResult {
    let state: JobState
    let lines: [String]
    let output: URL?
    var inspection: InspectionData? = nil
    var qc: RenderQC.Report? = nil
    var seconds = 0.0
}

/// Runs one transcode: temporary file next to the destination, progress and cancel like the mux, the Mac kept awake,
/// then the checks (frames, duration, colour, timecode; Render QC; VMAF) and the move into place.
final class TranscodeRunner {
    let plan: TranscodePlan
    let output: URL
    let runQC: Bool
    let runVMAF: Bool
    let cancel = CancelFlag()
    var onStage: (String, Double) -> Void = { _, _ in }
    var onLog: (String) -> Void = { _ in }
    // Beta 2.0.0 — nil by default; the same rules as JobRunner's (called off the main thread, never waited on), and
    // forwarded to the inner JobRunner on the Dolby Vision / HDR10+ path. onWorkFolder can come twice there: this
    // runner's temporary folder, then the inner JobRunner's.
    var onProgress: ((JobProgress) -> Void)?
    var onFinding: ((String) -> Void)?
    var onWorkFolder: ((URL) -> Void)?
    private var inner: JobRunner?
    private var findingsSent: [String] = []

    init(plan: TranscodePlan, output: URL, runQC: Bool, runVMAF: Bool) {
        self.plan = plan; self.output = output; self.runQC = runQC; self.runVMAF = runVMAF
    }

    /// The stages this transcode will go through, with their weight in the overall % — the stages run() reports, in order
    /// (seconds-equivalent, as JobRunner's): the encode from TranscodePlan.estimatedSeconds (2-pass: pass 1 = 35 % of
    /// pass 2); on the Dolby Vision / HDR10+ path the inner JobRunner's own plan (it reads the source's tracks to build it);
    /// then checking the result 2 s, Render QC at ≈ 250 frames/s (it decodes every frame, small), VMAF 12 s per 8-second
    /// stretch (3 stretches past 30 s, else 1), moving into place 0.5 s and the Academy / Zidoo check 5 s.
    static func plannedStages(_ plan: TranscodePlan, runQC: Bool, runVMAF: Bool) -> [(stage: JobProgress.Stage, weight: Double)] {
        JobRunner.merged(plannedItems(plan, runQC: runQC, runVMAF: runVMAF))
    }
    static func plannedItems(_ plan: TranscodePlan, runQC: Bool, runVMAF: Bool) -> [JobRunner.PlannedItem] {
        var items: [JobRunner.PlannedItem] = []
        if plan.needsInjection {
            // the inner JobRunner's own plan, from the same job it will run (reading the source's tracks: a fraction of a second)
            let placeholder = plan.source.url.deletingPathExtension().appendingPathExtension(plan.container.rawValue)
            items += JobRunner.plannedItems(injectionSpec(plan, output: placeholder))
        } else if let r = plan.video.rate, r.mode == .average, plan.encoder == "libx265" {
            items.append(.init(stage: .pass1, weight: 0.35 * plan.estimatedSeconds / 1.35, key: nil))
            items.append(.init(stage: .pass2, weight: plan.estimatedSeconds / 1.35, key: nil))
        } else {
            items.append(.init(stage: .transcodeVideo, weight: plan.estimatedSeconds, key: nil))
        }
        items.append(.init(stage: .checkResult, weight: 2, key: nil))
        if runQC { items.append(.init(stage: .renderQC, weight: max(2, Double(plan.frames) / 250), key: nil)) }
        if runVMAF && plan.color == .passthrough && Tools.canVMAF { items.append(.init(stage: .vmaf, weight: plan.seconds > 30 ? 36 : 12, key: nil)) }
        if !plan.needsInjection { items.append(.init(stage: .finalize, weight: 0.5, key: nil)) }
        items.append(.init(stage: .academy, weight: 5, key: nil))
        return items
    }
    /// The Dolby Vision / HDR10+ path's job: the picture encoded with its metadata, the source's other tracks bit for bit
    static func injectionSpec(_ plan: TranscodePlan, output: URL) -> JobSpec {
        let project = Project()
        let r = Probe.tracks(for: plan.source.url)
        project.insert(r.tracks)
        project.autoGroup()
        project.container = plan.container
        project.setOutput(output)
        project.matchVideoEnd = false
        let inc = project.tracks.filter { $0.include && $0.kind != .other && (plan.effectiveAudio != .none || $0.kind != .audio) }
        var plans: [UUID: TrimPlan] = [:]
        for t in inc where t.kind == .audio { if let p = project.plan(for: t), t.isGroup || t.channelPermutation != nil { plans[t.id] = p } }
        return JobSpec(tracks: inc, plans: plans, output: output, disableExtraAudio: false, interleaveMs: 500, writeChannelMap: true,
                       verifyAudio: true, verifyVideo: false, fixColorTag: false, isMOV: plan.container == .mov, reference: nil,
                       isMKV: plan.container == .mkv, referenceOffset: 0, videoEncode: plan, pictureCheck: false)
    }
    private func progress(_ stage: JobProgress.Stage, _ title: String, _ f: Double) {
        onProgress?(JobProgress(stage: stage, title: title, fraction: min(max(f, 0), 1)))
    }
    /// onFinding for the lines that went into the result since `old`
    private func found(_ new: [String], since old: [String]) {
        guard onFinding != nil, new.count > old.count else { return }
        var left: [String: Int] = [:]
        for l in old { left[l, default: 0] += 1 }
        for l in new { if let n = left[l], n > 0 { left[l] = n - 1 } else { findingsSent.append(l); onFinding?(l) } }
    }
    func requestCancel() { cancel.set(); inner?.requestCancel() }

    /// Problems that stop the job before anything is written
    static func validate(_ p: TranscodePlan, output: URL) -> String? {
        if let problem = p.problem { return problem }
        let ext = output.pathExtension.lowercased()
        guard ext == p.container.rawValue else { return "The output must end in .\(p.container.rawValue) for this format." }
        if Tools.sameFile(p.source.url, output) { return "The output can't be the source file — choose another name. The original is never touched." }
        let dir = output.deletingLastPathComponent()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { return "The destination folder doesn't exist." }
        guard FileManager.default.isWritableFile(atPath: dir.path) else { return "No permission to write to the destination folder." }
        let need = p.estimatedBytes * (p.needsInjection ? 3 : 1.3) + 1_000_000_000
        if let free = Tools.freeSpace(at: dir), free < need {
            return "Not enough free space on the destination drive: about \(Fmt.bytes(need)) is needed (the file will be ~\(Fmt.bytes(p.estimatedBytes))) and \(Fmt.bytes(free)) is free."
        }
        return nil
    }

    func run() -> TranscodeResult {
        findingsSent = []
        let r = runTranscode()
        if onFinding != nil {      // the lines only a failure or a cancel adds
            var seen: [String: Int] = [:]
            for l in findingsSent { seen[l, default: 0] += 1 }
            for l in r.lines { if let n = seen[l], n > 0 { seen[l] = n - 1 } else { onFinding?(l) } }
        }
        return r
    }

    private func runTranscode() -> TranscodeResult {
        let started = Date()
        if let problem = Self.validate(plan, output: output) { return TranscodeResult(state: .failed, lines: [problem], output: nil) }
        let activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: "BROS-MUX is transcoding")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let fm = FileManager.default
        let dir = output.deletingLastPathComponent()
        JobRunner.removeStaleTemps(in: dir)
        let tmp = dir.appendingPathComponent(".BROS-MUX-tmp-\(UUID().uuidString)", isDirectory: true)
        do { try fm.createDirectory(at: tmp, withIntermediateDirectories: false) }
        catch { return TranscodeResult(state: .failed, lines: ["Couldn't create the temporary folder: \(error.localizedDescription)"], output: nil) }
        let tempLock = JobRunner.TempLock(tmp)      // Beta 2.0.0: removeStaleTemps leaves this folder alone while the job runs
        defer { tempLock.release() }
        defer { try? fm.removeItem(at: tmp) }
        onWorkFolder?(tmp)
        let cancelled = TranscodeResult(state: .cancelled, lines: ["Cancelled — nothing was written to the destination."], output: nil)
        var quiet = false                              // the inner JobRunner's lines were already sent, live
        var lines: [String] = [] { didSet { if !quiet { found(lines, since: oldValue) } } }
        var ok = true, warn = false
        let tmpOut: URL

        if plan.needsInjection {
            // Dolby Vision / HDR10+: the Mux engine does it (elementary HEVC + injection + MP4Box + bit-exact audio)
            let spec = Self.injectionSpec(plan, output: output)
            let job = JobRunner(spec)
            inner = job
            job.onStage = onStage; job.onLog = onLog
            job.onProgress = onProgress; job.onFinding = onFinding; job.onWorkFolder = onWorkFolder
            let res = job.run()
            findingsSent += res.lines
            if res.state == .cancelled || cancel.isSet { return cancelled }
            guard let out = res.output else { return TranscodeResult(state: .failed, lines: res.lines, output: nil) }
            quiet = true; lines = res.lines; quiet = false
            ok = res.state != .failed
            warn = res.state == .warning
            tmpOut = out                      // already in place; the checks below run on the final file
        } else {
            let ext = plan.container.rawValue
            let t = tmp.appendingPathComponent("output.\(ext)")
            let stats: URL?
            do { stats = try Transcode.twoPassStats(plan, concat: nil, tmp: tmp, cancel: cancel, stage: onStage, log: onLog, progress: onProgress) }
            catch is Cancelled { return cancelled }
            catch { return TranscodeResult(state: .failed, lines: [error.localizedDescription], output: nil) }
            let args = Transcode.arguments(plan, concat: nil, output: t, elementary: false, pass: stats == nil ? 0 : 2, stats: stats)
            let what: String
            switch plan.video {
            case .prores(let p): what = "Encoding \(p.label) (\(plan.encoder == "prores_videotoolbox" ? "Apple VideoToolbox" : "ffmpeg prores_ks"))"
            case .h264(let q, let s): what = "Encoding H.264 (\(plan.usesVideoToolbox ? "VideoToolbox" : "x264 \(s.preset)"), quality \(q.label.lowercased()))"
            case .hevc(let q, let s, let r): what = (stats == nil ? "Encoding HEVC" : "Pass 2 of 2: encoding HEVC") + " (\(plan.usesVideoToolbox ? "VideoToolbox" : "x265 \(s.preset)"), \(r.text(q)))"
            }
            let r = Transcode.encode(args, frames: plan.frames, label: what, cancel: cancel, stage: onStage, log: onLog,
                                     progress: Transcode.relabel(stats == nil ? .transcodeVideo : .pass2, onProgress))
            if cancel.isSet { return cancelled }
            guard r.status == 0, fm.fileExists(atPath: t.path) else {
                return TranscodeResult(state: .failed, lines: ["The encode failed (ffmpeg error \(r.status)). See the log."], output: nil)
            }
            lines.append("Picture: RE-ENCODED (\(plan.source.codecName) → \(plan.outputCodecName)) · \(plan.encoder) · \(Fmt.int(r.done)) frames in \(Fmt.hm(Date().timeIntervalSince(started)))")
            tmpOut = t
        }

        // checks on the picture written
        onStage("Checking the result (frames, duration, colour, timecode)…", 0.9)
        progress(.checkResult, "Checking the result (frames, duration, colour, timecode)…", 0)
        let mi = MediaInfo.tracks(tmpOut)
        let streams = Probe.raw(tmpOut)?.streams ?? []
        if let v = mi.first(where: { $0.type == "Video" }), let vs = streams.first(where: { $0.codec_type == "video" }) {
            let frames = Int(v["FrameCount"] ?? "") ?? Int(vs.nb_frames ?? "") ?? -1
            let framesOK = frames == plan.frames
            if !plan.needsInjection {
                lines.append("Frames: \(Fmt.int(frames)) (source \(Fmt.int(plan.frames))) \(framesOK ? "✓" : "✗")")
                if !framesOK { ok = false }
                let dur = v.d("Duration") ?? 0
                let durOK = abs(dur - plan.seconds) <= 1.5 / max(plan.fps.value, 1)
                lines.append(String(format: "Duration: %@ (source %@) %@", Fmt.duration(dur), Fmt.duration(plan.seconds), durOK ? "✓" : "✗"))
                if !durOK { ok = false }
                let got = "\(v["Format"] ?? "") \(v["Format_Profile"] ?? "")".trimmingCharacters(in: .whitespaces)
                lines.append("Codec: \(got) · \(v["BitDepth"] ?? "\(plan.outputBits)")-bit \(v["ChromaSubsampling"] ?? plan.outputChroma) · \(v["Width"] ?? "?")×\(v["Height"] ?? "?") · \(v["FrameRate"] ?? "?") fps" +
                             (v.d("BitRate").map { " · " + Fmt.bitrate($0) } ?? ""))
                let fpsOK = abs((v.d("FrameRate") ?? 0) - plan.fps.value) < 0.002
                if !fpsOK { lines.append("⚠ Frame rate: \(v["FrameRate"] ?? "?") in the file, \(plan.source.fpsText) in the source"); warn = true }
                lines += Transcode.colourLines(v, expected: plan.outputColor, ok: &ok)
                if plan.container != .mkv {
                    let tc = streams.first { $0.codec_type == "data" && $0.codec_tag_string == "tmcd" }?.tags?["timecode"] ?? vs.tags?["timecode"]
                    if let want = plan.timecode {
                        let same = tc == want
                        lines.append("Timecode: \(tc ?? "none") (source \(want)) \(same ? "✓" : "✗")")
                        if !same { ok = false }
                    } else { lines.append("Timecode: the source has none") }
                }
                let aOut = streams.filter { $0.codec_type == "audio" }.count
                if plan.effectiveAudio != .none {
                    let same = aOut == plan.source.audio.count
                    lines.append("Audio: \(aOut) track\(aOut == 1 ? "" : "s") (\(plan.effectiveAudio == .copy ? "copied bit for bit" : plan.effectiveAudio.label)) \(same ? "✓" : "— the source has \(plan.source.audio.count) ✗")")
                    if !same { ok = false }
                }
            }
        } else { lines.append("⚠ Couldn't read the picture back from the file ✗"); ok = false }
        if cancel.isSet { return cancelled }

        var qcReport: RenderQC.Report?
        if runQC {
            progress(.renderQC, "Render QC on the result…", 0)
            let rep = RenderQC.run(url: tmpOut, cancel: cancel) { s, p in
                self.onStage("Render QC on the result: " + s, 0.9 + p * 0.08)
                self.progress(.renderQC, "Render QC on the result: " + s, p)
            }
            if cancel.isSet { return cancelled }
            if let rep {
                qcReport = rep
                if rep.findings.isEmpty { lines.append("Render QC: no render faults found in \(Fmt.int(rep.framesAnalysed)) frames ✓") }
                else {
                    lines.append("Render QC: \(rep.errors) error(s), \(rep.warnings) warning(s), \(rep.findings.count - rep.errors - rep.warnings) note(s) in \(Fmt.int(rep.framesAnalysed)) frames" + (rep.errors > 0 ? " ✗" : " ⚠"))
                    for f in rep.findings.prefix(6) { lines.append("   \(f.severity == .error ? "ERROR" : f.severity == .warning ? "warning" : "note") \(RenderQC.timecode(frame: f.frame, fps: rep.info.fps, start: rep.info.startTimecode)) \(f.kind.rawValue): \(f.detail)") }
                    if rep.errors > 0 { ok = false } else { warn = true }
                }
            } else { lines.append("⚠ Render QC couldn't read the result"); warn = true }
        }
        if runVMAF && plan.color == .passthrough && Tools.canVMAF {
            if let v = vmaf(tmpOut) { lines.append(v.line); if v.mean < 80 { warn = true } }
            else if !cancel.isSet { lines.append("⚠ VMAF couldn't be measured"); warn = true }
            if cancel.isSet { return cancelled }
        }

        // into place (the Mux path already moved it)
        var finalOut = output
        if !plan.needsInjection {
            progress(.finalize, "Moving the file into place…", 0)
            if !ok && fm.fileExists(atPath: output.path) {
                let base = output.deletingPathExtension().lastPathComponent, ext = output.pathExtension
                var n = 0
                repeat { finalOut = dir.appendingPathComponent(base + "_FAILED" + (n == 0 ? "" : "-\(n)")).appendingPathExtension(ext); n += 1 } while fm.fileExists(atPath: finalOut.path)
                lines.append("A check failed, so the existing \(output.lastPathComponent) was left untouched; this result was saved as \(finalOut.lastPathComponent).")
            }
            do {
                if fm.fileExists(atPath: finalOut.path) { _ = try fm.replaceItemAt(finalOut, withItemAt: tmpOut) }
                else { try fm.moveItem(at: tmpOut, to: finalOut) }
            } catch { return TranscodeResult(state: .failed, lines: lines + ["Couldn't move the final file into place: \(error.localizedDescription)"], output: nil) }
        } else { finalOut = tmpOut }
        onStage("Checking the final file against the Academy specs and the Zidoo…", 1)
        progress(.academy, "Checking the final file against the Academy specs and the Zidoo…", 0)
        let insp = Inspection.analyze(finalOut)
        return TranscodeResult(state: ok ? (warn ? .warning : .ok) : .failed, lines: lines, output: finalOut, inspection: insp, qc: qcReport,
                               seconds: Date().timeIntervalSince(started))
    }

    /// VMAF of the result against the source on three 8-second stretches (both scaled to 1920×1080, libvmaf's model)
    func vmaf(_ out: URL) -> (mean: Double, line: String)? {
        guard let ffmpeg = Tools.ffmpeg else { return nil }
        let len = min(8.0, max(2.0, plan.seconds / 4))
        let points = plan.seconds > 30 ? [0.2, 0.5, 0.8].map { $0 * plan.seconds } : [max(0, plan.seconds / 2 - len / 2)]
        var scores: [Double] = []
        for (k, t) in points.enumerated() {
            if cancel.isSet { return nil }
            onStage("VMAF \(k + 1) of \(points.count) (\(Fmt.duration(t)))…", 0.98)
            progress(.vmaf, "VMAF \(k + 1) of \(points.count) (\(Fmt.duration(t)))…", Double(k) / Double(points.count))
            let args = ["-nostdin", "-hide_banner", "-nostats", "-ss", String(format: "%.3f", t), "-t", String(format: "%.3f", len), "-i", out.path,
                        "-ss", String(format: "%.3f", t), "-t", String(format: "%.3f", len), "-i", plan.source.url.path,
                        "-lavfi", "[0:v]scale=1920:1080:flags=bicubic,format=yuv420p10le,setsar=1[d];[1:v]scale=1920:1080:flags=bicubic,format=yuv420p10le,setsar=1[r];[d][r]libvmaf=n_threads=8",
                        "-an", "-f", "null", "-"]
            guard let d = Tools.runCancellable(ffmpeg, args, cancel: cancel, stderr: true) else { return nil }
            let text = String(decoding: d, as: UTF8.self)
            guard let r = text.range(of: #"VMAF score: ([0-9.]+)"#, options: .regularExpression),
                  let v = Double(text[r].split(separator: " ").last ?? "") else { return nil }
            scores.append(v)
        }
        guard !scores.isEmpty else { return nil }
        let mean = scores.reduce(0, +) / Double(scores.count)
        let verdict = mean >= 93 ? "visually transparent" : mean >= 80 ? "good" : mean >= 60 ? "visible loss" : "poor"
        return (mean, String(format: "VMAF vs the source: %.1f (%@) on %d stretch%@ of %.0f s · %@", mean, scores.map { String(format: "%.1f", $0) }.joined(separator: ", "), scores.count, scores.count == 1 ? "" : "es", len, verdict))
    }
}

// MARK: - Audio TRANSCODE (Beta 2.0.0): the pre-step the Delivery runs before JobRunner

/// Audio TRANSCODE pre-step (run by the Delivery before JobRunner); the input is the bytes JobRunner would mux.
/// The codec changes, never the mix: the same samples go in (GroupSources / WavInfo.writeTrimmed with the TrimPlan and the
/// channel permutation, exactly what JobRunner would have written; a non-WAV PCM stream is decoded by ffmpeg), each channel
/// is labelled by its role with an explicit layout (refused when the roles aren't known), and after the mux `verify` checks
/// the sync to the sample, the level and the identity of every channel against that same source.
/// The output is in the layout's standard order (5.1: L R C LFE Ls Rs — the Academy's), each channel labelled by its role.
enum AudioTranscode {
    /// AAC bitrate: 640 Kbps above two channels (5.0 / 5.1), 256 Kbps stereo, 128 Kbps mono
    static func aacKbps(channels: Int) -> Int { channels > 2 ? 640 : channels == 2 ? 256 : 128 }

    /// "TRANSCODE → AAC 5.1 · 640 Kbps", "TRANSCODE → PCM 24-bit 5.1"
    static func targetText(_ t: Track, to: AudioDelivery) -> String {
        let ch = Probe.channelText(t.channels, nil)
        switch to {
        case .copy: return "COPY · bit-exact"
        case .aac: return "TRANSCODE → AAC \(ch) · \(aacKbps(channels: t.channels)) Kbps"
        case .pcm24: return "TRANSCODE → PCM 24-bit \(ch)"
        }
    }

    static let dolbyCodecs: Set<String> = ["eac3", "ac3", "truehd", "mlp", "ac4"]

    /// The roles of the channels in the order JobRunner writes them: the chosen order (channelTarget) when the channels are
    /// permuted, else the roles heard or set (channelRoles), else the layout the file declares. nil = not known.
    static func writtenRoles(_ t: Track) -> [ChannelRole]? {
        let order = t.channelPermutation != nil ? t.channelTarget : t.sourceOrder
        if let o = order, o.isComplete, o.count == t.channels { return o.roles }
        if t.channelPermutation == nil, let l = t.channelLayout, let r = roles(ofLayout: l), r.count == t.channels { return r }
        if t.channels == 1 { return [.M] }
        if t.channels == 2 && t.channelPermutation == nil { return [.L, .R] }     // two channels with no labels: left, right (every player reads them so)
        return nil
    }
    /// ffmpeg's layout names → roles (the order of the channels in that layout)
    static func roles(ofLayout l: String) -> [ChannelRole]? {
        switch l {
        case "mono": return [.M]
        case "stereo": return [.L, .R]
        case "3.0": return [.L, .R, .C]
        case "quad", "quad(side)": return [.L, .R, .Ls, .Rs]
        case "5.0", "5.0(side)": return [.L, .R, .C, .Ls, .Rs]
        case "5.1", "5.1(side)": return [.L, .R, .C, .LFE, .Ls, .Rs]
        case "7.1": return [.L, .R, .C, .LFE, .Lrs, .Rrs, .Ls, .Rs]
        default: return nil
        }
    }
    /// The output: ffmpeg's name for each role, and the layout they make (AAC through AudioToolbox takes the "side" 5.x)
    static func outputLayout(_ roles: [ChannelRole], for to: AudioDelivery) -> (names: [String], layout: String)? {
        let rears = roles.contains(.Lrs) || roles.contains(.Rrs)
        let side = to == .aac || rears
        func name(_ r: ChannelRole) -> String {
            switch r {
            case .L: return "FL"; case .R: return "FR"; case .C, .M: return "FC"; case .LFE: return "LFE"
            case .Ls: return side ? "SL" : "BL"; case .Rs: return side ? "SR" : "BR"
            case .Lrs: return "BL"; case .Rrs: return "BR"
            }
        }
        let names = roles.map(name)
        guard Set(names).count == names.count else { return nil }
        let layouts: [(Set<String>, String)] = [
            (["FC"], "mono"), (["FL", "FR"], "stereo"), (["FL", "FR", "FC"], "3.0"),
            (["FL", "FR", "BL", "BR"], "quad"), (["FL", "FR", "SL", "SR"], "quad(side)"),
            (["FL", "FR", "FC", "BL", "BR"], "5.0"), (["FL", "FR", "FC", "SL", "SR"], "5.0(side)"),
            (["FL", "FR", "FC", "LFE", "BL", "BR"], "5.1"), (["FL", "FR", "FC", "LFE", "SL", "SR"], "5.1(side)"),
            (["FL", "FR", "FC", "LFE", "BL", "BR", "SL", "SR"], "7.1"),
        ]
        guard let l = layouts.first(where: { $0.0 == Set(names) })?.1 else { return nil }
        if to == .aac && !["mono", "stereo", "3.0", "quad", "5.0(side)", "5.1(side)"].contains(l) { return nil }
        return (names, l)
    }

    // the highest sample of a float source (dBFS), measured once per track: PCM 24-bit can't hold more than 0 dBFS
    private static let peakLock = NSLock()
    private static var peakCache: [String: Double] = [:]
    private static func peakKey(_ t: Track) -> String { (t.isGroup ? t.members : [t]).map { "\($0.url.path)#\($0.streamIndex)" }.joined(separator: "|") }
    private static func peakDB(_ url: URL, map: String, cancel: CancelFlag) -> Double? {
        guard let ffmpeg = Tools.ffmpeg,
              let d = Tools.runCancellable(ffmpeg, ["-nostdin", "-hide_banner", "-v", "info", "-i", url.path, "-map", map,
                                                    "-af", "astats=measure_perchannel=none:measure_overall=Peak_level", "-f", "null", "-"], cancel: cancel, stderr: true)
        else { return nil }
        let text = String(decoding: d, as: UTF8.self)
        guard let r = text.range(of: #"Peak level dB: (-?inf|-?[0-9.]+)"#, options: [.regularExpression, .backwards]) else { return nil }
        let v = String(text[r].split(separator: ":").last ?? "").trimmingCharacters(in: .whitespaces)
        return v.hasSuffix("inf") ? -Double.infinity : Double(v)
    }
    /// The peak of a float PCM source in dBFS (a full read — call it off the main thread; problem() then knows it)
    static func measureFloatPeak(_ t: Track, cancel: CancelFlag) -> Double? {
        guard t.isFloatPCM else { return nil }
        let key = peakKey(t)
        peakLock.lock(); let known = peakCache[key]; peakLock.unlock()
        if let known { return known }
        var peak = -Double.infinity
        for m in t.isGroup ? t.members : [t] {
            guard let p = peakDB(m.url, map: "0:\(m.streamIndex)", cancel: cancel) else { return nil }
            peak = max(peak, p)
        }
        peakLock.lock(); peakCache[key] = peak; peakLock.unlock()
        return peak
    }

    /// Why this track can't become `to` (AAC > 8 ch, float > 0 dBFS → PCM 24, Dolby source…); nil = it can
    /// Quick: nothing is decoded. A float source's peak is known only once measureFloatPeak (or prepare) has read it.
    static func problem(_ t: Track, to: AudioDelivery) -> String? {
        guard to != .copy else { return nil }
        let name = "“\(t.title)”"
        guard t.kind == .audio else { return "\(name) isn't audio." }
        if dolbyCodecs.contains(t.codecKey) || t.isAtmos {
            return "\(name) is Dolby (\(t.codecName)): it only goes in as it is (COPY) — re-encoding would lose the Dolby / Atmos metadata."
        }
        if to == .aac && t.codecKey == "aac" { return "\(name) is already AAC: COPY keeps it as it is (encoding AAC again only loses quality)." }
        if to == .pcm24 && t.codecKey == "pcm_s24le" { return "\(name) is already PCM 24-bit: COPY gives the same samples, bit for bit." }
        if to == .aac && t.channels > 8 { return "AAC carries up to 8 channels and \(name) has \(t.channels) — keep it as it is (COPY)." }
        if to == .aac && t.sampleRate > 48000 { return "AAC is made at 48 kHz or less here and \(name) is \(Fmt.hz(t.sampleRate)) — keep it as it is (COPY) or use PCM 24-bit." }
        guard t.sampleRate > 0, t.channels > 0 else { return "\(name): the sample rate and channels couldn't be read." }
        guard let roles = writtenRoles(t) else {
            return "The channels of \(name) aren't identified (\(t.channels) channels, no labels) — set them first with “Channels…”, so each one keeps its place."
        }
        guard outputLayout(roles, for: to) != nil else {
            let order = ChannelOrder(roles: roles).text
            return to == .aac ? "AAC here takes mono, stereo, 3.0, quad, 5.0 or 5.1 — \(name) is \(order): deliver it as PCM 24-bit or COPY."
                              : "PCM 24-bit here takes mono, stereo, 3.0, quad, 5.0, 5.1 or 7.1 — \(name) is \(order): keep it as it is (COPY)."
        }
        if to == .pcm24 && t.isFloatPCM {
            peakLock.lock(); let peak = peakCache[peakKey(t)]; peakLock.unlock()
            if let peak, peak > 0 {
                return "\(name) is float and peaks at \(String(format: "%+.2f", peak)) dBFS: PCM 24-bit would clip it — keep it as it is (COPY)."
            }
        }
        return nil
    }

    /// Writes <folder>/audio-<n>.m4a (AAC, edit list kept) or .wav (PCM 24-bit, -rf64 auto); returns it
    static func prepare(_ t: Track, plan: TrimPlan?, to: AudioDelivery, folder: URL, index: Int, cancel: CancelFlag,
                        progress: (Double) -> Void) throws -> URL {
        guard to != .copy else { throw AppError("Nothing to transcode: “\(t.title)” goes in as it is (COPY).") }
        if let p = problem(t, to: to) { throw AppError(p) }
        guard Tools.ffmpeg != nil else { throw AppError("ffmpeg isn't installed. Run: brew install ffmpeg") }
        guard let roles = writtenRoles(t), let layout = outputLayout(roles, for: to) else { throw AppError("The channels of “\(t.title)” aren't identified.") }
        let fm = FileManager.default
        // 1. the bytes JobRunner would mux (same trim, same channel order), as a WAV next to the output
        var input = t.url, map = "0:\(t.streamIndex)"
        var frames = Int((t.duration * t.sampleRate).rounded())
        var temp: URL?
        defer { if let temp { try? fm.removeItem(at: temp) } }
        if t.isGroup {
            let plan = plan ?? TrimPlan(pad: 0, cut: 0, keep: t.groupTotal, total: t.groupTotal)
            let dst = folder.appendingPathComponent("audio-\(index)-input.wav")
            temp = dst
            let bps = t.groupBPS
            var sources: [ByteSource] = []
            defer { for s in sources { try? s.finish() } }
            for m in t.orderedMembers { sources.append(try GroupSources.open(m, as: t.codecKey, bps: bps, pad: plan.pad, cut: plan.cut, keep: plan.keep)) }
            let order = t.channelPermutation != nil ? t.channelTarget : t.sourceOrder
            let fmt = GroupSources.fmtChunk(channels: t.channels, sampleRate: t.sampleRate, bps: bps, validBits: t.bitDepth, float: t.isFloatPCM,
                                            order: order?.isComplete == true ? order : nil)
            try GroupSources.writeInterleaved(sources, bps: bps, frames: plan.pad + plan.keep, fmt: fmt, to: dst, cancel: cancel) { progress($0 * 0.2) }
            input = dst; map = "0:a:0"; frames = plan.pad + plan.keep
        } else if t.isPCM, let wav = t.wav {
            let total = wav.dataSize / max(wav.blockAlign, 1)
            let plan = plan ?? TrimPlan(pad: 0, cut: 0, keep: total, total: total)
            let dst = folder.appendingPathComponent("audio-\(index)-input.wav")
            temp = dst
            try WavInfo.writeTrimmed(wav, from: t.url, to: dst, pad: plan.pad, cut: plan.cut, keep: plan.keep, order: t.channelPermutation, cancel: cancel) { progress($0 * 0.2) }
            input = dst; map = "0:a:0"; frames = plan.pad + plan.keep
        } else if let plan, !plan.isIdentity {
            throw AppError("“\(t.title)” (\(t.codecName)) can't be trimmed for the sync — only WAV and mono PCM can.")
        }
        if cancel.isSet { throw Cancelled() }
        // 2. a float source must fit in 24 bits
        if to == .pcm24 && t.isFloatPCM {
            guard let peak = peakDB(input, map: map, cancel: cancel) else {
                if cancel.isSet { throw Cancelled() }
                throw AppError("Couldn't measure the peak of “\(t.title)”.")
            }
            if peak > 0 {
                peakLock.lock(); peakCache[peakKey(t)] = max(peak, peakCache[peakKey(t)] ?? peak); peakLock.unlock()
                throw AppError("“\(t.title)” is float and peaks at \(String(format: "%+.2f", peak)) dBFS: PCM 24-bit would clip it — keep it as it is (COPY).")
            }
        }
        // 3. ffmpeg: each channel to its role, explicitly (channelmap by index → named channels of the layout), then the codec
        let out = folder.appendingPathComponent("audio-\(index).\(to == .aac ? "m4a" : "wav")")
        try? fm.removeItem(at: out)
        let channelmap = "channelmap=map=" + layout.names.enumerated().map { "\($0.offset)-\($0.element)" }.joined(separator: "|") + ":channel_layout=\(layout.layout)"
        var args = ["-nostdin", "-v", "error", "-nostats", "-progress", "pipe:1", "-i", input.path, "-map", map, "-vn", "-sn", "-dn",
                    "-af", channelmap]
        if to == .aac { args += ["-c:a", Tools.aacEncoder, "-b:a", "\(aacKbps(channels: t.channels))k", "-use_editlist", "1", "-y", out.path] }
        else { args += ["-c:a", "pcm_s24le", "-rf64", "auto", "-y", out.path] }
        let seconds = Double(max(frames, 1)) / max(t.sampleRate, 1)
        let r = run(args, cancel: cancel) { line in
            if line.hasPrefix("out_time_us="), let us = Double(line.dropFirst(12)) { progress(0.2 + 0.8 * min(1, max(0, us / 1e6 / seconds))) }
        }
        if cancel.isSet { try? fm.removeItem(at: out); throw Cancelled() }
        guard r.status == 0, ((try? out.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0 else {
            try? fm.removeItem(at: out)
            throw AppError("The audio transcode of “\(t.title)” failed (ffmpeg error \(r.status)): \(r.errors.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        progress(1)
        return out
    }

    /// ffmpeg read on this thread, line by line (stdout), the errors kept; the cancel flag stops it
    private static func run(_ args: [String], cancel: CancelFlag, line: (String) -> Void) -> (status: Int32, errors: String) {
        guard let ffmpeg = Tools.ffmpeg else { return (-1, "ffmpeg not found") }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ffmpeg)
        p.arguments = args
        p.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        let lock = NSLock()
        var errors = Data()
        err.fileHandleForReading.readabilityHandler = { h in let d = h.availableData; lock.lock(); errors.append(d); lock.unlock() }
        do { try p.run() } catch { err.fileHandleForReading.readabilityHandler = nil; return (-1, error.localizedDescription) }
        var pending = ""
        while true {
            let d = out.fileHandleForReading.availableData       // ffmpeg writes a progress block every ~0.5 s
            if cancel.isSet && p.isRunning { p.terminate() }
            if d.isEmpty { break }
            pending += String(decoding: d, as: UTF8.self)
            while let nl = pending.firstIndex(of: "\n") { line(String(pending[..<nl])); pending = String(pending[pending.index(after: nl)...]) }
        }
        p.waitUntilExit()
        err.fileHandleForReading.readabilityHandler = nil
        let rest = err.fileHandleForReading.readDataToEndOfFile()
        try? out.fileHandleForReading.close(); try? err.fileHandleForReading.close()
        lock.lock(); errors.append(rest); let text = String(decoding: errors, as: UTF8.self); lock.unlock()
        return (p.terminationReason == .exit ? p.terminationStatus : -2, text)
    }

    /// Interleaved samples → floats (full scale ±1)
    static func floats(_ d: Data, codec: String) -> [Float]? {
        switch codec {
        case "pcm_f32le":
            return d.withUnsafeBytes { Array($0.bindMemory(to: Float.self).prefix(d.count / 4)) }
        case "pcm_f64le":
            return d.withUnsafeBytes { Array($0.bindMemory(to: Double.self).prefix(d.count / 8)).map { Float($0) } }
        case "pcm_s16le":
            return d.withUnsafeBytes { Array($0.bindMemory(to: Int16.self).prefix(d.count / 2)).map { Float($0) / 32768 } }
        case "pcm_s32le":
            return d.withUnsafeBytes { Array($0.bindMemory(to: Int32.self).prefix(d.count / 4)).map { Float(Double($0) / 2147483648) } }
        case "pcm_s24le":
            let n = d.count / 3
            var out = [Float](repeating: 0, count: n)
            d.withUnsafeBytes { raw in
                let b = raw.bindMemory(to: UInt8.self)
                for i in 0..<n {
                    var v = Int32(b[3 * i]) | Int32(b[3 * i + 1]) << 8 | Int32(b[3 * i + 2]) << 16
                    if v & 0x80_0000 != 0 { v -= 0x100_0000 }
                    out[i] = Float(v) / 8_388_608
                }
            }
            return out
        case "pcm_u8":
            return d.map { (Float($0) - 128) / 128 }
        default: return nil
        }
    }

    /// The source as JobRunner would have muxed it (same trim, same channel order), as interleaved float frames
    private final class SourceFrames {
        let channels: Int
        private var wav: ByteSource?, wavCodec = "", members: [ByteSource] = [], memberCodec = "", bps = 0, pipe: PipeSource?
        init(_ t: Track, plan: TrimPlan?) throws {
            channels = t.channels
            if t.isGroup {
                let p = plan ?? TrimPlan(pad: 0, cut: 0, keep: t.groupTotal, total: t.groupTotal)
                bps = t.groupBPS; memberCodec = t.codecKey
                guard AudioTranscode.floats(Data(count: 0), codec: memberCodec) != nil else { throw AppError("can't read \(memberCodec)") }
                for m in t.orderedMembers { members.append(try GroupSources.open(m, as: t.codecKey, bps: bps, pad: p.pad, cut: p.cut, keep: p.keep)) }
            } else if t.isPCM, let w = t.wav {
                let total = w.dataSize / max(w.blockAlign, 1)
                let p = plan ?? TrimPlan(pad: 0, cut: 0, keep: total, total: total)
                wavCodec = t.codecKey
                guard AudioTranscode.floats(Data(count: 0), codec: wavCodec) != nil else { throw AppError("can't read \(wavCodec)") }
                wav = try WavRangeSource(t.url, info: w, pad: p.pad, cut: p.cut, keep: p.keep, order: t.channelPermutation)
                bps = w.blockAlign / max(t.channels, 1)
            } else {
                pipe = try PipeSource(["-i", t.url.path, "-map", "0:\(t.streamIndex)", "-c:a", "pcm_f32le", "-f", "f32le", "-"])
            }
        }
        /// up to `n` frames (empty = the end)
        func read(_ n: Int) throws -> [Float] {
            if let wav {
                let d = try GroupSources.readExactly(wav, n * channels * bps)
                return AudioTranscode.floats(d.prefix(d.count / (channels * bps) * channels * bps), codec: wavCodec) ?? []
            }
            if !members.isEmpty {
                var parts: [[Float]] = []
                for m in members { parts.append(AudioTranscode.floats(try GroupSources.readExactly(m, n * bps), codec: memberCodec) ?? []) }
                let f = parts.map(\.count).min() ?? 0
                var out = [Float](repeating: 0, count: f * channels)
                for (c, p) in parts.enumerated() { for i in 0..<f { out[i * channels + c] = p[i] } }
                return out
            }
            guard let pipe else { return [] }
            let d = try GroupSources.readExactly(pipe, n * channels * 4)
            return AudioTranscode.floats(d.prefix(d.count / (channels * 4) * channels * 4), codec: "pcm_f32le") ?? []
        }
        func close() { try? wav?.finish(); for m in members { try? m.finish() }; pipe?.abort() }
    }

    /// After the mux: lag 0 ± 1 sample against the trimmed source, per-channel level within ±0.1 dB, per-channel
    /// correlation > 0.9 (order unchanged). Returns ✓/✗ lines.
    /// The final track is decoded by ffmpeg (the edit list applied) and put back in the source's channel order by role; both
    /// are read side by side: per channel the energy of each, and their products at lags −1, 0, +1; three windows of 32,768
    /// samples (at 25, 50 and 75 %) give the lag by cross-correlation within ±4,096 samples.
    static func verify(final: URL, audioOrdinal: Int, source: Track, plan: TrimPlan?, to: AudioDelivery) -> [String] {
        let name = "Audio “\(source.title)” (\(targetText(source, to: to)))"
        guard to != .copy else { return [] }
        guard let roles = writtenRoles(source), let layout = outputLayout(roles, for: to) else { return ["\(name): the channels aren't identified — can't verify ✗"] }
        _ = layout
        let n = source.channels
        // the final track's channels, put back in the source's order by their roles (as the file itself declares them)
        let finals = Probe.raw(final)?.streams?.filter { $0.codec_type == "audio" } ?? []
        guard audioOrdinal < finals.count else { return ["\(name): audio track \(audioOrdinal + 1) isn't in the final file ✗"] }
        let fs = finals[audioOrdinal]
        guard (fs.channels ?? 0) == n else { return ["\(name): the final file's track has \(fs.channels ?? 0) channels, the source \(n) ✗"] }
        let finalRoles: [ChannelRole]? = fs.channel_layout.flatMap { AudioTranscode.roles(ofLayout: $0) } ?? (n == 1 ? [.M] : n == 2 ? [.L, .R] : nil)
        var pick = Array(0..<n), declared = true
        if let fr = finalRoles, fr.count == n, Set(fr) == Set(roles) { pick = roles.map { fr.firstIndex(of: $0)! } } else { declared = false }
        let src: SourceFrames, out: PipeSource
        do { src = try SourceFrames(source, plan: plan) } catch { return ["\(name): couldn't read the source — \(error.localizedDescription) ✗"] }
        do {
            let reorder = pick == Array(0..<n) ? [] : ["-af", "channelmap=map=" + pick.map(String.init).joined(separator: "|")]
            out = try PipeSource(["-i", final.path, "-map", "0:a:\(audioOrdinal)"] + reorder + ["-c:a", "pcm_f32le", "-f", "f32le", "-"])
        } catch { src.close(); return ["\(name): couldn't read the final file — \(error.localizedDescription) ✗"] }
        let expected = plan.map { $0.pad + $0.keep } ?? (source.isGroup ? source.groupTotal : source.totalSamples)
        let W = 32768, M = 4096
        let windowStarts = [0.25, 0.5, 0.75].map { Int(Double(expected) * $0) }.filter { $0 >= M && $0 + W + M <= expected }
        var winSrc = windowStarts.map { _ in [Float](repeating: 0, count: W) }
        var winOut = windowStarts.map { _ in [Float](repeating: 0, count: W + 2 * M) }
        var es = [Double](repeating: 0, count: n), eo = es, x0 = es, xp = es, xm = es    // xp: out late by 1, xm: out early by 1
        var prevS = [Float](repeating: 0, count: n), prevO = prevS
        var pos = 0, srcEnded = false, outFrames = 0, srcFrames = 0
        let chunk = 1 << 16
        do {
            while true {
                let a = srcEnded ? [] : try src.read(chunk)
                if a.isEmpty { srcEnded = true }
                let want = max(a.count, chunk * n)
                let bd = try GroupSources.readExactly(out, want * 4)
                let b = floats(bd.prefix(bd.count / (n * 4) * n * 4), codec: "pcm_f32le") ?? []
                if a.isEmpty && b.isEmpty { break }
                srcFrames += a.count / n; outFrames += b.count / n
                let f = min(a.count, b.count) / n
                if f > 0 {
                    a.withUnsafeBufferPointer { ap in b.withUnsafeBufferPointer { bp in
                        let s = ap.baseAddress!, o = bp.baseAddress!
                        for c in 0..<n {
                            var v: Float = 0
                            vDSP_dotpr(s + c, vDSP_Stride(n), s + c, vDSP_Stride(n), &v, vDSP_Length(f)); es[c] += Double(v)
                            vDSP_dotpr(o + c, vDSP_Stride(n), o + c, vDSP_Stride(n), &v, vDSP_Length(f)); eo[c] += Double(v)
                            vDSP_dotpr(s + c, vDSP_Stride(n), o + c, vDSP_Stride(n), &v, vDSP_Length(f)); x0[c] += Double(v)
                            if f > 1 {
                                vDSP_dotpr(s + c, vDSP_Stride(n), o + c + n, vDSP_Stride(n), &v, vDSP_Length(f - 1)); xp[c] += Double(v)
                                vDSP_dotpr(s + c + n, vDSP_Stride(n), o + c, vDSP_Stride(n), &v, vDSP_Length(f - 1)); xm[c] += Double(v)
                            }
                            if pos > 0 { xp[c] += Double(prevS[c] * o[c]); xm[c] += Double(s[c] * prevO[c]) }
                            prevS[c] = s[(f - 1) * n + c]; prevO[c] = o[(f - 1) * n + c]
                        }
                    } }
                }
                // the lag windows: the source's mono sum, and the final's with M frames of margin on each side
                for (k, w0) in windowStarts.enumerated() {
                    let s0 = max(pos, w0), s1 = min(pos + a.count / n, w0 + W)
                    if s0 < s1 { for i in s0..<s1 { var v: Float = 0; for c in 0..<n { v += a[(i - pos) * n + c] }; winSrc[k][i - w0] = v } }
                    let o0 = max(pos, w0 - M), o1 = min(pos + b.count / n, w0 + W + M)
                    if o0 < o1 { for i in o0..<o1 { var v: Float = 0; for c in 0..<n { v += b[(i - pos) * n + c] }; winOut[k][i - w0 + M] = v } }
                }
                pos += f
                if a.isEmpty && bd.count < want * 4 { break }     // the source has ended, and now the file too
            }
        } catch {
            src.close(); out.abort()
            return ["\(name): \(error.localizedDescription) ✗"]
        }
        src.close(); out.abort()
        guard srcFrames > 0, outFrames > 0 else { return ["\(name): nothing could be read back — can't confirm ✗"] }
        var lines: [String] = []
        // 1. the lag
        var lags: [Int] = []
        for k in windowStarts.indices {
            let c = SyncEngine.correlate(winSrc[k], winOut[k])
            if let p = SyncEngine.peak(c, guardBand: 64), p.value >= 0.5 { lags.append(Int(p.index.rounded()) - M) }
        }
        let codecPad = to == .aac ? 2048 : 0
        let lengthText: String
        if outFrames == srcFrames { lengthText = "\(Fmt.int(srcFrames)) samples, the source's length" }
        else if outFrames > srcFrames { lengthText = "\(Fmt.int(srcFrames)) samples + \(Fmt.int(outFrames - srcFrames)) of encoder padding at the end" }
        else { lengthText = "\(Fmt.int(outFrames)) samples, \(Fmt.int(srcFrames - outFrames)) fewer than the source" }
        let lengthOK = outFrames >= srcFrames && outFrames - srcFrames <= codecPad
        var lag = 0
        if lags.isEmpty {
            lines.append("⚠ \(name): the lag couldn't be measured (too short or silent where it was checked) · \(lengthText)" + (lengthOK ? "" : " ✗"))
        } else {
            lag = Int(Fmt.median(lags.map(Double.init)).rounded())
            let ok = abs(lag) <= 1 && lags.allSatisfy { abs($0 - lag) <= 1 }
            let ms = Double(lag) / max(source.sampleRate, 1) * 1000
            lines.append("\(name): " + (lag == 0 ? "in sync with the trimmed source — lag 0 samples" : "lag \(Fmt.int(lag)) samples (\(String(format: "%+.2f", ms)) ms) against the trimmed source") +
                         " at \(lags.count) point\(lags.count == 1 ? "" : "s") · \(lengthText) " + (ok && lengthOK ? "✓" : "✗"))
        }
        // 2. the level of every channel, 3. the same channel in the same place
        let label = roles.map(\.rawValue)
        var levels: [String] = [], worst = 0.0, levelOK = true
        var minCorr = 1.0, corrOK = true, bad: [String] = []
        for c in 0..<n {
            let silentS = es[c] / Double(srcFrames) < 1e-12, silentO = eo[c] / Double(outFrames) < 1e-12      // below −120 dBFS
            if silentS && silentO { levels.append("\(label[c]) silent"); continue }
            if silentS != silentO { levelOK = false; corrOK = false; levels.append("\(label[c]) " + (silentS ? "silent in the source, not in the file" : "silent in the file")); bad.append(label[c]); continue }
            let db = 10 * log10(eo[c] / es[c])
            worst = max(worst, abs(db))
            if abs(db) > 0.1 { levelOK = false }
            levels.append("\(label[c]) \(String(format: "%+.2f", db))")
            let x = abs(lag) <= 1 ? (lag == 1 ? xp[c] : lag == -1 ? xm[c] : x0[c]) : x0[c]
            let r = x / (es[c] * eo[c]).squareRoot()
            minCorr = min(minCorr, r)
            if r <= 0.9 { corrOK = false; bad.append("\(label[c]) \(String(format: "%.2f", r))") }
        }
        lines.append("\(name): level per channel " + (levelOK ? "within ±0.1 dB of the source" : "differs from the source by up to \(String(format: "%.2f", worst)) dB") +
                     " (\(levels.joined(separator: " · ")) dB) " + (levelOK ? "✓" : "✗"))
        lines.append("\(name): " + (corrOK ? "every channel matches the same channel of the source (correlation ≥ \(String(format: "%.3f", minCorr))) — order unchanged" + (declared ? "" : " (the file declares no layout: compared in order)") + " ✓"
                                           : "channel\(bad.count == 1 ? "" : "s") \(bad.joined(separator: ", ")) don't match the same channel of the source (correlation ≤ 0.9) — channels swapped or changed ✗"))
        return lines
    }
}

// MARK: - Presets and the Transcode tab's model

enum TranscodePreset: String, CaseIterable, Identifiable {
    case prores422HQ, prores422, h264Review, hevcSDR, hevcDolbyVision, custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .prores422HQ: return "ProRes 422 HQ — Academy"
        case .prores422: return "ProRes 422"
        case .h264Review: return "H.264 — review copy"
        case .hevcSDR: return "HEVC SDR"
        case .hevcDolbyVision: return "HEVC Dolby Vision"
        case .custom: return "Custom"
        }
    }
    var detail: String {
        switch self {
        case .prores422HQ: return "What the Academy Screening Room asks for: ProRes 422 HQ in MOV, audio copied bit for bit."
        case .prores422: return "Lighter ProRes for editing and archive copies; MOV, audio copied."
        case .h264Review: return "Small file to send around: H.264 8-bit in MP4, AAC audio, quality High, speed Fast."
        case .hevcSDR: return "HEVC Main 10 in MP4 for playback: the source's own colour, no HDR metadata."
        case .hevcDolbyVision: return "HEVC 10-bit with Dolby Vision 8.1 + HDR10 (+ HDR10+): the same encode the Mux tab makes for playback versions."
        case .custom: return "Your own choice of codec, quality, size, audio and container."
        }
    }
    /// `--to` names on the command line
    static func named(_ s: String) -> TranscodePreset? {
        switch s.lowercased() {
        case "prores422hq", "422hq", "hq": return .prores422HQ
        case "prores422", "422": return .prores422
        case "h264", "avc", "review": return .h264Review
        case "hevc", "h265", "hevcsdr": return .hevcSDR
        case "hevcdv", "dolbyvision", "dv", "hevchdr": return .hevcDolbyVision
        default: return nil
        }
    }
}

/// One file in the Transcode queue
struct TranscodeItem: Identifiable {
    let id = UUID()
    let source: SourceVideo
    var output: URL
    var state: RunState = .idle
    var lines: [String] = []
    var inspection: InspectionData?
    var qc: RenderQC.Report?
    var seconds = 0.0
    var problem: String? = nil             // why the file can't be transcoded as asked (shown instead of the card)
}

@Observable
final class TranscodeModel {
    static let shared = TranscodeModel()

    var items: [TranscodeItem] = []
    var selectedID: UUID?
    var loading = 0
    var notices: [String] = []

    // the destination (one setting for the whole queue)
    var preset: TranscodePreset = .prores422HQ { didSet { if preset != .custom { apply(preset) } } }
    var codec: TargetCodec = .prores { didSet { custom() } }
    var proresProfile: ProResProfile = .hq { didSet { custom() } }
    var quality: HDRSettings.Quality = .high { didSet { custom() } }
    var speed: HDRSettings.Speed = .medium { didSet { custom() } }
    var resolution: OutputResolution = .same
    var audio: AudioPlan = .copy { didSet { custom() } }
    var container: Container = .mov { didSet { custom(); for i in items.indices { items[i].output = items[i].output.deletingPathExtension().appendingPathExtension(container.rawValue) } } }
    var toneMap = false
    var hdrMetadata = false { didSet { custom() } }      // HEVC: HDR10 (+ Dolby Vision / HDR10+ chosen in `hdr`)
    let hdr = HDRSettings()
    var outputFolder: URL?                                // nil = next to each source
    var suffix = "_TRANSCODE"
    var runQC = true
    var runVMAF = false

    // run
    var running = false
    var stage = ""
    var progress = 0.0
    var log = ""
    @ObservationIgnored private var runner: TranscodeRunner?
    @ObservationIgnored private var applying = false

    var selected: TranscodeItem? { items.first { $0.id == selectedID } }
    var busy: Bool { running || loading > 0 }
    var pending: [TranscodeItem] { items.filter { if case .done = $0.state { return false }; return true } }
    var canRun: Bool { !busy && !items.isEmpty && items.contains { plan(for: $0)?.problem == nil } }

    private func custom() { if !applying { preset = .custom } }
    private func apply(_ p: TranscodePreset) {
        applying = true
        switch p {
        case .prores422HQ: codec = .prores; proresProfile = .hq; container = .mov; audio = .copy; hdrMetadata = false; toneMap = false
        case .prores422: codec = .prores; proresProfile = .standard; container = .mov; audio = .copy; hdrMetadata = false; toneMap = false
        case .h264Review: codec = .h264; quality = .high; speed = .fast; container = .mp4; audio = .aac; hdrMetadata = false
        case .hevcSDR: codec = .hevc; quality = .high; speed = .medium; container = .mp4; audio = .copy; hdrMetadata = false; toneMap = false
        case .hevcDolbyVision: codec = .hevc; quality = .maximum; speed = .slow; container = .mp4; audio = .copy; hdrMetadata = true; toneMap = false; hdr.dolbyVision = true
        case .custom: break
        }
        applying = false
    }

    var target: VideoTarget {
        switch codec {
        case .prores: return .prores(proresProfile)
        case .h264: return .h264(quality: quality, speed: speed)
        case .hevc: return .hevc(quality: quality, speed: speed, rate: hdr.rate)
        }
    }

    /// The plan for one file with the current settings
    func plan(for item: TranscodeItem) -> TranscodePlan? {
        var p = TranscodePlan(source: item.source, video: target)
        p.resolution = resolution
        p.audio = audio
        p.container = container
        p.color = toneMap && item.source.isHDR ? .toneMapToSDR : .passthrough
        if codec == .hevc && hdrMetadata && p.color == .passthrough {
            p.hdr = HDRMeta(mastering: hdr.mastering, maxCLL: hdr.maxCLL, maxFALL: hdr.maxFALL,
                            dolbyVision: hdr.dolbyVision ? hdr.dvSource : nil, dvXML: hdr.dolbyVision ? hdr.dvXMLReady : nil,
                            hdr10plus: hdr.hdr10plus ? hdr.hdr10plusJSON : nil)
        }
        p.convertGamut = hdr.convertGamut
        return p
    }
    func problem(for item: TranscodeItem) -> String? {
        guard let p = plan(for: item) else { return "Couldn't read the picture." }
        if let x = p.problem { return x }
        if p.hdr?.dolbyVision != nil, hdr.dvChecking { return "Still reading the Dolby Vision metadata — try again in a moment." }
        if p.hdr?.dolbyVision != nil, let x = hdr.dvProblem { return x }
        if hdrMetadata && codec == .hevc && hdr.dolbyVision && hdr.dvSource == nil { return "Choose the Dolby Vision metadata (XML), or untick Dolby Vision." }
        if let x = hdr.hdr10plusProblem, p.hdr?.hdr10plus != nil { return x }
        return TranscodeRunner.validate(p, output: item.output)
    }

    func defaultOutput(for src: SourceVideo) -> URL {
        let dir = outputFolder ?? src.url.deletingLastPathComponent()
        let base = Fmt.academyName(src.url.deletingPathExtension().lastPathComponent) + suffix
        var u = dir.appendingPathComponent(base).appendingPathExtension(container.rawValue)
        var n = 2
        while FileManager.default.fileExists(atPath: u.path) || items.contains(where: { $0.output == u }) {
            u = dir.appendingPathComponent("\(base)_\(n)").appendingPathExtension(container.rawValue); n += 1
        }
        return u
    }

    func add(_ urls: [URL]) {
        guard !running else { return }
        var files: [URL] = []
        for u in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue {
                let items = (try? FileManager.default.contentsOfDirectory(at: u, includingPropertiesForKeys: nil)) ?? []
                files += items.filter { !$0.lastPathComponent.hasPrefix(".") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            } else { files.append(u) }
        }
        guard !files.isEmpty else { return }
        loading += 1
        DispatchQueue.global(qos: .userInitiated).async {
            for f in files {
                let src = SourceVideo.read(f)
                DispatchQueue.main.async {
                    guard let src else { self.notices.append("“\(f.lastPathComponent)” has no picture that ffmpeg can read."); return }
                    let item = TranscodeItem(source: src, output: self.defaultOutput(for: src))
                    self.items.append(item)
                    if self.selectedID == nil { self.selectedID = item.id; self.hdr.applySourceMastering(src.mi) }
                }
            }
            DispatchQueue.main.async { self.loading -= 1 }
        }
    }

    /// From the File Checker: this file, with this preset, ready in the Transcode tab
    func open(_ url: URL, preset p: TranscodePreset) {
        preset = p
        if !items.contains(where: { Tools.sameFile($0.source.url, url) }) { add([url]) }
        else if let i = items.first(where: { Tools.sameFile($0.source.url, url) }) { selectedID = i.id }
    }

    func remove(_ id: UUID) {
        guard !running else { return }
        items.removeAll { $0.id == id }
        if selectedID == id { selectedID = items.first?.id }
    }
    func clear() {
        guard !running else { return }
        items = []; selectedID = nil; notices = []; log = ""; hdr.reset()
    }
    func select(_ id: UUID?) {
        selectedID = id
        if let s = selected { hdr.applySourceMastering(s.source.mi) }
    }

    func pick() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = true
        p.message = "Choose the files to transcode (a new file is written for each; the originals are never touched)"
        p.prompt = "Add"
        if p.runModal() == .OK { add(p.urls) }
    }
    func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true; p.allowsMultipleSelection = false
        p.prompt = "Choose"; p.message = "Where should the transcoded files go?"
        if p.runModal() == .OK, let u = p.url {
            outputFolder = u
            for i in items.indices { items[i].output = u.appendingPathComponent(items[i].output.lastPathComponent) }
        }
    }

    /// Runs the queue, one file after the other
    func start() {
        guard canRun else { return }
        let todo = items.indices.filter { if case .done = items[$0].state { return false }; return plan(for: items[$0]) != nil }
        guard !todo.isEmpty else { return }
        let existing = todo.compactMap { FileManager.default.fileExists(atPath: items[$0].output.path) ? items[$0].output.lastPathComponent : nil }
        if !existing.isEmpty {
            let a = NSAlert()
            a.messageText = existing.count == 1 ? "“\(existing[0])” already exists" : "\(existing.count) output files already exist"
            a.informativeText = "Replace with the new file? (Only replaced at the very end, if the transcode passes its checks.)"
            a.addButton(withTitle: "Replace"); a.addButton(withTitle: "Cancel")
            if a.runModal() != .alertFirstButtonReturn { return }
        }
        running = true; progress = 0; stage = "Preparing…"; log = ""
        for i in todo { items[i].state = .idle; items[i].lines = []; items[i].inspection = nil; items[i].qc = nil }
        let qc = runQC, vmaf = runVMAF
        DispatchQueue.global(qos: .userInitiated).async {
            for (k, i) in todo.enumerated() {
                var plan: TranscodePlan?, out: URL?, id: UUID?
                DispatchQueue.main.sync { let it = self.items[i]; plan = self.plan(for: it); out = it.output; id = it.id; self.items[i].state = .running }
                guard let plan, let out, let id else { continue }
                let r = TranscodeRunner(plan: plan, output: out, runQC: qc, runVMAF: vmaf)
                DispatchQueue.main.sync { self.runner = r }
                let n = todo.count
                r.onStage = { s, p in DispatchQueue.main.async { self.stage = (n > 1 ? "File \(k + 1) of \(n) · " : "") + s; self.progress = (Double(k) + p) / Double(n) } }
                r.onLog = { l in DispatchQueue.main.async { self.log += l } }
                let res = r.run()
                DispatchQueue.main.sync {
                    guard let j = self.items.firstIndex(where: { $0.id == id }) else { return }
                    self.items[j].lines = res.lines; self.items[j].inspection = res.inspection; self.items[j].qc = res.qc; self.items[j].seconds = res.seconds
                    switch res.state {
                    case .cancelled: self.items[j].state = .cancelled
                    case .failed where res.output == nil: self.items[j].state = .failed
                    default: self.items[j].state = .done(res.output); self.items[j].problem = res.state == .failed ? "a check failed" : nil
                    }
                }
                if r.cancel.isSet { break }
            }
            DispatchQueue.main.async { self.runner = nil; self.running = false; self.stage = "" }
        }
    }
    func cancel() { runner?.requestCancel() }

    /// A plan for the command line
    static func plan(source: SourceVideo, preset: TranscodePreset, resolution: OutputResolution, toneMap: Bool, container: Container?,
                     quality: HDRSettings.Quality?, speed: HDRSettings.Speed?, audio: AudioPlan?, dv: URL?, hdr10plus: URL?, mi: MITrack?,
                     rate: HDRSettings.Rate? = nil) -> TranscodePlan {
        let m = TranscodeModel()
        m.preset = preset
        if let quality { m.quality = quality }
        if let rate { m.hdr.rateMode = rate.mode; m.hdr.bitratePreset = .custom; m.hdr.customMbps = rate.targetMbps; m.hdr.customMaxMbps = rate.maxMbps; m.hdr.qualityFloor = rate.floor }
        if let speed { m.speed = speed }
        if let audio { m.audio = audio }
        if let container { m.container = container }
        m.resolution = resolution
        m.toneMap = toneMap
        m.hdr.applySourceMastering(mi)
        if let dv { m.hdr.dvSource = .xml(dv); m.hdr.dolbyVision = true; m.hdrMetadata = true; m.codec = .hevc; m.hdr.checkDolbyVisionNow(width: source.width, height: source.height, frames: source.frames) }
        if let hdr10plus { m.hdr.hdr10plusJSON = hdr10plus; m.hdr.hdr10plus = true; m.hdr.hdr10plusFrames = HDR10Plus.frames(hdr10plus) ?? -1; m.hdrMetadata = true; m.codec = .hevc }
        if preset == .hevcDolbyVision && dv == nil { m.hdr.dolbyVision = false }   // HDR10 only
        let item = TranscodeItem(source: source, output: source.url)
        return m.plan(for: item)!
    }

    // MARK: command line

    /// `--transcode IN --to prores422hq|prores422|h264|hevc|hevcdv [--res hd|uhd] [--tonemap] [--quality Q] [--speed S]
    ///  [--audio copy|pcm|aac|none] [--mov|--mp4|--mkv] [--dv XML] [--hdr10plus JSON] [--no-qc] [--vmaf] --out OUT`
    static func cli(_ args: [String]) -> Int32 {
        setvbuf(stdout, nil, _IOLBF, 0)
        var input: String?, to = "prores422hq", res = OutputResolution.same, toneMap = false, out: String?, qc = true, vmaf = false
        var quality: HDRSettings.Quality?, speed: HDRSettings.Speed?, audio: AudioPlan?, container: Container?, dv: String?, hdr10plus: String?
        var rateMode: HDRSettings.RateMode?, mbps: Int?, maxMbps: Int?, floor = true
        var i = 0
        func next() -> String? { i += 1; return i < args.count ? args[i] : nil }
        while i < args.count {
            switch args[i] {
            case "--to": to = next() ?? to
            case "--res": res = OutputResolution(rawValue: next() ?? "") ?? .same
            case "--tonemap": toneMap = true
            case "--out", "-o": out = next()
            case "--quality": quality = HDRSettings.Quality(rawValue: next() ?? "")
            case "--speed": speed = HDRSettings.Speed(rawValue: next() ?? "")
            case "--rate": rateMode = HDRSettings.RateMode.named(next() ?? "")
            case "--mbps": mbps = Int(next() ?? "")
            case "--max-mbps": maxMbps = Int(next() ?? "")
            case "--no-floor": floor = false
            case "--audio": audio = AudioPlan(rawValue: next() ?? "")
            case "--mov": container = .mov
            case "--mp4": container = .mp4
            case "--mkv": container = .mkv
            case "--dv": dv = next()
            case "--hdr10plus": hdr10plus = next()
            case "--no-qc": qc = false
            case "--vmaf": vmaf = true
            default: if !args[i].hasPrefix("-") && input == nil { input = args[i] }
            }
            i += 1
        }
        guard let input, let out, let preset = TranscodePreset.named(to) else {
            print("usage: --transcode IN --to prores422hq|prores422|h264|hevc|hevcdv [--res hd|uhd] [--tonemap] [--quality master|maximum|high|compact] [--speed slow|medium|fast|draft] [--rate crf|2pass|cbr --mbps N [--max-mbps N] [--no-floor]] [--audio copy|pcm|aac|none] [--mov|--mp4|--mkv] [--dv XML] [--hdr10plus JSON] [--no-qc] [--vmaf] --out OUT")
            return 2
        }
        let url = URL(fileURLWithPath: input)
        guard let src = SourceVideo.read(url) else { print("ERROR: no picture ffmpeg can read in \(input)"); return 1 }
        let rate = HDRSettings.Rate.fromCLI(mode: rateMode, mbps: mbps, maxMbps: maxMbps, floor: floor)
        var plan = plan(source: src, preset: preset, resolution: res, toneMap: toneMap, container: container, quality: quality, speed: speed, audio: audio,
                        dv: dv.map { URL(fileURLWithPath: $0) }, hdr10plus: hdr10plus.map { URL(fileURLWithPath: $0) }, mi: src.mi, rate: rate)
        let output = URL(fileURLWithPath: out)
        if container == nil, let c = Container(rawValue: output.pathExtension.lowercased()) { plan.container = c }
        print("SOURCE: \(src.url.lastPathComponent) · \(src.summary) · \(src.sizeText) @ \(src.fpsText) fps · \(Fmt.int(src.frames)) frames · colour \(src.color.isTagged ? src.color.text : "untagged")" + (src.timecode.map { " · TC \($0)" } ?? ""))
        print("TARGET: \(plan.outputCodecName) · \(plan.outputBits)-bit \(plan.outputChroma) · \(plan.outputWidth)×\(plan.outputHeight) · colour \(plan.outputColor.text) · \(plan.formats) · audio \(plan.effectiveAudio.label) · \(plan.container.rawValue.uppercased()) · encoder \(plan.encoder)")
        for r in plan.rows where r.changed { print("  → \(r.id): \(r.from) → \(r.to)") }
        for w in plan.warnings { print("  ⚠ \(w)") }
        print("ESTIMATE: ~\(Fmt.bytes(plan.estimatedBytes)) · about \(Fmt.hm(plan.estimatedSeconds)) of encoding")
        if let p = TranscodeRunner.validate(plan, output: output) { print("ERROR: \(p)"); return 1 }
        print("COMMAND: ffmpeg " + Transcode.arguments(plan, concat: nil, output: output, elementary: plan.needsInjection).map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ") + (plan.needsInjection ? "  (then dovi_tool / hdr10plus_tool and MP4Box)" : "") + "\n")
        let r = TranscodeRunner(plan: plan, output: output, runQC: qc, runVMAF: vmaf)
        var lastPrint = Date.distantPast
        r.onStage = { s, p in if Date().timeIntervalSince(lastPrint) > 10 { print(String(format: "  … %@ %3.0f%%", s, max(0, p) * 100)); lastPrint = Date() } }
        r.onLog = { _ in }
        let started = Date()
        let result = r.run()
        print(String(format: "\nRESULT (%.0f s): %@", Date().timeIntervalSince(started), "\(result.state)"))
        result.lines.forEach { print("  •", $0) }
        if let insp = result.inspection {
            if let l = insp.level { print("\nACADEMY SEAL (on the result): \(l.emoji) \(l.title)") }
            if let z = insp.zidooLevel { print("ZIDOO: \(z.emoji) \(z.title)") }
        }
        return result.state == .failed ? 1 : 0
    }
}

// MARK: - Engine self-test (Beta 2.0.0)

/// `--selftest [--clips DIR] [--dv XML] [--out DIR] [--xml2 XML --mov2 MOV] [--skip-jobs]`: exercises the Beta 2.0.0 engine
/// additions on the QC clips — the Dolby Vision analysis, the audio TRANSCODE (prepare → mux → verify), the planned stages
/// against the stages a real run reports, the live findings and the temp-folder lock. Prints what it found; exit 1 when a
/// check fails. Writes only into --out. (Wired into Entry by the integrator.)
enum EngineSelfTest {
    static func run(_ args: [String]) -> Int32 {
        setvbuf(stdout, nil, _IOLBF, 0)
        var clips = "qc/out/clips", dv = "qc/reference/dv-120f.xml", outDir = NSTemporaryDirectory() + "BROS-MUX-selftest"
        var xml2: String?, mov2: String?, jobs = true
        var i = 0
        func next() -> String? { i += 1; return i < args.count ? args[i] : nil }
        while i < args.count {
            switch args[i] {
            case "--clips": clips = next() ?? clips
            case "--dv": dv = next() ?? dv
            case "--out": outDir = next() ?? outDir
            case "--xml2": xml2 = next()
            case "--mov2": mov2 = next()
            case "--skip-jobs": jobs = false
            default: break
            }
            i += 1
        }
        let C = URL(fileURLWithPath: clips), out = URL(fileURLWithPath: outDir, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var failures = 0
        func check(_ ok: Bool, _ what: String) { print("  \(ok ? "PASS" : "FAIL") \(what)"); if !ok { failures += 1 } }

        // (a) metadata analysis
        func analyse(_ xml: URL, picture: URL?, title: String) -> HDRSettings {
            print("\n== Dolby Vision analysis: \(xml.lastPathComponent) + \(picture?.lastPathComponent ?? "no picture") — \(title)")
            let hdr = HDRSettings()
            let src = picture.flatMap { SourceVideo.read($0) }
            hdr.applySourceMastering(src?.mi)
            hdr.dvSource = .xml(xml); hdr.dolbyVision = true; hdr.encode = true
            let t0 = Date()
            hdr.checkDolbyVisionNow(width: src?.width ?? 0, height: src?.height ?? 0, frames: src?.frames ?? 0)
            print(String(format: "  dovi_tool generate + info: %.1f s", Date().timeIntervalSince(t0)))
            if let s = hdr.dvSummary {
                print("  summary: \(s.line)")
                print("  profile=\(s.profile ?? "nil") level5=\(s.level5 ?? "nil") L1 MaxCLL=\(s.l1MaxCLL.map(String.init) ?? "nil") MaxFALL=\(s.l1MaxFALL.map(String.init) ?? "nil") rate=\(s.rate.map { String($0) } ?? "nil") primaries=\(s.primaries ?? "nil") · L6 MaxCLL=\(s.maxCLL.map(String.init) ?? "nil") MaxFALL=\(s.maxFALL.map(String.init) ?? "nil")")
            } else { print("  problem: \(hdr.dvProblem ?? "?")") }
            var lb: MetadataAnalysis.Letterbox?
            if let src {
                let t1 = Date()
                lb = MetadataAnalysis.measureLetterbox(video: src.url, index: src.streamIndex, duration: src.duration, cancel: CancelFlag())
                print(String(format: "  letterbox (cropdetect, %.1f s): ", Date().timeIntervalSince(t1)) + (lb.map { "\($0.width)×\($0.height) top \($0.top) bottom \($0.bottom) left \($0.left) right \($0.right)" } ?? "nil"))
            }
            for c in MetadataAnalysis.dolbyVision(hdr, picture: src, frames: src?.frames ?? 0, fps: src?.fps.value ?? 0, letterbox: lb) { show(c) }
            return hdr
        }
        func show(_ c: MetadataCheck) {
            let mark = c.level == .ok ? "✓" : c.level == .warn ? "⚠" : c.level == .fail ? "✕" : "·"
            print("    \(mark) \(c.title) → \(c.detail)" + (c.fix.map { "  [fix: \($0)]" } ?? ""))
        }
        let dvURL = URL(fileURLWithPath: dv)
        let hevc = C.appendingPathComponent("hevc10_pq2020.mov"), p3 = C.appendingPathComponent("prores4444_p3pq.mov")
        do {
            let h = analyse(dvURL, picture: hevc, title: "BT.2020 picture")
            let lines = MetadataAnalysis.dolbyVision(h, picture: SourceVideo.read(hevc), frames: 120, fps: 24, letterbox: MetadataAnalysis.Letterbox(width: 1920, height: 1080, top: 0, bottom: 0, left: 0, right: 0))
            check(!lines.contains { $0.level == .fail }, "dv-120f.xml + hevc10_pq2020.mov: no ✕")
            check(h.dvSummary?.rate == 24 && h.dvSummary?.primaries == "P3-D65" && h.dvSummary?.profile == "8" && h.dvSummary?.l1MaxCLL != nil && h.dvSummary?.level5 != nil,
                  "summary fields: rate 24, primaries P3-D65, profile 8, L1 and L5 read")
            print("\n  -- the same XML before the picture is known:")
            let waiting = MetadataAnalysis.dolbyVision(h, picture: nil, frames: 0, fps: 0, letterbox: nil)
            waiting.forEach(show)
            check(!waiting.contains { $0.level == .ok && ($0.title.hasPrefix("Frames") || $0.title.hasPrefix("Frame rate") || $0.title.hasPrefix("Level 5") || $0.title.hasPrefix("Master")) }
                  && waiting.filter { $0.detail == MetadataAnalysis.waiting }.count >= 4, "without the picture: frames, rate, Level 5, master say “Waiting for the picture…”, never ✓")
            print("\n  -- the same XML against a picture of 100 frames:")
            let short = MetadataAnalysis.dolbyVision(h, picture: SourceVideo.read(hevc), frames: 100, fps: 25, letterbox: nil)
            short.forEach(show)
            check(short.contains { $0.level == .fail && $0.fix == .copyText("Please send a Dolby Vision XML of 100 frames at 25 fps") }, "frames mismatch: ✕ with “Please send a Dolby Vision XML of 100 frames at 25 fps”")
        }
        do {
            let h = analyse(dvURL, picture: p3, title: "P3-D65 picture")
            let src = SourceVideo.read(p3)
            check(MetadataAnalysis.dolbyVision(h, picture: src, frames: 120, fps: 24, letterbox: nil).contains { $0.level == .ok && $0.fix == .keepSourcePrimaries && $0.detail.hasPrefix("Will be converted to BT.2020") },
                  "P3-D65 master, conversion on: ✓ “Will be converted to BT.2020…” with [Keep source primaries]")
            h.convertGamut = false
            h.rateMode = .average; h.qualityFloor = true
            print("\n  -- conversion off, Average with the quality floor on:")
            let l = MetadataAnalysis.dolbyVision(h, picture: src, frames: 120, fps: 24, letterbox: nil)
            l.forEach(show)
            check(l.contains { $0.level == .warn && $0.fix == .convertGamut }, "conversion off: ⚠ with [Convert to BT.2020]")
            check(l.contains { $0.level == .warn && $0.fix == .qualityFloorOff && $0.detail.contains("274–305 Mbps") }, "quality floor on with Average: ⚠ with [Turn the quality floor off]")
        }
        if let xml2 {
            let h = analyse(URL(fileURLWithPath: xml2), picture: mov2.map { URL(fileURLWithPath: $0) }, title: "the 2DIE4")
            let src = mov2.flatMap { SourceVideo.read(URL(fileURLWithPath: $0)) }
            let lines = MetadataAnalysis.dolbyVision(h, picture: src, frames: src?.frames ?? 0, fps: src?.fps.value ?? 0, letterbox: nil)
            check(lines.contains { $0.level == .warn && $0.fix == .useMeasuredLight }, "2DIE4: L6 MaxCLL/MaxFALL = 0 → ⚠ [Use the values measured from L1]")
            if src != nil { check(lines.contains { $0.level == .ok && $0.fix == .keepSourcePrimaries }, "2DIE4: P3-D65/PQ master → ✓ converted to BT.2020 [Keep source primaries]") }
            h.maxCLL = h.dvSummary?.l1MaxCLL ?? 0; h.maxFALL = h.dvSummary?.l1MaxFALL ?? 0
            print("\n  -- after [Use the values measured from L1]:")
            MetadataAnalysis.dolbyVision(h, picture: src, frames: src?.frames ?? 0, fps: src?.fps.value ?? 0, letterbox: nil).filter { $0.title.contains("L6") || $0.title.contains("light") }.forEach(show)
        }

        // (b) audio TRANSCODE: prepare → JobRunner (bit-exact mux of the result) → verify
        let video = C.appendingPathComponent("h264_709.mov")
        func audioTrack(_ u: URL) -> Track? { Probe.tracks(for: u).tracks.first { $0.kind == .audio } }
        func mux(_ a: URL, name: String, mov: Bool) -> URL? {
            guard let v = Probe.tracks(for: video).tracks.first(where: { $0.kind == .video }), let t = audioTrack(a) else { return nil }
            let o = out.appendingPathComponent(name)
            try? FileManager.default.removeItem(at: o)
            let spec = JobSpec(tracks: [v, t], plans: [:], output: o, disableExtraAudio: false, interleaveMs: 500, writeChannelMap: true,
                               verifyAudio: true, verifyVideo: false, fixColorTag: false, isMOV: mov, reference: nil, pictureCheck: false)
            let r = JobRunner(spec).run()
            print("  mux → \(o.lastPathComponent): \(r.state)"); r.lines.forEach { print("     • \($0)") }
            return r.output
        }
        func transcode(_ t: Track, plan: TrimPlan?, to: AudioDelivery, index: Int, container mov: Bool, wrongPlan: TrimPlan? = nil, wrongSource: Track? = nil) {
            print("\n== Audio \(AudioTranscode.targetText(t, to: to)): “\(t.title)” (\(t.codecName), \(t.isGroup ? "\(t.members.count) mono files" : t.url.lastPathComponent))" + (plan.map { " · cut \($0.cut) pad \($0.pad) keep \($0.keep)" } ?? ""))
            if let p = AudioTranscode.problem(t, to: to) { print("  problem: \(p)") }
            do {
                let t0 = Date()
                var last = -1.0
                let a = try AudioTranscode.prepare(t, plan: plan, to: to, folder: out, index: index, cancel: CancelFlag()) { p in
                    if p < last - 1e-9 { print("  FAIL progress went back \(last) → \(p)"); failures += 1 }
                    last = p
                }
                print(String(format: "  prepare → %@ (%.1f s)", a.lastPathComponent, Date().timeIntervalSince(t0)))
                let probe = Probe.raw(a)?.streams?.first
                print("  file: \(probe?.codec_name ?? "?") · \(probe?.channels ?? 0) ch · \(probe?.channel_layout ?? "?") · \(probe?.sample_rate ?? "?") Hz" + (probe?.bit_rate.map { " · \($0) bps" } ?? ""))
                guard let final = mux(a, name: "selftest-audio\(index).\(mov ? "mov" : "mp4")", mov: mov) else { check(false, "the mux of \(a.lastPathComponent)"); return }
                let t1 = Date()
                let lines = AudioTranscode.verify(final: final, audioOrdinal: 0, source: t, plan: plan, to: to)
                print(String(format: "  verify (%.1f s):", Date().timeIntervalSince(t1)))
                lines.forEach { print("     • \($0)") }
                check(!lines.isEmpty && lines.allSatisfy { $0.hasSuffix("✓") }, "verify: lag, level and channels ✓")
                if let w = wrongPlan {
                    let bad = AudioTranscode.verify(final: final, audioOrdinal: 0, source: t, plan: w, to: to)
                    print("  verify against a source trimmed \(w.cut - (plan?.cut ?? 0)) samples differently (must fail):")
                    bad.forEach { print("     • \($0)") }
                    check(bad.contains { $0.hasSuffix("✗") }, "verify catches a wrong trim")
                }
                if let w = wrongSource {
                    let bad = AudioTranscode.verify(final: final, audioOrdinal: 0, source: w, plan: plan, to: to)
                    print("  verify against a source whose C and LFE are swapped (must fail):")
                    bad.forEach { print("     • \($0)") }
                    check(bad.contains { $0.hasSuffix("✗") && $0.contains("swapped") }, "verify catches swapped channels")
                }
            } catch { print("  prepare threw: \(error.localizedDescription)"); check(false, "prepare") }
        }
        let monos = ["L", "R", "C", "LFE", "Ls", "Rs"].compactMap { audioTrack(C.appendingPathComponent("tone.\($0).wav")) }
        if monos.count == 6, var g = Track.group(monos) {
            g.title = "PCM 5.1 (6 mono files)"
            print("\n  group roles: \(g.sourceOrder?.text ?? "nil") (\(g.rolesSource ?? "")) · written \(AudioTranscode.writtenRoles(g).map { ChannelOrder(roles: $0).text } ?? "nil")")
            let total = g.groupTotal
            var swapped = g
            swapped.channelRoles = [.L, .R, .LFE, .C, .Ls, .Rs]       // mislabelled: the C file called LFE and the other way round
            transcode(g, plan: TrimPlan(pad: 0, cut: 4800, keep: total - 4800, total: total), to: .aac, index: 1, container: false,
                      wrongPlan: TrimPlan(pad: 0, cut: 5280, keep: total - 5280, total: total), wrongSource: swapped)
            // Film order written (L C R Ls Rs LFE): the samples are permuted like JobRunner does, then each channel keeps its role
            var film = g
            film.channelTarget = ChannelOrder(roles: [.L, .C, .R, .Ls, .Rs, .LFE])
            print("\n  film-order group: permutation \(film.channelPermutation.map { "\($0)" } ?? "nil")")
            transcode(film, plan: nil, to: .aac, index: 2, container: true)
            check(AudioTranscode.problem(g, to: .pcm24) != nil, "PCM 24-bit of a 24-bit group is refused (COPY is the same samples): \(AudioTranscode.problem(g, to: .pcm24) ?? "")")
        } else { check(false, "the six mono tone files make a group") }
        if let guide = audioTrack(C.appendingPathComponent("guide.wav")) {
            let total = guide.totalSamples
            transcode(guide, plan: TrimPlan(pad: 0, cut: 4800, keep: total - 4800, total: total), to: .aac, index: 3, container: false)
        }
        // a float source: PCM 24-bit when it fits, refused when it peaks above 0 dBFS
        let f32 = out.appendingPathComponent("guide_f32.wav"), hot = out.appendingPathComponent("guide_hot_f32.wav")
        _ = Tools.runAll(Tools.ffmpeg ?? "ffmpeg", ["-nostdin", "-v", "error", "-y", "-i", C.appendingPathComponent("guide.wav").path, "-c:a", "pcm_f32le", f32.path])
        _ = Tools.runAll(Tools.ffmpeg ?? "ffmpeg", ["-nostdin", "-v", "error", "-y", "-i", C.appendingPathComponent("guide.wav").path, "-af", "volume=12dB", "-c:a", "pcm_f32le", hot.path])
        if let t = audioTrack(f32) {
            let total = t.totalSamples
            transcode(t, plan: TrimPlan(pad: 2400, cut: 0, keep: total, total: total), to: .pcm24, index: 4, container: true)
        }
        if let t = audioTrack(hot) {
            print("\n== Audio PCM 24-bit of a float source peaking above 0 dBFS")
            print("  peak: \(AudioTranscode.measureFloatPeak(t, cancel: CancelFlag()).map { String(format: "%+.2f dBFS", $0) } ?? "?")")
            let p = AudioTranscode.problem(t, to: .pcm24)
            print("  problem: \(p ?? "nil")")
            check(p != nil, "a float source above 0 dBFS is refused for PCM 24-bit")
            check(AudioTranscode.problem(t, to: .aac) == nil, "… and still allowed for AAC")
        }

        // (c) planned stages against what a real run reports
        func stages(_ label: String, _ a: [String]) {
            print("\n== Planned stages: \(label)")
            let project = buildProject(CLIArgs(a), output: CLIArgs(a).output)
            guard let spec = project.jobSpec else { check(false, "\(label): a job"); return }
            let planned = JobRunner.plannedStages(spec)
            print("  planned: " + planned.map { String(format: "%@ %.1f s", $0.stage.rawValue, $0.weight) }.joined(separator: " → "))
            guard jobs else { return }
            let r = JobRunner(spec)
            let lock = NSLock()
            var seen: [JobProgress.Stage] = [], frac: [JobProgress.Stage: Double] = [:], back = 0, findings: [String] = [], folder: URL?, lockOK = false
            var encode: JobProgress?
            r.onProgress = { p in
                lock.lock(); defer { lock.unlock() }
                if seen.last != p.stage { seen.append(p.stage); frac[p.stage] = 0 }
                if p.fraction + 1e-9 < (frac[p.stage] ?? 0) { back += 1 }
                frac[p.stage] = p.fraction
                if [.encode, .pass2].contains(p.stage), (p.frame ?? 0) > 0 { encode = p }
            }
            r.onFinding = { l in lock.lock(); findings.append(l); lock.unlock() }
            r.onWorkFolder = { u in
                folder = u
                lockOK = JobRunner.TempLock.liveOwner(of: u) == getpid()
                JobRunner.removeStaleTemps(in: u.deletingLastPathComponent())          // must leave our running folder alone
                lockOK = lockOK && FileManager.default.fileExists(atPath: u.path)
            }
            let res = r.run()
            print("  ran:     " + seen.map(\.rawValue).joined(separator: " → ") + " · \(res.state)")
            check(seen == planned.map(\.stage), "\(label): the stages reported are the planned ones")
            check(back == 0, "\(label): no fraction went back inside a stage (\(back))")
            check(findings.sorted() == res.lines.sorted(), "\(label): onFinding gave every result line, as it came (\(findings.count)/\(res.lines.count))")
            check(folder != nil && lockOK, "\(label): onWorkFolder came, its .lock names this process and removeStaleTemps kept it")
            check(folder.map { !FileManager.default.fileExists(atPath: $0.path) } ?? false, "\(label): the temporary folder is gone after the run")
            if let e = encode {
                print("  encode progress: frame \(e.frame ?? 0)/\(e.totalFrames ?? 0) · fps \(e.fps.map { String($0) } ?? "nil") · \(e.bitrateKbps.map { "\($0) Kbps" } ?? "bitrate nil") · speed \(e.speed.map { String($0) } ?? "nil") · \(e.outBytes.map { "\($0) bytes" } ?? "nil") · “\(e.title)”")
            }
        }
        let o = out.path
        stages("stereo guide (MOV)", ["--video", C.appendingPathComponent("h264_709.mov").path, "--add", C.appendingPathComponent("guide.wav").path, "--no-picture-check", "-o", o + "/st-stereo.mov"])
        stages("6 monos → 5.1, picture check (MP4)", ["--video", C.appendingPathComponent("h264_709.mov").path] + ["L", "R", "C", "LFE", "Ls", "Rs"].flatMap { ["--add", C.appendingPathComponent("tone.\($0).wav").path] } + ["--mp4", "-o", o + "/st-group.mp4"])
        stages("guide 100 ms late, trimmed (MKV)", ["--video", C.appendingPathComponent("h264_709.mov").path, "--add", C.appendingPathComponent("guide_late100ms.wav").path, "--trim-ms", "100", "--no-picture-check", "--mkv", "-o", o + "/st-trim.mkv"])
        stages("HDR10 2-pass + Dolby Vision (MP4)", ["--video", hevc.path, "--encode", "--dv", dvURL.path, "--speed", "fast", "--rate", "2pass", "--mbps", "20", "--no-picture-check", "-o", o + "/st-dv.mp4"])

        // TranscodeRunner
        func transcodeStages(_ label: String, source: URL, preset: TranscodePreset, container: Container, dv: URL?, name: String) {
            print("\n== Planned stages: Transcode \(label)")
            guard let src = SourceVideo.read(source) else { check(false, "\(label): the source"); return }
            let plan = TranscodeModel.plan(source: src, preset: preset, resolution: .same, toneMap: false, container: container, quality: nil, speed: nil,
                                           audio: nil, dv: dv, hdr10plus: nil, mi: src.mi)
            let planned = TranscodeRunner.plannedStages(plan, runQC: true, runVMAF: false)
            print("  planned: " + planned.map { String(format: "%@ %.1f s", $0.stage.rawValue, $0.weight) }.joined(separator: " → "))
            guard jobs else { return }
            let o = out.appendingPathComponent(name)
            let tr = TranscodeRunner(plan: plan, output: o, runQC: true, runVMAF: false)
            var seen: [JobProgress.Stage] = [], findings: [String] = [], folders = 0
            let lock = NSLock()
            tr.onProgress = { p in lock.lock(); if seen.last != p.stage { seen.append(p.stage) }; lock.unlock() }
            tr.onFinding = { l in lock.lock(); findings.append(l); lock.unlock() }
            tr.onWorkFolder = { _ in lock.lock(); folders += 1; lock.unlock() }
            try? FileManager.default.removeItem(at: o)
            let res = tr.run()
            print("  ran:     " + seen.map(\.rawValue).joined(separator: " → ") + " · \(res.state) · work folders \(folders)")
            check(seen == planned.map(\.stage), "transcode \(label): the stages reported are the planned ones")
            check(findings.sorted() == res.lines.sorted(), "transcode \(label): onFinding gave every result line, as it came (\(findings.count)/\(res.lines.count))")
        }
        transcodeStages("H.264 → ProRes 422 HQ, Render QC", source: video, preset: .prores422HQ, container: .mov, dv: nil, name: "st-transcode.mov")
        transcodeStages("HEVC PQ → HEVC Dolby Vision (the inner JobRunner), Render QC", source: hevc, preset: .hevcDolbyVision, container: .mp4, dv: dvURL, name: "st-transcode-dv.mp4")

        // the lock: a stale folder of a dead process goes, a folder of a live one stays
        print("\n== Temporary folders")
        let fm = FileManager.default
        let live = out.appendingPathComponent(".BROS-MUX-tmp-selftest-live"), dead = out.appendingPathComponent(".BROS-MUX-tmp-selftest-dead")
        for (u, pid) in [(live, getpid()), (dead, Int32(99_999))] {
            try? fm.removeItem(at: u); try? fm.createDirectory(at: u, withIntermediateDirectories: true)
            try? "\(pid)\n".write(to: u.appendingPathComponent(".lock"), atomically: false, encoding: .utf8)
            try? fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -48 * 3600)], ofItemAtPath: u.path)
        }
        let deadAlive = kill(99_999, 0) == 0
        JobRunner.removeStaleTemps(in: out)
        check(fm.fileExists(atPath: live.path), "a 2-day-old folder whose .lock names a running process is kept")
        if !deadAlive { check(!fm.fileExists(atPath: dead.path), "a 2-day-old folder whose .lock names a finished process is removed") }
        try? fm.removeItem(at: live)

        print("\nSELFTEST: \(failures == 0 ? "PASSED" : "\(failures) FAILED")")
        return failures == 0 ? 0 : 1
    }
}
