import Foundation

/// What a multi-select question draws: its labels as tick-box rows, which
/// of them are ticked now, which the latest answer chose, and whether Send
/// would send anything. Built by `ItemDetailViewModel` for the item's own
/// question and for each follow-up comment that asks one; drawn by the
/// item thread on iPhone and Mac.
public struct ItemMultiSelectState: Equatable, Hashable, Sendable {
    /// The labels offered, in the agent's order.
    public let labels: [String]
    /// The labels ticked now: the user's unsent edit, else the latest
    /// answer's.
    public let ticked: Set<String>
    /// The labels of the latest answer (on its way, or recorded by the
    /// journal); empty before any.
    public let answered: Set<String>
    /// Whether Send is live: something is ticked, it differs from the
    /// latest answer, and no other write is in flight.
    public let canSend: Bool

    public init(labels: [String], ticked: Set<String>, answered: Set<String>, canSend: Bool) {
        self.labels = labels; self.ticked = ticked; self.answered = answered; self.canSend = canSend
    }

    /// Whether the question has been answered at least once.
    public var isAnswered: Bool { !answered.isEmpty }

    /// Whether every label is ticked: the Select all toggle then reads
    /// "Unselect all".
    public var allTicked: Bool { !labels.isEmpty && labels.allSatisfy(ticked.contains) }
}
