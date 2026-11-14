import Foundation
import SwiftUI
import MatronAuth
import MatronJournal
import MatronModels
import MatronViewModels
#if os(iOS)
import UIKit
#endif

extension AppDependencies {
    /// Gives a session its approval centre: the account's approval keys,
    /// this device's own, and the confirm sheet that signing goes through.
    /// Called once, when the session's journal stack is built, so the API
    /// client has its signer before any account action is sent.
    func installApprovals(on core: JournalCore, session: UserSession, directory: URL) {
        let host = session.homeserverURL.host ?? session.homeserverURL.absoluteString
        let center = ApprovalCenter(
            api: core.api, keys: Self.approvalKeyProvider(),
            store: ApprovalKeyStore.live(directory: directory, host: host, user: session.userID),
            user: session.userID, deviceID: Int64(session.deviceID), deviceName: Self.approvalKeyName)
        core.approvals = center
        core.approvalPresenter = ApprovalPromptPresenter(center: center)
        let signer = center.signer
        let api = core.api
        Task {
            await api.setApprovalSigner(signer)
            // After every sign-in and launch: is this device's key still
            // attached to this sign-in? The keys screen and the Settings
            // row say so when it is not.
            await center.refresh()
        }
    }

    /// The session's approval centre.
    func approvals(for session: UserSession) -> ApprovalCenter {
        let core = core(for: session)
        if let center = core.approvals { return center }
        // `core(for:)` installs it; this is only reached by a core built
        // some other way (a test).
        installApprovals(on: core, session: session, directory: FileManager.default.temporaryDirectory)
        return core.approvals!
    }

    /// Signs what needs an approval key, after showing it to the user.
    func approvalSigner(for session: UserSession) -> ApprovalSigner {
        approvals(for: session).signer
    }

    /// Answers consent cards, signing the ones aimed at a protected box.
    func signingConsentService(for session: UserSession) -> SigningConsentService {
        SigningConsentService(api: core(for: session).api, signer: approvalSigner(for: session))
    }

    /// The Secure Enclave, always, in a shipped app. A Debug build can be
    /// told to use a key in memory instead, for the Simulator (which has
    /// no Secure Enclave) and for screenshot runs.
    static func approvalKeyProvider() -> any ApprovalKeyProviding {
        #if DEBUG
        if ProcessInfo.processInfo.environment["MATRON_DEBUG_SOFTWARE_APPROVAL_KEY"] != nil {
            #if os(macOS)
            return SoftwareKeyProvider(method: "Touch ID")
            #else
            return SoftwareKeyProvider(method: "Face ID")
            #endif
        }
        #endif
        return SecureEnclaveKeyProvider()
    }

    /// Whether the journal says the account is locked (HTTP 423). One for
    /// the app: there is one signed-in account at a time.
    var accountLock: AccountLockMonitor { AccountLockMonitorHolder.shared }

    /// What this device's key is called on the account.
    static var approvalKeyName: String {
        #if os(iOS)
        return UIDevice.current.name
        #else
        return Host.current().localizedName ?? "Mac"
        #endif
    }
}

@MainActor
enum AccountLockMonitorHolder {
    static let shared = AccountLockMonitor()
}

/// Puts "This account is locked" across the top of a root view while the
/// journal says so.
struct AccountLockedBannerModifier: ViewModifier {
    let monitor: AccountLockMonitor

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .top, spacing: 0) {
            if monitor.isLocked {
                AccountLockedBanner()
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.default, value: monitor.isLocked)
    }
}

extension View {
    func accountLockedBanner(_ monitor: AccountLockMonitor) -> some View {
        modifier(AccountLockedBannerModifier(monitor: monitor))
    }
}
