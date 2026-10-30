import Foundation
import Observation
import MatronJournal

/// Settings → Security as a whole: the Email address, Password and
/// two-factor rows' models, and the one sheet the section has open.
///
/// The section's sheets are presented from a single `.sheet(item:)` on the
/// settings form, never from the rows: a modifier on a `Section` (or on a
/// `Group` around it) is applied to each of its rows, so a section-level
/// sheet sat on the same rows as the rows' own sheets and only one of them
/// ever presented.
@Observable @MainActor
public final class SecuritySettingsModel {
    /// The sheet on screen.
    public enum Sheet: Hashable, Identifiable, Sendable {
        case email
        case password
        case twoFactor(TwoFactorSettingsModel.Action)

        public var id: String {
            switch self {
            case .email: "email"
            case .password: "password"
            case .twoFactor(let action): "twoFactor.\(action.rawValue)"
            }
        }
    }

    public let twoFactor: TwoFactorSettingsModel
    /// nil leaves the Email address row out.
    public let email: AccountEmailModel?
    /// nil leaves the Password row out.
    public let password: ChangePasswordModel?

    /// Bound to the form's `.sheet(item:)`.
    public var sheet: Sheet?
    /// The sheet last opened, for `sheetClosed()`: by the time the
    /// presentation's dismiss handler runs, `sheet` is already nil.
    private var opened: Sheet?

    public init(twoFactorAPI: any TwoFactorSettingsProviding, passwordAPI: (any PasswordChanging)? = nil,
                emailAPI: (any AccountEmailProviding)? = nil) {
        twoFactor = TwoFactorSettingsModel(api: twoFactorAPI)
        password = passwordAPI.map { ChangePasswordModel(api: $0) }
        email = emailAPI.map { AccountEmailModel(api: $0) }
    }

    /// Whether Settings shows the Security section at all. The Password
    /// row keeps it up on a journal without two-factor.
    public var isShown: Bool {
        twoFactor.isShown || password != nil || email != nil
    }

    /// Reads the email address and the two-factor status side by side.
    public func refresh() async {
        async let status: Void = twoFactor.refresh()
        if let email { await email.refresh() }
        await status
    }

    /// Opens `sheet` with a fresh form.
    public func open(_ sheet: Sheet) {
        switch sheet {
        case .email: email?.beginEdit()
        case .password: password?.begin()
        case .twoFactor: break
        }
        opened = sheet
        self.sheet = sheet
    }

    /// Closes the open sheet (its Cancel, or done).
    public func close() {
        sheet = nil
    }

    /// The sheet has gone, however it went: clear what was typed into it,
    /// and re-read the two-factor status a two-factor sheet may have changed.
    public func sheetClosed() async {
        let closed = opened
        opened = nil
        switch closed {
        case .email: email?.endEdit()
        case .password: password?.end()
        case .twoFactor: await twoFactor.refresh()
        case nil: break
        }
    }
}
