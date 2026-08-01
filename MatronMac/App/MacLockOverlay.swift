#if os(macOS)
import SwiftUI
import MatronViewModels

/// Opaque in-window lock cover. Unlike iOS there is no sheet-window
/// problem to solve with a separate NSWindow — Mac content lives in the
/// scene windows this overlays (both the main WindowGroup and the
/// Settings scene mount one).
struct MacLockOverlay: View {
    let controller: AppLockController

    var body: some View {
        ZStack {
            Rectangle().fill(Color(nsColor: .windowBackgroundColor)).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text("Matron is locked")
                    .font(.title3.weight(.semibold))
                Button {
                    Task { await controller.unlock() }
                } label: {
                    Text("Unlock with \(controller.methodName ?? "your password")")
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
        // No auto-prompt here: this view mounts once per WINDOW (main +
        // Settings each get one), so a per-mount prompt would re-nag a
        // user who already cancelled whenever another window appears.
        // The host owns the once-per-activation automatic prompt.
    }
}
#endif
