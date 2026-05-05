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
/// only fires once per `(app, user)` pair — multi-account scoping via
/// `UserSession.verifyDoneKey`.
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
                .accessibilityIdentifier("verifygate.verifyWithOtherDevice")

                Button {
                    path.append(.restoreWithRecoveryKey)
                } label: {
                    Label("Use recovery key", systemImage: "key")
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("verifygate.useRecoveryKey")

                Button("This is my first device — generate a key") {
                    path.append(.generate)
                }
                // Was a plain-text button. iOS 26 Simulator XCUITest tap on
                // ~20pt-tall plain-text Buttons doesn't reliably trigger
                // the action, leaving the gate stuck. `.bordered` gives a
                // clear hit target without changing the destination flow.
                .buttonStyle(.bordered)
                .padding(.top, 8)
                .accessibilityIdentifier("verifygate.generateNew")
            }
            .padding()
            .navigationDestination(for: Path.self) { destination in
                switch destination {
                case .generate:
                    let mgr = RecoveryKeyManager(
                        provider: dependencies.clientProvider,
                        session: session,
                        keychain: KeychainStore.recoveryStore()
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
                        keychain: KeychainStore.recoveryStore()
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
                    // B2/M5 expert-QA fix: hand construction to the
                    // generic `SasSheetWrapper` that owns the
                    // `SasViewModel` in `@State`. Inline construction
                    // here re-built the VM + reopened a fresh
                    // `startSAS` stream on every parent re-render
                    // (`@State path: [Path]` on this view changes per
                    // navigation), so partner-side SAS state transitions
                    // could reach an orphaned VM whose continuation the
                    // visible destination was no longer observing.
                    SasSheetWrapper(
                        service: dependencies.verificationService(for: session),
                        requestID: session.userID,
                        title: "Verify this device",
                        streamFactory: { $0.startSAS(withUser: session.userID, deviceID: nil) },
                        onFinished: onCompleted,
                        onCancelled: { path.removeLast() }
                    )
                }
            }
        }
    }
}

