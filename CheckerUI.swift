// BROS-MUX — the File Checker: a read-only report on one file (CHECK A FILE, below the workflow). Cryo look: the
// READ ONLY strip, the seals, then recessed slots for what's inside, the Academy and Zidoo checks, each stream,
// the loudness and the full MediaInfo report. Nothing here writes anything; the one way out is the Fix row, which
// opens the file on the Video tab (a new file is written there, never this one).

import SwiftUI
import AppKit

struct InspectorView: View {
    @Environment(Project.self) private var project
    let targeted: Bool
    var scrolls = true                 // kept for the command line
    var forceRawCollapsed = false
    @State private var showRaw = true

    var insp: Inspector { project.inspector }

    var body: some View {
        VStack(spacing: 0) {
            CryoStrip(touch: .readOnly, title: "FILE CHECKER",
                      text: "reads the file, never changes it — codec, Academy specs, Zidoo playback, black at head and tail, loudness")
            if insp.url == nil {
                CryoDropZone(title: "Drop a file to check",
                             subtitle: "Shows codec, quality, bitrate, Atmos, channel labels, black at head and tail, checks everything against the Academy Screening Room specs, and says whether it plays on the Zidoo. Read only — nothing is changed.",
                             systemImage: AppMode.inspect.symbol, targeted: targeted) { project.openPanel() }
            } else if insp.loading {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small).tint(Cryo.ice)
                    Text("Reading the file…").font(CryoFont.body()).foregroundStyle(Cryo.ink2)
                    Text(insp.url?.lastPathComponent ?? "").font(CryoFont.mono(11)).foregroundStyle(Cryo.ink3)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        header
                        verdict
                        summary
                        academy
                        ChecksSection(title: "Zidoo playback checks", checks: insp.data.zidooChecks, footer: Zidoo.caveat)
                        VStack(alignment: .leading, spacing: 8) {
                            CryoSectionHeader("Streams")
                            ForEach(Array(insp.data.tracks.enumerated()), id: \.offset) { _, t in TrackCard(t: t) }
                        }
                        loudness
                        rawReport
                    }
                    .frame(maxWidth: 1000, alignment: .leading)
                    .padding(.horizontal, 24).padding(.vertical, 20)
                    .frame(maxWidth: .infinity)
                }
                .overlay {
                    if targeted {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Cryo.ice, style: StrokeStyle(lineWidth: 2, dash: [6, 4])).padding(10).allowsHitTesting(false)
                    }
                }
            }
        }
    }

    // MARK: the file

    var header: some View {
        let g = insp.data.tracks.first { $0.type == "General" }
        let facts = [g?.d("FileSize").map(Fmt.bytes), g?.d("Duration").map(Fmt.duration),
                     "\(g?["Format"] ?? "") \(g?["Format_Profile"] ?? "")".trimmingCharacters(in: .whitespaces),
                     g?.d("OverallBitRate").map(Fmt.bitrate)].compactMap { $0 }.filter { !$0.isEmpty }
        return CryoSlot {
            HStack(spacing: 14) {
                Image(systemName: "doc").font(.system(size: 24, weight: .light)).foregroundStyle(Cryo.ink3).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(insp.url?.lastPathComponent ?? "").font(CryoFont.title(17)).foregroundStyle(Cryo.ink)
                        .textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                    Text(facts.joined(separator: "  ·  ")).font(CryoFont.mono(11.5)).foregroundStyle(Cryo.ink2).textSelection(.enabled)
                }
                Spacer(minLength: 12)
                Button("Other File…") { project.openPanel() }.buttonStyle(CryoButtonStyle())
            }
        }
    }

    // MARK: the seals, and the one way out (Fix → the Video tab)

    var verdict: some View {
        VStack(alignment: .leading, spacing: 10) {
            CryoSlot {
                VStack(alignment: .leading, spacing: 14) {
                    if HDRFileCard.isHDR(insp.data.tracks) {
                        HDRFileCard(tracks: insp.data.tracks)
                    } else {
                        AcademySeal(level: insp.data.level, caption: "Verified on this file · based on the Academy Screening Room technical specs (not an official Academy approval)")
                    }
                    ChecksSection.Hairline()
                    ZidooSeal(level: insp.data.zidooLevel, caption: "Read from this file · " + Zidoo.caveat)
                }
                .padding(.vertical, 2)
            }
            if let codec = insp.data.checks.first(where: { $0.title == "Video codec" }), codec.level != .ok, let u = insp.url {
                fixRow(codec: codec, url: u)
            }
        }
    }

    /// The Academy's answer for a picture it doesn't take: a ProRes 422 HQ made on the Video tab. Announced like every
    /// transcode: opaque amber, source → destination, and why.
    func fixRow(codec: Check, url u: URL) -> some View {
        let v = insp.data.tracks.first { $0.type == "Video" }
        let source = [v?["Format"], v?["Format_Profile"]].compactMap { $0 }.joined(separator: " ")
        return HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    ChecksSection.Status(level: codec.level)
                    Text("The picture isn't what the Academy asks for").font(CryoFont.body(13).weight(.semibold)).foregroundStyle(Cryo.ink)
                }
                Text(codec.detail).font(CryoFont.body(12)).foregroundStyle(Cryo.ink2).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(FileTouch.transcode.word).font(CryoFont.label(10.5)).tracking(1).foregroundStyle(Cryo.attention)
                    Text(source.isEmpty ? "this picture" : source).font(CryoFont.mono(11.5)).foregroundStyle(Cryo.ink2)
                    Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Cryo.attention)
                    Text("Apple ProRes 422 HQ").font(CryoFont.mono(11.5)).foregroundStyle(Cryo.attention)
                    Text("· a new file").font(CryoFont.body(11.5)).foregroundStyle(Cryo.ink3)
                }
            }
            Spacer(minLength: 12)
            Button("Fix → Transcode to ProRes 422 HQ") {
                project.openInVideoTab(u, target: .transcode(VideoTranscodeSettings(preset: "prores422HQ"))); project.mode = .video
            }
            .buttonStyle(CryoGoButtonStyle(.amber))
            .help("Opens this file on the Video tab with ProRes 422 HQ chosen — a new file is written; this one isn't touched.")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(LinearGradient(colors: [checkerHex(0x191611), checkerHex(0x0A0C10)], startPoint: .top, endPoint: .bottom)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Cryo.attention.opacity(0.45), lineWidth: 1))
    }

    // MARK: what's inside

    /// Short "what's inside" summary of the inspected file
    var summary: some View {
        let v = insp.data.tracks.first { $0.type == "Video" }
        let audios = insp.data.tracks.filter { $0.type == "Audio" }
        var rows: [(String, String)] = []
        if let v {
            rows.append(("Video", "\(v["Format"] ?? "") \(v["Format_Profile"] ?? "") · \(v["Width"] ?? "?")×\(v["Height"] ?? "?") · \(v["FrameRate"] ?? "?") fps · \(v["BitDepth"] ?? "?")-bit \(v["ChromaSubsampling"] ?? "")" +
                         (v.d("BitRate").map { " · " + Fmt.bitrate($0) } ?? "") + (HDRInfo.rows(v).isEmpty ? "" : " · " + HDRInfo.rows(v).map(\.0).joined(separator: " + "))))
        }
        rows.append(("Audio tracks", "\(audios.count)"))
        for (i, a) in audios.enumerated() {
            let lossy = a["Compression_Mode"] == "Lossy"
            rows.append(("Audio \(i + 1)", "\(a["Format_Commercial_IfAny"] ?? a["Format"] ?? "") · \(a.d("SamplingRate").map(Fmt.hz) ?? "") · \(a["BitDepth"].map { "\($0)-bit · " } ?? "")\(a["Channels"] ?? "?") ch · \(a.d("BitRate").map(Fmt.bitrate) ?? "") · \(lossy ? "Lossy" : "Lossless")"))
        }
        return VStack(alignment: .leading, spacing: 8) {
            CryoSectionHeader("What's inside")
            CryoSlot {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 18, verticalSpacing: 7) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                        GridRow {
                            Text(r.0).font(CryoFont.body(12.5)).foregroundStyle(Cryo.ink3)
                            Text(r.1).font(CryoFont.mono(12)).foregroundStyle(Cryo.ink).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    var academy: some View {
        let fails = insp.data.checks.filter { $0.level == .fail }.count
        let warns = insp.data.checks.filter { $0.level == .warn }.count
        let level: CheckLevel = fails > 0 ? .fail : warns > 0 ? .warn : .ok
        let text = fails > 0 ? "\(fails) failing\(warns > 0 ? " · \(warns) warning\(warns == 1 ? "" : "s")" : "")" : warns > 0 ? "\(warns) warning\(warns == 1 ? "" : "s")" : "Everything within spec"
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                CryoSectionHeader("Academy Screening Room checks")
                ChecksSection.Summary(level: level, text: text)
            }
            CryoSlot {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(insp.data.checks.enumerated()), id: \.element.id) { i, c in
                        if i > 0 { ChecksSection.Hairline() }
                        ChecksSection.Row(check: c).padding(.vertical, 6)
                    }
                }
            }
        }
    }

    // MARK: loudness, the full report

    var loudness: some View {
        VStack(alignment: .leading, spacing: 8) {
            CryoSectionHeader("Loudness & true peak · read only")
            CryoSlot {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 12) {
                        Text("Whole-program loudness and true peak").font(CryoFont.body(12.5)).foregroundStyle(Cryo.ink)
                        Spacer(minLength: 8)
                        if insp.measuring {
                            ProgressView().controlSize(.small).tint(Cryo.ice)
                            Text(insp.measureStage).font(CryoFont.mono(11)).foregroundStyle(Cryo.ink2).lineLimit(1)
                        } else {
                            Button("Measure") { insp.measureLoudness() }
                                .buttonStyle(CryoButtonStyle())
                                .disabled(!insp.data.tracks.contains { $0.type == "Audio" })
                        }
                    }
                    ForEach(Array(insp.data.loudness.enumerated()), id: \.offset) { _, l in
                        Text(l).font(CryoFont.mono(11.5)).foregroundStyle(Cryo.ink).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Text("Only measures and reports — the mix is never changed. The Academy asks for -27 LKFS ±2 dialogue-gated and -2 dBTP; this is a whole-program measurement, for reference (the Academy says it may adjust levels).")
                .font(CryoFont.body(11)).foregroundStyle(Cryo.ink3).fixedSize(horizontal: false, vertical: true)
        }
    }

    var rawReport: some View {
        let open = showRaw && !forceRawCollapsed
        return CryoSlot {
            VStack(alignment: .leading, spacing: 10) {
                Button { showRaw = !open } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Cryo.ink3)
                            .rotationEffect(.degrees(open ? 90 : 0))
                        Text("FULL REPORT (MEDIAINFO)").font(CryoFont.label()).tracking(1.2).foregroundStyle(Cryo.ink2)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if open {
                    TerminalBox(text: insp.data.report, scrolls: false)
                    Button("Copy Report") {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(insp.data.report, forType: .string)
                    }
                    .buttonStyle(CryoButtonStyle())
                }
            }
        }
    }
}

/// One stream of the inspected file as a slot of key / value rows
struct TrackCard: View {
    let t: MITrack

    var rows: [(String, String)] {
        var r: [(String, String)] = []
        func add(_ label: String, _ v: String?) { if let v, !v.trimmingCharacters(in: .whitespaces).isEmpty { r.append((label, v)) } }
        switch t.type {
        case "General":
            add("Container", "\(t["Format"] ?? "") \(t["Format_Profile"] ?? "")")
            add("Duration", t.d("Duration").map(Fmt.duration))
            add("Size", t.d("FileSize").map(Fmt.bytes))
            add("Overall bitrate", t.d("OverallBitRate").map(Fmt.bitrate))
            add("Written by", t["Encoded_Application"])
        case "Video":
            add("Codec", "\(t["Format"] ?? "") \(t["Format_Profile"] ?? "")")
            add("Resolution", t["Width"].flatMap { w in t["Height"].map { "\(w)×\($0)" } })
            add("Frame rate", t["FrameRate"].map { "\($0) fps (\(t["FrameRate_Mode"] ?? ""))" })
            add("Bitrate", t.d("BitRate").map { Fmt.bitrate($0) + (t["BitRate_Mode"].map { " (\($0))" } ?? "") })
            add("Color", ["\(t["ColorSpace"] ?? "") \(t["ChromaSubsampling"] ?? "")".trimmingCharacters(in: .whitespaces),
                          t["BitDepth"].map { "\($0)-bit" } ?? ""].filter { !$0.isEmpty }.joined(separator: " · "))
            add("Primaries / transfer / matrix", "\(t["colour_primaries"] ?? "—") / \(t["transfer_characteristics"] ?? "—") / \(t["matrix_coefficients"] ?? "—")")
            add("Gamma (tag)", t["Gamma"])
            for (label, value) in HDRInfo.rows(t) { add(label, value) }
            add("Scan", t["ScanType"])
            add("Duration", t.d("Duration").map(Fmt.duration))
            add("Frames", t["FrameCount"])
        case "Audio":
            add("Format", t["Format_Commercial_IfAny"] ?? t["Format"])
            add("Codec", "\(t["Format"] ?? "") \(t["Format_AdditionalFeatures"] ?? "") \(t["CodecID"].map { "(\($0))" } ?? "")")
            add("Compression", t["Compression_Mode"] == "Lossy" ? "Lossy (compressed codec)" : t["Format"] == "PCM" ? "None (uncompressed PCM)" : t["Compression_Mode"])
            add("Bitrate", t.d("BitRate").map { "\(Fmt.bitrate($0)) (\(t["BitRate_Mode"] == "CBR" ? "constant" : t["BitRate_Mode"] ?? ""))" })
            add("Sample rate", t.d("SamplingRate").map(Fmt.hz))
            add("Bit depth", t["BitDepth"].map { "\($0)-bit" })
            add("Channels", "\(t["Channels"] ?? "") · \(t["ChannelLayout"] ?? "no channel labels")")
            add("Complexity Index", t["ComplexityIndex"])
            add("Dynamic objects", t["NumberOfDynamicObjects"])
            add("Bed", t["BedChannelConfiguration"])
            add("Dialnorm", t["dialnorm"].map { "\($0) dB" })
            // ADM BWF (Dolby Atmos master): programmes, contents, objects…
            add("Metadata", t["Metadata_Format"].map { $0 + (t["Metadata_MuxingMode"].map { " (\($0))" } ?? "") })
            for k in t.f.keys.sorted() where (k.hasPrefix("NumberOf") && k != "NumberOfDynamicObjects") || k.lowercased().hasPrefix("adm") {
                add(k.replacingOccurrences(of: "NumberOf", with: "Number of ").replacingOccurrences(of: "_", with: " "), t[k])
            }
            add("Duration", t.d("Duration").map(Fmt.duration))
            add("Name", t["Title"])
            add("Language", t["Language"])
            add("Group / default", "\(t["AlternateGroup"] ?? "—") / \(t["Default"] ?? "—")")
        case "Other":
            add("Type", t["Type"] ?? t["Format"])
            add("First frame", t["TimeCode_FirstFrame"])
            add("Frame rate", t["FrameRate"])
        default:
            add("Format", t["Format"])
            add("Language", t["Language"])
            add("Name", t["Title"])
        }
        return r
    }

    var title: String {
        switch t.type {
        case "General": return "General"
        case "Video": return "Video"
        case "Audio": return "Audio \(t["@typeorder"] ?? "")" + (Academy.isAtmos(t) ? " · Dolby Atmos" : "")
        case "Text": return "Subtitles"
        case "Other": return "Timecode"
        default: return t.type
        }
    }
    var symbol: String {
        switch t.type { case "Video": return "film"; case "Audio": return "waveform"; case "Text": return "captions.bubble"; case "Other": return "clock"; default: return "doc" }
    }

    var body: some View {
        CryoSlot {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(Cryo.ink3).frame(width: 16)
                    Text(title.uppercased()).font(CryoFont.label(11)).tracking(1.2).foregroundStyle(Cryo.ink2)
                }
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 18, verticalSpacing: 6) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                        GridRow {
                            Text(r.0).font(CryoFont.body(12)).foregroundStyle(Cryo.ink3)
                                .frame(minWidth: 180, alignment: .leading)
                            Text(r.1).font(CryoFont.body(12)).foregroundStyle(Cryo.ink).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
    }
}

private func checkerHex(_ v: UInt32) -> Color {
    Color(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255, opacity: 1)
}
