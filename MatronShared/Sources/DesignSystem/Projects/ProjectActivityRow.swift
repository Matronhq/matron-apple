import SwiftUI
import MatronModels

/// One row of the project page's "Latest" feed: the kind's glyph (a
/// thumbnail for an image), the title, a note saying what it is, and the
/// mission and time at the trailing edge. Fonts are parameters so the
/// Mac page draws it in its own sizes.
public struct ProjectActivityRow: View {
    let event: ProjectActivityEvent
    let image: Image?
    let time: String
    let titleFont: Font
    let noteFont: Font
    let metaFont: Font

    public init(event: ProjectActivityEvent, image: Image? = nil, time: String,
                titleFont: Font = .body, noteFont: Font = .subheadline, metaFont: Font = .caption) {
        self.event = event; self.image = image; self.time = time
        self.titleFont = titleFont; self.noteFont = noteFont; self.metaFont = metaFont
    }

    public var body: some View {
        let struck = isStruck
        HStack(alignment: .top, spacing: 10) {
            ProjectActivityGlyph(event: event, image: image).frame(width: 22, alignment: .center).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(ProjectActivityFormat.title(event)).font(titleFont).lineLimit(2)
                    .strikethrough(struck).foregroundStyle(struck ? Color.secondary : Color.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let note = ProjectActivityFormat.note(event) {
                    Text(note).font(noteFont).foregroundStyle(.secondary).lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                if let num = event.missionNum {
                    Text(verbatim: "#\(num)").font(metaFont.monospacedDigit()).foregroundStyle(.blue)
                }
                Text(time).font(metaFont.monospacedDigit()).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(ProjectActivityFormat.accessibilityLabel(event)), \(time)")
    }

    private var isStruck: Bool {
        if case .decision(let d) = event { return ProjectDecisionMark(d).isStruck }
        return false
    }
}

/// The feed row's glyph: a milestone's dot or person, a decision's mark,
/// an image's thumbnail (a document glyph for a file), an item's kind in
/// red when it waits on the user.
public struct ProjectActivityGlyph: View {
    let event: ProjectActivityEvent
    let image: Image?

    public init(event: ProjectActivityEvent, image: Image? = nil) { self.event = event; self.image = image }

    public var body: some View {
        switch event {
        case .milestone(let m):
            Image(systemName: MissionGlyph.symbol(m.milestone.kind)).font(.caption)
                .foregroundStyle(MissionGlyph.tint(m.milestone.kind))
        case .decision(let d):
            let mark = ProjectDecisionMark(d)
            Image(systemName: mark.symbol).foregroundStyle(mark.tint)
        case .file(let f):
            if f.isImage, let image {
                image.resizable().aspectRatio(contentMode: .fill).frame(width: 22, height: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            } else {
                Image(systemName: f.isImage ? "photo" : "doc.fill").foregroundStyle(.secondary)
            }
        case .item(let i):
            Image(systemName: ItemGlyph.symbol(i.kind))
                .foregroundStyle(i.awaiting == .user ? Color.red : ItemGlyph.tint(i.kind))
        }
    }
}

/// The headline card's pulse: the mission counts with their dots, then
/// the sessions and last-activity clause. One line on the Mac, two on a
/// phone (`axis`).
public struct ProjectPulseLine: View {
    let page: ProjectPageModel
    let now: Date
    let axis: Axis
    let font: Font

    public init(page: ProjectPageModel, now: Date, axis: Axis = .vertical, font: Font = .caption) {
        self.page = page; self.now = now; self.axis = axis; self.font = font
    }

    public var body: some View {
        let parts = ProjectActivityFormat.missionParts(page.project.missions)
        let sessions = ProjectActivityFormat.sessionsLine(page, now: now)
        Group {
            if axis == .horizontal {
                HStack(spacing: 8) {
                    counts(parts)
                    if !parts.isEmpty { Text("·") }
                    Text(sessions)
                }
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    if !parts.isEmpty { HStack(spacing: 8) { counts(parts) } }
                    Text(sessions)
                }
            }
        }
        .font(font).foregroundStyle(.secondary).lineLimit(1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel((parts.map(\.text) + [sessions]).joined(separator: ", "))
    }

    private func counts(_ parts: [ProjectPulsePart]) -> some View {
        ForEach(parts) { part in
            HStack(spacing: 4) {
                Circle().fill(part.tint).frame(width: 7, height: 7)
                Text(part.text)
            }
        }
    }
}

/// A folded reference section's label row: glyph, title, count, chevron.
public struct ProjectFoldLabel: View {
    let section: ProjectReferenceSection
    let detail: String?
    let font: Font
    let detailFont: Font

    public init(section: ProjectReferenceSection, detail: String?, font: Font = .body, detailFont: Font = .subheadline) {
        self.section = section; self.detail = detail; self.font = font; self.detailFont = detailFont
    }

    public var body: some View {
        HStack(spacing: 10) {
            Image(systemName: section.symbol).foregroundStyle(.secondary).frame(width: 22)
            Text(section.title).font(font)
            Spacer(minLength: 8)
            if let detail { Text(detail).font(detailFont.monospacedDigit()).foregroundStyle(.secondary) }
        }
        .accessibilityElement(children: .combine)
    }
}
