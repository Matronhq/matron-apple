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
                    // B2/M5 expert-QA fix mirroring iOS — hand
                    // construction to `MacSelfVerifySasDestination` so
                    // the SasViewModel + stream survive parent
                    // re-renders. See iOS `PostLoginVerificationView`
                    // for full rationale.
                    MacSelfVerifySasDestination(
                        service: dependencies.verificationService(for: session),
                        userID: session.userID,
                        onFinished: onCompleted
                    )
                }
            }
        }
    }
}

/// Mac self-verify SAS navigation destination. Owns the `SasViewModel`
/// + stream as `@State` so they're built exactly once per push.
/// Mirrors iOS `SelfVerifySasDestination`. See iOS view for the
/// B2/M5 expert-QA rationale.
private struct MacSelfVerifySasDestination: View {
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
        MacSasView(
            viewModel: viewModel,
            title: "Verify this device",
            onFinished: onFinished
        )
    }
}
#endif
