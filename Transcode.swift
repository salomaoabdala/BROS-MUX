// BROS-MUX — Transcode: the ONE place where the picture is re-encoded. Everywhere else the files go in and out bit for bit.
// The engine here (TranscodePlan → ffmpeg arguments → TranscodeRunner) is used by the Transcode tab for ProRes, H.264 and
// HEVC, and by the Mux tab for its single exception: the HEVC 10-bit encode that Dolby Vision / HDR10+ playback versions
// need. The colour of the source (primaries, transfer, matrix, range) is read from the file and repeated in the output —
// nothing is tagged BT.2020/PQ by default any more — unless a tone mapping to SDR is asked for.

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import CryptoKit

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
                             stage: @escaping (String, Double) -> Void, log: @escaping (String) -> Void) throws -> URL? {
        guard let r = p.video.rate, r.mode == .average, p.encoder == "libx265" else { return nil }
        let stats = tmp.appendingPathComponent("x265.stats")
        let args = arguments(p, concat: concat, output: stats, elementary: true, pass: 1, stats: stats)
        let res = encode(args, frames: p.frames, label: "Pass 1 of 2: measuring the picture (x265, average \(r.targetMbps) Mbps)", cancel: cancel, stage: stage, log: log)
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
    static func encode(_ args: [String], frames: Int, label: String, cancel: CancelFlag,
                       stage: @escaping (String, Double) -> Void, log: @escaping (String) -> Void) -> (status: Int32, done: Int) {
        guard let ffmpeg = Tools.ffmpeg else { return (-1, 0) }
        log("ffmpeg " + args.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ") + "\n")
        let started = Date()
        var done = 0
        stage(label + "…", 0)
        let status = Tools.runStreaming(ffmpeg, args, cancel: cancel, line: { l in
            guard let f = frame(of: l) else { return }
            done = f
            let elapsed = Date().timeIntervalSince(started)
            let fps = elapsed > 0 ? Double(f) / elapsed : 0
            let left = fps > 0 ? Double(frames - f) / fps : 0
            stage("\(label): frame \(Fmt.int(f)) of \(Fmt.int(frames)) · \(String(format: "%.1f", fps)) fps · \(Fmt.hm(left)) left", Double(f) / Double(max(frames, 1)))
        }, log: log)
        return (status, done)
    }

    /// The Mux path: the picture as an elementary HEVC stream with the Dolby Vision / HDR10+ metadata injected.
    /// Returns the final stream (in `tmp`), the RPU that went in, and notes.
    static func encodeElementary(_ p: TranscodePlan, tmp: URL, cancel: CancelFlag,
                                 stage: @escaping (String, Double) -> Void, log: @escaping (String) -> Void) throws -> (hevc: URL, rpu: URL?, notes: [String]) {
        let fm = FileManager.default
        var notes: [String] = []
        // 1. Dolby Vision metadata → RPU (checked against the frame count before hours of encoding)
        var rpu: URL?
        if let src = p.hdr?.dolbyVision {
            stage("Reading the Dolby Vision metadata…", 0)
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
        let stats = try twoPassStats(p, concat: concat, tmp: tmp, cancel: cancel, stage: stage, log: log)
        let args = arguments(p, concat: concat, output: base, elementary: true, pass: stats == nil ? 0 : 2, stats: stats)
        let label = stats == nil ? "Encoding the picture (x265 \(s.preset), \(rate.text(q)))" : "Pass 2 of 2: encoding the picture (x265 \(s.preset), \(rate.text(q)))"
        let r = encode(args, frames: p.frames, label: label, cancel: cancel, stage: stage, log: log)
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
    private var inner: JobRunner?

    init(plan: TranscodePlan, output: URL, runQC: Bool, runVMAF: Bool) {
        self.plan = plan; self.output = output; self.runQC = runQC; self.runVMAF = runVMAF
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
        defer { try? fm.removeItem(at: tmp) }
        let cancelled = TranscodeResult(state: .cancelled, lines: ["Cancelled — nothing was written to the destination."], output: nil)
        var lines: [String] = []
        var ok = true, warn = false
        let tmpOut: URL

        if plan.needsInjection {
            // Dolby Vision / HDR10+: the Mux engine does it (elementary HEVC + injection + MP4Box + bit-exact audio)
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
            let spec = JobSpec(tracks: inc, plans: plans, output: output, disableExtraAudio: false, interleaveMs: 500, writeChannelMap: true,
                               verifyAudio: true, verifyVideo: false, fixColorTag: false, isMOV: plan.container == .mov, reference: nil,
                               isMKV: plan.container == .mkv, referenceOffset: 0, videoEncode: plan, pictureCheck: false)
            let job = JobRunner(spec)
            inner = job
            job.onStage = onStage; job.onLog = onLog
            let res = job.run()
            if res.state == .cancelled || cancel.isSet { return cancelled }
            guard let out = res.output else { return TranscodeResult(state: .failed, lines: res.lines, output: nil) }
            lines = res.lines
            ok = res.state != .failed
            warn = res.state == .warning
            tmpOut = out                      // already in place; the checks below run on the final file
        } else {
            let ext = plan.container.rawValue
            let t = tmp.appendingPathComponent("output.\(ext)")
            let stats: URL?
            do { stats = try Transcode.twoPassStats(plan, concat: nil, tmp: tmp, cancel: cancel, stage: onStage, log: onLog) }
            catch is Cancelled { return cancelled }
            catch { return TranscodeResult(state: .failed, lines: [error.localizedDescription], output: nil) }
            let args = Transcode.arguments(plan, concat: nil, output: t, elementary: false, pass: stats == nil ? 0 : 2, stats: stats)
            let what: String
            switch plan.video {
            case .prores(let p): what = "Encoding \(p.label) (\(plan.encoder == "prores_videotoolbox" ? "Apple VideoToolbox" : "ffmpeg prores_ks"))"
            case .h264(let q, let s): what = "Encoding H.264 (\(plan.usesVideoToolbox ? "VideoToolbox" : "x264 \(s.preset)"), quality \(q.label.lowercased()))"
            case .hevc(let q, let s, let r): what = (stats == nil ? "Encoding HEVC" : "Pass 2 of 2: encoding HEVC") + " (\(plan.usesVideoToolbox ? "VideoToolbox" : "x265 \(s.preset)"), \(r.text(q)))"
            }
            let r = Transcode.encode(args, frames: plan.frames, label: what, cancel: cancel, stage: onStage, log: onLog)
            if cancel.isSet { return cancelled }
            guard r.status == 0, fm.fileExists(atPath: t.path) else {
                return TranscodeResult(state: .failed, lines: ["The encode failed (ffmpeg error \(r.status)). See the log."], output: nil)
            }
            lines.append("Picture: RE-ENCODED (\(plan.source.codecName) → \(plan.outputCodecName)) · \(plan.encoder) · \(Fmt.int(r.done)) frames in \(Fmt.hm(Date().timeIntervalSince(started)))")
            tmpOut = t
        }

        // checks on the picture written
        onStage("Checking the result (frames, duration, colour, timecode)…", 0.9)
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
            let rep = RenderQC.run(url: tmpOut, cancel: cancel) { s, p in self.onStage("Render QC on the result: " + s, 0.9 + p * 0.08) }
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
