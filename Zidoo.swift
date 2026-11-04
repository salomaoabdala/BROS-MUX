// BROS-MUX — will this file play on the Zidoo Z9X PRO (the Realtek 4K media player in the screening room)?
//
// The screening room has a Zidoo Z9X PRO 4K (Realtek RTD1619BPD) — confirmed by the user on 2026-11-04.
// Every rule below says where it comes from. Three kinds of source, never mixed up:
//   (Zidoo spec)  written by Zidoo (checked 2026-11-04):
//            • Official Z9X PRO spec page https://www.zidoo.tv/Product/spec/model/Z9X+PRO/ : "Realtek RTD1619BPD ARM Quad-A55",
//              "4K@60p HEVC/H.265 12Bit HDR10, HDR10+, Dolby vision", "Support truehd audio pass-through and LPCM 2.0 channel",
//              "HDMI 2.1, support up to 4K @ 60p, HDR, 12Bit, YCbCr 4:4:4 color space, support audio pass-through".
//              It names NO other video codec: no H.264, VP9, AV1 or ProRes.
//            • Zidoo support guide (official): "Video formats can all be played, such as BD/UHD BDMV/ISO, MVC 3D (Blu-ray, MKV), MKV,
//              M2TS, MTS, TS, MP4, MOV, AVI, WMV, MPG, MPEG, VOB, FLV, 3GP, TP etc."
//              https://www.zidoo.tv/Support/support_guide/guide_target/zYGfACCO6[ld]jeq7k9e[ld]3ulg==.html
//   (owners' reports / retailers)  not written by Zidoo: Dolby Vision profile 7 FEL, multichannel LPCM over HDMI, AV1, HLG.
//   (tested by the owner)  H.264 plays on the screening-room Z9X PRO — the user confirmed it on 2026-11-04 from his own use
//            ("H264 eu tenho sem dúvida certeza que ele funciona"). Zidoo's spec page simply doesn't list it.
//   (our guess / inference)  said as such in the text the user reads.
// Web check 2026-11-04 for the rest: AV1 — the AVSForum RTD1619BPD owners' thread and retailers say this chip added AV1, Zidoo's
// spec page doesn't; VP9 — on the older Z9X spec and the RTD1619 family, not on the Z9X PRO page; ProRes — no source at all.
// Nothing here has been tested on the screening-room Zidoo itself; the seal says so.
// ProRes, DNxHD/HR, JPEG 2000 and CineForm appear in NO Zidoo spec or guide, nor any Blu-ray format: expect them not to play.
// (The older Z9X, a different chip — RTD1619DR — was specced "H.264 up to 4K @ 24fps"; not used here.)

import SwiftUI

enum ZidooLevel {
    case plays, likely, noPlay
    var emoji: String { switch self { case .plays: return "🟢"; case .likely: return "🟡"; case .noPlay: return "🔴" } }
    var title: String { switch self { case .plays: return "PLAYS ON THE ZIDOO"; case .likely: return "SHOULD PLAY ON THE ZIDOO"; case .noPlay: return "NOT SUPPORTED ON THE ZIDOO" } }
    var color: Color { switch self { case .plays: return .green; case .likely: return Color(red: 0.86, green: 0.62, blue: 0.0); case .noPlay: return .red } }
    var explanation: String {
        switch self {
        case .plays: return "Container, video and audio are all confirmed for the Z9X PRO (Zidoo's specs or your own use)."
        case .likely: return "Nothing blocks it, but at least one item isn't confirmed by Zidoo for the Z9X PRO — see the checks."
        case .noPlay: return "At least one stream uses a codec that no Zidoo spec covers — expect it not to play. See the checks."
        }
    }
}

enum Zidoo {
    static let caveat = "Zidoo Z9X PRO · Zidoo's published specs + H.264 confirmed by you; this file itself wasn't played on it."

    static func checks(_ tracks: [MITrack]) -> [Check] {
        var c: [Check] = []
        let general = tracks.first { $0.type == "General" }
        let videos = tracks.filter { $0.type == "Video" }
        let audios = tracks.filter { $0.type == "Audio" }

        // Container
        let fmt = general?["Format"] ?? ""
        let isMOV = general?["Format_Profile"] == "QuickTime"
        let containers: [String: String] = ["MPEG-4": isMOV ? "MOV" : "MP4", "Matroska": "MKV", "MPEG-TS": "TS", "BDAV": "M2TS", "AVI": "AVI",
                                            "Windows Media": "WMV", "MPEG-PS": "MPG/VOB", "Flash Video": "FLV"]
        if let name = containers[fmt] {
            c.append(Check(level: .ok, title: "Container", detail: "\(name) — in Zidoo's list of playable formats (Zidoo spec)"))
        } else if !fmt.isEmpty {
            c.append(Check(level: .warn, title: "Container", detail: "\(fmt) — not in Zidoo's list (MKV, MP4, MOV, M2TS, TS, AVI…) (Zidoo spec)"))
        }

        // Video
        for (i, v) in videos.enumerated() {
            let n = videos.count > 1 ? "Video \(i + 1)" : "Video"
            let f = v["Format"] ?? ""
            let w = Int(v["Width"] ?? "") ?? 0
            let fps = v.d("FrameRate") ?? 0
            let fpsText = fps > 0 ? String(format: "%.3g fps", fps) : "? fps"
            let depth = v["BitDepth"] ?? "?"
            switch f {
            case "HEVC":
                let hchroma = v["ChromaSubsampling"] ?? "4:2:0"
                if hchroma != "4:2:0" {
                    c.append(Check(level: .warn, title: n, detail: "HEVC \(depth)-bit \(hchroma) — the spec says 12-bit but not which chroma; consumer HEVC is 4:2:0 (our guess: \(hchroma) may not play)"))
                } else if w > 4096 || fps > 60.5 {
                    c.append(Check(level: .warn, title: n, detail: "HEVC \(w) px · \(fpsText) — above the 4K@60p HEVC in Zidoo's spec (Zidoo spec)"))
                } else {
                    c.append(Check(level: .ok, title: n, detail: "HEVC \(depth)-bit · \(fpsText) — Zidoo decodes HEVC 4K@60p up to 12-bit (Zidoo spec)"))
                }
            case "AVC":
                let prof = v["Format_Profile"] ?? ""
                let chroma = v["ChromaSubsampling"] ?? "4:2:0"
                if prof.contains("10") || prof.contains("4:2:2") || prof.contains("4:4:4") || depth != "8" || chroma != "4:2:0" {
                    c.append(Check(level: .warn, title: n, detail: "H.264 \(prof) \(depth)-bit \(chroma) — H.264 plays on your Z9X PRO in its usual 8-bit 4:2:0 form; this variant isn't confirmed (our guess: often doesn't play on Realtek players)"))
                } else if fps > 60.5 {
                    c.append(Check(level: .warn, title: n, detail: "H.264 at \(fpsText) — H.264 plays on your Z9X PRO, but the player outputs up to 60p (Zidoo spec)"))
                } else {
                    c.append(Check(level: .ok, title: n, detail: "H.264 \(w) px · \(fpsText) — plays on the screening-room Z9X PRO (confirmed by you; Zidoo's spec page doesn't list H.264)"))
                }
            case "VP9":
                c.append(Check(level: .warn, title: n, detail: "VP9 — on the older Z9X spec and the Realtek RTD1619 family, not on the Z9X PRO spec page: probably plays, not confirmed"))
            case "AV1":
                c.append(Check(level: .warn, title: n, detail: "AV1 — owners (AVSForum) and retailers say the Z9X PRO's chip added AV1; Zidoo's spec page doesn't say it: probably plays, not confirmed"))
            case "MPEG Video", "VC-1":
                c.append(Check(level: .warn, title: n, detail: "\(f) — not in the Z9X PRO spec; it is a Blu-ray/DVD codec and Zidoo plays those discs (our inference)"))
            case "ProRes":
                c.append(Check(level: .fail, title: n, detail: "Apple ProRes \(v["Format_Profile"] ?? "") — no Zidoo spec, guide or owner report says ProRes plays. Make an HEVC or H.264 version for the Zidoo."))
            case "JPEG 2000", "VC-3", "CineForm", "DNxHR", "DNxHD":
                c.append(Check(level: .fail, title: n, detail: "\(f) — a mastering codec, not in any Zidoo spec. Make an HEVC version for the Zidoo."))
            default:
                c.append(Check(level: .fail, title: n, detail: "\(f.isEmpty ? "Unknown codec" : f) — not in any Zidoo spec (the Z9X PRO spec lists HEVC)"))
            }

            // HDR
            let hdr = v["HDR_Format"] ?? ""
            let transfer = v["transfer_characteristics"] ?? ""
            if hdr.contains("Dolby Vision") {
                let raw = (v["HDR_Format_Profile"] ?? "").split(separator: "/").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
                let prof = raw.hasPrefix("dvhe.") || raw.hasPrefix("dvav.") ? "Profile \(Int(raw.dropFirst(5).prefix(2)) ?? 0) (\(raw))" : (raw.isEmpty ? hdr : raw)
                if raw.hasPrefix("dvhe.07") {
                    c.append(Check(level: .warn, title: "\(n) · Dolby Vision", detail: "Profile 7 (dual layer) — owners report MEL plays in DV, FEL sometimes only as HDR10 depending on model/firmware (owners' reports, not Zidoo)"))
                } else {
                    c.append(Check(level: .ok, title: "\(n) · Dolby Vision", detail: "\(prof) — Dolby Vision is in Zidoo's spec (Zidoo spec)"))
                }
            }
            if hdr.contains("2094") { c.append(Check(level: .ok, title: "\(n) · HDR10+", detail: "In Zidoo's spec (Zidoo spec)")) }
            else if transfer == "PQ" && !hdr.contains("Dolby Vision") { c.append(Check(level: .ok, title: "\(n) · HDR10", detail: "In Zidoo's spec (Zidoo spec)")) }
            if transfer == "HLG" { c.append(Check(level: .warn, title: "\(n) · HLG", detail: "Retailers list HLG; Zidoo's spec page only says HDR10, HDR10+ and Dolby Vision")) }
        }

        // Audio
        for (i, a) in audios.enumerated() {
            let n = "Audio \(i + 1)"
            let f = a["Format"] ?? ""
            let ch = Int(a["Channels"] ?? "") ?? 0
            let name = a["Format_Commercial_IfAny"] ?? f
            if Academy.isTrueHD(a) {
                c.append(Check(level: .ok, title: n, detail: "\(name) · \(ch) ch — \"truehd audio pass-through\" to the receiver over HDMI (Zidoo spec). Without a receiver the Zidoo itself decodes only 2 channels."))
            } else if ["E-AC-3", "AC-3", "DTS"].contains(f) {
                c.append(Check(level: .ok, title: n, detail: "\(name) · \(ch) ch — HDMI \"audio pass-through\" to the receiver (Zidoo spec). Without a receiver the Zidoo itself decodes only 2 channels."))
            } else if f == "PCM" {
                if ch <= 2 {
                    c.append(Check(level: .ok, title: n, detail: "PCM \(ch) ch — \"LPCM 2.0 channel\" is in the Z9X PRO spec (Zidoo spec)"))
                } else {
                    c.append(Check(level: .warn, title: n, detail: "PCM \(ch) ch — the Z9X PRO spec only states \"LPCM 2.0 channel\"; multichannel LPCM over HDMI is reported by owners, not written by Zidoo"))
                }
            } else if f == "AAC" || f == "FLAC" {
                c.append(Check(level: .warn, title: n, detail: "\(name) · \(ch) ch — common, but not named in the Zidoo specs we found (our guess: plays)"))
            } else {
                c.append(Check(level: .warn, title: n, detail: "\(name) — not named in the Zidoo specs we found"))
            }
        }
        if videos.isEmpty && audios.isEmpty { c.append(Check(level: .fail, title: "Streams", detail: "No video or audio found")) }
        return c
    }

    static func level(_ checks: [Check]) -> ZidooLevel {
        if checks.contains(where: { $0.level == .fail }) { return .noPlay }
        if checks.contains(where: { $0.level == .warn }) { return .likely }
        return .plays
    }
}

/// The Zidoo seal, drawn like the Academy seal so the two sit side by side
struct ZidooSeal: View {
    let level: ZidooLevel?
    let caption: String
    var compact = false

    var body: some View {
        let color = level?.color ?? Color.secondary
        let d: CGFloat = compact ? 48 : 64
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(color.opacity(0.12))
                Circle().strokeBorder(color, lineWidth: 2)
                Image(systemName: "play.rectangle.fill").font(.system(size: d * 0.36)).foregroundStyle(color)
            }
            .frame(width: d, height: d)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(level?.title ?? "Zidoo: —")
                    .font(compact ? .headline : .title3.weight(.semibold)).foregroundStyle(color)
                Text(level?.explanation ?? "Add a video and audio to evaluate.")
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(caption).font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A list of checks with the same look as the Academy list in the File Checker
struct ChecksSection: View {
    let title: String
    let checks: [Check]
    var footer: String? = nil

    var body: some View {
        let fails = checks.filter { $0.level == .fail }.count
        let warns = checks.filter { $0.level == .warn }.count
        Section {
            ForEach(checks) { c in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: c.level.icon).foregroundStyle(c.level.color).frame(width: 16)
                    Text(c.title).fontWeight(.medium).frame(width: 230, alignment: .leading)
                    Text(c.detail).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            HStack {
                Text(title)
                Spacer()
                Text(fails > 0 ? "\(fails) blocking\(warns > 0 ? " · \(warns) not confirmed" : "")" : warns > 0 ? "\(warns) not confirmed" : "Everything in the specs")
                    .foregroundStyle(fails > 0 ? Color.red : warns > 0 ? Color.orange : Color.green)
            }
        } footer: {
            if let footer { Text(footer) }
        }
    }
}
