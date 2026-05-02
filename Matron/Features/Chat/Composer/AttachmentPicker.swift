import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// Paperclip menu that opens either the photo library (`PhotosPicker`) or
/// the system file importer. Selection state is bound back to
/// `ComposerView` which forwards to the view model's `attachFiles(_:)`
/// once the URL/data is materialised.
struct AttachmentPicker: View {
    @Binding var photoItem: PhotosPickerItem?
    @Binding var showFileImporter: Bool

    var body: some View {
        Menu {
            PhotosPicker(selection: $photoItem, matching: .images) {
                Label("Photo", systemImage: "photo")
            }
            Button {
                showFileImporter = true
            } label: {
                Label("File", systemImage: "doc")
            }
        } label: {
            Image(systemName: "paperclip")
                .font(.title3)
                .foregroundStyle(.secondary)
                .padding(8)
        }
    }
}
