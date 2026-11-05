// BROS-MUX Beta 2.0.0 — the HDR panels, in A · CRYO (the engine stays in HDR.swift). Signatures as before; the
// encode switch goes through the Video tab's plan (project.video.choose), never straight to hdr.encode.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Interface

/// The advanced HDR · Dolby Vision · HDR10+ section of the Video inspector
struct HDRPanel: View {
    @Environment(Project.self) private var project

    var body: some View {
        @Bindable var hdr = project.hdr
        let video = project.video
        let on = video.choice(project) == .hevcHDR
        let frames = project.videoFrames
        VStack(alignment: .leading, spacing: 12) {
            CryoSectionHeader("HDR · Dolby Vision · HDR10+")
            Toggle(isOn: Binding(get: { on }, set: { video.choose($0 ? .hevcHDR : .copy, project: project) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Transcode to HEVC 10-bit HDR").font(CryoFont.body(12.5)).foregroundStyle(Cryo.ink)
                    Text(on ? "The picture is encoded again to HEVC 10-bit — the only way Dolby Vision, HDR10+ and HDR10 play on TVs, Apple TV, iPhone and Mac. The audio stays bit-exact."
                            : "Masters (ProRes, JPEG 2000, IMF) don't play on TVs or Apple devices. Turn this on for a playback version: HEVC 10-bit with HDR10, and Dolby Vision / HDR10+ when their metadata is here.")
                        .font(CryoFont.body(11)).foregroundStyle(Cryo.ink2).fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(CryoToggleStyle()).disabled(project.busy || project.videoSource == nil)

            if let imf = hdr.imf {
                VideoKV("IMF", "\(imf.title) · \(Fmt.int(frames)) frames @ \(imf.editRate) fps")
            }

            metadataRow(kind: .dolbyVision,
                        file: hdr.dvSource?.label,
                        detail: hdr.dvChecking ? "Reading…" : hdr.dvProblem ?? hdr.dvSummary?.line,
                        bad: hdr.dvProblem != nil,
                        empty: "No Dolby Vision metadata (an XML from DaVinci Resolve, or an IMF DOLBY_….mxf)")
            metadataRow(kind: .hdr10Plus,
                        file: hdr.hdr10plusJSON?.lastPathComponent,
                        detail: hdr.hdr10plusProblem ?? hdr.hdr10plusFrames.map { $0 >= 0 ? "\(Fmt.int($0)) frames" + (frames == 0 ? "" : $0 == frames ? " — the picture has as many" : " — the picture has \(Fmt.int(frames))") : "" },
                        bad: hdr.hdr10plusProblem != nil || (hdr.hdr10plusFrames.map { $0 >= 0 && frames > 0 && $0 != frames } ?? false),
                        empty: "No HDR10+ metadata (Samsung TVs then use HDR10)")

            if on {
                VStack(alignment: .leading, spacing: 3) {
                    CryoFieldLabel("HDR10 (always)")
                    Text(verbatim: "\(hdr.mastering.text) · MaxCLL \(hdr.maxCLL) · MaxFALL \(hdr.maxFALL)").font(CryoFont.mono(11)).foregroundStyle(Cryo.ink)
                    Text(hdr.masteringSource).font(CryoFont.body(10.5)).foregroundStyle(hdr.masteringSource.contains("defaults") ? Cryo.attention : Cryo.ink3)
                }
                RateControlRows(hdr: hdr, showsQuality: true, disabled: project.busy)
                VideoSpeedRow(speed: $hdr.speed, disabled: project.busy, hdrMetadata: true, encoder: "x265")
                if let plan = project.encodePlan {
                    if VideoToolsGate.shared.ready {
                    VideoNote(symbol: "clock", color: Cryo.ink2,
                              text: "Output: \(plan.formats) · ~\(Fmt.bytes(plan.estimatedBytes)) of picture · about \(Fmt.hm(plan.estimatedSeconds)) of encoding on this Mac (rough; it can run overnight — the Mac won't sleep)")
                    }
                    VideoNote(symbol: "paintpalette", color: plan.source.color.isComplete ? Cryo.ink2 : Cryo.attention,
                              text: "Colour: \(plan.outputColor.text)" + (plan.colourNote.map { " — \($0)" } ?? (plan.source.color.isComplete ? " — read from the source and repeated in the output" : " — primaries/transfer missing in the source; BT.2020 / PQ assumed")))
                    // a master that isn't BT.2020: the app says so and recommends the conversion, never converts (or skips) in silence
                    if let from = plan.gamutConversion ?? (plan.gamutWarning != nil ? plan.source.color.primaries : nil) {
                        Toggle(isOn: $hdr.convertGamut) {
                            Text("Convert \(ColorLUT.label(from)) → BT.2020 (recommended)").font(CryoFont.body(12)).foregroundStyle(Cryo.ink)
                        }
                        .toggleStyle(CryoToggleStyle()).disabled(project.busy)
                        VideoNote(symbol: plan.gamutWarning == nil ? "checkmark.circle" : "exclamationmark.triangle.fill",
                                  color: plan.gamutWarning == nil ? Cryo.ink2 : Cryo.attention,
                                  text: plan.gamutWarning ?? "The source is \(ColorLUT.label(from)). HDR10 and Dolby Vision streams are BT.2020: the picture is converted in linear light, the matrix becomes BT.2020 and the chroma siting UHD. The colours don't change — BT.2020 is the container they travel in. The mastering display stays \(ColorLUT.label(from)).")
                    }
                } else if project.videoSource == nil {
                    VideoNote(symbol: "exclamationmark.triangle.fill", color: Cryo.attention, text: "Add the picture (IMF package, or an HDR ProRes/MXF file).")
                }
            }
        }
    }

    /// One metadata file: what it is, what was read, and Choose / Change / Remove (removing says so on the card)
    func metadataRow(kind: VideoPlanModel.MetadataKind, file: String?, detail: String?, bad: Bool, empty: String) -> some View {
        let video = project.video
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                VideoMetadataLogo(kind: kind, height: 11)
                Spacer(minLength: 6)
                if file != nil {
                    Button("Analysis…") { video.present(.metadata(kind)) }.buttonStyle(CryoButtonStyle())
                    Button("Remove") { video.removeMetadata(project: project) }.buttonStyle(CryoButtonStyle(tint: Cryo.ink2))
                }
                Button(file == nil ? "Choose…" : "Change…") { choose(kind) }.buttonStyle(CryoButtonStyle())
            }
            .disabled(project.busy)
            Text(file ?? empty).font(CryoFont.body(11.5)).foregroundStyle(file == nil ? Cryo.ink3 : Cryo.ink).lineLimit(2).truncationMode(.middle)
            if let detail, !detail.isEmpty {
                Text(detail).font(CryoFont.body(10.5)).foregroundStyle(bad ? Cryo.attention : Cryo.ink2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Cryo.s0.opacity(0.5)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Cryo.s3, lineWidth: 1))
    }

    /// The file picker lives in the view; the plan reads what was chosen (and opens its analysis)
    func choose(_ kind: VideoPlanModel.MetadataKind) {
        let p = NSOpenPanel()
        if kind == .dolbyVision {
            p.allowedContentTypes = [.xml, UTType(filenameExtension: "mxf") ?? .data]
            p.message = "Choose the Dolby Vision metadata: the XML exported from DaVinci Resolve, or an IMF DOLBY_….mxf"
        } else {
            p.allowedContentTypes = [.json]
            p.message = "Choose the HDR10+ metadata (JSON — e.g. exported from DaVinci Resolve Studio)"
        }
        guard p.runModal() == .OK, let u = p.url else { return }
        project.video.didAddMetadata(kind: kind, url: u, project: project)
    }
}

/// Where the output will play (replaces the Academy seal for playback versions)
struct PlaybackPanel: View {
    @Environment(Project.self) private var project

    var body: some View {
        let audio = project.included.filter { $0.kind == .audio }
        let hdr = project.videoTrack?.mi?["HDR_Format"] ?? ""
        VStack(alignment: .leading, spacing: 8) {
            PlaybackRows(dolbyVision: project.encodePlan?.hdr?.dolbyVision != nil || hdr.contains("Dolby Vision"),
                         hdr10plus: project.encodePlan?.hdr?.hdr10plus != nil || hdr.contains("2094"),
                         atmosDDP: audio.contains { $0.codecKey == "eac3" && $0.isAtmos },
                         trueHD: audio.contains { $0.codecKey == "truehd" || $0.codecKey == "mlp" },
                         mkv: project.container == .mkv)
            Text("Not for the Academy: it asks for SDR (ProRes 422 HQ / H.264).").font(CryoFont.body(11)).foregroundStyle(Cryo.ink3)
        }
    }
}

/// File Checker: an HDR playback file is judged by where it plays — the Academy checks are for SDR deliveries
struct HDRFileCard: View {
    let tracks: [MITrack]

    static func isHDR(_ tracks: [MITrack]) -> Bool {
        guard let v = tracks.first(where: { $0.type == "Video" }) else { return false }
        let t = v["transfer_characteristics"] ?? ""
        return v["HDR_Format"] != nil || t == "PQ" || t == "HLG"
    }

    var body: some View {
        let v = tracks.first { $0.type == "Video" }
        let hdr = v?["HDR_Format"] ?? ""
        let audios = tracks.filter { $0.type == "Audio" }
        let formats = [hdr.contains("Dolby Vision") ? "Dolby Vision" : nil, hdr.contains("2086") || v?["transfer_characteristics"] == "PQ" ? "HDR10" : nil,
                       hdr.contains("2094") ? "HDR10+" : nil, v?["transfer_characteristics"] == "HLG" ? "HLG" : nil].compactMap { $0 }
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Cryo.s2)
                    RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Cryo.s3, lineWidth: 1)
                    Image(systemName: "sun.max").font(.system(size: 18, weight: .semibold)).foregroundStyle(Cryo.ice)
                }
                .frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text("HDR playback file").font(CryoFont.title(15)).foregroundStyle(Cryo.ink)
                    HStack(spacing: 8) {
                        if hdr.contains("Dolby Vision") { DolbyVisionLogo(height: 11) }
                        if hdr.contains("2094") { HDR10PlusLogo(height: 11) }
                        Text(formats.joined(separator: " + ")).font(CryoFont.body(12)).foregroundStyle(Cryo.ink2)
                    }
                }
            }
            PlaybackRows(dolbyVision: hdr.contains("Dolby Vision"), hdr10plus: hdr.contains("2094"),
                         atmosDDP: audios.contains { Academy.isEAC3JOC($0) }, trueHD: audios.contains { Academy.isTrueHD($0) },
                         mkv: tracks.first { $0.type == "General" }?["Format"] == "Matroska")
            Text("The Academy checks below are for SDR deliveries — they don't apply to this file.").font(CryoFont.body(11)).foregroundStyle(Cryo.ink3)
        }
        .padding(.vertical, 4)
    }
}

struct PlaybackRows: View {
    let dolbyVision: Bool
    let hdr10plus: Bool
    let atmosDDP: Bool
    let trueHD: Bool
    let mkv: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            row("Apple TV 4K · iPhone · iPad · Mac", mkv ? "no — Apple doesn't open MKV (Infuse does)" :
                    [dolbyVision ? "Dolby Vision" : "HDR10", atmosDDP ? "Atmos (E-AC-3)" : trueHD ? "no TrueHD on Apple" : "audio"].joined(separator: " · "), good: !mkv)
            row("LG · Sony · Philips TVs (USB)", [dolbyVision ? "Dolby Vision" : "HDR10", atmosDDP || trueHD ? "Atmos to the soundbar (eARC)" : "audio"].joined(separator: " · "), good: true)
            row("Samsung TVs", hdr10plus ? "HDR10+" : "HDR10 (add HDR10+ metadata for dynamic HDR)", good: hdr10plus)
            row("Home theater (Zidoo, Shield, Kodi, Plex → receiver)", trueHD ? (mkv ? "TrueHD Atmos (lossless)" : "TrueHD Atmos — MKV is the safest container") :
                    atmosDDP ? "Atmos (E-AC-3)" : "—", good: trueHD ? mkv : atmosDDP)
        }
    }

    func row(_ device: String, _ what: String, good: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: good ? "checkmark.circle.fill" : "minus.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(good ? Cryo.pass : Cryo.ink3)
                .accessibilityLabel(good ? "plays" : "partly or not")
            VStack(alignment: .leading, spacing: 1) {
                Text(device).font(CryoFont.body(12).weight(.medium)).foregroundStyle(Cryo.ink)
                Text(what).font(CryoFont.body(11)).foregroundStyle(Cryo.ink2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Bitrate control of the HEVC encode: the mode (CRF / 2-pass / CBR), the quality level or the target preset, the
/// quality floor. Shared by the Video tab's transcode settings and the inspector's HDR panel.
struct RateControlRows: View {
    @Bindable var hdr: HDRSettings
    var showsQuality: Bool          // false where the caller shows its own Quality (an SDR HEVC keeps it in its settings)
    var disabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                CryoFieldLabel("Mode")
                VideoPickChips(selection: $hdr.rateMode, options: HDRSettings.RateMode.allCases.map { (value: $0, label: $0.label) }, disabled: disabled)
                Text(hdr.rateMode.detail).font(CryoFont.body(11)).foregroundStyle(Cryo.ink2).fixedSize(horizontal: false, vertical: true)
            }
            if hdr.rateMode == .quality {
                if showsQuality {
                    VStack(alignment: .leading, spacing: 6) {
                        CryoFieldLabel("Quality")
                        VideoPickChips(selection: $hdr.quality, options: HDRSettings.Quality.allCases.map { (value: $0, label: $0.label) }, disabled: disabled)
                        Text(hdr.quality.detail).font(CryoFont.body(11)).foregroundStyle(Cryo.ink2).fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    CryoFieldLabel("Preset")
                    VideoPickChips(selection: $hdr.bitratePreset, options: HDRSettings.BitratePreset.allCases.map { (value: $0, label: $0 == .custom ? "Custom" : $0.label) }, disabled: disabled)
                    Text(hdr.bitratePreset.detail).font(CryoFont.body(11)).foregroundStyle(Cryo.ink2).fixedSize(horizontal: false, vertical: true)
                }
                if hdr.bitratePreset == .custom {
                    HStack(spacing: 18) {
                        mbpsField(hdr.rateMode == .average ? "Average" : "Bitrate", value: $hdr.customMbps)
                        if hdr.rateMode == .average { mbpsField("Peak", value: $hdr.customMaxMbps) }
                    }
                    .disabled(disabled)
                }
                Toggle(isOn: $hdr.qualityFloor) {
                    Text("Quality floor — no frame worse than QP \(HDRSettings.Rate.floorQP), however easy the scene").font(CryoFont.body(12)).foregroundStyle(Cryo.ink)
                }
                .toggleStyle(CryoToggleStyle()).disabled(disabled)
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    if hdr.rate.beyondLevel51 {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(Cryo.attention)
                    }
                    Text(hdr.rate.summary).font(CryoFont.body(11)).foregroundStyle(hdr.rate.beyondLevel51 ? Cryo.attention : Cryo.ink2).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    func mbpsField(_ label: String, value: Binding<Int>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            CryoFieldLabel(label)
            HStack(spacing: 6) {
                TextField("", value: value, format: .number)
                    .textFieldStyle(.plain).font(CryoFont.mono(12)).foregroundStyle(Cryo.ink)
                    .multilineTextAlignment(.trailing).frame(width: 56)
                    .cryoField()
                Text("Mbps").font(CryoFont.body(11.5)).foregroundStyle(Cryo.ink2)
            }
        }
    }
}
