import SwiftUI
import UIKit
import MatronViewModels

/// Presents the lock / privacy shield in its OWN `UIWindow` above the app.
/// Sheets and full-screen covers render in separate presentation windows,
/// so an in-hierarchy `.overlay` at the root would leave any open sheet
/// (settings, image preview, search) exposed while "locked".
@MainActor
enum AppLockOverlay {
    private static var window: UIWindow?

    /// `shield` covers content without offering unlock UI — used while the
    /// app is merely inactive (app switcher snapshot) rather than locked.
    static func update(controller: AppLockController, shield: Bool) {
        guard controller.isLocked || shield else {
            window?.isHidden = true
            window = nil
            return
        }
        let root = LockScreenView(controller: controller)
        if let window {
            (window.rootViewController as? UIHostingController<LockScreenView>)?.rootView = root
            return
        }
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState != .unattached }) else { return }
        let fresh = UIWindow(windowScene: scene)
        fresh.windowLevel = .alert + 1
        fresh.rootViewController = UIHostingController(rootView: root)
        fresh.isHidden = false
        window = fresh
    }
}

/// Opaque cover: branding while shielding, plus the unlock affordance when
/// actually locked. Opaque (not a material blur) so the app-switcher
/// snapshot reveals nothing.
struct LockScreenView: View {
    let controller: AppLockController

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: controller.isLocked ? "lock.fill" : "lock.shield")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text("Matron")
                    .font(.title2.weight(.semibold))
                if controller.isLocked {
                    Button {
                        Task { await controller.unlock() }
                    } label: {
                        Text("Unlock with \(controller.methodName ?? "passcode")")
                            .padding(.horizontal, 4)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(controller.isUnlocking)
                    if let error = controller.unlockError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                }
            }
        }
    }
}
