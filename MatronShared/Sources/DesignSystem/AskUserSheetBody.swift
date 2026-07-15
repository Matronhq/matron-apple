import SwiftUI
import MatronEvents

/// The inner content of an ask-user prompt — prompt text, one of four
/// input kinds, expiry notice, error line. Single-choice options and
/// Yes/No are one-tap answer buttons (web/desktop-client parity); a
/// Send button appears only for the kinds a tap can't fully answer
/// (free text, multi-select, "Other…"). Single source of truth for
/// BOTH platforms via `AskUserCard` — nothing in the body itself
/// branches per platform.
///
/// Parameterised on plain state values + bindings (not the ViewModel)
/// so DesignSystem stays decoupled from app/service types and the
/// snapshot tests can render every input kind directly.
public struct AskUserSheetBody: View {
    public let event: AskUserEvent
    @Binding public var textInput: String
    @Binding public var selectedChoiceIDs: Set<String>
    @Binding public var booleanAnswer: Bool?
    public let isSending: Bool
    public let isExpired: Bool
    public let error: String?
    public let onSend: () -> Void

    public init(
        event: AskUserEvent,
        textInput: Binding<String>,
        selectedChoiceIDs: Binding<Set<String>>,
        booleanAnswer: Binding<Bool?>,
        isSending: Bool,
        isExpired: Bool,
        error: String? = nil,
        onSend: @escaping () -> Void
    ) {
        self.event = event
        self._textInput = textInput
        self._selectedChoiceIDs = selectedChoiceIDs
        self._booleanAnswer = booleanAnswer
        self.isSending = isSending
        self.isExpired = isExpired
        self.error = error
        self.onSend = onSend
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(event.prompt).font(.body)

            switch event.kind {
            case .text:
                TextField("Your answer…", text: $textInput, axis: .vertical)
                    .lineLimit(3...8)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isExpired)

            case .choice(let options, let allowOther):
                // One tap answers — a light accent-tinted chip per option, no
                // radio + Send round-trip (parity with the web/desktop clients
                // and the bridge's Matrix buttons). The binding write lands
                // synchronously before `onSend()`, so the ViewModel's send
                // reads the fresh selection. When any option's label leads with
                // a glyph (e.g. "⚡ Send now") every row reserves the fixed
                // glyph slot so the text after it lines up across the stack.
                let choiceReservesGlyph = optionsHaveGlyph(options)
                ForEach(options, id: \.id) { opt in
                    Button {
                        selectedChoiceIDs = [opt.id]
                        onSend()
                    } label: {
                        choiceButtonLabel(opt.label, reserveGlyphSlot: choiceReservesGlyph)
                    }
                    .buttonStyle(.plain)
                    .disabled(isSending || isExpired)
                }
                if allowOther {
                    TextField("Other…", text: $textInput)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isExpired)
                }

            case .multiChoice(let options, let allowOther):
                // The checkbox already provides a fixed leading slot; when any
                // label leads with a glyph, reserve a second fixed slot between
                // the checkbox and the text so mixed lists still align.
                let multiReservesGlyph = optionsHaveGlyph(options)
                ForEach(options, id: \.id) { opt in
                    let split = splitLeadingGlyph(opt.label)
                    Button {
                        if selectedChoiceIDs.contains(opt.id) {
                            selectedChoiceIDs.remove(opt.id)
                        } else {
                            selectedChoiceIDs.insert(opt.id)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: selectedChoiceIDs.contains(opt.id) ? "checkmark.square.fill" : "square")
                            glyphSlot(split.glyph, reserve: multiReservesGlyph)
                            Text(split.text)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(isExpired)
                }
                if allowOther {
                    TextField("Other…", text: $textInput)
                        .textFieldStyle(.roundedBorder)
                        .disabled(isExpired)
                }

            case .boolean:
                // Same one-tap contract as `.choice`.
                HStack {
                    booleanButton("Yes", selectedWhen: true)
                    booleanButton("No", selectedWhen: false)
                    Spacer()
                }
            }

            if isExpired {
                Label("This question has expired.", systemImage: "clock.badge.exclamationmark")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            // Send exists only where a tap can't be the whole answer:
            // free text, multi-select, or a choice set with an "Other…"
            // field. Instant kinds surface in-flight state as a bare
            // spinner instead (their option buttons are already disabled
            // while sending).
            if needsSendButton {
                Button {
                    onSend()
                } label: {
                    if isSending { ProgressView() } else { Text("Send") }
                }
                .buttonStyle(.borderedProminent)
                .tint(.matronAccent)
                .keyboardShortcut(.defaultAction)
                .disabled(isSending || isExpired)
            } else if isSending {
                ProgressView()
            }
        }
        .padding()
    }

    private var needsSendButton: Bool {
        switch event.kind {
        case .text, .multiChoice:
            return true
        case .choice(_, let allowOther):
            return allowOther
        case .boolean:
            return false
        }
    }

    @ViewBuilder
    private func booleanButton(_ title: String, selectedWhen value: Bool) -> some View {
        Button {
            booleanAnswer = value
            onSend()
        } label: {
            Text(title)
                .modifier(AccentChip(dimmed: isSending || isExpired))
        }
        .buttonStyle(.plain)
        .disabled(isSending || isExpired)
    }

    /// A full-width, leading-aligned accent-tinted answer chip for a `.choice`
    /// option. Splits any leading glyph into a fixed 18pt slot so the text
    /// after it aligns across the stack; `reserveGlyphSlot` keeps the slot on
    /// glyphless rows when *other* rows in the same list carry a glyph.
    @ViewBuilder
    private func choiceButtonLabel(_ label: String, reserveGlyphSlot: Bool) -> some View {
        let split = splitLeadingGlyph(label)
        HStack(spacing: 8) {
            glyphSlot(split.glyph, reserve: reserveGlyphSlot)
            Text(split.text)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(AccentChip(dimmed: isSending || isExpired))
    }

    /// The fixed 18pt leading slot: the glyph centred when present, an empty
    /// reservation when a sibling row has one, nothing otherwise.
    @ViewBuilder
    private func glyphSlot(_ glyph: String?, reserve: Bool) -> some View {
        if let glyph {
            Text(glyph).frame(width: 18, alignment: .center)
        } else if reserve {
            // Reserve the 18pt width only — a fixed height:0 keeps `Color.clear`
            // from staying vertically greedy and stretching the row (the sibling
            // `Text` defines the row height).
            Color.clear.frame(width: 18, height: 0)
        }
    }

    /// Whether any option's label leads with a glyph — drives the per-list
    /// decision to reserve the glyph slot on every row.
    private func optionsHaveGlyph(_ options: [AskUserEvent.Option]) -> Bool {
        options.contains { splitLeadingGlyph($0.label).glyph != nil }
    }
}

/// The light, airy answer-chip chrome shared by `.choice` and `.boolean`
/// buttons: a brand-accent fill + hairline border with accent-coloured
/// text that reads clearly on the white card in both colour schemes.
/// `Color.matronAccent` (not the system `accentColor`) — the default blue
/// read foreign against the warm cream palette (Dan, 2026-07-15). `.plain`
/// button style drops the system's automatic disabled dimming, so callers
/// pass `dimmed` to restore it.
///
/// Chips deepen under the pointer (Dan, 2026-07-15: buttons read "very
/// dead" without a hover state). `onHover` never fires on touch-only
/// iPhones, so the shared modifier costs iOS nothing; iPad pointer users
/// get it for free.
private struct AccentChip: ViewModifier {
    let dimmed: Bool

    @State private var hovering = false

    private var highlighted: Bool { hovering && !dimmed }

    func body(content: Content) -> some View {
        content
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .foregroundStyle(Color.matronAccent)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.matronAccent.opacity(highlighted ? 0.22 : 0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.matronAccent.opacity(highlighted ? 0.6 : 0.35), lineWidth: 1)
            )
            .contentShape(Rectangle())
            .opacity(dimmed ? 0.5 : 1)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
