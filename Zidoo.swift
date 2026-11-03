// BROS-MUX — will this file play on the Zidoo (the Realtek 4K media player in the screening room)?
//
// Every rule below says where it comes from. Three kinds of source, never mixed up:
//   [SPEC]   written by Zidoo or in a Zidoo spec sheet (checked 2026-11-03):
//            • Zidoo support guide (official): "Video formats can all be played, such as BD/UHD BDMV/ISO, MVC 3D, MKV, M2TS, MTS,
//              TS, MP4, MOV, AVI, WMV, MPG, MPEG, VOB, FLV, 3GP, TP etc." and "HEVC/H.265/10bit/12Bit, HDR10+, HDR10 and Dolby Vision"
//              https://www.zidoo.tv/Support/support_guide/guide_target/zYGfACCO6[ld]jeq7k9e[ld]3ulg==.html
//            • Z9X PRO spec sheet (Realtek RTD1619BPD, dealer PDF stassen.nl, Feb 2024): "Video Decode 4K@60p HEVC/H.265 12 Bit HDR10,
//              HDR10+, Dolby vision", "Audio Decode Support HD audio passthrough and decode 2 channels",
//              "truehd audio pass-through and LPCM 2.0 channel". HLG is listed in the HDMI output line of the same family's listings.
//            • Z9X / Z10 PRO launch spec (Realtek RTD1619DR, CNX Software 2020-08-13): "10-bit HEVC/H.265 up to 4K @ 60fps,
//              VP9 up to 4K @ 60fps, H.264 up to 4K @ 24fps".
//   [USERS]  reported by owners on forums, not written by Zidoo (Dolby Vision profile 7 FEL behaviour, multichannel LPCM out).
//   [GUESS]  our own inference — said as such in the text the user reads.
// Nothing here has been tested on the screening-room Zidoo itself; the seal says so.
// ProRes, DNxHD/HR, JPEG 2000 and CineForm appear in NO Zidoo spec or guide: the decoders Zidoo lists are HEVC, H.264, VP9
// (and AV1 on one retailer page only). Realtek media SoCs are built around those consumer codecs.

import SwiftUI

enum ZidooLevel {
    case plays, likely, noPlay
    var emoji: String { switch self { case .plays: return "🟢"; case .likely: return "🟡"; case .noPlay: return "🔴" } }
    var title: String { switch self { case .plays: return "PLAYS ON THE ZIDOO"; case .likely: return "SHOULD PLAY ON THE ZIDOO"; case .noPlay: return "WON'T PLAY ON THE ZIDOO" } }
    var color: Color { switch self { case .plays: return .green; case .likely: return Color(red: 0.86, green: 0.62, blue: 0.0); case .noPlay: return .red } }
    var explanation: String {
        switch self {
        case .plays: return "Container, video and audio are all in Zidoo's published specs."
        case .likely: return "Nothing blocks it, but at least one item isn't confirmed in Zidoo's published specs — see the checks."
        case .noPlay: return "At least one stream isn't in Zidoo's list of decoders — see the checks."
        }
    }
}

enum Zidoo {
    static let caveat = "Based on Zidoo's published specs (Z9X / Z9X PRO line) — not tested on your player."

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
                if w > 4096 || fps > 60.5 {
                    c.append(Check(level: .warn, title: n, detail: "HEVC \(w) px · \(fpsText) — above the 4K@60p HEVC in Zidoo's spec (Zidoo spec)"))
                } else {
                    c.append(Check(level: .ok, title: n, detail: "HEVC \(depth)-bit · \(fpsText) — Zidoo decodes HEVC 4K@60p up to 12-bit (Zidoo spec)"))
                }
            case "AVC":
                let prof = v["Format_Profile"] ?? ""
                let chroma = v["ChromaSubsampling"] ?? "4:2:0"
                if prof.contains("10") || prof.contains("4:2:2") || prof.contains("4:4:4") || depth != "8" || chroma != "4:2:0" {
                    c.append(Check(level: .warn, title: n, detail: "H.264 \(prof) \(depth)-bit \(chroma) — Zidoo's specs don't say whether it decodes beyond 8-bit 4:2:0 H.264 (our guess: often not on Realtek)"))
                } else if w > 1920 && fps > 30.5 {
                    c.append(Check(level: .warn, title: n, detail: "H.264 4K at \(fpsText) — the Z9X spec stops at H.264 4K@24fps; the Z9X PRO sheet doesn't list H.264 at all (Zidoo spec). Use HEVC for 4K above 30 fps."))
                } else if w > 1920 && fps > 25 {
                    c.append(Check(level: .warn, title: n, detail: "H.264 4K at \(fpsText) — the Z9X spec says H.264 up to 4K@24fps (Zidoo spec); 25–30 fps isn't confirmed"))
                } else if w > 1920 {
                    c.append(Check(level: .warn, title: n, detail: "H.264 4K at \(fpsText) — the Z9X spec says H.264 up to 4K@24fps, but the Z9X PRO sheet doesn't list H.264 at all (Zidoo spec): should play, not confirmed for the PRO"))
                } else {
                    c.append(Check(level: .ok, title: n, detail: "H.264 \(w) px · \(fpsText) — inside the Z9X spec (H.264 up to 4K@24fps) (Zidoo spec)"))
                }
            case "VP9":
                c.append(Check(level: fps > 60.5 ? .warn : .ok, title: n, detail: "VP9 · \(fpsText) — Zidoo spec: VP9 up to 4K@60fps (Zidoo spec)"))
            case "AV1":
                c.append(Check(level: .warn, title: n, detail: "AV1 — only one retailer page claims AV1 for the Z9X PRO; not in Zidoo's own spec (owners' reports, not Zidoo)"))
            case "MPEG Video", "VC-1":
                c.append(Check(level: .warn, title: n, detail: "\(f) — not in the specs we found; Zidoo plays Blu-ray/DVD discs, which use it (our guess)"))
            case "ProRes":
                c.append(Check(level: .fail, title: n, detail: "Apple ProRes \(v["Format_Profile"] ?? "") — not in any Zidoo spec (its decoders are HEVC, H.264, VP9) (Zidoo spec). Make an HEVC or H.264 version for the Zidoo."))
            case "JPEG 2000", "VC-3", "CineForm", "DNxHR", "DNxHD":
                c.append(Check(level: .fail, title: n, detail: "\(f) — a mastering codec, not in any Zidoo spec (Zidoo spec). Make an HEVC version for the Zidoo."))
            default:
                c.append(Check(level: .fail, title: n, detail: "\(f.isEmpty ? "Unknown codec" : f) — not in Zidoo's list of decoders (HEVC, H.264, VP9) (Zidoo spec)"))
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
            if transfer == "HLG" { c.append(Check(level: .ok, title: "\(n) · HLG", detail: "HLG is in the Z9X PRO's HDMI output line on dealer listings, not on Zidoo's own guide")) }
        }

        // Audio
        for (i, a) in audios.enumerated() {
            let n = "Audio \(i + 1)"
            let f = a["Format"] ?? ""
            let ch = Int(a["Channels"] ?? "") ?? 0
            let name = a["Format_Commercial_IfAny"] ?? f
            if Academy.isTrueHD(a) || ["E-AC-3", "AC-3", "DTS"].contains(f) {
                c.append(Check(level: .ok, title: n, detail: "\(name) · \(ch) ch — HD audio passthrough to the receiver over HDMI (Zidoo spec). Without a receiver the Zidoo itself decodes only 2 channels (Zidoo spec)."))
            } else if f == "PCM" {
                if ch <= 2 {
                    c.append(Check(level: .ok, title: n, detail: "PCM \(ch) ch — LPCM 2.0 is in Zidoo's spec (Zidoo spec)"))
                } else {
                    c.append(Check(level: .warn, title: n, detail: "PCM \(ch) ch — the spec only states LPCM 2.0; multichannel LPCM over HDMI is reported by owners, not written by Zidoo"))
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
