import SwiftUI
import MatronModels

/// Symbols, labels and tints for missions and milestones — the single place
/// the two vocabularies are named, so a row, a card and a page can never
/// disagree. Sibling of `ItemGlyph`.
public enum MissionGlyph {
    /// The bare mission glyph, for call sites that only know an item or
    /// mission exists — not its open/closed state (e.g. `ItemRow`'s mission
    /// chip, which only has `missionID`/`missionNum`, never a resolved
    /// `MissionState`). Same literal as `symbol(.open)`, named through this
    /// enum instead of duplicated so the two can't silently drift.
    public static func symbol() -> String { symbol(MissionState.open) }
    public static func symbol(_ state: MissionState) -> String {
        switch state { case .open: return "flag.checkered"; case .closed: return "flag.checkered.circle.fill" }
    }
    public static func label(_ state: MissionState) -> String {
        switch state { case .open: return "Open"; case .closed: return "Closed" }
    }
    public static func tint(_ state: MissionState) -> Color {
        switch state { case .open: return .accentColor; case .closed: return .secondary }
    }
    /// `user_input` gets the person glyph — the spec's "kind glyph (person
    /// for `user_input`)" — because finding Dan's own inputs is the point.
    public static func symbol(_ kind: MilestoneKind) -> String {
        switch kind { case .userInput: return "person.fill"; case .progress: return "circle.fill" }
    }
    public static func label(_ kind: MilestoneKind) -> String {
        switch kind { case .userInput: return "Your input"; case .progress: return "Progress" }
    }
    public static func tint(_ kind: MilestoneKind) -> Color {
        switch kind { case .userInput: return .orange; case .progress: return .secondary }
    }
}
