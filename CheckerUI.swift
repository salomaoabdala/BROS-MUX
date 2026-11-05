// BROS-MUX — the File Checker screen: a read-only report on one file, laid out as grouped sections.

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
        if insp.url == nil {
            EmptyDropView(targeted: targeted, title: "Drop a file to inspect",
                          subtitle: "Shows codec, quality, bitrate, Atmos, channel labels, black at head/tail, checks everything against the Academy Screening Room specs, and says whether it plays on the Zidoo. Read-only — nothing is changed.")
        } else if insp.loading {
            ProgressView("Reading the file…").frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Form {
                header
                verdict
                summary
                academy
                ChecksSection(title: "Zidoo playback checks", checks: insp.data.zidooChecks, footer: Zidoo.caveat)
                ForEach(Array(insp.data.tracks.enumerated()), id: \.offset) { _, t in TrackCard(t: t) }
                loudness
                Section {
                    DisclosureGroup(isExpanded: Binding(get: { showRaw && !forceRawCollapsed }, set: { showRaw = $0 })) {
                        TerminalBox(text: insp.data.report, scrolls: false)
                        HStack {
                            Button("Copy Report") {
                                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(insp.data.report, forType: .string)
                            }
                            Spacer()
                        }
                    } label: {
                        Text("Full report (MediaInfo)")
                    }
                }
            }
            .formStyle(.grouped)
        }
    }

    var header: some View {
        let g = insp.data.tracks.first { $0.type == "General" }
        return Section {
            HStack(spacing: 12) {
                Image(systemName: "doc.fill").font(.title).foregroundStyle(.secondary).symbolRenderingMode(.hierarchical)
                VStack(alignment: .leading, spacing: 3) {
                    Text(insp.url?.lastPathComponent ?? "").font(.title3.weight(.semibold)).textSelection(.enabled)
                    HStack(spacing: 12) {
                        if let s = g?.d("FileSize") { Text(Fmt.bytes(s)) }
                        if let d = g?.d("Duration") { Text(Fmt.duration(d)).monospacedDigit() }
                        Text("\(g?["Format"] ?? "") \(g?["Format_Profile"] ?? "")")
                        if let b = g?.d("OverallBitRate") { Text(Fmt.bitrate(b)) }
                    }
                    .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Other File…") { project.openPanel() }
            }
            .padding(.vertical, 4)
        }
    }

    var verdict: some View {
        Section {
            if HDRFileCard.isHDR(insp.data.tracks) {
                HDRFileCard(tracks: insp.data.tracks)
            } else {
                AcademySeal(level: insp.data.level, caption: "Verified on this file · based on the Academy Screening Room technical specs (not an official Academy approval)")
                    .padding(.vertical, 4)
            }
            ZidooSeal(level: insp.data.zidooLevel, caption: "Read from this file · " + Zidoo.caveat)
                .padding(.vertical, 4)
            if let codec = insp.data.checks.first(where: { $0.title == "Video codec" }), codec.level != .ok, let u = insp.url {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Label("The picture isn't what the Academy asks for (\(codec.detail)).", systemImage: codec.level.icon).foregroundStyle(codec.level.color).font(.callout).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Fix → Transcode to ProRes 422 HQ") { project.openInVideoTab(u, target: .transcode(VideoTranscodeSettings(preset: "prores422HQ"))); project.mode = .video }
                        .tint(.orange).buttonStyle(.borderedProminent)
                        .help("Opens the Video tab with this file and the Academy preset (a new file is written; this one isn't touched)")
                }
                .padding(.vertical, 4)
            }
        }
    }

    /// Short "what's inside" summary of the inspected file
    var summary: some View {
        let v = insp.data.tracks.first { $0.type == "Video" }
        let audios = insp.data.tracks.filter { $0.type == "Audio" }
        return Section {
            if let v {
                LabeledContent("Video") {
                    Text("\(v["Format"] ?? "") \(v["Format_Profile"] ?? "") · \(v["Width"] ?? "?")×\(v["Height"] ?? "?") · \(v["FrameRate"] ?? "?") fps · \(v["BitDepth"] ?? "?")-bit \(v["ChromaSubsampling"] ?? "")" +
                         (v.d("BitRate").map { " · " + Fmt.bitrate($0) } ?? "") + (HDRInfo.rows(v).isEmpty ? "" : " · " + HDRInfo.rows(v).map(\.0).joined(separator: " + ")))
                        .textSelection(.enabled).multilineTextAlignment(.trailing)
                }
            }
            LabeledContent("Audio tracks") { Text("\(audios.count)") }
            ForEach(Array(audios.enumerated()), id: \.offset) { i, a in
                let lossy = a["Compression_Mode"] == "Lossy"
                LabeledContent("Audio \(i + 1)") {
                    Text("\(a["Format_Commercial_IfAny"] ?? a["Format"] ?? "") · \(a.d("SamplingRate").map(Fmt.hz) ?? "") · \(a["BitDepth"].map { "\($0)-bit · " } ?? "")\(a["Channels"] ?? "?") ch · \(a.d("BitRate").map(Fmt.bitrate) ?? "") · \(lossy ? "Lossy" : "Lossless")")
                        .textSelection(.enabled).multilineTextAlignment(.trailing)
                }
            }
        } header: {
            Text("What's inside")
        }
    }

    var academy: some View {
        let fails = insp.data.checks.filter { $0.level == .fail }.count
        let warns = insp.data.checks.filter { $0.level == .warn }.count
        return Section {
            ForEach(insp.data.checks) { c in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: c.level.icon).foregroundStyle(c.level.color).frame(width: 16)
                    Text(c.title).fontWeight(.medium).frame(width: 230, alignment: .leading)
                    Text(c.detail).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            HStack {
                Text("Academy Screening Room checks")
                Spacer()
                Text(fails > 0 ? "\(fails) failing\(warns > 0 ? " · \(warns) warning(s)" : "")" : warns > 0 ? "\(warns) warning(s)" : "Everything within spec")
                    .foregroundStyle(fails > 0 ? Color.red : warns > 0 ? Color.orange : Color.green)
            }
        }
    }

    var loudness: some View {
        Section {
            LabeledContent("Whole-program loudness and true peak") {
                if insp.measuring {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text(insp.measureStage).foregroundStyle(.secondary) }
                } else {
                    Button("Measure") { insp.measureLoudness() }
                        .disabled(!insp.data.tracks.contains { $0.type == "Audio" })
                }
            }
            ForEach(Array(insp.data.loudness.enumerated()), id: \.offset) { _, l in
                Text(l).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Loudness & true peak (read-only)")
        } footer: {
            Text("Only measures and reports — the mix is never changed. The Academy asks for -27 LKFS ±2 dialogue-gated and -2 dBTP; this is a whole-program measurement, for reference (the Academy says it may adjust levels).")
        }
    }
}

/// One stream of the inspected file as a section of key / value rows
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
            add("Color", "\(t["ColorSpace"] ?? "") \(t["ChromaSubsampling"] ?? "") · \(t["BitDepth"].map { "\($0)-bit" } ?? "")")
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
        Section {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                LabeledContent(r.0) {
                    Text(r.1).textSelection(.enabled).multilineTextAlignment(.trailing)
                }
            }
        } header: {
            Label(title, systemImage: symbol)
        }
    }
}
