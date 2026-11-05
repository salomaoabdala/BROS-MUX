# Beta 2.0.0 — the contract (exact signatures every agent codes against)

Source of truth for the agents. The wave-0 skeleton compiles exactly these declarations with stub bodies; each owner
replaces the stubs with the real implementation **without changing a signature**. Need a new cross-file symbol?
Declare it in your own file with your domain prefix; never edit another owner's file. Semantics are in
`PLANO-BETA-2.0.0.md` (Parte 1 = what the owner sees, Parte 2 = rules). UI text is English; units Mbps/Kbps, MB/s.

Agents: **E1** model & app shell plumbing · **E2** engine additions · **C** Cryo design system · **S** window shell ·
**V** Video tab · **A** Audio tab · **D** Delivery · **X** Subtitles + checking tools.

## Ownership

| Owner | Files |
|---|---|
| E1 | `BrosMux.swift` — everything EXCEPT the JobRunner/Verifier/GroupSources section (JobSpec … end of JobRunner) and removeStaleTemps |
| E2 | `BrosMux.swift` JobRunner section (struct JobSpec … end of `final class JobRunner`, incl. removeStaleTemps), `Transcode.swift` (additions only), `HDR.swift` (engine) |
| C | `Cryo.swift`, `Design.swift` |
| S | `Shell.swift`, `Welcome.swift` |
| V | `VideoTab.swift`, `VideoModel.swift`, `HDRViews.swift`, `TranscodeUI.swift` |
| A | `AudioTab.swift`, `MuxUI.swift`, `SyncViewer.swift`, `PictureSync.swift` (`enum PictureSync` frozen), `ChannelOrderUI.swift` |
| D | `DeliveryTab.swift`, `DeliveryEngine.swift`, `DeliveryJob.swift`, `DeliveryParts.swift`, `Monitor.swift` |
| X | `SubtitlesTab.swift`, `CheckerUI.swift`, `RenderQC.swift`, `AtmosViz.swift`, `Zidoo.swift` (ZidooSeal/ChecksSection look only) |
| nobody | `ABMark.swift`, `RenderQCEngine.swift`, `AtmosOAMD.swift`, `AtmosDecoder.swift`, `ChannelID.swift`, `Alignment.swift`, `ColorLUT.swift`, `MonoGroup.swift` |

E1 and E2 share `BrosMux.swift` in disjoint regions (merged with git). Neither touches the other's region.

## Invariants (all agents)

- Engine result strings never change (`JobRunner`, `Verifier`, `GroupSources`, `Transcode.encodeElementary/verifyElementary`,
  `TranscodeRunner`, `runJobCLI`, `TranscodeModel.cli`, `RenderQC.cli`, `pictureCLI`). The UI reads ✓/⚠/✗, never rewrites them.
- `Transcode.arguments`, `encodeElementary`'s command, `HDRSettings` stored defaults, the Quality/Speed/BitratePreset tables,
  `qc/reference/dv-command.txt`, `CLIArgs`/`buildProject` behaviour: untouched.
- `AppInfo` stays in `Design.swift` with the line `static let version = "2.0.0"`.
- With no `embeddedAudioAnswer` stored, `insert`, `makeGroup`, `chooseDefaultReference` behave exactly as before (the CLI path).
- `GUI code never uses TranscodeModel.shared` (it stays for `--transcode` and the old CLI only).
- New top-level names start with the owner's domain (Video*, Audio*, Subtitles*, Delivery*, Cryo*, Shell*). Reserved
  (exist already): OutputSection, ChecksSection, LogSheet, ResultBanner, NoticeStack, EmptyDropView, Chip, NoticeRow,
  KeyValueRow, TerminalBox, TabStrip, ReencodeBanner, Engine, EngineStatus, AcademySeal, ZidooSeal, StatuetteShape.
- Check with `nice -n 10 swiftc -typecheck -parse-as-library -swift-version 5 -target arm64-apple-macos14.0 *.swift`
  in your own worktree. Never run `./build.sh` (it wipes build.noindex) or `./qc.sh`.

## E1 · BrosMux.swift (model, routing, app plumbing)

```swift
enum AppMode: String, CaseIterable, Identifiable {
    case video, audio, subtitles, delivery           // WORKFLOW, in order
    case inspect, qc, atmos                           // CHECK A FILE, below the divider
    var id: String { rawValue }
    var label: String                                 // "Video" "Audio" "Subtitles" "Delivery" "File Checker" "Render QC" "Atmos Visualizer"
    var symbol: String                                // SF Symbol
    var step: Int?                                    // 1…4 for the workflow, nil for the tools
    var isWorkflow: Bool { step != nil }
    static let workflow: [AppMode] = [.video, .audio, .subtitles, .delivery]
    static let tools: [AppMode] = [.inspect, .qc, .atmos]
}

/// A stable name for an audio stream, or a group of mono streams, across re-reads of the files
struct StreamKey: Hashable, Codable { var path: String; var streams: [Int] }

enum AudioDelivery: String, CaseIterable, Identifiable, Codable {
    case copy, aac, pcm24
    var id: String { rawValue }
    var label: String                                 // "COPY · bit-exact" / "TRANSCODE → AAC" / "TRANSCODE → PCM 24-bit"
}

struct ProjectNotice: Identifiable, Equatable {
    let id = UUID(); var tab: AppMode; var text: String; var level: CheckLevel
}

// Track gains:
//     var delivery: AudioDelivery = .copy

// Project gains (all on the main actor, @Observable as the class already is):
//     let video = VideoPlanModel()                          // V's class; reset in clear()
//     var notices: [ProjectNotice]                          // REPLACES [String]; every existing append site gets a tab
//     func notices(for tab: AppMode) -> [ProjectNotice]
//     func post(_ text: String, tab: AppMode, level: CheckLevel = .info)
//     var embeddedAudioAnswer: [StreamKey: Bool] = [:]      // nil entry = not asked yet; reset in clear()
//     var pictureReplaceRequest: [URL]? = nil               // set by route() when a picture exists; V asks "Replace the picture?"
//     var batchRequest: [URL]? = nil                        // several pictures dropped at once; V asks "One delivery per file?"
//     func key(of t: Track) -> StreamKey                    // group = members' url + sorted stream indexes
//     func isEmbedded(_ t: Track) -> Bool                   // t.url == videoSource?.url (NOT fromVideoFile)
//     var videoSource: Track? { get }                      // first video track, included or not
//     var embeddedAudio: [Track] { get }
//     var userAudio: [Track] { get }
//     var outputAudio: [Track] { get }                      // included audio, output order
//     var subtitleTracks: [Track] { get }
//     var pendingAudioDecisions: [Track] { get }            // embedded audio with no stored answer
//     var metadataNotEmbedded: String? { get }              // DV/HDR10+ loaded and video.choice(self) != .hevcHDR
//     func pendingCount(for tab: AppMode) -> Int            // sidebar amber badge
//     func outputSlot(of id: UUID) -> Int?                  // 0-based among outputAudio
//     func binding(for id: UUID) -> Binding<Track>?         // for filtered lists and sheets
//     func route(_ urls: [URL])                             // THE routing rule (all drops, Finder opens, Add Files):
//                                                           //   picture → video tab (replace request if one exists; >1 → batchRequest)
//                                                           //   DV XML / HDR10+ JSON → video; audio → audio; subtitles → subtitles; .bmjob → delivery
//                                                           //   (DeliveryQueue.shared.load); tools tabs keep today's behaviour.
//                                                           //   A file landing on another tab than the current one posts
//                                                           //   "X goes on the Y tab — added there" on the current tab.
//     func confirmReplacePicture()                          // replaces: old picture, its embedded audio, timecode, answers;
//     func cancelReplacePicture()                           //   clears alignment (trims, syncApplied, syncReferenceID,
//                                                           //   referenceLateFrames via restore), hdr.imf/auto encode; notice
//     func setEmbeddedAudio(_ id: UUID, use: Bool)          // No → include=false; becomes syncReferenceID if none set or the
//                                                           //   current one has more channels. Yes → include=true; becomes the
//                                                           //   reference if none; if referenceLateFrames ≠ 0 and canTrim, its
//                                                           //   trimStart follows (exact sync), else a notice.
//     func moveAudio(_ id: UUID, toSlot k: Int?)            // nil = not in the file (include=false); taken slot = swap
//     func audioConversionReason(_ t: Track) -> String?     // why it can't go in as it is (container, trim on an untrimmable codec, MXF…)
//     func openInVideoTab(_ url: URL, target: VideoPlanModel.Choice)   // File Checker hand-off; asks via pictureReplaceRequest
//     func restore(referenceLateFrames: Double)             // set without the didSet shift (job rebuild, replace picture)
//     func makeGroup(_ ids: [UUID], listen: Bool)           // listen:false = no background ChannelID (job rebuild)
//     chooseDefaultReference(), makeGroup(), ungroup() carry embeddedAudioAnswer and the reference across regrouping.
//     autoAlign() no longer sets include=false on the reference when its answer is Yes.
//     busy stays project-local (loading, aligning) — the Delivery queue never locks the tabs.
//
// App plumbing in BrosMux.swift (E1):
//     - CommandMenu("Go"): ⌘1…⌘7 set project.mode (AppMode.workflow + tools order). Add Files ⌘O → openPanel (per tab).
//       Clear All ⌘N clears the project (asks if a job is queued from it — no, queue is independent; just clears).
//     - NSApp.appearance = .darkAqua at launch (Cryo is dark-only); the welcome sheet stays.
//     - AppDelegate: Finder opens → project.route(urls); quit guard only for project.aligning (renders are detached).
//     - Entry: case "--job-file": exit(DeliveryCLI.run(Array(args.dropFirst())))
//     - snapshot(): always dark; --tab NAME; --popup dv|transcode|useaudio|savejob|replace; --demo-running;
//       views drawn alone sit on CryoWindowBackground(progress: nil). After buildProject in snapshot mode: store
//       embeddedAudioAnswer from the CLI rule and call video.didAddVideo(project:). Old flags map:
//       default → .video; --transcode FILE [--to P] → .video with FILE and openInVideoTab target; --inspect/--atmos/
//       --welcome/--syncviewer/--pictureviewer/--channelsheet as today; --quality → the Audio tab's options view.
//     - CheckLevel.color / AcademyLevel.color / TrackKind.color use Cryo tokens.
```

## E2 · engine additions (BrosMux.swift JobRunner region, Transcode.swift, HDR.swift)

```swift
struct JobProgress: Codable, Equatable {
    enum Stage: String, Codable, CaseIterable {
        case readMetadata, pass1, pass2, encode, injectHDR10Plus, injectDV, interleave, trim, mux, mkv, headers,
             verifyPicture, verifyBits, sync, picture, academy, transcodeVideo, transcodeAudio, checkResult,
             renderQC, vmaf, finalize
        var title: String                             // "Pass 1 of 2", "Muxing", "Verifying bit for bit", …
    }
    var stage: Stage
    var title: String                                 // the same text onStage receives
    var fraction: Double                              // 0…1 inside the stage
    var frame: Int? = nil
    var totalFrames: Int? = nil
    var fps: Double? = nil                            // ffmpeg's fps= (cumulative); the monitor derives "now"
    var bitrateKbps: Double? = nil                    // nil for N/A (pass 1)
    var speed: Double? = nil
    var outBytes: Int64? = nil
}

// JobRunner gains (nil by default; called off the main thread, never block):
//     var onProgress: ((JobProgress) -> Void)?
//     var onFinding: ((String) -> Void)?             // each ✓/⚠/✗ line the moment it is produced (live view only)
//     var onWorkFolder: ((URL) -> Void)?             // the .BROS-MUX-tmp folder once created
//     static func plannedStages(_ spec: JobSpec) -> [(stage: JobProgress.Stage, weight: Double)]
// TranscodeRunner gains the same three callbacks (forwarded to its inner JobRunner on the DV/HDR10+ path) and
//     static func plannedStages(_ plan: TranscodePlan, runQC: Bool, runVMAF: Bool) -> [(stage: JobProgress.Stage, weight: Double)]
// Transcode.encode / twoPassStats / encodeElementary gain `progress: ((JobProgress) -> Void)? = nil`, parsed from the
//     SAME -progress output (frame=, fps=, bitrate=, total_size=, speed=); args and stage strings unchanged.
// removeStaleTemps skips a .BROS-MUX-tmp-* folder holding a `.lock` whose pid is alive; JobRunner/TranscodeRunner
//     write that `.lock` (pid) in their tmp folder and refresh its mtime while running.

/// One line of the metadata analysis shown in the Video tab's popup
struct MetadataCheck: Identifiable, Equatable {
    let id = UUID()
    var level: CheckLevel
    var title: String
    var detail: String
    var fix: Fix?
    enum Fix: Equatable { case convertGamut, keepSourcePrimaries, useMeasuredLight, qualityFloorOff, removeMetadata, copyText(String) }
}
enum MetadataAnalysis {
    struct Letterbox: Equatable, Codable { var width: Int; var height: Int; var top: Int; var bottom: Int; var left: Int; var right: Int }
    /// cropdetect on a few frames spread over the film (background queue; a few seconds)
    static func measureLetterbox(video: URL, index: Int, duration: Double, cancel: CancelFlag) -> Letterbox?
    /// waitingForPicture == true → lines that need the picture say "Waiting for the picture…" (level .info, never ✓)
    static func dolbyVision(_ hdr: HDRSettings, picture: SourceVideo?, frames: Int, fps: Double, letterbox: Letterbox?) -> [MetadataCheck]
    static func hdr10Plus(_ hdr: HDRSettings, picture: SourceVideo?, frames: Int, fps: Double) -> [MetadataCheck]
}
// DolbyVisionMeta.Summary gains: var level5: String?; var profile: String?; var l1MaxCLL: Int?; var l1MaxFALL: Int?;
//     var rate: Double?; var primaries: String?   (parsed from dovi_tool 2.3.4 output / the XML; nil when absent)

/// Audio TRANSCODE pre-step (run by the Delivery before JobRunner); the input is the bytes JobRunner would mux
enum AudioTranscode {
    static func problem(_ t: Track, to: AudioDelivery) -> String?        // AAC > 8 ch, float > 0 dBFS → PCM 24, Dolby source…
    /// Writes <folder>/audio-<n>.m4a (AAC, edit list kept) or .wav (PCM 24-bit, -rf64 auto); returns it
    static func prepare(_ t: Track, plan: TrimPlan?, to: AudioDelivery, folder: URL, index: Int, cancel: CancelFlag,
                        progress: (Double) -> Void) throws -> URL
    /// After the mux: lag 0 ± 1 sample against the trimmed source, per-channel level within ±0.1 dB, per-channel
    /// correlation > 0.9 (order unchanged). Returns ✓/✗ lines.
    static func verify(final: URL, audioOrdinal: Int, source: Track, plan: TrimPlan?, to: AudioDelivery) -> [String]
}
```

## C · Cryo.swift (+ Design.swift reskin, API unchanged)

```swift
enum Cryo {                                           // colour tokens (dark only)
    static let s0: Color /* #05080C */, s1: Color /* #0B1622 */, s2: Color /* #111A24 */, s3: Color /* #1E2A36 */
    static let ink: Color /* #E6EDF3 */, ink2: Color /* #9FB0BF */, ink3: Color /* #8396A6 */
    static let ice: Color /* #7FE7FF */, icePale: Color /* #B2F8F8 */, tint: Color /* #0E7490 */
    static let pass: Color /* #5EE6A0 */, attention: Color /* #FFB04A */, fail: Color /* #FF6B6B */,
               info: Color /* #8FA3B3 */, gold: Color /* #D8A84E */
}
enum CryoFont {                                       // the one place to switch to Archivo / Geist later
    static func title(_ size: CGFloat) -> Font        // SF Pro Expanded semibold
    static func body(_ size: CGFloat = 13) -> Font
    static func label(_ size: CGFloat = 10.5) -> Font // caps labels (use with .tracking)
    static func mono(_ size: CGFloat = 12) -> Font    // SF Mono, tabular digits
}
enum FileTouch: Equatable {
    case readOnly, copy, mux, transcode, pending      // pending = a decision is open (amber "DECIDE")
    var color: Color { get }
    var word: String { get }                          // "READ ONLY" "COPY · bit-exact" "MUX" "TRANSCODE" "DECIDE"
}
struct CryoWindowBackground: View { init(progress: Double?) }                  // slab, frost corners, grain, rim, edge light
struct CryoPanel<Content: View>: View { init(cornerRadius: CGFloat = 20, @ViewBuilder content: () -> Content) }   // glass (nav layer)
struct CryoSlot<Content: View>: View { init(highlighted: Bool = false, dimmed: Bool = false, @ViewBuilder content: () -> Content) }
struct CryoStrip<Trailing: View>: View {
    init(touch: FileTouch, title: String, text: String, @ViewBuilder trailing: () -> Trailing)
}
extension CryoStrip where Trailing == EmptyView { init(touch: FileTouch, title: String, text: String) }
struct CryoGoButtonStyle: ButtonStyle { enum Kind { case primary, amber, ghost, done }; init(_ kind: Kind = .primary) }
struct CryoButtonStyle: ButtonStyle { init(tint: Color? = nil) }
struct CryoChip: View { enum Style { case plain, lit, ref, amber, pass, fail }; init(_ text: String, style: Style = .plain) }
struct CryoLamp: View { init(_ color: Color, size: CGFloat = 10) }
struct CryoSectionHeader: View { init(_ title: String) }
struct CryoSegmented<T: Hashable>: View { init(selection: Binding<T>, options: [(value: T, label: String)]) }
struct CryoToggleStyle: ToggleStyle { init() }
struct CryoFieldLabel: View { init(_ text: String) }
extension View { func cryoField() -> some View }      // inset input look for TextField/Picker
struct CryoGauge: View { init(valueMs: Double?, rangeMs: ClosedRange<Double>, goodMs: ClosedRange<Double>, label: String) }
struct CryoAlertCard: View {
    struct Line: Identifiable { let id = UUID(); var level: CheckLevel; var title: String; var detail: String
        init(level: CheckLevel, title: String, detail: String = "") }
    struct Action { enum Role { case primary, secondary, destructive }
        var title: String; var role: Role; var run: () -> Void
        init(_ title: String, role: Role = .secondary, run: @escaping () -> Void) }
    init(logo: AnyView? = nil, title: String, subtitle: String? = nil, lines: [Line] = [],
         detected: String? = nil, recommendation: String? = nil, actions: [Action])
}
struct CryoDropZone: View { init(title: String, subtitle: String, systemImage: String, targeted: Bool, action: @escaping () -> Void) }
struct CryoSeal: View { enum Kind { case academy, zidoo }; init(kind: Kind, passed: Bool, caption: String) }
struct CryoTube: View { init(label: String, value: String, fraction: Double) }
struct CryoDiffRow: Identifiable { let id = UUID(); var label: String; var from: String; var to: String; var changed: Bool
    init(label: String, from: String, to: String, changed: Bool) }
struct CryoDiffTable: View { init(rows: [CryoDiffRow], fromTitle: String = "SOURCE", toTitle: String = "DESTINATION") }
struct CryoSignalLine: View { init(touch: FileTouch) }
struct DolbyVisionLogo: View { init(height: CGFloat = 18) }     // vector; uses Resources/Logos/dolby-vision.pdf if present
struct HDR10PlusLogo: View { init(height: CGFloat = 18) }       // vector; uses Resources/Logos/hdr10plus.pdf if present
@Observable final class EffectsGovernor {
    static let shared = EffectsGovernor()
    var calm = false                                  // D sets it while a job renders; ambient effects stop
    var reduceMotion: Bool { get }
}
// Moved here unchanged (signature kept): AcademySeal(level:caption:compact:), StatuetteShape
```

## S · Shell.swift

```swift
struct ContentView: View                              // Cryo window: CryoWindowBackground(progress: DeliveryQueue.shared.overall),
                                                      // sidebar (WORKFLOW + divider + CHECK A FILE), toolbar, strip, inspector
struct ShellSidebar: View { init(selection: Binding<AppMode>) }
struct ShellToolbar: ToolbarContent { init(project: Project, inspectorShown: Binding<Bool>) }
// Content per mode: VideoTab(targeted:) / AudioTab(targeted:) / SubtitlesTab(targeted:) / DeliveryTab(targeted:) /
//   InspectorView(targeted:) / RenderQCView(targeted:) / AtmosView(targeted:)
// Inspector per mode: VideoInspector() / AudioInspector() / SubtitlesInspector() / DeliveryInspector() / none /
//   RenderQCInspector() / AtmosInspector()
// Sidebar lines: project.video.sidebarLine(project:), AudioTab.sidebarLine(project:), SubtitlesTab.sidebarLine(project:),
//   DeliveryTab.sidebarLine(project:); amber badge = project.pendingCount(for:)
// Toolbar: NEXT: AUDIO → (video), NEXT: DELIVERY → (audio, subtitles); on .delivery it places DeliveryToolbarButtons(project:)
//   and binds NO ⌘↩ itself.
// Drops: project.route(urls) (Render QC / Atmos / File Checker keep their own single-file open).
```

## V · VideoModel.swift / VideoTab.swift / HDRViews.swift

```swift
struct VideoTranscodeSettings: Codable, Equatable {
    var preset: String                                // TranscodePreset raw: prores422HQ | prores422 | h264Review | hevcSDR
    var resolution: String = "same"                   // OutputResolution raw
    var toneMap: Bool = false
    var quality: String? = nil                        // HDRSettings.Quality raw (H.264/HEVC)
    var speed: String? = nil                          // HDRSettings.Speed raw
}
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
    init()
    func choice(_ project: Project) -> Choice         // project.hdr.encode ? .hevcHDR : transcode.map(.transcode) ?? .copy
    func choose(_ c: Choice, project: Project)        // the ONLY writer of hdr.encode / autoEnabledBy / autoReason
    func didAddVideo(project: Project)
    func didAddMetadata(kind: MetadataKind, url: URL, project: Project)
    func removeMetadata(project: Project)
    func reset()
    func touch(project: Project) -> FileTouch
    func touchText(project: Project) -> String
    func sidebarLine(project: Project) -> String
    func transcodePlan(project: Project) -> TranscodePlan?    // .transcode only (SDR), audio .none
    func legalTargets(project: Project) -> [VideoTargetOption]
}
struct VideoTab: View { let targeted: Bool }
struct VideoInspector: View { init() }
struct VideoMetadataPopup: View { init(project: Project) }
struct VideoTranscodeChooser: View { init(project: Project) }
// HDRViews.swift: HDRPanel, PlaybackPanel, HDRFileCard, PlaybackRows, RateControlRows (moved from HDR.swift, signatures kept)
```

## A · AudioTab.swift (+ MuxUI.swift)

```swift
struct AudioTab: View { let targeted: Bool; static func sidebarLine(project: Project) -> String }
struct AudioInspector: View { init() }
struct EmbeddedAudioPopover: View { init(project: Project, trackID: UUID) }
struct AudioOptionsView: View { init() }              // what --quality draws (channel map, disable extra audio, interleave)
// MuxUI.swift keeps (restyled): SyncPanel, SyncLights, GroupOffer, NoticeStack(tab:) — NoticeStack gains `tab: AppMode`.
// Deleted by A: MuxContent, MuxInspector, TrackListView, TrackRow, QualitySheet (its parts move to AudioOptionsView,
//   VideoInspector (fixColorTag, by V) and DeliveryParts (verify/picture check, by D)).
```

## D · DeliveryJob.swift / DeliveryEngine.swift / DeliveryTab.swift / DeliveryParts.swift

```swift
// DeliveryJob: exactly the schema in PLANO-BETA-2.0.0.md ("Arquivo de job"), schemaVersion 1, plus:
//     static func capture(_ project: Project) -> DeliveryJob
//     func rebuild(into project: Project) throws -> [String]      // synchronous, the order in the plan
//     static func canonicalText(_ project: Project) -> String     // commandPreview + per-track identity/flags + plans +
//                                                                 // reference identity + referenceOffset + video choice
//     func writeText(to url: URL) throws                          // the readable .job.txt
enum DeliveryState: String, Codable { case queued, running, done, warning, failed, cancelled }
struct DeliverySnapshot: Codable, Equatable {
    var stage: JobProgress.Stage?; var title: String; var stageFraction: Double; var overall: Double
    var frame: Int?; var totalFrames: Int?; var fpsAverage: Double?; var bitrateKbps: Double?
    var bytesWritten: Int64?; var bytesTotal: Int64?; var stageIndex: Int; var stageCount: Int
    var stagesDone: [JobProgress.Stage]; var started: Date; var updated: Date
}
struct DeliveryItem: Identifiable {
    let id: UUID; var job: DeliveryJob; var jobFile: URL; var state: DeliveryState
    var snapshot: DeliverySnapshot?; var findings: [String]; var resultLines: [String]; var output: URL?
}
struct DeliveryPreflightItem: Identifiable { let id = UUID(); var level: CheckLevel; var text: String; var tab: AppMode? }
@Observable final class DeliveryQueue {
    static let shared = DeliveryQueue()
    var items: [DeliveryItem] = []
    var current: DeliveryItem? { items.first { $0.state == .running } }
    var isRunning: Bool { current != nil }
    var overall: Double? { current?.snapshot?.overall }
    func preflight(_ project: Project) -> [DeliveryPreflightItem]
    func startNow(from project: Project)
    func enqueue(from project: Project)
    func enqueueBatch(_ pictures: [URL], template project: Project)
    func startQueue()
    func cancel(_ id: UUID)
    func remove(_ id: UUID)
    func saveWithPanel(from project: Project)
    func load(_ url: URL, into project: Project)
    func restoreAtLaunch()
    func loadDemoRunningJob()
}
enum DeliveryCLI { static func run(_ args: [String]) -> Int32 }   // --job-file A.bmjob [B.bmjob…] [--dry-run]
struct DeliveryTab: View { let targeted: Bool; static func sidebarLine(project: Project) -> String }
struct DeliveryInspector: View { init() }
struct DeliveryToolbarButtons: View { init(project: Project) }    // SAVE JOB… · ADD TO QUEUE · START DELIVERY (⌘↩)
struct SaveJobSheet: View { init(project: Project) }
// DeliveryParts.swift holds (moved from MuxUI.swift, D restyles/rebinds): OutputSection, AcademySection,
//   SummarySections, ResultBanner, LogSheet.
```

## X · SubtitlesTab.swift (+ checking tools)

```swift
struct SubtitlesTab: View { let targeted: Bool; static func sidebarLine(project: Project) -> String }
struct SubtitlesInspector: View { init() }
// CheckerUI: "Fix → Transcode to ProRes 422 HQ" calls project.openInVideoTab(u, target: .transcode(
//   VideoTranscodeSettings(preset: "prores422HQ"))) and project.mode = .video. EmptyDropView callers → CryoDropZone.
```
