// BROS-MUX — design system. One 8-pt grid, the system type ramp (no ad-hoc sizes), system materials and
// semantic colours. The accent colour is the system accent; colour otherwise only carries meaning
// (pass / warning / failure, the kind of a track). Everything else is monochrome, like a Mac app.

import SwiftUI
import AppKit

/// Name and version shown in the window title, the welcome screen, the reports and the Finder (build.sh writes the same
/// version into Info.plist — keep the two in step).
enum AppInfo {
    static let version = "1.3"
    static let name = "BROS-MUX (v.\(version))"
}

enum DS {
    static let margin: CGFloat = 16          // content edge
    static let gap: CGFloat = 12             // between groups
    static let rowGap: CGFloat = 8           // inside a group
    static let radius: CGFloat = 10          // grouped containers
    static let tile: CGFloat = 28            // Settings-style icon tile
    static let inspectorWidth: CGFloat = 400
    static let sidebarWidth: CGFloat = 200

    /// Fill of a grouped container in a free layout: white-ish in light mode, one step lighter than the window in dark mode
    static let groupFill = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.06) : NSColor(white: 1, alpha: 0.85)
    })
    /// Hairline around a grouped container
    static let groupStroke = Color(nsColor: NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.10) : NSColor(white: 0, alpha: 0.08)
    })
    /// Background of waveform and chart canvases (content layer, always dark like a scope)
    static let scope = Color(red: 0.09, green: 0.10, blue: 0.12)
}

// MARK: - Containers

/// A titled, rounded container with the look of a grouped Form section, for free layouts
struct InsetGroupStyle: GroupBoxStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            configuration.label.font(.headline).padding(.leading, 2)
            configuration.content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: DS.radius, style: .continuous).fill(DS.groupFill))
                .overlay(RoundedRectangle(cornerRadius: DS.radius, style: .continuous).strokeBorder(DS.groupStroke, lineWidth: 1))
        }
    }
}
extension GroupBoxStyle where Self == InsetGroupStyle {
    static var inset: InsetGroupStyle { InsetGroupStyle() }
}

/// Inline notice (information, warning or failure) placed next to what it describes
struct NoticeRow: View {
    let text: String
    var level: CheckLevel = .info
    var body: some View {
        Label {
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        } icon: {
            Image(systemName: level.icon).foregroundStyle(level.color)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.radius, style: .continuous).fill(level.color.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: DS.radius, style: .continuous).strokeBorder(level.color.opacity(0.22), lineWidth: 1))
    }
}

// MARK: - Small pieces

/// Settings-style icon tile: a white symbol on a coloured rounded square
struct IconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = DS.tile
    var body: some View {
        Image(systemName: symbol)
            .font(.body.weight(.medium))
            .imageScale(size > 32 ? .large : .medium)
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).fill(color.gradient))
            .accessibilityHidden(true)
    }
}

/// Small capsule tag; monochrome unless it carries a state
struct Chip: View {
    let text: String
    var tint: Color? = nil
    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(tint ?? Color.secondary)
            .background(Capsule().fill((tint ?? Color.secondary).opacity(0.12)))
            .fixedSize()
    }
}

/// Monospaced read-only text (logs, commands, reports) on the text background.
/// On a page that scrolls itself (a Form, the inspector) pass `scrolls: false`: the box then grows and wraps with its
/// text, because a scroll view nested in a scrolling page swallows the wheel whenever the cursor is over it.
struct TerminalBox: View {
    let text: String
    var scrolls = true
    var body: some View {
        Group {
            if scrolls {
                ScrollView([.vertical, .horizontal]) { content }
            } else {
                content.fixedSize(horizontal: false, vertical: true)
            }
        }
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(DS.groupStroke, lineWidth: 1))
    }

    var content: some View {
        Text(text.isEmpty ? " " : text)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
    }
}

/// Key / value row for free layouts (the Form has LabeledContent)
struct KeyValueRow: View {
    let label: String
    let value: String
    var chip: String? = nil
    var chipTint: Color? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label).font(.subheadline.weight(.medium))
                Spacer(minLength: 8)
                if let chip { Chip(text: chip, tint: chipTint) }
            }
            Text(value).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
        }
    }
}

/// Title of a sheet: title, optional subtitle, controls on the trailing side
struct SheetHeader<Accessory: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var accessory: () -> Accessory
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title2.weight(.semibold))
                if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
            }
            Spacer(minLength: 12)
            accessory()
        }
        .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 6)
    }
}

/// Buttons at the bottom trailing corner of a sheet
struct SheetButtons<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        HStack(spacing: 10) { Spacer(); content() }
            .padding(.horizontal, 20).padding(.vertical, 14)
    }
}
