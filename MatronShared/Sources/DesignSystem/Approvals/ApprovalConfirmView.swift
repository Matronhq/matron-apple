import SwiftUI

/// The confirm sheet for a signed approval: what is being approved, the
/// button, and every line of the subject exactly as it will be signed,
/// above the button that asks for Face ID or Touch ID.
///
/// Pure: plain values and closures, so both apps host it and it renders in
/// tests without a key.
public struct ApprovalConfirmView: View {
    public struct Model: Equatable {
        /// The item's number as text ("#7"), when the approval is a tap or
        /// a consent item.
        public var reference: String?
        /// The item's title, or the account action.
        public var headline: String
        /// The button being pressed, for a tap or a consent answer.
        public var button: String?
        /// The question's words, or a spawn's task in full.
        public var detail: String?
        /// A box the request is sent to (unlock, clear lockdown, start).
        public var box: String?
        /// The subject's lines, key and value, in the order they are signed.
        public var subject: [Line]
        /// "Face ID" or "Touch ID".
        public var method: String
        /// The fingerprint of the key that signs.
        public var fingerprint: String
        /// This device's key is re-attached first: the system asks twice.
        public var attachesFirst: Bool
        public var isSigning: Bool
        public var error: String?

        public struct Line: Equatable, Identifiable {
            public var key: String
            public var value: String
            public var id: String { key }
            public init(key: String, value: String) { self.key = key; self.value = value }
        }

        public init(reference: String? = nil, headline: String, button: String? = nil, detail: String? = nil,
                    box: String? = nil, subject: [Line], method: String, fingerprint: String,
                    attachesFirst: Bool = false, isSigning: Bool = false, error: String? = nil) {
            self.reference = reference; self.headline = headline; self.button = button; self.detail = detail
            self.box = box; self.subject = subject; self.method = method; self.fingerprint = fingerprint
            self.attachesFirst = attachesFirst; self.isSigning = isSigning; self.error = error
        }
    }

    public let model: Model
    public let onConfirm: () -> Void
    public let onCancel: () -> Void

    public init(model: Model, onConfirm: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.model = model
        self.onConfirm = onConfirm
        self.onCancel = onCancel
    }

    public static let title = "Approve with your key"

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    if let detail = model.detail, !detail.isEmpty { detailBlock(detail) }
                    subjectBlock
                    if model.attachesFirst {
                        note("This device signed in again since its key was added, so the key is re-attached first. \(model.method) is asked twice.",
                             systemImage: "arrow.triangle.2.circlepath")
                    }
                    if let error = model.error {
                        note(error, systemImage: "exclamationmark.triangle.fill", tint: .red)
                            .accessibilityIdentifier("approval.error")
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            footer
        }
        .accessibilityIdentifier("approval.confirm")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(Self.title, systemImage: "lock.shield")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let reference = model.reference {
                    Text(reference)
                        .font(.title3.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(model.headline)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let button = model.button {
                HStack(spacing: 6) {
                    Text("Button")
                        .foregroundStyle(.secondary)
                    Text(button)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.18), in: Capsule())
                }
                .font(.subheadline)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("approval.button")
            }
        }
    }

    private func detailBlock(_ detail: String) -> some View {
        Text(detail)
            .font(.callout)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityIdentifier("approval.detail")
    }

    private var subjectBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What you are signing")
                .font(.subheadline.weight(.semibold))
            if model.subject.isEmpty {
                Text("Nothing beyond the item and the button above.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.subject.enumerated()), id: \.element.id) { index, line in
                        if index > 0 { Divider() }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: line.key)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                            Text(verbatim: line.value.isEmpty ? "(empty)" : line.value)
                                .font(.callout.monospaced())
                                .foregroundStyle(line.value.isEmpty ? .secondary : .primary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.vertical, 8)
                        .padding(.horizontal, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                    }
                }
                .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityIdentifier("approval.subject")
            }
            if let box = model.box {
                Text("Sent to \(box), which checks the signature against the keys pinned on it.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func note(_ text: String, systemImage: String, tint: Color = .secondary) -> some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
        }
        .font(.footnote)
        .foregroundStyle(tint)
    }

    private var footer: some View {
        VStack(spacing: 10) {
            Button(action: onConfirm) {
                HStack(spacing: 8) {
                    if model.isSigning {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: model.method == "Face ID" ? "faceid" : "touchid")
                    }
                    Text(model.isSigning ? "Waiting for \(model.method)…" : "Confirm with \(model.method)")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.isSigning)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("approval.confirmButton")

            HStack {
                Text("Signed by this device's key \(model.fingerprint)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isSigning)
                    .accessibilityIdentifier("approval.cancelButton")
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}
