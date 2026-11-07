import SwiftUI
import MatronModels

// The People pieces iOS and the Mac share: the minted link (QR, Share,
// Copy), what an invite link says about who sent it, and the list rows.
// Each app wraps them in its own Form and sheet chrome.

/// A link just minted, shown this once: a QR code to scan, Share and Copy,
/// and how long it lasts. Nothing here keeps the link.
public struct InviteLinkPanel: View {
    let minted: MintedInvite
    @State private var copied = false

    public init(minted: MintedInvite) {
        self.minted = minted
    }

    public var body: some View {
        VStack(spacing: 16) {
            QRCodeView(string: minted.link, accessibilityLabel: "Invite link QR code")
                .frame(maxWidth: 240, maxHeight: 240)
                .padding(12)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 12))
            Text(MintedInvite.lifetimeNote)
                .font(.callout)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                ShareLink(item: minted.link) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                Button {
                    Pasteboard.copy(minted.link)
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("people.invite.copy")
            }
            Text("Only you see this link, on this device. Send it to the person yourself.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("people.invite.panel")
    }
}

/// Who an invite link is from, for the user to check before accepting:
/// the full address, the journal, and its key fingerprint grouped in fours.
public struct InvitePreviewDetails: View {
    let preview: ContactInvitePreview

    public init(preview: ContactInvitePreview) {
        self.preview = preview
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(preview.address)
                .font(.title3.weight(.semibold))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("people.add.address")
            Text("Journal: \(preview.journal)")
                .font(.body)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            VStack(alignment: .leading, spacing: 4) {
                Text("Fingerprint")
                    .font(.subheadline.weight(.semibold))
                Text(preview.fingerprint)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Fingerprint: \(Self.spokenFingerprint(preview.fingerprint))")
                    .accessibilityIdentifier("people.add.fingerprint")
            }
            Text(ContactInvitePreview.checkNote)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One character at a time, so VoiceOver reads it the way a person
    /// would read it out on a call.
    static func spokenFingerprint(_ grouped: String) -> String {
        grouped.split(separator: " ").map { $0.map(String.init).joined(separator: " ") }.joined(separator: ", ")
    }
}

/// One contact: the address (in full for someone on another journal), and
/// a second line when the row isn't simply active or their key changed.
public struct ContactRow: View {
    let contact: Contact

    public init(contact: Contact) {
        self.contact = contact
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(contact.address)
                .lineLimit(1)
                .truncationMode(.middle)
            if contact.keyChanged {
                Label(Contact.keyChangedNotice, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let line = contact.stateLine {
                Text(line)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// One open invite: when it was made and when it runs out, and Withdraw.
public struct OpenInviteRow: View {
    let invite: ContactInvite
    let isWithdrawing: Bool
    let onWithdraw: () -> Void

    public init(invite: ContactInvite, isWithdrawing: Bool, onWithdraw: @escaping () -> Void) {
        self.invite = invite
        self.isWithdrawing = isWithdrawing
        self.onWithdraw = onWithdraw
    }

    public var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Made \(invite.createdAt.formatted(date: .abbreviated, time: .shortened))")
                Text("Expires \(invite.expiresAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Withdraw", role: .destructive, action: onWithdraw)
                .disabled(isWithdrawing)
                .accessibilityIdentifier("people.invite.withdraw")
        }
    }
}

public enum PeopleText {
    public static let inviteButton = "Invite someone on another Matron"
    public static let openInvites = "Open invites"
    public static let noContacts = "No contacts yet."
    public static let inviteFooter = "Make a link for someone on another Matron journal. When they open it and accept, you become contacts. Being contacts shares nothing by itself."
}
