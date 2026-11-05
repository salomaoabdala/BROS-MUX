// BROS-MUX — the welcome (A · CRYO boot): the AB mark etched on the dark slab, the name and version, the ten engines as
// lamps that light green as each one is found (amber, with the command that installs it, when one is missing), and
// Start. The boot lasts at most 0.9 s; a click or any key skips it; with Reduce Motion (or while a Delivery renders)
// it shows only the final state.

import SwiftUI
import AppKit

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
    /// The version reading is over (with or without a version for each tool)
    private(set) var loaded = false
    @ObservationIgnored private var loading = false

    var engines: [Engine] {
        [
            Engine(id: "mp4box", name: "MP4Box (GPAC)", role: "Writes the MOV / MP4: every track copied bit for bit. BROS-MUX then fixes the channel and Dolby atoms itself.", symbol: "shippingbox", color: Cryo.ice, path: Tools.mp4box, install: "brew install gpac"),
            Engine(id: "ffmpeg", name: "FFmpeg", role: "Decodes for the sync, the Picture check and Render QC; writes the MKV; runs every transcode you choose (ProRes, H.264, HEVC, AAC, PCM).", symbol: "film.stack", color: Cryo.ice, path: Tools.ffmpeg, install: "brew install ffmpeg"),
            Engine(id: "ffprobe", name: "FFprobe", role: "Reads streams, codecs, timestamps and frame counts of every file.", symbol: "doc.text.magnifyingglass", color: Cryo.ice, path: Tools.ffprobe, install: "brew install ffmpeg"),
            Engine(id: "mediainfo", name: "MediaInfo", role: "Profiles, bit depths, colour tags and Dolby details for the File Checker and the Academy specs.", symbol: "info.circle", color: Cryo.ice, path: Tools.mediainfo, install: "brew install media-info"),
            Engine(id: "dovi", name: "dovi_tool", role: "Dolby Vision: reads the metadata (XML or IMF), rebuilds the RPU and injects it into the HEVC stream.", symbol: "sparkles.tv", color: Cryo.ice, path: Tools.doviTool, install: "brew install dovi_tool"),
            Engine(id: "hdr10plus", name: "hdr10plus_tool", role: "HDR10+ dynamic metadata injection.", symbol: "sun.max", color: Cryo.ice, path: Tools.hdr10plusTool, install: "brew install hdr10plus_tool"),
            Engine(id: "accelerate", name: "Accelerate (vDSP)", role: "The sync engine: cross-correlation of the real waveforms, sample exact, at 15 points of the film.", symbol: "waveform.path", color: Cryo.ice, path: "/System", install: nil),
            Engine(id: "vision", name: "Vision", role: "Reads the text of a red frame to confirm a “Media Offline” card in Render QC.", symbol: "text.viewfinder", color: Cryo.ice, path: "/System", install: nil),
            Engine(id: "avfoundation", name: "AVFoundation", role: "Plays the looping preview of a cut with the muxed or the aligned sound, frame by frame.", symbol: "play.rectangle", color: Cryo.ice, path: "/System", install: nil),
            Engine(id: "scenekit", name: "SceneKit", role: "Draws the Dolby Atmos objects and beds in 3D in the Atmos Visualizer.", symbol: "cube.transparent", color: Cryo.ice, path: "/System", install: nil),
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
            DispatchQueue.main.async { self.versions = found; self.loaded = true; self.loading = false }
        }
    }
}

struct WelcomeView: View {
    var onStart: () -> Void = {}
    @Bindable var status = EngineStatus.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var bootStart: Date? = nil
    @State private var booted = false                  // the boot is over (or skipped, or never played): the final state
    @State private var monitor: Any? = nil

    /// The whole boot, at most (the report: ≤ 0.9 s on a cold launch)
    static let bootLength = 0.9

    func start() { onStart() }

    var body: some View {
        ZStack {
            CryoWindowBackground(progress: nil)
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: booted)) { ctx in
                content(t: booted ? .infinity : ctx.date.timeIntervalSince(bootStart ?? ctx.date))
            }
        }
        .frame(width: 1040, height: 700)
        .preferredColorScheme(.dark)                    // Cryo is dark only, also when the welcome is drawn alone
        .contentShape(Rectangle())
        .onAppear(perform: begin)
        .onDisappear(perform: removeMonitor)
    }

    // MARK: Boot

    func begin() {
        status.loadVersions()
        if reduceMotion || EffectsGovernor.shared.reduceMotion || EffectsGovernor.shared.calm { booted = true; return }
        bootStart = Date()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown]) { ev in
            guard !booted else { return ev }
            finish()
            return ev.type == .keyDown ? nil : ev            // a key only skips; a click also reaches what it was on (Start)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.bootLength + 0.05) { finish() }
    }

    func finish() {
        guard !booted else { return }
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { booted = true }
        removeMonitor()
    }

    func removeMonitor() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }

    /// 0…1 of a step that starts at `from` and lasts `length` seconds, eased
    static func phase(_ t: Double, from: Double, length: Double) -> Double {
        guard t.isFinite else { return 1 }
        let x = max(0, min(1, (t - from) / length))
        return x * x * (3 - 2 * x)
    }

    // MARK: Layout

    func content(t: Double) -> some View {
        let etch = Self.phase(t, from: 0.0, length: 0.45)       // the A is engraved
        let outline = Self.phase(t, from: 0.12, length: 0.40)   // the B's outline
        let fill = Self.phase(t, from: 0.32, length: 0.30)      // the B fills from the left
        let words = Self.phase(t, from: 0.42, length: 0.30)     // the name settles
        return VStack(spacing: 0) {
            Spacer(minLength: 26)
            WelcomeMark(etch: etch, outline: outline, fill: fill)
                .frame(width: 118, height: 79)
                .background {
                    RadialGradient(colors: [Cryo.ice.opacity(0.13 * etch), .clear], center: .center, startRadius: 4, endRadius: 190)
                        .frame(width: 420, height: 300)
                        .allowsHitTesting(false)
                }
                .padding(.bottom, 22)
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text("BROS-MUX").font(CryoFont.title(40).weight(.bold)).tracking(8 + 10 * (1 - words))
                    .foregroundStyle(Color(.sRGB, red: 0.95, green: 0.99, blue: 1, opacity: 1))
                    .shadow(color: Cryo.ice.opacity(0.45 * words), radius: 12)
                Text(AppInfo.label.uppercased()).font(CryoFont.body(17).weight(.light)).tracking(3)
                    .foregroundStyle(Cryo.ice)
            }
            .opacity(words)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("BROS-MUX \(AppInfo.label)")
            Text("Muxing, sync and QC for film delivery — bit for bit, unless you choose to transcode")
                .font(CryoFont.body(13.5)).foregroundStyle(Cryo.ink2)
                .padding(.top, 10)
                .opacity(words)
            engines(t: t)
                .frame(maxWidth: 940)
                .padding(.horizontal, 40)
                .padding(.top, 28)
            Spacer(minLength: 16)
            Button(action: start) { Text("START").frame(minWidth: 150) }
                .buttonStyle(CryoGoButtonStyle(.primary))
                .keyboardShortcut(.defaultAction)
                .help("Open BROS-MUX (Return)")
            Text(booted ? "ABDALA BROTHERS" : "CLICK OR PRESS ANY KEY TO SKIP")
                .font(CryoFont.label(10)).tracking(2.4).foregroundStyle(Cryo.ink3)
                .padding(.top, 14).padding(.bottom, 20)
        }
    }

    func engines(t: Double) -> some View {
        let all = status.engines
        let missing = all.filter { $0.path == nil }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("ENGINES").font(CryoFont.label(10.5)).tracking(2.2).foregroundStyle(Cryo.ink3)
                    .accessibilityAddTraits(.isHeader)
                Text(summary(all: all, missing: missing)).font(CryoFont.mono(11))
                    .foregroundStyle(missing.isEmpty ? Cryo.ink3 : Cryo.attention)
                Rectangle().fill(LinearGradient(colors: [Cryo.ice.opacity(0.25), .clear], startPoint: .leading, endPoint: .trailing))
                    .frame(height: 1)
                    .alignmentGuide(.firstTextBaseline) { d in d[.bottom] + 4 }
            }
            .padding(.horizontal, 2)
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], alignment: .leading, spacing: 8) {
                ForEach(Array(all.enumerated()), id: \.element.id) { i, e in
                    // each lamp lights in turn (0.40 → 0.81 s), and only once its engine has really been found
                    WelcomeEngineCard(engine: e, version: status.versions[e.id], state: state(e),
                                      lit: Self.phase(t, from: 0.40 + 0.045 * Double(i), length: 0.08) >= 1,
                                      shown: Self.phase(t, from: 0.30 + 0.03 * Double(i), length: 0.20))
                }
            }
        }
    }

    fileprivate func state(_ e: Engine) -> WelcomeEngineCard.State {
        if e.path == nil { return .missing }
        if e.builtIn || status.versions[e.id] != nil || status.loaded { return .found }
        return .reading
    }

    func summary(all: [Engine], missing: [Engine]) -> String {
        if !missing.isEmpty { return "\(missing.count) of \(all.count) missing — install with Homebrew" }
        if !status.loaded { return "reading the versions…" }
        return "all \(all.count) found"
    }
}

/// The AB mark, engraved: the A is etched in cyan light, the B's outline follows, then the B fills from the left
private struct WelcomeMark: View {
    let etch: Double
    let outline: Double
    let fill: Double

    var body: some View {
        GeometryReader { g in
            let stroke = g.size.width * ABMarkGeometry.strokeShare
            let inset = stroke / 2 + 0.5
            ZStack {
                ABMarkB()
                    .fill(LinearGradient(colors: [Color(.sRGB, red: 0.95, green: 0.99, blue: 1, opacity: 1), Cryo.ice, Cryo.tint],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .padding(inset)
                    .mask(alignment: .leading) { Rectangle().frame(width: g.size.width * fill) }
                    .shadow(color: Cryo.ice.opacity(0.5 * fill), radius: 8)
                ABMarkB().trim(from: 0, to: outline)
                    .stroke(Cryo.icePale.opacity(0.9), lineWidth: 1)
                    .padding(inset)
                ABMarkA().trim(from: 0, to: etch)
                    .stroke(Cryo.ice, style: StrokeStyle(lineWidth: stroke, lineCap: .butt, lineJoin: .miter, miterLimit: 10))
                    .padding(inset)
                    .shadow(color: Cryo.ice.opacity(0.9), radius: 3)
                    .shadow(color: Cryo.ice.opacity(0.45), radius: 10)
            }
        }
        .aspectRatio(ABMarkGeometry.aspect, contentMode: .fit)
        .accessibilityLabel("Abdala Brothers")
    }
}

/// One engine: its lamp (green when found, amber when missing), its name and version, what it does here
private struct WelcomeEngineCard: View {
    enum State { case reading, found, missing }
    let engine: Engine
    let version: String?
    let state: State
    let lit: Bool          // its turn in the boot has come
    let shown: Double      // 0…1 fade in

    var body: some View {
        let s = RoundedRectangle(cornerRadius: 12, style: .continuous)
        HStack(alignment: .top, spacing: 11) {
            WelcomeLamp(color: lit ? lampColor : nil).padding(.top, 4)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(engine.name).font(CryoFont.body(12.5).weight(.semibold)).foregroundStyle(Cryo.ink)
                        .lineLimit(1)
                    Text(detail).font(CryoFont.mono(11)).foregroundStyle(detailColor).lineLimit(1)
                    Spacer(minLength: 0)
                }
                if state == .missing, let cmd = engine.install {
                    Text("Recommended: \(cmd)").font(CryoFont.mono(11)).foregroundStyle(Cryo.attention)
                        .textSelection(.enabled)
                }
                Text(engine.role).font(CryoFont.body(11)).foregroundStyle(Cryo.ink2)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .topLeading)
        .background(s.fill(Color.black.opacity(0.32)))
        .overlay(s.strokeBorder(state == .missing ? Cryo.attention.opacity(0.40) : Cryo.ice.opacity(0.08), lineWidth: 1))
        .opacity(shown)
        .accessibilityElement(children: .combine)
        .accessibilityValue(state == .missing ? "missing" : state == .reading ? "reading the version" : "found")
    }

    var lampColor: Color? {
        switch state {
        case .found: return Cryo.pass
        case .missing: return Cryo.attention
        case .reading: return nil
        }
    }

    var detail: String {
        switch state {
        case .missing: return "MISSING"
        case .reading: return "reading…"
        case .found: return engine.builtIn ? "macOS" : (version ?? "installed")
        }
    }

    var detailColor: Color {
        switch state {
        case .missing: return Cryo.attention
        case .reading: return Cryo.ink3
        case .found: return engine.builtIn ? Cryo.ink3 : Cryo.ink2
        }
    }
}

/// A lamp lit from inside; unlit, it is a dark etched dot
private struct WelcomeLamp: View {
    let color: Color?
    var body: some View {
        Group {
            if let color {
                Circle()
                    .fill(RadialGradient(stops: [.init(color: .white.opacity(0.95), location: 0), .init(color: color, location: 0.45),
                                                 .init(color: color.opacity(0.5), location: 1)],
                                         center: UnitPoint(x: 0.4, y: 0.35), startRadius: 0, endRadius: 6))
                    .shadow(color: color.opacity(0.8), radius: 4)
            } else {
                Circle().fill(Color.white.opacity(0.12))
            }
        }
        .frame(width: 9, height: 9)
        .accessibilityHidden(true)
    }
}
