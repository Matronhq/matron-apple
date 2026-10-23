import Foundation
import Observation
import MatronJournal

/// Settings → Security → Password: the change-password form's fields, the
/// checks made before anything is sent, and the outcome (`POST /password`).
/// The passwords live only in this model. A change clears them all; a
/// refusal clears only the current password, which is typed again, and
/// keeps the new one.
@Observable @MainActor
public final class ChangePasswordModel {
    /// The words, in one place so the iPhone and the Mac say the same thing.
    /// Button and sheet titles take title case, as both platforms' buttons do.
    public static let rowTitle = "Password"
    public static let rowHelp = "Used to sign in on a new device."
    public static let title = "Change Password"
    public static let currentLabel = "Current password"
    public static let newLabel = "New password"
    public static let confirmLabel = "Confirm new password"
    public static let signOutOthersLabel = "Sign out of my other devices"
    public static let signOutOthersHelp = "Your agent boxes stay connected."
    /// The journal's own floor for a new password.
    public static let minimumLength = 8

    public var currentPassword = ""
    public var newPassword = ""
    public var confirmPassword = ""
    public var signOutOthers = true
    public private(set) var isSubmitting = false
    /// What went wrong, shown under the form.
    public private(set) var errorMessage: String?
    /// "Password changed." and how many devices were signed out, shown on
    /// the Password row once the form has closed.
    public private(set) var successMessage: String?

    private let api: any PasswordChanging

    public init(api: any PasswordChanging) {
        self.api = api
    }

    /// The primary button: off while sending or while any field is empty.
    public var canSubmit: Bool {
        !isSubmitting && !currentPassword.isEmpty && !newPassword.isEmpty && !confirmPassword.isEmpty
    }

    /// The first check the fields fail, or nil when they are fit to send.
    public var validationError: String? {
        if newPassword.count < Self.minimumLength { return "Use at least \(Self.minimumLength) characters." }
        if newPassword != confirmPassword { return "The new passwords don't match." }
        if newPassword == currentPassword { return "Choose a password different from your current one." }
        return nil
    }

    /// A fresh form: empty fields, the toggle back on, no messages. Called
    /// each time the form opens.
    public func begin() {
        clearPasswords()
        signOutOthers = true
        errorMessage = nil
        successMessage = nil
    }

    /// The form closed (cancelled or done): drop anything typed into it.
    /// A success message stays for Settings to show.
    public func end() {
        clearPasswords()
        errorMessage = nil
    }

    /// Checks the fields, then sends them. Returns true once the password
    /// has changed, so the form can close; on false, `errorMessage` says
    /// why and the form stays open.
    @discardableResult
    public func submit() async -> Bool {
        guard canSubmit else { return false }
        if let problem = validationError {
            errorMessage = problem
            return false
        }
        isSubmitting = true
        errorMessage = nil
        successMessage = nil
        defer { isSubmitting = false }
        do {
            let result = try await api.changePassword(oldPassword: currentPassword, newPassword: newPassword,
                                                      signOutOthers: signOutOthers)
            clearPasswords()
            successMessage = Self.successText(signedOut: result.signedOut)
            return true
        } catch {
            errorMessage = Self.message(for: error)
            // Whatever went wrong, the current password is typed again;
            // the new one stays.
            currentPassword = ""
            return false
        }
    }

    /// "Password changed." and, when other devices were signed out, how many.
    public static func successText(signedOut: Int) -> String {
        switch signedOut {
        case ...0: return "Password changed."
        case 1: return "Password changed. Signed out of 1 other device."
        default: return "Password changed. Signed out of \(signedOut) other devices."
        }
    }

    /// The line the form shows for a failure.
    public static func message(for error: Error) -> String {
        if case JournalAPIError.lockedOut(let seconds) = error {
            let minutes = max(1, (seconds + 59) / 60)
            return "Too many attempts. Try again in \(minutes) \(minutes == 1 ? "minute" : "minutes")."
        }
        return error.localizedDescription
    }

    private func clearPasswords() {
        currentPassword = ""
        newPassword = ""
        confirmPassword = ""
    }
}
