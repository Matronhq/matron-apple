import SwiftUI
import UIKit
import MatronModels
import MatronDesignSystem
import MatronViewModels
import MatronJournal

/// Settings ▸ People (iOS): the user's contacts, with the full address of
/// anyone on another journal; "Invite someone on another Matron", which
/// mints a link and shows it once; the open invites, each with Withdraw;
/// and scanning or pasting someone else's invite link.
struct PeopleView: View {
    let api: any ContactsProviding
    @State private var model: PeopleViewModel
    @State private var scanning = false
    @State private var adding: AddContactViewModel?
    @State private var linkError: String?
    @State private var typingLink = false
    /// A scanned payload, opened once the scanner's cover has gone: a sheet
    /// presented while the cover is still dismissing is dropped.
    @State private var scanned: String?
    @State private var typedLink = ""

    init(api: any ContactsProviding) {
        self.api = api
        _model = State(initialValue: PeopleViewModel(api: api))
    }

    var body: some View {
        Form {
            MatronGroupedRows {
            if let error = model.errorMessage {
                Section {
                    Text(error).font(.callout).foregroundStyle(.red)
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
            inviteSection
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
        .navigationTitle("People")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .refreshable { await model.load() }
        .sheet(item: $model.minted) { minted in
            InviteLinkSheet(minted: minted)
        }
        .sheet(item: $adding) { addModel in
            AddContactSheet(model: addModel, onDone: { Task { await model.load() } })
        }
        .fullScreenCover(isPresented: $scanning, onDismiss: {
            if let payload = scanned { scanned = nil; open(payload) }
        }) {
            QRScannerView { payload in scanned = payload }
        }
        .alert(PeopleText.openLinkButton, isPresented: $typingLink) {
            TextField("https://…/contact#…", text: $typedLink)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) {}
            Button("Open") { open(typedLink) }
        } message: {
            Text("Paste the link they sent you.")
        }
        .alert("Not an invite link", isPresented: Binding(get: { linkError != nil }, set: { if !$0 { linkError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(linkError ?? "")
        }
    }

    @ViewBuilder private var inviteSection: some View {
        if model.federationOff {
            Section {
                Text(ContactInviteError.federationOff.localizedDescription)
                    .foregroundStyle(.secondary)
            }
        } else {
            Section {
                Button {
                    Task { await model.createInvite() }
                } label: {
                    HStack {
                        Label(PeopleText.inviteButton, systemImage: "link.badge.plus")
                        if model.isMinting { Spacer(); ProgressView() }
                    }
                }
                .disabled(model.isMinting)
                .accessibilityIdentifier("people.invite")
                Button {
                    typedLink = ""
                    typingLink = true
                } label: {
                    Label(PeopleText.openLinkButton, systemImage: "link")
                }
                .accessibilityIdentifier("people.open")
                Button {
                    scanning = true
                } label: {
                    Label("Scan an invite QR code", systemImage: "qrcode.viewfinder")
                }
            } footer: {
                Text(PeopleText.inviteFooter)
            }
        }
    }

    private func open(_ text: String) {
        guard let link = ContactInviteLink(text) else {
            linkError = ContactInviteError.badLink.localizedDescription
            return
        }
        adding = AddContactViewModel(link: link, api: api)
    }
}

/// The minted link, once, in its own sheet: closing it is the last this
/// device shows of it.
struct InviteLinkSheet: View {
    let minted: MintedInvite
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                InviteLinkPanel(minted: minted)
                    .padding(24)
            }
            .navigationTitle("Invite link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// The approved asks' links, each once. Only Done closes it, and Done is
/// the last this device shows of the links on screen when it was tapped.
struct ApprovedInviteLinksSheet: View {
    let shown: ShownInviteLinks
    var onClose: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let visible = shown.links.map(\.id)
        NavigationStack {
            ScrollView {
                InviteLinkList(links: shown.links)
                    .padding(24)
            }
            .navigationTitle(shown.links.count > 1 ? "Invite links" : "Invite link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { shown.acknowledge(visible); dismiss() }
                }
            }
        }
        // A swipe would close it without saying which links were seen.
        .interactiveDismissDisabled()
        .onDisappear(perform: onClose)
    }
}

/// "Contact invite": who the link is from, to check before
/// Accept. Cancel sends nothing.
struct AddContactSheet: View {
    @State var model: AddContactViewModel
    var onDone: () -> Void = {}
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                MatronGroupedRows {
                switch model.phase {
                case .opening:
                    Section {
                        HStack { ProgressView(); Text("Checking the link with \(model.link.host)…") }
                    }
                case .preview(let preview), .accepting(let preview):
                    Section {
                        InvitePreviewDetails(preview: preview)
                    }
                    if let error = model.acceptError {
                        Section { Text(error).foregroundStyle(.red) }
                    }
                case .accepted(let contact):
                    Section {
                        Text(contact.address).font(.headline)
                        Label(AddContactViewModel.acceptedText, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                case .refused(let message):
                    Section {
                        Label(message, systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("people.add.refused")
                    }
                }
                }
            }
            .navigationTitle(AddContactViewModel.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
        }
        // Once Accept is on its way it can't be called back: the sheet
        // stays until the journal answers, so Done can reload the list.
        .interactiveDismissDisabled(isAccepting)
        .task { await model.open() }
    }

    private var isAccepting: Bool {
        if case .accepting = model.phase { return true }
        return false
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        switch model.phase {
        case .accepted, .refused:
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { onDone(); dismiss() }
            }
        case .opening, .preview, .accepting:
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
                    .disabled(isAccepting)
            }
            ToolbarItem(placement: .confirmationAction) {
                if isAccepting {
                    ProgressView()
                } else {
                    Button("Accept") { Task { await model.accept() } }
                        .disabled(model.phase == .opening)
                        .accessibilityIdentifier("people.add.accept")
                }
            }
        }
    }
}

/// Shows the two People sheets that can arrive from anywhere: an invite
/// link opened from outside the app, and a link minted by Approve on an
/// agent's invite ask (which may answer from the outbox, after its screen
/// is gone). Presented from the topmost view controller, so a sheet that
/// is already up doesn't swallow them.
struct PeopleLinkPresenter: ViewModifier {
    let api: any ContactsProviding
    @State private var incoming = IncomingInviteLinks.shared
    @State private var minted = MintedInviteLinks.shared
    @State private var shown = ShownInviteLinks()
    @State private var sheetUp = false

    func body(content: Content) -> some View {
        content
            .onChange(of: incoming.pending, initial: true) { _, link in
                guard link != nil, let link = incoming.take() else { return }
                TopmostPresenter.present(AddContactSheet(model: AddContactViewModel(link: link, api: api)))
            }
            .onChange(of: minted.pending, initial: true) { _, _ in
                var arrived = false
                while let value = minted.take() { shown.add(value); arrived = true }
                if arrived { presentShownLinks() }
            }
    }

    /// Puts the links' sheet up unless it already is. UIKit refuses a
    /// presentation while another is mid-transition, so a refusal tries
    /// again shortly: the journal never returns these links twice.
    private func presentShownLinks(attempt: Int = 0) {
        guard !shown.links.isEmpty, !sheetUp else { return }
        sheetUp = TopmostPresenter.present(ApprovedInviteLinksSheet(shown: shown) {
            sheetUp = false
            presentShownLinks()
        })
        guard !sheetUp, attempt < 20 else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            presentShownLinks(attempt: attempt + 1)
        }
    }
}

enum TopmostPresenter {
    /// Whether UIKit took the presentation: it refuses one while `top` is
    /// mid-transition, and then never sets `presentedViewController`.
    @MainActor @discardableResult
    static func present<V: View>(_ view: V) -> Bool {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window = scenes.flatMap(\.windows).first { $0.isKeyWindow }
            ?? scenes.flatMap(\.windows).first
        guard var top = window?.rootViewController else { return false }
        while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
        let host = UIHostingController(rootView: view)
        top.present(host, animated: true)
        return top.presentedViewController === host
    }
}
