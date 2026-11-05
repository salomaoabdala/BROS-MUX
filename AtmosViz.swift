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

/// The room as a hologram: an ice wireframe in the dark, faint floor grid, glowing objects with a soft halo and a drop
/// line to the floor. The one place in the app where a 3-D "hologram" look is used — it draws sound, never a picture.
/// The glow (camera bloom) and the smoothing of the object motion stop while a Delivery renders (EffectsGovernor.calm)
/// and the smoothing also under Reduce Motion.
final class AtmosScene {
    let scene = SCNScene()
    let camera = SCNNode()
    private var objectNodes: [Int: SCNNode] = [:]
    static let W: CGFloat = 10, D: CGFloat = 12, H: CGFloat = 4.5
    static let ear: CGFloat = 1.2        // height of the ear-level speaker plane (Dolby z = 0)
    /// Moves glide over one 30 Hz step instead of jumping (off while calm and under Reduce Motion)
    var smoothMotion = false

    private static func rgb(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: a)
    }
    static let ice = rgb(0x7FE7FF)
    static let icePale = rgb(0xB2F8F8)

    /// Object colours: a cool hologram family (ice, sky, periwinkle, lavender, orchid, pink, white…) that stays clear of
    /// the status colours (mint PASS, amber, red FAIL), since an object's colour is its name, never a verdict
    static let palette: [NSColor] = [
        rgb(0x7FE7FF), rgb(0xB79CFF), rgb(0xFF9CD6), rgb(0x5CA8FF), rgb(0xE6F7FF), rgb(0x4FE3D6),
        rgb(0xE39BFF), rgb(0x8FB2FF), rgb(0xB2F8F8), rgb(0x6E7BFF), rgb(0xFFC2E8), rgb(0x9FD4FF),
    ]
    static func color(_ id: Int) -> NSColor { palette[abs(id) % palette.count] }

    /// Dolby z: 0 = ear level, 1 = ceiling, -1 = floor
    static func position(_ x: Float, _ y: Float, _ z: Float) -> SCNVector3 {
        let zz = CGFloat(z)
        let height = zz >= 0 ? ear + zz * (H - ear) : ear * (1 + max(zz, -1))
        return SCNVector3((CGFloat(x) - 0.5) * W, height, (CGFloat(y) - 0.5) * D)
    }

    /// A self-lit material: hologram light doesn't depend on a lamp; `add` makes overlaps glow instead of hiding
    private static func glow(_ c: NSColor, additive: Bool = true) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = NSColor.black          // constant lighting adds diffuse and emission: emission alone keeps the hue
        m.lightingModel = .constant
        m.isDoubleSided = true
        let cc = c.usingColorSpace(.sRGB) ?? c
        if additive {
            // added light ignores alpha: the colour itself carries how much light (premultiplied)
            let a = cc.alphaComponent
            m.emission.contents = NSColor(srgbRed: cc.redComponent * a, green: cc.greenComponent * a, blue: cc.blueComponent * a, alpha: 1)
            m.blendMode = .add; m.writesToDepthBuffer = false
        } else {
            m.emission.contents = cc.withAlphaComponent(1)
            m.transparency = cc.alphaComponent
        }
        return m
    }

    init() {
        scene.background.contents = Self.rgb(0x05080C)
        let root = scene.rootNode

        // floor + grid
        let floor = SCNPlane(width: Self.W, height: Self.D)
        floor.firstMaterial = Self.glow(Self.rgb(0x07121A), additive: false)
        let floorNode = SCNNode(geometry: floor)
        floorNode.eulerAngles.x = -.pi / 2
        root.addChildNode(floorNode)
        let grid = Self.ice.withAlphaComponent(0.26)
        for i in 0...10 {
            let x = -Self.W / 2 + Self.W * CGFloat(i) / 10
            root.addChildNode(line(SCNVector3(x, 0.003, -Self.D / 2), SCNVector3(x, 0.003, Self.D / 2), grid, 0.007))
        }
        for i in 0...12 {
            let z = -Self.D / 2 + Self.D * CGFloat(i) / 12
            root.addChildNode(line(SCNVector3(-Self.W / 2, 0.003, z), SCNVector3(Self.W / 2, 0.003, z), grid, 0.007))
        }

        // room outline
        let edge = Self.ice.withAlphaComponent(0.95)
        let xs = [-Self.W / 2, Self.W / 2], zs = [-Self.D / 2, Self.D / 2]
        for x in xs { for z in zs { root.addChildNode(line(SCNVector3(x, 0, z), SCNVector3(x, Self.H, z), edge, 0.013)) } }
        for y in [0, Self.H] {
            for x in xs { root.addChildNode(line(SCNVector3(x, y, -Self.D / 2), SCNVector3(x, y, Self.D / 2), edge, 0.013)) }
            for z in zs { root.addChildNode(line(SCNVector3(-Self.W / 2, y, z), SCNVector3(Self.W / 2, y, z), edge, 0.013)) }
        }
        // the ear-level speaker plane, faint: it is where Dolby z = 0
        let plane = Self.ice.withAlphaComponent(0.32)
        for x in xs { root.addChildNode(line(SCNVector3(x, Self.ear, -Self.D / 2), SCNVector3(x, Self.ear, Self.D / 2), plane, 0.006)) }
        for z in zs { root.addChildNode(line(SCNVector3(-Self.W / 2, Self.ear, z), SCNVector3(Self.W / 2, Self.ear, z), plane, 0.006)) }

        // screen on the front wall: a pale sheet with a lit frame
        let sw = Self.W * 0.7, sh = Self.H * 0.55, sy = Self.H * 0.45, sz = -Self.D / 2 + 0.01
        let screen = SCNPlane(width: sw, height: sh)
        screen.firstMaterial = Self.glow(Self.icePale.withAlphaComponent(0.09))
        let screenNode = SCNNode(geometry: screen)
        screenNode.position = SCNVector3(0, sy, sz)
        root.addChildNode(screenNode)
        let frame = Self.icePale.withAlphaComponent(0.8)
        let l = -sw / 2, r = sw / 2, b = sy - sh / 2, t = sy + sh / 2
        root.addChildNode(line(SCNVector3(l, b, sz), SCNVector3(r, b, sz), frame, 0.01))
        root.addChildNode(line(SCNVector3(l, t, sz), SCNVector3(r, t, sz), frame, 0.01))
        root.addChildNode(line(SCNVector3(l, b, sz), SCNVector3(l, t, sz), frame, 0.01))
        root.addChildNode(line(SCNVector3(r, b, sz), SCNVector3(r, t, sz), frame, 0.01))

        // reference speakers (7.1.4)
        let speakers: [(Float, Float, Float)] = [
            (0, 0, 0), (0.5, 0, 0), (1, 0, 0),            // L C R
            (0, 0.55, 0), (1, 0.55, 0),                   // Lss Rss
            (0.1, 1, 0), (0.9, 1, 0),                     // Lrs Rrs
            (0.25, 0.25, 1), (0.75, 0.25, 1),             // Ltf Rtf
            (0.25, 0.75, 1), (0.75, 0.75, 1),             // Ltr Rtr
        ]
        for s in speakers {
            let box = SCNBox(width: 0.3, height: 0.3, length: 0.3, chamferRadius: 0.04)
            box.firstMaterial = Self.glow(Self.ice.withAlphaComponent(0.5))
            let n = SCNNode(geometry: box)
            var p = Self.position(s.0, s.1, s.2)
            if s.2 > 0.5 { p.y = Self.H - 0.18 }          // ceiling speakers sit just under the ceiling
            n.position = p
            root.addChildNode(n)
        }

        // listener (center of the room, ears at the speaker plane)
        let head = SCNSphere(radius: 0.22)
        head.firstMaterial = Self.glow(Self.icePale.withAlphaComponent(0.8))
        let headNode = SCNNode(geometry: head)
        headNode.position = SCNVector3(0, Self.ear, 0)
        root.addChildNode(headNode)
        let nose = SCNCone(topRadius: 0, bottomRadius: 0.08, height: 0.2)
        nose.firstMaterial = Self.glow(Self.icePale.withAlphaComponent(0.8))
        let noseNode = SCNNode(geometry: nose)
        noseNode.eulerAngles.x = -.pi / 2
        noseNode.position = SCNVector3(0, Self.ear, -0.28)
        root.addChildNode(noseNode)

        // camera: behind and above the listener, looking at the screen; bloom gives the hologram its glow
        camera.camera = SCNCamera()
        camera.camera?.fieldOfView = 52
        camera.camera?.wantsHDR = true
        camera.camera?.bloomThreshold = 0.45
        camera.camera?.bloomBlurRadius = 10
        camera.camera?.wantsExposureAdaptation = false
        camera.position = SCNVector3(0, 8.5, 13.5)
        camera.look(at: SCNVector3(0, 1.2, -1))
        root.addChildNode(camera)
        setGlow(true)
    }

    /// The bloom around the lit lines and objects; off while a Delivery renders (it costs GPU time)
    func setGlow(_ on: Bool) { camera.camera?.bloomIntensity = on ? 0.9 : 0 }

    private func line(_ a: SCNVector3, _ b: SCNVector3, _ color: NSColor, _ radius: CGFloat) -> SCNNode {
        let dx = b.x - a.x, dy = b.y - a.y, dz = b.z - a.z
        let len = (dx * dx + dy * dy + dz * dz).squareRoot()
        let c = SCNCylinder(radius: radius, height: len)
        c.radialSegmentCount = 6
        c.firstMaterial = Self.glow(color)
        let n = SCNNode(geometry: c)
        n.position = SCNVector3((a.x + b.x) / 2, (a.y + b.y) / 2, (a.z + b.z) / 2)
        n.look(at: b, up: scene.rootNode.worldUp, localFront: SCNVector3(0, 1, 0))
        return n
    }

    private func makeObjectNode(_ id: Int) -> SCNNode {
        let c = Self.color(id)
        let core = SCNSphere(radius: 0.3)
        core.firstMaterial = Self.glow(c, additive: false)
        core.firstMaterial?.isDoubleSided = false      // a see-through sphere must not show its own back faces
        let n = SCNNode(geometry: core)
        // a soft halo around the core: a radial glow that always faces the camera
        let halo = SCNPlane(width: 1.7, height: 1.7)
        halo.firstMaterial = Self.glow(c)
        halo.firstMaterial?.emission.contents = Self.haloImage(c)
        halo.firstMaterial?.transparent.contents = Self.haloImage(.white)
        let haloNode = SCNNode(geometry: halo)
        haloNode.constraints = [SCNBillboardConstraint()]
        haloNode.renderingOrder = 10
        n.addChildNode(haloNode)
        // a thin "drop line" down to the floor helps read the height
        let pole = SCNCylinder(radius: 0.012, height: 1)
        pole.radialSegmentCount = 6
        pole.firstMaterial = Self.glow(c.withAlphaComponent(0.7))
        let poleNode = SCNNode(geometry: pole)
        poleNode.name = "pole"
        n.addChildNode(poleNode)
        scene.rootNode.addChildNode(n)
        objectNodes[id] = n
        return n
    }

    /// A radial glow, bright in the middle and gone at the edge, in one colour (made once per colour)
    private static var halos: [String: NSImage] = [:]
    private static func haloImage(_ c: NSColor) -> NSImage {
        let key = c.description
        if let i = halos[key] { return i }
        let side = 128
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { r in
            let cc = c.usingColorSpace(.sRGB) ?? c
            let g = NSGradient(colors: [cc.withAlphaComponent(0.55), cc.withAlphaComponent(0.18), cc.withAlphaComponent(0)],
                               atLocations: [0, 0.4, 1], colorSpace: .sRGB)
            g?.draw(in: NSBezierPath(ovalIn: r), relativeCenterPosition: .zero)
            return true
        }
        halos[key] = img
        return img
    }

    /// Moves the spheres to the given frame (objects not present are hidden)
    func update(_ frame: VizFrame?) {
        SCNTransaction.begin()
        SCNTransaction.animationDuration = smoothMotion ? 1.0 / 30 : 0
        var seen = Set<Int>()
        for o in frame?.objects ?? [] where o.isVisible {
            let node = objectNodes[o.id] ?? makeObjectNode(o.id)
            let p = Self.position(o.x, o.y, o.z)
            let wasHidden = node.isHidden
            if wasHidden { SCNTransaction.disableActions = true }
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
            if wasHidden { SCNTransaction.disableActions = false }
            seen.insert(o.id)
        }
        for (id, n) in objectNodes where !seen.contains(id) { n.isHidden = true }
        SCNTransaction.commit()
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
        VStack(spacing: 0) {
            CryoStrip(touch: .readOnly, title: "ATMOS VISUALIZER",
                      text: "reads the Atmos object metadata, never changes the file — the sound you hear is your Mac's own Dolby decode")
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder var content: some View {
        if viz.url == nil {
            CryoDropZone(title: "Drop a Dolby Atmos file",
                         subtitle: "E-AC-3 JOC (Dolby Digital Plus with Dolby Atmos) in .mp4, .mov or .ec3 — the objects of the mix are shown moving in a 3D room, in sync with the audio.",
                         systemImage: AppMode.atmos.symbol, targeted: targeted) { project.openPanel() }
        } else if viz.loading {
            VStack(spacing: 10) {
                ProgressView().controlSize(.small).tint(Cryo.ice)
                Text(viz.progressText).font(CryoFont.body()).foregroundStyle(Cryo.ink2)
                Text(viz.url?.lastPathComponent ?? "").font(CryoFont.mono(11)).foregroundStyle(Cryo.ink3)
            }
        } else if let e = viz.error {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    ChecksSection.Status(level: .fail)
                    Text("Couldn't read the Atmos objects").font(CryoFont.title(15)).foregroundStyle(Cryo.ink)
                }
                Text(e).font(CryoFont.body(12.5)).foregroundStyle(Cryo.ink2).fixedSize(horizontal: false, vertical: true)
                Button("Choose Another File…") { project.openPanel() }.buttonStyle(CryoButtonStyle())
            }
            .padding(18)
            .frame(maxWidth: 560, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Cryo.s1))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Cryo.fail.opacity(0.35), lineWidth: 1))
        } else {
            VStack(spacing: 0) {
                SceneView(scene: viz.scene.scene, pointOfView: viz.scene.camera, options: [.allowsCameraControl])
                    .background(Cryo.s0)
                    .overlay(alignment: .topLeading) {
                        Text("Drag to orbit · scroll to zoom").font(CryoFont.body(11)).foregroundStyle(Cryo.ink3).padding(12)
                    }
                    .overlay(alignment: .topTrailing) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("OBJECTS NOW").font(CryoFont.label(9.5)).tracking(1.2).foregroundStyle(Cryo.ink3)
                            Text("\(viz.current.count)").font(CryoFont.mono(13)).foregroundStyle(Cryo.ice)
                        }
                        .padding(12)
                    }
                transport
            }
            .onAppear { applyEffects() }
            .onChange(of: EffectsGovernor.shared.calm) { applyEffects() }
            .onChange(of: viz.playing) { applyEffects() }
        }
    }

    /// The glow and the smoothed motion are the only effects; both stop while a Delivery renders, the motion also under Reduce Motion
    func applyEffects() {
        let g = EffectsGovernor.shared
        viz.scene.setGlow(!g.calm)
        viz.scene.smoothMotion = viz.playing && !g.calm && !g.reduceMotion
    }

    /// Play / pause, the time and a scrubber, in a bar under the room
    var transport: some View {
        @Bindable var viz = project.atmos
        return HStack(spacing: 14) {
            Button { viz.togglePlay() } label: {
                Image(systemName: viz.playing ? "pause.fill" : "play.fill").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Cryo.ice).frame(width: 30, height: 30)
                    .background(Circle().fill(Cryo.s2))
                    .overlay(Circle().strokeBorder(Cryo.ice.opacity(0.45), lineWidth: 1))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain).keyboardShortcut(.space, modifiers: []).help(viz.playing ? "Pause (space)" : "Play (space)")
            Text(Fmt.duration(viz.time)).font(CryoFont.mono(12.5)).foregroundStyle(Cryo.ink)
            Slider(value: Binding(get: { viz.time }, set: { viz.seek($0) }), in: 0...max(viz.duration, 0.1)).tint(Cryo.ice)
            Text(Fmt.duration(viz.duration)).font(CryoFont.mono(12.5)).foregroundStyle(Cryo.ink3)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Cryo.s1)
        .overlay(alignment: .top) { Rectangle().fill(Cryo.s3).frame(height: 1) }
    }
}

/// The inspector of the Atmos screen: the file and the objects at the playhead
struct AtmosInspector: View {
    @Environment(Project.self) private var project
    var viz: AtmosVisualizer { project.atmos }

    var body: some View {
        if viz.url == nil || viz.loading || viz.error != nil {
            Text(viz.url == nil ? "No Atmos file" : viz.loading ? "Reading the file…" : "Nothing to show")
                .font(CryoFont.title(14)).foregroundStyle(Cryo.ink3)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    CryoSectionHeader("Dolby Atmos")
                    CryoSlot {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(viz.url?.lastPathComponent ?? "").font(CryoFont.body(13).weight(.medium)).foregroundStyle(Cryo.ink).lineLimit(2)
                            ForEach(Array(viz.summary.enumerated()), id: \.offset) { _, s in
                                Text(s).font(CryoFont.body(12)).foregroundStyle(Cryo.ink2).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    HStack(alignment: .firstTextBaseline) {
                        CryoSectionHeader("Objects now")
                        Text("\(viz.current.count)").font(CryoFont.mono(12)).foregroundStyle(Cryo.ice)
                    }
                    CryoSlot {
                        VStack(alignment: .leading, spacing: 7) {
                            if viz.current.isEmpty {
                                Text("No object is sounding at this moment.").font(CryoFont.body(12)).foregroundStyle(Cryo.ink3)
                            }
                            ForEach(viz.current) { o in
                                let c = Color(nsColor: AtmosScene.color(o.id))
                                HStack(spacing: 8) {
                                    Circle().fill(c).frame(width: 9, height: 9).accessibilityHidden(true)
                                    Text("Object \(o.id)").font(CryoFont.body(12).weight(.medium)).foregroundStyle(Cryo.ink).frame(width: 74, alignment: .leading)
                                    Text(String(format: "x %.2f  y %.2f  z %.2f", o.x, o.y, o.z)).font(CryoFont.mono(11)).foregroundStyle(Cryo.ink2)
                                    Spacer(minLength: 4)
                                    Capsule().fill(Cryo.s3).frame(width: 40, height: 5)
                                        .overlay(alignment: .leading) {
                                            Capsule().fill(c).frame(width: CGFloat(40 * max(0, min(1, o.gain))), height: 5)
                                        }
                                        .accessibilityLabel(String(format: "gain %.0f %%", o.gain * 100))
                                }
                            }
                        }
                    }
                    Text("x: left → right · y: front (screen) → back · z: ear level → ceiling (Dolby room coordinates). Positions come from the Atmos object metadata in the stream; idle clusters parked at the front-left corner are hidden. The sound you hear is your Mac's own Dolby decode.")
                        .font(CryoFont.body(11)).foregroundStyle(Cryo.ink3).fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
            }
        }
    }
}
