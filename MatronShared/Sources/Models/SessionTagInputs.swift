import Foundation

/// The three halves `SessionTagText.run` needs, carried as one value so a
/// leaf view can draw a conversation's `A:bc` tag without reaching for a
/// store. Any half may be missing: single-box users have no letter (the
/// same gate `BoxChip` uses), and seed titles / pre-#224 conversations
/// have no session short. A `nil` `SessionTagInputs` means "no tag at
/// all" — never an empty placeholder.
public struct SessionTagInputs: Equatable, Hashable, Sendable {
    public var boxLetter: String?
    public var boxName: String?
    public var sessionShort: String?
    public init(boxLetter: String?, boxName: String?, sessionShort: String?) {
        self.boxLetter = boxLetter
        self.boxName = boxName
        self.sessionShort = sessionShort
    }
}
