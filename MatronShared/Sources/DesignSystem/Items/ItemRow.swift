import SwiftUI
import MatronModels

public struct ItemRow: View {
    let item: TrackerItem
    let origin: String?
    let thumbnail: Image?
    public init(item: TrackerItem, showsOrigin origin: String? = nil, thumbnail: Image? = nil) {
        self.item = item; self.origin = origin; self.thumbnail = thumbnail
    }

    /// `#61` when the item belongs to a mission, else `nil`. Static so the
    /// copy is testable without rendering — and deliberately bare: `#61` may
    /// name an item, a mission or a milestone, and prefixing it with a type
    /// word would be the only place in the app that pretends otherwise.
    ///
    /// An item can carry a `missionNum` for a mission this device cannot
    /// read (protocol, "Accepted exception — numbers, never words"), so the
    /// chip must never try to resolve a title.
    public static func missionChipText(for item: TrackerItem) -> String? {
        item.missionNum.map { "#\($0)" }
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ItemGlyph.symbol(item.kind))
                .foregroundStyle(ItemGlyph.tint(item.kind))
                .font(.body)
                .frame(width: 20)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("#\(item.num)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Text(item.title).font(.body.weight(.medium)).lineLimit(2)
                }
                if !item.body.isEmpty {
                    Text(item.body.replacingOccurrences(of: "\n", with: " ")).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 8) {
                    if let origin { Text(origin).font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
                    if let chip = Self.missionChipText(for: item) {
                        Label(chip, systemImage: "flag.checkered")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .accessibilityLabel("Mission \(chip)")
                    }
                    if item.needsUser {
                        Text("Needs you").font(.caption2.weight(.semibold)).foregroundStyle(.orange)
                    } else if item.state == .closed, let r = item.resolution {
                        Text(ItemGlyph.label(r)).font(.caption2).foregroundStyle(.tertiary)
                    } else if item.awaiting == .agent {
                        Text("With the agent").font(.caption2).foregroundStyle(.tertiary)
                    }
                    if item.commentCount > 0 {
                        Label("\(item.commentCount)", systemImage: "bubble.left").font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            Spacer(minLength: 0)
            if let thumbnail {
                // `.foregroundStyle` is a no-op on a real bitmap thumbnail
                // (the common case), but without it a template-rendered
                // image (e.g. an SF Symbol placeholder passed in while a
                // real thumbnail is still loading) renders with no tint at
                // all in this target's default environment — effectively
                // invisible against a light background. Matches the
                // `.tertiary` tint used by the `item.hasImage` fallback
                // below so a loading-placeholder and the no-thumbnail
                // fallback read the same.
                thumbnail.resizable().scaledToFill().frame(width: 40, height: 40).clipShape(RoundedRectangle(cornerRadius: 6)).foregroundStyle(.tertiary)
            } else if item.hasImage {
                Image(systemName: "photo").foregroundStyle(.tertiary).frame(width: 40, height: 40)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(ItemGlyph.label(item.kind)) \(item.num), \(item.title)\(item.needsUser ? ", needs you" : "")")
    }
}
