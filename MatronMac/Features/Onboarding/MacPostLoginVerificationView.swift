#if os(macOS)
import SwiftUI
import MatronModels
import MatronStorage
import MatronVerification
import MatronViewModels

/// Mac analogue of `PostLoginVerificationView` (spec §5.2). Same shape as
/// the iOS gate; the navigation destinations build the Mac-specific
/// `MacRecoveryKeyView` / `MacSasView` surfaces. See the iOS view for the
/// per-branch rationale.
struct MacPostLoginVerificationView: View {
    enum Path: Hashable {
        case generate
        case sasWithOtherDevice
        case restoreWithRecoveryKey
    }

    let dependencies: AppDependencies
    let session: UserSession
    let onCompleted: () -> Void

    @State private var path: [Path] = []

    /// Per-user `UserDefaults` key — same shape as the iOS gate so a
    /// future shared-default migration (Phase 7) doesn't have to reconcile
    /// two differently-named keys. See `PostLoginVerificationView`.
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
                    Label("Verify with another device", systemImage: "laptopcomputer")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.return)

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
            .padding(32)
            .frame(width: 480, height: 400)
            .navigationDestination(for: Path.self) { destination in
                switch destination {
                case .generate:
                    let mgr = RecoveryKeyManager(
                        provider: dependencies.clientProvider,
                        session: session,
                        keychain: KeychainStore(service: "chat.matron.recovery", synchronizable: true)
                    )
                    MacRecoveryKeyView(
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
                    MacRecoveryKeyView(
                        viewModel: RecoveryKeyViewModel(
                            mode: .restore,
                            generate: { "" },
                            restore: { try await mgr.restore(usingKey: $0) }
                        ),
                        onFinished: onCompleted
                    )
                case .sasWithOtherDevice:
                    let svc = VerificationServiceLive(
                        provider: dependencies.clientProvider,
                        session: session
                    )
                    // Same self-verification cache-key choice as iOS — the
                    // FlowStore entry registered by `startSAS` is keyed by
                    // userID, so confirm/cancel must use the same key.
                    let requestID = session.userID
                    let stream = svc.startSAS(withUser: session.userID, deviceID: nil)
                    MacSasView(
                        viewModel: SasViewModel(
                            stream: stream,
                            requestID: requestID,
                            confirm: { try await svc.confirmEmojiMatch(requestID: requestID) },
                            cancel: { reason in try await svc.cancel(requestID: requestID, reason: reason) }
                        ),
                        title: "Verify this device",
                        onFinished: onCompleted
                    )
                }
            }
        }
    }
}
#endif
