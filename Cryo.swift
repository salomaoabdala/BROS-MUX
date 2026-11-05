// BROS-MUX Beta 2.0.0 — Cryo, the design language ("A · CRYO", dark only): colour tokens, type, motion, textures and the
// pieces every tab is built from.
//
// The window is an opaque blue-black slab lit cyan at the rim, like engraved edge-lit acrylic. Frost lives only in the
// window corners and in the drop zones. System glass (macOS 26) is only the navigation layer (CryoPanel); content sits in
// opaque recessed slots. The bottom edge light is the job progress bar. Status colours never decorate: PASS mint,
// ATTENTION amber, FAIL #FF6B6B, always with an icon and a word. Cyan is identity, focus and light — never "OK". Gold is
// the Academy seal only. Pictures sit on a neutral surround (no cyan, no glass over an image). A transcode is always
// announced on an opaque amber plate. Reduce Transparency drops frost and grain, Reduce Motion drops every animation,
// Increase Contrast drops the glows and thickens the borders. Every texture is drawn in code (no image files).

import SwiftUI
import AppKit

private func cryoHex(_ v: UInt32, _ opacity: Double = 1) -> Color {
    Color(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255, opacity: opacity)
}

// MARK: - Tokens

/// Colour tokens (dark only). Text contrast, WCAG 2: ink ≥ 12:1 and ink2 ≥ 6.5:1 on every surface; ink3 (#8396A6) is
/// ≥ 4.78:1 on s3 and on the glass, so it is safe everywhere.
enum Cryo {
    static let s0: Color = cryoHex(0x05080C)          // the window slab, the ground of images
    static let s1: Color = cryoHex(0x0B1622)          // panels, plates
    static let s2: Color = cryoHex(0x111A24)          // rows, cards
    static let s3: Color = cryoHex(0x1E2A36)          // raised surfaces
    static let ink: Color = cryoHex(0xE6EDF3)
    static let ink2: Color = cryoHex(0x9FB0BF)
    static let ink3: Color = cryoHex(0x8396A6)
    static let ice: Color = cryoHex(0x7FE7FF)         // identity, focus, active, light — never "OK"
    static let icePale: Color = cryoHex(0xB2F8F8)     // text on the cyan tint
    static let tint: Color = cryoHex(0x0E7490)        // cyan fills (white on it is 5.4:1 — the accent colour)
    static let pass: Color = cryoHex(0x5EE6A0)
    static let attention: Color = cryoHex(0xFFB04A)
    static let fail: Color = cryoHex(0xFF6B6B)
    static let info: Color = cryoHex(0x8FA3B3)
    static let gold: Color = cryoHex(0xD8A84E)        // the Academy seal only

    // Light, taken from the prototype (edge highlight, progress head, lamp and LED depth, rings, code)
    static let iceHot: Color = cryoHex(0xD9FBFF)
    static let iceWhite: Color = cryoHex(0xE9FDFF)
    static let iceDeep: Color = cryoHex(0x0B6F86)
    static let iceRing: Color = cryoHex(0xAAF0FF)
    static let goText: Color = cryoHex(0xEAFDFF)
    static let codeText: Color = cryoHex(0xBFE9F2)
    static let amberInk: Color = cryoHex(0x1A1206)    // text on solid amber (10:1)
    static let hairline: Color = cryoHex(0x8CDCFF, 0.10)

    // Neutral image surround: black ground, grey ring, no cyan, no glass
    static let imageGround: Color = .black
    static let imageRing: Color = cryoHex(0x96A0AA, 0.35)
    static let scope: Color = cryoHex(0x06090C)
    static let timecodeInk: Color = cryoHex(0xD9DDE1)

    /// The slab: opaque, a faint vertical light
    static let slab = LinearGradient(stops: [.init(color: cryoHex(0x060B12), location: 0), .init(color: cryoHex(0x05090E), location: 0.6),
                                             .init(color: cryoHex(0x070F16), location: 1)], startPoint: .top, endPoint: .bottom)
    /// A recessed slot: opaque, darker at the top where the inner shadow falls
    static let recess = LinearGradient(colors: [cryoHex(0x03070B), cryoHex(0x081119)], startPoint: .top, endPoint: .bottom)
    /// The opaque attention surface (alerts, the transcode plate): warm dark, never translucent
    static let warm = LinearGradient(colors: [cryoHex(0x241A0C), cryoHex(0x0E0D0C)], startPoint: .top, endPoint: .bottom)
    /// The opaque sheet / card surface
    static let sheet = LinearGradient(colors: [cryoHex(0x0E1A26), cryoHex(0x060C12)], startPoint: .top, endPoint: .bottom)
    /// Our own glass tint (the fallback before macOS 26, and the look under the system glass)
    static let glassFill = LinearGradient(stops: [.init(color: cryoHex(0x96E1FF, 0.075), location: 0), .init(color: cryoHex(0x96E1FF, 0.028), location: 0.4),
                                                  .init(color: cryoHex(0x96E1FF, 0.045), location: 1)], startPoint: .top, endPoint: .bottom)

    /// The status colour of a check (the one mapping every Cryo piece uses)
    static func status(_ level: CheckLevel) -> Color {
        switch level { case .ok: return pass; case .warn: return attention; case .fail: return fail; case .info: return info }
    }
    /// The word that goes with the status colour (status is never colour alone); nil for plain information
    static func word(_ level: CheckLevel) -> String? {
        switch level { case .ok: return "PASS"; case .warn: return "ATTENTION"; case .fail: return "FAIL"; case .info: return nil }
    }
    /// `c` blended toward `other` by `f` (0…1), in sRGB: lamp highlights and opaque tinted surfaces
    static func mix(_ c: Color, _ other: Color, _ f: Double) -> Color {
        let a = NSColor(c).usingColorSpace(.sRGB) ?? NSColor(c)
        let b = NSColor(other).usingColorSpace(.sRGB) ?? NSColor(other)
        return Color(nsColor: a.blended(withFraction: CGFloat(max(0, min(1, f))), of: b) ?? a)
    }
    /// A system colour handed to an old API (Chip, IconTile, TabStrip…) turned into its Cryo token
    static func mapped(_ c: Color) -> Color {
        switch c {
        case .green, .mint: return pass
        case .orange, .yellow: return attention
        case .red, .pink: return fail
        case .blue, .accentColor, .cyan, .teal, .indigo, .purple: return ice
        case .secondary, .gray, .primary: return ink2
        default: return c
        }
    }
    /// Caps for labels and headers, keeping the units and the one mixed-case word as they are written
    /// ("Bitrate (Mbps)" → "BITRATE (Mbps)", "COPY · bit-exact" stays).
    static func caps(_ s: String) -> String {
        var out = s.uppercased()
        for (re, keep) in capsKeep { out = re.stringByReplacingMatches(in: out, range: NSRange(out.startIndex..., in: out), withTemplate: keep) }
        return out
    }
    private static let capsKeep: [(NSRegularExpression, String)] =
        ["Mbps", "Kbps", "MB/s", "KB/s", "GB/s", "kHz", "Hz", "ms", "dBFS", "dBTP", "dB", "LUFS", "bit-exact"].compactMap { t in
            (try? NSRegularExpression(pattern: "(?<![A-Z0-9])" + NSRegularExpression.escapedPattern(for: t.uppercased()) + "(?![A-Z0-9])")).map { ($0, NSRegularExpression.escapedTemplate(for: t)) }
        }
}

/// The one place to switch to Archivo / Geist later
enum CryoFont {
    /// SF Pro Expanded semibold
    static func title(_ size: CGFloat) -> Font { Font.system(size: size, weight: .semibold).width(.expanded) }
    static func body(_ size: CGFloat = 13) -> Font { Font.system(size: size) }
    static func body(_ size: CGFloat, weight: Font.Weight) -> Font { Font.system(size: size, weight: weight) }
    /// Caps labels (use with .tracking)
    static func label(_ size: CGFloat = 10.5) -> Font { Font.system(size: size, weight: .bold) }
    /// SF Mono, tabular digits
    static func mono(_ size: CGFloat = 12) -> Font { Font.system(size: size, design: .monospaced).monospacedDigit() }
    /// Expanded bold: plate titles and the go buttons
    static func plate(_ size: CGFloat = 11.5) -> Font { Font.system(size: size, weight: .bold).width(.expanded) }
    /// Big light numbers (percent, frames)
    static func readout(_ size: CGFloat = 30) -> Font { Font.system(size: size, weight: .light, design: .monospaced).monospacedDigit() }
}

/// The motion budget (the research's timings, not the prototype's): short, never endless, nothing on a failure
enum CryoMotion {
    static let press = Animation.spring(duration: 0.1, bounce: 0)          // buttons: scale 0.97
    static let select = Animation.spring(duration: 0.25, bounce: 0.1)      // pill, switch
    static let needle = Animation.spring(duration: 0.4, bounce: 0.12)
    static let stamp = Animation.spring(duration: 0.35, bounce: 0.2)       // seals, ≤ 400 ms
    static let progress = Animation.linear(duration: 0.25)                 // values arrive 1–4 times a second
    static let frost = Animation.easeOut(duration: 0.3)                    // the drop zone's frost receding
    static func gated(_ a: Animation, _ reduceMotion: Bool) -> Animation? { reduceMotion ? nil : a }
}

/// What a tab (or a track) does to the file
enum FileTouch: Equatable {
    case readOnly, copy, mux, transcode, pending      // pending = a decision is open (amber "DECIDE")
    var color: Color {
        switch self {
        case .readOnly: return Cryo.info
        case .copy, .mux: return Cryo.ice
        case .transcode, .pending: return Cryo.attention
        }
    }
    var word: String {
        switch self {
        case .readOnly: return "READ ONLY"
        case .copy: return "COPY · bit-exact"
        case .mux: return "MUX"
        case .transcode: return "TRANSCODE"
        case .pending: return "DECIDE"
        }
    }
    /// Amber: the bits change, or a decision is still open
    var isAmber: Bool { self == .transcode || self == .pending }
}

// MARK: - Textures (procedural: drawn once in code, cached as images)

private struct CryoRNG {
    var s: UInt64
    init(_ seed: UInt64) { s = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed }
    mutating func next() -> CGFloat {
        s ^= s << 13; s ^= s >> 7; s ^= s << 17
        return CGFloat(Double(s >> 11) / Double(UInt64(1) << 53))
    }
}

/// Frost (window corners, drop zones) and grain, generated once with a fixed seed (snapshots stay identical)
enum CryoTexture {
    static let frostA: CGImage? = frost(seed: 0x51F1_5EED_0BAD_CAFE, pixels: 768)
    static let frostB: CGImage? = frost(seed: 0xC0FF_EE11_D00D_F00D, pixels: 768)
    static let grain: CGImage? = grain(seed: 0x2545_F491_4F6C_DD1D, pixels: 192)
    private static let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    /// Frost growing from the top-left corner: a faint haze, a crust of soft fog, feathery fern crystals (a stem with
    /// pairs of barbs at ±60°, each barb barbed again), a few hexagonal stars and speckle — all fading fast with the
    /// distance from the corner, so it never sits bright behind text
    static func frost(seed: UInt64, pixels: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let n = CGFloat(pixels)
        ctx.translateBy(x: 0, y: n); ctx.scaleBy(x: 1, y: -1)              // (0, 0) = the corner, at the top left
        ctx.setLineCap(.round)
        var rng = CryoRNG(seed)
        func frostColor(_ a: CGFloat) -> CGColor { CGColor(colorSpace: space, components: [0.86, 0.97, 1, max(0, min(1, a))]) ?? .white }
        func fade(_ x: CGFloat, _ y: CGFloat) -> CGFloat { max(0, 1 - (x * x + y * y).squareRoot() / (n * 0.95)) }
        if let haze = CGGradient(colorsSpace: space, colors: [frostColor(0.22), frostColor(0.06), frostColor(0)] as CFArray, locations: [0, 0.35, 1]) {
            ctx.drawRadialGradient(haze, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: n * 0.85, options: [])
        }
        for _ in 0..<320 {                                                    // the crust: soft fog clumps
            let d = pow(rng.next(), 1.7) * n * 0.8, th = rng.next() * .pi / 2
            let cx = cos(th) * d, cy = sin(th) * d
            let f = pow(fade(cx, cy), 2)
            let r = 6 + rng.next() * 26
            guard f > 0.02, let g = CGGradient(colorsSpace: space, colors: [frostColor((0.05 + 0.08 * rng.next()) * f), frostColor(0)] as CFArray,
                                               locations: [0, 1]) else { continue }
            ctx.drawRadialGradient(g, startCenter: CGPoint(x: cx, y: cy), startRadius: 0, endCenter: CGPoint(x: cx, y: cy), endRadius: r, options: [])
        }
        func line(_ x: CGFloat, _ y: CGFloat, _ x2: CGFloat, _ y2: CGFloat, _ w: CGFloat, _ a: CGFloat) {
            let f = fade((x + x2) / 2, (y + y2) / 2)
            guard f > 0.01 else { return }
            ctx.setStrokeColor(frostColor(a * pow(f, 1.7)))
            ctx.setLineWidth(w)
            ctx.move(to: CGPoint(x: x, y: y)); ctx.addLine(to: CGPoint(x: x2, y: y2)); ctx.strokePath()
        }
        /// A barb: a short straight crystal with its own tiny barbs
        func barb(_ x: CGFloat, _ y: CGFloat, _ a: CGFloat, _ len: CGFloat, _ w: CGFloat, _ sub: Bool) {
            let x2 = x + cos(a) * len, y2 = y + sin(a) * len
            line(x, y, x2, y2, w, 0.75)
            guard sub, len > 5 else { return }
            let k = 1 + Int(rng.next() * 3)
            for i in 1...k {
                let t = CGFloat(i) / CGFloat(k + 1)
                let ox = x + cos(a) * len * t, oy = y + sin(a) * len * t
                let s = len * 0.32 * (1 - t * 0.5)
                for side in [CGFloat(1), -1] where rng.next() < 0.8 {
                    let b = a + side * .pi / 3
                    line(ox, oy, ox + cos(b) * s, oy + sin(b) * s, w * 0.7, 0.6)
                }
            }
        }
        /// A fern: a gently curving stem with barbs in pairs, longest near the root
        func fern(_ x0: CGFloat, _ y0: CGFloat, _ a0: CGFloat, _ len: CGFloat, _ w: CGFloat) {
            var x = x0, y = y0, a = a0
            let steps = 9
            let step = len / CGFloat(steps)
            for i in 0..<steps {
                let t = CGFloat(i) / CGFloat(steps)
                a += (rng.next() - 0.5) * 0.16
                let x2 = x + cos(a) * step, y2 = y + sin(a) * step
                line(x, y, x2, y2, w * (1 - t * 0.5), 0.85)
                let bl = len * (0.30 - 0.22 * t) * (0.7 + 0.5 * rng.next())
                for side in [CGFloat(1), -1] where rng.next() < 0.85 {
                    barb(x2, y2, a + side * .pi / 3 + (rng.next() - 0.5) * 0.12, bl, w * 0.55, true)
                }
                x = x2; y = y2
            }
        }
        for _ in 0..<46 {                                                     // ferns growing in from the two edges
            let top = rng.next() < 0.5
            let u = pow(rng.next(), 1.5) * 0.85
            let a = (top ? CGFloat.pi / 2 : 0) + (top ? -1 : 1) * rng.next() * 0.55 + (rng.next() - 0.5) * 0.35
            let len = n * (0.05 + 0.11 * rng.next()) * (1 - u * 0.6)
            fern(top ? u * n : -1, top ? -1 : u * n, a, len, 0.9 + rng.next() * 0.5)
        }
        for _ in 0..<6 {                                                      // a few longer ferns out of the corner itself
            fern(0, 0, .pi / 4 + (rng.next() - 0.5) * 0.9, n * (0.12 + 0.08 * rng.next()), 1.2)
        }
        for _ in 0..<36 {                                                     // loose hexagonal stars
            let d = pow(rng.next(), 1.3) * n * 0.55, th = rng.next() * .pi / 2
            let cx = cos(th) * d, cy = sin(th) * d
            let s = 2 + rng.next() * 5, rot = rng.next() * .pi / 3
            for j in 0..<6 { barb(cx, cy, rot + CGFloat(j) * .pi / 3, s, 0.6, false) }
        }
        for _ in 0..<2600 {                                                   // speckle
            let d = pow(rng.next(), 1.8) * n * 0.9, th = rng.next() * .pi / 2
            let px = cos(th) * d, py = sin(th) * d
            let r = 0.3 + rng.next() * 0.8
            ctx.setFillColor(frostColor(0.75 * pow(fade(px, py), 1.5) * rng.next()))
            ctx.fillEllipse(in: CGRect(x: px - r, y: py - r, width: r * 2, height: r * 2))
        }
        return ctx.makeImage()
    }

    /// Fine film grain: faint light and dark specks (premultiplied), tiled over the slab
    static func grain(seed: UInt64, pixels: Int) -> CGImage? {
        var rng = CryoRNG(seed)
        var bytes = [UInt8](repeating: 0, count: pixels * pixels * 4)
        for i in 0..<(pixels * pixels) {
            let a = UInt8(min(255, rng.next() * rng.next() * 60))
            let v: UInt8 = rng.next() < 0.55 ? a : 0
            bytes[i * 4] = v; bytes[i * 4 + 1] = v; bytes[i * 4 + 2] = v; bytes[i * 4 + 3] = a
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(width: pixels, height: pixels, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: pixels * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// Frost in the four corners of whatever it covers (the two textures, mirrored, so no corner repeats its neighbour)
private struct CryoFrostCorners: View {
    var opacity: Double
    var fraction: CGFloat = 0.34
    var maxSide: CGFloat = 520
    var body: some View {
        GeometryReader { g in
            let side = min(maxSide, max(g.size.width, g.size.height) * fraction)
            ZStack {
                corner(CryoTexture.frostA, side).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                corner(CryoTexture.frostB, side).scaleEffect(x: -1, y: 1).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                corner(CryoTexture.frostB, side).scaleEffect(x: 1, y: -1).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                corner(CryoTexture.frostA, side).scaleEffect(x: -1, y: -1).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
        .opacity(opacity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
    @ViewBuilder func corner(_ img: CGImage?, _ side: CGFloat) -> some View {
        if let img { Image(decorative: img, scale: 1).resizable().interpolation(.high).frame(width: side, height: side) }
    }
}

private struct CryoGrain: View {
    var opacity: Double
    var body: some View {
        if let g = CryoTexture.grain {
            Image(decorative: g, scale: 2).resizable(resizingMode: .tile).interpolation(.none)
                .opacity(opacity).allowsHitTesting(false).accessibilityHidden(true)
        }
    }
}

// MARK: - The window

/// The window slab; while a Delivery renders, the bottom edge light is its progress bar
struct CryoWindowBackground: View {
    let progress: Double?
    init(progress: Double?) { self.progress = progress }
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let increased = contrast == .increased
        ZStack {
            Cryo.slab
            CryoIceLight()
            if !reduceTransparency {
                CryoFrostCorners(opacity: 0.75, fraction: 0.28, maxSide: 430)
                CryoGrain(opacity: 0.6)
            }
            CryoRim(increased: increased)
            CryoEdgeLight(progress: progress, glow: !increased, animated: !reduceMotion)
        }
        .ignoresSafeArea()
    }
}

/// The faint cold light inside the slab: pooled above the bottom edge, cast from the top left
private struct CryoIceLight: View {
    var body: some View {
        ZStack {
            RadialGradient(colors: [Cryo.tint.opacity(0.12), .clear], center: UnitPoint(x: 0.1, y: -0.05), startRadius: 0, endRadius: 760)
            GeometryReader { g in
                EllipticalGradient(stops: [.init(color: Cryo.ice.opacity(0.14), location: 0), .init(color: Cryo.ice.opacity(0.04), location: 0.5),
                                           .init(color: .clear, location: 1)], center: .bottom, startRadiusFraction: 0, endRadiusFraction: 0.5)
                    .frame(width: g.size.width * 1.1, height: 300)
                    .position(x: g.size.width / 2, y: g.size.height - 150)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The 1-px rim light along the four edges: brightest at the top-left and bottom-right, like edge-lit acrylic. Each edge
/// fades out before the corner, so the light fits any window corner radius (the system draws the corner itself).
private struct CryoRim: View {
    var increased: Bool
    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height, m: CGFloat = 22
            let lw: CGFloat = increased ? 2 : 1
            ZStack {
                edge(increased ? 0.6 : 0.65, increased ? 0.6 : 0.06, horizontal: true).frame(width: max(0, w - 2 * m), height: lw).position(x: w / 2, y: lw / 2)
                edge(increased ? 0.6 : 0.16, increased ? 0.6 : 0.55, horizontal: true).frame(width: max(0, w - 2 * m), height: lw).position(x: w / 2, y: h - lw / 2)
                edge(increased ? 0.6 : 0.65, increased ? 0.6 : 0.14, horizontal: false).frame(width: lw, height: max(0, h - 2 * m)).position(x: lw / 2, y: h / 2)
                edge(increased ? 0.6 : 0.05, increased ? 0.6 : 0.55, horizontal: false).frame(width: lw, height: max(0, h - 2 * m)).position(x: w - lw / 2, y: h / 2)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
    /// One edge: from `a` to `b` (opacities), fading to nothing at both ends
    func edge(_ a: Double, _ b: Double, horizontal: Bool) -> some View {
        let c = increased ? Color.white : cryoHex(0xC8F6FF)
        return Rectangle().fill(LinearGradient(stops: [.init(color: c.opacity(0), location: 0), .init(color: c.opacity(a), location: 0.06),
                                                       .init(color: c.opacity((a + b) / 2 * 0.6), location: 0.5),
                                                       .init(color: c.opacity(b), location: 0.94), .init(color: c.opacity(0), location: 1)],
                                               startPoint: horizontal ? .leading : .top, endPoint: horizontal ? .trailing : .bottom))
    }
}

/// The 2-px light at the bottom edge; with a progress, a 3-px bar with a bright head fills it left to right
private struct CryoEdgeLight: View {
    let progress: Double?
    let glow: Bool
    let animated: Bool
    var body: some View {
        GeometryReader { g in
            let w = max(0, g.size.width - 80)
            ZStack(alignment: .bottomLeading) {
                Capsule()
                    .fill(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: Cryo.ice.opacity(0.9), location: 0.12),
                                                 .init(color: Cryo.iceHot, location: 0.5), .init(color: Cryo.ice.opacity(0.9), location: 0.88),
                                                 .init(color: .clear, location: 1)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: w, height: 2)
                    .shadow(color: glow ? Cryo.ice.opacity(0.75) : .clear, radius: 5)
                    .shadow(color: glow ? Cryo.ice.opacity(0.22) : .clear, radius: 18)
                    .opacity(progress == nil ? 1 : 0.25)
                if let p = progress {
                    let pw = max(3, w * CGFloat(max(0, min(1, p))))
                    Capsule()
                        .fill(LinearGradient(colors: [Cryo.ice.opacity(0.6), Cryo.iceWhite], startPoint: .leading, endPoint: .trailing))
                        .frame(width: pw, height: 3)
                        .shadow(color: glow ? Cryo.ice.opacity(0.9) : .clear, radius: 6)
                        .shadow(color: glow ? Cryo.ice.opacity(0.35) : .clear, radius: 20)
                    Circle().fill(Color.white).frame(width: 10, height: 10)
                        .shadow(color: glow ? Cryo.ice.opacity(0.95) : .clear, radius: 7)
                        .offset(x: pw - 5, y: 3.5)
                }
            }
            .animation(animated ? CryoMotion.progress : nil, value: progress)
            .padding(.leading, 40).padding(.bottom, 2)
            .frame(width: g.size.width, height: g.size.height, alignment: .bottomLeading)
        }
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityHidden(progress == nil)
        .accessibilityLabel("Delivery progress")
        .accessibilityValue(progress.map { "\(Int(($0 * 100).rounded())) percent" } ?? "")
    }
}

// MARK: - Surfaces

/// Glass (the navigation layer: sidebar cards, toolbar pills, the run bay, the inspector). System glass on macOS 26,
/// our own frosted tint before; solid with a hairline under Reduce Transparency and Increase Contrast.
struct CryoPanel<Content: View>: View {
    let cornerRadius: CGFloat
    let content: Content
    init(cornerRadius: CGFloat = 20, @ViewBuilder content: () -> Content) { self.cornerRadius = cornerRadius; self.content = content() }
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let solid = reduceTransparency || contrast == .increased
        content
            .modifier(CryoGlassSurface(shape: shape, solid: solid))
            .overlay(shape.strokeBorder(solid ? AnyShapeStyle(contrast == .increased ? Color.white.opacity(0.7) : Cryo.ice.opacity(0.12))
                                              : AnyShapeStyle(LinearGradient(stops: [.init(color: Color.white.opacity(0.18), location: 0),
                                                                                    .init(color: cryoHex(0xA0EBFF, 0.10), location: 0.12),
                                                                                    .init(color: cryoHex(0xA0EBFF, 0.08), location: 0.85),
                                                                                    .init(color: Cryo.ice.opacity(0.16), location: 1)],
                                                                             startPoint: .top, endPoint: .bottom)),
                                        lineWidth: contrast == .increased ? 2 : 1))
    }
}

private struct CryoGlassSurface<S: Shape>: ViewModifier {
    let shape: S
    let solid: Bool
    func body(content: Content) -> some View {
        if solid {
            content.background(shape.fill(Cryo.s1))
        } else if #available(macOS 26, *) {
            content.glassEffect(.regular.tint(Cryo.ice.opacity(0.05)), in: shape)
        } else {
            content
                .background(shape.fill(Cryo.glassFill))
                .background(shape.fill(.ultraThinMaterial))
                .shadow(color: .black.opacity(0.55), radius: 20, y: 12)
        }
    }
}

/// An opaque recessed slot (the content layer — never glass). Highlighted = the ice edge glows (a swap, the selection);
/// dimmed = not in the file: the content fades and loses its colour, the edge turns dashed.
struct CryoSlot<Content: View>: View {
    let highlighted: Bool
    let dimmed: Bool
    let content: Content
    init(highlighted: Bool = false, dimmed: Bool = false, @ViewBuilder content: () -> Content) {
        self.highlighted = highlighted; self.dimmed = dimmed; self.content = content()
    }
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        let increased = contrast == .increased
        content
            .saturation(dimmed ? 0.4 : 1)
            .opacity(dimmed ? 0.55 : 1)
            .padding(EdgeInsets(top: 14, leading: 14, bottom: 14, trailing: 16))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(Cryo.recess.shadow(.inner(color: .black.opacity(0.9), radius: 10, y: 8))))
            .overlay(shape.inset(by: 1).strokeBorder(Color.white.opacity(0.03), lineWidth: 1).mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .center)))
            .overlay(ring(shape, increased))
            .shadow(color: highlighted && !increased ? Cryo.ice.opacity(0.45) : .clear, radius: 10)
    }

    @ViewBuilder func ring(_ shape: RoundedRectangle, _ increased: Bool) -> some View {
        if highlighted {
            shape.strokeBorder(Cryo.ice.opacity(increased ? 1 : 0.75), lineWidth: increased ? 2 : 1.5)
        } else if dimmed {
            shape.strokeBorder(Cryo.ink3.opacity(increased ? 0.9 : 0.4), style: StrokeStyle(lineWidth: increased ? 2 : 1, dash: [5, 4]))
        } else {
            shape.strokeBorder(increased ? Color.white.opacity(0.5) : Cryo.hairline, lineWidth: increased ? 2 : 1)
        }
    }
}

/// The plate at the top of a tab: what it does to the file. COPY / MUX glow ice; TRANSCODE and DECIDE are an opaque
/// amber plate with high contrast — a transcode must be impossible to miss. Place it edge to edge at the top of the tab:
/// it draws its own margin.
struct CryoStrip<Trailing: View>: View {
    let touch: FileTouch
    let title: String
    let text: String
    let trailing: Trailing
    init(touch: FileTouch, title: String, text: String, @ViewBuilder trailing: () -> Trailing) {
        self.touch = touch; self.title = title; self.text = text; self.trailing = trailing()
    }
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        CryoPlateRow(touch: touch, title: title, text: text, symbol: nil) { trailing }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
    }
}
extension CryoStrip where Trailing == EmptyView {
    init(touch: FileTouch, title: String, text: String) { self.init(touch: touch, title: title, text: text) { EmptyView() } }
}

/// The plate itself (CryoStrip and the old TabStrip share it)
struct CryoPlateRow<Trailing: View>: View {
    let touch: FileTouch
    let title: String
    let text: String
    let symbol: String?
    let trailing: Trailing
    init(touch: FileTouch, title: String, text: String, symbol: String?, @ViewBuilder trailing: () -> Trailing) {
        self.touch = touch; self.title = title; self.text = text; self.symbol = symbol; self.trailing = trailing()
    }
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        let amber = touch.isAmber
        let increased = contrast == .increased
        HStack(spacing: 12) {
            CryoLamp(touch.color, size: 10)
            if let symbol { Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(touch.color).accessibilityHidden(true) }
            if !title.isEmpty {
                Text(Cryo.caps(title)).font(CryoFont.plate(11.5)).tracking(1.6)
                    .foregroundStyle(amber ? Cryo.attention : Cryo.ink).fixedSize()
            }
            CryoTouchBadge(touch: touch)
            Text(text).font(CryoFont.body(12.5)).foregroundStyle(amber ? Cryo.ink : Cryo.ink2)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true).layoutPriority(-1)
            Spacer(minLength: 8)
            trailing
        }
        .padding(.leading, amber ? 18 : 16).padding(.trailing, 10).padding(.vertical, 7)
        .frame(minHeight: 44)
        .background(plate(shape, amber))
        .overlay(alignment: .leading) {
            if amber { Rectangle().fill(Cryo.attention).frame(width: 4).accessibilityHidden(true) }
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(ringColor(amber, increased), lineWidth: amber || increased ? 1.5 : 1))
        .shadow(color: amber && !increased ? Cryo.attention.opacity(0.28) : .clear, radius: 12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title), \(touch.word), \(text)")
    }

    @ViewBuilder func plate(_ shape: RoundedRectangle, _ amber: Bool) -> some View {
        if amber {
            ZStack {
                shape.fill(cryoHex(0x1A1309))
                shape.fill(LinearGradient(colors: [Cryo.attention.opacity(0.16), Cryo.attention.opacity(0.05)], startPoint: .leading, endPoint: .trailing))
            }
        } else {
            ZStack {
                shape.fill(Cryo.s1)
                shape.fill(LinearGradient(colors: [touch.color.opacity(0.08), touch.color.opacity(0.02)], startPoint: .leading, endPoint: .trailing))
                shape.inset(by: 0.5).stroke(Color.white.opacity(0.06), lineWidth: 1).mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .init(x: 0.5, y: 0.2)))
            }
        }
    }
    func ringColor(_ amber: Bool, _ increased: Bool) -> Color {
        if increased { return amber ? Cryo.attention : Color.white.opacity(0.6) }
        return amber ? Cryo.attention.opacity(0.65) : touch.color.opacity(0.16)
    }
}

/// The word of a FileTouch as a badge: lit ice for COPY / MUX, grey for READ ONLY, solid amber for TRANSCODE, amber
/// outline for DECIDE
struct CryoTouchBadge: View {
    let touch: FileTouch
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        HStack(spacing: 5) {
            if touch == .transcode { Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 9, weight: .bold)) }
            if touch == .pending { Image(systemName: "hand.raised.fill").font(.system(size: 9, weight: .bold)) }
            Text(touch.word).font(CryoFont.label(10)).tracking(1.1)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, 8).frame(height: 20)
        .background(shape.fill(fill))
        .overlay(shape.strokeBorder(ring, lineWidth: 1))
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
    var foreground: Color {
        switch touch {
        case .transcode: return Cryo.amberInk
        case .pending: return Cryo.attention
        case .copy, .mux: return Cryo.icePale
        case .readOnly: return Cryo.ink2
        }
    }
    var fill: Color {
        switch touch {
        case .transcode: return Cryo.attention
        case .pending: return Cryo.attention.opacity(0.12)
        case .copy, .mux: return Cryo.ice.opacity(0.10)
        case .readOnly: return Color.white.opacity(0.05)
        }
    }
    var ring: Color {
        switch touch {
        case .transcode: return Cryo.attention
        case .pending: return Cryo.attention.opacity(0.7)
        case .copy, .mux: return Cryo.ice.opacity(0.38)
        case .readOnly: return Color.white.opacity(0.12)
        }
    }
}

// MARK: - Controls

/// The primary action: a capsule lit from inside. .primary cyan, .amber when the action transcodes, .ghost (CANCEL while
/// running), .done mint (SHOW IN FINDER). Press = 0.97 in 100 ms. Disabled = an unlit grey capsule, still legible.
struct CryoGoButtonStyle: ButtonStyle {
    enum Kind { case primary, amber, ghost, done }
    let kind: Kind
    init(_ kind: Kind = .primary) { self.kind = kind }
    func makeBody(configuration: Configuration) -> some View {
        CryoGoBody(kind: kind, label: configuration.label, pressed: configuration.isPressed)
    }
}

private struct CryoGoBody<Label: View>: View {
    let kind: CryoGoButtonStyle.Kind
    let label: Label
    let pressed: Bool
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hover = false

    var glow: Color {
        switch kind { case .primary, .ghost: return Cryo.ice; case .amber: return Cryo.attention; case .done: return Cryo.pass }
    }
    var textColor: Color {
        guard enabled else { return Cryo.ink3 }
        switch kind {
        case .primary: return Cryo.goText
        case .amber: return cryoHex(0xFFF4E2)
        case .done: return cryoHex(0xEAFFF3)
        case .ghost: return Cryo.ink
        }
    }
    var fill: AnyShapeStyle {
        guard enabled else { return AnyShapeStyle(Color.white.opacity(0.05)) }
        func lit(_ a: Color, _ b: Color, _ c: Color) -> AnyShapeStyle {
            AnyShapeStyle(EllipticalGradient(stops: [.init(color: a, location: 0), .init(color: b, location: 0.55), .init(color: c, location: 1)],
                                             center: UnitPoint(x: 0.5, y: 1.3), startRadiusFraction: 0, endRadiusFraction: 1.0))
        }
        switch kind {
        case .primary: return lit(Cryo.ice.opacity(0.85), Cryo.tint.opacity(0.75), cryoHex(0x0A2837))
        case .amber: return lit(Cryo.attention.opacity(0.85), cryoHex(0x8A4B00), cryoHex(0x2A1A08))
        case .done: return lit(Cryo.pass.opacity(0.6), cryoHex(0x14503C), cryoHex(0x081E18))
        case .ghost: return AnyShapeStyle(Color.white.opacity(hover ? 0.09 : 0.06))
        }
    }
    var ring: Color {
        if contrast == .increased { return enabled ? Color.white : Cryo.ink3 }
        guard enabled else { return Color.white.opacity(0.12) }
        switch kind {
        case .primary: return cryoHex(0xBEF5FF, hover ? 0.65 : 0.45)
        case .amber: return cryoHex(0xFFD9A0, hover ? 0.75 : 0.55)
        case .done: return cryoHex(0x96FFC8, hover ? 0.6 : 0.4)
        case .ghost: return Color.white.opacity(hover ? 0.3 : 0.18)
        }
    }
    var body: some View {
        let showGlow = enabled && kind != .ghost && contrast != .increased
        label
            .font(CryoFont.plate(12.5)).tracking(1.2)
            .lineLimit(1)
            .fixedSize()                                      // a primary action never truncates
            .foregroundStyle(textColor)
            .padding(.horizontal, 20)
            .frame(minHeight: 34)
            .background(Capsule().fill(fill))
            .overlay(Capsule().inset(by: 1).stroke(Color.white.opacity(enabled && kind != .ghost ? 0.45 : 0.08), lineWidth: 1)
                        .mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .init(x: 0.5, y: 0.35))))
            .overlay(Capsule().strokeBorder(ring, lineWidth: contrast == .increased ? 2 : 1))
            .shadow(color: showGlow ? glow.opacity(pressed ? 0.85 : (hover ? 0.75 : 0.55)) : .clear, radius: hover ? 16 : 12)
            .shadow(color: .black.opacity(0.6), radius: 10, y: 8)
            .contentShape(Capsule())
            .scaleEffect(pressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : CryoMotion.press, value: pressed)
            .onHover { hover = $0 }
    }
}

/// The secondary action: a glass-like pill (drawn, not live glass — it sits on content). The icon of a Label is lit ice
/// (or the tint); hover lights the ring.
struct CryoButtonStyle: ButtonStyle {
    let tint: Color?
    init(tint: Color? = nil) { self.tint = tint }
    func makeBody(configuration: Configuration) -> some View {
        CryoPillBody(tint: tint, label: configuration.label, pressed: configuration.isPressed)
    }
}

private struct CryoPillBody<Label: View>: View {
    let tint: Color?
    let label: Label
    let pressed: Bool
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hover = false

    var accent: Color { tint ?? Cryo.ice }
    var increased: Bool { contrast == .increased }
    var textColor: Color { enabled ? (tint ?? Cryo.ink) : Cryo.ink3 }
    var ring: Color {
        if increased { return Color.white.opacity(0.8) }
        if hover && enabled { return accent.opacity(0.55) }
        return tint?.opacity(0.4) ?? cryoHex(0xC8F0FF, 0.16)
    }
    var halo: Color { hover && enabled && !increased ? accent.opacity(0.35) : .clear }
    var surface: some View {
        ZStack {
            Capsule().fill(Cryo.s2)
            Capsule().fill(LinearGradient(colors: [Color.white.opacity(hover ? 0.13 : 0.10), Color.white.opacity(0.04)], startPoint: .top, endPoint: .bottom))
            Capsule().inset(by: 1).stroke(Color.white.opacity(0.18), lineWidth: 1)
                .mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .init(x: 0.5, y: 0.3)))
            Capsule().strokeBorder(ring, lineWidth: increased ? 2 : 1)
        }
    }
    var body: some View {
        label
            .labelStyle(CryoIconLabelStyle(iconColor: enabled ? accent : Cryo.ink3))
            .font(CryoFont.body(12.5, weight: .medium))
            .lineLimit(1)
            .foregroundStyle(textColor)
            .padding(.horizontal, 13)
            .frame(minHeight: 30)
            .background(surface)
            .shadow(color: halo, radius: 9)
            .shadow(color: .black.opacity(0.5), radius: 6, y: 4)
            .contentShape(Capsule())
            .scaleEffect(pressed && !reduceMotion ? 0.97 : 1)
            .animation(reduceMotion ? nil : CryoMotion.press, value: pressed)
            .onHover { hover = $0 }
    }
}

/// A Label whose icon is lit in a colour and whose title keeps the text colour
struct CryoIconLabelStyle: LabelStyle {
    var iconColor: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 7) {
            configuration.icon.foregroundStyle(iconColor).imageScale(.medium)
            configuration.title
        }
    }
}

/// An etched tag. plain = grey; lit = ice (COPY · bit-exact, the active one); ref = outline (SYNC REFERENCE);
/// amber = changes / transcodes; pass and fail carry their icon besides the word.
struct CryoChip: View {
    enum Style { case plain, lit, ref, amber, pass, fail }
    let text: String
    let style: Style
    init(_ text: String, style: Style = .plain) { self.text = text; self.style = style }
    @Environment(\.colorSchemeContrast) private var contrast

    var color: Color {
        switch style {
        case .plain, .ref: return Cryo.ink2
        case .lit: return Cryo.icePale
        case .amber: return Cryo.attention
        case .pass: return Cryo.pass
        case .fail: return Cryo.fail
        }
    }
    var fill: Color {
        switch style {
        case .plain: return Color.white.opacity(0.05)
        case .ref: return .clear
        case .lit: return Cryo.ice.opacity(0.10)
        case .amber: return Cryo.attention.opacity(0.10)
        case .pass: return Cryo.pass.opacity(0.10)
        case .fail: return Cryo.fail.opacity(0.12)
        }
    }
    var ring: Color {
        switch style {
        case .plain: return Color.white.opacity(0.10)
        case .ref: return Cryo.ink2.opacity(0.45)
        case .lit: return Cryo.ice.opacity(0.38)
        case .amber: return Cryo.attention.opacity(0.38)
        case .pass: return Cryo.pass.opacity(0.38)
        case .fail: return Cryo.fail.opacity(0.45)
        }
    }
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        let increased = contrast == .increased
        HStack(spacing: 4) {
            if style == .pass { Image(systemName: "checkmark").font(.system(size: 8.5, weight: .heavy)) }
            if style == .fail { Image(systemName: "xmark").font(.system(size: 8.5, weight: .heavy)) }
            Text(text).font(CryoFont.label(10)).tracking(0.9)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8).frame(height: 20)
        .background(shape.fill(fill))
        .overlay(shape.strokeBorder(increased ? color : ring, style: StrokeStyle(lineWidth: increased ? 1.5 : 1, dash: style == .ref ? [3, 2] : [])))
        .shadow(color: style == .lit && !increased ? Cryo.ice.opacity(0.35) : .clear, radius: 6)
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

/// A lit lamp (radial: hot centre, the colour, a deep rim) with its glow. The meaning is always in the word beside it.
struct CryoLamp: View {
    let color: Color
    let size: CGFloat
    init(_ color: Color, size: CGFloat = 10) { self.color = color; self.size = size }
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        Circle()
            .fill(RadialGradient(stops: [.init(color: Cryo.mix(color, .white, 0.78), location: 0), .init(color: color, location: 0.45),
                                         .init(color: Cryo.mix(color, .black, 0.55), location: 1)],
                                 center: UnitPoint(x: 0.4, y: 0.35), startRadius: 0, endRadius: size * 0.65))
            .frame(width: size, height: size)
            .shadow(color: contrast == .increased ? .clear : color.opacity(0.8), radius: size * 0.5)
            .accessibilityHidden(true)
    }
}

/// A section title: caps, wide tracking, and a cyan rule fading to the right
struct CryoSectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        HStack(spacing: 10) {
            Text(Cryo.caps(title)).font(CryoFont.label(10.5)).tracking(2.2).foregroundStyle(Cryo.ink3).fixedSize()
            Rectangle().fill(LinearGradient(colors: [Cryo.ice.opacity(0.28), Cryo.ice.opacity(0)], startPoint: .leading, endPoint: .trailing))
                .frame(height: 1).accessibilityHidden(true)
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// A small closed choice (MOV / MP4 / MKV, Before / After): equal segments and a glowing pill that slides to the choice
struct CryoSegmented<T: Hashable>: View {
    @Binding var selection: T
    let options: [(value: T, label: String)]
    init(selection: Binding<T>, options: [(value: T, label: String)]) { _selection = selection; self.options = options }
    @Namespace private var ns
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let outer = RoundedRectangle(cornerRadius: 11, style: .continuous)
        CryoEqualWidthRow {
            ForEach(options.indices, id: \.self) { i in segment(options[i].value, options[i].label) }
        }
        .padding(3)
        .background(outer.fill(Color.black.opacity(0.35)))
        .background(outer.fill(Cryo.s0))
        .overlay(outer.strokeBorder(contrast == .increased ? Color.white.opacity(0.6) : Color.white.opacity(0.08), lineWidth: 1))
        .opacity(enabled ? 1 : 0.5)
    }

    func segment(_ value: T, _ label: String) -> some View {
        let on = value == selection
        let pill = RoundedRectangle(cornerRadius: 8, style: .continuous)
        return Button { withAnimation(CryoMotion.gated(CryoMotion.select, reduceMotion)) { selection = value } } label: {
            Text(label).font(CryoFont.body(12, weight: .semibold)).lineLimit(1)
                .foregroundStyle(on ? Color.white : Cryo.ink2)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, minHeight: 28)
                .background {
                    if on {
                        pill.fill(LinearGradient(colors: [Cryo.ice.opacity(0.28), Cryo.ice.opacity(0.13)], startPoint: .top, endPoint: .bottom))
                            .overlay(pill.strokeBorder(Cryo.iceRing.opacity(contrast == .increased ? 1 : 0.45), lineWidth: 1))
                            .shadow(color: contrast == .increased ? .clear : Cryo.ice.opacity(0.5), radius: 6)
                            .matchedGeometryEffect(id: "pill", in: ns)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Children side by side, all as wide as the widest (the segments of CryoSegmented)
struct CryoEqualWidthRow: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let total = (sizes.map(\.width).max() ?? 0) * CGFloat(subviews.count)
        let width = proposal.width.map { $0.isFinite ? min(total, $0) : total } ?? total
        return CGSize(width: width, height: sizes.map(\.height).max() ?? 0)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let w = bounds.width / CGFloat(subviews.count)
        for (i, s) in subviews.enumerated() {
            s.place(at: CGPoint(x: bounds.minX + CGFloat(i) * w, y: bounds.minY), anchor: .topLeading,
                    proposal: ProposedViewSize(width: w, height: bounds.height))
        }
    }
}

/// A switch: the label on the leading side, the switch on the trailing side; the whole row toggles
struct CryoToggleStyle: ToggleStyle {
    init() {}
    func makeBody(configuration: Configuration) -> some View { CryoToggleBody(configuration: configuration) }
}

private struct CryoToggleBody: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let on = configuration.isOn
        Button { withAnimation(CryoMotion.gated(CryoMotion.select, reduceMotion)) { configuration.isOn.toggle() } } label: {
            HStack(spacing: 10) {
                configuration.label.font(CryoFont.body(12.5)).foregroundStyle(Cryo.ink)
                Spacer(minLength: 8)
                ZStack(alignment: on ? .trailing : .leading) {
                    Capsule().fill(on ? AnyShapeStyle(LinearGradient(colors: [Cryo.tint.opacity(0.9), Cryo.ice.opacity(0.75)], startPoint: .leading, endPoint: .trailing))
                                      : AnyShapeStyle(Color.white.opacity(0.08)))
                    Capsule().strokeBorder(contrast == .increased ? Color.white.opacity(0.8) : (on ? cryoHex(0xBEF5FF, 0.5) : Color.white.opacity(0.14)), lineWidth: 1)
                    Circle().fill(on ? Color.white : cryoHex(0xCFD8DE)).frame(width: 16, height: 16).padding(3)
                        .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
                }
                .frame(width: 38, height: 22)
                .shadow(color: on && contrast != .increased ? Cryo.ice.opacity(0.45) : .clear, radius: 7)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.45)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(on ? "On" : "Off")
    }
}

/// The small caps label above a field
struct CryoFieldLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(Cryo.caps(text)).font(CryoFont.label(9.5)).tracking(1.5).foregroundStyle(Cryo.ink3)
    }
}

extension View {
    /// Inset input look for TextField / Picker
    func cryoField() -> some View { modifier(CryoFieldLook()) }

    /// The neutral surround of a picture (thumbnails, frames, scopes): a black ground and a grey ring — never cyan, glow
    /// or glass on or around an image
    func cryoImageSurround(cornerRadius: CGFloat = 10) -> some View {
        self.background(Cryo.imageGround)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Cryo.imageRing, lineWidth: 1))
    }
}

private struct CryoFieldLook: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        content
            .textFieldStyle(.plain)
            .font(CryoFont.body(12.5))
            .foregroundStyle(Cryo.ink)
            .padding(.horizontal, 10)
            .frame(minHeight: 30)
            .background(shape.fill(Color.white.opacity(0.045).shadow(.inner(color: .black.opacity(0.6), radius: 1.5, y: 1))))
            .background(shape.fill(Cryo.s0))
            .overlay(shape.strokeBorder(contrast == .increased ? Color.white.opacity(0.7) : Color.white.opacity(0.10), lineWidth: 1))
    }
}

// MARK: - Readouts

/// A value in ms on a scale: the good zone hatched mint, outside it red, a needle on the value and the exact value with
/// its word (PASS / EARLY / LATE) and icon
struct CryoGauge: View {
    let valueMs: Double?
    let rangeMs: ClosedRange<Double>
    let goodMs: ClosedRange<Double>
    let label: String
    init(valueMs: Double?, rangeMs: ClosedRange<Double>, goodMs: ClosedRange<Double>, label: String) {
        self.valueMs = valueMs; self.rangeMs = rangeMs; self.goodMs = goodMs; self.label = label
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    func fraction(_ v: Double) -> CGFloat {
        let span = max(rangeMs.upperBound - rangeMs.lowerBound, 0.001)
        return CGFloat(max(0, min(1, (v - rangeMs.lowerBound) / span)))
    }
    var verdict: (word: String, icon: String, color: Color)? {
        guard let v = valueMs else { return nil }
        if goodMs.contains(v) { return ("PASS", "checkmark", Cryo.pass) }
        return (v < goodMs.lowerBound ? "EARLY" : "LATE", "xmark", Cryo.fail)
    }
    var ticks: [Double] {
        var t = [rangeMs.lowerBound, goodMs.lowerBound, goodMs.upperBound, rangeMs.upperBound]
        if rangeMs.contains(0) && !t.contains(0) { t.append(0) }
        return Array(Set(t)).sorted()
    }
    static func signed(_ v: Double, decimals: Bool) -> String {
        let s = decimals ? String(format: "%.1f", abs(v)) : String(format: "%g", abs(v))
        return v == 0 ? (decimals ? "0.0" : "0") : (v > 0 ? "+" : "−") + s
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                CryoFieldLabel(label)
                Spacer(minLength: 8)
                readout
            }
            band.frame(height: 22)
            tickLabels.frame(height: 12)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(valueMs.map { "\(Self.signed($0, decimals: true)) milliseconds, \(verdict?.word ?? "")" } ?? "not measured")
    }

    @ViewBuilder var readout: some View {
        if let v = valueMs, let verdict {
            HStack(spacing: 6) {
                Image(systemName: verdict.icon).font(.system(size: 11, weight: .bold))
                Text("\(Self.signed(v, decimals: true)) ms").font(CryoFont.mono(13).weight(.medium))
                Text(verdict.word).font(CryoFont.label(10.5)).tracking(1.2)
            }
            .foregroundStyle(verdict.color)
        } else {
            Text("not measured").font(CryoFont.mono(12)).foregroundStyle(Cryo.ink3)
        }
    }

    var band: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            let lo = fraction(goodMs.lowerBound) * w, hi = fraction(goodMs.upperBound) * w
            ZStack(alignment: .topLeading) {
                Canvas { ctx, size in
                    let r = CGRect(origin: .zero, size: size)
                    let band = Path(roundedRect: r, cornerRadius: 7)
                    ctx.fill(band, with: .color(Cryo.s0))
                    ctx.fill(band, with: .color(Cryo.fail.opacity(0.14)))
                    var zone = Path(CGRect(x: lo, y: 0, width: max(0, hi - lo), height: size.height))
                    ctx.fill(zone, with: .color(Cryo.s0))
                    ctx.fill(zone, with: .color(Cryo.pass.opacity(0.09)))
                    var x = lo
                    while x < hi { ctx.fill(Path(CGRect(x: x, y: 0, width: min(2, hi - x), height: size.height)), with: .color(Cryo.pass.opacity(0.16))); x += 6 }
                    zone = Path(CGRect(x: lo, y: 0.5, width: max(0, hi - lo), height: size.height - 1))
                    ctx.stroke(zone, with: .color(Cryo.pass.opacity(0.4)), lineWidth: 1)
                    for t in ticks { ctx.fill(Path(CGRect(x: fraction(t) * size.width - 0.5, y: 0, width: 1, height: size.height)), with: .color(.white.opacity(t == 0 ? 0.3 : 0.12))) }
                    ctx.stroke(band, with: .color(.white.opacity(0.10)), lineWidth: 1)
                }
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                if let v = valueMs, let verdict {
                    Capsule().fill(verdict.color).frame(width: 2.5, height: h + 8)
                        .shadow(color: contrast == .increased ? .clear : verdict.color.opacity(0.9), radius: 5)
                        .position(x: fraction(v) * w, y: h / 2)
                        .animation(CryoMotion.gated(CryoMotion.needle, reduceMotion), value: v)
                }
            }
        }
    }

    var tickLabels: some View {
        GeometryReader { g in
            ForEach(ticks, id: \.self) { t in
                Text(Self.signed(t, decimals: false)).font(CryoFont.mono(9)).foregroundStyle(t == 0 ? Cryo.ink2 : Cryo.ink3).fixedSize()
                    .position(x: min(max(fraction(t) * g.size.width, 12), g.size.width - 12), y: 6)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A pop-up card: the logo or a badge, the title, the ✓/⚠/✕ lines (icon + word), DETECTED → RECOMMENDED, and the
/// buttons (the recommended one prominent and last; Return = the primary, Esc = the first secondary). Opaque, never
/// translucent: warm when something needs attention, cool otherwise.
struct CryoAlertCard: View {
    struct Line: Identifiable {
        let id = UUID()
        var level: CheckLevel
        var title: String
        var detail: String
        init(level: CheckLevel, title: String, detail: String = "") { self.level = level; self.title = title; self.detail = detail }
    }
    struct Action {
        enum Role { case primary, secondary, destructive }
        var title: String
        var role: Role
        var run: () -> Void
        init(_ title: String, role: Role = .secondary, run: @escaping () -> Void) { self.title = title; self.role = role; self.run = run }
    }
    let logo: AnyView?
    let title: String
    let subtitle: String?
    let lines: [Line]
    let detected: String?
    let recommendation: String?
    let actions: [Action]
    init(logo: AnyView? = nil, title: String, subtitle: String? = nil, lines: [Line] = [],
         detected: String? = nil, recommendation: String? = nil, actions: [Action]) {
        self.logo = logo; self.title = title; self.subtitle = subtitle; self.lines = lines
        self.detected = detected; self.recommendation = recommendation; self.actions = actions
    }
    @Environment(\.colorSchemeContrast) private var contrast

    var worst: CheckLevel? {
        if lines.contains(where: { $0.level == .fail }) { return .fail }
        if lines.contains(where: { $0.level == .warn }) { return .warn }
        return nil
    }
    var tone: Color { worst == .fail ? Cryo.fail : (worst == .warn || detected != nil) ? Cryo.attention : Cryo.ice }
    var warm: Bool { worst != nil || detected != nil }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)
        let increased = contrast == .increased
        VStack(alignment: .leading, spacing: 0) {
            head
            if !lines.isEmpty { lineList.padding(.top, 16) }
            if detected != nil || recommendation != nil { decision.padding(.top, 14) }
            buttons.padding(.top, 18)
        }
        .padding(EdgeInsets(top: 22, leading: 22, bottom: 18, trailing: 22))
        .frame(minWidth: 380, idealWidth: 560, maxWidth: 560, alignment: .leading)
        .background(shape.fill(warm ? Cryo.warm : Cryo.sheet))
        .overlay(shape.inset(by: 1).stroke(Color.white.opacity(0.14), lineWidth: 1).mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .init(x: 0.5, y: 0.12))))
        .overlay(shape.strokeBorder(increased ? tone : tone.opacity(0.38), lineWidth: increased ? 2 : 1))
        .shadow(color: increased ? .clear : tone.opacity(0.22), radius: 26)
        .shadow(color: .black.opacity(0.6), radius: 24, y: 18)
        .accessibilityElement(children: .contain)
    }

    var head: some View {
        HStack(alignment: .top, spacing: 16) {
            if let logo {
                logo
                    .padding(.horizontal, 12).frame(minHeight: 46)
                    .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Cryo.s0))
                    .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            } else {
                badge
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(CryoFont.title(18)).foregroundStyle(Cryo.ink).fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle).font(CryoFont.body(13)).foregroundStyle(Cryo.ink2).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 2)
        }
    }

    var badge: some View {
        let shape = RoundedRectangle(cornerRadius: 15, style: .continuous)
        let symbol = worst == .fail ? "xmark.octagon" : (warm ? "exclamationmark.triangle" : "info.circle")
        return Image(systemName: symbol).font(.system(size: 21, weight: .medium)).foregroundStyle(tone)
            .frame(width: 46, height: 46)
            .background(shape.fill(RadialGradient(colors: [Cryo.mix(tone, .black, 0.55), Cryo.mix(tone, .black, 0.85)], center: UnitPoint(x: 0.45, y: 0.3), startRadius: 0, endRadius: 40)))
            .overlay(shape.strokeBorder(tone.opacity(0.55), lineWidth: 1))
            .shadow(color: contrast == .increased ? .clear : tone.opacity(0.45), radius: 10)
            .accessibilityHidden(true)
    }

    var lineList: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.element.id) { i, l in
                if i > 0 { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1) }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: l.level.icon).font(.system(size: 13)).foregroundStyle(Cryo.status(l.level)).frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(l.title).font(CryoFont.body(13, weight: .medium)).foregroundStyle(Cryo.ink).fixedSize(horizontal: false, vertical: true)
                        if !l.detail.isEmpty {
                            Text(l.detail).font(CryoFont.body(12)).foregroundStyle(Cryo.ink2).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 8)
                    if let w = Cryo.word(l.level) {
                        Text(w).font(CryoFont.label(9.5)).tracking(1.2).foregroundStyle(Cryo.status(l.level)).fixedSize()
                    }
                }
                .padding(.vertical, 9)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Cryo.recess))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Cryo.hairline, lineWidth: 1))
    }

    var decision: some View {
        HStack(alignment: .top, spacing: 10) {
            if let detected {
                box(label: "DETECTED", symbol: "eye", text: detected, color: Cryo.attention)
                if recommendation != nil {
                    Image(systemName: "arrow.right").font(.system(size: 13, weight: .bold)).foregroundStyle(Cryo.ink3)
                        .frame(maxHeight: .infinity).accessibilityHidden(true)
                }
            }
            if let recommendation { box(label: "RECOMMENDED", symbol: "lightbulb", text: recommendation, color: Cryo.ice) }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    func box(label: String, symbol: String, text: String, color: Color) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                Text(label).font(CryoFont.label(10)).tracking(1.8)
            }
            .foregroundStyle(color)
            Text(text).font(CryoFont.body(12.5)).foregroundStyle(Cryo.ink).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
        }
        .padding(EdgeInsets(top: 11, leading: 13, bottom: 12, trailing: 13))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(shape.fill(Cryo.s0))
        .background(shape.fill(color.opacity(0.07)))
        .overlay(shape.strokeBorder(color.opacity(0.3), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    var buttons: some View {
        let ordered = actions.enumerated().sorted { a, b in
            (a.element.role == .primary ? 1 : 0, a.offset) < (b.element.role == .primary ? 1 : 0, b.offset)
        }
        let firstPrimary = actions.firstIndex { $0.role == .primary }
        let firstSecondary = actions.firstIndex { $0.role == .secondary }
        let others = ordered.filter { $0.element.role != .primary }
        let primaries = ordered.filter { $0.element.role == .primary }
        func row(_ items: [EnumeratedSequence<[Action]>.Element]) -> some View {
            ForEach(items, id: \.offset) { item in
                actionButton(item.element, isDefault: item.offset == firstPrimary, isCancel: item.offset == firstSecondary).fixedSize()
            }
        }
        // one row when it fits; otherwise the secondary buttons above the recommended one (never truncated)
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { Spacer(minLength: 0); row(ordered) }
            VStack(alignment: .trailing, spacing: 10) {
                HStack(spacing: 10) { Spacer(minLength: 0); row(others) }
                HStack(spacing: 10) { Spacer(minLength: 0); row(primaries) }
            }
        }
    }

    @ViewBuilder func actionButton(_ a: Action, isDefault: Bool, isCancel: Bool) -> some View {
        switch a.role {
        case .primary:
            Button(a.title, action: a.run)
                .buttonStyle(CryoGoButtonStyle(a.title.lowercased().contains("transcode") ? .amber : .primary))
                .keyboardShortcut(isDefault ? .defaultAction : nil)
        case .secondary:
            Button(a.title, action: a.run).buttonStyle(CryoButtonStyle())
                .keyboardShortcut(isCancel ? .cancelAction : nil)
        case .destructive:
            Button(a.title, action: a.run).buttonStyle(CryoButtonStyle(tint: Cryo.fail))
        }
    }
}

/// Where files are dropped — the only place frost lives inside content. The frost recedes when a file is over it.
struct CryoDropZone: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let targeted: Bool
    let action: () -> Void
    init(title: String, subtitle: String, systemImage: String, targeted: Bool, action: @escaping () -> Void) {
        self.title = title; self.subtitle = subtitle; self.systemImage = systemImage; self.targeted = targeted; self.action = action
    }
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let outer = RoundedRectangle(cornerRadius: 24, style: .continuous)
        let inner = RoundedRectangle(cornerRadius: 18, style: .continuous)
        let increased = contrast == .increased
        let calm = EffectsGovernor.shared.calm || reduceMotion
        VStack(spacing: 14) {
            tile
            Text(title).font(CryoFont.title(22)).foregroundStyle(Cryo.ink).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            Text(subtitle).font(CryoFont.body(13)).foregroundStyle(Cryo.ink2).lineSpacing(3).multilineTextAlignment(.center)
                .frame(maxWidth: 520).fixedSize(horizontal: false, vertical: true)
            Button(action: action) { Label("Choose Files…", systemImage: "plus") }
                .buttonStyle(CryoButtonStyle()).padding(.top, 4)
        }
        .padding(44)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ZStack {
                outer.fill(cryoHex(0x03070B))
                outer.fill(RadialGradient(colors: [Cryo.ice.opacity(targeted ? 0.12 : 0.06), .clear], center: .center, startRadius: 0, endRadius: 420))
                if !reduceTransparency {
                    CryoFrostCorners(opacity: targeted ? 0.12 : 0.6, fraction: 0.42, maxSide: 440)
                        .scaleEffect(targeted ? 1.08 : 1)
                }
            }
            .clipShape(outer)
        }
        .overlay(outer.strokeBorder(increased ? Color.white.opacity(0.6) : Cryo.ice.opacity(0.10), lineWidth: 1))
        .overlay(
            inner.strokeBorder(targeted ? Cryo.ice.opacity(0.85) : Cryo.ice.opacity(increased ? 0.7 : 0.30),
                               style: StrokeStyle(lineWidth: targeted ? 2 : 1.5, dash: [7, 5]))
                .shadow(color: targeted && !increased ? Cryo.ice.opacity(0.7) : .clear, radius: 8)
                .padding(18)
        )
        .animation(calm ? nil : CryoMotion.frost, value: targeted)
        .padding(12)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    var tile: some View {
        let shape = RoundedRectangle(cornerRadius: 28, style: .continuous)
        return Image(systemName: systemImage).font(.system(size: 40, weight: .light)).foregroundStyle(Cryo.ice)
            .shadow(color: contrast == .increased ? .clear : Cryo.ice.opacity(0.8), radius: 6)
            .frame(width: 92, height: 92)
            .background(shape.fill(RadialGradient(colors: [Cryo.ice.opacity(0.25), Cryo.tint.opacity(0.15)], center: UnitPoint(x: 0.5, y: 0.3), startRadius: 0, endRadius: 70)))
            .background(shape.fill(Cryo.s1))
            .overlay(shape.strokeBorder(Cryo.iceRing.opacity(targeted ? 0.7 : 0.4), lineWidth: 1))
            .shadow(color: contrast == .increased ? .clear : Cryo.ice.opacity(targeted ? 0.7 : 0.4), radius: targeted ? 22 : 16)
            .accessibilityHidden(true)
    }
}

/// The Academy (gold) and Zidoo (mint) seals at the end of a Delivery: lit and stamped in when passed, etched and dark
/// when not
struct CryoSeal: View {
    enum Kind { case academy, zidoo }
    let kind: Kind
    let passed: Bool
    let caption: String
    init(kind: Kind, passed: Bool, caption: String) { self.kind = kind; self.passed = passed; self.caption = caption }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var stamped = false

    var color: Color { kind == .academy ? Cryo.gold : Cryo.pass }
    var name: String { kind == .academy ? "ACADEMY" : "ZIDOO" }

    var body: some View {
        let lit = passed
        let c = lit ? color : Cryo.ink3
        let glow = lit && contrast != .increased
        VStack(spacing: 5) {
            emblem(lit).frame(height: 30)
            Text(name).font(CryoFont.plate(10)).tracking(1.6).foregroundStyle(c)
            Text(Cryo.caps(caption)).font(CryoFont.body(8.5, weight: .medium)).tracking(0.6)
                .foregroundStyle(lit ? Cryo.ink2 : Cryo.ink3)
                .multilineTextAlignment(.center).lineLimit(2).frame(width: 84)
        }
        .frame(width: 112, height: 112)
        .background(Circle().fill(RadialGradient(colors: [c.opacity(lit ? 0.24 : 0.05), c.opacity(lit ? 0.08 : 0.02), Color.black.opacity(0.35)],
                                                 center: UnitPoint(x: 0.45, y: 0.3), startRadius: 0, endRadius: 66)))
        .background(Circle().fill(Cryo.s0))
        .overlay(Circle().strokeBorder(c.opacity(lit ? 0.75 : 0.35), lineWidth: 1.5))
        .overlay(Circle().inset(by: 6).strokeBorder(c.opacity(lit ? 0.35 : 0.22), style: StrokeStyle(lineWidth: 1, dash: lit ? [] : [2, 3])))
        .overlay(alignment: .topTrailing) {
            if lit {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(Cryo.s0)
                    .frame(width: 22, height: 22).background(Circle().fill(color))
                    .overlay(Circle().strokeBorder(Cryo.s0, lineWidth: 2))
                    .offset(x: -4, y: 4)
            }
        }
        .shadow(color: glow ? color.opacity(0.55) : .clear, radius: 14)
        .scaleEffect(stamped || !lit ? 1 : 1.25)
        .opacity(stamped || !lit ? 1 : 0)
        .onAppear {
            guard lit, !reduceMotion else { stamped = true; return }
            withAnimation(CryoMotion.stamp) { stamped = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name) seal")
        .accessibilityValue("\(passed ? "passed" : "not passed"), \(caption)")
    }

    @ViewBuilder func emblem(_ lit: Bool) -> some View {
        if kind == .academy {
            StatuetteShape()
                .fill(lit ? AnyShapeStyle(LinearGradient(colors: [cryoHex(0xF6DFA6), Cryo.gold, cryoHex(0x8C6420)], startPoint: .top, endPoint: .bottom))
                          : AnyShapeStyle(Cryo.ink3.opacity(0.6)))
                .frame(width: 14, height: 30)
        } else {
            Image(systemName: "play.tv").font(.system(size: 22, weight: .light)).foregroundStyle(lit ? color : Cryo.ink3)
        }
    }
}

/// A run-bay meter (CPU, GPU, RAM, disk in MB/s): a glass tube that fills with lit liquid, the value above, the label below
struct CryoTube: View {
    let label: String
    let value: String
    let fraction: Double
    init(label: String, value: String, fraction: Double) { self.label = label; self.value = value; self.fraction = fraction }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let f = CGFloat(max(0, min(1, fraction)))
        VStack(spacing: 6) {
            Text(value).font(CryoFont.mono(10.5)).foregroundStyle(Cryo.ink).lineLimit(1).fixedSize()
            ZStack(alignment: .bottom) {
                Capsule().fill(Cryo.s0)
                Capsule().fill(Color.white.opacity(0.04))
                VStack(spacing: 0) {
                    Ellipse().fill(cryoHex(0xF0FFFF, 0.9)).frame(height: 5).blur(radius: 0.8).offset(y: 2)
                    Rectangle().fill(LinearGradient(stops: [.init(color: cryoHex(0xDCFCFF, 0.95), location: 0), .init(color: Cryo.ice.opacity(0.75), location: 0.18),
                                                            .init(color: Cryo.tint.opacity(0.8), location: 1)], startPoint: .top, endPoint: .bottom))
                }
                .frame(height: max(4, 84 * f))
                .opacity(f > 0 ? 1 : 0)
                .shadow(color: contrast == .increased ? .clear : Cryo.ice.opacity(0.6), radius: 7)
                .animation(CryoMotion.gated(CryoMotion.progress, reduceMotion), value: f)
                Capsule().strokeBorder(contrast == .increased ? Color.white.opacity(0.7) : Cryo.iceRing.opacity(0.25), lineWidth: 1)
                Capsule().fill(LinearGradient(colors: [Color.white.opacity(0.22), .clear], startPoint: .leading, endPoint: .init(x: 0.35, y: 0.5)))
                    .padding(2).allowsHitTesting(false)
            }
            .frame(width: 26, height: 84)
            .clipShape(Capsule())
            Text(Cryo.caps(label)).font(CryoFont.body(9, weight: .semibold)).tracking(1.3).foregroundStyle(Cryo.ink3).lineLimit(1).fixedSize()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }
}

/// One row of a Source → Destination table
struct CryoDiffRow: Identifiable {
    let id = UUID()
    var label: String
    var from: String
    var to: String
    var changed: Bool
    init(label: String, from: String, to: String, changed: Bool) { self.label = label; self.from = from; self.to = to; self.changed = changed }
}

/// Source → Destination: what changes is amber with "CHANGED", what is preserved stays grey with "kept"
struct CryoDiffTable: View {
    let rows: [CryoDiffRow]
    let fromTitle: String
    let toTitle: String
    init(rows: [CryoDiffRow], fromTitle: String = "SOURCE", toTitle: String = "DESTINATION") {
        self.rows = rows; self.fromTitle = fromTitle; self.toTitle = toTitle
    }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 0) {
            GridRow {
                Color.clear.frame(width: 1, height: 1).gridCellUnsizedAxes([.horizontal, .vertical])
                CryoFieldLabel(fromTitle)
                Color.clear.frame(width: 1, height: 1).gridCellUnsizedAxes([.horizontal, .vertical])
                CryoFieldLabel(toTitle)
                Color.clear.frame(width: 1, height: 1).gridCellUnsizedAxes([.horizontal, .vertical])
            }
            .padding(.bottom, 6)
            ForEach(rows) { r in
                Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1).gridCellUnsizedAxes(.horizontal)
                GridRow(alignment: .firstTextBaseline) {
                    HStack(spacing: 8) {
                        Capsule().fill(r.changed ? Cryo.attention : Color.clear).frame(width: 3, height: 14).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
                        Text(r.label).font(CryoFont.body(12)).foregroundStyle(r.changed ? Cryo.ink : Cryo.ink3)
                    }
                    Text(r.from).font(CryoFont.mono(11.5)).foregroundStyle(r.changed ? Cryo.ink2 : Cryo.ink3).fixedSize(horizontal: false, vertical: true)
                    Image(systemName: "arrow.right").font(.system(size: 10, weight: .bold)).foregroundStyle(r.changed ? Cryo.attention : Cryo.ink3.opacity(0.6))
                    Text(r.to).font(CryoFont.mono(11.5).weight(r.changed ? .semibold : .regular))
                        .foregroundStyle(r.changed ? Cryo.attention : Cryo.ink3).fixedSize(horizontal: false, vertical: true)
                    Group {
                        if r.changed { CryoChip("CHANGED", style: .amber) }
                        else { Text("kept").font(CryoFont.label(9.5)).tracking(1).foregroundStyle(Cryo.ink3) }
                    }
                    .gridColumnAlignment(.trailing)
                }
                .padding(.vertical, 7)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Cryo.recess))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Cryo.hairline, lineWidth: 1))
    }
}

/// The signal line of a stream: a 1-px ice line, straight for COPY / MUX; TRANSCODE breaks it with an amber node and the
/// signal leaves amber; DECIDE leaves it dashed after an open node; READ ONLY is a grey tap.
struct CryoSignalLine: View {
    let touch: FileTouch
    init(touch: FileTouch) { self.touch = touch }
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let glow = contrast != .increased
        let line: CGFloat = contrast == .increased ? 2 : 1
        GeometryReader { g in
            let w = g.size.width, y = g.size.height / 2, mid = w / 2
            ZStack {
                switch touch {
                case .copy, .mux:
                    segment(0, w, y, Cryo.ice, line, glow)
                    arrow(w, y, Cryo.ice)
                case .readOnly:
                    segment(0, w, y, Cryo.info.opacity(0.7), line, false, dash: [2, 3])
                case .transcode:
                    segment(0, mid - 7, y, Cryo.ice, line, glow)
                    segment(mid + 7, w, y, Cryo.attention, line, glow)
                    arrow(w, y, Cryo.attention)
                    Rectangle().fill(Cryo.attention).frame(width: 9, height: 9).rotationEffect(.degrees(45))
                        .shadow(color: glow ? Cryo.attention.opacity(0.9) : .clear, radius: 5)
                        .position(x: mid, y: y)
                case .pending:
                    segment(0, mid - 7, y, Cryo.ice, line, glow)
                    segment(mid + 7, w, y, Cryo.attention.opacity(0.8), line, false, dash: [3, 3])
                    Circle().strokeBorder(Cryo.attention, lineWidth: 1.5).frame(width: 10, height: 10).position(x: mid, y: y)
                }
            }
        }
        .frame(minWidth: 40)
        .frame(height: 12)
        .accessibilityElement()
        .accessibilityLabel(touch.word)
    }

    func segment(_ x0: CGFloat, _ x1: CGFloat, _ y: CGFloat, _ c: Color, _ lw: CGFloat, _ glow: Bool, dash: [CGFloat] = []) -> some View {
        Path { p in p.move(to: CGPoint(x: x0, y: y)); p.addLine(to: CGPoint(x: max(x0, x1), y: y)) }
            .stroke(c, style: StrokeStyle(lineWidth: lw, lineCap: .round, dash: dash))
            .shadow(color: glow ? c.opacity(0.8) : .clear, radius: 3)
    }
    func arrow(_ x: CGFloat, _ y: CGFloat, _ c: Color) -> some View {
        Path { p in p.move(to: CGPoint(x: x - 5, y: y - 3.5)); p.addLine(to: CGPoint(x: x, y: y)); p.addLine(to: CGPoint(x: x - 5, y: y + 3.5)) }
            .stroke(c, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
    }
}

// MARK: - Logos (vector; the official art is used when the app carries Contents/Resources/Logos/*.pdf)

private enum CryoLogoArt {
    static let dolbyVision: NSImage? = load("dolby-vision")
    static let hdr10Plus: NSImage? = load("hdr10plus")
    static func load(_ name: String) -> NSImage? {
        guard let u = Bundle.main.url(forResource: name, withExtension: "pdf", subdirectory: "Logos") else { return nil }
        return NSImage(contentsOf: u)
    }
}

/// The Dolby "double-D": two D shapes, mirrored, their bowls facing each other
struct CryoDolbyMark: Shape {
    func path(in r: CGRect) -> Path {
        let h = r.height, gap = r.width * 0.07
        let half = (r.width - gap) / 2
        let radius = min(h / 2, half)
        var p = Path()
        // left D: flat edge on the left, bowl to the right
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + half - radius, y: r.minY))
        p.addArc(center: CGPoint(x: r.minX + half - radius, y: r.midY), radius: radius, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        // right D: flat edge on the right, bowl to the left
        p.move(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - half + radius, y: r.minY))
        p.addArc(center: CGPoint(x: r.maxX - half + radius, y: r.midY), radius: radius, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: true)
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

struct DolbyVisionLogo: View {
    let height: CGFloat
    init(height: CGFloat = 18) { self.height = height }
    var body: some View {
        Group {
            if let art = CryoLogoArt.dolbyVision {
                Image(nsImage: art).renderingMode(.template).resizable().scaledToFit().foregroundStyle(Cryo.ink).frame(height: height)
            } else {
                HStack(spacing: height * 0.38) {
                    CryoDolbyMark().fill(Cryo.ink).frame(width: height * 1.3, height: height * 0.86)
                    (Text("DOLBY").font(.system(size: height * 0.62, weight: .heavy).width(.expanded))
                     + Text(" VISION").font(.system(size: height * 0.62, weight: .light).width(.expanded)))
                        .tracking(height * 0.06)
                        .foregroundStyle(Cryo.ink)
                        .fixedSize()
                }
                .frame(height: height)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Dolby Vision")
    }
}

struct HDR10PlusLogo: View {
    let height: CGFloat
    init(height: CGFloat = 18) { self.height = height }
    var body: some View {
        Group {
            if let art = CryoLogoArt.hdr10Plus {
                Image(nsImage: art).renderingMode(.template).resizable().scaledToFit().foregroundStyle(Cryo.ink).frame(height: height)
            } else {
                HStack(alignment: .firstTextBaseline, spacing: height * 0.04) {
                    Text("HDR").font(.system(size: height * 0.8, weight: .heavy).width(.expanded))
                    Text("10").font(.system(size: height * 0.8, weight: .light).width(.expanded))
                    Text("+").font(.system(size: height * 0.72, weight: .heavy)).baselineOffset(height * 0.22)
                }
                .foregroundStyle(Cryo.ink)
                .fixedSize()
                .frame(height: height)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("HDR10+")
    }
}

// MARK: - Effects

/// Ambient effects stop while a Delivery renders (calm) and when the system asks for less motion. Ambient pieces check
/// `ambientAllowed`; the progress light and the meters keep updating (1–4 times a second).
@Observable final class EffectsGovernor {
    static let shared = EffectsGovernor()
    var calm = false                                  // the Delivery sets it while a job renders; ambient effects stop
    var reduceMotion: Bool { systemReduceMotion }
    var reduceTransparency: Bool { systemReduceTransparency }
    var ambientAllowed: Bool { !calm && !systemReduceMotion }
    private(set) var systemReduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private(set) var systemReduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
    @ObservationIgnored private var observer: NSObjectProtocol?

    init() {
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                                                     object: nil, queue: .main) { [weak self] _ in
            self?.systemReduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            self?.systemReduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        }
    }
}

// MARK: - The Academy seal

/// A stylized award statuette (figure on a base)
struct StatuetteShape: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        let w = r.width, h = r.height, x = r.minX, y = r.minY
        func pt(_ a: CGFloat, _ b: CGFloat) -> CGPoint { CGPoint(x: x + a * w, y: y + b * h) }
        p.addEllipse(in: CGRect(x: x + 0.39 * w, y: y, width: 0.22 * w, height: 0.11 * h))                 // head
        p.addRect(CGRect(x: x + 0.46 * w, y: y + 0.105 * h, width: 0.08 * w, height: 0.03 * h))              // neck
        p.move(to: pt(0.24, 0.15)); p.addLine(to: pt(0.76, 0.15))                                             // shoulders
        p.addQuadCurve(to: pt(0.66, 0.30), control: pt(0.80, 0.22))
        p.addLine(to: pt(0.62, 0.47)); p.addLine(to: pt(0.38, 0.47)); p.addLine(to: pt(0.34, 0.30))
        p.addQuadCurve(to: pt(0.24, 0.15), control: pt(0.20, 0.22)); p.closeSubpath()                      // torso with arms
        p.move(to: pt(0.38, 0.47)); p.addLine(to: pt(0.62, 0.47)); p.addLine(to: pt(0.57, 0.76))
        p.addLine(to: pt(0.43, 0.76)); p.closeSubpath()                                                       // legs
        p.addRoundedRect(in: CGRect(x: x + 0.30 * w, y: y + 0.76 * h, width: 0.40 * w, height: 0.06 * h), cornerSize: CGSize(width: 2, height: 2))
        p.addRoundedRect(in: CGRect(x: x + 0.18 * w, y: y + 0.82 * h, width: 0.64 * w, height: 0.18 * h), cornerSize: CGSize(width: 3, height: 3)) // base
        return p
    }
}

/// The Academy verdict: a gold plate with the statuette (lit when the file meets the specs, etched when not), the
/// verdict in its status colour with an icon, the explanation and the caption
struct AcademySeal: View {
    let level: AcademyLevel?
    let caption: String
    var compact = false
    @Environment(\.colorSchemeContrast) private var contrast

    var status: Color {
        switch level { case .preferred: return Cryo.pass; case .accepted: return Cryo.attention; case .notApproved: return Cryo.fail; case nil: return Cryo.ink3 }
    }
    var icon: String {
        switch level { case .preferred: return "checkmark.seal.fill"; case .accepted: return "checkmark.circle"; case .notApproved: return "xmark.octagon.fill"; case nil: return "minus.circle" }
    }

    var body: some View {
        let lit = level == .preferred || level == .accepted
        let d: CGFloat = compact ? 48 : 64
        let glow = lit && contrast != .increased
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(Cryo.s0)
                Circle().fill(RadialGradient(colors: [Cryo.gold.opacity(lit ? 0.26 : 0.04), Cryo.gold.opacity(lit ? 0.07 : 0.01), .clear],
                                             center: UnitPoint(x: 0.45, y: 0.3), startRadius: 0, endRadius: d * 0.6))
                Circle().strokeBorder(lit ? Cryo.gold.opacity(0.8) : (level == .notApproved ? Cryo.fail.opacity(0.7) : Cryo.ink3.opacity(0.4)), lineWidth: 1.5)
                Circle().inset(by: 4).strokeBorder(lit ? Cryo.gold.opacity(0.3) : Cryo.ink3.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: lit ? [] : [2, 2.5]))
                StatuetteShape()
                    .fill(lit ? AnyShapeStyle(LinearGradient(colors: [cryoHex(0xF6DFA6), Cryo.gold, cryoHex(0x8C6420)], startPoint: .top, endPoint: .bottom))
                              : AnyShapeStyle(Cryo.ink3.opacity(0.55)))
                    .frame(width: d * 0.3, height: d * 0.62)
            }
            .frame(width: d, height: d)
            .shadow(color: glow ? Cryo.gold.opacity(0.45) : .clear, radius: 9)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: icon).font(.system(size: compact ? 12 : 14, weight: .semibold))
                    Text(level?.title ?? "Academy specs: —").font(CryoFont.title(compact ? 13 : 15))
                }
                .foregroundStyle(status)
                Text(level?.explanation ?? "Add a video and audio to evaluate.")
                    .font(CryoFont.body(12.5)).foregroundStyle(Cryo.ink2).fixedSize(horizontal: false, vertical: true)
                Text(caption).font(CryoFont.body(11)).foregroundStyle(Cryo.ink3).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Gallery (every piece in every state, for the QC capture: --popup gallery / gallery2)

/// Two pages that each fit a 1920 × 1080 screen (snapshotSize): 1 = window, plates and controls; 2 = cards, seals,
/// readouts and drop zones. Real 2DIE4 wording, so the capture also checks the texts.
struct CryoGallery: View {
    let page: Int
    init() { page = 1 }
    init(page: Int) { self.page = min(max(page, 1), 2) }
    /// The window size the capture should use (each page fits it)
    static let snapshotSize = CGSize(width: 1860, height: 980)

    @State private var container = "mov"
    @State private var before = 1
    @State private var verify = true
    @State private var interleave = false
    @State private var name = "PCM 5.1 · Deluxe master"
    @State private var language = "eng"

    var body: some View {
        ZStack(alignment: .topLeading) {
            CryoWindowBackground(progress: page == 1 ? 0.42 : nil)
            VStack(alignment: .leading, spacing: 22) {
                header
                if page == 1 { pageOne } else { pageTwo }
            }
            .padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .environment(\.colorScheme, .dark)
    }

    var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text("CRYO").font(CryoFont.plate(28)).tracking(8).foregroundStyle(Cryo.iceWhite)
                .shadow(color: Cryo.ice.opacity(0.5), radius: 12)
            Text(page == 1 ? "page 1 of 2 · window, plates and controls" : "page 2 of 2 · cards, seals, readouts and drop zones")
                .font(CryoFont.body(13)).foregroundStyle(Cryo.ink2)
            Spacer()
            Text("\(AppInfo.name) · design system").font(CryoFont.mono(11)).foregroundStyle(Cryo.ink3)
        }
        .padding(.leading, 70)                                   // clear of the traffic lights
    }

    // MARK: page 1

    var pageOne: some View {
        VStack(alignment: .leading, spacing: 20) {
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    CryoStrip(touch: .copy, title: "VIDEO", text: "the picture is not touched — ProRes 4444 copied bit for bit")
                    CryoStrip(touch: .transcode, title: "VIDEO",
                              text: "→ HEVC 10-bit · Dolby Vision 8.1 — you chose it because ProRes 4444 can't carry the Dolby Vision metadata (2DIE4.xml)") {
                        Button("Change…") {}.buttonStyle(CryoButtonStyle(tint: Cryo.attention))
                    }
                }
                GridRow {
                    CryoStrip(touch: .mux, title: "DELIVERY", text: "3 streams copied bit for bit into 2DIE4_ACADEMY.mov · 1 trimmed at the head (88.7 ms)")
                    CryoStrip(touch: .pending, title: "AUDIO", text: "1 decision pending — the stereo that came inside the video") {
                        Button { } label: { Label("Decide", systemImage: "hand.point.right") }.buttonStyle(CryoButtonStyle(tint: Cryo.attention))
                    }
                }
                GridRow {
                    CryoStrip(touch: .readOnly, title: "FILE CHECKER", text: "reads the file, never changes it")
                    TabStrip.transcode
                }
            }
            .padding(.horizontal, -12)
            HStack(alignment: .top, spacing: 24) {
                buttonsColumn.frame(width: 432)
                choicesColumn.frame(width: 432)
                slotsColumn.frame(width: 432)
                linesColumn.frame(width: 432)
            }
        }
    }

    var buttonsColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            CryoSectionHeader("Go buttons")
            HStack(spacing: 10) {
                Button("START DELIVERY") {}.buttonStyle(CryoGoButtonStyle(.primary))
                Button("CANCEL") {}.buttonStyle(CryoGoButtonStyle(.ghost))
            }
            HStack(spacing: 10) {
                Button("TRANSCODE TO EMBED IT") {}.buttonStyle(CryoGoButtonStyle(.amber))
                Button("START") {}.buttonStyle(CryoGoButtonStyle(.primary)).disabled(true)
            }
            Button { } label: { Label("SHOW IN FINDER", systemImage: "folder") }.buttonStyle(CryoGoButtonStyle(.done))
            CryoSectionHeader("Secondary buttons")
            HStack(spacing: 8) {
                Button { } label: { Label("Sync Viewer…", systemImage: "waveform") }.buttonStyle(CryoButtonStyle())
                Button { } label: { Label("Choose Folder…", systemImage: "folder") }.buttonStyle(CryoButtonStyle())
                Button("Off") {}.buttonStyle(CryoButtonStyle()).disabled(true)
            }
            HStack(spacing: 8) {
                Button("Change the container") {}.buttonStyle(CryoButtonStyle(tint: Cryo.attention))
                Button("Remove the metadata") {}.buttonStyle(CryoButtonStyle(tint: Cryo.fail))
            }
            CryoSectionHeader("Chips")
            HStack(spacing: 6) {
                CryoChip("5.1 · 48 kHz")
                CryoChip("COPY · bit-exact", style: .lit)
                CryoChip("SYNC REFERENCE", style: .ref)
            }
            HStack(spacing: 6) {
                CryoChip("TRANSCODE → AAC · 640 Kbps", style: .amber)
                CryoChip("PASS", style: .pass)
                CryoChip("FAIL", style: .fail)
            }
            CryoSectionHeader("What it does to the file")
            HStack(spacing: 6) {
                CryoTouchBadge(touch: .copy); CryoTouchBadge(touch: .mux); CryoTouchBadge(touch: .transcode)
            }
            HStack(spacing: 6) { CryoTouchBadge(touch: .pending); CryoTouchBadge(touch: .readOnly) }
            CryoSectionHeader("Lamps")
            HStack(spacing: 16) {
                lamp(Cryo.ice, "COPY"); lamp(Cryo.attention, "ATTENTION"); lamp(Cryo.pass, "PASS"); lamp(Cryo.fail, "FAIL"); lamp(Cryo.info, "READ ONLY")
            }
        }
    }

    var choicesColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            CryoSectionHeader("Switches")
            VStack(spacing: 8) {
                Toggle("Verify every audio sample against the sources", isOn: $verify).toggleStyle(CryoToggleStyle())
                Toggle("Interleave audio every 500 ms", isOn: $interleave).toggleStyle(CryoToggleStyle())
            }
            CryoSectionHeader("Where will this file play?")
            CryoSegmented(selection: $container, options: [(value: "mov", label: "MOV"), (value: "mp4", label: "MP4"), (value: "mkv", label: "MKV")])
            CryoSegmented(selection: $before, options: [(value: 0, label: "Before alignment"), (value: 1, label: "After alignment")])
            CryoSectionHeader("Fields")
            HStack(alignment: .bottom, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    CryoFieldLabel("Track name")
                    TextField("Track name", text: $name).cryoField()
                }
                VStack(alignment: .leading, spacing: 5) {
                    CryoFieldLabel("Language")
                    TextField("Language", text: $language).cryoField().frame(width: 70)
                }
                VStack(alignment: .leading, spacing: 5) {
                    CryoFieldLabel("Bitrate (Mbps)")
                    Text("80.0").font(CryoFont.mono(12.5)).foregroundStyle(Cryo.ink).frame(minHeight: 30)
                }
            }
            CryoSectionHeader("Notices")
            NoticeRow(text: "Dolby Vision XML matches the picture: 120 frames at 24 fps.", level: .ok)
            NoticeRow(text: "Audio track order differs from the Academy's (Atmos = 1, 5.1 PCM = 2).", level: .warn)
            NoticeRow(text: "The XML has 120 frames; the picture has 121.", level: .fail)
            NoticeRow(text: "Stereo from the video goes on the Audio tab — added there.", level: .info)
            CryoSectionHeader("Older pieces (Design.swift)")
            HStack(spacing: 6) {
                Chip(text: "PCM 24-bit"); Chip(text: "Atmos", tint: .blue); Chip(text: "WARN", tint: .orange); Chip(text: "PASS", tint: .green)
                Spacer(minLength: 6)
                IconTile(symbol: "film", color: .indigo); IconTile(symbol: "waveform", color: .green); IconTile(symbol: "exclamationmark.triangle", color: .orange)
            }
            KeyValueRow(label: "Free on that drive", value: "2.31 TB · needs about 79 GB while muxing (temp copy + final file)", chip: "OK", chipTint: .green)
        }
    }

    var slotsColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            CryoSectionHeader("Slots · normal, highlighted, not in the file")
            CryoSlot { slotTrack(name: "Dolby Atmos", chips: [("E-AC-3 JOC", .plain), ("COPY · bit-exact", .lit)], meta: "768 Kbps · 16 objects · 48 kHz", note: ("checkmark.circle.fill", "lined up with the picture", Cryo.pass)) }
            CryoSlot(highlighted: true) { slotTrack(name: "PCM 5.1", chips: [("Audio track 1", .lit), ("6 ch", .plain)], meta: "PCM 24-bit · 6 mono WAVs joined · 48 kHz", note: ("arrow.left.arrow.right", "swapped with Audio track 2", Cryo.ice)) }
            CryoSlot(dimmed: true) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "lock.fill").foregroundStyle(Cryo.ink2)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) { Text("Stereo").font(CryoFont.title(13.5)).foregroundStyle(Cryo.ink).lineLimit(1); CryoChip("SYNC REFERENCE", style: .ref) }
                        Text("Used only to line up your mix with the picture — not in the file").font(CryoFont.body(12)).foregroundStyle(Cryo.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    Button("Change") {}.buttonStyle(CryoButtonStyle())
                }
            }
            CryoSectionHeader("Sync gauges")
            CryoSlot {
                VStack(spacing: 12) {
                    CryoGauge(valueMs: 8.6, rangeMs: -50...130, goodMs: -15...45, label: "Dolby Atmos vs picture")
                    CryoGauge(valueMs: 83.3, rangeMs: -50...130, goodMs: -15...45, label: "PCM 5.1 vs picture")
                    CryoGauge(valueMs: -22, rangeMs: -50...130, goodMs: -15...45, label: "Stereo vs picture")
                    CryoGauge(valueMs: nil, rangeMs: -50...130, goodMs: -15...45, label: "Not lined up yet")
                }
            }
        }
    }

    var linesColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            CryoSectionHeader("Signal lines")
            CryoSlot {
                VStack(alignment: .leading, spacing: 10) {
                    signal(.copy, "Picture", "ProRes 4444")
                    signal(.mux, "Audio 1", "6 WAVs → 5.1")
                    signal(.transcode, "Picture", "→ HEVC DV")
                    signal(.pending, "Stereo", "from the video")
                    signal(.readOnly, "Checker", "reads only")
                }
            }
            CryoSectionHeader("Source → Destination")
            CryoDiffTable(rows: [
                CryoDiffRow(label: "Codec", from: "ProRes 4444", to: "HEVC Main 10", changed: true),
                CryoDiffRow(label: "Bitrate", from: "1,900 Mbps", to: "≈ 80 Mbps", changed: true),
                CryoDiffRow(label: "Primaries", from: "P3-D65", to: "BT.2020", changed: true),
                CryoDiffRow(label: "Transfer", from: "PQ", to: "PQ", changed: false),
                CryoDiffRow(label: "Resolution", from: "3840×2160", to: "3840×2160", changed: false),
            ])
            CryoSectionHeader("Edge light · idle and rendering")
            HStack(spacing: 12) {
                miniWindow(progress: nil, caption: "idle")
                miniWindow(progress: 0.72, caption: "rendering 72 %")
            }
        }
    }

    // MARK: page 2

    var pageTwo: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                CryoSectionHeader("Alert card · attention, with the logo")
                CryoAlertCard(logo: AnyView(DolbyVisionLogo(height: 20)), title: "ProRes 4444 can't carry Dolby Vision",
                              subtitle: "To embed 2DIE4.xml the picture must be transcoded. Your master isn't changed.",
                              lines: [CryoAlertCard.Line(level: .ok, title: "XML readable", detail: "dovi_tool 2.3.4 · CM v4.0 · 8.1 out"),
                                      CryoAlertCard.Line(level: .warn, title: "Level 5 active area", detail: "XML 3840×1608 · picture 3840×1600 (cropdetect)"),
                                      CryoAlertCard.Line(level: .fail, title: "Frames", detail: "XML 120 · picture 121 — ask the colourist for an XML of 121 frames at 24 fps"),
                                      CryoAlertCard.Line(level: .info, title: "Waiting for the picture…")],
                              detected: "ProRes 4444 · P3-D65 / PQ · 1,000 nits",
                              recommendation: "HEVC 10-bit · Dolby Vision 8.1 + HDR10 (x265), converted to BT.2020",
                              actions: [CryoAlertCard.Action("Deliver without it") {}, CryoAlertCard.Action("Remove the metadata", role: .destructive) {},
                                        CryoAlertCard.Action("Transcode to embed it", role: .primary) {}])
                CryoSectionHeader("Alert card · a plain question")
                CryoAlertCard(title: "This audio came inside the video. Use it in the delivery?",
                              subtitle: "PCM stereo · 48 kHz · 24-bit. It keeps lining up your mix with the picture either way.",
                              actions: [CryoAlertCard.Action("Use it") {}, CryoAlertCard.Action("Don't use", role: .primary) {}])
            }
            .frame(width: 572)
            VStack(alignment: .leading, spacing: 12) {
                CryoSectionHeader("Logos")
                HStack(spacing: 22) {
                    DolbyVisionLogo(height: 22); HDR10PlusLogo(height: 22); DolbyVisionLogo(height: 13); HDR10PlusLogo(height: 13)
                }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Cryo.s0))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Cryo.hairline, lineWidth: 1))
                CryoSectionHeader("Seals · lit, and etched when not passed")
                HStack(spacing: 14) {
                    CryoSeal(kind: .academy, passed: true, caption: "Accepted specs")
                    CryoSeal(kind: .zidoo, passed: true, caption: "Plays on Z9X Pro")
                    CryoSeal(kind: .academy, passed: false, caption: "Not approved")
                    CryoSeal(kind: .zidoo, passed: false, caption: "Not checked")
                }
                CryoSectionHeader("Academy verdict")
                AcademySeal(level: .preferred, caption: "Checked in the final file")
                AcademySeal(level: .accepted, caption: "H.264 picture", compact: true)
                AcademySeal(level: .notApproved, caption: "PCM in MP4 is not accepted", compact: true)
                CryoSectionHeader("Run bay · glass panel and tubes")
                CryoPanel {
                    HStack(alignment: .bottom, spacing: 16) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Pass 2 of 2 · encoding").font(CryoFont.body(13.5, weight: .semibold)).foregroundStyle(Cryo.ink)
                            Text("x265 · HEVC Main 10 · Dolby Vision 8.1").font(CryoFont.body(11.5)).foregroundStyle(Cryo.ink2)
                            Text("42 %").font(CryoFont.readout(30)).foregroundStyle(.white).padding(.top, 4)
                            Text("36,402 / 86,659 frames · about 1 h 12 min left").font(CryoFont.mono(11)).foregroundStyle(Cryo.ink2)
                        }
                        Spacer(minLength: 8)
                        CryoTube(label: "CPU", value: "86 %", fraction: 0.86)
                        CryoTube(label: "GPU", value: "12 %", fraction: 0.12)
                        CryoTube(label: "Memory", value: "21 GB", fraction: 0.33)
                        CryoTube(label: "Write", value: "38 MB/s", fraction: 0.2)
                    }
                    .padding(16)
                }
            }
            .frame(width: 560)
            VStack(alignment: .leading, spacing: 12) {
                CryoSectionHeader("Drop zones · waiting, and a file over it")
                HStack(spacing: 0) {
                    CryoDropZone(title: "Drop the picture", subtitle: "ProRes, HEVC, H.264, an IMF or a Dolby Vision XML", systemImage: "film", targeted: false) {}
                    CryoDropZone(title: "Release to add", subtitle: "the frost recedes while a file is over it", systemImage: "film", targeted: true) {}
                }
                .frame(height: 400).padding(.horizontal, -12).padding(.vertical, -12)
                CryoSectionHeader("Terminal and inset group")
                TerminalBox(text: "# every track copied bit for bit\nMP4Box -new\n  -add 2DIE4_OSCARS_STEREO_80mbps.mov#video:name=Video\n  -add pcm51_interleaved.wav#audio:name=\"PCM 5.1\"\n  2DIE4_ACADEMY_V2.mov", scrolls: false)
                GroupBox("Inset group") { Text("A GroupBox with .inset takes the slot look.").font(CryoFont.body(12.5)).foregroundStyle(Cryo.ink2) }.groupBoxStyle(.inset)
            }
            .frame(width: 600)
        }
    }

    // MARK: helpers

    func lamp(_ c: Color, _ word: String) -> some View {
        HStack(spacing: 6) { CryoLamp(c); Text(word).font(CryoFont.label(9.5)).tracking(1).foregroundStyle(Cryo.ink2) }
    }

    func slotTrack(name: String, chips: [(String, CryoChip.Style)], meta: String, note: (String, String, Color)) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(name).font(CryoFont.title(14)).foregroundStyle(Cryo.ink)
                ForEach(chips.indices, id: \.self) { i in CryoChip(chips[i].0, style: chips[i].1) }
            }
            Text(meta).font(CryoFont.mono(11)).foregroundStyle(Cryo.ink2)
            Label(note.1, systemImage: note.0).font(CryoFont.body(11.5)).foregroundStyle(note.2)
        }
    }

    func signal(_ t: FileTouch, _ name: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            Text(name).font(CryoFont.body(12)).foregroundStyle(Cryo.ink).frame(width: 52, alignment: .leading)
            CryoSignalLine(touch: t).frame(width: 84)
            CryoTouchBadge(touch: t)
            Text(text).font(CryoFont.mono(10.5)).foregroundStyle(Cryo.ink2).lineLimit(1)
        }
    }

    func miniWindow(progress: Double?, caption: String) -> some View {
        ZStack(alignment: .topLeading) {
            CryoWindowBackground(progress: progress)
            Text(caption).font(CryoFont.mono(10.5)).foregroundStyle(Cryo.ink2).padding(12)
        }
        .frame(width: 210, height: 110)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
