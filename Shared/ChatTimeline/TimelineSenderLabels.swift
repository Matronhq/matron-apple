import MatronChat

/// Sender presentation shared by both timelines (iOS `TimelineItemView`, Mac
/// `MacTimelineItemView` and both table/collection timelines).
enum TimelineSenderLabels {
    /// Non-nil only in multi-sender rooms, never for own rows or the
    /// streaming placeholder.
    static func avatarSender(for item: TimelineItem, hasMultipleSenders: Bool) -> String? {
        guard !item.isOwn, hasMultipleSenders, !item.isEphemeralStreamingPlaceholder else { return nil }
        return item.sender
    }

    /// Local part of a Matrix-style id without the `@` sigil.
    static func displayName(for senderID: String) -> String {
        let withoutSigil = senderID.hasPrefix("@") ? String(senderID.dropFirst()) : senderID
        return withoutSigil.split(separator: ":").first.map(String.init) ?? senderID
    }
}
