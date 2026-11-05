// BROS-MUX Beta 2.0.0 — 02 · AUDIO: the sound that came inside the video file, your own audio, where each one goes in
// the file, the alignment with the picture, and how each track is delivered (COPY, or TRANSCODE when the owner asks).
// Pure interface: the model lives on Project (BrosMux.swift); the engines (sync, mux, audio transcode) live elsewhere.
// The app never decides silently here: the sound of the video starts out of the file and waits for an answer.

import SwiftUI
import AppKit

// MARK: - Look (Cryo tokens plus the few surfaces this tab needs)

private func audioHex(_ v: UInt32, _ opacity: Double = 1) -> Color {
    Color(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255, opacity: opacity)
}

enum AudioLook {
    /// Opaque amber-dark surface: every transcode and every open decision is announced on it (never translucent)
    static let attention = LinearGradient(colors: [audioHex(0x191611), audioHex(0x0A0C10)], startPoint: .top, endPoint: .bottom)
    /// The sheets' own surface (opaque), so they read the same drawn alone or presented
    static let sheet = LinearGradient(colors: [audioHex(0x0E1A26), audioHex(0x060C12)], startPoint: .top, endPoint: .bottom)
    /// Waveforms: the reference in ice, the track under test in lilac
    static let lilac = audioHex(0xC7A8FF)
    /// Scope ground (solid, neutral) and its ring; the neutral ring around any picture
    static let scope = audioHex(0x06090C)
    static let scopeRing = audioHex(0x96A0AA, 0.18)
    static let imageRing = audioHex(0x96A0AA, 0.35)
    /// Cards inside the inspector and the sheets
    static let card = Cryo.s1
    static let cardLine = Cryo.s3
    static let field = audioHex(0x070D14)
}

extension CheckLevel {
    /// Status colour on Cryo: mint PASS, amber ATTENTION, red FAIL, grey info — always shown with its icon and a word
    var audioTint: Color {
        switch self {
        case .ok: return Cryo.pass
        case .warn: return Cryo.attention
        case .fail: return Cryo.fail
        case .info: return Cryo.info
        }
    }
}

/// A rounded opaque card (inspector, sheets)
struct AudioCard<Content: View>: View {
    var padding: CGFloat = 12
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content() }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(AudioLook.card))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(AudioLook.cardLine, lineWidth: 1))
    }
}

/// A caps section title with an optional detail and trailing controls
struct AudioSectionTitle<Trailing: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder var trailing: () -> Trailing
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title.uppercased()).font(CryoFont.label(11)).tracking(1.6).foregroundStyle(Cryo.ink2).lineLimit(1).fixedSize()
            if let detail { Text(detail).font(CryoFont.mono(11)).foregroundStyle(Cryo.ink3).lineLimit(1).truncationMode(.middle) }
            Rectangle().fill(LinearGradient(colors: [Cryo.ice.opacity(0.28), Cryo.ice.opacity(0)], startPoint: .leading, endPoint: .trailing))
                .frame(height: 1).frame(minWidth: 20).alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 4 }
            trailing()
        }
    }
}
extension AudioSectionTitle where Trailing == EmptyView {
    init(title: String, detail: String? = nil) { self.init(title: title, detail: detail) { EmptyView() } }
}

/// A row's title with its chips; when the row is narrow the chips go first (they never push the window wider)
struct AudioTitleChips: View {
    let title: String
    let chips: [String]
    var reference = false
    var size: CGFloat = 14

    var body: some View {
        ViewThatFits(in: .horizontal) {
            line(chips.count)
            if chips.count > 1 { line(1) }
            line(0)
            Text(title).font(CryoFont.title(size)).foregroundStyle(Cryo.ink).lineLimit(1).truncationMode(.tail)
        }
    }
    func line(_ n: Int) -> some View {
        HStack(spacing: 8) {
            Text(title).font(CryoFont.title(size)).foregroundStyle(Cryo.ink).lineLimit(1).fixedSize()
            ForEach(Array(chips.prefix(n)), id: \.self) { CryoChip($0) }
            if reference { CryoChip("SYNC REFERENCE", style: .ref) }
        }
    }
}

/// One status line: icon + words in the status colour (PASS / ATTENTION / FAIL), plain ink for information
struct AudioStatusLine: View {
    let level: CheckLevel
    let text: String
    var symbol: String? = nil
    var size: CGFloat = 12
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol ?? level.icon).font(.system(size: size - 1, weight: .semibold)).foregroundStyle(level.audioTint)
            // the status colour is for the icon and a few words; a whole sentence stays in ink, so colour never decorates
            Text(text).font(CryoFont.body(size)).foregroundStyle(level == .info ? Cryo.ink2 : text.count <= 64 ? level.audioTint : Cryo.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Shared state of the tab (selection, the question that is open, what the owner kept as it is)

@Observable final class AudioTabState {
    static let shared = AudioTabState()
    /// The row whose details the inspector shows
    var selected: UUID?
    /// Rows lit for a moment (a swap of output slots highlights both)
    var flash: Set<UUID> = []
    /// "Keep" on a can't-go-in-as-it-is card: the card closes (the Delivery still checks the file)
    var keptAsIs: Set<UUID> = []
    /// The embedded track whose "Use it in the delivery?" question is open
    var popover: UUID?
    /// Questions closed without an answer: they stay pending, but don't pop up again by themselves
    var dismissed: Set<UUID> = []
    /// Tracks this tab has already lined up by itself (a dropped mix is aligned once, automatically)
    var autoAligned: Set<UUID> = []

    func light(_ ids: [UUID]) {
        flash = Set(ids)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            if self?.flash == Set(ids) { self?.flash = [] }
        }
    }
    func ask(_ id: UUID) { dismissed.remove(id); selected = id; popover = id }
}

// MARK: - What the tab says about the audio (pure functions over the project)

enum AudioFacts {
    /// AAC bitrate the transcode uses: 640 Kbps above stereo, 256 Kbps for stereo and mono
    static func aacKbps(_ channels: Int) -> Int { channels > 2 ? 640 : 256 }
    static func layout(_ t: Track) -> String { Probe.channelText(t.channels, t.channelLayout) }
    static func isDolby(_ t: Track) -> Bool { t.isAtmos || ["eac3", "ac3", "truehd", "mlp", "ac4"].contains(t.codecKey) }

    static func codecShort(_ t: Track) -> String {
        if t.isPCM { return t.bitDepth > 0 ? "PCM \(t.bitDepth)-bit" + (t.codecKey.hasPrefix("pcm_f") ? " float" : "") : "PCM" }
        switch t.codecKey {
        case "eac3": return t.isAtmos ? "E-AC-3 JOC" : "E-AC-3"
        case "ac3": return "AC-3"
        case "truehd", "mlp": return "TrueHD"
        case "ac4": return "AC-4"
        case "aac": return "AAC"
        case "alac": return "ALAC"
        case "flac": return "FLAC"
        case "opus": return "Opus"
        case "mp3": return "MP3"
        case "dts": return "DTS"
        default: return t.codecKey.uppercased()
        }
    }

    /// The chips of a row: ATMOS, the layout, the codec
    static func chips(_ t: Track) -> [String] {
        var c: [String] = []
        if t.isAtmos { c.append("ATMOS") }
        c.append(layout(t).uppercased())
        c.append(codecShort(t).uppercased())
        if t.isGroup { c.append("\(t.members.count) MONO \(t.fromVideoFile ? "STREAMS" : t.members.allSatisfy { $0.wav != nil } ? "WAVS" : "FILES")") }
        return c
    }

    /// "PCM 24-bit 5.1 · 6.9 Mbps"
    static func source(_ t: Track) -> String {
        "\(codecShort(t)) \(layout(t))" + (t.bitRate > 0 ? " · \(Fmt.bitrate(t.bitRate))" : "")
    }
    /// "AAC 5.1 · 640 Kbps" / "PCM 24-bit 5.1" / "COPY"
    static func destination(_ t: Track, _ d: AudioDelivery) -> String {
        switch d {
        case .copy: return "\(codecShort(t)) \(layout(t)) · copied bit for bit"
        case .aac: return "AAC \(layout(t)) · \(aacKbps(t.channels)) Kbps"
        case .pcm24: return "PCM 24-bit \(layout(t))"
        case .ddpAtmos, .trueHDAtmos: return DolbyEncode.target(d)
        }
    }

    /// The Dolby encode that fits the chosen container: DD+ Atmos plays everywhere, TrueHD Atmos only from an MKV
    static func dolbyFit(_ p: Project) -> AudioDelivery { p.container == .mkv ? .trueHDAtmos : .ddpAtmos }

    /// Why this track can't be delivered as `d` (nil = it can). The engine's rule first, then the rules any owner can see.
    static func deliveryProblem(_ t: Track, _ d: AudioDelivery) -> String? {
        guard d != .copy else { return nil }
        if let p = AudioTranscode.problem(t, to: d) { return p }
        if isDolby(t) { return "Dolby (Atmos, E-AC-3, TrueHD) only goes in as a copy" }
        if d == .aac && t.channels > 8 { return "AAC carries at most 8 channels (this track has \(t.channels))" }
        if d == .pcm24 && t.isPCM && t.bitDepth == 24 && !t.codecKey.hasPrefix("pcm_f") { return "It is already PCM 24-bit — COPY keeps it bit for bit" }
        return nil
    }

    /// The container that would take this track as it is, when that is what blocks it
    static func containerFix(_ t: Track, _ p: Project) -> Container? {
        if t.isPCM && p.container == .mp4 { return .mov }
        if ["truehd", "mlp", "dts"].contains(t.codecKey) && p.container != .mkv { return .mkv }
        return nil
    }

    /// Output tracks that can't go in as they are and that nobody has answered yet
    static func unresolved(_ p: Project) -> [Track] {
        p.outputAudio.filter { $0.delivery == .copy && !AudioTabState.shared.keptAsIs.contains($0.id) && p.audioConversionReason($0) != nil }
    }

    /// Every operation on the audio, named once: trims, joined monos, reordered channels, transcodes
    static func operations(_ p: Project) -> [String] {
        let out = p.outputAudio
        var ops: [String] = []
        var heads: [String] = [], later: [String] = [], tails = 0
        for t in out where t.sampleRate > 0 {
            guard let plan = p.plan(for: t) else { continue }
            let net = Double(plan.cut - plan.pad) / t.sampleRate * 1000
            if net >= 0.05 { heads.append(String(format: "%.1f ms", net)) }
            else if net <= -0.05 { later.append(String(format: "%.1f ms", -net)) }
            if plan.tail > 0 { tails += 1 }
        }
        if !heads.isEmpty { ops.append("\(heads.count) trimmed at the head (\(heads.joined(separator: ", ")))") }
        if !later.isEmpty { ops.append("\(later.count) start\(later.count == 1 ? "s" : "") later (\(later.joined(separator: ", ")))") }
        if tails > 0 { ops.append("\(tails) trimmed at the tail to end with the picture") }
        for g in out where g.isGroup {
            let what = g.fromVideoFile ? "mono streams of the video" : g.members.allSatisfy({ $0.wav != nil }) ? "mono WAVs" : "mono files"
            ops.append("\(g.members.count) \(what) joined into one \(layout(g))")
        }
        if out.contains(where: { $0.channelPermutation != nil }) { ops.append("channel order changed") }
        let tx = out.filter { $0.delivery != .copy }
        if !tx.isEmpty {
            ops.append("\(tx.count) track\(tx.count == 1 ? "" : "s") will be transcoded (\(tx.map { "\(codecShort($0)) \(layout($0)) → \(destination($0, $0.delivery))" }.joined(separator: ", "))) — the mix is not changed")
        }
        return ops
    }

    static func touch(_ p: Project) -> FileTouch {
        if !p.pendingAudioDecisions.isEmpty || !unresolved(p).isEmpty { return .pending }
        if p.outputAudio.contains(where: { $0.delivery != .copy }) { return .transcode }
        return .copy
    }

    static func stripText(_ p: Project) -> String {
        var parts: [String] = []
        let n = p.pendingAudioDecisions.count
        if n > 0 { parts.append("\(n) decision\(n == 1 ? "" : "s") pending — the sound inside the video: use it in the delivery?") }
        let u = unresolved(p)
        if let first = u.first, let why = p.audioConversionReason(first) {
            parts.append(u.count == 1 ? "“\(first.title)” can't go in as it is (\(why)) — choose below" : "\(u.count) tracks can't go in as they are — choose below")
        }
        if p.audioTracks.isEmpty { parts.append("no audio yet — drop your mix below") }
        else if p.outputAudio.isEmpty { parts.append("nothing goes in the file yet") }
        else {
            let ops = operations(p)
            if !ops.isEmpty { parts.append(ops.joined(separator: " · ")) }
            else if u.isEmpty { parts.append("every track goes in exactly as it is") }
        }
        return parts.joined(separator: " · ")
    }

    /// One plain sync light per row
    static func sync(_ p: Project, _ t: Track) -> (level: CheckLevel, text: String) {
        if p.syncReferenceID == t.id { return (.info, "the sync reference — the other tracks line up with it") }
        guard p.reference != nil else {
            return (.warn, p.videoSource == nil ? "not lined up yet — no picture" : "not lined up yet — no reference to line up with")
        }
        if p.aligning && t.include { return (.info, "lining up…") }
        if let m = p.alignmentMeter(for: t) {
            return m.allAligned ? (.ok, "lined up with the picture ✓") : (.warn, m.summary)
        }
        if let lag = t.syncLag {
            let sr = t.sampleRate > 0 ? t.sampleRate : 48000
            let applied = p.plan(for: t).map { Double($0.cut - $0.pad) } ?? Double(t.trimStart)
            let ms = (lag + p.referenceOffset - applied / sr) * 1000
            if SyncLights.ok(ms) { return (.ok, "lined up with the picture ✓") }
            return (.warn, String(format: "out of sync: %.1f ms %@ after the trim", abs(ms), ms > 0 ? "late" : "early"))
        }
        if let n = t.syncNote, n.hasPrefix("Not") { return (.warn, n) }
        return (.warn, "not lined up yet")
    }

    /// The Academy's order: Atmos = audio track 1, 5.1 PCM = audio track 2
    static func orderWarning(_ p: Project) -> String? {
        let out = p.outputAudio
        guard let atmos = out.firstIndex(where: \.isAtmos) else { return nil }
        if atmos != 0 { return "The Academy's order is Dolby Atmos = Audio track 1, 5.1 PCM = Audio track 2 — here Atmos is Audio track \(atmos + 1)." }
        if let pcm = out.firstIndex(where: { $0.isPCM && $0.channels == 6 }), pcm != 1 {
            return "The Academy's order is Dolby Atmos = Audio track 1, 5.1 PCM = Audio track 2 — here the 5.1 PCM is Audio track \(pcm + 1)."
        }
        return nil
    }

    /// "2 tracks · Atmos + 5.1"
    static func summary(_ p: Project) -> String {
        let out = p.outputAudio
        let kinds = out.map { $0.isAtmos ? "Atmos" : layout($0) }
        return "\(out.count) track\(out.count == 1 ? "" : "s") · " + kinds.joined(separator: " + ")
    }
}

/// Where a track goes: a slot among the output audio tracks, or out of the file. Embedded tracks go through the answer.
enum AudioActions {
    static func place(_ p: Project, _ id: UUID, slot: Int?) {
        guard let t = p.tracks.first(where: { $0.id == id }) else { return }
        let before = p.outputAudio
        let occupant = slot.flatMap { k in before.indices.contains(k) && before[k].id != id ? before[k].id : nil }
        if p.isEmbedded(t) {
            if slot == nil { p.setEmbeddedAudio(id, use: false); AudioTabState.shared.light([id]); return }
            if p.embeddedAudioAnswer[p.key(of: t)] != true { p.setEmbeddedAudio(id, use: true) }
        }
        p.moveAudio(id, toSlot: slot)
        AudioTabState.shared.light([id] + (occupant.map { [$0] } ?? []))
    }
}

// MARK: - The tab

struct AudioTab: View {
    @Environment(Project.self) private var project
    let targeted: Bool

    static func sidebarLine(project: Project) -> String {
        let n = project.pendingAudioDecisions.count
        if n > 0 { return "\(n) decision\(n == 1 ? "" : "s") pending" }
        if project.audioTracks.isEmpty { return "no audio yet" }
        if project.outputAudio.isEmpty { return "nothing in the file yet" }
        var s = AudioFacts.summary(project)
        let tx = project.outputAudio.filter { $0.delivery != .copy }.count
        if tx > 0 { s += " · \(tx) transcode" + (tx == 1 ? "" : "s") }
        let u = AudioFacts.unresolved(project).count
        if u > 0 { s += " · \(u) can't go in as \(u == 1 ? "it is" : "they are")" }
        return s
    }

    /// Snapshots draw a still frame: no question pops up and nothing is aligned behind their back
    static var drawingStill: Bool { CommandLine.arguments.contains("--snapshot") }

    var body: some View {
        let ui = AudioTabState.shared
        VStack(spacing: 0) {
            CryoStrip(touch: AudioFacts.touch(project), title: "AUDIO", text: AudioFacts.stripText(project)) {
                if let first = project.pendingAudioDecisions.first {
                    let n = project.pendingAudioDecisions.count
                    Button("\(n) DECISION\(n == 1 ? "" : "S")") { ui.ask(first.id) }
                        .buttonStyle(CryoGoButtonStyle(.amber))
                        .help("The sound that came inside the video is waiting for an answer: use it in the delivery or not")
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    NoticeStack(tab: .audio)
                    embeddedSection
                    userSection
                }
                .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 28)
            }
        }
        .onAppear { settle() }
        .onChange(of: settleKey) { settle() }
    }

    /// What can change the question to ask or the alignment to run
    var settleKey: String {
        "\(project.loadingCount)|\(project.busy)|\(project.pendingAudioDecisions.map(\.id))|\(String(describing: project.syncReferenceID))|\(project.outputAudio.map(\.id))"
    }

    func settle() {
        guard !Self.drawingStill else { return }
        let ui = AudioTabState.shared
        // the sound of the video starts out of the file until the owner answers (a 5.1 inside the video comes in with
        // include = true from the engine's old rule); nothing is stored as an answer here — the question stays open
        if project.loadingCount == 0, !project.busy {
            for t in project.pendingAudioDecisions where t.include {
                if let i = project.tracks.firstIndex(where: { $0.id == t.id }) { project.tracks[i].include = false }
            }
        }
        // the question opens on its own once the files are read — one at a time, never again after it was closed unanswered
        if project.loadingCount == 0, ui.popover == nil || !project.pendingAudioDecisions.contains(where: { $0.id == ui.popover }) {
            if let t = project.pendingAudioDecisions.first(where: { !ui.dismissed.contains($0.id) }) {
                ui.popover = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    if project.pendingAudioDecisions.contains(where: { $0.id == t.id }) { ui.selected = t.id; ui.popover = t.id }
                }
            } else { ui.popover = nil }
        }
        // a mix dropped with a reference present is lined up with the picture by itself (once per track); a track that
        // was nudged by hand is never re-measured behind the owner's back — "Line up with the picture" does that
        guard !project.busy, project.state != .running, project.pendingAudioDecisions.isEmpty, let ref = project.reference else { return }
        let targets = project.outputAudio.filter { $0.id != ref.id }
        let fresh = targets.filter { $0.syncLag == nil && !$0.syncApplied && $0.syncNote == nil && !ui.autoAligned.contains($0.id) }
        guard !fresh.isEmpty, !targets.contains(where: { $0.syncNote?.contains("manual nudge") == true }) else { return }
        ui.autoAligned.formUnion(targets.map(\.id))
        project.autoAlign()
    }

    // MARK: FROM THE VIDEO FILE

    @ViewBuilder var embeddedSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            AudioSectionTitle(title: "From the video file", detail: project.videoSource?.url.lastPathComponent)
            if project.videoSource == nil {
                CryoSlot {
                    HStack(spacing: 12) {
                        Image(systemName: "film").font(.system(size: 16)).foregroundStyle(Cryo.ink3)
                        Text("No picture yet. The sound that comes inside the video file shows up here, and you decide whether it goes in the delivery.")
                            .font(CryoFont.body(12.5)).foregroundStyle(Cryo.ink2).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button("Go to Video") { project.mode = .video }.buttonStyle(CryoButtonStyle())
                    }
                }
            } else if project.embeddedAudio.isEmpty {
                CryoSlot {
                    HStack(spacing: 10) {
                        if project.loadingCount > 0 { ProgressView().controlSize(.small) }
                        Text(project.loadingCount > 0 ? "Reading the picture's file…" : "The picture's file carries no sound.")
                            .font(CryoFont.body(12.5)).foregroundStyle(Cryo.ink2)
                    }
                }
            } else {
                ForEach(project.embeddedAudio) { t in AudioEmbeddedRow(track: t) }
            }
        }
    }

    // MARK: YOUR AUDIO

    @ViewBuilder var userSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            AudioSectionTitle(title: "Your audio", detail: project.userAudio.isEmpty ? nil : AudioFacts.summary(project)) {
                if !project.userAudio.isEmpty {
                    Button { project.openPanel() } label: { Label("Add audio…", systemImage: "plus") }
                        .buttonStyle(CryoButtonStyle()).disabled(project.busy)
                }
            }
            if let w = AudioFacts.orderWarning(project) { AudioStatusLine(level: .warn, text: w) }
            GroupOffer()
            if project.userAudio.isEmpty {
                CryoDropZone(title: "Drop your mix", subtitle: "5.1, 7.1, Dolby Atmos, mono WAVs — it goes in bit for bit and is lined up with the picture",
                             systemImage: "waveform", targeted: targeted) { project.openPanel() }
                    .frame(height: 280)
            } else {
                VStack(spacing: 10) {
                    ForEach(project.userAudio) { t in AudioUserRow(track: t) }
                }
                .overlay {
                    if targeted {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Cryo.ice, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                            .padding(-6).allowsHitTesting(false)
                    }
                }
            }
            if project.loadingCount > 0 {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Reading files…").font(CryoFont.body(12)).foregroundStyle(Cryo.ink2)
                }
                .padding(.leading, 4)
            }
        }
    }
}

// MARK: - Rows

/// The output-slot selector: "Output: Not in the file / Audio track 1 / 2 / 3…" (a taken slot swaps the two tracks)
struct AudioSlotMenu: View {
    @Environment(Project.self) private var project
    let track: Track
    /// The caps "OUTPUT" label inside the control (rows); the inspector has its own row label
    var showsLabel = true

    var body: some View {
        let slot = project.outputSlot(of: track.id)
        let out = project.outputAudio
        let count = track.include ? out.count : out.count + 1
        Menu {
            Picker("Output", selection: Binding(get: { slot ?? -1 }, set: { AudioActions.place(project, track.id, slot: $0 < 0 ? nil : $0) })) {
                Text("Not in the file").tag(-1)
                ForEach(0..<max(count, 1), id: \.self) { k in
                    let other = out.indices.contains(k) && out[k].id != track.id ? out[k] : nil
                    Text("Audio track \(k + 1)" + (other.map { " — swaps with “\($0.title)”" } ?? "")).tag(k)
                }
            }
            .pickerStyle(.inline).labelsHidden()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                if showsLabel { Text("OUTPUT").font(CryoFont.label(9)).tracking(1.4).foregroundStyle(Cryo.ink3) }
                HStack(spacing: 6) {
                    Text(slot.map { "Audio track \($0 + 1)" } ?? "Not in the file")
                        .font(CryoFont.body(12.5).weight(.semibold)).foregroundStyle(slot == nil ? Cryo.ink2 : Cryo.ink)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Cryo.ink3)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .frame(minWidth: 128, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(AudioLook.field))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(slot == nil ? Cryo.s3 : Cryo.ice.opacity(0.35), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .fixedSize()
        .disabled(project.busy)
        .help("Where this track goes in the delivered file. Picking a slot another track has swaps the two.")
    }
}

/// COPY (ice) or TRANSCODE (amber) — what happens to this track's bits
struct AudioDeliveryChip: View {
    let track: Track
    var body: some View {
        if track.delivery == .copy { CryoChip("COPY", style: .lit).help("Copied bit for bit") }
        else if track.delivery.isDolbyEncode {
            CryoChip(track.delivery == .ddpAtmos ? "DOLBY → DD+ ATMOS" : "DOLBY → TRUEHD ATMOS", style: .amber).help(track.delivery.label + " · made by Dolby Media Encoder")
        }
        else { CryoChip(track.delivery == .aac ? "TRANSCODE → AAC" : "TRANSCODE → PCM 24", style: .amber).help(track.delivery.label) }
    }
}

/// The sync light of a row
struct AudioSyncLight: View {
    @Environment(Project.self) private var project
    let track: Track
    var body: some View {
        let s = AudioFacts.sync(project, track)
        if project.syncReferenceID == track.id {
            AudioStatusLine(level: .info, text: s.text, symbol: "metronome", size: 11.5)
        } else if project.aligning && track.include {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("lining up with the picture…").font(CryoFont.body(11.5)).foregroundStyle(Cryo.ink2)
            }
        } else {
            AudioStatusLine(level: s.level, text: s.text, size: 11.5).lineLimit(2)
        }
    }
}

/// The opaque amber announcement under a track that is transcoded: source → destination, the reason, the promise
struct AudioTranscodeBanner: View {
    @Environment(Project.self) private var project
    let track: Track
    var body: some View {
        if track.delivery.isDolbyEncode { AudioDolbyBanner(track: track) } else { transcode }
    }
    var transcode: some View {
        let why = project.audioConversionReason(track).map { "you chose it because \($0)" } ?? "you chose it in the inspector"
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 13, weight: .semibold)).foregroundStyle(Cryo.attention).padding(.top, 1)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("TRANSCODE").font(CryoFont.label(11)).tracking(1.4).foregroundStyle(Cryo.attention)
                    Text("\(AudioFacts.source(track)) → \(AudioFacts.destination(track, track.delivery))")
                        .font(CryoFont.mono(11.5)).foregroundStyle(Cryo.ink).lineLimit(1).truncationMode(.middle)
                }
                Text("\(why.prefix(1).uppercased() + why.dropFirst()). The mix is not changed: level, channels, order and sync stay the same and are checked after writing.")
                    .font(CryoFont.body(11.5)).foregroundStyle(Cryo.ink2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(AudioLook.attention))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Cryo.attention.opacity(0.5), lineWidth: 1))
    }
}

/// Beta 2.0.1: the amber announcement of a Dolby encode — the master → the Dolby stream, who makes it (Dolby Media
/// Encoder, and whether its licence is there), what changes and what is checked; a TrueHD outside an MKV says so with the fix
struct AudioDolbyBanner: View {
    @Environment(Project.self) private var project
    let track: Track
    var body: some View {
        let status = DolbyStatus.shared.state
        let wrongContainer = track.delivery == .trueHDAtmos && project.container != .mkv
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "waveform.badge.plus").font(.system(size: 13, weight: .semibold)).foregroundStyle(Cryo.attention).padding(.top, 1)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("DOLBY ENCODE").font(CryoFont.label(11)).tracking(1.4).foregroundStyle(Cryo.attention)
                    Text("ADM master \(track.channels) ch → \(DolbyEncode.target(track.delivery))")
                        .font(CryoFont.mono(11.5)).foregroundStyle(Cryo.ink).lineLimit(1).truncationMode(.middle)
                }
                Text("You chose it. Dolby Media Encoder renders the master's beds and objects into Dolby Atmos"
                     + (track.delivery == .trueHDAtmos ? " (16 elements, lossless) with a 7.1 core" : " (E-AC-3 JOC) with a 5.1 core")
                     + " for players without Atmos. The loudness is only measured, never changed; the master is only read. Codec, Atmos and length are checked, and the sync is measured against the reference after the mux.")
                    .font(CryoFont.body(11.5)).foregroundStyle(Cryo.ink2).fixedSize(horizontal: false, vertical: true)
                switch status {
                case .ready(let s): AudioStatusLine(level: .ok, text: s, size: 11.5)
                case .notInstalled: AudioStatusLine(level: .fail, text: DolbyEncode.notInstalledText, size: 11.5)
                case .notReady(let s): AudioStatusLine(level: .fail, text: s, size: 11.5)
                case .checking: AudioStatusLine(level: .info, text: "Asking \(DolbyEncode.name) for its licence…", symbol: "hourglass", size: 11.5)
                case .closed, .unknown:
                    HStack(spacing: 8) {
                        AudioStatusLine(level: .info, text: "\(DolbyEncode.name) is closed: BROS-MUX opens it in the background for the encode.", size: 11.5)
                        Button("Check the licence now") { DolbyStatus.shared.refresh(open: true) }.buttonStyle(CryoButtonStyle())
                    }
                }
                if wrongContainer {
                    HStack(spacing: 8) {
                        AudioStatusLine(level: .fail, text: "TrueHD Atmos goes in MKV only — MOV and MP4 players don't play TrueHD.", size: 11.5)
                        Button("Change the container to MKV") { project.container = .mkv }.buttonStyle(CryoGoButtonStyle(.amber))
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(AudioLook.attention))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Cryo.attention.opacity(0.5), lineWidth: 1))
        .onAppear { if case .unknown = status { DolbyStatus.shared.refresh() } }
    }
}

/// Beta 2.0.1: an Atmos master (ADM BWF) that isn't Dolby-encoded yet — what it is, and the encode that makes it playable
struct AudioADMCard: View {
    @Environment(Project.self) private var project
    let track: Track
    var body: some View {
        let fit = AudioFacts.dolbyFit(project)
        let other: AudioDelivery = fit == .ddpAtmos ? .trueHDAtmos : .ddpAtmos
        let installed = DolbyEncode.appURL != nil
        var actions: [CryoAlertCard.Action] = []
        if installed {
            actions.append(.init("Encode → \(short(fit))", role: .primary) { encode(fit) })
            actions.append(.init("Encode → \(short(other))" + (other == .trueHDAtmos ? " (MKV)" : ""), role: .secondary) { encode(other) })
        }
        actions.append(.init(track.include ? "Keep" : "Only for sync") { AudioTabState.shared.keptAsIs.insert(track.id) })
        let recommendation = installed
            ? "Encode it here with Dolby Media Encoder: DD+ Atmos (E-AC-3 JOC, \(DolbyEncode.ddpKbps) Kbps) plays on Apple TV, TVs and in MOV/MP4 — it's what the Academy asks for; TrueHD Atmos is lossless, for an MKV home-theater file. The master is only read."
            : DolbyEncode.notInstalledText
        return CryoAlertCard(title: "This is a Dolby Atmos master", subtitle: "\(track.title) · ADM BWF · \(track.channels) channels",
                             detected: "Beds and objects for the Dolby renderer: no player plays it as it is" + (track.include ? "" : " — today it only lines the other tracks up"),
                             recommendation: recommendation, actions: actions)
    }
    func short(_ d: AudioDelivery) -> String { d == .trueHDAtmos ? "TrueHD Atmos" : "DD+ Atmos" }
    func encode(_ d: AudioDelivery) {
        if d == .trueHDAtmos && project.container != .mkv { project.container = .mkv }
        if !track.include { AudioActions.place(project, track.id, slot: project.outputAudio.count) }
        if let i = project.tracks.firstIndex(where: { $0.id == track.id }) { project.tracks[i].delivery = d }
        DolbyStatus.shared.refresh(open: true)
    }
}

/// DETECTED → RECOMMENDED on the row of a track that can't go in as it is
struct AudioConversionCard: View {
    @Environment(Project.self) private var project
    let track: Track
    let reason: String
    var body: some View {
        let aac = AudioFacts.deliveryProblem(track, .aac) == nil
        let pcm = AudioFacts.deliveryProblem(track, .pcm24) == nil
        let to: AudioDelivery? = aac ? .aac : pcm ? .pcm24 : nil
        let fix = AudioFacts.containerFix(track, project)
        var actions: [CryoAlertCard.Action] = []
        if let to {
            actions.append(.init("Transcode to \(AudioFacts.destination(track, to))", role: .primary) { setDelivery(to) })
        }
        if let fix {
            actions.append(.init("Change the container to \(fix.rawValue.uppercased())", role: to == nil ? .primary : .secondary) { project.container = fix })
        }
        actions.append(.init("Keep") { AudioTabState.shared.keptAsIs.insert(track.id) })
        let recommendation = to.map { "Transcode to \(AudioFacts.destination(track, $0)). The mix is not changed: level, channels, order and sync stay the same and are checked after writing." }
            ?? fix.map { "Change the container to \($0.rawValue.uppercased()) — the track then goes in bit for bit." }
            ?? "This track can't be transcoded here (\(AudioFacts.deliveryProblem(track, .aac) ?? "no audio transcode fits")). Keep it and check the Delivery's list, or remove it."
        return CryoAlertCard(title: "This track can't go in as it is", subtitle: "\(track.title) · \(AudioFacts.source(track))",
                             detected: reason, recommendation: recommendation, actions: actions)
    }
    func setDelivery(_ d: AudioDelivery) {
        if let i = project.tracks.firstIndex(where: { $0.id == track.id }) { project.tracks[i].delivery = d }
    }
}

/// One sound that came inside the video file
struct AudioEmbeddedRow: View {
    @Environment(Project.self) private var project
    let track: Track

    var body: some View {
        let ui = AudioTabState.shared
        let answer = project.embeddedAudioAnswer[project.key(of: track)]
        let isRef = project.syncReferenceID == track.id
        let inFile = answer == true && track.include
        CryoSlot(highlighted: ui.selected == track.id || ui.flash.contains(track.id)) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 14) {
                    badge(answer: answer)
                    VStack(alignment: .leading, spacing: 4) {
                        AudioTitleChips(title: track.title, chips: AudioFacts.chips(track), reference: isRef)
                        Text("\(track.url.lastPathComponent) · \(track.sourceLabel)" + (track.isGroup ? "" : " · \(track.details)"))
                            .font(CryoFont.mono(11)).foregroundStyle(Cryo.ink3).lineLimit(1).truncationMode(.tail)
                    }
                    .opacity(inFile ? 1 : 0.55).saturation(inFile ? 1 : 0.4)
                    Spacer(minLength: 8)
                    if inFile {
                        AudioSlotMenu(track: track)
                        AudioDeliveryChip(track: track)
                    }
                    if answer == nil {
                        Button("Decide…") { ui.ask(track.id) }.buttonStyle(CryoGoButtonStyle(.amber)).disabled(project.loadingCount > 0)
                    } else {
                        Button("Change") { ui.ask(track.id) }.buttonStyle(CryoButtonStyle()).disabled(project.busy)
                            .help("Ask again: use this audio in the delivery or not")
                    }
                }
                status(answer: answer, isRef: isRef, inFile: inFile)
                if inFile && track.delivery != .copy { AudioTranscodeBanner(track: track) }
                if inFile, track.delivery == .copy, !ui.keptAsIs.contains(track.id), let r = project.audioConversionReason(track) {
                    AudioConversionCard(track: track, reason: r)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { ui.selected = track.id }
        .popover(isPresented: Binding(get: { ui.popover == track.id },
                                      set: { if !$0, ui.popover == track.id { ui.popover = nil; if project.pendingAudioDecisions.contains(where: { $0.id == track.id }) { ui.dismissed.insert(track.id) } } }),
                 arrowEdge: .bottom) {
            EmbeddedAudioPopover(project: project, trackID: track.id)
        }
    }

    @ViewBuilder func badge(answer: Bool?) -> some View {
        ZStack {
            Circle().fill(AudioLook.field)
            Circle().strokeBorder(answer == nil ? Cryo.attention.opacity(0.7) : answer == true ? Cryo.ice.opacity(0.6) : Cryo.s3, lineWidth: 1)
            if answer == nil {
                Image(systemName: "questionmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Cryo.attention)
            } else if answer == false {
                Image(systemName: "lock.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(Cryo.ink2)
            } else {
                Image(systemName: "film").font(.system(size: 11, weight: .semibold)).foregroundStyle(Cryo.ice)
            }
        }
        .frame(width: 30, height: 30)
        .accessibilityHidden(true)
    }

    @ViewBuilder func status(answer: Bool?, isRef: Bool, inFile: Bool) -> some View {
        if answer == nil {
            AudioStatusLine(level: .warn, text: "Decide: use this audio? Until you answer, it stays out of the file and the Delivery waits.", symbol: "questionmark.circle.fill")
        } else if answer == false {
            HStack(spacing: 6) {
                Image(systemName: "lock.fill").font(.system(size: 11)).foregroundStyle(Cryo.ink3)
                Text(isRef ? "Used only to line up your mix with the picture — not in the file" : "Not in the file")
                    .font(CryoFont.body(12)).foregroundStyle(Cryo.ink2)
            }
        } else {
            HStack(spacing: 14) {
                if let k = project.outputSlot(of: track.id) {
                    Text("In the file as Audio track \(k + 1)" + (isRef ? " · it is also the sync reference" : ""))
                        .font(CryoFont.body(12)).foregroundStyle(Cryo.ink2)
                } else {
                    Text("You said “Use it”, but it isn't in the file — pick an output slot").font(CryoFont.body(12)).foregroundStyle(Cryo.attention)
                }
                if !isRef { AudioSyncLight(track: track) }
            }
        }
    }
}

/// One of the owner's own audio files (or a group of mono files)
struct AudioUserRow: View {
    @Environment(Project.self) private var project
    let track: Track

    var body: some View {
        let ui = AudioTabState.shared
        let reason = track.include ? project.audioConversionReason(track) : nil
        CryoSlot(highlighted: ui.selected == track.id || ui.flash.contains(track.id)) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 14) {
                    AudioSlotMenu(track: track)
                    VStack(alignment: .leading, spacing: 5) {
                        AudioTitleChips(title: track.title, chips: AudioFacts.chips(track))
                        Text(track.isGroup ? track.groupMembersText : "\(track.url.lastPathComponent) · \(track.details)")
                            .font(CryoFont.mono(11)).foregroundStyle(Cryo.ink3).lineLimit(1).truncationMode(.tail)
                        if track.include { AudioSyncLight(track: track) }
                    }
                    .opacity(track.include ? 1 : 0.55).saturation(track.include ? 1 : 0.4)
                    Spacer(minLength: 8)
                    if track.include { AudioDeliveryChip(track: track) }
                    Button { project.remove(track.id) } label: {
                        Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Cryo.ink3)
                            .frame(width: 22, height: 22).background(Circle().fill(AudioLook.field))
                    }
                    .buttonStyle(.plain).disabled(project.busy).help("Remove from the list (the file itself is never touched)")
                }
                if track.include && track.delivery != .copy { AudioTranscodeBanner(track: track) }
                if track.isADMMaster && track.delivery == .copy && !ui.keptAsIs.contains(track.id) {
                    AudioADMCard(track: track)          // Beta 2.0.1: in the file or not, the encode that makes it playable
                } else if let reason, track.delivery == .copy {
                    if ui.keptAsIs.contains(track.id) {
                        HStack(spacing: 8) {
                            AudioStatusLine(level: .warn, text: "Kept as it is: \(reason). The Delivery checks it again before it starts.")
                            Spacer(minLength: 8)
                            Button("Choose again") { ui.keptAsIs.remove(track.id) }.buttonStyle(CryoButtonStyle())
                        }
                    } else {
                        AudioConversionCard(track: track, reason: reason)
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { ui.selected = track.id }
    }
}

// MARK: - "Use it in the delivery?"

/// "This audio came inside the video. Use it in the delivery?" — anchored on the row; [Don't use] is the default
struct EmbeddedAudioPopover: View {
    let project: Project
    let trackID: UUID
    @Environment(\.dismiss) private var dismiss
    init(project: Project, trackID: UUID) { self.project = project; self.trackID = trackID }

    var body: some View {
        let t = project.tracks.first { $0.id == trackID }
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "film").font(.system(size: 12, weight: .semibold)).foregroundStyle(Cryo.ice)
                    .frame(width: 26, height: 26).background(Circle().fill(AudioLook.field))
                    .overlay(Circle().strokeBorder(Cryo.ice.opacity(0.4), lineWidth: 1))
                CryoFieldLabel("From the video file")
                Spacer(minLength: 0)
                CryoChip("DECIDE", style: .amber)
            }
            Text("This audio came inside the video. Use it in the delivery?")
                .font(CryoFont.title(16)).foregroundStyle(Cryo.ink).fixedSize(horizontal: false, vertical: true)
            if let t {
                VStack(alignment: .leading, spacing: 6) {
                    AudioTitleChips(title: t.title, chips: AudioFacts.chips(t), size: 13)
                    Text("\(t.url.lastPathComponent) · \(t.sourceLabel)").font(CryoFont.mono(11)).foregroundStyle(Cryo.ink3)
                        .lineLimit(1).truncationMode(.middle)
                }
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(AudioLook.field))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Cryo.s3, lineWidth: 1))
                Text(t.channels > 2
                     ? "Usually the sound inside the picture's file is a guide or a temp mix. If this \(AudioFacts.layout(t)) is your final mix, use it. If not, it stays out of the file and only lines up your mix with the picture."
                     : "Usually the sound inside the picture's file is a guide or a temp mix. If you don't use it, it stays out of the file and only lines up your mix with the picture.")
                    .font(CryoFont.body(12)).foregroundStyle(Cryo.ink2).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("This sound is no longer in the list.").font(CryoFont.body(12)).foregroundStyle(Cryo.ink2)
            }
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button("Use it") { answer(true) }.buttonStyle(CryoGoButtonStyle(.ghost)).disabled(t == nil)
                Button("Don't use") { answer(false) }.buttonStyle(CryoGoButtonStyle(.primary)).keyboardShortcut(.defaultAction).disabled(t == nil)
            }
        }
        .padding(18)
        .frame(width: 420, alignment: .leading)
        .background(AudioLook.sheet)
        .environment(\.colorScheme, .dark)
    }

    func answer(_ use: Bool) {
        let ui = AudioTabState.shared
        project.setEmbeddedAudio(trackID, use: use)
        ui.dismissed.remove(trackID)
        if ui.popover == trackID { ui.popover = nil }
        ui.selected = trackID
        dismiss()
    }
}

// MARK: - Inspector

struct AudioInspector: View {
    @Environment(Project.self) private var project
    init() {}

    var selectedTrack: Track? {
        let ui = AudioTabState.shared
        if let id = ui.selected, let t = project.audioTracks.first(where: { $0.id == id }) { return t }
        return project.userAudio.first ?? project.embeddedAudio.first
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if let t = selectedTrack, let b = project.binding(for: t.id) {
                    AudioTrackDetails(track: b).id(t.id)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        AudioSectionTitle(title: "Track")
                        Text("Add your audio, then select a track to see its details: language, name, head trim, channels and how it goes in the file.")
                            .font(CryoFont.body(12)).foregroundStyle(Cryo.ink2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if project.audioTracks.count >= 2 {
                    SyncPanel()
                } else if !project.audioTracks.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        AudioSectionTitle(title: "Line up with the picture")
                        Text(project.reference != nil
                             ? "The reference is ready. Drop your mix: it is lined up with the picture by itself."
                             : "Lining up needs a reference: the sound inside the picture's file, or a guide track. Add one to line your mix up with the picture.")
                            .font(CryoFont.body(12)).foregroundStyle(Cryo.ink2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    AudioSectionTitle(title: "Options")
                    AudioOptionsBody(showTable: false)
                }
            }
            .padding(16)
        }
        .scrollContentBackground(.hidden)
    }
}

/// The selected track's details in the inspector
struct AudioTrackDetails: View {
    @Environment(Project.self) private var project
    @Binding var track: Track
    @State private var showChannels = false
    @State private var viewer: SyncViewerModel?
    @State private var picture: PictureSyncModel?

    var isRef: Bool { project.syncReferenceID == track.id }
    var embedded: Bool { project.isEmbedded(track) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            inFile
            sync
            if track.isGroup || track.canReorder { channels }
            delivery
        }
        .disabled(project.busy)
        .sheet(item: $viewer) { SyncViewerSheet(model: $0) }
        .sheet(item: $picture) { PictureSyncSheet(model: $0) }
        .sheet(isPresented: $showChannels) {
            ChannelOrderSheet(track: $track, onUngroup: track.isGroup ? { let id = track.id; project.ungroup(id) } : nil)
        }
    }

    var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            AudioSectionTitle(title: embedded ? "From the video file" : "Your audio")
            Text(track.title).font(CryoFont.title(17)).foregroundStyle(Cryo.ink).lineLimit(2)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    ForEach(AudioFacts.chips(track), id: \.self) { CryoChip($0) }
                    if isRef { CryoChip("SYNC REFERENCE", style: .ref) }
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) { ForEach(AudioFacts.chips(track), id: \.self) { CryoChip($0) } }
                    if isRef { CryoChip("SYNC REFERENCE", style: .ref) }
                }
            }
            Text(track.isGroup ? track.groupMembersText : "\(track.url.lastPathComponent) · \(track.sourceLabel)")
                .font(CryoFont.mono(11)).foregroundStyle(Cryo.ink3).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            if !track.details.isEmpty { Text(track.details).font(CryoFont.mono(11)).foregroundStyle(Cryo.ink2) }
        }
    }

    var inFile: some View {
        AudioCard {
            row("Output") {
                if embedded && project.embeddedAudioAnswer[project.key(of: track)] == nil {
                    Button("Decide: use it?") { AudioTabState.shared.ask(track.id) }.buttonStyle(CryoGoButtonStyle(.amber))
                } else {
                    AudioSlotMenu(track: track, showsLabel: false)
                }
            }
            row("Track name") {
                TextField("Name", text: $track.title).textFieldStyle(.plain).font(CryoFont.body(12.5)).cryoField().frame(minWidth: 110, maxWidth: 220)
            }
            row("Language") {
                Picker("", selection: $track.language) {
                    ForEach(languageOptions, id: \.0) { Text($0.1).tag($0.0) }
                }
                .labelsHidden().frame(minWidth: 110, maxWidth: 220)
            }
            VStack(alignment: .leading, spacing: 4) {
                Toggle(isOn: $track.enabled) { Text("Default").font(CryoFont.body(12.5)).foregroundStyle(Cryo.ink) }
                    .toggleStyle(CryoToggleStyle())
                    .disabled(project.disableExtraAudio)
                Text(project.disableExtraAudio ? "Options: only the first audio track plays by default." : "Plays by default in players.")
                    .font(CryoFont.body(11)).foregroundStyle(Cryo.ink3)
            }
        }
        .disabled(!track.include)
        .opacity(track.include ? 1 : 0.6)
    }

    var sync: some View {
        VStack(alignment: .leading, spacing: 8) {
            AudioSectionTitle(title: "Sync")
            AudioCard {
                row("Head trim (ms)") {
                    if isRef {
                        Text("— read from its start (the reference)").font(CryoFont.body(11.5)).foregroundStyle(Cryo.ink3)
                    } else if track.canTrim {
                        TextField("0", value: $track.trimStartMs, format: .number.precision(.fractionLength(0...3)))
                            .textFieldStyle(.plain).font(CryoFont.mono(12.5)).multilineTextAlignment(.trailing).cryoField().frame(width: 110)
                            .help("How much to cut from the start to sync (negative makes it start later: silence written at the head for PCM, a start delay in the container for Dolby E-AC-3). Filled in by “Line up with the picture”.")
                    } else {
                        Text("— this codec can't be trimmed without a transcode").font(CryoFont.body(11.5)).foregroundStyle(Cryo.ink3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if track.include, let p = project.planText(for: track) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "scissors").font(.system(size: 11)).foregroundStyle(Cryo.ice)
                        Text(p).font(CryoFont.body(11.5)).foregroundStyle(Cryo.ink2).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if track.include || isRef { AudioSyncLight(track: track) }
                if let n = track.syncNote, track.include, !n.hasPrefix("Not") {
                    Text(n).font(CryoFont.body(11)).foregroundStyle(Cryo.ink3).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array((track.warnings + project.containerWarnings(track)).enumerated()), id: \.offset) { _, w in
                    AudioStatusLine(level: .warn, text: w, size: 11.5)
                }
                HStack(spacing: 8) {
                    Button("Sync Viewer…") { viewer = SyncViewerModel(project: project, target: track) }
                        .disabled(project.reference == nil || isRef || !track.include)
                        .help("Both waveforms before/after the alignment, the strongest hits of the mix and the offset along the film")
                    Button("Picture check…") { picture = PictureSyncModel(project: project, target: isRef ? nil : track) }
                        .disabled(project.videoTrack == nil || (project.reference == nil && !track.include))
                        .help("Checks the sound against the picture itself: hard cuts in the image vs sound hits")
                }
                .buttonStyle(CryoButtonStyle())
            }
        }
    }

    var channels: some View {
        VStack(alignment: .leading, spacing: 8) {
            AudioSectionTitle(title: "Channels")
            AudioCard {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: track.listening ? "ear" : "rectangle.split.3x1").font(.system(size: 12))
                        .foregroundStyle(track.listening || track.sourceOrder?.isComplete == true ? Cryo.ice : Cryo.attention)
                    Text(track.isGroup ? track.groupChannelsText : ChannelOrderRow.statusText(track))
                        .font(CryoFont.body(11.5)).foregroundStyle(track.channelPermutation != nil ? Cryo.ink : Cryo.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button(track.channelRoles == nil ? "Identify the channels…" : "Channels…") { showChannels = true }
                    .buttonStyle(CryoButtonStyle())
                    .help("Which \(track.isGroup ? "mono \(track.fromVideoFile ? "stream" : "file")" : "channel") is which, the order they are written in" + (track.isGroup ? ", or ungroup them" : ""))
            }
        }
    }

    @ViewBuilder var delivery: some View {
        VStack(alignment: .leading, spacing: 8) {
            AudioSectionTitle(title: "In the delivery")
            if !track.include {
                Text(isRef ? "Not in the file — it only lines the other tracks up with the picture." : "Not in the file — pick an output slot to deliver it.")
                    .font(CryoFont.body(12)).foregroundStyle(Cryo.ink2).fixedSize(horizontal: false, vertical: true)
            } else {
            AudioCard {
                ForEach(AudioDelivery.options(for: track)) { d in
                    let problem = AudioFacts.deliveryProblem(track, d)
                    let on = track.delivery == d
                    Button {
                        track.delivery = d
                        if d.isDolbyEncode { DolbyStatus.shared.refresh(open: true) }      // the licence is asked now, not at Start
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: on ? "largecircle.fill.circle" : "circle")
                                .font(.system(size: 13)).foregroundStyle(on ? (d == .copy ? Cryo.ice : Cryo.attention) : Cryo.ink3)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(d.label).font(CryoFont.label(11.5)).tracking(0.8)
                                    .foregroundStyle(problem != nil ? Cryo.ink3 : d == .copy ? Cryo.ink : Cryo.attention)
                                Text(problem ?? detail(d)).font(CryoFont.body(11)).foregroundStyle(Cryo.ink3)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(problem != nil || !track.include)
                }
                if track.delivery.isDolbyEncode {
                    let hd = track.delivery == .trueHDAtmos
                    CryoDiffTable(rows: [
                        CryoDiffRow(label: "Codec", from: "\(AudioFacts.codecShort(track)) · ADM", to: hd ? "Dolby TrueHD Atmos" : "E-AC-3 JOC (DD+ Atmos)", changed: true),
                        CryoDiffRow(label: "Bitrate", from: track.bitRate > 0 ? Fmt.bitrate(track.bitRate) : "—", to: hd ? "lossless, VBR" : "\(DolbyEncode.ddpKbps) Kbps", changed: true),
                        CryoDiffRow(label: "Channels", from: "\(track.channels) (beds + objects)", to: hd ? "16 elements + 7.1 core" : "objects + 5.1 core", changed: true),
                        CryoDiffRow(label: "Loudness", from: "the mix", to: "measured only, unchanged", changed: false),
                        CryoDiffRow(label: "Made by", from: "—", to: DolbyEncode.name, changed: true),
                    ])
                } else if track.delivery != .copy {
                    CryoDiffTable(rows: [
                        CryoDiffRow(label: "Codec", from: AudioFacts.codecShort(track), to: track.delivery == .aac ? "AAC" : "PCM 24-bit", changed: true),
                        CryoDiffRow(label: "Bitrate", from: track.bitRate > 0 ? Fmt.bitrate(track.bitRate) : "—",
                                    to: track.delivery == .aac ? "\(AudioFacts.aacKbps(track.channels)) Kbps" : Fmt.bitrate(Double(track.channels) * 24 * max(track.sampleRate, 1)),
                                    changed: true),
                        CryoDiffRow(label: "Channels", from: AudioFacts.layout(track), to: AudioFacts.layout(track), changed: false),
                        CryoDiffRow(label: "Level · order · sync", from: "the mix", to: "unchanged, checked", changed: false),
                    ])
                }
            }
            }
        }
    }

    func detail(_ d: AudioDelivery) -> String {
        switch d {
        case .copy: return "The bits go in unchanged."
        case .aac: return "AAC \(AudioFacts.layout(track)) · \(AudioFacts.aacKbps(track.channels)) Kbps — lossy, for players and MP4. Level, channels, order and sync stay the same."
        case .pcm24: return "PCM 24-bit \(AudioFacts.layout(track)) — lossless; for a float or 32-bit source, or a codec the container can't carry."
        case .ddpAtmos: return "E-AC-3 JOC · \(DolbyEncode.ddpKbps) Kbps, made by Dolby Media Encoder — plays on Apple TV and TVs; MOV, MP4 or MKV. The Academy's format."
        case .trueHDAtmos: return "Dolby TrueHD with Atmos, lossless, made by Dolby Media Encoder — for home theater; MKV only."
        }
    }

    func row<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(label).font(CryoFont.body(12)).foregroundStyle(Cryo.ink2).frame(width: 96, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    var languageOptions: [(String, String)] {
        var l = Languages.list
        if !l.contains(where: { $0.0 == track.language }) { l.insert((track.language, track.language.uppercased()), at: 0) }
        return l
    }
}

// MARK: - Options (what --quality draws; also the inspector's last section)

/// What --quality draws (channel map, disable extra audio, interleave). Presented as a sheet it has its own Done button.
struct AudioOptionsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.isPresented) private var isPresented
    init() {}

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Audio options").font(CryoFont.title(22)).foregroundStyle(Cryo.ink)
                    Text("Labels and flags in the file only — the sound itself is never touched.").font(CryoFont.body(12.5)).foregroundStyle(Cryo.ink2)
                }
                Spacer(minLength: 12)
                CryoChip("COPY · BIT-EXACT", style: .lit)
            }
            .padding(.horizontal, 22).padding(.top, 20).padding(.bottom, 12)
            ScrollView {
                AudioOptionsBody(showTable: true).padding(.horizontal, 22).padding(.bottom, 16)
            }
            if isPresented {
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }.buttonStyle(CryoGoButtonStyle(.primary)).keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 22).padding(.vertical, 14)
            }
        }
        .frame(minWidth: 620, idealWidth: 900, minHeight: 480, idealHeight: 760)
        .background(AudioLook.sheet.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
    }
}

/// The audio options themselves
struct AudioOptionsBody: View {
    @Environment(Project.self) private var project
    var showTable = false

    var body: some View {
        @Bindable var project = project
        VStack(alignment: .leading, spacing: 14) {
            if showTable && !project.outputAudio.isEmpty { table }
            AudioCard {
                Toggle(isOn: $project.writeChannelMap) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Write channel labels on PCM tracks (L R C LFE Ls Rs)").font(CryoFont.body(12.5)).foregroundStyle(Cryo.ink)
                        Text("Required by the Academy. Only the labels in the file's header — the audio itself is untouched.")
                            .font(CryoFont.body(11)).foregroundStyle(Cryo.ink3).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(CryoToggleStyle())
                ForEach(project.outputAudio.filter(\.isPCM)) { t in
                    if let b = project.binding(for: t.id) {
                        HStack(spacing: 10) {
                            Text(t.title).font(CryoFont.body(12)).foregroundStyle(Cryo.ink2).lineLimit(1).frame(width: 130, alignment: .leading)
                            Picker("", selection: b.channelMap) {
                                ForEach(ChannelMap.allCases) { Text($0.label).tag($0) }
                            }
                            .labelsHidden()
                            .disabled(!project.writeChannelMap)
                        }
                    }
                }
                ForEach(project.outputAudio.filter(\.canReorder)) { t in
                    if let b = project.binding(for: t.id) { ChannelOrderRow(track: b) }
                }
            }
            AudioCard {
                Toggle(isOn: $project.disableExtraAudio) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Only the first audio track plays by default").font(CryoFont.body(12.5)).foregroundStyle(Cryo.ink)
                        Text("The others stay in the file, switched off until a player picks them.")
                            .font(CryoFont.body(11)).foregroundStyle(Cryo.ink3).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(CryoToggleStyle())
                VStack(alignment: .leading, spacing: 6) {
                    Text("Audio/video interleave").font(CryoFont.body(12.5)).foregroundStyle(Cryo.ink)
                    CryoSegmented(selection: $project.interleaveMs, options: [(250, "250 ms"), (500, "500 ms (default)"), (1000, "1000 ms")])
                    Text("How the blocks are laid out in the file — it doesn't change the quality.")
                        .font(CryoFont.body(11)).foregroundStyle(Cryo.ink3)
                }
            }
        }
        .disabled(project.busy)
    }

    var table: some View {
        AudioCard {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 7) {
                GridRow {
                    ForEach(["OUTPUT", "TRACK", "CODEC", "BITRATE", "SAMPLE RATE", "CHANNELS", "PROCESS"], id: \.self) {
                        Text($0).font(CryoFont.label(9.5)).tracking(1.2).foregroundStyle(Cryo.ink3)
                    }
                }
                Rectangle().fill(Cryo.s3).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                ForEach(Array(project.outputAudio.enumerated()), id: \.element.id) { k, t in
                    GridRow {
                        Text("Audio \(k + 1)").font(CryoFont.mono(11.5)).foregroundStyle(Cryo.ink2)
                        Text(t.title).font(CryoFont.body(12)).foregroundStyle(Cryo.ink).lineLimit(1)
                        Text(AudioFacts.codecShort(t)).font(CryoFont.body(12)).foregroundStyle(Cryo.ink2).lineLimit(1)
                        Text(t.bitRate > 0 ? Fmt.bitrate(t.bitRate) : "—").font(CryoFont.mono(11.5)).foregroundStyle(Cryo.ink2)
                        Text(Fmt.hz(t.sampleRate)).font(CryoFont.mono(11.5)).foregroundStyle(Cryo.ink2)
                        Text(AudioFacts.layout(t)).font(CryoFont.mono(11.5)).foregroundStyle(Cryo.ink2)
                        Text(process(t)).font(CryoFont.body(11.5)).foregroundStyle(t.delivery == .copy ? Cryo.ice : Cryo.attention)
                    }
                }
            }
        }
    }

    func process(_ t: Track) -> String {
        if t.delivery != .copy { return "TRANSCODE → \(AudioFacts.destination(t, t.delivery))" }
        var s = "COPY"
        if project.planText(for: t) != nil { s += " + trim" }
        if t.isGroup { s += " + join" }
        if t.channelPermutation != nil { s += " + reorder" }
        return s
    }
}
