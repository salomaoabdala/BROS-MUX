// BROS-MUX — the Channel order panel of a PCM track: listen to the track to learn which channel is which, correct the
// roles if needed, and pick the order the channels are written in. The mux then permutes whole samples; nothing is
// transcoded.

import SwiftUI

/// One line in the audio options: what will happen to this track's channels, and the button to the sheet
struct ChannelOrderRow: View {
    @Binding var track: Track
    @State private var open = false

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Channel order · \(track.title)").font(CryoFont.body(12.5)).foregroundStyle(Cryo.ink)
                Text(Self.statusText(track)).font(CryoFont.body(11))
                    .foregroundStyle(track.channelPermutation != nil ? Cryo.ice : Cryo.ink3).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button(track.channelRoles == nil ? "Identify…" : "Channels…") { open = true }.buttonStyle(CryoButtonStyle())
        }
        .sheet(isPresented: $open) { ChannelOrderSheet(track: $track) }
    }

    /// What happens to the channels of this track, in one line
    static func statusText(_ track: Track) -> String {
        if let src = track.sourceOrder, let t = track.channelTarget, track.channelPermutation != nil {
            return "\(src.text) → \(t.text)" + (t.presetName.map { " (\($0))" } ?? "") + " · samples permuted, nothing transcoded"
        }
        if let src = track.sourceOrder {
            let heard = track.channelConfidence != nil
            let c = track.channelConfidence.map { String(format: " · %.0f%% sure", $0 * 100) } ?? ""
            return (heard ? "Heard as " : "Roles set by hand: ") + src.text + (src.presetName.map { " (\($0))" } ?? "") + c + " · written as it is"
        }
        return "\(track.channels) channels, order not checked · written as it is"
    }
}

struct ChannelOrderSheet: View {
    @Binding var track: Track
    @Environment(\.dismiss) private var dismiss
    @State private var running = false
    @State private var progress = 0.0
    @State private var report: ChannelID.Report?
    @State private var roles: [ChannelRole] = []            // the roles as they stand (heard, then corrected by hand)
    @State private var choice = "keep"                      // "keep", a preset's id, or "custom"
    @State private var custom: [ChannelRole] = []
    @State private var problem: String?
    @State private var cancel = CancelFlag()
    @State private var showReport = false
    @State private var loadedRoles: [ChannelRole] = []      // the roles as they were when the sheet opened
    /// A mono group (MonoGroup.swift): "Ungroup" puts the mono tracks back on their own
    var onUngroup: (() -> Void)? = nil

    init(track: Binding<Track>, initialReport: ChannelID.Report? = nil, onUngroup: (() -> Void)? = nil) {
        _track = track
        _report = State(initialValue: initialReport)
        self.onUngroup = onUngroup
    }

    var presets: [ChannelOrder.Preset] { ChannelOrder.presets(channels: track.channels) }
    var sourceOrder: ChannelOrder? { roles.count == track.channels ? ChannelOrder(roles: roles) : nil }
    var target: ChannelOrder? {
        if choice == "keep" { return nil }
        if choice == "custom" { return custom.count == track.channels ? ChannelOrder(roles: custom) : nil }
        return presets.first { $0.id == choice }?.order
    }
    var permutation: [Int]? { guard let t = target, let s = sourceOrder else { return nil }; return t.permutation(from: s) }
    var rolesComplete: Bool { sourceOrder?.isComplete == true }
    /// The chosen order can be written from the roles above (the same order counts: the labels then follow it)
    var targetValid: Bool { guard let t = target, let s = sourceOrder else { return false }; return t.canBeWritten(from: s) }
    /// The roles shown are exactly what the engine heard (hand edits drop the confidence)
    var heard: Bool { report.map { $0.guesses.map(\.role) == roles } ?? false }

    static func confidenceLevel(_ c: Double) -> CheckLevel { c >= 0.8 ? .ok : c >= 0.5 ? .warn : .fail }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Channel order").font(CryoFont.title(22)).foregroundStyle(Cryo.ink)
                    Text("\(track.title) · \(track.channels) channels" + (track.isGroup ? " (\(track.members.count) mono \(track.fromVideoFile ? "streams of \(track.url.lastPathComponent)" : "files"))" : "") + " · \(Int(track.sampleRate)) Hz · \(track.bitDepth)-bit PCM")
                        .font(CryoFont.mono(11)).foregroundStyle(Cryo.ink2).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                CryoChip("COPY · BIT-EXACT", style: .lit)
                if report != nil { Button("Report…") { showReport = true }.buttonStyle(CryoButtonStyle()) }
            }

            AudioCard(padding: 14) {
                HStack {
                    Text("WHO IS WHO").font(CryoFont.label(11)).tracking(1.4).foregroundStyle(Cryo.ink2)
                    Spacer()
                    if running {
                        ProgressView(value: progress).tint(Cryo.ice).frame(width: 160)
                        Button("Stop") { cancel.set() }.buttonStyle(CryoButtonStyle())
                    } else {
                        Button(report == nil ? "Listen to the track" : "Listen again") { listen() }.buttonStyle(CryoButtonStyle())
                    }
                }
                Text((track.isGroup ? "Each mono \(track.fromVideoFile ? "stream" : "file") is one channel" + (track.rolesSource.map { "; the roles shown were \($0)" } ?? "") + ". " : "") +
                     "40 passages between 5% and 80% of the track: the LFE has nothing above 120 Hz, the front pair is the loud pair that moves together, the centre carries the speech, the surrounds are what is left. Left and right inside a pair follow the file order; the sound cannot tell them apart.")
                    .font(CryoFont.body(11)).foregroundStyle(Cryo.ink3).fixedSize(horizontal: false, vertical: true)
                if let r = report {
                    let lv = Self.confidenceLevel(r.overall)
                    HStack(spacing: 8) {
                        Text("Heard: \(r.detected.text)").font(CryoFont.body(13).weight(.semibold)).foregroundStyle(Cryo.ink)
                        if let p = r.detected.presetName { CryoChip(p.uppercased()) }
                        Spacer()
                        AudioStatusLine(level: lv, text: String(format: "%.0f%% sure", r.overall * 100), size: 11.5)
                    }
                }
                if roles.count == track.channels {
                    if track.channels > 6 {                     // six rows fit the sheet; more scroll
                        ScrollView(.vertical) {
                            VStack(alignment: .leading, spacing: 6) { ForEach(0..<track.channels, id: \.self) { c in channelRow(c) } }
                        }
                        .frame(maxHeight: 380)
                    } else {
                        VStack(alignment: .leading, spacing: 6) { ForEach(0..<track.channels, id: \.self) { c in channelRow(c) } }
                    }
                    if !rolesComplete { AudioStatusLine(level: .warn, text: "Each role must be used once.", size: 11.5) }
                }
                if let r = report {
                    ForEach(r.notes.filter { !$0.hasPrefix("which channel of a pair") }, id: \.self) {
                        Text("· " + $0).font(CryoFont.body(11)).foregroundStyle(Cryo.ink3).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let problem { AudioStatusLine(level: .fail, text: problem, size: 11.5) }
            }

            AudioCard(padding: 14) {
                Text("WRITE THE CHANNELS AS").font(CryoFont.label(11)).tracking(1.4).foregroundStyle(Cryo.ink2)
                Picker("", selection: $choice) {
                    Text("Keep the source order").tag("keep")
                    ForEach(presets) { Text("\($0.order.text)  —  \($0.name)").tag($0.id) }
                    Text("Custom order…").tag("custom")
                }
                .labelsHidden()
                if choice == "custom" && custom.count == track.channels {
                    HStack(spacing: 6) {
                        ForEach(0..<track.channels, id: \.self) { k in
                            Picker("", selection: $custom[k]) { ForEach(ChannelRole.allCases) { Text($0.rawValue).tag($0) } }
                                .labelsHidden().frame(width: 72)
                        }
                    }
                }
                if let t = target {
                    if let s = sourceOrder, let p = t.permutation(from: s) {
                        Text("Output: " + p.enumerated().map { "\($0 + 1) ← ch \($1 + 1) (\(s.roles[$1].rawValue))" }.joined(separator: " · "))
                            .font(CryoFont.mono(11)).foregroundStyle(Cryo.ink2).fixedSize(horizontal: false, vertical: true)
                        if t.layoutTag != nil {
                            Text("Channel labels written: \(t.text)").font(CryoFont.body(11)).foregroundStyle(Cryo.ink2)
                        } else {
                            AudioStatusLine(level: .warn, text: "No standard QuickTime label describes this order; the labels will not be written for this track.", size: 11)
                        }
                    } else if let s = sourceOrder {
                        if !s.isComplete {
                            AudioStatusLine(level: .warn, text: "Fix the roles above first: each role once.", size: 11)
                        } else if !t.isComplete {
                            AudioStatusLine(level: .warn, text: "Each role must be used once in the custom order.", size: 11)
                        } else if t == s {
                            Text("The track is already in that order; nothing to permute. The channel labels will say \(t.text).").font(CryoFont.body(11)).foregroundStyle(Cryo.ink2)
                        } else {
                            AudioStatusLine(level: .warn, text: "The roles above (\(s.text)) are not the roles of that order (\(t.text)).", size: 11)
                        }
                    } else {
                        AudioStatusLine(level: .warn, text: "Listen to the track first, or set the roles by hand, so the order is known.", size: 11)
                    }
                }
                Text("Nothing is transcoded: every sample is copied as it is; only its place inside each block changes.")
                    .font(CryoFont.body(11)).foregroundStyle(Cryo.ink3)
            }

            HStack(spacing: 10) {
                Button("Cancel") { cancel.set(); dismiss() }.buttonStyle(CryoGoButtonStyle(.ghost))
                if track.isGroup, let onUngroup {
                    Button("Ungroup") { cancel.set(); dismiss(); onUngroup() }
                        .buttonStyle(CryoButtonStyle())
                        .help("Put the \(track.members.count) mono \(track.fromVideoFile ? "streams" : "files") back as separate tracks")
                }
                Spacer()
                Button("Apply") { apply() }.keyboardShortcut(.defaultAction).buttonStyle(CryoGoButtonStyle(.primary))
                    .disabled(running || !rolesComplete || (choice != "keep" && !targetValid))
            }
        }
        .padding(20)
        .frame(width: 720)
        .background(AudioLook.sheet.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .onAppear { load() }
        .sheet(isPresented: $showReport) {
            VStack(alignment: .leading, spacing: 12) {
                ScrollView {
                    Text(report?.text ?? "").font(CryoFont.mono(11)).foregroundStyle(Cryo.ink2).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                }
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(AudioLook.scope))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(AudioLook.scopeRing, lineWidth: 1))
                HStack { Spacer(); Button("Close") { showReport = false }.keyboardShortcut(.defaultAction).buttonStyle(CryoGoButtonStyle(.primary)) }
            }
            .padding(20).frame(width: 760, height: 420)
            .background(AudioLook.sheet.ignoresSafeArea())
            .environment(\.colorScheme, .dark)
        }
    }

    func channelRow(_ c: Int) -> some View {
        let g = report?.guesses[safe: c]
        let f = report?.features[safe: c]
        return HStack(spacing: 10) {
            Text("CH \(c + 1)").font(CryoFont.mono(11.5)).foregroundStyle(Cryo.ink2).frame(width: 40, alignment: .leading)
            if track.isGroup, let m = track.members[safe: c] {
                Text(m.fromVideoFile ? "stream \(m.streamIndex + 1)" : m.url.lastPathComponent)
                    .font(CryoFont.mono(11)).foregroundStyle(Cryo.ink3).lineLimit(1).truncationMode(.middle).frame(width: 150, alignment: .leading)
                    .help(m.url.path)
            }
            Picker("", selection: $roles[c]) { ForEach(ChannelRole.allCases) { Text($0.rawValue).tag($0) } }
                .labelsHidden().frame(width: 76)
            if let g {
                let lv = Self.confidenceLevel(g.confidence)
                ZStack(alignment: .leading) {
                    Capsule().fill(Cryo.s3)
                    Capsule().fill(lv.audioTint).frame(width: 70 * CGFloat(max(0, min(1, g.confidence))))
                }
                .frame(width: 70, height: 4)
                Text(String(format: "%.0f%%", g.confidence * 100)).font(CryoFont.mono(11)).foregroundStyle(lv.audioTint).frame(width: 36, alignment: .trailing)
                VStack(alignment: .leading, spacing: 0) {
                    Text(g.why).font(CryoFont.body(11)).foregroundStyle(Cryo.ink2).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    if let f { Text(String(format: "%.0f dBFS · low %.0f%% · speech %.0f%% · high %.0f%%", f.level, f.low * 100, f.speech * 100, f.high * 100)).font(CryoFont.mono(10)).foregroundStyle(Cryo.ink3) }
                }
            } else {
                Text(track.isGroup ? (track.rolesSource ?? "not identified") + (track.channelConfidence.map { String(format: " · %.0f%% sure", $0 * 100) } ?? "") : "set by hand")
                    .font(CryoFont.body(11)).foregroundStyle(Cryo.ink3)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3).padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(AudioLook.field))
    }

    func load() {
        if let r = report, roles.isEmpty { roles = r.guesses.map(\.role) }
        else if let r = track.channelRoles, r.count == track.channels { roles = r }
        else if let p = presets.first { roles = p.order.roles }
        else { roles = (0..<track.channels).map { _ in .M } }
        loadedRoles = roles
        custom = roles
        if let t = track.channelTarget { choice = presets.first { $0.order == t }?.id ?? "custom"; custom = t.roles }
        if let text = track.channelReport, report == nil, !text.isEmpty { /* the earlier report is kept as text only */ }
    }

    func listen() {
        let group = track.isGroup ? track : nil
        guard group != nil || track.wav != nil else { problem = "Only PCM read from a WAV file can be analysed."; return }
        running = true; progress = 0; problem = nil; cancel = CancelFlag()
        let url = track.url, wav = track.wav, flag = cancel
        DispatchQueue.global(qos: .userInitiated).async {
            let r = group.map { ChannelID.analyzeGroup($0, cancel: flag) { p in DispatchQueue.main.async { progress = p } } }
                ?? ChannelID.analyze(url: url, info: wav!, cancel: flag) { p in DispatchQueue.main.async { progress = p } }
            DispatchQueue.main.async {
                running = false
                if let r { report = r; roles = r.guesses.map(\.role); if choice == "keep", let p = presets.first { custom = p.order.roles } }
                else if !flag.isSet { problem = "The track could not be analysed." }
            }
        }
    }

    func apply() {
        track.channelRoles = roles
        track.channelConfidence = heard ? report?.overall : nil
        track.channelReport = report?.text
        track.channelTarget = target
        if track.isGroup {
            if heard { track.rolesSource = "heard" }
            else if roles != loadedRoles || track.rolesSource == nil { track.rolesSource = "set by hand" }
        }
        dismiss()
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { i >= 0 && i < count ? self[i] : nil }
}
