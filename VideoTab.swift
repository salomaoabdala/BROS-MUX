// BROS-MUX Beta 2.0.0 — 01 · VIDEO: the picture, its metadata and what happens to it. Nothing runs here: the tab
// decides (COPY · bit-exact, or a TRANSCODE said out loud with source → destination and the reason) and the Delivery
// does it. A question nobody answered stays open (DECIDE), in amber, and the Delivery waits for it.

import SwiftUI
import AppKit

// MARK: - The tab

struct VideoTab: View {
    @Environment(Project.self) private var project
    let targeted: Bool
    /// A snapshot draws the window as it is: the pop-ups are drawn on their own (`--popup`), never as a sheet over it
    private static let drawingSnapshot = CommandLine.arguments.contains("--snapshot")

    var body: some View {
        let video = project.video
        VStack(spacing: 0) {
            CryoStrip(touch: video.touch(project: project), title: "VIDEO", text: video.touchText(project: project))
            if project.videoSource == nil {
                VStack(alignment: .leading, spacing: 18) {
                    VideoNoticeList(tab: .video)
                    VideoWherePlays()
                    VideoEmptyState(targeted: targeted)
                }
                .padding(.horizontal, 20).padding(.top, 16).padding(.bottom, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        VideoNoticeList(tab: .video)
                        VideoWherePlays()
                        VideoCard()
                        ForEach(video.metadataKinds(project), id: \.self) { k in VideoMetadataSlot(kind: k) }
                        VideoWhatHappens()
                    }
                    .padding(.horizontal, 20).padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .overlay {
                    if targeted {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Cryo.ice, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                            .padding(8).allowsHitTesting(false)
                    }
                }
            }
        }
        .task(id: project.videoSource?.url) { _ = VideoToolsGate.shared; video.syncPicture(project: project) }
        .sheet(isPresented: Binding(get: { !Self.drawingSnapshot && video.popup != nil }, set: { shown in
            // dismissed by the system: the same as Esc on that pop-up
            guard !shown, let p = video.popup else { return }
            if case .metadata = p { video.metadataContinue(project: project) } else { video.chooserEscape(project: project) }
        })) {
            VideoPopupHost(project: project)
        }
        .background {
            Color.clear.alert("Replace the picture?", isPresented: Binding(get: { project.pictureReplaceRequest != nil }, set: { _ in })) {
                Button("Replace", role: .destructive) { project.confirmReplacePicture() }
                Button("Cancel", role: .cancel) { project.cancelReplacePicture() }
            } message: {
                Text("The alignment of your audio will be cleared.\n\n" + (project.pictureReplaceRequest ?? []).map(\.lastPathComponent).joined(separator: ", ")
                     + (project.videoSource.map { " replaces " + $0.url.lastPathComponent + "." } ?? ""))
            }
        }
        .background {
            Color.clear.alert("Make one delivery per file with these settings?", isPresented: Binding(get: { project.batchRequest != nil }, set: { _ in })) {
                Button("Make \(project.batchRequest?.count ?? 0) Deliveries") {
                    if let urls = project.batchRequest { DeliveryQueue.shared.enqueueBatch(urls, template: project) }
                    project.batchRequest = nil
                }
                Button("Cancel", role: .cancel) { project.batchRequest = nil }
            } message: {
                let urls = project.batchRequest ?? []
                Text("\(urls.count) pictures: " + urls.prefix(6).map(\.lastPathComponent).joined(separator: ", ") + (urls.count > 6 ? "…" : "")
                     + ".\n\nEach one becomes its own delivery in the queue, with this tab's choice for the picture and your audio settings.")
            }
        }
        .overlay {
            Color.clear.allowsHitTesting(false)
                .alert("Some tracks can't go in as they are", isPresented: Binding(get: { video.containerFlip != nil }, set: { if !$0 { video.containerFlip = nil } })) {
                    Button("OK", role: .cancel) { video.containerFlip = nil }
                } message: { Text(video.containerFlip ?? "") }
        }
    }
}

/// Which pop-up is up (one at a time; the content follows `video.popup` without closing the sheet)
private struct VideoPopupHost: View {
    let project: Project
    /// The chooser asks a question (amber card) unless it was opened by hand with nothing wrong
    var asksQuestion: Bool {
        let video = project.video
        guard case .needsTranscode(let r)? = video.popup else { return false }
        return !r.isEmpty || !video.metadataKinds(project).isEmpty || video.needsReason(project) != nil
    }
    var body: some View {
        Group {
            switch project.video.popup {
            case .metadata?: VideoMetadataPopup(project: project)
            case .needsTranscode?: VideoTranscodeChooser(project: project)
            case nil: Color.clear.frame(width: 600, height: 120)
            }
        }
        .interactiveDismissDisabled(true)
        .presentationBackground(asksQuestion ? VideoTone.alertSurface : VideoTone.sheetSurface)
    }
}

// MARK: - The empty tab

private struct VideoEmptyState: View {
    @Environment(Project.self) private var project
    let targeted: Bool

    var body: some View {
        let video = project.video
        VStack(alignment: .leading, spacing: 12) {
            ForEach(video.metadataKinds(project), id: \.self) { k in
                CryoSlot {
                    HStack(spacing: 12) {
                        VideoMetadataLogo(kind: k, height: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(VideoPlanModel.kindName(k)) metadata · \(video.metadataName(k, project) ?? "")").font(CryoFont.body(13)).foregroundStyle(Cryo.ink)
                            Text("Waiting for the picture — the analysis opens as soon as it arrives.").font(CryoFont.body(11.5)).foregroundStyle(Cryo.ink2)
                        }
                        Spacer(minLength: 8)
                        Button("Remove") { video.removeMetadata(project: project) }.buttonStyle(CryoButtonStyle(tint: Cryo.ink2))
                    }
                }
            }
            if project.loadingCount > 0 {
                CryoSlot {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("Reading the picture…").font(CryoFont.body(12.5)).foregroundStyle(Cryo.ink2)
                    }
                }
            }
            CryoDropZone(title: "Drop the picture",
                         subtitle: "A master, a ProRes, an IMF package. Dolby Vision XML and HDR10+ metadata go here too.",
                         systemImage: "film", targeted: targeted) { project.openPanel() }
                .frame(maxWidth: .infinity, minHeight: 300, maxHeight: .infinity)
        }
    }
}

// MARK: - "Where will this file play?"

private struct VideoWherePlays: View {
    @Environment(Project.self) private var project

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Where will this file play?").font(CryoFont.title(14)).foregroundStyle(Cryo.ink)
                Spacer(minLength: 8)
                Text("The container decides what goes in without a transcode. You can change it later.")
                    .font(CryoFont.body(11)).foregroundStyle(Cryo.ink3).lineLimit(1).truncationMode(.tail)
            }
            CryoSegmented(selection: Binding(get: { project.container }, set: { project.video.setContainer($0, project: project) }),
                          options: [(value: Container.mov, label: "MOV — Academy, Resolve"),
                                    (value: Container.mp4, label: "MP4 — TVs and players"),
                                    (value: Container.mkv, label: "MKV — home theater, Zidoo")])
                .disabled(project.busy)
        }
    }
}

// MARK: - The picture's card

private struct VideoCard: View {
    @Environment(Project.self) private var project

    var body: some View {
        let video = project.video
        if let v = project.videoSource {
            let s = v.source
            CryoSlot {
                HStack(alignment: .top, spacing: 16) {
                    VideoThumbnail(image: video.thumbnail, label: s.flatMap { VideoFormat.middleTimecode($0, frames: project.videoFrames) },
                                   loading: video.thumbnail == nil && s != nil)
                    VStack(alignment: .leading, spacing: 8) {
                        headline(s)
                        if let s {
                            Text(VideoFormat.pictureLine(s, project: project))
                                .font(CryoFont.mono(11.5)).foregroundStyle(Cryo.ink2).textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text(v.details).font(CryoFont.mono(11.5)).foregroundStyle(Cryo.ink2).fixedSize(horizontal: false, vertical: true)
                        }
                        chips
                        if let note = VideoFormat.embeddedAudioNote(project) {
                            VideoNote(symbol: "speaker.wave.2", color: Cryo.ink2, text: note)
                        }
                        ForEach(Array(video.removedMetadata.enumerated()), id: \.offset) { _, m in
                            HStack(spacing: 10) {
                                VideoNote(symbol: "minus.circle", color: Cryo.ink2,
                                          text: "\(VideoPlanModel.kindName(m.kind)) metadata removed (\(m.url.lastPathComponent)) — it won't be in the file.")
                                Button("Put it back") { video.restoreRemovedMetadata(project: project) }
                                    .buttonStyle(CryoButtonStyle(tint: Cryo.ice)).disabled(project.busy)
                            }
                        }
                        Text(v.url.path).font(CryoFont.body(10.5)).foregroundStyle(Cryo.ink3).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    /// "You have: ProRes 4444 picture + Dolby Vision metadata (2DIE4.xml)"
    func headline(_ s: SourceVideo?) -> some View {
        let video = project.video
        var t = Text("You have: ").foregroundStyle(Cryo.ink2)
            + Text((s.map(VideoPlanModel.codecShort) ?? "a") + " picture").foregroundStyle(Cryo.ink)
        if project.hdr.imf != nil { t = t + Text(" (IMF package)").foregroundStyle(Cryo.ink2) }
        for k in video.metadataKinds(project) {
            t = t + Text(" + ").foregroundStyle(Cryo.ink3) + Text("\(VideoPlanModel.kindName(k)) metadata").foregroundStyle(Cryo.ink)
                + Text(" (\(video.metadataName(k, project) ?? ""))").foregroundStyle(Cryo.ink2)
        }
        return t.font(CryoFont.title(15)).fixedSize(horizontal: false, vertical: true)
    }

    /// The Dolby Vision / HDR10+ logos (they reopen the analysis), and what the file already says about HDR
    @ViewBuilder var chips: some View {
        let video = project.video
        let kinds = video.metadataKinds(project)
        let s = project.videoSource?.source
        if !kinds.isEmpty || (s?.isHDR ?? false) || project.hdr.imf != nil {
            HStack(spacing: 8) {
                ForEach(kinds, id: \.self) { k in
                    Button { video.present(.metadata(k)) } label: {
                        VideoMetadataLogo(kind: k, height: 12)
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(Capsule().fill(Cryo.s2))
                            .overlay(Capsule().strokeBorder(Cryo.ink3.opacity(0.5), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .help("Open the \(VideoPlanModel.kindName(k)) analysis")
                    VideoCheckCount(checks: video.checks(for: k))
                }
                if let s, s.isHDR { CryoChip("HDR · " + VideoFormat.colour(s.color), style: .plain) }
                if project.hdr.imf != nil { CryoChip("IMF", style: .plain) }
            }
        }
    }
}

/// The picture on a neutral surround: black ground, a grey ring, no ice or glass over it
struct VideoThumbnail: View {
    let image: CGImage?
    let label: String?
    var loading = false
    var width: CGFloat = 178
    var height: CGFloat = 100

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black
            if let image {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Group {
                    if loading { ProgressView().controlSize(.small) }
                    else { Image(systemName: "film").font(.system(size: 22, weight: .light)).foregroundStyle(Color(white: 0.45)) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let label {
                Text(label).font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(Color(red: 0xD9 / 255, green: 0xDD / 255, blue: 0xE1 / 255))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.65)))
                    .padding(6)
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(Color(red: 150 / 255, green: 160 / 255, blue: 170 / 255).opacity(0.35), lineWidth: 1))
        .accessibilityLabel("The picture's middle frame")
    }
}

/// "1 TO FIX" / "2 TO LOOK AT" next to a metadata logo (status colour with its word, never alone)
private struct VideoCheckCount: View {
    let checks: [MetadataCheck]
    var body: some View {
        let fails = checks.filter { $0.level == .fail }.count
        let warns = checks.filter { $0.level == .warn }.count
        if fails > 0 { CryoChip("✕ \(fails) TO FIX", style: .fail) }
        else if warns > 0 { CryoChip("⚠ \(warns) TO LOOK AT", style: .amber) }
        else if !checks.isEmpty && checks.allSatisfy({ $0.level == .ok }) { CryoChip("✓ PASS", style: .pass) }
    }
}

// MARK: - The metadata analysis, on the tab

private struct VideoMetadataSlot: View {
    @Environment(Project.self) private var project
    let kind: VideoPlanModel.MetadataKind

    var body: some View {
        let video = project.video
        let lines = video.checks(for: kind)
        CryoSlot {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 10) {
                    VideoMetadataLogo(kind: kind, height: 14)
                    Text(video.metadataName(kind, project) ?? "").font(CryoFont.mono(11.5)).foregroundStyle(Cryo.ink2)
                        .lineLimit(1).truncationMode(.middle)
                    VideoCheckCount(checks: lines)
                    Spacer(minLength: 8)
                    Button("Open the analysis…") { video.present(.metadata(kind)) }.buttonStyle(CryoButtonStyle())
                    Button("Remove the metadata") { video.removeMetadata(project: project) }
                        .buttonStyle(CryoButtonStyle(tint: Cryo.ink2)).disabled(project.busy)
                }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { c in
                        VideoCheckRow(check: c) { f in video.applyFix(f, project: project) }
                        if c.id != lines.last?.id { Rectangle().fill(Cryo.s3.opacity(0.6)).frame(height: 1) }
                    }
                }
            }
        }
    }
}

/// One line of the analysis: what was found (status icon + word), what is recommended, and the button that does it
struct VideoCheckRow: View {
    let check: MetadataCheck
    let fix: (MetadataCheck.Fix) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VideoStatusTag(level: check.level).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.title).font(CryoFont.body(12.5)).foregroundStyle(Cryo.ink)
                if !check.detail.isEmpty {
                    Text(check.detail).font(CryoFont.body(11.5)).foregroundStyle(Cryo.ink2)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let f = check.fix {
                Button { fix(f) } label: {
                    if case .copyText = f { Label(Self.title(f), systemImage: "doc.on.doc") } else { Text(Self.title(f)) }
                }
                .buttonStyle(CryoButtonStyle(tint: Self.isRemoval(f) ? Cryo.ink2 : Cryo.ice))
                .fixedSize()
            }
        }
        .padding(.vertical, 7)
    }

    static func title(_ f: MetadataCheck.Fix) -> String {
        switch f {
        case .convertGamut: return "Convert to BT.2020"
        case .keepSourcePrimaries: return "Keep source primaries"
        case .useMeasuredLight: return "Use the values measured from L1"
        case .qualityFloorOff: return "Turn the quality floor off"
        case .removeMetadata: return "Remove the metadata"
        case .copyText: return "Copy"
        }
    }
    static func isRemoval(_ f: MetadataCheck.Fix) -> Bool { if case .removeMetadata = f { return true }; return false }
}

// MARK: - What happens to the picture

private struct VideoWhatHappens: View {
    @Environment(Project.self) private var project

    var body: some View {
        let video = project.video
        VStack(alignment: .leading, spacing: 10) {
            CryoSectionHeader("What happens to the picture")
            switch video.touch(project: project) {
            case .pending: VideoPendingPanel()
            case .transcode:
                VideoTranscodeAnnouncement()
                VideoTranscodeAssets()
            default: VideoCopyPanel()
            }
        }
    }
}

private struct VideoCopyPanel: View {
    @Environment(Project.self) private var project
    var body: some View {
        CryoSlot {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        CryoLamp(Cryo.ice, size: 8)
                        Text(FileTouch.copy.word).font(CryoFont.label(12)).tracking(1).foregroundStyle(Cryo.ice)
                    }
                    Text("The picture goes into the file bit for bit — not a single pixel changes.")
                        .font(CryoFont.body(13)).foregroundStyle(Cryo.ink)
                    CryoSignalLine(touch: .copy).frame(maxWidth: 260)
                }
                Spacer(minLength: 12)
                Button("Transcode the picture…") { project.video.openChooser(project: project) }
                    .buttonStyle(CryoButtonStyle()).disabled(project.busy)
            }
        }
    }
}

/// DECIDE: the question is open; the two ways out are right here
private struct VideoPendingPanel: View {
    @Environment(Project.self) private var project
    var body: some View {
        let video = project.video
        let hasMetadata = !video.metadataKinds(project).isEmpty && video.choice(project) != .hevcHDR
        let proresContainer = !hasMetadata && project.container != .mov && video.containerProblem(project) != nil
            && video.containerProblem(project, container: .mov) == nil
        VideoAmberPanel {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Cryo.attention)
                Text(FileTouch.pending.word).font(CryoFont.label(12)).tracking(1).foregroundStyle(Cryo.attention)
                Text("a decision is open").font(CryoFont.body(12)).foregroundStyle(Cryo.ink2)
            }
            Text(video.needsReason(project) ?? "The picture's destination isn't decided yet.")
                .font(CryoFont.body(13.5)).foregroundStyle(Cryo.ink).fixedSize(horizontal: false, vertical: true)
            Text("The Delivery won't start until you decide.").font(CryoFont.body(11.5)).foregroundStyle(Cryo.ink2)
            HStack(spacing: 10) {
                Button(hasMetadata ? "Transcode to embed it…" : "Transcode the picture…") { video.openChooser(project: project) }
                    .buttonStyle(CryoGoButtonStyle(.amber))
                if hasMetadata {
                    Button("Remove the metadata") { video.removeMetadata(project: project) }.buttonStyle(CryoGoButtonStyle(.ghost))
                } else if proresContainer {
                    Button("Use MOV instead") { video.setContainer(.mov, project: project) }.buttonStyle(CryoGoButtonStyle(.ghost))
                }
            }
            .disabled(project.busy)
        }
    }
}

/// TRANSCODE, said out loud: source → destination and the reason, on an opaque amber surface
private struct VideoTranscodeAnnouncement: View {
    @Environment(Project.self) private var project
    var body: some View {
        let video = project.video
        let s = video.source(project)
        let plan = video.choice(project) == .hevcHDR ? video.hevcPreviewPlan(project) : video.transcodePlan(project: project)
        let metadata = !video.metadataKinds(project).isEmpty
        VideoAmberPanel {
            HStack(spacing: 8) {
                CryoLamp(Cryo.attention, size: 8)
                Text(FileTouch.transcode.word).font(CryoFont.label(12)).tracking(1).foregroundStyle(Cryo.attention)
                Text("the picture is encoded again — a new picture is written; the source file is never touched")
                    .font(CryoFont.body(11.5)).foregroundStyle(Cryo.ink2).lineLimit(2)
                Spacer(minLength: 8)
                Button("Change…") { video.openChooser(project: project) }.buttonStyle(CryoButtonStyle()).disabled(project.busy)
            }
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    CryoFieldLabel("Source")
                    Text(s.map { VideoFormat.sourceShort($0) } ?? "—").font(CryoFont.body(13.5).weight(.semibold)).foregroundStyle(Cryo.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Image(systemName: "arrow.right").font(.system(size: 15, weight: .semibold)).foregroundStyle(Cryo.attention).padding(.top, 16)
                VStack(alignment: .leading, spacing: 3) {
                    CryoFieldLabel("Destination")
                    Text(plan.map { VideoFormat.destinationShort($0, project: project) } ?? video.outputLabel(project))
                        .font(CryoFont.body(13.5).weight(.semibold)).foregroundStyle(Cryo.attention).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            Text((video.choice(project) == .hevcHDR ? video.hevcReason(project) : "You chose it") + ".")
                .font(CryoFont.body(12.5)).foregroundStyle(Cryo.ink).fixedSize(horizontal: false, vertical: true)
            if video.copyProblem(project) == nil {
                Button(metadata ? "Keep the picture as it is (removes the metadata)" : "Keep the picture as it is (COPY)") {
                    if metadata { video.removeMetadata(project: project, announce: false) }
                    video.choose(.copy, project: project)
                }
                .buttonStyle(CryoButtonStyle(tint: Cryo.ink2)).disabled(project.busy)
            }
        }
    }
}

/// The transcode's own settings, right under the announcement: preset, mode, speed, floor, Source → Destination,
/// size and time (no quality scores here)
private struct VideoTranscodeAssets: View {
    @Environment(Project.self) private var project

    var body: some View {
        let video = project.video
        CryoSlot {
            VStack(alignment: .leading, spacing: 16) {
                switch video.choice(project) {
                case .hevcHDR: hevcSettings
                case .transcode(let s): sdrSettings(s)
                case .copy: EmptyView()
                }
                if let plan = video.choice(project) == .hevcHDR ? video.hevcPreviewPlan(project) : video.transcodePlan(project: project) {
                    VStack(alignment: .leading, spacing: 8) {
                        CryoSectionHeader("Source → destination")
                        CryoDiffTable(rows: VideoFormat.diffRows(plan, project: project))
                        HStack(spacing: 14) {
                            HStack(spacing: 5) { Circle().fill(Cryo.attention).frame(width: 6, height: 6); Text("changes") }
                            HStack(spacing: 5) { Circle().fill(Cryo.ink3).frame(width: 6, height: 6); Text("preserved") }
                        }
                        .font(CryoFont.body(10.5)).foregroundStyle(Cryo.ink3)
                    }
                    if !VideoToolsGate.shared.ready {
                        VideoToolsWaiting()
                    } else {
                    VideoEstimate(plan: plan, hevc: video.choice(project) == .hevcHDR)
                    let warnings = VideoFormat.warnings(plan, project: project)
                    if !warnings.isEmpty || plan.problem != nil {
                        VStack(alignment: .leading, spacing: 6) {
                            if let p = plan.problem { VideoNote(symbol: "xmark.octagon.fill", color: Cryo.fail, text: p, word: "FAIL") }
                            ForEach(warnings, id: \.self) { w in VideoNote(symbol: "exclamationmark.triangle.fill", color: Cryo.attention, text: w) }
                        }
                    }
                    }
                }
            }
        }
    }

    @ViewBuilder var hevcSettings: some View {
        @Bindable var hdr = project.hdr
        let video = project.video
        VStack(alignment: .leading, spacing: 14) {
            CryoSectionHeader("HEVC 10-bit · x265")
            RateControlRows(hdr: hdr, showsQuality: true, disabled: project.busy)
            VideoSpeedRow(speed: $hdr.speed, disabled: project.busy, hdrMetadata: true, encoder: "x265")
            if let plan = video.hevcPreviewPlan(project), let from = plan.gamutConversion ?? (plan.gamutWarning != nil ? plan.source.color.primaries : nil) {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: $hdr.convertGamut) {
                        Text("Convert \(ColorLUT.label(from)) → BT.2020 (recommended)").font(CryoFont.body(12.5)).foregroundStyle(Cryo.ink)
                    }
                    .toggleStyle(CryoToggleStyle()).disabled(project.busy)
                    Text(plan.gamutWarning ?? "HDR10 and Dolby Vision streams are BT.2020: the picture is converted in linear light; the colours don't change, and your master isn't touched.")
                        .font(CryoFont.body(11)).foregroundStyle(plan.gamutWarning == nil ? Cryo.ink2 : Cryo.attention).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder func sdrSettings(_ s: VideoTranscodeSettings) -> some View {
        let video = project.video
        let preset = TranscodePreset(rawValue: s.preset) ?? .prores422HQ
        let src = video.source(project)
        let ready = VideoToolsGate.shared.ready
        let canToneMap = ready && Tools.canToneMap
        VStack(alignment: .leading, spacing: 14) {
            CryoSectionHeader(VideoPlanModel.presetTitle(preset))
            VStack(alignment: .leading, spacing: 6) {
                CryoFieldLabel("Resolution")
                VideoPickChips(selection: Binding(get: { OutputResolution(rawValue: s.resolution) ?? .same },
                                                  set: { r in video.updateTranscode(project: project) { $0.resolution = r.rawValue } }),
                               options: OutputResolution.allCases.map { (value: $0, label: $0.label) }, disabled: project.busy)
            }
            if let src, src.isHDR {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(isOn: Binding(get: { s.toneMap }, set: { v in video.updateTranscode(project: project) { $0.toneMap = v } })) {
                        Text("Tone map HDR → SDR (BT.709)").font(CryoFont.body(12.5)).foregroundStyle(Cryo.ink)
                    }
                    .toggleStyle(CryoToggleStyle()).disabled(project.busy || !canToneMap)
                    Text(!ready ? "Checking what this Mac's ffmpeg can do…"
                         : canToneMap ? "zscale + tonemap (hable): for review copies and SDR deliveries from an HDR master. Off: the HDR (PQ) colour is kept, without HDR10 metadata."
                                      : "Not available: this ffmpeg has no zscale filter (libzimg). Install ffmpeg with zimg to tone map.")
                        .font(CryoFont.body(11)).foregroundStyle(!ready || canToneMap ? Cryo.ink2 : Cryo.attention).fixedSize(horizontal: false, vertical: true)
                }
            }
            switch preset {
            case .prores422HQ, .prores422:
                Text("ProRes has no quality setting: the profile is the quality." + (!ready ? "" : " Encoder: " + (Tools.proresEncoder == "prores_videotoolbox" ? "Apple VideoToolbox (the ProRes hardware of the M chips)." : "ffmpeg prores_ks.")))
                    .font(CryoFont.body(11)).foregroundStyle(Cryo.ink2).fixedSize(horizontal: false, vertical: true)
            case .hevcSDR:
                @Bindable var hdr = project.hdr
                RateControlRows(hdr: hdr, showsQuality: false, disabled: project.busy)
                if hdr.rateMode == .quality { qualityRow(s, fallback: .high) }
                VideoSpeedRow(speed: Binding(get: { s.speed.flatMap(HDRSettings.Speed.init(rawValue:)) ?? .medium },
                                             set: { v in video.updateTranscode(project: project) { $0.speed = v.rawValue } }),
                              disabled: project.busy, hdrMetadata: false, encoder: "x265")
            default:
                qualityRow(s, fallback: .high)
                VideoSpeedRow(speed: Binding(get: { s.speed.flatMap(HDRSettings.Speed.init(rawValue:)) ?? .fast },
                                             set: { v in video.updateTranscode(project: project) { $0.speed = v.rawValue } }),
                              disabled: project.busy, hdrMetadata: false, encoder: "x264")
            }
        }
    }

    func qualityRow(_ s: VideoTranscodeSettings, fallback: HDRSettings.Quality) -> some View {
        let video = project.video
        let q = s.quality.flatMap(HDRSettings.Quality.init(rawValue:)) ?? fallback
        return VStack(alignment: .leading, spacing: 6) {
            CryoFieldLabel("Quality")
            VideoPickChips(selection: Binding(get: { q }, set: { v in video.updateTranscode(project: project) { $0.quality = v.rawValue } }),
                           options: HDRSettings.Quality.allCases.map { (value: $0, label: $0.label) }, disabled: project.busy)
            Text(q.detail).font(CryoFont.body(11)).foregroundStyle(Cryo.ink2).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Speed of the encoder; Draft is Apple's hardware encoder, which can't write HDR metadata
struct VideoSpeedRow: View {
    @Binding var speed: HDRSettings.Speed
    let disabled: Bool
    let hdrMetadata: Bool
    var encoder = "x265"

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CryoFieldLabel("Speed")
            VideoPickChips(selection: $speed, options: HDRSettings.Speed.allCases.map { (value: $0, label: $0.label) }, disabled: disabled)
            if speed == .draft {
                VideoNote(symbol: "exclamationmark.triangle.fill", color: Cryo.attention,
                          text: hdrMetadata ? "Draft uses Apple's hardware encoder (VideoToolbox): it can't write the HDR10 / Dolby Vision metadata — not for delivery."
                                            : "Draft uses Apple's hardware encoder (VideoToolbox): fast, bigger files, not for delivery.")
            } else {
                Text("\(encoder) preset “\(speed.preset)”" + (encoder == "x265" ? " · about \(Int(speed.fps4K.rounded())) frames per second at 4K on this Mac (rough)." : "."))
                    .font(CryoFont.body(11)).foregroundStyle(Cryo.ink2)
            }
        }
    }
}

/// Size and time, rough
private struct VideoEstimate: View {
    let plan: TranscodePlan
    let hevc: Bool
    var body: some View {
        HStack(spacing: 22) {
            VStack(alignment: .leading, spacing: 2) {
                CryoFieldLabel("Picture size")
                Text("~" + Fmt.bytes(plan.estimatedBytes)).font(CryoFont.mono(13)).foregroundStyle(Cryo.ink)
            }
            VStack(alignment: .leading, spacing: 2) {
                CryoFieldLabel("Time on this Mac")
                Text("about " + Fmt.hm(plan.estimatedSeconds)).font(CryoFont.mono(13)).foregroundStyle(Cryo.ink)
            }
            VStack(alignment: .leading, spacing: 2) {
                CryoFieldLabel("Average bitrate")
                Text("~" + VideoFormat.mbps(plan.estimatedBytes * 8 / max(plan.seconds, 0.001))).font(CryoFont.mono(13)).foregroundStyle(Cryo.ink)
            }
            Spacer(minLength: 0)
        }
        .overlay(alignment: .bottomLeading) { EmptyView() }
        .help(hevc ? "Rough: an encode like this can run overnight — the Mac won't sleep while the Delivery renders." : "Rough estimate.")
    }
}

// MARK: - Notices of this tab

private struct VideoNoticeList: View {
    @Environment(Project.self) private var project
    let tab: AppMode

    var body: some View {
        let notices = project.notices(for: tab)
        if !notices.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(notices) { n in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        VideoStatusTag(level: n.level)
                        Text(n.text).font(CryoFont.body(12)).foregroundStyle(Cryo.ink).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button { project.notices.removeAll { $0.id == n.id } } label: {
                            Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                        }
                        .buttonStyle(.plain).foregroundStyle(Cryo.ink3).help("Dismiss")
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(n.level == .warn ? VideoTone.amberSurface : Cryo.s1))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(VideoStatus.color(n.level).opacity(0.35), lineWidth: 1))
                }
            }
        }
    }
}

// MARK: - The pop-ups

/// The Dolby Vision / HDR10+ analysis: each line DETECTED → RECOMMENDED → its button; "Continue" goes on
struct VideoMetadataPopup: View {
    let project: Project
    init(project: Project) { self.project = project }

    var body: some View {
        let video = project.video
        let kind: VideoPlanModel.MetadataKind = {
            if case .metadata(let k)? = video.popup { return k }
            return project.hdr.dvSource == nil && project.hdr.hdr10plusJSON != nil ? .hdr10Plus : .dolbyVision
        }()
        let lines = video.checks(for: kind)
        let fails = lines.filter { $0.level == .fail }.count
        let warns = lines.filter { $0.level == .warn }.count
        let name = video.metadataName(kind, project) ?? "—"
        let s = video.source(project)
        VideoPopupCard(attention: false,
                       logo: AnyView(VideoMetadataLogo(kind: kind, height: 22)),
                       title: kind == .dolbyVision ? "Dolby Vision metadata" : "HDR10+ metadata",
                       subtitle: name + (s.map { " · for the picture \(VideoPlanModel.codecShort($0)) · \($0.sizeText) · \($0.fpsText) fps · \(Fmt.int(project.videoFrames > 0 ? project.videoFrames : $0.frames)) frames" } ?? " · waiting for the picture")) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    CryoFieldLabel("Detected")
                    Spacer()
                    CryoFieldLabel("Recommended")
                }
                .padding(.bottom, 4)
                if lines.isEmpty {
                    Text("Nothing to analyse yet.").font(CryoFont.body(12)).foregroundStyle(Cryo.ink2).padding(.vertical, 8)
                }
                ForEach(lines) { c in
                    VideoCheckRow(check: c) { f in video.applyFix(f, project: project) }
                    if c.id != lines.last?.id { Rectangle().fill(Cryo.s3.opacity(0.6)).frame(height: 1) }
                }
            }
            HStack(spacing: 8) {
                if fails > 0 {
                    VideoNote(symbol: "xmark.octagon.fill", color: Cryo.fail, text: "\(fails == 1 ? "1 problem stops" : "\(fails) problems stop") the Delivery until it's fixed.", word: "FAIL")
                } else if warns > 0 {
                    VideoNote(symbol: "exclamationmark.triangle.fill", color: Cryo.attention, text: "Nothing stops the Delivery; \(warns == 1 ? "1 thing" : "\(warns) things") to look at.")
                } else if lines.contains(where: { $0.level == .ok }) && s != nil && !project.hdr.dvChecking {
                    // a PASS only for what was really checked (INFO lines alone say nothing about it)
                    VideoNote(symbol: "checkmark.circle.fill", color: Cryo.pass, text: "Nothing stops the Delivery.", word: "PASS")
                }
            }
            VideoRecommendation(text: recommendation(kind))
        } buttons: {
            Button("Remove the metadata") { video.removeMetadata(project: project) }.buttonStyle(CryoGoButtonStyle(.ghost))
            Spacer(minLength: 8)
            Button("Continue") { video.metadataContinue(project: project) }
                .buttonStyle(CryoGoButtonStyle(.primary)).keyboardShortcut(.defaultAction)
        }
        .background { VideoEscapeKey { video.metadataContinue(project: project) } }
    }

    func recommendation(_ kind: VideoPlanModel.MetadataKind) -> String {
        let video = project.video
        if video.choice(project) == .hevcHDR {
            return "It goes into the file: \(video.outputLabel(project)) (x265). You'll see the encode settings on the Video tab."
        }
        let what = VideoPlanModel.kindName(kind)
        return "Transcode the picture to HEVC 10-bit · \(kind == .dolbyVision ? "Dolby Vision 8.1 + HDR10" : "HDR10 + HDR10+") — the only way the \(what) metadata goes into the file. “Continue” asks you."
    }
}

/// "ProRes 4444 can't carry Dolby Vision. To embed it, the picture must be transcoded." — the destination KINDS,
/// each with its reason when it isn't possible, and the ways to deliver without the metadata. Esc leaves it pending.
struct VideoTranscodeChooser: View {
    let project: Project
    init(project: Project) { self.project = project }

    var body: some View {
        let video = project.video
        let kinds = video.metadataKinds(project)
        let reason: String = {
            if case .needsTranscode(let r)? = video.popup, !r.isEmpty { return r }
            return video.needsReason(project) ?? ""
        }()
        Group {
            if !kinds.isEmpty { metadataChooser(reason: video.carryReason(project) ?? reason, kinds: kinds) } else { plainChooser(reason: reason) }
        }
        .background { VideoEscapeKey { video.chooserEscape(project: project) } }
    }

    // the picture can't carry the metadata: transcode to embed it, or deliver without it
    func metadataChooser(reason: String, kinds: [VideoPlanModel.MetadataKind]) -> some View {
        let video = project.video
        let targets = video.legalTargets(project: project)
        let what = video.metadataWhat(project)
        let hevc = targets.first { $0.id == "hevcHDR" }
        let apple = targets.first { $0.id == "appleHardware" }
        let s = video.source(project)
        let parts = VideoFormat.splitReason(reason)
        let ready = VideoToolsGate.shared.ready
        let estimate = ready ? (video.hevcPreviewPlan(project).map { " About \(Fmt.hm($0.estimatedSeconds)) of encoding on this Mac (rough)." } ?? "") : ""
        return VideoPopupCard(attention: true, logo: nil, title: parts.title, subtitle: parts.rest) {
            VStack(alignment: .leading, spacing: 8) {
                CryoFieldLabel("To embed it")
                if let hevc {
                    VideoOptionRow(title: hevc.title, detail: hevc.detail + estimate, recommended: hevc.problem == nil,
                                   problem: hevc.problem, action: video.choice(project) == .hevcHDR ? "Chosen — keep it" : "Transcode to embed it",
                                   primary: true, waiting: !ready) {
                        video.choose(.hevcHDR, project: project)
                    }
                }
                if let apple {
                    VideoOptionRow(title: "Apple hardware (VideoToolbox)", detail: apple.detail, recommended: false,
                                   problem: "Not possible: it can't write the HDR10 / Dolby Vision metadata.", action: "", primary: false) {}
                }
                Text("No other format can carry \(what) in this app (ProRes and H.264 can't).")
                    .font(CryoFont.body(11.5)).foregroundStyle(Cryo.ink2).padding(.leading, 2)
            }
            VStack(alignment: .leading, spacing: 8) {
                CryoFieldLabel("Deliver without \(what)")
                Text("Each of these removes the metadata from the delivery — the card will say so, and can put it back.")
                    .font(CryoFont.body(11.5)).foregroundStyle(Cryo.ink2)
                let hq = targets.first { $0.id == TranscodePreset.prores422HQ.rawValue }
                VideoOptionRow(title: "Apple ProRes 422 HQ", detail: (s?.isHDR ?? false) ? "A master or archive copy in MOV; it keeps the HDR (PQ) colour." : "What the Academy asks for (MOV).",
                               recommended: false, problem: hq?.problem, action: "Choose", primary: false, waiting: !ready) {
                    video.removeMetadata(project: project, announce: false)
                    video.choose(.transcode(VideoTranscodeSettings(preset: TranscodePreset.prores422HQ.rawValue)), project: project)
                }
                let hdr10Problem: String? = (s?.isHDR ?? false) || project.hdr.imf != nil ? nil : "The picture isn't HDR (no PQ / HLG): there is nothing for HDR10 to describe."
                VideoOptionRow(title: "HEVC 10-bit · HDR10, without \(what)", detail: "Plays everywhere HDR10 plays; the dynamic metadata is left out.",
                               recommended: false, problem: hdr10Problem, action: "Choose", primary: false) {
                    video.removeMetadata(project: project, announce: false)
                    video.choose(.hevcHDR, project: project)
                }
                VideoOptionRow(title: "Keep the picture as it is (COPY · bit-exact)", detail: "Not a single pixel changes; the metadata isn't in the file.",
                               recommended: false, problem: video.copyProblem(project), action: "Choose", primary: false) {
                    video.removeMetadata(project: project, announce: false)
                    video.choose(.copy, project: project)
                }
            }
        } buttons: {
            Text("Esc leaves it to decide later — the Delivery won't start until you do.")
                .font(CryoFont.body(11)).foregroundStyle(Cryo.ink3)
            Spacer(minLength: 8)
            Button("Decide later") { video.chooserEscape(project: project) }.buttonStyle(CryoGoButtonStyle(.ghost))
        }
    }

    // no metadata: every destination this picture can take, with the reason when it can't
    func plainChooser(reason: String) -> some View {
        let video = project.video
        let s = video.source(project)
        let targets = video.legalTargets(project: project)
        let current = video.choice(project)
        let parts = VideoFormat.splitReason(reason)
        let title = reason.isEmpty ? "Transcode the picture" : parts.title
        let sub = (parts.rest.map { $0 + " " } ?? "")
            + (s.map { "\(VideoPlanModel.codecShort($0)) · \($0.sizeText) · \(VideoFormat.colour($0.color)). " } ?? "")
            + "The source file is never touched — a new picture is written."
        return VideoPopupCard(attention: !reason.isEmpty, logo: nil, title: title, subtitle: sub) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(targets) { t in
                    VideoOptionRow(title: t.title, detail: t.detail, recommended: t.recommended, problem: t.problem,
                                   action: t.choice == .copy ? "Keep" : (t.choice == current ? "Chosen" : "Transcode"),
                                   primary: t.recommended, waiting: t.choice != .copy && !VideoToolsGate.shared.ready) {
                        video.choose(t.choice, project: project)
                    }
                }
            }
        } buttons: {
            if !reason.isEmpty {
                Text("Esc leaves it to decide later — the Delivery won't start until you do.").font(CryoFont.body(11)).foregroundStyle(Cryo.ink3)
            }
            Spacer(minLength: 8)
            Button(reason.isEmpty ? "Cancel" : "Decide later") { video.chooserEscape(project: project) }.buttonStyle(CryoGoButtonStyle(.ghost))
        }
    }
}

/// The pop-up's card (the alert chrome of A · CRYO: 600 wide, radius 26, an amber ring when it asks a question)
struct VideoPopupCard<Content: View, Buttons: View>: View {
    let attention: Bool
    let logo: AnyView?
    let title: String
    let subtitle: String?
    @ViewBuilder let content: () -> Content
    @ViewBuilder let buttons: () -> Buttons

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 16) {
                if attention {
                    ZStack {
                        RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Cryo.attention.opacity(0.14))
                        RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(Cryo.attention.opacity(0.55), lineWidth: 1)
                        Image(systemName: "exclamationmark.triangle").font(.system(size: 20, weight: .semibold)).foregroundStyle(Cryo.attention)
                    }
                    .frame(width: 46, height: 46)
                }
                VStack(alignment: .leading, spacing: 8) {
                    if let logo { logo.padding(.bottom, 4) }
                    Text(title).font(CryoFont.title(19)).foregroundStyle(Cryo.ink).fixedSize(horizontal: false, vertical: true)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(CryoFont.body(13)).foregroundStyle(Cryo.ink2).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            content()
            HStack(alignment: .center, spacing: 10) { buttons() }
        }
        .padding(EdgeInsets(top: 24, leading: 24, bottom: 20, trailing: 24))
        .frame(width: 600, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(attention ? VideoTone.alertSurface : VideoTone.sheetSurface))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous)
            .strokeBorder(attention ? Cryo.attention.opacity(0.30) : Cryo.ice.opacity(0.14), lineWidth: 1))
    }
}

/// One destination in the chooser: what it is, why (or why not), and its button
struct VideoOptionRow: View {
    let title: String
    let detail: String
    let recommended: Bool
    let problem: String?
    let action: String
    let primary: Bool
    var waiting = false              // what this Mac's ffmpeg can do isn't known yet
    let run: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title).font(CryoFont.body(13).weight(.semibold)).foregroundStyle(problem == nil ? Cryo.ink : Cryo.ink3)
                    if recommended && problem == nil { CryoChip("RECOMMENDED", style: .lit) }
                }
                Text(problem ?? detail).font(CryoFont.body(11.5)).foregroundStyle(problem == nil ? Cryo.ink2 : Cryo.ink3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if waiting && problem == nil && !action.isEmpty {
                ProgressView().controlSize(.small)
            } else if problem == nil && !action.isEmpty {
                Button(action, action: run).buttonStyle(CryoGoButtonStyle(primary ? .primary : .ghost)).fixedSize()
            } else if problem != nil {
                HStack(spacing: 4) {
                    Image(systemName: "nosign")
                    Text("NOT POSSIBLE").tracking(0.8)
                }
                .font(CryoFont.label(9.5)).foregroundStyle(Cryo.ink3).fixedSize()
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(recommended && problem == nil ? Cryo.ice.opacity(0.06) : Cryo.s0.opacity(0.55)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(recommended && problem == nil ? Cryo.ice.opacity(0.28) : Cryo.s3, lineWidth: 1))
    }
}

/// While the Mac's ffmpeg is asked what it can do (once, a second or so)
private struct VideoToolsWaiting: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Checking what this Mac's ffmpeg can do…").font(CryoFont.body(11.5)).foregroundStyle(Cryo.ink2)
        }
    }
}

/// The cyan RECOMMENDED box of a pop-up
private struct VideoRecommendation: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lightbulb").font(.system(size: 14, weight: .semibold)).foregroundStyle(Cryo.ice).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                CryoFieldLabel("Recommended")
                Text(text).font(CryoFont.body(12.5)).foregroundStyle(Cryo.ink).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Cryo.ice.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Cryo.ice.opacity(0.22), lineWidth: 1))
    }
}

/// Esc on a pop-up (the sheet itself can't be dismissed any other way)
private struct VideoEscapeKey: View {
    let run: () -> Void
    var body: some View {
        Button("", action: run).keyboardShortcut(.cancelAction).opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
    }
}

// MARK: - Inspector

struct VideoInspector: View {
    @Environment(Project.self) private var project
    init() {}

    var body: some View {
        @Bindable var project = project
        let video = project.video
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let v = project.videoSource {
                    VStack(alignment: .leading, spacing: 8) {
                        CryoSectionHeader("The picture")
                        if let s = v.source {
                            VideoKV("File", v.url.lastPathComponent)
                            VideoKV("Codec", s.codecName + (s.profile.map { s.codecName.contains($0) ? "" : " · \($0)" } ?? ""))
                            VideoKV("Size", s.sizeText + (s.sar.map { $0 == "1:1" || $0 == "0:1" ? "" : " · SAR \($0)" } ?? ""))
                            VideoKV("Frame rate", "\(s.fpsText) fps · \(Fmt.int(project.videoFrames > 0 ? project.videoFrames : s.frames)) frames")
                            VideoKV("Duration", Fmt.duration(project.videoDuration > 0 ? project.videoDuration : s.duration))
                            VideoKV("Bits · chroma", "\(s.bitDepth)-bit · \(s.chroma)" + (s.hasAlpha ? " + alpha" : ""))
                            VideoKV("Colour", s.color.isTagged ? s.color.text : "untagged")
                            VideoKV("HDR", s.hdrFormat ?? (s.color.isHDR ? s.color.short + " (no static metadata)" : "SDR"))
                            VideoKV("Timecode", s.timecode ?? "none")
                            VideoKV("Bitrate", s.bitRate > 0 ? VideoFormat.mbps(s.bitRate) : "—")
                            if let f = s.fieldOrder, f != "progressive", f != "unknown" { VideoKV("Scan", "interlaced (\(f))") }
                        } else {
                            VideoKV("File", v.url.lastPathComponent)
                            Text(v.details).font(CryoFont.mono(11)).foregroundStyle(Cryo.ink2)
                        }
                    }
                } else {
                    Text("No picture yet. Drop it on the Video tab.").font(CryoFont.body(12)).foregroundStyle(Cryo.ink2)
                }

                if showsHDR10 {
                    VStack(alignment: .leading, spacing: 8) {
                        CryoSectionHeader("HDR10 · static metadata")
                        VideoKV("Mastering", project.hdr.mastering.text)
                        VideoKV("MaxCLL", "\(project.hdr.maxCLL) nits")
                        VideoKV("MaxFALL", "\(project.hdr.maxFALL) nits")
                        Text(project.hdr.masteringSource).font(CryoFont.body(11)).foregroundStyle(project.hdr.masteringSource.contains("defaults") ? Cryo.attention : Cryo.ink3)
                    }
                }

                if project.videoSource != nil {
                    VStack(alignment: .leading, spacing: 8) {
                        CryoSectionHeader("Where it plays")
                        if outputPlaysHDR {
                            let audio = project.outputAudio
                            let hdrFormat = video.source(project)?.hdrFormat ?? ""
                            let encode = video.choice(project) == .hevcHDR
                            PlaybackRows(dolbyVision: encode ? project.hdr.dvSource != nil : hdrFormat.contains("Dolby Vision"),
                                         hdr10plus: encode ? project.hdr.hdr10plusJSON != nil : hdrFormat.contains("2094"),
                                         atmosDDP: audio.contains { $0.codecKey == "eac3" && $0.isAtmos },
                                         trueHD: audio.contains { $0.codecKey == "truehd" || $0.codecKey == "mlp" },
                                         mkv: project.container == .mkv)
                            Text("Not for the Academy: it asks for SDR (ProRes 422 HQ / H.264).").font(CryoFont.body(11)).foregroundStyle(Cryo.ink3)
                        } else if outputIsHDR {
                            Text("An HDR master (\(video.source(project).map(VideoPlanModel.codecShort) ?? "this codec")): it plays in Resolve and in QuickTime on a Mac, not on TVs or Apple TV. For those, transcode it to HEVC 10-bit HDR.")
                                .font(CryoFont.body(11.5)).foregroundStyle(Cryo.ink2).fixedSize(horizontal: false, vertical: true)
                        } else {
                            Text("An SDR picture: the Delivery predicts the Academy seal of the whole file.")
                                .font(CryoFont.body(11.5)).foregroundStyle(Cryo.ink2).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if project.videoSource != nil {
                VStack(alignment: .leading, spacing: 8) {
                    CryoSectionHeader("Colour tag")
                    Toggle(isOn: $project.fixColorTag) {
                        Text("Fix the colour tag (nclc) on import").font(CryoFont.body(12.5)).foregroundStyle(Cryo.ink)
                    }
                    .toggleStyle(CryoToggleStyle())
                    .disabled(project.busy || video.choice(project) != .copy)
                    Text(video.choice(project) == .copy
                         ? "Tags the picture BT.709 in the container (fixes Resolve's “Rec.709-A / Gamma 2.4”). Only the tag changes — the pixels stay identical. The Academy requires the BT.709 transfer; QuickTime Player may show the picture slightly brighter."
                         : "Only for COPY: a transcode writes its own colour tags.")
                        .font(CryoFont.body(11)).foregroundStyle(Cryo.ink2).fixedSize(horizontal: false, vertical: true)
                }
                }

                if project.hdrRelevant || video.choice(project) == .hevcHDR || !video.metadataKinds(project).isEmpty
                    || (project.videoSource?.source?.isHDR ?? false) {
                    HDRPanel()
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var showsHDR10: Bool {
        project.video.choice(project) == .hevcHDR || (project.videoSource?.source?.isHDR ?? false) || project.hdr.dvSource != nil
    }
    /// An HDR file that players open: the HEVC HDR transcode, or a copy of an HEVC / H.264 HDR picture
    var outputPlaysHDR: Bool {
        switch project.video.choice(project) {
        case .hevcHDR: return true
        case .copy: return outputIsHDR && ["hevc", "h264"].contains(project.videoSource?.codecKey ?? "")
        case .transcode: return false
        }
    }
    var outputIsHDR: Bool {
        switch project.video.choice(project) {
        case .hevcHDR: return true
        case .copy: return project.videoSource?.source?.isHDR ?? false
        case .transcode(let s): return !s.toneMap && (project.videoSource?.source?.isHDR ?? false)
        }
    }
}

// MARK: - Small pieces (Video's own; Cryo tokens only)

enum VideoTone {
    /// Opaque amber-dark: the surface of every TRANSCODE / DECIDE announcement (ink on it is high contrast)
    static let amberSurface = Color(.sRGB, red: 0x1F / 255, green: 0x18 / 255, blue: 0x0E / 255, opacity: 1)
    /// The alert surface of A · CRYO (#191611 → #0A0C10, flattened)
    static let alertSurface = Color(.sRGB, red: 0x15 / 255, green: 0x13 / 255, blue: 0x10 / 255, opacity: 1)
    /// The sheet surface of A · CRYO (#0E1A26 → #060C12, flattened)
    static let sheetSurface = Color(.sRGB, red: 0x0B / 255, green: 0x15 / 255, blue: 0x1F / 255, opacity: 1)
}

/// Status colour, icon and word (the colour never alone)
enum VideoStatus {
    static func color(_ l: CheckLevel) -> Color {
        switch l { case .ok: return Cryo.pass; case .warn: return Cryo.attention; case .fail: return Cryo.fail; case .info: return Cryo.info }
    }
    static func icon(_ l: CheckLevel) -> String {
        switch l { case .ok: return "checkmark.circle.fill"; case .warn: return "exclamationmark.triangle.fill"; case .fail: return "xmark.octagon.fill"; case .info: return "info.circle" }
    }
    static func word(_ l: CheckLevel) -> String {
        switch l { case .ok: return "PASS"; case .warn: return "ATTENTION"; case .fail: return "FAIL"; case .info: return "INFO" }
    }
}

struct VideoStatusTag: View {
    let level: CheckLevel
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: VideoStatus.icon(level)).font(.system(size: 11, weight: .semibold))
            Text(VideoStatus.word(level)).font(CryoFont.label(9.5)).tracking(0.8)
        }
        .foregroundStyle(VideoStatus.color(level))
        .frame(width: 88, alignment: .leading)
    }
}

/// A line with an icon (and the status word when it's a status)
struct VideoNote: View {
    let symbol: String
    let color: Color
    let text: String
    var word: String? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(color)
            if let word { Text(word).font(CryoFont.label(9.5)).tracking(0.8).foregroundStyle(color) }
            Text(text).font(CryoFont.body(11.5)).foregroundStyle(color == Cryo.ink2 ? Cryo.ink2 : Cryo.ink).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The opaque amber surface of a TRANSCODE or DECIDE announcement
struct VideoAmberPanel<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content() }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(VideoTone.amberSurface))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Cryo.attention.opacity(0.55), lineWidth: 1))
    }
}

/// A label and its value (the inspector)
struct VideoKV: View {
    let label: String
    let value: String
    init(_ label: String, _ value: String) { self.label = label; self.value = value }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).font(CryoFont.body(11.5)).foregroundStyle(Cryo.ink3).frame(width: 92, alignment: .leading)
            Text(value).font(CryoFont.mono(11.5)).foregroundStyle(Cryo.ink).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

/// The Dolby Vision or HDR10+ logo
struct VideoMetadataLogo: View {
    let kind: VideoPlanModel.MetadataKind
    var height: CGFloat = 18
    var body: some View {
        if kind == .dolbyVision { DolbyVisionLogo(height: height) } else { HDR10PlusLogo(height: height) }
    }
}

/// Choices as chips that wrap (presets, quality, speed, resolution)
struct VideoPickChips<T: Hashable>: View {
    @Binding var selection: T
    let options: [(value: T, label: String)]
    var disabled = false

    var body: some View {
        VideoFlowLayout(spacing: 6) {
            ForEach(options.indices, id: \.self) { i in
                let on = options[i].value == selection
                Button { selection = options[i].value } label: {
                    Text(options[i].label).font(CryoFont.body(11.5)).foregroundStyle(on ? Cryo.icePale : Cryo.ink2)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(on ? Cryo.ice.opacity(0.12) : Cryo.s2))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(on ? Cryo.ice.opacity(0.6) : Cryo.s3, lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .disabled(disabled)
        .opacity(disabled ? 0.55 : 1)
    }
}

/// Rows of chips that wrap to the width they're given
struct VideoFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0 && x + sz.width > maxW { y += rowH + spacing; x = 0; rowH = 0 }
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width.map { min($0, max(widest, 0)) } ?? widest, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + sz.width > bounds.maxX { y += rowH + spacing; x = bounds.minX; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
    }
}

// MARK: - Words and numbers

enum VideoFormat {
    /// `ProRes 4444 · 12-bit · 4:4:4 · 3840×2160 · 24 fps · P3-D65 / PQ · TC 01:00:00:00 · 60:09 · 1,900 Mbps`
    static func pictureLine(_ s: SourceVideo, project: Project) -> String {
        var p = [VideoPlanModel.codecShort(s), "\(s.bitDepth)-bit", s.chroma + (s.hasAlpha ? " + alpha" : ""), s.sizeText, "\(s.fpsText) fps", colour(s.color)]
        if let tc = s.timecode { p.append("TC \(tc)") }
        p.append(minutes(project.videoDuration > 0 ? project.videoDuration : s.duration))
        if s.bitRate > 0 { p.append(mbps(s.bitRate)) }
        return p.joined(separator: " · ")
    }

    /// "P3-D65 / PQ", "BT.2020 / PQ", "BT.709"
    static func colour(_ c: SourceColor) -> String {
        func prim(_ v: String?) -> String {
            switch v {
            case "smpte432"?: return "P3-D65"
            case "smpte431"?: return "DCI-P3"
            case "bt709"?: return "BT.709"
            case "bt2020"?: return "BT.2020"
            default: return SourceColor.name(v)
            }
        }
        func tf(_ v: String?) -> String {
            switch v {
            case "smpte2084"?: return "PQ"
            case "arib-std-b67"?: return "HLG"
            case "bt709"?: return "BT.709"
            case "iec61966-2-1"?: return "sRGB"
            default: return SourceColor.name(v)
            }
        }
        if c.primaries == nil && c.transfer == nil { return "colour untagged" }
        let a = prim(c.primaries), b = tf(c.transfer)
        return a == b ? a : "\(a) / \(b)"
    }

    /// 60:09 (minutes:seconds)
    static func minutes(_ d: Double) -> String {
        guard d.isFinite, d > 0 else { return "0:00" }
        let t = Int(d.rounded())
        return "\(t / 60):\(String(format: "%02d", t % 60))"
    }

    /// Bitrate in Mbps (Kbps below 1 Mbps): "1,900 Mbps", "45 Mbps", "8.4 Mbps", "640 Kbps"
    static func mbps(_ bps: Double) -> String {
        let m = bps / 1_000_000
        if m >= 100 { return Fmt.int(Int(m.rounded())) + " Mbps" }
        if m >= 10 { return String(format: "%.0f Mbps", m) }
        if m >= 1 { return String(format: "%.1f Mbps", m) }
        return String(format: "%.0f Kbps", bps / 1000)
    }

    /// The timecode of the middle frame (the one in the thumbnail), non-drop-frame only
    static func middleTimecode(_ s: SourceVideo, frames: Int) -> String? {
        guard let tc = s.timecode, !tc.contains(";") else { return nil }
        let f = tc.split(separator: ":").compactMap { Int($0) }
        let base = Int(s.fps.value.rounded())
        guard f.count == 4, base > 0 else { return nil }
        let total = ((f[0] * 60 + f[1]) * 60 + f[2]) * base + f[3] + max(frames > 0 ? frames : s.frames, 0) / 2
        let ff = total % base, secs = total / base
        return String(format: "%02d:%02d:%02d:%02d", (secs / 3600) % 24, (secs / 60) % 60, secs % 60, ff)
    }

    /// "This file also carries 6 mono PCM streams (a 5.1). You'll decide on the Audio tab whether to use them."
    static func embeddedAudioNote(_ project: Project) -> String? {
        let e = project.embeddedAudio
        guard !e.isEmpty else { return nil }
        func codec(_ t: Track) -> String { t.isPCM ? "PCM" : t.codecName }
        var parts: [String] = []
        for g in e where g.isGroup {
            parts.append("\(g.members.count) mono \(codec(g)) streams (a \(Probe.channelText(g.channels, g.channelLayout)))")
        }
        let monos = e.filter { !$0.isGroup && $0.channels == 1 }
        if monos.count > 1 { parts.append("\(monos.count) mono \(codec(monos[0])) streams") }
        for t in e where !t.isGroup && !(t.channels == 1 && monos.count > 1) {
            let ch = Probe.channelText(t.channels, t.channelLayout)
            parts.append("a \(ch == "Stereo" || ch == "Mono" ? ch.lowercased() : ch) \(codec(t)) stream")
        }
        let list = parts.count <= 1 ? parts.joined() : parts.dropLast().joined(separator: ", ") + " and " + parts.last!
        let one = e.count == 1 && !e[0].isGroup
        return "This file also carries \(list). You'll decide on the Audio tab whether to use \(one ? "it" : "them")."
    }

    /// A reason as a short title and the rest: the first sentence, cut at ": " or " — " when it's long
    static func splitReason(_ r: String) -> (title: String, rest: String?) {
        guard !r.isEmpty else { return ("", nil) }
        var title = r, rest: String? = nil
        if let dot = r.range(of: ". ") { title = String(r[..<dot.lowerBound]) + "."; rest = String(r[dot.upperBound...]) }
        if title.count > 60 {
            for sep in [": ", " — "] {
                if let c = title.range(of: sep) {
                    let tail = String(title[c.upperBound...])
                    title = String(title[..<c.lowerBound]) + "."
                    let more = tail.prefix(1).uppercased() + tail.dropFirst()
                    rest = rest.map { more + " " + $0 } ?? more
                    break
                }
            }
        }
        return (title, rest)
    }

    /// "ProRes 4444 · 12-bit · 4:4:4 · 1,900 Mbps"
    static func sourceShort(_ s: SourceVideo) -> String {
        var p = [VideoPlanModel.codecShort(s), "\(s.bitDepth)-bit · \(s.chroma)" + (s.hasAlpha ? " + alpha" : ""), colour(s.color)]
        if s.bitRate > 0 { p.append(mbps(s.bitRate)) }
        return p.joined(separator: " · ")
    }

    /// "HEVC 10-bit · 4:2:0 · BT.2020 / PQ · Dolby Vision 8.1 + HDR10 · ~60 Mbps"
    static func destinationShort(_ p: TranscodePlan, project: Project) -> String {
        var parts = [p.outputCodecShort + (p.video.codec == .prores ? "" : " · \(p.outputChroma)"), colour(p.outputColor)]
        if let h = p.hdr { parts.append(h.formats) }
        if p.resizes { parts.append("\(p.outputWidth)×\(p.outputHeight)") }
        parts.append("~" + mbps(p.estimatedBytes * 8 / max(p.seconds, 0.001)))
        return parts.joined(separator: " · ")
    }

    /// The plan's Source → Destination rows, for the file the Delivery writes: the audio is the Audio tab's business
    /// (it never goes through this encode) and the container is the one chosen above
    static func diffRows(_ p: TranscodePlan, project: Project) -> [CryoDiffRow] {
        p.rows.compactMap { r -> CryoDiffRow? in
            switch r.id {
            case "Audio": return nil
            case "Container":
                let to = project.container.rawValue.uppercased()
                return CryoDiffRow(label: r.id, from: r.from, to: to, changed: r.from != to)
            case "Timecode":
                let to = project.container == .mkv ? "none (MKV has no timecode track)" : r.to
                return CryoDiffRow(label: r.id, from: r.from, to: to, changed: r.from != to)
            default:
                return CryoDiffRow(label: r.id, from: r.from, to: r.to, changed: r.changed)
            }
        }
    }

    /// The plan's warnings that concern the picture of this delivery (the audio and the container are said elsewhere)
    static func warnings(_ p: TranscodePlan, project: Project) -> [String] {
        var w = p.warnings.filter { !$0.contains("audio") && !$0.hasPrefix("ProRes belongs in MOV") && !$0.contains("Choose the Dolby Vision / HDR preset") }
        if p.video.codec == .hevc, p.hdr != nil, p.video.rate?.beyondLevel51 == true {
            w.append("Peak above \(HDRSettings.Rate.level51Mbps) Mbps: the stream leaves HEVC Level 5.1 (UHD Blu-ray, most players) — fine on the Zidoo, test anything else.")
        }
        return w
    }
}

// MARK: - The Academy prediction of a transcode (moved from the old Transcode inspector, unchanged)

enum VideoPrediction {
    /// MediaInfo-style description of the file a TranscodePlan writes (for Academy.checks(…, predicted: true))
    static func tracks(_ p: TranscodePlan, output: URL) -> [MITrack] {
        var general = MITrack(type: "General", f: ["@type": "General", "Format": p.container == .mkv ? "Matroska" : "MPEG-4", "Format_Profile": p.container == .mov ? "QuickTime" : "Base Media"])
        general.f["Duration"] = String(p.seconds)
        general.f["FileSize"] = String(p.estimatedBytes)
        let c = p.outputColor
        var v: [String: String] = ["@type": "Video", "Width": "\(p.outputWidth)", "Height": "\(p.outputHeight)", "FrameRate": String(format: "%.3f", p.fps.value),
                                   "BitDepth": "\(p.outputBits)", "ChromaSubsampling": p.outputChroma, "Duration": String(p.seconds), "ScanType": "Progressive",
                                   "colour_primaries": Transcode.miName(c.primaries), "transfer_characteristics": Transcode.miName(c.transfer), "matrix_coefficients": Transcode.miName(c.matrix),
                                   "BitRate": String(p.estimatedBytes * 8 / max(p.seconds, 0.001))]
        switch p.video {
        case .prores(let pr): v["Format"] = "ProRes"; v["Format_Profile"] = pr.mediaInfoProfile
        case .h264: v["Format"] = "AVC"; v["Format_Profile"] = "High"
        case .hevc: v["Format"] = "HEVC"; v["Format_Profile"] = "Main 10"
        }
        if let h = p.hdr { v["HDR_Format"] = h.formats }
        var out = [general, MITrack(type: "Video", f: v)]
        if p.effectiveAudio != .none {
            for a in p.source.audio {
                var f: [String: String] = ["@type": "Audio", "Channels": "\(a.channels)", "SamplingRate": "\(a.sampleRate)", "Duration": String(p.seconds)]
                switch p.effectiveAudio {
                case .copy:
                    f["Format"] = a.isPCM ? "PCM" : a.codec == "eac3" ? "E-AC-3" : a.codec == "ac3" ? "AC-3" : a.codec == "aac" ? "AAC" : a.codec == "truehd" ? "MLP FBA" : a.codec.uppercased()
                    if a.isPCM { f["BitDepth"] = "\(a.bits)" }
                case .pcm: f["Format"] = "PCM"; f["BitDepth"] = "24"
                case .aac: f["Format"] = "AAC"; f["Format_Profile"] = "LC"; f["BitRate"] = "\(p.aacKbps * 1000)"
                case .none: break
                }
                if a.isPCM || p.effectiveAudio == .pcm, p.container == .mov {
                    let n = a.channels
                    f["ChannelLayout"] = n == 6 ? "L R C LFE Ls Rs" : n == 2 ? "L R" : n == 8 ? "L R C LFE Ls Rs Lrs Rrs" : nil
                }
                out.append(MITrack(type: "Audio", f: f))
            }
        }
        return out
    }
}
