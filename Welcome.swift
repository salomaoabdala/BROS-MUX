// BROS-MUX — welcome screen: the mark, the name, what is inside this one muxer (which engines do what, and whether
// they are installed), and Start.

import SwiftUI

struct Engine: Identifiable {
    let id: String
    let name: String
    let role: String
    let symbol: String
    let color: Color
    let path: String?            // nil = not installed (Homebrew tools)
    let install: String?         // how to install when missing
    var builtIn: Bool { install == nil }
}

@Observable
final class EngineStatus {
    static let shared = EngineStatus()
    var versions: [String: String] = [:]
    @ObservationIgnored private var loading = false

    var engines: [Engine] {
        [
            Engine(id: "mp4box", name: "MP4Box (GPAC)", role: "Writes the MOV / MP4: every track copied bit for bit, nothing re-encoded. BROS-MUX then fixes the channel and Dolby atoms itself.", symbol: "shippingbox", color: .indigo, path: Tools.mp4box, install: "brew install gpac"),
            Engine(id: "ffmpeg", name: "FFmpeg", role: "Decodes audio and picture for the waveform sync, the Picture check and Render QC; lossless MKV copies; the HEVC/x265 encode of the HDR playback versions.", symbol: "film.stack", color: .green, path: Tools.ffmpeg, install: "brew install ffmpeg"),
            Engine(id: "ffprobe", name: "FFprobe", role: "Reads streams, codecs, timestamps and frame counts of every file.", symbol: "doc.text.magnifyingglass", color: .teal, path: Tools.ffprobe, install: "brew install ffmpeg"),
            Engine(id: "mediainfo", name: "MediaInfo", role: "Profiles, bit depths, colour tags and Dolby details for the File Checker and the Academy specs.", symbol: "info.circle", color: .blue, path: Tools.mediainfo, install: "brew install media-info"),
            Engine(id: "dovi", name: "dovi_tool", role: "Dolby Vision: rebuilds the RPU from the IMF metadata and injects it into the HEVC stream.", symbol: "sparkles.tv", color: .purple, path: Tools.doviTool, install: "brew install dovi_tool"),
            Engine(id: "hdr10plus", name: "hdr10plus_tool", role: "HDR10+ dynamic metadata injection.", symbol: "sun.max", color: .orange, path: Tools.hdr10plusTool, install: "brew install hdr10plus_tool"),
            Engine(id: "accelerate", name: "Accelerate (vDSP)", role: "The sync engine: cross-correlation of the real waveforms, sample exact, at 15 points of the film.", symbol: "waveform.path", color: .pink, path: "/System", install: nil),
            Engine(id: "vision", name: "Vision", role: "Reads the text of a red frame to confirm a “Media Offline” card in Render QC.", symbol: "text.viewfinder", color: .cyan, path: "/System", install: nil),
            Engine(id: "avfoundation", name: "AVFoundation", role: "Plays the looping preview of a cut with the muxed or the aligned sound, frame by frame.", symbol: "play.rectangle", color: .gray, path: "/System", install: nil),
            Engine(id: "scenekit", name: "SceneKit", role: "Draws the Dolby Atmos objects and beds in 3D in the Atmos Visualizer.", symbol: "cube.transparent", color: .mint, path: "/System", install: nil),
        ]
    }

    /// `tool -version` for the Homebrew tools, once, off the main thread
    func loadVersions() {
        guard !loading, versions.isEmpty else { return }
        loading = true
        let jobs: [(String, String?, [String], String)] = [
            ("mp4box", Tools.mp4box, ["-version"], "GPAC version "), ("ffmpeg", Tools.ffmpeg, ["-version"], "ffmpeg version "),
            ("ffprobe", Tools.ffprobe, ["-version"], "ffprobe version "), ("mediainfo", Tools.mediainfo, ["--Version"], "MediaInfoLib - v"),
            ("dovi", Tools.doviTool, ["--version"], "dovi_tool "), ("hdr10plus", Tools.hdr10plusTool, ["--version"], "hdr10plus_tool "),
        ]
        DispatchQueue.global(qos: .utility).async {
            var found: [String: String] = [:]
            for (id, exe, args, prefix) in jobs {
                guard let exe else { continue }
                var out = Tools.runSync(exe, args).flatMap { String(data: $0, encoding: .utf8) } ?? ""
                if !out.contains(prefix) { out += Tools.runSync(exe, args, stderr: true).flatMap { String(data: $0, encoding: .utf8) } ?? "" }
                let line = out.split(separator: "\n").first { $0.contains(prefix) }.map(String.init) ?? out.split(separator: "\n").first.map(String.init) ?? ""
                var v = line.range(of: prefix).map { String(line[$0.upperBound...]) } ?? line   // the text after the prefix ("MP4Box - GPAC version 26.07" → "26.07")
                if let sp = v.firstIndex(of: " ") , v.distance(from: v.startIndex, to: sp) > 2 { v = String(v[..<sp]) }
                v = v.trimmingCharacters(in: CharacterSet(charactersIn: " -"))
                if !v.isEmpty { found[id] = String(v.prefix(24)) }
            }
            DispatchQueue.main.async { self.versions = found; self.loading = false }
        }
    }
}

struct WelcomeView: View {
    var onStart: () -> Void = {}
    @Bindable var status = EngineStatus.shared
    @Environment(\.colorScheme) private var scheme

    func start() { onStart() }

    var body: some View {
        ZStack {
            Rectangle().fill(.background)
            RadialGradient(colors: [Color.accentColor.opacity(scheme == .dark ? 0.18 : 0.10), .clear], center: .top, startRadius: 20, endRadius: 700)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer(minLength: 16)
                VStack(spacing: 14) {
                    ABMark(color: .primary).frame(height: 64)
                    VStack(spacing: 4) {
                        (Text("BROS-MUX").font(.system(size: 34, weight: .semibold, design: .rounded))
                         + Text(" (v.\(AppInfo.version))").font(.system(size: 20, weight: .regular, design: .rounded)).foregroundStyle(.secondary))
                            .tracking(2)
                        Text("Lossless muxing, sync and QC for film delivery").font(.title3).foregroundStyle(.secondary)
                    }
                }
                .padding(.bottom, 18)
                VStack(alignment: .leading, spacing: 10) {
                    Text("What is inside this one muxer").font(.headline).padding(.leading, 2)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: DS.gap), GridItem(.flexible(), spacing: DS.gap)], alignment: .leading, spacing: DS.gap) {
                        ForEach(status.engines) { e in engineRow(e) }
                    }
                }
                .frame(maxWidth: 980)
                .padding(.horizontal, DS.margin)
                Spacer(minLength: 14)
                Button(action: start) {
                    Text("Start").font(.title3.weight(.semibold)).foregroundStyle(.white)
                        .frame(minWidth: 200).padding(.vertical, 11).padding(.horizontal, 24)
                        .background(Capsule().fill(Color.accentColor.gradient))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .help("Open the muxer (Return)")
                Text("Abdala Brothers").font(.caption).foregroundStyle(.tertiary).padding(.top, 10).padding(.bottom, 14)
            }
        }
        .frame(width: 1040, height: 700)
        .onAppear { status.loadVersions() }
    }

    func engineRow(_ e: Engine) -> some View {
        let installed = e.path != nil
        return HStack(alignment: .top, spacing: 10) {
            IconTile(symbol: e.symbol, color: installed ? e.color : .gray, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(e.name).font(.subheadline.weight(.semibold))
                    if e.builtIn { Chip(text: "macOS") }
                    else if let v = status.versions[e.id] { Chip(text: v, tint: .green) }
                    else if installed { Chip(text: "installed", tint: .green) }
                    else { Chip(text: "missing", tint: .red) }
                }
                Text(e.role).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !installed, let cmd = e.install { Text(cmd).font(.caption.monospaced()).foregroundStyle(.red) }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.radius, style: .continuous).fill(DS.groupFill))
        .overlay(RoundedRectangle(cornerRadius: DS.radius, style: .continuous).strokeBorder(DS.groupStroke, lineWidth: 1))
    }
}
