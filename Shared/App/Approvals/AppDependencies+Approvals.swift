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
            user: session.userID, deviceID: Int64(session.deviceID), deviceName: Self.approvalKeyName,
            journalHost: Self.journalHost(session.homeserverURL))
        core.approvals = center
        core.approvalPresenter = ApprovalPromptPresenter(center: center)
        // Replies held while the account was locked go once it is cleared.
        accountLock.whenCleared { [weak core] in
            guard let items = core?.items else { return }
            Task { await items.drainOutbox() }
        }
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

    /// The journal as a statement names it: the server's host, lowercased,
    /// with a port that is not the scheme's default.
    static func journalHost(_ url: URL) -> String? {
        guard let host = url.host?.lowercased(), !host.isEmpty else { return nil }
        guard let port = url.port else { return host }
        let standard = url.scheme?.lowercased() == "http" ? 80 : 443
        return port == standard ? host : "\(host):\(port)"
    }

    /// Unlocking the account from this device, when the lock froze it.
    func accountUnlock(for session: UserSession) -> AccountUnlockModel {
        let core = core(for: session)
        let center = approvals(for: session)
        return AccountUnlockModel(
            monitor: accountLock, api: core.api,
            sign: { since in try await center.signUnlock(since: since) },
            adoptToken: { [weak self] token in try await self?.adoptToken(token, for: session) },
            pending: Self.pendingUnlock(for: session))
    }

    static func pendingUnlock(for session: UserSession) -> PendingUnlockStore {
        PendingUnlockStore(user: session.userID, host: session.homeserverURL.host ?? session.homeserverURL.absoluteString)
    }

    /// The journal gave this device a new token (it unlocked the account):
    /// saved first, then every client of this session uses it. The old
    /// socket and requests still out with the old token are dropped.
    func adoptToken(_ token: String, for session: UserSession) async throws {
        let core = core(for: session)
        let saved: Error?
        do {
            try auth.persist(UserSession(userID: session.userID, deviceID: session.deviceID,
                                         homeserverURL: session.homeserverURL, accessToken: token))
            saved = nil
        } catch {
            saved = error
        }
        await core.api.replaceToken(token)
        await core.engine.replaceToken(token)
        if let saved { throw saved }
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
/// journal says so. When the lock froze this device (it can unlock), the
/// locked screen covers the app instead, with its Unlock button.
struct AccountLockedBannerModifier: ViewModifier {
    let monitor: AccountLockMonitor
    let makeUnlock: (() -> AccountUnlockModel)?
    let method: String

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                if monitor.isLocked && !(monitor.canUnlock && makeUnlock != nil) {
                    AccountLockedBanner()
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .overlay {
                if monitor.canUnlock, let makeUnlock {
                    AccountLockedScreenHost(monitor: monitor, makeUnlock: makeUnlock, method: method)
                        .transition(.opacity)
                }
            }
            .animation(.default, value: monitor.isLocked)
            .animation(.default, value: monitor.canUnlock)
    }
}

/// Holds the unlock model for as long as the locked screen is up.
private struct AccountLockedScreenHost: View {
    let monitor: AccountLockMonitor
    let makeUnlock: () -> AccountUnlockModel
    let method: String
    @State private var model: AccountUnlockModel?

    var body: some View {
        Group {
            if let model {
                AccountLockedScreen(since: monitor.lock?.since, method: method,
                                    isUnlocking: model.isUnlocking, error: model.errorText) {
                    Task { await model.unlock() }
                }
            } else {
                AccountLockedScreen(since: monitor.lock?.since, method: method, isUnlocking: false, error: nil) {}
            }
        }
        .onAppear { if model == nil { model = makeUnlock() } }
    }
}

extension View {
    func accountLockedBanner(_ monitor: AccountLockMonitor) -> some View {
        modifier(AccountLockedBannerModifier(monitor: monitor, makeUnlock: nil, method: "Face ID"))
    }

    /// The banner, and the locked screen with Unlock for a frozen device.
    func accountLocked(_ dependencies: AppDependencies, session: UserSession) -> some View {
        let center = dependencies.approvals(for: session)
        return modifier(AccountLockedBannerModifier(
            monitor: dependencies.accountLock,
            makeUnlock: { dependencies.accountUnlock(for: session) },
            method: center.method ?? AppDependencies.defaultApprovalMethod))
    }
}

extension AppDependencies {
    static var defaultApprovalMethod: String {
        #if os(macOS)
        return "Touch ID"
        #else
        return "Face ID"
        #endif
    }
}
