import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Plus menu that opens either the photo library or the system file
/// importer. BOTH rows are plain buttons that only raise a flag — the
/// pickers themselves are presented by `ComposerView` modifiers.
///
/// A `PhotosPicker` placed directly in this `Menu` renders a row that does
/// NOTHING when tapped (Dan, 2026-07-15, iOS): tapping dismisses the menu,
/// and the picker goes down with the presentation context it was relying
/// on, so it never appears. "File" always worked because it already used
/// the flag + presenting-modifier pattern; "Photo" now matches it.
struct AttachmentPicker: View {
    @Binding var showPhotosPicker: Bool
    @Binding var showFileImporter: Bool

    var body: some View {
        Menu {
            Button {
                showPhotosPicker = true
            } label: {
                Label("Photo", systemImage: "photo")
            }
            Button {
                showFileImporter = true
            } label: {
                Label("File", systemImage: "doc")
            }
        } label: {
            Image(systemName: "plus.circle")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 2)
                // Fill the height ComposerView pins on this picker so the
                // whole accessory column stays tappable, not just the glyph.
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
        }
    }
}
