import Foundation
import Observation
import MatronJournal

/// Settings → Security → Email address: the address a password-reset link
/// goes to (`GET /account/email`), and the Edit form that changes or
/// removes it (`PUT /account/email`, which needs the current password).
/// A journal predating account email 404s the read and the row hides.
/// The password lives only in this model and is cleared once the journal
/// has answered.
@Observable @MainActor
public final class AccountEmailModel {
    public enum Phase: Equatable {
        case loading
        case loaded(AccountEmail)
        /// The journal has no `/account/email`: the row is not offered.
        case unsupported
        case failed(String)
    }

    /// The words, in one place so the iPhone and the Mac say the same thing.
    public static let title = "Email address"
    public static let notSet = "Not set"
    public static let editTitle = "Edit"
    public static let fieldLabel = "Email address"
    public static let passwordLabel = "Current password"
    public static let saveTitle = "Save"
    public static let removeTitle = "Remove"
    public static let help = "Used to reset your password if you forget it."
    public static let cannotSendNote = "This journal can't send email yet."

    public private(set) var phase: Phase = .loading
    /// The Edit form's fields.
    public var email = ""
    public var password = ""
    public private(set) var isSaving = false
    /// What went wrong, shown on the form.
    public private(set) var errorMessage: String?

    private let api: any AccountEmailProviding

    public init(api: any AccountEmailProviding) {
        self.api = api
    }

    /// Whether Settings shows the row at all.
    public var isShown: Bool { phase != .unsupported }

    private var account: AccountEmail? {
        if case .loaded(let account) = phase { return account }
        return nil
    }

    /// Whether an address is on file (and so "Remove" is offered).
    public var hasEmail: Bool { account?.email != nil }

    /// The address, or "Not set"; nil while there is nothing to say.
    public var valueText: String? {
        guard let account else { return nil }
        return account.email ?? Self.notSet
    }

    /// The line under the row.
    public var helpText: String {
        switch phase {
        case .loaded(let account) where !account.resetByEmail:
            return "\(Self.help) \(Self.cannotSendNote)"
        case .failed(let message):
            return message
        default:
            return Self.help
        }
    }

    /// Edit is only offered once the address on file is known.
    public var canEdit: Bool { account != nil }

    private var trimmedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }

    public var canSave: Bool { !isSaving && !trimmedEmail.isEmpty && !password.isEmpty }
    public var canRemove: Bool { !isSaving && hasEmail && !password.isEmpty }

    public func refresh() async {
        do {
            phase = .loaded(try await api.accountEmail())
        } catch JournalAPIError.notFound {
            phase = .unsupported
        } catch {
            // Keep an address already shown over a transient failure.
            if case .loaded = phase { return }
            phase = .failed("Couldn't load your email address.")
        }
    }

    /// "Edit": the form starts from the address on file.
    public func beginEdit() {
        email = account?.email ?? ""
        password = ""
        errorMessage = nil
    }

    /// The form closed (cancelled or saved): drop the password.
    public func endEdit() {
        password = ""
        errorMessage = nil
    }

    /// "Save". Returns true once stored, so the form can close.
    @discardableResult
    public func save() async -> Bool {
        guard canSave else { return false }
        return await send(trimmedEmail)
    }

    /// "Remove", only while an address is on file. Returns true once done.
    @discardableResult
    public func remove() async -> Bool {
        guard canRemove else { return false }
        return await send(nil)
    }

    private func send(_ newEmail: String?) async -> Bool {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            let stored = try await api.setAccountEmail(password: password, email: newEmail)
            password = ""
            if let account {
                phase = .loaded(AccountEmail(email: stored, resetByEmail: account.resetByEmail))
            }
            return true
        } catch {
            password = ""
            errorMessage = ChangePasswordModel.message(for: error)
            return false
        }
    }
}
