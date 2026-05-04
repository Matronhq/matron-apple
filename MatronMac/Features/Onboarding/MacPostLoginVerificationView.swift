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
                .padding(.top, 8)
                .accessibilityIdentifier("verifygate.generateNew")
            }
            .padding(32)
            .frame(width: 480, height: 400)
            .navigationDestination(for: Path.self) { destination in
                switch destination {
                case .generate:
                    let mgr = RecoveryKeyManager(
                        provider: dependencies.clientProvider,
                        session: session,
                        keychain: KeychainStore.recoveryStore()
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
                        keychain: KeychainStore.recoveryStore()
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

/// Mac self-verify SAS navigation destination. Mirrors iOS
/// `SelfVerifySasDestination` — see iOS `ChatView.swift`'s
/// `VerifyBotSheet` for the Wave 5 bugbot #2 rationale (the prior
/// `init`-side `startSAS` call fired on every parent body re-render
/// and silently cancelled the active continuation via Wave 2 / M3's
/// "Replaced by new flow" drain).
private struct MacSelfVerifySasDestination: View {
    let service: VerificationService
    let userID: String
    let onFinished: () -> Void

    @State private var viewModel: SasViewModel?

    var body: some View {
        Group {
            if let vm = viewModel {
                MacSasView(
                    viewModel: vm,
                    title: "Verify this device",
                    onFinished: onFinished
                )
            } else {
                ProgressView("Starting verification…")
            }
        }
        .task(id: userID) {
            guard viewModel == nil else { return }
            let stream = service.startSAS(withUser: userID, deviceID: nil)
            viewModel = SasViewModel(
                stream: stream,
                requestID: userID,
                confirm: { try await service.confirmEmojiMatch(requestID: userID) },
                cancel: { reason in try await service.cancel(requestID: userID, reason: reason) }
            )
        }
    }
}
#endif
