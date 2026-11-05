// BROS-MUX Beta 2.0.0 — the pieces the old Mux screen left behind, in Cryo: the notices of a tab, the offer to join
// mono files, and the sync panel with its lights (the Audio tab's inspector). The window lives in Shell.swift, the
// seals in Cryo.swift, the output/result pieces in DeliveryParts.swift.
// Pure interface: the engine (probing, trimming, MP4Box, verification, sync) lives in BrosMux.swift.

import SwiftUI
import AppKit

// MARK: - Notices

/// Missing tools and what went wrong with the files — this tab's notices only — and, when asked, the result of the
/// last job. Nothing at all when there is nothing to say.
struct NoticeStack: View {
    @Environment(Project.self) private var project
    let tab: AppMode
    let hasResult: Bool

    init(tab: AppMode, hasResult: Bool = false) { self.tab = tab; self.hasResult = hasResult }

    var body: some View {
        let notices = project.notices(for: tab)
        if !Tools.missing.isEmpty || !notices.isEmpty || hasResult {
            VStack(spacing: 6) {
                if !Tools.missing.isEmpty {
                    AudioNoticeLine(text: "Missing tools (\(Tools.missing.joined(separator: ", "))). Run: brew install gpac media-info", level: .fail)
                }
                ForEach(notices) { n in
                    AudioNoticeLine(text: n.text, level: n.level) { project.notices.removeAll { $0.id == n.id } }
                }
                if hasResult { ResultBanner() }
            }
        }
    }
}

/// One notice: the status icon in its colour, the words in ink, on an opaque surface; × puts it away
struct AudioNoticeLine: View {
    let text: String
    var level: CheckLevel = .info
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: level.icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(level.audioTint)
            Text(text).font(CryoFont.body(12.5)).foregroundStyle(Cryo.ink)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            Spacer(minLength: 8)
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Cryo.ink3)
                }
                .buttonStyle(.plain).help("Put this notice away")
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Cryo.s1))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(level == .info ? Cryo.s3 : level.audioTint.opacity(0.35), lineWidth: 1))
    }
}

/// Empty state: symbol, one line, one action — and the drop target highlight (kept for the tools until they move to
/// CryoDropZone)
struct EmptyDropView: View {
    @Environment(Project.self) private var project
    let targeted: Bool
    let title: String
    let subtitle: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "square.and.arrow.down.on.square")
        } description: {
            Text(subtitle).frame(maxWidth: 520)
        } actions: {
            Button("Choose Files…") { project.openPanel() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            if targeted {
                RoundedRectangle(cornerRadius: DS.radius, style: .continuous)
                    .fill(Color.accentColor.opacity(0.06))
                    .overlay(RoundedRectangle(cornerRadius: DS.radius, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 2))
                    .padding(DS.margin)
            }
        }
    }
}

// MARK: - Mono files on their own

/// The owner's mono PCM files still on their own: offer to make them one multichannel track (MonoGroup.swift).
/// Only the files the owner added — the sound inside the video is grouped by itself and answered on its own row.
struct GroupOffer: View {
    @Environment(Project.self) private var project

    var body: some View {
        let c = project.groupCandidates.filter { !project.isEmbedded($0) }
        if c.count >= 2 && !project.busy {
            let problem = Track.groupProblem(c)
            let ch = Probe.channelText(c.count, nil)
            let wavs = c.allSatisfy { $0.wav != nil }
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "rectangle.split.3x1").font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(problem == nil ? Cryo.ice : Cryo.attention)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(c.count) mono \(wavs ? "WAVs" : "files") on their own").font(CryoFont.body(13).weight(.semibold)).foregroundStyle(Cryo.ink)
                    Text(problem.map { "Not joined: \($0)." } ?? "Together they are one \(ch) sound: one sync offset for all of them, one \(ch) PCM track in the file. Every sample is copied as it is.")
                        .font(CryoFont.body(11.5)).foregroundStyle(problem == nil ? Cryo.ink2 : Cryo.attention).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if problem == nil {
                    Button("Join into one \(ch)") { project.makeGroup(c.map(\.id)) }
                        .buttonStyle(CryoGoButtonStyle(.primary))
                        .help("Treat these mono files as one multichannel sound")
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Cryo.s1))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(problem == nil ? Cryo.ice.opacity(0.3) : Cryo.attention.opacity(0.4), lineWidth: 1))
        }
    }
}

// MARK: - Sync

/// Line up with the picture: pick the reference (e.g. the video's own stereo) and align the others to it
struct SyncPanel: View {
    @Environment(Project.self) private var project
    @State private var viewer: SyncViewerModel?
    @State private var picture: PictureSyncModel?

    var viewerTargets: [Track] { project.tracks.filter { $0.kind == .audio && $0.include && $0.id != project.syncReferenceID } }
    func openViewer() { if let t = viewerTargets.first { viewer = SyncViewerModel(project: project, target: t) } }

    var lateText: String {
        let f = project.referenceLateFrames
        if f == 0 { return "in sync with its picture" }
        return "\(Int(abs(f))) frame\(abs(f) == 1 ? "" : "s") \(f > 0 ? "late" : "early") vs its picture"
    }
    /// Whether the reference goes in the file too (the owner said "Use it") or only lines the others up
    var referenceInFile: Bool { project.reference?.include == true }
    var referenceSentence: String { referenceInFile ? "The reference is also in the file." : "The reference itself is not in the file." }

    var body: some View {
        @Bindable var project = project
        VStack(alignment: .leading, spacing: 8) {
            AudioSectionTitle(title: "Line up with the picture")
            AudioCard {
                VStack(alignment: .leading, spacing: 5) {
                    CryoFieldLabel("Reference")
                    Picker("", selection: $project.syncReferenceID) {
                        Text("None").tag(UUID?.none)
                        ForEach(project.audioTracks) { t in
                            Text("\(t.title) · \(t.url.lastPathComponent) · \(t.sourceLabel)").tag(UUID?.some(t.id))
                        }
                    }
                    .labelsHidden()
                    .disabled(project.busy)
                    .help("Follow the reference audio — usually the video's own stereo. The other tracks are lined up with it; " +
                          (referenceInFile ? "the reference is also in the file." : "the reference itself is not in the file."))
                    if project.reference != nil {
                        Text("The other tracks line up with it. " + referenceSentence)
                            .font(CryoFont.body(11)).foregroundStyle(Cryo.ink3).fixedSize(horizontal: false, vertical: true)
                    }
                }

                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        CryoFieldLabel("The reference is")
                        Text(lateText).font(CryoFont.body(12.5).weight(project.referenceLateFrames == 0 ? .regular : .semibold))
                            .foregroundStyle(project.referenceLateFrames == 0 ? Cryo.ink : Cryo.attention)
                    }
                    Spacer(minLength: 8)
                    Stepper("", value: $project.referenceLateFrames, in: -12...12, step: 1).labelsHidden()
                        .disabled(project.busy)
                        .help("If the video's own audio isn't in sync with its picture, enter by how many frames it's late — the alignment then follows the picture. “Picture Check…” measures this for you (hard cuts in the image vs sound hits) and can fill it in.")
                }
                if project.referenceLateFrames != 0 {
                    Text(String(format: "The tracks follow the picture: %.1f ms is added to every trim.", project.referenceOffset * 1000))
                        .font(CryoFont.body(11)).foregroundStyle(Cryo.ink2)
                }

                Toggle(isOn: $project.matchVideoEnd) {
                    Text("Audio ends with the video").font(CryoFont.body(12.5)).foregroundStyle(Cryo.ink)
                }
                .toggleStyle(CryoToggleStyle())
                .help("Trims the audio tails so they end on the last video frame")
                .disabled(project.busy)

                if project.aligning {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: project.alignProgress).tint(Cryo.ice)
                        HStack {
                            Text(project.alignStage).font(CryoFont.body(11)).foregroundStyle(Cryo.ink2).lineLimit(1)
                            Spacer()
                            Button("Stop") { project.cancelAlign() }.buttonStyle(CryoButtonStyle())
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Button { project.autoAlign() } label: {
                            Label("Line up with the picture", systemImage: "waveform.badge.magnifyingglass")
                        }
                        .buttonStyle(CryoGoButtonStyle(.primary))
                        .disabled(project.reference == nil || project.busy)
                        .help("Lines up every track in the file with the reference: finds each one's exact offset by cross-correlation and fills in the head trims")
                        HStack(spacing: 8) {
                            Button("Sync Viewer…") { openViewer() }
                                .help("See both waveforms before/after alignment, the strongest hits of the mix and the offset along the film")
                                .disabled(project.reference == nil || project.busy || viewerTargets.isEmpty)
                            Button("Picture Check…") { picture = PictureSyncModel(project: project, target: viewerTargets.first) }
                                .help("Checks the sound against the picture itself: hard cuts in the image vs sound hits, with the frames around a cut, the waveform under them and a looping preview — tells how late the reference is vs its picture")
                                .disabled(project.videoTrack == nil || project.busy || (project.reference == nil && viewerTargets.isEmpty))
                        }
                        .buttonStyle(CryoButtonStyle())
                    }
                    .sheet(item: $viewer) { SyncViewerSheet(model: $0) }
                    .sheet(item: $picture) { PictureSyncSheet(model: $0) }
                }

                ForEach(Array(project.alignLines.enumerated()), id: \.offset) { _, l in
                    let bad = l.contains("not aligned") || l.hasPrefix("Check at least")
                    AudioStatusLine(level: bad ? .warn : .ok, text: l, size: 11.5)
                }
                if !viewerTargets.isEmpty {
                    Rectangle().fill(Cryo.s3).frame(height: 1)
                    ForEach(viewerTargets) { t in SyncLights(track: t) }
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("Lines up the waveforms: slides each track's waveform against the reference's (cross-correlation) at 15 points spread evenly over the film and finds the exact offset, down to one sample. Trimming is lossless and exact: sample exact for PCM; Atmos (E-AC-3) is cut in whole 32 ms Dolby frames and the rest of the trim is a start delay in the container, so no frame is touched; a track that has to start later gets silence at the head (PCM) or a start delay in the container (Atmos). \(referenceSentence) The audio is lined up with audio; “Picture Check…” lines it up with the image (hard cuts vs sound hits), and the same check runs on the delivered file.")
                if !viewerTargets.isEmpty {
                    Text("* Tolerance: the sound may be at most 15 ms early or 45 ms late vs the picture (ATSC IS-191, the broadcast limit; viewers start to notice at about 45 ms early / 125 ms late, ITU-R BT.1359).")
                }
            }
            .font(CryoFont.body(10.5)).foregroundStyle(Cryo.ink3).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 2)
        }
    }
}

/// One track's sync: as delivered → as it will be muxed, against the tolerance (*), plus the alignment meter
struct SyncLights: View {
    @Environment(Project.self) private var project
    let track: Track
    static let early = -15.0, late = 45.0
    static func ok(_ ms: Double) -> Bool { ms >= early && ms <= late }

    var body: some View {
        let sr = track.sampleRate > 0 ? track.sampleRate : 48000
        let applied = project.plan(for: track).map { Double($0.cut - $0.pad) } ?? Double(track.trimStart)   // samples, as it will be muxed
        let before = track.syncLag.map { ($0 + project.referenceOffset) * 1000 }
        let after = track.syncLag.map { ($0 + project.referenceOffset - applied / sr) * 1000 }
        let meter = project.alignmentMeter(for: track)
        VStack(alignment: .leading, spacing: 5) {
            Text(track.title).font(CryoFont.body(12.5).weight(.semibold)).foregroundStyle(Cryo.ink).lineLimit(1)
            line(before, "as delivered")
            line(after, "as muxed")
            if let a = after {
                CryoGauge(valueMs: max(-75, min(105, a)), rangeMs: -75...105, goodMs: Self.early...Self.late, label: "AS MUXED vs THE PICTURE · −15 / +45 ms*")
            }
            if let a = after, !Self.ok(a) {
                AudioStatusLine(level: .fail, text: a < Self.early ? (track.isPCM || track.codecKey == "eac3" ? "Early: nudge it later in the Sync Viewer." : "Early: a compressed track can't be delayed without a transcode.") : "Still late: nudge it in the Sync Viewer.", size: 11)
            }
            if let m = meter {   // how much of the film this trim aligns, and where it drifts (updates as the trim is typed)
                AudioStatusLine(level: m.allAligned ? .ok : .warn, text: "Alignment meter: " + m.summary, size: 11)
                    .help(m.lines.joined(separator: "\n") + "\n" + m.note)
            }
        }
    }

    func line(_ ms: Double?, _ what: String) -> some View {
        let level: CheckLevel = ms == nil ? .info : Self.ok(ms!) ? .ok : .fail
        return AudioStatusLine(level: level, text: text(ms, what), symbol: ms == nil ? "circle.dashed" : nil, size: 11)
    }
    func text(_ ms: Double?, _ what: String) -> String {
        guard let ms else { return "\(what): not measured" }
        if abs(ms) < 0.05 { return "\(what): exact sync" }
        return String(format: "%@: %.1f ms %@ (%.2f fr) %@", what, abs(ms), ms > 0 ? "late" : "early", abs(ms) / 1000 * max(1, project.videoFPS.value), Self.ok(ms) ? "✓ inside the tolerance*" : "✗ outside the tolerance*")
    }
}
