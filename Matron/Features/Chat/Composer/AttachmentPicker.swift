import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Plus menu that opens either the photo library (`PhotosPicker`) or
/// the system file importer. Selection state is bound back to
/// `ComposerView` which forwards to the view model's `attachFiles(_:)`
/// once the URL/data is materialised.
struct AttachmentPicker: View {
    @Binding var photoItem: PhotosPickerItem?
    @Binding var showFileImporter: Bool

    var body: some View {
        Menu {
            // `photoLibrary: .shared()` is required for
            // `PhotosPickerItem.itemIdentifier` to be populated. Without
            // it, `itemIdentifier` is always nil and the consumer falls
            // back to a hardcoded `"photo.jpg"` filename — which forces
            // every selection to be sent as `image/jpeg` regardless of
            // the actual format (HEIC, PNG, …).
            PhotosPicker(
                selection: $photoItem,
                matching: .images,
                photoLibrary: .shared()
            ) {
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
