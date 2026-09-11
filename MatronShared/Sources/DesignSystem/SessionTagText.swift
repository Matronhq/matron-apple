import SwiftUI

/// Builds the styled `A:bc ` run that leads a chat title: the box letter in
/// the box's chip hue (so the eye can match rows to machines by color at
/// the START of the scan), the `:bc` session short in primary — Dan reads
/// the short constantly, so it matches the title's weight; only the
/// colon/separator punctuation stays secondary (Dan, 2026-08-16: "duller
/// than the chat title but should be closer to it"). Returned as a `Text`
/// so callers concatenate it with the title and the whole line truncates
/// as one — a separate view would ellipsize the title while the tag kept
/// its own layout box.
///
/// Either half may be missing: single-box users have no letter (same gate
/// as `BoxChip`), seed titles and pre-#224 conversations have no session
/// short. `nil` when there is nothing to show at all.
///
/// `SessionTag.searchSpellings` (MatronChat — this module can't see it) is
/// the plain-text mirror of these runs, so chat search matches what the
/// rows render. Changing a separator glyph here means changing it there.
public enum SessionTagText {
    public static func run(
        boxLetter: String?,
        boxName: String?,
        sessionShort: String?,
        colorScheme: ColorScheme
    ) -> Text? {
        let tint = boxName.map { BoxChip.textTint(for: $0, in: colorScheme) } ?? .secondary
        let letter = boxLetter.map {
            Text($0).foregroundStyle(tint).fontWeight(.semibold)
        }
        let short = sessionShort.map { s -> Text in
            let glyphs = Text(s).foregroundStyle(.primary)
            guard boxLetter != nil else { return glyphs }
            return Text(":").foregroundStyle(.secondary) + glyphs
        }
        switch (letter, short) {
        case (nil, nil): return nil
        case (let l?, nil): return l
        case (nil, let s?): return s
        case (let l?, let s?): return l + s
        }
    }

    /// The multi-agent room variant: one letter per participating box, each
    /// in its own box's hue — `A↔B` for a pair, `A,B,C` beyond — then the
    /// 2-char room short in primary, same as the single-box tag.
    /// `letters` and `names` are parallel arrays (`ChatSummary.roomBoxShorts`
    /// / `roomBoxNames`): letters are the glyphs, names carry the hue.
    /// `nil` unless at least two boxes arrive — the gates upstream mean a
    /// non-room, a local room, or a single-box user all fall through to
    /// `run(...)`.
    public static func room(
        letters: [String],
        names: [String],
        sessionShort: String?,
        colorScheme: ColorScheme
    ) -> Text? {
        guard letters.count >= 2, letters.count == names.count else { return nil }
        let separator = Text(letters.count == 2 ? "↔" : ",").foregroundStyle(.secondary)
        var run: Text?
        for (letter, name) in zip(letters, names) {
            let colored = Text(letter)
                .foregroundStyle(BoxChip.textTint(for: name, in: colorScheme))
                .fontWeight(.semibold)
            run = run.map { $0 + separator + colored } ?? colored
        }
        guard let tag = run else { return nil }
        guard let short = sessionShort else { return tag }
        return tag + Text(":").foregroundStyle(.secondary)
            + Text(short).foregroundStyle(.primary)
    }

    /// Plain-text mirror of `room`/`run`'s room-first fallback, for sites
    /// that need the same tag as a VoiceOver label rather than a colored
    /// `Text` run (CodeRabbit #209: `MissionDetailView`'s milestone row
    /// announced only `boxName`, omitting the other room boxes and the
    /// session short a multi-agent room's visual tag carries). Speaks box
    /// NAMES, not the single-letter glyphs the visual run draws (fix
    /// round 2, H3: the first version spoke "d", "↔" — box letters and a
    /// separator glyph meant to be read, not heard). `nil` when there is
    /// nothing to show, same as `room`/`run`.
    public static func plainLabel(
        boxName: String?,
        sessionShort: String?,
        roomBoxNames: [String] = []
    ) -> String? {
        // Mirrors `room(...)`'s own gate exactly (fix round 3, N2): that
        // Text-producing branch requires at least 2 names, so a single
        // `roomBoxNames` entry falls through to the single-box `boxName`
        // there too — this branch must agree, or VoiceOver speaks a
        // "room" label the eye never sees.
        let names = roomBoxNames.count >= 2 ? roomBoxNames : [boxName].compactMap { $0 }
        let joinedNames = names.isEmpty ? nil : names.joined(separator: ", ")
        switch (joinedNames, sessionShort) {
        case (nil, nil): return nil
        case (let n?, nil): return n
        case (nil, let s?): return s
        case (let n?, let s?): return "\(n), \(s)"
        }
    }

    /// The full title line: room tag first, single-box tag second, bare
    /// title last — one composition shared by every place a tagged title
    /// renders (list rows, chat headers, search results), so the fallback
    /// order can't drift between them. `title` arrives ready to sit beside
    /// whatever tag renders (callers drop the room marker only when they
    /// pass ≥2 room participants — `SessionTag.titleBesideRoomTag`).
    public static func titleLine(
        title: String,
        boxLetter: String?,
        boxName: String?,
        sessionShort: String?,
        roomBoxNames: [String] = [],
        roomBoxShorts: [String] = [],
        colorScheme: ColorScheme
    ) -> Text {
        let tag = room(letters: roomBoxShorts, names: roomBoxNames,
                       sessionShort: sessionShort, colorScheme: colorScheme)
            ?? run(boxLetter: boxLetter, boxName: boxName,
                   sessionShort: sessionShort, colorScheme: colorScheme)
        guard let tag else { return Text(title) }
        return tag + Text(" ") + Text(title)
    }
}
