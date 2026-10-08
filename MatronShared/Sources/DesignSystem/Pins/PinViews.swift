import SwiftUI

/// A pinned desk chat's glyph (journal "Pinned desk chats"): its emoji, or
/// the label's first letter in a tinted rounded square. A missing pin draws
/// greyed out.
public struct PinGlyph: View {
    private let glyph: String
    private let size: CGFloat
    private let dimmed: Bool

    public init(_ glyph: String, size: CGFloat = 28, dimmed: Bool = false) {
        self.glyph = glyph
        self.size = size
        self.dimmed = dimmed
    }

    /// An emoji draws bare; a letter gets the tinted square.
    static func isLetter(_ glyph: String) -> Bool {
        guard let scalar = glyph.unicodeScalars.first else { return true }
        return glyph.count == 1 && !scalar.properties.isEmojiPresentation
            && !(scalar.properties.isEmoji && glyph.unicodeScalars.count > 1)
    }

    public var body: some View {
        Group {
            if Self.isLetter(glyph) {
                Text(glyph)
                    .font(.system(size: size * 0.55, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white)
                    .frame(width: size, height: size)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: size * 0.25))
            } else {
                Text(glyph)
                    .font(.system(size: size * 0.8))
                    .frame(width: size, height: size)
            }
        }
        .saturation(dimmed ? 0 : 1)
        .opacity(dimmed ? 0.45 : 1)
        .accessibilityHidden(true)
    }
}

/// The name and emoji fields of a pin, shared by "Pin…" and Settings →
/// Pinned chats. The caller clamps on save; the counter shows the
/// journal's 24-character limit as the user types.
public struct PinEditorFields: View {
    @Binding private var label: String
    @Binding private var emoji: String
    private let labelMax: Int

    public init(label: Binding<String>, emoji: Binding<String>, labelMax: Int = 24) {
        _label = label
        _emoji = emoji
        self.labelMax = labelMax
    }

    /// The label's length as the journal counts it (code points).
    static func count(_ text: String) -> Int {
        text.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.count
    }

    public var body: some View {
        TextField("Name", text: $label, prompt: Text("Release desk"))
            .accessibilityIdentifier("pin.label")
        if Self.count(label) > labelMax {
            Text("Names are cut to \(labelMax) characters.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        TextField("Emoji", text: $emoji, prompt: Text("📮 (optional)"))
            .accessibilityIdentifier("pin.emoji")
    }
}
