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

                // The .borderedProminent button's press animation runs
                // on mouse-up; if the action mutates `path` synchronously,
                // NavigationStack unmounts the host view before the
                // press-up frame renders and the click looks like it
                // did nothing. Defer the path mutation by one runloop +
                // ~120 ms so the button visibly compresses + releases
                // first. (`.bordered` and the plain text button below
                // are subtler visually and don't need the same defer.)
                Button {
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 120_000_000)
                        path.append(.sasWithOtherDevice)
                    }
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
                    // construction to the generic `MacSasSheetWrapper`
                    // so the SasViewModel + stream survive parent
                    // re-renders. See iOS `PostLoginVerificationView`
                    // for full rationale. `onCancelled` pops back to
                    // the verify-gate buttons so a cancelled SAS
                    // doesn't strand the user inside the destination
                    // with no way out.
                    MacSasSheetWrapper(
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

#endif
