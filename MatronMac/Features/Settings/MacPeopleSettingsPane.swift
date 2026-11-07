#if os(macOS)
import SwiftUI
import AppKit
import MatronModels
import MatronDesignSystem
import MatronViewModels
import MatronJournal

/// Settings → People: the user's contacts, with the full address of anyone
/// on another journal; "Invite someone on another Matron", which mints a
/// link and shows it once; the open invites, each with Withdraw; and
/// opening someone else's invite link by pasting it. Same sections as iOS
/// `PeopleView`.
struct MacPeopleSettingsPane: View {
    let api: any ContactsProviding
    @State private var model: PeopleViewModel
    @State private var adding: AddContactViewModel?
    @State private var pasted = ""
    @State private var linkError: String?

    init(api: any ContactsProviding) {
        self.api = api
        _model = State(initialValue: PeopleViewModel(api: api))
    }

    var body: some View {
        Form {
            if let error = model.errorMessage {
                Section {
                    Text(error).foregroundStyle(.red)
                }
            }
            Section("Contacts") {
                if model.contacts.isEmpty {
                    Text(model.isLoading ? "Loading…" : PeopleText.noContacts)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.contacts) { ContactRow(contact: $0) }
                }
            }
            if model.federationOff {
                Section {
                    Text(ContactInviteError.federationOff.localizedDescription)
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    HStack {
                        Button(PeopleText.inviteButton) {
                            Task { await model.createInvite() }
                        }
                        .disabled(model.isMinting)
                        .accessibilityIdentifier("people.invite")
                        if model.isMinting { ProgressView().controlSize(.small) }
                    }
                    HStack {
                        TextField("Paste the link they sent you", text: $pasted)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(openPasted)
                        Button(PeopleText.openLinkButton, action: openPasted)
                            .disabled(pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    if let linkError {
                        Text(linkError).font(.footnote).foregroundStyle(.red)
                    }
                } footer: {
                    Text(PeopleText.inviteFooter)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if !model.openInvites.isEmpty {
                    Section(PeopleText.openInvites) {
                        ForEach(model.openInvites) { invite in
                            OpenInviteRow(invite: invite, isWithdrawing: model.withdrawing.contains(invite.id)) {
                                Task { await model.withdraw(invite) }
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { await model.load() }
        .sheet(item: $model.minted) { minted in
            MacInviteLinkSheet(minted: minted)
        }
        .sheet(item: $adding) { addModel in
            MacAddContactSheet(model: addModel, onDone: { Task { await model.load() } })
        }
        .frame(width: MacSettingsLayout.paneWidth, height: 560)
    }

    private func openPasted() {
        guard let link = ContactInviteLink(pasted) else {
            linkError = ContactInviteError.badLink.localizedDescription
            return
        }
        linkError = nil
        pasted = ""
        adding = AddContactViewModel(link: link, api: api)
    }
}

/// The minted link, once: closing the sheet is the last this Mac shows of it.
struct MacInviteLinkSheet: View {
    let minted: MintedInvite
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("Invite link").font(.headline)
            InviteLinkPanel(minted: minted)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 400)
    }
}

/// "Contact invite": who the link is from, to check before
/// Accept. Cancel sends nothing.
struct MacAddContactSheet: View {
    @State var model: AddContactViewModel
    var onDone: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(AddContactViewModel.title).font(.headline)
            content
            HStack {
                Spacer()
                buttons
            }
        }
        .padding(24)
        .frame(width: 440)
        // Once Accept is on its way it can't be called back: the sheet
        // stays until the journal answers, so Done can reload the list.
        .interactiveDismissDisabled(isAccepting)
        .task { await model.open() }
    }

    private var isAccepting: Bool {
        if case .accepting = model.phase { return true }
        return false
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .opening:
            HStack { ProgressView().controlSize(.small); Text("Checking the link with \(model.link.host)…") }
        case .preview(let preview), .accepting(let preview):
            InvitePreviewDetails(preview: preview)
            if let error = model.acceptError {
                Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        case .accepted(let contact):
            Text(contact.address).font(.title3.weight(.semibold))
            Label(AddContactViewModel.acceptedText, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .refused(let message):
            Label(message, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("people.add.refused")
        }
    }

    @ViewBuilder private var buttons: some View {
        switch model.phase {
        case .accepted, .refused:
            Button("Done") { onDone(); dismiss() }
                .keyboardShortcut(.defaultAction)
        case .opening, .preview, .accepting:
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(isAccepting)
            if isAccepting {
                ProgressView().controlSize(.small)
            } else {
                Button("Accept") { Task { await model.accept() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.phase == .opening)
                    .accessibilityIdentifier("people.add.accept")
            }
        }
    }
}

/// Shows the People sheets that can arrive from anywhere in a signed-in
/// window: an invite link opened from outside the app, and a link minted by
/// Approve on an agent's invite ask (which may answer from the outbox,
/// after its screen is gone). The first window to see one takes it.
struct MacPeopleLinkPresenter: ViewModifier {
    let api: (any ContactsProviding)?
    @State private var incoming = IncomingInviteLinks.shared
    @State private var minted = MintedInviteLinks.shared
    @State private var adding: AddContactViewModel?
    @State private var showing: MintedInvite?

    func body(content: Content) -> some View {
        content
            .onChange(of: incoming.pending, initial: true) { _, link in
                guard link != nil, let api, let link = incoming.take() else { return }
                adding = AddContactViewModel(link: link, api: api)
            }
            .onChange(of: minted.pending, initial: true) { _, _ in showNextMinted() }
            .sheet(item: $adding) { MacAddContactSheet(model: $0) }
            .sheet(item: $showing, onDismiss: showNextMinted) { MacInviteLinkSheet(minted: $0) }
    }

    /// One link at a time: the next waits until this sheet closes.
    private func showNextMinted() {
        guard showing == nil, api != nil, let value = minted.take() else { return }
        showing = value
    }
}
#endif
