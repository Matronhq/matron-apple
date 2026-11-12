import SwiftUI
import os
import MatronViewModels

/// Breadcrumbs for a crash that only AppKit and SwiftUI are on the stack of:
/// `EXC_BAD_ACCESS` under `NSHostingView._regionForOpaqueDescendants`, from
/// the window's drag-region pass.
///
/// The window's title bar is clear, so AppKit asks every hosting view under
/// it where a click drags the window. A hosting view answers from its SwiftUI
/// graph; asked while SwiftUI is rebuilding that graph, it reads one that is
/// gone. In the reports the hosting view is the split view's detail column,
/// and nothing in them says why its graph was being rebuilt.
///
/// So this logs, at `notice` level (kept in the unified log), when the detail
/// column's content is built or torn down and the changes around it that
/// re-lay the title bar or the column's root. Read with:
///
///     log show --last 10m --predicate 'subsystem == "chat.matron" AND category == "detail-column"'
enum MacDetailColumnLog {
    static let logger = Logger(subsystem: "chat.matron", category: "detail-column")

    /// How many times the detail column's root has appeared this launch. One
    /// is the window opening; every one after is the column's content being
    /// built again.
    @MainActor static var rootAppearances = 0

    static func note(_ event: String) {
        logger.notice("\(event, privacy: .public)")
    }
}

/// Sits at the root of the detail column, outside everything that changes
/// with the page shown: its probe's `onAppear` fires again only when SwiftUI
/// builds the column's content anew.
///
/// The modifier itself reads nothing, so it never re-evaluates the column.
/// Everything observed is read by `MacDetailColumnProbe`, a leaf behind it.
struct MacDetailColumnDiagnostics: ViewModifier {
    let voiceNotes: VoiceNoteSession?
    let markdownPreview: MarkdownPreviewModel

    func body(content: Content) -> some View {
        content.background { MacDetailColumnProbe(voiceNotes: voiceNotes, markdownPreview: markdownPreview) }
    }

    /// Which rows the voice-note pill shows; it sits in a safe-area inset at
    /// the column's root, so a change re-lays the whole column.
    static func pillState(_ session: VoiceNoteSession?) -> String {
        guard let session else { return "none" }
        var rows: [String] = []
        if session.showsIndicator { rows.append("recording") }
        if session.sendingTarget != nil { rows.append("sending") }
        if !session.failures.isEmpty { rows.append("failed×\(session.failures.count)") }
        return rows.isEmpty ? "none" : rows.joined(separator: "+")
    }
}

/// An invisible leaf: a change it observes re-evaluates this view alone.
private struct MacDetailColumnProbe: View {
    let voiceNotes: VoiceNoteSession?
    let markdownPreview: MarkdownPreviewModel
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        Color.clear
            .onAppear {
                MacDetailColumnLog.rootAppearances += 1
                MacDetailColumnLog.note("root appeared #\(MacDetailColumnLog.rootAppearances)")
            }
            .onDisappear { MacDetailColumnLog.note("root disappeared") }
            .onChange(of: MacDetailColumnDiagnostics.pillState(voiceNotes)) { old, new in
                MacDetailColumnLog.note("voice-note pill \(old) -> \(new)")
            }
            .onChange(of: markdownPreview.isOpen) { _, open in
                MacDetailColumnLog.note("markdown panel \(open ? "opened" : "closed")")
            }
            .onChange(of: controlActiveState) { _, state in MacDetailColumnLog.note("window \(Self.name(state))") }
    }

    private static func name(_ state: ControlActiveState) -> String {
        switch state {
        case .key: "key"
        case .active: "active"
        case .inactive: "inactive"
        @unknown default: "unknown"
        }
    }
}
