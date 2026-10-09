import ImageIO
import SwiftUI
import MatronShare

/// The share sheet: what is being sent, an optional message, and the
/// conversation it goes to.
struct ShareView: View {
    @Bindable var model: ShareViewModel
    let onCancel: () -> Void
    let onDone: () -> Void

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("Send to Matron")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: onCancel)
                            .disabled(isSending)
                            .accessibilityIdentifier("share.cancel")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Send") { Task { await model.send() } }
                            .fontWeight(.semibold)
                            .disabled(!model.canSend)
                            .accessibilityIdentifier("share.send")
                    }
                }
        }
        .onChange(of: model.phase) { _, phase in
            guard phase == .sent else { return }
            // Long enough to read "Sent", short enough not to be waited on.
            Task {
                try? await Task.sleep(for: .milliseconds(700))
                onDone()
            }
        }
    }

    private var isSending: Bool {
        if case .sending = model.phase { return true }
        return model.phase == .sent
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .signedOut:
            ContentUnavailableView(
                "Sign in to Matron first",
                systemImage: "person.crop.circle.badge.exclamationmark",
                description: Text("Open Matron and sign in, then share again."))
        case .loading where model.files.isEmpty && model.targets.isEmpty:
            ProgressView()
        default:
            form
                .safeAreaInset(edge: .bottom) { statusBar }
        }
    }

    private var form: some View {
        List {
            if let error = model.errorMessage {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                        .accessibilityIdentifier("share.error")
                }
            }
            if !model.files.isEmpty {
                Section {
                    ForEach(model.files) { file in
                        SharedFileRow(file: file, canRemove: !isSending) { model.removeFile(id: file.id) }
                    }
                }
            }
            Section {
                TextField("Add a message", text: $model.message, axis: .vertical)
                    .lineLimit(1...6)
                    .accessibilityIdentifier("share.message")
            }
            Section("Send to") {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search conversations", text: $model.query)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .accessibilityIdentifier("share.search")
                }
                if model.targets.isEmpty, model.isLoadingTargets {
                    HStack {
                        ProgressView()
                        Text("Loading conversations…").foregroundStyle(.secondary)
                    }
                } else if model.visibleTargets.isEmpty, !model.offersNewConversation {
                    Text(model.targets.isEmpty ? "No conversations yet." : "No conversations match.")
                        .foregroundStyle(.secondary)
                }
                // The Coordinator leads, a new conversation comes next, then
                // everything else by how recently it was used.
                targetRows(model.visibleTargets.filter(\.isCoordinator))
                if model.offersNewConversation {
                    NewConversationRow(isSelected: model.isNewConversation) {
                        model.isNewConversation = true
                    }
                    if model.isNewConversation, model.boxes.count > 1 {
                        Picker("Box", selection: $model.selectedBoxID) {
                            ForEach(model.boxes) { box in
                                Text(box.name).tag(Optional(box.id))
                            }
                        }
                        .accessibilityIdentifier("share.box")
                    }
                }
                targetRows(model.visibleTargets.filter { !$0.isCoordinator })
            }
        }
        .listStyle(.insetGrouped)
        .scrollDismissesKeyboard(.interactively)
        .disabled(isSending)
    }

    private func targetRows(_ targets: [ShareTarget]) -> some View {
        ForEach(targets) { target in
            ShareTargetRow(target: target, isSelected: target.id == model.selectedTargetID) {
                model.selectedTargetID = target.id
            }
        }
    }

    /// Progress while sending, and the confirmation after.
    @ViewBuilder
    private var statusBar: some View {
        switch model.phase {
        case .sending(let progress):
            VStack(alignment: .leading, spacing: 6) {
                Text(Self.statusText(for: progress))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                ProgressView(value: progress.fraction)
            }
            .padding()
            .background(.bar)
            .accessibilityIdentifier("share.progress")
        case .sent:
            Label("Sent", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)
                .frame(maxWidth: .infinity)
                .padding()
                .background(.bar)
                .accessibilityIdentifier("share.sent")
        default:
            EmptyView()
        }
    }

    static func statusText(for progress: ShareProgress) -> String {
        switch progress.step {
        case .starting: return "Starting a new conversation…"
        case .waking: return "Waking the box…"
        case .posting, .uploading: break
        }
        guard let index = progress.fileIndex, let name = progress.filename else { return "Sending…" }
        return progress.fileCount > 1
            ? "Uploading \(name) (\(index) of \(progress.fileCount))"
            : "Uploading \(name)"
    }
}

private struct SharedFileRow: View {
    let file: SharedFile
    let canRemove: Bool
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            SharedFileIcon(file: file)
            VStack(alignment: .leading, spacing: 2) {
                Text(file.filename)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(file.formattedSize)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if canRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(file.filename)")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("share.file")
    }
}

/// A small preview for a picture, a document glyph for anything else.
///
/// The preview is made by ImageIO at thumbnail size. Decoding a full camera
/// photo to draw it 40 points wide would cost tens of megabytes, in a
/// process the system ends for using too much memory.
private struct SharedFileIcon: View {
    let file: SharedFile
    @State private var thumbnail: UIImage?

    private static let side: CGFloat = 40

    var body: some View {
        Group {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: file.isImage ? "photo" : "doc")
                    .font(.title3)
                    .foregroundStyle(.tint)
            }
        }
        .frame(width: Self.side, height: Self.side)
        .background(Color(.tertiarySystemFill))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: file.id) {
            guard file.isImage else { return }
            let url = file.url
            let pixels = Self.side * 3
            thumbnail = await Task.detached(priority: .utility) {
                Self.makeThumbnail(url: url, maxPixelSize: pixels)
            }.value
        }
    }

    private static func makeThumbnail(url: URL, maxPixelSize: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

private struct NewConversationRow: View {
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                Image(systemName: "square.and.pencil")
                    .foregroundStyle(.tint)
                Text("New conversation")
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("share.newConversation")
    }
}

private struct ShareTargetRow: View {
    let target: ShareTarget
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                if target.isCoordinator {
                    Image(systemName: "person.crop.circle.badge.checkmark")
                        .foregroundStyle(.tint)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(target.title)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    if let detail = Self.detail(for: target) {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark")
                        .fontWeight(.semibold)
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("share.target")
    }

    /// The Coordinator is labelled as such, unless its title already says so.
    private static func detail(for target: ShareTarget) -> String? {
        guard target.isCoordinator else { return target.detail }
        return target.title.localizedCaseInsensitiveContains("coordinator") ? target.detail : "Coordinator"
    }
}
