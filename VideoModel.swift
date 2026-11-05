// BROS-MUX Beta 2.0.0 — the Video tab's plan: COPY, HEVC HDR (Dolby Vision / HDR10+ / HDR10) or an SDR transcode.
// hdr.encode stays the one truth of the HEVC HDR path; choice(_:) is computed from it and choose(_:project:) is its only
// writer. The app never decides here in silence: a picture that can't go in as it is opens the question, and while the
// question has no answer the step stays amber (DECIDE) and the Delivery doesn't start.

import SwiftUI
import AppKit

/// An SDR transcode of the picture (the only destinations `.transcode` can take)
struct VideoTranscodeSettings: Codable, Equatable {
    var preset: String                                // TranscodePreset raw: prores422HQ | prores422 | h264Review | hevcSDR
    var resolution: String = "same"                   // OutputResolution raw
    var toneMap: Bool = false
    var quality: String? = nil                        // HDRSettings.Quality raw (H.264/HEVC)
    var speed: String? = nil                          // HDRSettings.Speed raw
}

/// One destination the picture can go to, with the reason when it can't
struct VideoTargetOption: Identifiable {
    let id: String; let title: String; let detail: String
    let choice: VideoPlanModel.Choice; let problem: String?; let recommended: Bool
}

@Observable final class VideoPlanModel {
    enum Choice: Equatable { case copy, hevcHDR, transcode(VideoTranscodeSettings) }
    enum MetadataKind: Equatable { case dolbyVision, hdr10Plus }
    enum Popup: Equatable { case metadata(MetadataKind), needsTranscode(reason: String) }

    var transcode: VideoTranscodeSettings? = nil      // the only stored half of the choice
    var popup: Popup? = nil
    var decisionPending = false                       // the needs-transcode question was dismissed (Esc)
    var checks: [MetadataCheck] = []
    var letterbox: MetadataAnalysis.Letterbox? = nil

    // MARK: V's own state (not in the contract; read by the Video tab only)

    /// The analysis lines of each kind of metadata (`checks` holds both, Dolby Vision first)
    var dolbyVisionChecks: [MetadataCheck] = []
    var hdr10PlusChecks: [MetadataCheck] = []
    /// The middle frame of the picture, for the card (drawn on a neutral surround)
    var thumbnail: CGImage? = nil
    var measuringLetterbox = false
    /// What "Deliver without …" / "Remove the metadata" took out — the card says so, and can put it back
    var removedMetadata: [(kind: MetadataKind, url: URL)] = []
    /// A container change made a track need a transcode: the Video tab shows this list once
    var containerFlip: String? = nil

    /// The picture this model last saw (to tell a new picture from the same one)
    @ObservationIgnored private(set) var picturePath: String?
    /// Each metadata file opens its analysis by itself once (re-dropping it opens it again)
    @ObservationIgnored private var metadataShown: Set<String> = []
    @ObservationIgnored private var popupQueue: [Popup] = []
    @ObservationIgnored private var letterboxCancel: CancelFlag?
    @ObservationIgnored private var thumbnailToken = UUID()
    @ObservationIgnored private var recheckToken = UUID()
    @ObservationIgnored private var dvCheckedKey: String?

    init() {}

    // MARK: - The choice

    func choice(_ project: Project) -> Choice {
        if project.hdr.encode { return .hevcHDR }
        return transcode.map { .transcode($0) } ?? .copy
    }

    /// The ONLY writer of hdr.encode / autoEnabledBy / autoReason
    func choose(_ c: Choice, project: Project) {
        let hdr = project.hdr
        switch c {
        case .copy:
            transcode = nil
            hdr.encode = false; hdr.autoEnabledBy = nil; hdr.autoReason = nil
        case .hevcHDR:
            transcode = nil
            // whatever metadata is loaded goes in: nothing is left out in silence (Remove the metadata is the way out)
            if hdr.dvSource != nil { hdr.dolbyVision = true }
            if hdr.hdr10plusJSON != nil { hdr.hdr10plus = true }
            hdr.encode = true
            hdr.autoEnabledBy = Self.metadataURL(.dolbyVision, hdr) ?? Self.metadataURL(.hdr10Plus, hdr) ?? hdr.imf?.cpl
            hdr.autoReason = hevcReason(project)
        case .transcode(let s):
            transcode = s
            hdr.encode = false; hdr.autoEnabledBy = nil; hdr.autoReason = nil
        }
        hdr.bannerCollapsed = false
        decisionPending = false
        if case .needsTranscode = popup { nextPopup() }
        refreshPending(project)
    }

    /// Tweaks of the chosen SDR transcode (resolution, tone map, quality, speed); the destination stays
    func updateTranscode(project: Project, _ edit: (inout VideoTranscodeSettings) -> Void) {
        guard var s = transcode else { return }
        edit(&s)
        transcode = s
    }

    // MARK: - Events

    func didAddVideo(project: Project) {
        guard Thread.isMainThread else { return }        // a worker's throwaway Project (TranscodeRunner) has no tab to show
        guard let v = project.videoSource else { clearPicture(); return }
        let isNew = picturePath != v.url.path
        if isNew {
            picturePath = v.url.path
            letterbox = nil
            thumbnail = nil
            startThumbnail(v, project: project)
            startLetterbox(v, project: project)
        }
        ensureDolbyVisionChecked(project)
        recheck(project)
        // metadata that came before the picture: its analysis opens now that the picture is known
        var opened = false
        for k in metadataKinds(project) {
            let key = metadataKey(k, project)
            if !metadataShown.contains(key) { metadataShown.insert(key); present(.metadata(k)); opened = true }
        }
        if isNew, !opened, metadataKinds(project).isEmpty, let r = containerProblem(project) {
            decisionPending = true
            present(.needsTranscode(reason: r))
        }
    }

    func didAddMetadata(kind: MetadataKind, url: URL, project: Project) {
        guard Thread.isMainThread else { return }
        let hdr = project.hdr
        removedMetadata.removeAll { $0.kind == kind }
        switch kind {
        case .dolbyVision:
            let src: DolbyVisionMeta.Source = url.pathExtension.lowercased() == "mxf"
                ? .isxd([.init(file: url, entry: 0, count: project.videoFrames)]) : .xml(url)
            if hdr.dvSource != src {
                hdr.dvSource = src
                if !hdr.dvChecking { hdr.dvSummary = nil; hdr.dvProblem = nil; hdr.dvXMLReady = nil }
                dvCheckedKey = nil
            } else if hdr.dvChecking {
                dvCheckedKey = dolbyVisionKey(project)       // routed and already being read with this picture
            }
            hdr.dolbyVision = true
        case .hdr10Plus:
            if hdr.hdr10plusJSON != url || hdr.hdr10plusFrames == nil {
                hdr.hdr10plusJSON = url; hdr.hdr10plusFrames = nil
                DispatchQueue.global(qos: .userInitiated).async {
                    let n = HDR10Plus.frames(url)
                    DispatchQueue.main.async { if hdr.hdr10plusJSON == url { hdr.hdr10plusFrames = n ?? -1; self.recheck(project) } }
                }
            }
            hdr.hdr10plus = true
        }
        // already going to HEVC HDR: the new metadata goes in with it (said by its analysis); the reason is refreshed
        if choice(project) == .hevcHDR { choose(.hevcHDR, project: project) }
        ensureDolbyVisionChecked(project)
        recheck(project)
        let key = metadataKey(kind, project)
        if project.videoSource != nil {
            metadataShown.insert(key)
            present(.metadata(kind))
        } else {
            metadataShown.remove(key)                         // opens when the picture arrives
        }
    }

    func removeMetadata(project: Project) { removeMetadata(project: project, announce: true) }

    /// `announce: false` when the caller says itself what happens next (the "Deliver without …" choices)
    func removeMetadata(project: Project, announce: Bool) {
        let hdr = project.hdr
        var gone: [(kind: MetadataKind, url: URL)] = []
        if let u = Self.metadataURL(.dolbyVision, hdr) { gone.append((.dolbyVision, u)) }
        if let u = Self.metadataURL(.hdr10Plus, hdr) { gone.append((.hdr10Plus, u)) }
        let encodeForMetadata = hdr.encode && hdr.imf == nil && gone.contains { $0.url == hdr.autoEnabledBy }
        // an IMF package's own Dolby Vision track (ISXD) has no file to put back
        let fromIMF: Bool = { if case .isxd? = hdr.dvSource { return true }; return false }()
        hdr.dvSource = nil; hdr.dvSummary = nil; hdr.dvProblem = nil; hdr.dvXMLReady = nil; hdr.dvChecking = false
        hdr.dolbyVision = true
        hdr.hdr10plusJSON = nil; hdr.hdr10plusFrames = nil; hdr.hdr10plus = false
        // the HDR10 values that came from the Dolby Vision L6 go back to the picture's own (or the defaults)
        hdr.mastering = MasteringDisplay(); hdr.maxCLL = 0; hdr.maxFALL = 0; hdr.masteringSource = "defaults — check them"
        hdr.applySourceMastering(project.videoSource?.mi)
        dvCheckedKey = nil
        removedMetadata = fromIMF ? gone.filter { $0.kind != .dolbyVision } : gone
        checks = []; dolbyVisionChecks = []; hdr10PlusChecks = []
        popupQueue.removeAll { if case .metadata = $0 { return true }; return false }
        if case .metadata? = popup { nextPopup() }
        if encodeForMetadata {
            choose(.copy, project: project)
            if announce {
                project.post("\(gone.map { "\(Self.kindName($0.kind)) metadata (\($0.url.lastPathComponent))" }.joined(separator: " and ")) removed: the picture goes back to COPY · bit-exact.", tab: .video, level: .info)
            }
        } else if announce && !gone.isEmpty {
            project.post("\(gone.map { "\(Self.kindName($0.kind)) metadata (\($0.url.lastPathComponent))" }.joined(separator: " and ")) removed — it won't be in the file.", tab: .video, level: .info)
        }
        refreshPending(project)
        recheck(project)
    }

    /// Puts back what "Remove the metadata" took out
    func restoreRemovedMetadata(project: Project) {
        let back = removedMetadata
        removedMetadata = []
        for m in back { didAddMetadata(kind: m.kind, url: m.url, project: project) }
    }

    func reset() {
        transcode = nil; popup = nil; decisionPending = false; checks = []; letterbox = nil
        dolbyVisionChecks = []; hdr10PlusChecks = []; thumbnail = nil; measuringLetterbox = false
        removedMetadata = []; containerFlip = nil
        picturePath = nil; metadataShown = []; popupQueue = []; dvCheckedKey = nil
        letterboxCancel?.set(); letterboxCancel = nil
        thumbnailToken = UUID(); recheckToken = UUID()
    }

    /// The view's safety net: a picture this model hasn't seen yet (or one that went away)
    func syncPicture(project: Project) {
        if let v = project.videoSource {
            if picturePath != v.url.path { didAddVideo(project: project) } else { recheck(project) }
        } else if picturePath != nil {
            clearPicture()
            recheck(project)
        } else {
            recheck(project)
        }
    }

    private func clearPicture() {
        picturePath = nil; thumbnail = nil; letterbox = nil; measuringLetterbox = false
        letterboxCancel?.set(); letterboxCancel = nil; thumbnailToken = UUID()
    }

    // MARK: - Pop-ups (one at a time; the next waits its turn)

    func present(_ p: Popup) {
        if popup == nil { popup = p; return }
        if popup != p && !popupQueue.contains(p) { popupQueue.append(p) }
    }

    func nextPopup() { popup = popupQueue.isEmpty ? nil : popupQueue.removeFirst() }

    /// "Continue" on the metadata analysis: if the picture can't carry it, the question comes next
    func metadataContinue(project: Project) {
        nextPopup()
        if choice(project) != .hevcHDR, !metadataKinds(project).isEmpty, let r = needsReason(project) {
            decisionPending = true
            popupQueue.removeAll { if case .needsTranscode = $0 { return true }; return false }
            present(.needsTranscode(reason: r))
        }
    }

    /// Esc (or "Decide later") on the question: it stays pending, the step goes amber, the Delivery waits
    func chooserEscape(project: Project) {
        if case .needsTranscode(let reason)? = popup, !reason.isEmpty || needsReason(project) != nil { decisionPending = true }
        nextPopup()
        refreshPending(project)
    }

    /// The question, asked again from the tab ("Transcode the picture…", the pending banner)
    func openChooser(project: Project) {
        let r = needsReason(project) ?? ""
        if !r.isEmpty { decisionPending = true }
        if case .needsTranscode? = popup { popup = .needsTranscode(reason: r); return }
        present(.needsTranscode(reason: r))
    }

    /// A pending decision whose reason went away (container changed, metadata removed) is no longer pending
    func refreshPending(_ project: Project) {
        if decisionPending && needsReason(project) == nil { decisionPending = false }
    }

    // MARK: - The container ("Where will this file play?")

    /// Changes the container and says which tracks now need a transcode (the picture's question opens)
    func setContainer(_ c: Container, project: Project) {
        guard c != project.container else { return }
        let old = project.container
        let audioBefore = Set(project.audioTracks.filter { $0.include && project.audioConversionReason($0) != nil }.map(\.id))
        let pictureBefore = containerProblem(project, container: old) != nil
        project.container = c
        var lines: [String] = []
        if !pictureBefore, let r = containerProblem(project, container: c), let s = source(project) {
            lines.append("Picture · \(Self.codecShort(s)) — \(r)")
        }
        let audioNow = project.audioTracks.filter { $0.include && !audioBefore.contains($0.id) }
            .compactMap { t in project.audioConversionReason(t).map { (t, $0) } }
        for (t, r) in audioNow {
            lines.append("Audio · \(t.title) — \(r)")
            project.post("\(c.rawValue.uppercased()): “\(t.title)” can't go in as it is (\(r)). Choose TRANSCODE for it, or change the container on the Video tab.", tab: .audio, level: .warn)
        }
        refreshPending(project)
        guard !lines.isEmpty else { return }
        project.post("\(c.rawValue.uppercased()): \(lines.count == 1 ? "1 track" : "\(lines.count) tracks") can't go in as \(lines.count == 1 ? "it is" : "they are") — " + lines.joined(separator: " · "), tab: .video, level: .warn)
        if !pictureBefore, let r = containerProblem(project) {
            // the picture's question says it; the audio lines stay in the notice above
            decisionPending = true
            popupQueue.removeAll { if case .needsTranscode = $0 { return true }; return false }
            present(.needsTranscode(reason: r))
        } else {
            containerFlip = "In \(c.rawValue.uppercased()), \(lines.count == 1 ? "this track can't" : "these tracks can't") go into the file as \(lines.count == 1 ? "it is" : "they are"):\n\n" + lines.map { "• " + $0 }.joined(separator: "\n")
                + (lines.contains { $0.hasPrefix("Audio") } ? "\n\nThe Audio tab shows what to do for the audio." : "")
        }
    }

    // MARK: - What the tab says

    func touch(project: Project) -> FileTouch {
        if decisionPending || project.metadataNotEmbedded != nil { return .pending }
        switch choice(project) {
        case .copy: return copyProblem(project) != nil ? .pending : .copy
        case .transcode: return containerProblem(project) != nil ? .pending : .transcode
        case .hevcHDR: return .transcode
        }
    }

    func touchText(project: Project) -> String {
        if touch(project: project) == .pending {
            if let r = needsReason(project) { return "— " + Self.lowerFirst(r) }
            return "— the picture's destination isn't decided yet"
        }
        switch choice(project) {
        case .copy:
            return project.videoSource == nil ? "— drop the picture: it goes into the file bit for bit" : "— the picture is not touched"
        case .hevcHDR:
            return "→ \(outputLabel(project)) — " + Self.lowerFirst(hevcReason(project))
        case .transcode:
            return "→ \(outputLabel(project)) — you chose it"
        }
    }

    func sidebarLine(project: Project) -> String {
        guard let v = project.videoSource else {
            let k = metadataKinds(project)
            return k.isEmpty ? "no picture yet" : "\(metadataWhat(project)) metadata · waiting for the picture"
        }
        let codec = v.source.map(Self.codecShort) ?? v.codecName.replacingOccurrences(of: "Apple ", with: "")
        switch touch(project: project) {
        case .pending: return "\(codec) · DECIDE"
        case .transcode:
            switch choice(project) {
            case .hevcHDR:
                let hdr = project.hdr
                let f = hdr.dvSource != nil ? "Dolby Vision" : hdr.hdr10plusJSON != nil ? "HDR10+" : "HDR10"
                return "\(codec) · TRANSCODE → HEVC \(f)"
            case .transcode(let s):
                return "\(codec) · TRANSCODE → " + Self.presetShort(s.preset)
            case .copy: return "\(codec) · COPY"
            }
        default: return "\(codec) · COPY"
        }
    }

    /// What the picture becomes, in a few words: "HEVC 10-bit · Dolby Vision 8.1", "Apple ProRes 422 HQ", …
    func outputLabel(_ project: Project) -> String {
        switch choice(project) {
        case .copy: return "COPY · bit-exact"
        case .hevcHDR:
            let hdr = project.hdr
            var f: [String] = []
            if hdr.dvSource != nil { f.append("Dolby Vision 8.1") }
            if hdr.hdr10plusJSON != nil { f.append("HDR10+") }
            if f.isEmpty { f.append("HDR10") }
            return "HEVC 10-bit · " + f.joined(separator: " + ")
        case .transcode(let s):
            var t = TranscodePreset(rawValue: s.preset).map(Self.presetTitle) ?? s.preset
            if let r = OutputResolution(rawValue: s.resolution), r != .same { t += " · " + (r == .hd ? "HD" : "UHD") }
            if s.toneMap, source(project)?.isHDR == true { t += " · SDR (tone-mapped)" }
            return t
        }
    }

    /// Why the picture goes to HEVC HDR: "You chose it because ProRes 4444 can't carry the Dolby Vision metadata (2DIE4.xml)"
    func hevcReason(_ project: Project) -> String {
        let hdr = project.hdr
        if hdr.imf != nil { return "You chose it because an IMF master (JPEG 2000 in MXF) plays nowhere as it is" }
        let files = metadataKinds(project).compactMap { Self.metadataURL($0, hdr)?.lastPathComponent }
        if !files.isEmpty && source(project) == nil {
            return "You chose it for the \(metadataWhat(project)) metadata (\(files.joined(separator: ", "))) — the picture isn't here yet"
        }
        if !files.isEmpty {
            let what = metadataWhat(project)
            if let s = source(project), s.codec == "hevc" {
                return "You chose it because the \(what) metadata (\(files.joined(separator: ", "))) can only be added while the picture is encoded"
            }
            let codec = source(project).map(Self.codecShort) ?? "this picture"
            return "You chose it because \(codec) can't carry the \(what) metadata (\(files.joined(separator: ", ")))"
        }
        if let r = copyProblem(project) { return "You chose it because " + Self.lowerFirst(r) }
        if !removedMetadata.isEmpty { return "You chose it, without the \(removedMetadata.map { Self.kindName($0.kind) }.joined(separator: " and ")) metadata" }
        return "You chose it"
    }

    // MARK: - Why the picture can't go in as it is

    /// The question to ask, or nil when the picture can go in as it is with the current choice
    func needsReason(_ project: Project) -> String? {
        if choice(project) != .hevcHDR, let r = carryReason(project) { return r }
        return containerProblem(project)
    }

    /// The current choice doesn't fit the container: COPY of a picture that can't be copied there, or a ProRes
    /// transcode into MP4 / MKV (the HEVC HDR path fits all three)
    func containerProblem(_ project: Project, container: Container? = nil) -> String? {
        switch choice(project) {
        case .copy: return copyProblem(project, container: container)
        case .transcode(let s):
            let c = container ?? project.container
            if s.preset.hasPrefix("prores") && c != .mov {
                return "ProRes can't go into \(c.rawValue.uppercased()): players there don't open it (the Academy and Resolve want ProRes in MOV)."
            }
            return nil
        case .hevcHDR: return nil
        }
    }

    /// "ProRes 4444 can't carry Dolby Vision (2DIE4.xml). To embed it, the picture must be transcoded." — whatever the
    /// current choice (nil without metadata)
    func carryReason(_ project: Project) -> String? {
        if !metadataKinds(project).isEmpty {
            let what = metadataWhat(project)
            let files = metadataKinds(project).compactMap { Self.metadataURL($0, project.hdr)?.lastPathComponent }.joined(separator: ", ")
            if let s = source(project) {
                if s.codec == "hevc" {
                    return "This HEVC can't take the \(what) metadata (\(files)) as it is: in this app the metadata is added while the picture is encoded. To embed it, the picture must be transcoded."
                }
                return "\(Self.codecShort(s)) can't carry \(what) (\(files)). To embed it, the picture must be transcoded."
            }
            return "The \(what) metadata (\(files)) needs the picture to be transcoded to HEVC to go into the file."
        }
        return nil
    }

    /// Why this picture can't be copied into that container (nil = it can, bit for bit)
    func copyProblem(_ project: Project, container: Container? = nil) -> String? {
        guard let v = project.videoSource else { return nil }
        let c = container ?? project.container
        if project.hdr.imf != nil {
            return "An IMF master (JPEG 2000 in MXF) can't be copied into MOV, MP4 or MKV as it is — it can only become HEVC."
        }
        if v.url.pathExtension.lowercased() == "mxf" {
            return "An MXF master can't be copied into MOV, MP4 or MKV as it is."
        }
        if v.codecKey == "prores" && c != .mov {
            return "ProRes can't be copied into \(c.rawValue.uppercased()): players there don't open it (the Academy and Resolve want ProRes in MOV)."
        }
        return nil
    }

    // MARK: - The transcode

    /// `.transcode` only (SDR), audio .none. The plan writes the intermediate picture (MOV, the TranscodeRunner's
    /// `video.mov`); the Delivery then copies it bit for bit into the final container.
    func transcodePlan(project: Project) -> TranscodePlan? {
        guard case .transcode(let s) = choice(project), let src = source(project) else { return nil }
        return Self.sdrPlan(s, source: src, project: project)
    }

    /// The plan for one SDR destination (never TranscodeModel.shared: a throwaway model reads only these settings)
    static func sdrPlan(_ s: VideoTranscodeSettings, source src: SourceVideo, project: Project) -> TranscodePlan? {
        guard let preset = TranscodePreset(rawValue: s.preset),
              [.prores422HQ, .prores422, .h264Review, .hevcSDR].contains(preset) else { return nil }
        let quality = s.quality.flatMap(HDRSettings.Quality.init(rawValue:))
        let speed = s.speed.flatMap(HDRSettings.Speed.init(rawValue:))
        return TranscodeModel.plan(source: src, preset: preset, resolution: OutputResolution(rawValue: s.resolution) ?? .same,
                                   toneMap: s.toneMap && src.isHDR, container: .mov, quality: quality, speed: speed,
                                   audio: AudioPlan.none, dv: nil, hdr10plus: nil, mi: src.mi,
                                   rate: preset == .hevcSDR ? project.hdr.rate : nil)
    }

    /// What the HEVC HDR encode would be (the same plan Project.encodePlan builds, without needing the encode to be on)
    func hevcPreviewPlan(_ project: Project) -> TranscodePlan? {
        if let p = project.encodePlan { return p }
        guard let v = project.videoSource, let src = v.source else { return nil }
        let hdr = project.hdr
        var p = TranscodePlan(source: src, video: .hevc(quality: hdr.quality, speed: hdr.speed, rate: hdr.rate))
        let frames = project.videoFrames > 0 ? project.videoFrames : src.frames
        p.segments = v.imfSegments.isEmpty
            ? [.init(file: v.url, start: 0, count: frames)]
            : v.imfSegments.flatMap { r in Array(repeating: TranscodePlan.Segment(file: r.file, start: r.entryPoint, count: r.duration), count: r.repeatCount) }
        p.frames = frames
        p.fps = project.videoTrack != nil ? project.videoFPS : src.fps
        p.width = project.videoWidth > 0 ? project.videoWidth : src.width
        p.height = project.videoHeight > 0 ? project.videoHeight : src.height
        p.rgbSource = (v.mi?["ColorSpace"] ?? "").contains("RGB") || src.color.isRGB
        p.hdr = HDRMeta(mastering: hdr.mastering, maxCLL: hdr.maxCLL, maxFALL: hdr.maxFALL, dolbyVision: hdr.dvSource,
                        dvXML: hdr.dvSource == nil ? nil : hdr.dvXMLReady, hdr10plus: hdr.hdr10plusJSON)
        p.container = project.container
        p.audio = .none
        p.convertGamut = hdr.convertGamut
        return p
    }

    func legalTargets(project: Project) -> [VideoTargetOption] {
        guard let src = source(project) else { return [] }
        let hdr = project.hdr
        let imf = hdr.imf != nil
        let isHDR = src.isHDR || hdr.imf != nil
        let sdrTagged = src.color.isTagged && !src.color.isHDR && src.color.transfer != nil
        let meta = metadataKinds(project)
        let containerReason = copyProblem(project)
        var out: [VideoTargetOption] = []

        // HEVC HDR: the only way Dolby Vision / HDR10+ / HDR10 go into the file
        let hevcTitle = "HEVC 10-bit · " + (meta.contains(.dolbyVision) ? "Dolby Vision 8.1 + HDR10" : "HDR10") + (meta.contains(.hdr10Plus) ? " + HDR10+" : "") + " (x265)"
        var hevcProblem: String? = sdrTagged ? "The picture is SDR (\(src.color.short)): HDR10 and Dolby Vision would describe it wrongly." : nil
        if hevcProblem == nil, !isHDR, meta.isEmpty { hevcProblem = "The picture isn't HDR (no PQ / HLG): there is nothing for HDR10 to describe." }
        let toolsReady = VideoToolsGate.shared.ready
        if hevcProblem == nil, toolsReady, let p = hevcPreviewPlan(project)?.problem { hevcProblem = p }
        out.append(VideoTargetOption(id: "hevcHDR", title: hevcTitle,
                                     detail: "Plays on Apple TV 4K, iPhone, iPad, Mac and LG / Sony / Samsung TVs. Software encoder (x265): slow, the best quality.",
                                     choice: .hevcHDR, problem: hevcProblem, recommended: hevcProblem == nil && (!meta.isEmpty || imf || isHDR)))
        if isHDR || !meta.isEmpty {
            out.append(VideoTargetOption(id: "appleHardware", title: "HEVC 10-bit · Apple hardware (VideoToolbox)",
                                         detail: "Fast, but not for HDR delivery.", choice: .hevcHDR,
                                         problem: "Not possible: it can't write the HDR10 / Dolby Vision metadata.", recommended: false))
        }
        // the SDR destinations
        let sdr: [(TranscodePreset, String)] = [
            (.prores422HQ, "What the Academy Screening Room asks for (MOV)."),
            (.prores422, "Lighter ProRes for editing and archive copies (MOV)."),
            (.h264Review, "A small 8-bit file to send around for review."),
            (.hevcSDR, "HEVC Main 10 for playback, the source's own colour, no HDR metadata."),
        ]
        for (preset, detail) in sdr {
            let tone = src.isHDR && (preset == .h264Review || preset == .hevcSDR)
            let s = VideoTranscodeSettings(preset: preset.rawValue, toneMap: tone)
            var problem: String?
            if imf { problem = "An IMF package can only become HEVC in this app." }
            else if (preset == .prores422HQ || preset == .prores422) && project.container != .mov {
                problem = "ProRes goes in MOV only — choose MOV under “Where will this file play?”."
            } else if toolsReady, let p = Self.sdrPlan(s, source: src, project: project)?.problem { problem = p }
            let extra = tone ? " The HDR picture is tone-mapped to SDR (BT.709)." : (src.isHDR && preset.rawValue.hasPrefix("prores") ? " Keeps the HDR (PQ) colour: a master copy, not a screening file." : "")
            let recommended: Bool = problem == nil && !imf && meta.isEmpty && !src.isHDR
                && (project.container == .mov ? preset == .prores422HQ : preset == .hevcSDR)
            out.append(VideoTargetOption(id: preset.rawValue, title: Self.presetTitle(preset), detail: detail + extra,
                                         choice: .transcode(s), problem: problem, recommended: recommended))
        }
        out.append(VideoTargetOption(id: "copy", title: "Keep the picture as it is (COPY · bit-exact)",
                                     detail: "Not a single pixel changes" + (meta.isEmpty ? "." : " — and the metadata isn't in the file."),
                                     choice: .copy, problem: containerReason, recommended: false))
        return out
    }

    // MARK: - The metadata analysis

    /// Recomputes the analysis lines; re-runs by itself whenever anything they read changes (the Dolby Vision summary
    /// arriving from dovi_tool, the letterbox, a fix applied, a new picture)
    func recheck(_ project: Project) {
        guard Thread.isMainThread else { return }
        let token = UUID(); recheckToken = token
        let box = VideoRecheckBox(model: self, project: project)
        // the picture is read outside the observation (a new picture comes through didAddVideo / syncPicture):
        // a trim or a title changing on an audio track doesn't re-run the analysis
        let pic = source(project)
        let frames = pic == nil ? 0 : project.videoFrames
        let fps = pic == nil ? 0 : (project.videoTrack != nil ? project.videoFPS.value : pic?.fps.value ?? 0)
        scrubStaleDolbyVision(project)
        let (dv, hp) = withObservationTracking { () -> ([MetadataCheck], [MetadataCheck]) in
            _ = project.hdr.dvSummary; _ = project.hdr.dvChecking      // a late read after "Remove" must come back here
            return computeChecks(project.hdr, picture: pic, frames: frames, fps: fps)
        } onChange: {
            DispatchQueue.main.async { guard let m = box.model, let p = box.project, m.recheckToken == token else { return }; m.recheck(p) }
        }
        func same(_ a: [MetadataCheck], _ b: [MetadataCheck]) -> Bool {
            a.count == b.count && zip(a, b).allSatisfy { $0.level == $1.level && $0.title == $1.title && $0.detail == $1.detail && $0.fix == $1.fix }
        }
        if !same(dv, dolbyVisionChecks) { dolbyVisionChecks = dv }
        if !same(hp, hdr10PlusChecks) { hdr10PlusChecks = hp }
        if !same(dv + hp, checks) { checks = dv + hp }
    }

    /// A Dolby Vision read still running when the metadata was removed lands afterwards (HDRSettings has no way to
    /// cancel it): what it brought is taken out again, and the HDR10 values go back to the picture's own
    private func scrubStaleDolbyVision(_ project: Project) {
        let hdr = project.hdr
        guard hdr.dvSource == nil, hdr.dvSummary != nil || hdr.dvProblem != nil || hdr.dvXMLReady != nil || hdr.dvChecking else { return }
        hdr.dvSummary = nil; hdr.dvProblem = nil; hdr.dvXMLReady = nil; hdr.dvChecking = false
        if hdr.masteringSource.contains("Dolby Vision") {
            hdr.mastering = MasteringDisplay(); hdr.maxCLL = 0; hdr.maxFALL = 0; hdr.masteringSource = "defaults — check them"
            hdr.applySourceMastering(project.videoSource?.mi)
        }
    }

    private func computeChecks(_ hdr: HDRSettings, picture pic: SourceVideo?, frames: Int, fps: Double) -> ([MetadataCheck], [MetadataCheck]) {
        var dv: [MetadataCheck] = [], hp: [MetadataCheck] = []
        if hdr.dvSource != nil {
            dv = MetadataAnalysis.dolbyVision(hdr, picture: pic, frames: frames, fps: fps, letterbox: letterbox)
            if dv.isEmpty { dv = Self.basicDolbyVisionLines(hdr, picture: pic, frames: frames) }
        }
        if hdr.hdr10plusJSON != nil {
            hp = MetadataAnalysis.hdr10Plus(hdr, picture: pic, frames: frames, fps: fps)
            if hp.isEmpty { hp = Self.basicHDR10PlusLines(hdr, picture: pic, frames: frames) }
        }
        return (dv, hp)
    }

    /// The least the pop-up says when the engine's analysis has nothing to say (never a ✓ it didn't check)
    private static func basicDolbyVisionLines(_ hdr: HDRSettings, picture: SourceVideo?, frames: Int) -> [MetadataCheck] {
        let name = hdr.dvSource?.label ?? "the metadata"
        if hdr.dvChecking { return [MetadataCheck(level: .info, title: "Reading \(name)…", detail: "dovi_tool reads the XML (a long film takes a few seconds).", fix: nil)] }
        if let p = hdr.dvProblem { return [MetadataCheck(level: .fail, title: "The Dolby Vision metadata can't be used", detail: p, fix: .copyText(p))] }
        guard let s = hdr.dvSummary else { return [MetadataCheck(level: .info, title: "Not read yet", detail: name, fix: nil)] }
        if picture == nil { return [MetadataCheck(level: .info, title: "Waiting for the picture…", detail: s.line, fix: nil)] }
        var out = [MetadataCheck(level: .info, title: "Read: \(Fmt.int(s.frames)) frames", detail: s.line, fix: nil)]
        if frames > 0, s.frames != frames {
            let ask = "Please send a Dolby Vision XML of \(Fmt.int(frames)) frames — the picture has \(Fmt.int(frames)), the XML covers \(Fmt.int(s.frames))."
            out.append(MetadataCheck(level: .fail, title: "Frames: the XML has \(Fmt.int(s.frames)), the picture \(Fmt.int(frames))", detail: "Ask the colourist for an XML of \(Fmt.int(frames)) frames.", fix: .copyText(ask)))
        }
        return out
    }

    private static func basicHDR10PlusLines(_ hdr: HDRSettings, picture: SourceVideo?, frames: Int) -> [MetadataCheck] {
        let name = hdr.hdr10plusJSON?.lastPathComponent ?? "the JSON"
        guard let n = hdr.hdr10plusFrames else { return [MetadataCheck(level: .info, title: "Reading \(name)…", detail: "", fix: nil)] }
        if n < 0 { return [MetadataCheck(level: .fail, title: "This JSON isn't HDR10+ metadata", detail: "No SceneInfo list in \(name).", fix: nil)] }
        if picture == nil { return [MetadataCheck(level: .info, title: "Waiting for the picture…", detail: "\(Fmt.int(n)) frames of HDR10+ metadata.", fix: nil)] }
        if frames > 0, n != frames {
            return [MetadataCheck(level: .fail, title: "Frames: the JSON has \(Fmt.int(n)), the picture \(Fmt.int(frames))", detail: "Ask for HDR10+ metadata of \(Fmt.int(frames)) frames.", fix: .copyText("Please send HDR10+ metadata (JSON) of \(Fmt.int(frames)) frames — the picture has \(Fmt.int(frames)), the JSON covers \(Fmt.int(n))."))]
        }
        return [MetadataCheck(level: .info, title: "Read: \(Fmt.int(n)) frames", detail: name, fix: nil)]
    }

    /// The fix buttons of the analysis lines
    func applyFix(_ fix: MetadataCheck.Fix, project: Project) {
        let hdr = project.hdr
        switch fix {
        case .convertGamut: hdr.convertGamut = true
        case .keepSourcePrimaries: hdr.convertGamut = false
        case .useMeasuredLight:
            if let c = hdr.dvSummary?.l1MaxCLL { hdr.maxCLL = c }
            if let f = hdr.dvSummary?.l1MaxFALL { hdr.maxFALL = f }
            hdr.masteringSource = "MaxCLL / MaxFALL measured from the Dolby Vision L1"
        case .qualityFloorOff: hdr.qualityFloor = false
        case .removeMetadata: removeMetadata(project: project)
        case .copyText(let s):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(s, forType: .string)
        }
        recheck(project)
    }

    // MARK: - Helpers the tab reads

    func source(_ project: Project) -> SourceVideo? { project.videoSource?.source }

    func metadataKinds(_ project: Project) -> [MetadataKind] {
        var k: [MetadataKind] = []
        if project.hdr.dvSource != nil { k.append(.dolbyVision) }
        if project.hdr.hdr10plusJSON != nil { k.append(.hdr10Plus) }
        return k
    }

    func metadataWhat(_ project: Project) -> String { metadataKinds(project).map(Self.kindName).joined(separator: " and ") }

    func checks(for kind: MetadataKind) -> [MetadataCheck] { kind == .dolbyVision ? dolbyVisionChecks : hdr10PlusChecks }

    static func kindName(_ k: MetadataKind) -> String { k == .dolbyVision ? "Dolby Vision" : "HDR10+" }

    static func metadataURL(_ k: MetadataKind, _ hdr: HDRSettings) -> URL? {
        switch k {
        case .dolbyVision:
            switch hdr.dvSource {
            case .xml(let u)?: return u
            case .isxd(let p)?: return p.first?.file
            case nil: return nil
            }
        case .hdr10Plus: return hdr.hdr10plusJSON
        }
    }

    func metadataName(_ k: MetadataKind, _ project: Project) -> String? {
        k == .dolbyVision ? project.hdr.dvSource?.label : project.hdr.hdr10plusJSON?.lastPathComponent
    }

    private func metadataKey(_ k: MetadataKind, _ project: Project) -> String {
        (k == .dolbyVision ? "dv:" : "hdr10plus:") + (Self.metadataURL(k, project.hdr)?.path ?? "")
    }

    /// "ProRes 4444", "H.264", "HEVC", "JPEG 2000"
    static func codecShort(_ s: SourceVideo) -> String {
        var c = s.codecName.replacingOccurrences(of: "Apple ", with: "")
        if s.codec == "hevc", let p = s.profile, !p.isEmpty, p != "Main" { c += " " + p }
        return c
    }

    static func presetTitle(_ p: TranscodePreset) -> String {
        switch p {
        case .prores422HQ: return "Apple ProRes 422 HQ"
        case .prores422: return "Apple ProRes 422"
        case .h264Review: return "H.264 · review copy"
        case .hevcSDR: return "HEVC 10-bit · SDR"
        case .hevcDolbyVision: return "HEVC 10-bit · Dolby Vision"
        case .custom: return "Custom"
        }
    }

    static func presetShort(_ raw: String) -> String {
        switch raw {
        case "prores422HQ": return "ProRes 422 HQ"
        case "prores422": return "ProRes 422"
        case "h264Review": return "H.264"
        case "hevcSDR": return "HEVC SDR"
        default: return raw
        }
    }

    static func lowerFirst(_ s: String) -> String {
        guard let f = s.first else { return s }
        // keep names and acronyms as they are ("ProRes", "HEVC", "An MXF" → "an MXF")
        let second = s.dropFirst().first
        if f.isUppercase, let second, second.isLowercase, !s.hasPrefix("ProRes") { return f.lowercased() + s.dropFirst() }
        return s
    }

    // MARK: - Background work: thumbnail, letterbox, the Dolby Vision read

    private func startThumbnail(_ v: Track, project: Project) {
        guard let src = v.source else { return }
        let token = UUID(); thumbnailToken = token
        let url = v.url, index = v.streamIndex, fps = src.fps.value
        let frames = v.imfSegments.first.map { $0.entryPoint + $0.duration / 2 } ?? max(src.frames, project.videoFrames) / 2
        DispatchQueue.global(qos: .utility).async {
            let img = PictureSync.thumbnails(video: url, index: index, fps: fps, firstFrame: frames, count: 1, width: 384, height: 216).first
            DispatchQueue.main.async { if self.thumbnailToken == token { self.thumbnail = img } }
        }
    }

    private func startLetterbox(_ v: Track, project: Project) {
        letterboxCancel?.set()
        let flag = CancelFlag(); letterboxCancel = flag
        let url = v.url, index = v.streamIndex
        let duration = project.videoDuration > 0 ? project.videoDuration : (v.source?.duration ?? v.duration)
        measuringLetterbox = true
        DispatchQueue.global(qos: .utility).async {
            let lb = MetadataAnalysis.measureLetterbox(video: url, index: index, duration: duration, cancel: flag)
            DispatchQueue.main.async {
                guard !flag.isSet, self.picturePath == url.path else { return }
                self.measuringLetterbox = false
                self.letterbox = lb
            }
        }
    }

    private func dolbyVisionKey(_ project: Project) -> String {
        "\(project.hdr.dvSource?.label ?? "")|\(project.videoWidth)x\(project.videoHeight)|\(project.videoFrames)"
    }

    /// The Dolby Vision metadata read again with the picture's size and length when they changed (L5 and the frame
    /// count need the picture); a read already running for this picture is left alone
    private func ensureDolbyVisionChecked(_ project: Project) {
        let hdr = project.hdr
        guard hdr.dvSource != nil else { return }
        let key = dolbyVisionKey(project)
        guard key != dvCheckedKey else { return }
        dvCheckedKey = key
        if hdr.imf != nil { return }                     // the IMF's own track is read by applyIMF (rebuilding its XML is long)
        hdr.checkDolbyVision(width: project.videoWidth, height: project.videoHeight, frames: project.videoFrames)
    }
}

/// Who to re-check when the analysis inputs change (weak: the observation must not keep the project alive)
private final class VideoRecheckBox: @unchecked Sendable {
    weak var model: VideoPlanModel?
    weak var project: Project?
    init(model: VideoPlanModel, project: Project) { self.model = model; self.project = project }
}

/// What this Mac's ffmpeg can do (`Tools.encoders` / `Tools.filters`), learned once on a worker thread. Reading those
/// the first time on the main thread inside a view runs ffmpeg with `waitUntilExit`, which spins the run loop and can
/// re-enter the same view (a crash in dispatch_once): the Video tab waits for this instead.
@Observable final class VideoToolsGate {
    static let shared = VideoToolsGate()
    private(set) var ready = false
    private init() {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = Tools.encoders; _ = Tools.filters
            DispatchQueue.main.async { self.ready = true }
        }
    }
}

extension VideoPlanModel.Popup: Identifiable {
    var id: String {
        switch self {
        case .metadata(let k): return k == .dolbyVision ? "metadata-dv" : "metadata-hdr10plus"
        case .needsTranscode(let r): return "transcode-" + r
        }
    }
}
