import SwiftUI
import AppKit
import MatronDesignSystem

/// The Mac composer's input: `MacComposerTextEditor` (the `NSTextView`
/// that re-wraps on live resize, inserts a newline on Shift+Return and
/// claims ⌘V of images/files) on the composer surface, with its placeholder
/// and grow-then-scroll height.
///
/// Shared by the chat composer (`MacComposerView`) and a tracker item's
/// reply composer (`MacItemDetailHost`, through `ItemCommentComposer`'s
/// field slot), so the two inputs are one implementation — the same keys,
/// the same paste gate, the same look — rather than two that drift apart.
/// Everything behavioural is the caller's, passed straight through to the
/// editor (see `MacComposerTextEditor` for the contract).
struct MacComposerField: View {
    @Binding var text: String
    let placeholder: String
    var onMoveUp: () -> Bool = { false }
    var onMoveDown: () -> Bool = { false }
    let onCommit: () -> Bool
    let onPasteAttachments: () -> Bool
    let onAttachablePasteboardTypes: () -> [NSPasteboard.PasteboardType]
    var onFocusChange: ((Bool, NSWindow?) -> Void)? = nil
    /// See `MacComposerTextEditor.isChatComposer`.
    var isChatComposer = false

    /// Measured height of the input's content (text + padding), reported by
    /// `MacComposerTextEditor` and driving the grow-then-scroll frame below.
    @State private var contentHeight: CGFloat = 0

    /// The input's vertical padding (top and bottom). Reads the editor's
    /// own inset so the single-line height below stays tied to it: if the
    /// inset changes, the accessory-button height follows.
    private static var verticalPadding: CGFloat {
        MacComposerTextEditor.textInset
    }

    private static var lineHeight: CGFloat {
        let body = NSFont.preferredFont(forTextStyle: .body)
        return ceil(body.ascender - body.descender + body.leading)
    }

    /// Rendered height of a one-line input: the body font's line height plus
    /// the input's vertical padding top and bottom. Accessory buttons beside
    /// the field pin their icon container to this so they sit centred
    /// against a single-line field.
    static var singleLineHeight: CGFloat {
        lineHeight + verticalPadding * 2
    }

    /// The input stops growing at 8 lines and scrolls internally beyond that.
    static var maxHeight: CGFloat {
        lineHeight * 8 + verticalPadding * 2
    }

    var body: some View {
        // Grow-then-scroll input: an AppKit `NSTextView` whose text
        // container tracks the view width (so a live window resize
        // re-wraps the text — the SwiftUI field editor didn't),
        // inside its own NSScrollView. The frame tracks
        // the reported content height up to `maxHeight` — past 8
        // lines the frame stops growing and the content scrolls, with
        // the text view keeping the caret in view as it always does.
        MacComposerTextEditor(
            text: $text,
            onHeightChange: { contentHeight = $0 },
            onMoveUp: onMoveUp,
            onMoveDown: onMoveDown,
            onCommit: onCommit,
            onPasteAttachments: onPasteAttachments,
            onAttachablePasteboardTypes: onAttachablePasteboardTypes,
            onFocusChange: onFocusChange,
            isChatComposer: isChatComposer
        )
            .frame(height: min(max(contentHeight, Self.singleLineHeight), Self.maxHeight))
            // White (dark-mode: elevated warm) input surface, same
            // as bot bubbles — `.regularMaterial` read muddy-dark
            // against the cream timeline gradient. Matches
            // matron-web's white composer on the cream ground.
            .background(Color.matronBubbleBot)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(color: .matronBubbleShadow, radius: 2, y: 1)
            // NSTextView has no placeholder — draw it in SwiftUI,
            // aligned with the editor's own text inset.
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .foregroundStyle(Color(nsColor: .placeholderTextColor))
                        .padding(MacComposerTextEditor.textInset)
                        .allowsHitTesting(false)
                }
            }
    }
}
