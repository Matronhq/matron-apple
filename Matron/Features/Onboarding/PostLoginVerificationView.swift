import SwiftUI
import MatronModels
import MatronStorage
import MatronVerification
import MatronViewModels

/// Onboarding step 2 (spec §5.2). Sign-in landed in Phase 1; this view is
/// the gate that runs once after sign-in and lets the user pick how to
/// secure encryption on this device:
///
///   * **Verify with another device** — runs the SAS emoji-compare flow
///     against an already-trusted device the user has signed into. Lands
///     in `SasView`.
///   * **Use recovery key** — additional-device path. User pastes the
///     recovery key generated on a prior device; we feed it back into the
///     SDK to unlock backup + cross-signing. Lands in `RecoveryKeyView`
///     (`.restore` mode).
///   * **First device — generate a key** — first-device path. SDK
///     generates a fresh recovery key; the view shows it once with a
///     mandatory acknowledgement + re-entry confirmation. Lands in
///     `RecoveryKeyView` (`.generate` mode).
///
/// Once the user finishes any of those flows, `onCompleted()` flips the
/// `verifyDone` flag in the host (`MatronApp`) so the chat list is
/// reachable. The flag is also persisted in `UserDefaults` so the gate
/// only fires once per `(app, user)` pair — multi-account scoping uses
/// `verifyDoneKey(for:)`.
///
/// The view itself owns no SDK state. Each `navigationDestination` builds
/// the right manager / service inline using the injected `dependencies`
/// and `session`, so the view can be exercised in tests without standing
/// up a fake stack.
struct PostLoginVerificationView: View {
    /// Navigation destinations driven by the three primary buttons. Hashable
    /// because `NavigationStack(path:)` requires the path element to be
    /// hashable for stable identity across renders.
    enum Path: Hashable {
        case generate
        case sasWithOtherDevice
        case restoreWithRecoveryKey
    }

    let dependencies: AppDependencies
    let session: UserSession
    let onCompleted: () -> Void

    @State private var path: [Path] = []

    /// Per-user `UserDefaults` key for the persisted "this user has
    /// completed the post-login verification gate" flag. Scoped by
    /// `userID` so signing into a second account on the same device
    /// re-runs the gate for that account. Exposed `internal` so the test
    /// suite can lock the key shape — a future rename without test
    /// coverage would silently leave gated users perpetually staring at
    /// this screen.
    static func verifyDoneKey(for session: UserSession) -> String {
        "matron.verify-done.\(session.userID)"
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 16) {
                Image(systemName: "lock.shield")
                    .font(.system(size: 60))
                    .foregroundStyle(.tint)
                Text("Secure this device")
                    .font(.title2)
                    .bold()
                Text("Choose how to set up encryption for this device.")
                    .multilineTextAlignment(.center)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                Button {
                    path.append(.sasWithOtherDevice)
                } label: {
                    Label("Verify with another device", systemImage: "iphone")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    path.append(.restoreWithRecoveryKey)
                } label: {
                    Label("Use recovery key", systemImage: "key")
                }
                .buttonStyle(.bordered)

                Button("This is my first device — generate a key") {
                    path.append(.generate)
                }
                .padding(.top, 8)
            }
            .padding()
            .navigationDestination(for: Path.self) { destination in
                switch destination {
                case .generate:
                    let mgr = RecoveryKeyManager(
                        provider: dependencies.clientProvider,
                        session: session,
                        keychain: KeychainStore(service: "chat.matron.recovery", synchronizable: true)
                    )
                    RecoveryKeyView(
                        viewModel: RecoveryKeyViewModel(
                            mode: .generate,
                            generate: { try await mgr.generateAndPersist() },
                            restore: { _ in }
                        ),
                        onFinished: onCompleted
                    )
                case .restoreWithRecoveryKey:
                    let mgr = RecoveryKeyManager(
                        provider: dependencies.clientProvider,
                        session: session,
                        keychain: KeychainStore(service: "chat.matron.recovery", synchronizable: true)
                    )
                    RecoveryKeyView(
                        viewModel: RecoveryKeyViewModel(
                            mode: .restore,
                            generate: { "" },
                            restore: { try await mgr.restore(usingKey: $0) }
                        ),
                        onFinished: onCompleted
                    )
                case .sasWithOtherDevice:
                    // B2/M5 expert-QA fix: hand construction to a
                    // dedicated `SelfVerifySasDestination` that owns
                    // the `SasViewModel` in `@State`. Inline construction
                    // here re-built the VM + reopened a fresh
                    // `startSAS` stream on every parent re-render
                    // (`@State path: [Path]` on this view changes per
                    // navigation), so partner-side SAS state transitions
                    // could reach an orphaned VM whose continuation the
                    // visible destination was no longer observing.
                    SelfVerifySasDestination(
                        service: dependencies.verificationService(for: session),
                        userID: session.userID,
                        onFinished: onCompleted
                    )
                }
            }
        }
    }
}

/// Self-verify SAS navigation destination. Owns the `SasViewModel` +
/// stream as `@State` so they're built exactly once per push, surviving
/// the parent's body re-renders (B2/M5 expert-QA fix). Cache key is
/// `session.userID` — that's the FlowStore key
/// `VerificationServiceLive.startSAS` registers under for self-
/// verification flows, so confirm/cancel hit the same entry.
///
/// `service` is captured in `init` and used to construct the VM's
/// closures; `@State` is seeded once per view-identity, so
/// SwiftUI ignores subsequent `init` calls' `_viewModel` initial
/// values during re-renders. That's the load-bearing SwiftUI
/// behaviour the M5 fix relies on.
private struct SelfVerifySasDestination: View {
    @State private var viewModel: SasViewModel
    private let onFinished: () -> Void

    init(service: VerificationService, userID: String, onFinished: @escaping () -> Void) {
        self.onFinished = onFinished
        let stream = service.startSAS(withUser: userID, deviceID: nil)
        _viewModel = State(initialValue: SasViewModel(
            stream: stream,
            requestID: userID,
            confirm: { try await service.confirmEmojiMatch(requestID: userID) },
            cancel: { reason in try await service.cancel(requestID: userID, reason: reason) }
        ))
    }

    var body: some View {
        SasView(
            viewModel: viewModel,
            title: "Verify this device",
            onFinished: onFinished
        )
    }
}
