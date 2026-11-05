// BROS-MUX — design system: spacing (DS) and the shared small pieces, drawn in the Cryo language (Cryo.swift).
// One 8-pt grid. The APIs below are the ones every screen already uses; only their look is Cryo: opaque recessed
// groups, caps labels, etched chips, status colours with an icon and a word, code on the slab. Colour only carries
// meaning — a system colour handed to these pieces is turned into its Cryo token (Cryo.mapped).

import SwiftUI
import AppKit

/// Name and version shown in the window title, the welcome screen, the reports and the Finder (build.sh writes the same
/// version into Info.plist — keep the two in step).
enum AppInfo {
    static let version = "2.0.1"
    static let label = "Beta 2.0.1"            // the working version's name: shown wherever the version is
    static let name = "BROS-MUX \(label)"
}

enum DS {
    static let margin: CGFloat = 16          // content edge
    static let gap: CGFloat = 12             // between groups
    static let rowGap: CGFloat = 8           // inside a group
    static let radius: CGFloat = 12          // grouped containers
    static let tile: CGFloat = 28            // icon tile
    static let inspectorWidth: CGFloat = 400
    static let sidebarWidth: CGFloat = 200

    /// The frame of a big sheet: its designed size, shrunk to what the screen can show. A MacBook screen is 982 points
    /// tall; a sheet taller than that is clipped by macOS and its Done button is out of reach.
    static func sheet(_ width: CGFloat, _ height: CGFloat) -> CGSize {
        let screen = NSScreen.main?.visibleFrame.size ?? CGSize(width: width, height: height)
        return CGSize(width: min(width, screen.width - 48), height: min(height, screen.height - 48))
    }

    /// Fill of a grouped container in a free layout: the recessed slot (opaque, below the slab)
    static let groupFill = Color(.sRGB, red: 0x06 / 255.0, green: 0x0E / 255.0, blue: 0x15 / 255.0, opacity: 1)
    /// Hairline around a grouped container: a faint ice edge
    static let groupStroke = Color(.sRGB, red: 0x8C / 255.0, green: 0xDC / 255.0, blue: 0xFF / 255.0, opacity: 0.10)
    /// Background of waveform and chart canvases (content layer, a neutral dark ground like a scope — no cyan behind data)
    static let scope = Cryo.scope
}

// MARK: - Containers

/// A titled, rounded container: a caps label over an opaque recessed slot, for free layouts
struct InsetGroupStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: DS.radius + 2, style: .continuous)
        VStack(alignment: .leading, spacing: 8) {
            configuration.label
                .font(CryoFont.label(10.5)).tracking(2).textCase(.uppercase)
                .foregroundStyle(Cryo.ink3)
                .padding(.leading, 4)
                .accessibilityAddTraits(.isHeader)
            configuration.content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(shape.fill(Cryo.recess.shadow(.inner(color: .black.opacity(0.85), radius: 8, y: 6))))
                .overlay(shape.strokeBorder(DS.groupStroke, lineWidth: 1))
        }
    }
}
extension GroupBoxStyle where Self == InsetGroupStyle {
    static var inset: InsetGroupStyle { InsetGroupStyle() }
}

/// Inline notice (information, warning or failure) placed next to what it describes: an opaque plate tinted by the
/// status, with its icon and its word (PASS / ATTENTION / FAIL) — never colour alone
struct NoticeRow: View {
    let text: String
    var level: CheckLevel = .info
    var body: some View {
        let c = Cryo.status(level)
        let shape = RoundedRectangle(cornerRadius: DS.radius, style: .continuous)
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: level.icon).foregroundStyle(c).accessibilityHidden(true)
            if let w = Cryo.word(level) {
                Text(w).font(CryoFont.label(9.5)).tracking(1.2).foregroundStyle(c).fixedSize()
            }
            Text(text).font(CryoFont.body(12.5)).foregroundStyle(Cryo.ink)
                .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
        .padding(.leading, 14).padding(.trailing, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(Cryo.mix(Cryo.s1, c, level == .info ? 0.03 : 0.08)))
        .overlay(alignment: .leading) { Rectangle().fill(c.opacity(level == .info ? 0.5 : 0.9)).frame(width: 3).accessibilityHidden(true) }
        .clipShape(shape)
        .overlay(shape.strokeBorder(c.opacity(level == .info ? 0.18 : 0.35), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

/// The fixed strip at the top of a tab: what this tab does, and nothing else (the old two-tab strip, drawn as a Cryo
/// plate: an amber tint means the file is re-encoded)
struct TabStrip: View {
    let symbol: String
    let title: String
    let text: String
    let tint: Color
    var body: some View {
        let mapped = Cryo.mapped(tint)
        let touch: FileTouch = mapped == Cryo.attention ? .transcode : (mapped == Cryo.info || mapped == Cryo.ink2 ? .readOnly : .copy)
        CryoPlateRow(touch: touch, title: title.trimmingCharacters(in: CharacterSet(charactersIn: " ·")), text: text, symbol: symbol) { EmptyView() }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
    }
    static let mux = TabStrip(symbol: "checkmark.seal.fill", title: "Mux ·", text: "nothing is re-encoded — picture and sound go in and out bit for bit; tracks are only combined.", tint: Cryo.ice)
    static let transcode = TabStrip(symbol: "arrow.triangle.2.circlepath", title: "Transcode ·", text: "the file is re-encoded — codec, quality, size, resolution and colour can change. The original is never touched; a new file is always written.", tint: Cryo.attention)
}

// MARK: - Small pieces

/// Icon tile: an etched dark square lit from inside by its colour (no Settings-style coloured squares)
struct IconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = DS.tile
    var lit: Color { Cryo.mapped(color) }
    var glow: RadialGradient {
        RadialGradient(colors: [lit.opacity(0.28), lit.opacity(0.08)], center: UnitPoint(x: 0.5, y: 0.3), startRadius: 0, endRadius: size * 0.8)
    }
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
        Image(systemName: symbol)
            .font(.system(size: size * 0.46, weight: .medium))
            .foregroundStyle(Cryo.mix(lit, .white, 0.25))
            .frame(width: size, height: size)
            .background(shape.fill(glow))
            .background(shape.fill(Cryo.s2))
            .overlay(shape.strokeBorder(lit.opacity(0.45), lineWidth: 1))
            .accessibilityHidden(true)
    }
}

/// Small etched tag; monochrome unless it carries a state (a system colour becomes its Cryo token)
struct Chip: View {
    let text: String
    var tint: Color? = nil
    var body: some View {
        let c = tint.map(Cryo.mapped) ?? Cryo.ink2
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        Text(text)
            .font(CryoFont.label(10)).tracking(0.6)
            .padding(.horizontal, 7).frame(minHeight: 19)
            .foregroundStyle(c)
            .background(shape.fill(tint == nil ? Color.white.opacity(0.05) : c.opacity(0.11)))
            .overlay(shape.strokeBorder(tint == nil ? Color.white.opacity(0.10) : c.opacity(0.38), lineWidth: 1))
            .fixedSize()
    }
}

/// Monospaced read-only text (logs, commands, reports) on the slab, in the code colour.
/// On a page that scrolls itself (a Form, the inspector) pass `scrolls: false`: the box then grows and wraps with its
/// text, because a scroll view nested in a scrolling page swallows the wheel whenever the cursor is over it.
struct TerminalBox: View {
    let text: String
    var scrolls = true
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        Group {
            if scrolls {
                ScrollView([.vertical, .horizontal]) { content }
            } else {
                content.fixedSize(horizontal: false, vertical: true)
            }
        }
        .background(shape.fill(Color(.sRGB, red: 0x02 / 255.0, green: 0x05 / 255.0, blue: 0x08 / 255.0, opacity: 1)))
        .overlay(shape.strokeBorder(Cryo.ice.opacity(0.10), lineWidth: 1))
    }

    var content: some View {
        Text(text.isEmpty ? " " : text)
            .font(CryoFont.mono(11))
            .lineSpacing(3)
            .foregroundStyle(Cryo.codeText)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
    }
}

extension View {
    /// A picker in a sheet header: segments while there are a few choices, a pop-up menu beyond that
    /// (a segmented control with dozens of tracks runs over the whole header)
    @ViewBuilder func headerPickerStyle(count: Int) -> some View {
        if count <= 4 { pickerStyle(.segmented) } else { pickerStyle(.menu) }
    }
}

/// Key / value row for free layouts (the Form has LabeledContent)
struct KeyValueRow: View {
    let label: String
    let value: String
    var chip: String? = nil
    var chipTint: Color? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label).font(CryoFont.body(12.5, weight: .semibold)).foregroundStyle(Cryo.ink)
                Spacer(minLength: 8)
                if let chip { Chip(text: chip, tint: chipTint) }
            }
            Text(value).font(CryoFont.body(11.5)).foregroundStyle(Cryo.ink2).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }
}

/// Title of a sheet: an expanded title, an optional subtitle in mono, controls on the trailing side
struct SheetHeader<Accessory: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var accessory: () -> Accessory
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(CryoFont.title(22)).tracking(0.5).foregroundStyle(Cryo.ink).accessibilityAddTraits(.isHeader)
                if let subtitle { Text(subtitle).font(CryoFont.mono(11.5)).foregroundStyle(Cryo.ink2).lineLimit(1).truncationMode(.middle) }
            }
            Spacer(minLength: 12)
            accessory()
        }
        .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 6)
    }
}

/// Buttons at the bottom trailing corner of a sheet, under a faint ice rule
struct SheetButtons<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        HStack(spacing: 10) { Spacer(); content() }
            .padding(.horizontal, 20).padding(.vertical, 14)
            .overlay(alignment: .top) {
                Rectangle().fill(LinearGradient(colors: [Cryo.ice.opacity(0), Cryo.ice.opacity(0.18), Cryo.ice.opacity(0)], startPoint: .leading, endPoint: .trailing))
                    .frame(height: 1).padding(.horizontal, 20).accessibilityHidden(true)
            }
    }
}
