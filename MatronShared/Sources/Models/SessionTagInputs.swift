import Foundation

/// The halves `SessionTagText.run` and `SessionTagText.room` need, carried
/// as one value so a leaf view can draw a conversation's tag without
/// reaching for a store. Any half may be missing: single-box users have no
/// letter (the same gate `BoxChip` uses), and seed titles / pre-#224
/// conversations have no session short. `roomBoxNames`/`roomBoxShorts` are
/// parallel arrays (mirroring `ChatSummary.roomBoxNames`/`roomBoxShorts`),
/// empty unless the conversation is a multi-agent room with ≥2 distinct
/// boxes — the same gate `JournalChatService.roomTags(for:boxNames:boxLetters:)`
/// applies, so a caller tries `SessionTagText.room` first (falling back to
/// `.run`) exactly as the chat list does (Bugbot: the mission page carried
/// only the `run` halves, so a room conversation there rendered as an
/// owner-box tag instead of `A↔B:bc`, or no tag at all). A `nil`
/// `SessionTagInputs` means "no tag at all" — never an empty placeholder.
public struct SessionTagInputs: Equatable, Hashable, Sendable {
    public var boxLetter: String?
    public var boxName: String?
    public var sessionShort: String?
    public var roomBoxNames: [String]
    public var roomBoxShorts: [String]
    public init(boxLetter: String?, boxName: String?, sessionShort: String?,
                roomBoxNames: [String] = [], roomBoxShorts: [String] = []) {
        self.boxLetter = boxLetter
        self.boxName = boxName
        self.sessionShort = sessionShort
        self.roomBoxNames = roomBoxNames
        self.roomBoxShorts = roomBoxShorts
    }
}
