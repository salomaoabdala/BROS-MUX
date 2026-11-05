// BROS-MUX Beta 2.0.0 — Cryo, the design language (dark only): colour tokens, type, and the pieces every tab is built from.
// Wave 0: plain, compiling versions with the exact signatures of BETA2-CONTRACT.swift.md; the Cryo owner replaces the
// bodies (glass, frost, grain, edge light) without changing a signature. The Academy seal moved here unchanged.

import SwiftUI
import AppKit

private func cryoHex(_ v: UInt32) -> Color {
    Color(.sRGB, red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255, opacity: 1)
}

// MARK: - Tokens

/// Colour tokens (dark only)
enum Cryo {
    static let s0: Color = cryoHex(0x05080C)
    static let s1: Color = cryoHex(0x0B1622)
    static let s2: Color = cryoHex(0x111A24)
    static let s3: Color = cryoHex(0x1E2A36)
    static let ink: Color = cryoHex(0xE6EDF3)
    static let ink2: Color = cryoHex(0x9FB0BF)
    static let ink3: Color = cryoHex(0x8396A6)
    static let ice: Color = cryoHex(0x7FE7FF)
    static let icePale: Color = cryoHex(0xB2F8F8)
    static let tint: Color = cryoHex(0x0E7490)
    static let pass: Color = cryoHex(0x5EE6A0)
    static let attention: Color = cryoHex(0xFFB04A)
    static let fail: Color = cryoHex(0xFF6B6B)
    static let info: Color = cryoHex(0x8FA3B3)
    static let gold: Color = cryoHex(0xD8A84E)
}

/// The one place to switch to Archivo / Geist later
enum CryoFont {
    /// SF Pro Expanded semibold
    static func title(_ size: CGFloat) -> Font { Font.system(size: size, weight: .semibold).width(.expanded) }
    static func body(_ size: CGFloat = 13) -> Font { Font.system(size: size) }
    /// Caps labels (use with .tracking)
    static func label(_ size: CGFloat = 10.5) -> Font { Font.system(size: size, weight: .semibold) }
    /// SF Mono, tabular digits
    static func mono(_ size: CGFloat = 12) -> Font { Font.system(size: size, design: .monospaced).monospacedDigit() }
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
}

// MARK: - Surfaces

/// The window slab; while a Delivery renders, the bottom edge light is its progress bar
struct CryoWindowBackground: View {
    let progress: Double?
    init(progress: Double?) { self.progress = progress }
    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Cryo.s0
            if let progress {
                GeometryReader { g in
                    Rectangle().fill(Cryo.ice)
                        .frame(width: g.size.width * CGFloat(max(0, min(1, progress))), height: 2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
            }
        }
        .ignoresSafeArea()
    }
}

/// Glass (the navigation layer)
struct CryoPanel<Content: View>: View {
    let cornerRadius: CGFloat
    let content: Content
    init(cornerRadius: CGFloat = 20, @ViewBuilder content: () -> Content) { self.cornerRadius = cornerRadius; self.content = content() }
    var body: some View {
        content
            .background(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).fill(.ultraThinMaterial))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Cryo.s3, lineWidth: 1))
    }
}

/// An opaque recessed slot (the content layer)
struct CryoSlot<Content: View>: View {
    let highlighted: Bool
    let dimmed: Bool
    let content: Content
    init(highlighted: Bool = false, dimmed: Bool = false, @ViewBuilder content: () -> Content) {
        self.highlighted = highlighted; self.dimmed = dimmed; self.content = content()
    }
    var body: some View {
        content
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Cryo.s1))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(highlighted ? Cryo.ice : Cryo.s3, lineWidth: 1))
            .opacity(dimmed ? 0.55 : 1)
    }
}

/// The fixed strip at the top of a tab: what it does to the file
struct CryoStrip<Trailing: View>: View {
    let touch: FileTouch
    let title: String
    let text: String
    let trailing: Trailing
    init(touch: FileTouch, title: String, text: String, @ViewBuilder trailing: () -> Trailing) {
        self.touch = touch; self.title = title; self.text = text; self.trailing = trailing()
    }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(CryoFont.label(12)).tracking(1).foregroundStyle(touch.color)
            Text("·").foregroundStyle(Cryo.ink3)
            Text(touch.word).font(CryoFont.label(12)).tracking(1).foregroundStyle(touch.color)
            Text(text).font(CryoFont.body()).foregroundStyle(Cryo.ink2).lineLimit(2)
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Cryo.s1)
    }
}
extension CryoStrip where Trailing == EmptyView {
    init(touch: FileTouch, title: String, text: String) { self.init(touch: touch, title: title, text: text) { EmptyView() } }
}

// MARK: - Controls

struct CryoGoButtonStyle: ButtonStyle {
    enum Kind { case primary, amber, ghost, done }
    let kind: Kind
    init(_ kind: Kind = .primary) { self.kind = kind }
    var tint: Color {
        switch kind {
        case .primary: return Cryo.ice
        case .amber: return Cryo.attention
        case .ghost: return Cryo.ink2
        case .done: return Cryo.pass
        }
    }
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(CryoFont.label(12)).tracking(1)
            .foregroundStyle(kind == .ghost ? tint : Cryo.s0)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(Capsule().fill(kind == .ghost ? Color.clear : tint))
            .overlay(Capsule().strokeBorder(tint, lineWidth: 1))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

struct CryoButtonStyle: ButtonStyle {
    let tint: Color?
    init(tint: Color? = nil) { self.tint = tint }
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(CryoFont.body(12))
            .foregroundStyle(tint ?? Cryo.ink)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Cryo.s2))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder((tint ?? Cryo.s3).opacity(0.6), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

struct CryoChip: View {
    enum Style { case plain, lit, ref, amber, pass, fail }
    let text: String
    let style: Style
    init(_ text: String, style: Style = .plain) { self.text = text; self.style = style }
    var color: Color {
        switch style {
        case .plain: return Cryo.ink2
        case .lit: return Cryo.ice
        case .ref: return Cryo.icePale
        case .amber: return Cryo.attention
        case .pass: return Cryo.pass
        case .fail: return Cryo.fail
        }
    }
    var body: some View {
        Text(text)
            .font(CryoFont.label()).tracking(0.5)
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
            .overlay(Capsule().strokeBorder(color.opacity(0.35), lineWidth: 1))
            .fixedSize()
    }
}

struct CryoLamp: View {
    let color: Color
    let size: CGFloat
    init(_ color: Color, size: CGFloat = 10) { self.color = color; self.size = size }
    var body: some View {
        Circle().fill(color).frame(width: size, height: size).accessibilityHidden(true)
    }
}

struct CryoSectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }
    var body: some View {
        Text(title.uppercased()).font(CryoFont.label()).tracking(1.2).foregroundStyle(Cryo.ink3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct CryoSegmented<T: Hashable>: View {
    @Binding var selection: T
    let options: [(value: T, label: String)]
    init(selection: Binding<T>, options: [(value: T, label: String)]) { _selection = selection; self.options = options }
    var body: some View {
        Picker("", selection: $selection) {
            ForEach(options.indices, id: \.self) { i in Text(options[i].label).tag(options[i].value) }
        }
        .pickerStyle(.segmented).labelsHidden()
    }
}

struct CryoToggleStyle: ToggleStyle {
    init() {}
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.label
            Spacer(minLength: 8)
            Capsule().fill(configuration.isOn ? Cryo.ice : Cryo.s3)
                .frame(width: 30, height: 16)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) { Circle().fill(Cryo.ink).padding(2) }
                .onTapGesture { configuration.isOn.toggle() }
        }
    }
}

struct CryoFieldLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(CryoFont.label()).tracking(1).foregroundStyle(Cryo.ink3)
    }
}

extension View {
    /// Inset input look for TextField / Picker
    func cryoField() -> some View {
        self.padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Cryo.s0))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Cryo.s3, lineWidth: 1))
    }
}

// MARK: - Readouts

/// A value in ms on a scale, with the good range marked
struct CryoGauge: View {
    let valueMs: Double?
    let rangeMs: ClosedRange<Double>
    let goodMs: ClosedRange<Double>
    let label: String
    init(valueMs: Double?, rangeMs: ClosedRange<Double>, goodMs: ClosedRange<Double>, label: String) {
        self.valueMs = valueMs; self.rangeMs = rangeMs; self.goodMs = goodMs; self.label = label
    }
    func fraction(_ v: Double) -> CGFloat {
        let span = max(rangeMs.upperBound - rangeMs.lowerBound, 0.001)
        return CGFloat(max(0, min(1, (v - rangeMs.lowerBound) / span)))
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(CryoFont.label()).foregroundStyle(Cryo.ink3)
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Cryo.s3).frame(height: 4)
                    Capsule().fill(Cryo.pass.opacity(0.5))
                        .frame(width: max(0, (fraction(goodMs.upperBound) - fraction(goodMs.lowerBound)) * g.size.width), height: 4)
                        .offset(x: fraction(goodMs.lowerBound) * g.size.width)
                    if let v = valueMs {
                        Circle().fill(goodMs.contains(v) ? Cryo.pass : Cryo.fail).frame(width: 8, height: 8)
                            .offset(x: fraction(v) * g.size.width - 4)
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .frame(height: 10)
            Text(valueMs.map { String(format: "%+.1f ms", $0) } ?? "not measured").font(CryoFont.mono(11)).foregroundStyle(Cryo.ink2)
        }
    }
}

/// A pop-up card: what was found (✓/⚠/✕ lines), DETECTED → RECOMMENDED, and the buttons
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
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if let logo { logo }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(CryoFont.title(16)).foregroundStyle(Cryo.ink)
                    if let subtitle { Text(subtitle).font(CryoFont.body(12)).foregroundStyle(Cryo.ink2) }
                }
            }
            ForEach(lines) { l in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: l.level.icon).foregroundStyle(l.level.color)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(l.title).font(CryoFont.body()).foregroundStyle(Cryo.ink)
                        if !l.detail.isEmpty { Text(l.detail).font(CryoFont.body(11)).foregroundStyle(Cryo.ink2).fixedSize(horizontal: false, vertical: true) }
                    }
                }
            }
            if let detected {
                CryoFieldLabel("Detected")
                Text(detected).font(CryoFont.body(12)).foregroundStyle(Cryo.ink2).fixedSize(horizontal: false, vertical: true)
            }
            if let recommendation {
                CryoFieldLabel("Recommended")
                Text(recommendation).font(CryoFont.body(12)).foregroundStyle(Cryo.ice).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                ForEach(actions.indices, id: \.self) { i in
                    Button(actions[i].title, action: actions[i].run)
                        .buttonStyle(CryoGoButtonStyle(actions[i].role == .primary ? .primary : actions[i].role == .destructive ? .amber : .ghost))
                }
            }
        }
        .padding(16)
        .frame(maxWidth: 520, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Cryo.s1))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Cryo.s3, lineWidth: 1))
    }
}

/// Where files are dropped (frost lives here in the real thing)
struct CryoDropZone: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let targeted: Bool
    let action: () -> Void
    init(title: String, subtitle: String, systemImage: String, targeted: Bool, action: @escaping () -> Void) {
        self.title = title; self.subtitle = subtitle; self.systemImage = systemImage; self.targeted = targeted; self.action = action
    }
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage).font(.system(size: 34, weight: .light)).foregroundStyle(Cryo.ice)
            Text(title).font(CryoFont.title(18)).foregroundStyle(Cryo.ink)
            Text(subtitle).font(CryoFont.body()).foregroundStyle(Cryo.ink2).multilineTextAlignment(.center).frame(maxWidth: 520)
            Button("Choose Files…", action: action).buttonStyle(CryoButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(targeted ? Cryo.ice : Cryo.s3, style: StrokeStyle(lineWidth: targeted ? 2 : 1, dash: [6, 4]))
                .padding(16)
        )
    }
}

/// The Academy (gold) and Zidoo (mint) seals at the end of a Delivery
struct CryoSeal: View {
    enum Kind { case academy, zidoo }
    let kind: Kind
    let passed: Bool
    let caption: String
    init(kind: Kind, passed: Bool, caption: String) { self.kind = kind; self.passed = passed; self.caption = caption }
    var color: Color { passed ? (kind == .academy ? Cryo.gold : Cryo.pass) : Cryo.fail }
    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle().strokeBorder(color, lineWidth: 2)
                if kind == .academy {
                    StatuetteShape().fill(Cryo.gold).frame(width: 12, height: 26)
                } else {
                    Image(systemName: "play.tv").foregroundStyle(color)
                }
            }
            .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(kind == .academy ? "ACADEMY" : "ZIDOO").font(CryoFont.label(12)).tracking(1).foregroundStyle(color)
                Text(caption).font(CryoFont.body(11)).foregroundStyle(Cryo.ink2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// A level tube (CPU, GPU, RAM, disk)
struct CryoTube: View {
    let label: String
    let value: String
    let fraction: Double
    init(label: String, value: String, fraction: Double) { self.label = label; self.value = value; self.fraction = fraction }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(CryoFont.label()).foregroundStyle(Cryo.ink3)
                Spacer(minLength: 4)
                Text(value).font(CryoFont.mono(11)).foregroundStyle(Cryo.ink2)
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Cryo.s3)
                    Capsule().fill(Cryo.ice).frame(width: g.size.width * CGFloat(max(0, min(1, fraction))))
                }
            }
            .frame(height: 4)
        }
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

/// Source → Destination: what changes in amber, what is preserved in grey
struct CryoDiffTable: View {
    let rows: [CryoDiffRow]
    let fromTitle: String
    let toTitle: String
    init(rows: [CryoDiffRow], fromTitle: String = "SOURCE", toTitle: String = "DESTINATION") {
        self.rows = rows; self.fromTitle = fromTitle; self.toTitle = toTitle
    }
    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
            GridRow {
                Text("")
                CryoFieldLabel(fromTitle)
                CryoFieldLabel(toTitle)
            }
            ForEach(rows) { r in
                GridRow {
                    Text(r.label).font(CryoFont.body(12)).foregroundStyle(Cryo.ink3)
                    Text(r.from).font(CryoFont.mono(11)).foregroundStyle(Cryo.ink2)
                    Text(r.to).font(CryoFont.mono(11)).foregroundStyle(r.changed ? Cryo.attention : Cryo.ink2)
                }
            }
        }
    }
}

/// The signal line of a stream: straight for COPY, with an amber node for TRANSCODE
struct CryoSignalLine: View {
    let touch: FileTouch
    init(touch: FileTouch) { self.touch = touch }
    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(touch.color).frame(height: 2)
            if touch == .transcode || touch == .pending {
                Circle().fill(Cryo.attention).frame(width: 8, height: 8)
                Rectangle().fill(touch.color).frame(height: 2)
            }
        }
        .frame(height: 8)
    }
}

// MARK: - Logos (vector; the official art is used if Resources/Logos/*.pdf exists — the Cryo owner wires that)

struct DolbyVisionLogo: View {
    let height: CGFloat
    init(height: CGFloat = 18) { self.height = height }
    var body: some View {
        Text("DOLBY VISION").font(.system(size: height * 0.6, weight: .heavy)).tracking(0.5)
            .foregroundStyle(Cryo.ink).frame(height: height).fixedSize()
    }
}

struct HDR10PlusLogo: View {
    let height: CGFloat
    init(height: CGFloat = 18) { self.height = height }
    var body: some View {
        Text("HDR10+").font(.system(size: height * 0.7, weight: .heavy))
            .foregroundStyle(Cryo.ink).frame(height: height).fixedSize()
    }
}

// MARK: - Effects

/// Ambient effects stop while a Delivery renders (calm) and when the system asks for less motion
@Observable final class EffectsGovernor {
    static let shared = EffectsGovernor()
    var calm = false                                  // the Delivery sets it while a job renders; ambient effects stop
    var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
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

struct AcademySeal: View {
    let level: AcademyLevel?
    let caption: String
    var compact = false

    var body: some View {
        let color = level?.color ?? Color.secondary
        let d: CGFloat = compact ? 48 : 64
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(color.opacity(0.12))
                Circle().strokeBorder(color, lineWidth: 2)
                StatuetteShape()
                    .fill(Color(red: 0.85, green: 0.66, blue: 0.22))
                    .frame(width: d * 0.33, height: d * 0.7)
            }
            .frame(width: d, height: d)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(level?.title ?? "Academy specs: —")
                    .font(compact ? .headline : .title3.weight(.semibold)).foregroundStyle(color)
                Text(level?.explanation ?? "Add a video and audio to evaluate.")
                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(caption).font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
