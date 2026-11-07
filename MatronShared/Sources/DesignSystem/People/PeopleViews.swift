import SwiftUI
import MatronModels

// The People pieces iOS and the Mac share: the minted link (QR, Share,
// Copy), what an invite link says about who sent it, and the list rows.
// Each app wraps them in its own Form and sheet chrome.

/// A link just minted, shown this once: a QR code to scan, Share and Copy,
/// and how long it lasts. Nothing here keeps the link. A link minted by
/// Approve on an agent's ask also says it is shown only here.
public struct InviteLinkPanel: View {
    let minted: MintedInvite
    @State private var copied = false

    public init(minted: MintedInvite) {
        self.minted = minted
    }

    public var body: some View {
        VStack(spacing: 16) {
            if minted.fromAgentAsk {
                Text(MintedInvite.agentAskNote)
                    .font(.callout.weight(.semibold))
                    .multilineTextAlignment(.center)
            }
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
        }
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("people.invite.panel")
    }
}

/// Who an invite link is from, for the user to check before accepting:
/// "<address> invites you to be contacts", then From (the full address),
/// Journal, and the journal's key fingerprint grouped in fours.
public struct InvitePreviewDetails: View {
    let preview: ContactInvitePreview

    public init(preview: ContactInvitePreview) {
        self.preview = preview
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(preview.headline)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            row("From") {
                Text(preview.address)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("people.add.address")
            }
            row("Journal") {
                Text(preview.journal).textSelection(.enabled)
            }
            row("Fingerprint") {
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

    private func row<Value: View>(_ label: String, @ViewBuilder value: () -> Value) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            value()
        }
    }

    /// One character at a time, so VoiceOver reads it the way a person
    /// would read it out on a call.
    static func spokenFingerprint(_ grouped: String) -> String {
        grouped.split(separator: " ").map { $0.map(String.init).joined(separator: " ") }.joined(separator: ", ")
    }
}

/// One contact: the address (in full for someone on another journal), and
/// a second line when their key changed, their journal has stopped
/// answering, or the row isn't simply active.
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
            } else if let line = contact.unreachableLine {
                Label(line, systemImage: "wifi.exclamationmark")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
    public static let openLinkButton = "Open an invite link"
    public static let openInvites = "Open invites"
    public static let noContacts = "No contacts yet."
    public static let inviteFooter = "Make a link for someone on another Matron journal. When they open it and accept, you become contacts. Being contacts shares nothing by itself."
}
