// BROS-MUX — Dolby Atmos Visualizer
// Shows the objects of an E-AC-3 JOC (Dolby Digital Plus with Dolby Atmos) mix moving in a 3D room,
// in sync with the audio. Positions come from the stream's object audio metadata (OAMD).

import SwiftUI
import SceneKit
import AVFoundation

/// One object sample, in Dolby's normalized room coordinates (ETSI TS 103 420):
/// x 0 = left wall → 1 = right wall · y 0 = front (screen) → 1 = back wall ·
/// z 0 = ear-level speaker plane → 1 = ceiling (negative values go down toward the floor)
struct VizObject: Identifiable {
    let id: Int
    let x: Float, y: Float, z: Float
    let gain: Float      // 0…1 (linear)
    let size: Float      // 0…1
    let isBed: Bool
    var isParked = false // idle cluster parked by the encoder at (0,0,0)
    var isActive = true  // false when the bitstream flags the object as silent
    var isVisible: Bool { !isBed && !isParked && isActive }
}
struct VizFrame { let time: Double; let objects: [VizObject] }

// MARK: - 3D scene

final class AtmosScene {
    let scene = SCNScene()
    let camera = SCNNode()
    private var objectNodes: [Int: SCNNode] = [:]
    static let W: CGFloat = 10, D: CGFloat = 12, H: CGFloat = 4.5
    static let ear: CGFloat = 1.2        // height of the ear-level speaker plane (Dolby z = 0)

    static let palette: [NSColor] = [
        .systemRed, .systemOrange, .systemYellow, .systemGreen, .systemMint, .systemTeal, .systemCyan, .systemBlue,
        .systemIndigo, .systemPurple, .systemPink, .systemBrown,
        NSColor(red: 1, green: 0.55, blue: 0.75, alpha: 1), NSColor(red: 0.55, green: 0.9, blue: 0.4, alpha: 1),
        NSColor(red: 0.4, green: 0.75, blue: 1, alpha: 1), NSColor(red: 1, green: 0.85, blue: 0.5, alpha: 1),
    ]
    static func color(_ id: Int) -> NSColor { palette[abs(id) % palette.count] }

    /// Dolby z: 0 = ear level, 1 = ceiling, -1 = floor
    static func position(_ x: Float, _ y: Float, _ z: Float) -> SCNVector3 {
        let zz = CGFloat(z)
        let height = zz >= 0 ? ear + zz * (H - ear) : ear * (1 + max(zz, -1))
        return SCNVector3((CGFloat(x) - 0.5) * W, height, (CGFloat(y) - 0.5) * D)
    }

    init() {
        scene.background.contents = NSColor(calibratedWhite: 0.07, alpha: 1)
        let root = scene.rootNode

        // floor + grid
        let floor = SCNPlane(width: Self.W, height: Self.D)
        floor.firstMaterial?.diffuse.contents = NSColor(calibratedWhite: 0.13, alpha: 1)
        floor.firstMaterial?.isDoubleSided = true
        let floorNode = SCNNode(geometry: floor)
        floorNode.eulerAngles.x = -.pi / 2
        root.addChildNode(floorNode)
        let gridColor = NSColor(calibratedWhite: 0.22, alpha: 1)
        for i in 0...10 {
            let x = -Self.W / 2 + Self.W * CGFloat(i) / 10
            root.addChildNode(line(SCNVector3(x, 0.002, -Self.D / 2), SCNVector3(x, 0.002, Self.D / 2), gridColor, 0.008))
        }
        for i in 0...12 {
            let z = -Self.D / 2 + Self.D * CGFloat(i) / 12
            root.addChildNode(line(SCNVector3(-Self.W / 2, 0.002, z), SCNVector3(Self.W / 2, 0.002, z), gridColor, 0.008))
        }

        // room outline
        let edge = NSColor(calibratedWhite: 0.55, alpha: 1)
        let xs = [-Self.W / 2, Self.W / 2], zs = [-Self.D / 2, Self.D / 2]
        for x in xs { for z in zs { root.addChildNode(line(SCNVector3(x, 0, z), SCNVector3(x, Self.H, z), edge, 0.015)) } }
        for y in [0, Self.H] {
            for x in xs { root.addChildNode(line(SCNVector3(x, y, -Self.D / 2), SCNVector3(x, y, Self.D / 2), edge, 0.015)) }
            for z in zs { root.addChildNode(line(SCNVector3(-Self.W / 2, y, z), SCNVector3(Self.W / 2, y, z), edge, 0.015)) }
        }

        // screen on the front wall
        let screen = SCNPlane(width: Self.W * 0.7, height: Self.H * 0.55)
        screen.firstMaterial?.diffuse.contents = NSColor(calibratedRed: 0.25, green: 0.3, blue: 0.42, alpha: 1)
        screen.firstMaterial?.emission.contents = NSColor(calibratedRed: 0.12, green: 0.15, blue: 0.24, alpha: 1)
        let screenNode = SCNNode(geometry: screen)
        screenNode.position = SCNVector3(0, Self.H * 0.45, -Self.D / 2 + 0.01)
        root.addChildNode(screenNode)

        // reference speakers (7.1.4)
        let speakers: [(Float, Float, Float)] = [
            (0, 0, 0), (0.5, 0, 0), (1, 0, 0),            // L C R
            (0, 0.55, 0), (1, 0.55, 0),                   // Lss Rss
            (0.1, 1, 0), (0.9, 1, 0),                     // Lrs Rrs
            (0.25, 0.25, 1), (0.75, 0.25, 1),             // Ltf Rtf
            (0.25, 0.75, 1), (0.75, 0.75, 1),             // Ltr Rtr
        ]
        for s in speakers {
            let box = SCNBox(width: 0.32, height: 0.32, length: 0.32, chamferRadius: 0.05)
            box.firstMaterial?.diffuse.contents = NSColor(calibratedWhite: 0.45, alpha: 1)
            let n = SCNNode(geometry: box)
            var p = Self.position(s.0, s.1, s.2)
            if s.2 > 0.5 { p.y = Self.H - 0.18 }          // ceiling speakers sit just under the ceiling
            n.position = p
            root.addChildNode(n)
        }

        // listener (center of the room, ears at the speaker plane)
        let head = SCNSphere(radius: 0.22)
        head.firstMaterial?.diffuse.contents = NSColor(calibratedWhite: 0.85, alpha: 1)
        let headNode = SCNNode(geometry: head)
        headNode.position = SCNVector3(0, Self.ear, 0)
        root.addChildNode(headNode)
        let nose = SCNCone(topRadius: 0, bottomRadius: 0.08, height: 0.2)
        nose.firstMaterial?.diffuse.contents = NSColor(calibratedWhite: 0.85, alpha: 1)
        let noseNode = SCNNode(geometry: nose)
        noseNode.eulerAngles.x = -.pi / 2
        noseNode.position = SCNVector3(0, Self.ear, -0.28)
        root.addChildNode(noseNode)

        // lights
        let ambient = SCNNode(); ambient.light = SCNLight(); ambient.light?.type = .ambient
        ambient.light?.color = NSColor(calibratedWhite: 0.45, alpha: 1)
        root.addChildNode(ambient)
        let key = SCNNode(); key.light = SCNLight(); key.light?.type = .omni
        key.position = SCNVector3(0, Self.H * 2, Self.D)
        root.addChildNode(key)

        // camera: behind and above the listener, looking at the screen
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 52
        camera.position = SCNVector3(0, 8.5, 13.5)
        camera.look(at: SCNVector3(0, 1.2, -1))
        root.addChildNode(camera)
    }

    private func line(_ a: SCNVector3, _ b: SCNVector3, _ color: NSColor, _ radius: CGFloat) -> SCNNode {
        let dx = b.x - a.x, dy = b.y - a.y, dz = b.z - a.z
        let len = (dx * dx + dy * dy + dz * dz).squareRoot()
        let c = SCNCylinder(radius: radius, height: len)
        c.firstMaterial?.diffuse.contents = color
        c.firstMaterial?.lightingModel = .constant
        let n = SCNNode(geometry: c)
        n.position = SCNVector3((a.x + b.x) / 2, (a.y + b.y) / 2, (a.z + b.z) / 2)
        n.look(at: b, up: scene.rootNode.worldUp, localFront: SCNVector3(0, 1, 0))
        return n
    }

    private func makeObjectNode(_ id: Int) -> SCNNode {
        let s = SCNSphere(radius: 0.32)
        let m = s.firstMaterial!
        m.diffuse.contents = Self.color(id)
        m.emission.contents = Self.color(id).withAlphaComponent(0.6)
        m.lightingModel = .physicallyBased
        let n = SCNNode(geometry: s)
        // a thin "drop line" down to the floor helps read the height
        let pole = SCNCylinder(radius: 0.012, height: 1)
        pole.firstMaterial?.diffuse.contents = Self.color(id).withAlphaComponent(0.5)
        pole.firstMaterial?.lightingModel = .constant
        let poleNode = SCNNode(geometry: pole)
        poleNode.name = "pole"
        n.addChildNode(poleNode)
        scene.rootNode.addChildNode(n)
        objectNodes[id] = n
        return n
    }

    /// Moves the spheres to the given frame (objects not present are hidden)
    func update(_ frame: VizFrame?) {
        var seen = Set<Int>()
        for o in frame?.objects ?? [] where o.isVisible {
            let node = objectNodes[o.id] ?? makeObjectNode(o.id)
            let p = Self.position(o.x, o.y, o.z)
            node.position = p
            let scale = CGFloat(0.7 + 1.3 * max(0, min(1, o.size)))
            node.scale = SCNVector3(scale, scale, scale)
            node.opacity = CGFloat(0.25 + 0.75 * max(0, min(1, o.gain)))
            if let pole = node.childNode(withName: "pole", recursively: false) {
                let h = max(0.001, p.y)
                (pole.geometry as? SCNCylinder)?.height = h / scale
                pole.position = SCNVector3(0, -h / 2 / scale, 0)
            }
            node.isHidden = false
            seen.insert(o.id)
        }
        for (id, n) in objectNodes where !seen.contains(id) { n.isHidden = true }
    }

    /// Renders the scene to an image (for documentation / offscreen checks)
    func snapshot(size: CGSize) -> NSImage {
        let r = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        r.scene = scene
        r.pointOfView = camera
        return r.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
    }
}

/// Command line: renders the 3D scene to a PNG.
/// --atmos-snapshot -o out.png [FILE] [-t seconds]   (no FILE = demo objects at known positions)
func atmosSnapshot(_ args: [String]) {
    _ = NSApplication.shared
    var out = "atmos.png", file: String?, t = 0.0
    var i = 0
    while i < args.count {
        switch args[i] {
        case "-o": i += 1; if i < args.count { out = args[i] }
        case "-t": i += 1; if i < args.count { t = Double(args[i]) ?? 0 }
        default: file = args[i]
        }
        i += 1
    }
    let scene = AtmosScene()
    var frame: VizFrame
    if let file {
        do {
            let r = try AtmosDecoder.decode(URL(fileURLWithPath: file)) { print("  …", $0) }
            r.summary.forEach { print("  •", $0) }
            let v = AtmosVisualizer()
            v.frames = r.frames; v.duration = r.frames.last?.time ?? 0
            frame = v.frame(at: t) ?? VizFrame(time: t, objects: [])
            print(String(format: "frame at %.3f s: %d objects", frame.time, frame.objects.count))
            for o in frame.objects {
                let tag = o.isBed ? " (bed)" : o.isParked ? " (parked)" : o.isActive ? "" : " (silent)"
                print(String(format: "  obj %2d%@ x %.3f y %.3f z %.3f gain %.2f size %.2f", o.id, tag, o.x, o.y, o.z, o.gain, o.size))
            }
        } catch { print("ERROR:", error.localizedDescription); return }
    } else {
        // demo: corners, center, ceiling — easy to check the mapping by eye
        frame = VizFrame(time: 0, objects: [
            VizObject(id: 0, x: 0, y: 0, z: 0, gain: 1, size: 0, isBed: false),        // front-left, floor
            VizObject(id: 1, x: 1, y: 0, z: 0, gain: 1, size: 0, isBed: false),        // front-right, floor
            VizObject(id: 2, x: 0.5, y: 0.5, z: 1, gain: 1, size: 0.5, isBed: false),  // center, ceiling
            VizObject(id: 3, x: 0, y: 1, z: 0.5, gain: 0.6, size: 0, isBed: false),    // back-left, mid height
            VizObject(id: 4, x: 1, y: 1, z: 1, gain: 0.3, size: 1, isBed: false),      // back-right, ceiling
            VizObject(id: 7, x: 0.5, y: 0.1, z: 0.3, gain: 1, size: 0.2, isBed: false),// near the screen
        ])
    }
    scene.update(frame)
    let img = scene.snapshot(size: CGSize(width: 1600, height: 1000))
    if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: out)); print("snapshot:", out)
    }
}

// MARK: - Model

@Observable
final class AtmosVisualizer {
    var url: URL?
    var loading = false
    var progressText = ""
    var error: String?
    var summary: [String] = []
    var frames: [VizFrame] = []
    var duration = 0.0
    var time = 0.0
    var playing = false
    var current: [VizObject] = []

    @ObservationIgnored let scene = AtmosScene()
    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var generation = 0

    func load(_ u: URL) {
        stop()
        generation += 1
        let g = generation
        url = u; loading = true; error = nil; frames = []; summary = []; current = []; time = 0; duration = 0
        progressText = "Reading the Atmos metadata…"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try AtmosDecoder.decode(u) { p in
                DispatchQueue.main.async { if g == self.generation { self.progressText = p } }
            } }
            DispatchQueue.main.async {
                guard g == self.generation else { return }
                self.loading = false
                switch result {
                case .success(let r):
                    self.frames = r.frames
                    self.summary = r.summary
                    self.duration = r.frames.last?.time ?? 0
                    self.player = AVPlayer(url: u)
                    self.setTime(0)
                case .failure(let e):
                    self.error = e.localizedDescription
                }
            }
        }
    }

    func frame(at t: Double) -> VizFrame? {
        guard !frames.isEmpty else { return nil }
        var lo = 0, hi = frames.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if frames[mid].time <= t { lo = mid } else { hi = mid - 1 }
        }
        return frames[lo]
    }

    func setTime(_ t: Double) {
        time = max(0, min(t, duration))
        let f = frame(at: time)
        current = (f?.objects ?? []).filter(\.isVisible).sorted { $0.id < $1.id }
        scene.update(f)
    }

    func seek(_ t: Double) {
        setTime(t)
        player?.seek(to: CMTime(seconds: time, preferredTimescale: 48000), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func togglePlay() {
        guard let player else { return }
        if playing {
            player.pause(); playing = false
            if let o = timeObserver { player.removeTimeObserver(o); timeObserver = nil }
        } else {
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
                self?.setTime(t.seconds)
            }
            player.play(); playing = true
        }
    }

    func pause() { if playing { togglePlay() } }

    func stop() {
        if let player, let o = timeObserver { player.removeTimeObserver(o) }
        timeObserver = nil
        player?.pause(); player = nil; playing = false
    }
}

// MARK: - View

struct AtmosView: View {
    @Environment(Project.self) private var project
    let targeted: Bool

    var viz: AtmosVisualizer { project.atmos }

    var body: some View {
        if viz.url == nil {
            EmptyDropView(targeted: targeted, title: "Drop a Dolby Atmos file",
                          subtitle: "E-AC-3 JOC (Dolby Digital Plus with Dolby Atmos) in .mp4, .mov or .ec3 — the objects of the mix are shown moving in a 3D room, in sync with the audio.")
        } else if viz.loading {
            ProgressView(viz.progressText).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let e = viz.error {
            ContentUnavailableView {
                Label("Couldn't read the Atmos objects", systemImage: "exclamationmark.triangle")
            } description: {
                Text(e).frame(maxWidth: 520)
            } actions: {
                Button("Choose Another File…") { project.openPanel() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                SceneView(scene: viz.scene.scene, pointOfView: viz.scene.camera,
                          options: [.allowsCameraControl, .autoenablesDefaultLighting])
                    .overlay(alignment: .topLeading) {
                        Text("Drag to orbit · scroll to zoom").font(.caption).foregroundStyle(.white.opacity(0.6)).padding(12)
                    }
                transport
            }
        }
    }

    /// Play / pause, the time and a scrubber, in a bar under the room
    var transport: some View {
        @Bindable var viz = project.atmos
        return HStack(spacing: 12) {
            Button { viz.togglePlay() } label: {
                Image(systemName: viz.playing ? "pause.fill" : "play.fill").font(.title3).frame(width: 24)
            }
            .buttonStyle(.borderless).keyboardShortcut(.space, modifiers: []).help(viz.playing ? "Pause (space)" : "Play (space)")
            Text(Fmt.duration(viz.time)).font(.system(.body, design: .monospaced)).monospacedDigit()
            Slider(value: Binding(get: { viz.time }, set: { viz.seek($0) }), in: 0...max(viz.duration, 0.1))
            Text(Fmt.duration(viz.duration)).font(.system(.body, design: .monospaced)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, DS.margin).padding(.vertical, 10)
        .background(.bar)
    }
}

/// The inspector of the Atmos screen: the file and the objects at the playhead
struct AtmosInspector: View {
    @Environment(Project.self) private var project
    var viz: AtmosVisualizer { project.atmos }

    var body: some View {
        if viz.url == nil || viz.loading || viz.error != nil {
            Text(viz.url == nil ? "No Atmos File" : viz.loading ? "Reading the File…" : "Nothing to Show")
                .font(.title3).foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Form {
                Section {
                    LabeledContent("File") { Text(viz.url?.lastPathComponent ?? "").lineLimit(2).multilineTextAlignment(.trailing) }
                    ForEach(Array(viz.summary.enumerated()), id: \.offset) { _, s in
                        Text(s).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                } header: {
                    Text("Dolby Atmos")
                }
                Section {
                    ForEach(viz.current) { o in
                        HStack(spacing: 8) {
                            Circle().fill(Color(nsColor: AtmosScene.color(o.id))).frame(width: 9, height: 9)
                            Text("Object \(o.id)").font(.subheadline.weight(.medium)).frame(width: 70, alignment: .leading)
                            Text(String(format: "x %.2f  y %.2f  z %.2f", o.x, o.y, o.z))
                                .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                            Spacer()
                            Capsule().fill(Color.secondary.opacity(0.2)).frame(width: 40, height: 5)
                                .overlay(alignment: .leading) {
                                    Capsule().fill(Color(nsColor: AtmosScene.color(o.id))).frame(width: CGFloat(40 * max(0, min(1, o.gain))), height: 5)
                                }
                                .accessibilityLabel(String(format: "gain %.0f %%", o.gain * 100))
                        }
                    }
                } header: {
                    Text("Objects now · \(viz.current.count)")
                } footer: {
                    Text("x: left → right · y: front (screen) → back · z: ear level → ceiling (Dolby room coordinates). Positions come from the Atmos object metadata in the stream; idle clusters parked at the front-left corner are hidden. The sound you hear is your Mac's own Dolby decode.")
                }
            }
            .formStyle(.grouped)
        }
    }
}
