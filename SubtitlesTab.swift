// BROS-MUX Beta 2.0.0 — 03 · SUBTITLES: reserved ("coming in a later Beta"). The subtitles found in the files are listed,
// each one starting out of the file; "Include" puts it in as it is (the engine muxes an included subtitle track with its
// text and timing unchanged). Nothing here edits, styles, converts or burns in a subtitle.

import SwiftUI

/// Which subtitle the inspector shows (shared by the tab and its inspector; nil = the first one)
@Observable final class SubtitlesSelection {
    static let shared = SubtitlesSelection()
    var id: UUID?
}

struct SubtitlesTab: View {
    @Environment(Project.self) private var project
    let targeted: Bool
    @Bindable private var selection = SubtitlesSelection.shared

    /// The sidebar line: "coming later" until a subtitle is found, then how many go in the file
    static func sidebarLine(project: Project) -> String {
        let subs = project.subtitleTracks
        guard !subs.isEmpty else { return "coming later" }
        return "\(subs.filter(\.include).count) of \(subs.count) included"
    }

    /// The strip's text: this step muxes subtitles as they are; say how many are in the file
    static func stripText(project: Project) -> String {
        let subs = project.subtitleTracks
        let n = subs.filter(\.include).count
        if subs.isEmpty { return "coming in a later Beta · nothing from this step is in the file" }
        if n == 0 { return "coming in a later Beta · none of the \(subs.count) subtitle\(subs.count == 1 ? "" : "s") found is in the file" }
        return "coming in a later Beta · \(n) of \(subs.count) go\(n == 1 ? "es" : "") in the file as \(n == 1 ? "it is" : "they are")"
    }

    var body: some View {
        let subs = project.subtitleTracks
        VStack(spacing: 0) {
            CryoStrip(touch: .mux, title: "SUBTITLES", text: Self.stripText(project: project))
            if subs.isEmpty {
                VStack(spacing: 0) {
                    notices.padding(.horizontal, 16).padding(.top, 12)
                    CryoDropZone(title: "Subtitles — coming in a later Beta",
                                 subtitle: "Drop SRT, WebVTT or TTML files, or a video that carries subtitles. Each subtitle found is listed here and starts out of the file; “Include” puts it in, as it is. Editing and styling subtitles come in a later Beta.",
                                 systemImage: AppMode.subtitles.symbol, targeted: targeted) { project.openPanel() }
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        notices
                        HStack(alignment: .firstTextBaseline) {
                            CryoSectionHeader("Found in your files · \(subs.count)")
                            Text("“Include” puts one in the file, as it is").font(CryoFont.body(11.5)).foregroundStyle(Cryo.ink3).fixedSize()
                        }
                        ForEach(subs) { t in row(t, subs: subs) }
                        HStack(spacing: 10) {
                            Button("Add Subtitle Files…") { project.openPanel() }.buttonStyle(CryoButtonStyle())
                            Text("Included subtitles are muxed as they are: their text and timing aren't changed.")
                                .font(CryoFont.body(11.5)).foregroundStyle(Cryo.ink3)
                        }
                        .padding(.top, 6)
                    }
                    .frame(maxWidth: 980, alignment: .leading)
                    .padding(.horizontal, 20).padding(.vertical, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .overlay {
                    if targeted {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Cryo.ice, style: StrokeStyle(lineWidth: 2, dash: [6, 4])).padding(10).allowsHitTesting(false)
                    }
                }
            }
        }
    }

    @ViewBuilder var notices: some View {
        let list = project.notices(for: .subtitles)
        if !list.isEmpty {
            VStack(spacing: 6) { ForEach(list) { NoticeRow(text: $0.text, level: $0.level) } }
        }
    }

    func row(_ t: Track, subs: [Track]) -> some View {
        let selected = (selection.id ?? subs.first?.id) == t.id
        let slot = subs.filter(\.include).firstIndex { $0.id == t.id }
        return CryoSlot(highlighted: selected, dimmed: !t.include) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "captions.bubble").font(.system(size: 18, weight: .light))
                    .foregroundStyle(t.include ? Cryo.ice : Cryo.ink3).frame(width: 24).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(t.title.isEmpty ? "Subtitles" : t.title).font(CryoFont.title(14)).foregroundStyle(Cryo.ink).lineLimit(1)
                        CryoChip(t.codecName)
                        CryoChip(Languages.name(t.language))
                        if t.badges.contains("Forced") { CryoChip("Forced", style: .lit) }
                    }
                    Text("\(t.url.lastPathComponent) · \(t.sourceLabel)").font(CryoFont.mono(11)).foregroundStyle(Cryo.ink3)
                        .lineLimit(1).truncationMode(.middle)
                    ForEach(t.warnings + project.containerWarnings(t), id: \.self) { w in
                        Label(w, systemImage: CheckLevel.warn.icon).font(CryoFont.body(11.5)).foregroundStyle(Cryo.attention)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                VStack(alignment: .trailing, spacing: 6) {
                    Text(slot.map { "Subtitle track \($0 + 1)" } ?? "Not in the file")
                        .font(CryoFont.label(10.5)).tracking(0.8).foregroundStyle(t.include ? Cryo.ice : Cryo.ink3)
                    if let b = project.binding(for: t.id) {
                        Toggle(isOn: b.include) { Text("Include").font(CryoFont.body(12)).foregroundStyle(Cryo.ink2) }
                            .toggleStyle(CryoToggleStyle()).fixedSize()
                            .help(t.include ? "Leave this subtitle out of the file" : "Put this subtitle in the file, as it is")
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { selection.id = t.id }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(t.title), \(t.codecName), \(Languages.name(t.language)), \(t.include ? "in the file" : "not in the file")")
    }
}

struct SubtitlesInspector: View {
    @Environment(Project.self) private var project
    @Bindable private var selection = SubtitlesSelection.shared
    init() {}

    var body: some View {
        let subs = project.subtitleTracks
        let t = subs.first { $0.id == selection.id } ?? subs.first
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let t {
                    CryoSectionHeader("Subtitle")
                    CryoSlot(highlighted: false, dimmed: false) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(t.title.isEmpty ? "Subtitles" : t.title).font(CryoFont.title(15)).foregroundStyle(Cryo.ink)
                            fact("Language", "\(Languages.name(t.language)) (\(t.language))")
                            fact("Title", t.title.isEmpty ? "—" : t.title)
                            fact("Format", "\(t.codecName) · \(t.codecKey)")
                            fact("From", "\(t.url.lastPathComponent) · \(t.sourceLabel)")
                            fact("In the player", t.badges.contains("Forced") ? "Forced — always shown" : t.enabled ? "Shown by default" : "Off until chosen in the player")
                        }
                    }
                    CryoSlot {
                        VStack(alignment: .leading, spacing: 6) {
                            if let b = project.binding(for: t.id) {
                                Toggle(isOn: b.include) { Text("Include in the file").font(CryoFont.body(12.5)).foregroundStyle(Cryo.ink) }
                                    .toggleStyle(CryoToggleStyle())
                            }
                            Text(t.include ? "Goes in the file as it is: its text and timing aren't changed." : "Not in the file.")
                                .font(CryoFont.body(11.5)).foregroundStyle(Cryo.ink3).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    ForEach(t.warnings + project.containerWarnings(t), id: \.self) { NoticeRow(text: $0, level: .warn) }
                    Text("Editing, styling and timing subtitles come in a later Beta.")
                        .font(CryoFont.body(11)).foregroundStyle(Cryo.ink3).fixedSize(horizontal: false, vertical: true)
                } else {
                    CryoSectionHeader("Subtitles")
                    Text("Coming in a later Beta. The subtitles found in your files are listed on this step; each one starts out of the file, and “Include” puts it in as it is.")
                        .font(CryoFont.body(12.5)).foregroundStyle(Cryo.ink2).fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
        }
    }

    func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(CryoFont.label(9.5)).tracking(1).foregroundStyle(Cryo.ink3)
            Text(value).font(CryoFont.body(12.5)).foregroundStyle(Cryo.ink).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}
