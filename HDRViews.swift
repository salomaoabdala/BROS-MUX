// BROS-MUX Beta 2.0.0 — the HDR panels (moved unchanged from HDR.swift; the engine stays there).

import SwiftUI
import AppKit

// MARK: - Interface

/// The HDR & Dolby Vision section of the Mux inspector
struct HDRPanel: View {
    @Environment(Project.self) private var project

    var body: some View {
        @Bindable var hdr = project.hdr
        let v = project.videoTrack
        let frames = project.videoFrames
        Section {
            Toggle("Encode the picture for playback", isOn: Binding(get: { hdr.encode }, set: { hdr.encode = $0; hdr.autoEnabledBy = nil; hdr.autoReason = nil; hdr.bannerCollapsed = false }))
                .toggleStyle(.switch).disabled(project.busy)
            if let imf = hdr.imf {
                LabeledContent("IMF") {
                    Text("\(imf.title) · \(Fmt.int(frames)) frames @ \(imf.editRate) fps").multilineTextAlignment(.trailing)
                }
            }
            if hdr.encode {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: Binding(get: { hdr.dolbyVision && hdr.dvSource != nil }, set: { hdr.dolbyVision = $0 })) {
                        Text("Dolby Vision 8.1")
                    }
                    .toggleStyle(.checkbox).disabled(hdr.dvSource == nil)
                    metaLine(hdr.dvSource?.label ?? "No Dolby Vision metadata",
                             detail: hdr.dvChecking ? "Reading…" : hdr.dvProblem ?? hdr.dvSummary?.line,
                             bad: hdr.dvProblem != nil)
                    Button(hdr.dvSource == nil ? "Choose Dolby Vision XML…" : "Change…") {
                        hdr.chooseDolbyVision(width: project.videoWidth, height: project.videoHeight, frames: frames)
                    }.controlSize(.small)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: Binding(get: { hdr.hdr10plus && hdr.hdr10plusJSON != nil }, set: { hdr.hdr10plus = $0 })) {
                        Text("HDR10+")
                    }
                    .toggleStyle(.checkbox).disabled(hdr.hdr10plusJSON == nil)
                    metaLine(hdr.hdr10plusJSON?.lastPathComponent ?? "No HDR10+ metadata (Samsung TVs then use HDR10)",
                             detail: hdr.hdr10plusProblem ?? hdr.hdr10plusFrames.map { $0 >= 0 ? "\(Fmt.int($0)) frames" + ($0 == frames ? " ✓" : " — the picture has \(Fmt.int(frames))") : "" },
                             bad: hdr.hdr10plusProblem != nil || (hdr.hdr10plusFrames.map { $0 >= 0 && $0 != frames } ?? false))
                    Button(hdr.hdr10plusJSON == nil ? "Choose HDR10+ JSON…" : "Change…") { hdr.chooseHDR10Plus(frames: frames) }.controlSize(.small)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("HDR10 (always)")
                    metaLine("\(hdr.mastering.text) · MaxCLL \(hdr.maxCLL) · MaxFALL \(hdr.maxFALL)", detail: hdr.masteringSource, bad: false)
                }
                RateControlRows(hdr: hdr, showsQuality: true, disabled: project.busy)
                Picker("Speed", selection: $hdr.speed) {
                    ForEach(HDRSettings.Speed.allCases) { Text($0.label).tag($0) }
                }
                .disabled(project.busy)
                if let plan = project.encodePlan {
                    Label("Output: \(plan.formats) · ~\(Fmt.bytes(plan.estimatedBytes)) of picture · about \(Fmt.hm(plan.estimatedSeconds)) of encoding on this Mac (rough; it can run overnight — the Mac won't sleep)",
                          systemImage: "clock").font(.caption).foregroundStyle(.secondary)
                    Label("Colour: \(plan.outputColor.text)" + (plan.colourNote.map { " — \($0)" } ?? (plan.source.color.isComplete ? " — read from the source and repeated in the output" : " — primaries/transfer missing in the source; BT.2020 / PQ assumed")),
                          systemImage: "paintpalette").font(.caption).foregroundStyle(plan.source.color.isComplete ? Color.secondary : Color.orange)
                    // a master that isn't BT.2020: the app says so and recommends the conversion, never converts (or skips) in silence
                    if let from = plan.gamutConversion ?? (plan.gamutWarning != nil ? plan.source.color.primaries : nil) {
                        Toggle(isOn: $hdr.convertGamut) { Text("Convert \(ColorLUT.label(from)) → BT.2020 (recommended)") }.disabled(project.busy)
                        Label(plan.gamutWarning ?? "The source is \(ColorLUT.label(from)). HDR10 and Dolby Vision streams are BT.2020: the picture is converted in linear light, the matrix becomes BT.2020 and the chroma siting UHD. The colours don't change — BT.2020 is the container they travel in. The mastering display stays \(ColorLUT.label(from)).",
                              systemImage: plan.gamutWarning == nil ? "checkmark.circle" : "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(plan.gamutWarning == nil ? Color.secondary : Color.orange).fixedSize(horizontal: false, vertical: true)
                    }
                } else if v == nil {
                    Label("Add the picture (IMF package, or an HDR ProRes/MXF file).", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                }
            }
        } header: {
            Text("HDR · Dolby Vision · HDR10+")
        } footer: {
            Text(hdr.encode
                 ? "The picture is re-encoded to HEVC 10-bit — the only way Dolby Vision, HDR10+ and HDR10 play on TVs, Apple TV, iPhone and Mac. The audio stays bit-exact."
                 : "Masters (ProRes, JPEG 2000, IMF) don't play on TVs or Apple devices. Turn this on to make a playback version: HEVC 10-bit with Dolby Vision, HDR10 and HDR10+.")
        }
    }

    func metaLine(_ title: String, detail: String?, bad: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).lineLimit(1).truncationMode(.middle)
            if let detail, !detail.isEmpty {
                Text(detail).font(.caption2).foregroundStyle(bad ? Color.orange : Color.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Where the output will play (replaces the Academy seal for playback versions)
struct PlaybackPanel: View {
    @Environment(Project.self) private var project

    var body: some View {
        let audio = project.included.filter { $0.kind == .audio }
        let hdr = project.videoTrack?.mi?["HDR_Format"] ?? ""
        PlaybackRows(dolbyVision: project.encodePlan?.hdr?.dolbyVision != nil || hdr.contains("Dolby Vision"),
                     hdr10plus: project.encodePlan?.hdr?.hdr10plus != nil || hdr.contains("2094"),
                     atmosDDP: audio.contains { $0.codecKey == "eac3" && $0.isAtmos },
                     trueHD: audio.contains { $0.codecKey == "truehd" || $0.codecKey == "mlp" },
                     mkv: project.container == .mkv)
        Text("Not for the Academy: it asks for SDR (ProRes 422 HQ / H.264).").font(.caption).foregroundStyle(.secondary)
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                IconTile(symbol: "sun.max.fill", color: .orange, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text("HDR playback file").font(.headline)
                    Text(formats.joined(separator: " + ")).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            PlaybackRows(dolbyVision: hdr.contains("Dolby Vision"), hdr10plus: hdr.contains("2094"),
                         atmosDDP: audios.contains { Academy.isEAC3JOC($0) }, trueHD: audios.contains { Academy.isTrueHD($0) },
                         mkv: tracks.first { $0.type == "General" }?["Format"] == "Matroska")
            Text("The Academy checks below are for SDR deliveries — they don't apply to this file.").font(.caption).foregroundStyle(.secondary)
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
        VStack(alignment: .leading, spacing: 8) {
            row("Apple TV 4K · iPhone · iPad · Mac", mkv ? "no — Apple doesn't open MKV (Infuse does)" :
                    [dolbyVision ? "Dolby Vision" : "HDR10", atmosDDP ? "Atmos (E-AC-3)" : trueHD ? "no TrueHD on Apple" : "audio"].joined(separator: " · "), good: !mkv)
            row("LG · Sony · Philips TVs (USB)", [dolbyVision ? "Dolby Vision" : "HDR10", atmosDDP || trueHD ? "Atmos to the soundbar (eARC)" : "audio"].joined(separator: " · "), good: true)
            row("Samsung TVs", hdr10plus ? "HDR10+" : "HDR10 (add HDR10+ metadata for dynamic HDR)", good: hdr10plus)
            row("Home theater (Zidoo, Shield, Kodi, Plex → receiver)", trueHD ? (mkv ? "TrueHD Atmos (lossless)" : "TrueHD Atmos — MKV is the safest container") :
                    atmosDDP ? "Atmos (E-AC-3)" : "—", good: trueHD ? mkv : atmosDDP)
        }
    }

    func row(_ device: String, _ what: String, good: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: good ? "checkmark.circle.fill" : "minus.circle.fill").foregroundStyle(good ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(device).font(.subheadline.weight(.medium))
                Text(what).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Bitrate control of the HEVC encode: the mode (CRF / 2-pass / CBR), the quality level or the target, the quality floor.
/// Shared by the Mux's HDR panel and the Transcode inspector.
struct RateControlRows: View {
    @Bindable var hdr: HDRSettings
    var showsQuality: Bool          // the Transcode inspector has its own Quality picker (shared with H.264)
    var disabled: Bool

    var body: some View {
        Picker(selection: $hdr.rateMode) {
            ForEach(HDRSettings.RateMode.allCases) { Text($0.label).tag($0) }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Bitrate")
                Text(hdr.rateMode.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(disabled)
        if hdr.rateMode == .quality {
            if showsQuality {
                Picker(selection: $hdr.quality) {
                    ForEach(HDRSettings.Quality.allCases) { Text($0.label).tag($0) }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Quality")
                        Text(hdr.quality.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .disabled(disabled)
            }
        } else {
            Picker(selection: $hdr.bitratePreset) {
                ForEach(HDRSettings.BitratePreset.allCases) { Text($0.label).tag($0) }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Target")
                    Text(hdr.bitratePreset.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(disabled)
            if hdr.bitratePreset == .custom {
                LabeledContent(hdr.rateMode == .average ? "Average" : "Bitrate") {
                    HStack(spacing: 4) {
                        TextField("", value: $hdr.customMbps, format: .number).textFieldStyle(.roundedBorder).frame(width: 60).multilineTextAlignment(.trailing)
                        Text("Mbps")
                    }
                }
                .disabled(disabled)
                if hdr.rateMode == .average {
                    LabeledContent("Peak") {
                        HStack(spacing: 4) {
                            TextField("", value: $hdr.customMaxMbps, format: .number).textFieldStyle(.roundedBorder).frame(width: 60).multilineTextAlignment(.trailing)
                            Text("Mbps")
                        }
                    }
                    .disabled(disabled)
                }
            }
            Toggle(isOn: $hdr.qualityFloor) {
                Text("Quality floor — no frame worse than QP \(HDRSettings.Rate.floorQP), however easy the scene")
            }
            .toggleStyle(.checkbox).disabled(disabled)
            Text(hdr.rate.summary).font(.caption).foregroundStyle(hdr.rate.beyondLevel51 ? Color.orange : Color.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
