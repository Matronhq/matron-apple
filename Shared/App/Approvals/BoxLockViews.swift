import SwiftUI
import MatronDesignSystem
import MatronJournal
import MatronViewModels

/// A locked box's line on its card: a lock, whether an unlock window is
/// open and how long is left, and the buttons that open, end or clear it.
/// Draws nothing for a box that is not in locked mode.
struct BoxLockBar: View {
    let device: DeviceDTO
    let viewModel: BoxesViewModel
    /// Opens the unlock sheet for this box.
    let onUnlock: (DeviceDTO) -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 20)) { context in
            if viewModel.showsLock(device, now: context.date) {
                content(device.locked ?? BoxLock(), now: context.date)
            }
        }
    }

    @ViewBuilder private func content(_ lock: BoxLock, now: Date) -> some View {
        let unlocked = lock.isUnlocked(at: now)
        let inLockdown = viewModel.isInLockdown(device, now: now)
        let busy = viewModel.lockBusy.contains(device.id)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: inLockdown ? "exclamationmark.lock.fill" : (unlocked ? "lock.open.fill" : "lock.fill"))
                    .foregroundStyle(inLockdown ? Color.red : (unlocked ? Color.green : Color.orange))
                Text(inLockdown ? "In lockdown" : BoxLockControl.stateText(lock, now: now))
                    .font(.subheadline.weight(.medium))
                Spacer(minLength: 4)
                if busy {
                    ProgressView().controlSize(.small)
                } else if inLockdown {
                    Button("Clear Lockdown…") { Task { await viewModel.clearLockdown(device) } }
                        .accessibilityIdentifier("boxes.clearLockdown.\(device.id)")
                } else if unlocked {
                    Button("Lock Now") { Task { await viewModel.lock(device) } }
                        .accessibilityIdentifier("boxes.lock.\(device.id)")
                } else {
                    Button("Unlock…") { onUnlock(device) }
                        .accessibilityIdentifier("boxes.unlock.\(device.id)")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            if !unlocked && !inLockdown {
                Text("Takes no instructions until you unlock it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if viewModel.lockErrorBoxID == device.id, let error = viewModel.lockError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("boxes.lockError.\(device.id)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("boxes.lockBar.\(device.id)")
    }
}

/// "Protected", beside a box's name: work aimed at it needs the user's own
/// signed approval.
struct ProtectedBoxBadge: View {
    var body: some View {
        Label("Protected", systemImage: "shield.lefthalf.filled")
            .font(.caption2.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.accentColor.opacity(0.18), in: Capsule())
            .accessibilityLabel("Protected box")
    }
}

/// Picks how long to unlock a locked box for, then asks for the signature.
struct BoxUnlockSheet: View {
    let device: DeviceDTO
    let viewModel: BoxesViewModel
    let close: () -> Void
    @State private var minutes = BoxLockControl.defaultMinutes

    var body: some View {
        #if os(iOS)
        NavigationStack {
            form
                .navigationTitle("Unlock \(device.name)")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: close) }
                }
        }
        .presentationDetents([.medium])
        #else
        VStack(alignment: .leading, spacing: 0) {
            Text("Unlock \(device.name)").font(.headline).padding([.top, .horizontal], 20)
            form
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: close).keyboardShortcut(.cancelAction)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 420)
        #endif
    }

    private var busy: Bool { viewModel.lockBusy.contains(device.id) }

    private var form: some View {
        Form {
            MatronGroupedRows {
                Section {
                    Picker("Unlock for", selection: $minutes) {
                        ForEach(BoxLockControl.offeredMinutes, id: \.self) { value in
                            Text(BoxLockControl.durationText(value)).tag(value)
                        }
                    }
                    #if os(iOS)
                    .pickerStyle(.inline)
                    .labelsHidden()
                    #endif
                    .accessibilityIdentifier("boxUnlock.minutes")
                } header: {
                    // The Mac's picker carries the label itself.
                    #if os(iOS)
                    Text("Unlock for")
                    #endif
                } footer: {
                    Text("While it is unlocked, \(device.name) takes instructions from this device only. It locks again by itself. A step-up question still asks for its own approval.")
                }
                Section {
                    Button {
                        Task {
                            let unlocked = await viewModel.unlock(device, minutes: minutes)
                            // In lockdown, the way forward is Clear
                            // Lockdown on the box's card, behind this sheet.
                            if unlocked || viewModel.isInLockdown(device) { close() }
                        }
                    } label: {
                        HStack {
                            Spacer()
                            if busy { ProgressView().controlSize(.small) }
                            Text("Unlock for \(BoxLockControl.durationText(minutes))").fontWeight(.semibold)
                            Spacer()
                        }
                    }
                    .disabled(busy)
                    .accessibilityIdentifier("boxUnlock.confirm")
                    if viewModel.lockErrorBoxID == device.id, let error = viewModel.lockError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        #if os(macOS)
        .formStyle(.grouped)
        #endif
    }
}

/// "This account is locked", across the top of the app while the journal
/// answers 423: nothing is accepted until the lock is cleared.
struct AccountLockedBanner: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.fill")
            VStack(alignment: .leading, spacing: 1) {
                Text("This account is locked").fontWeight(.semibold)
                Text("Sessions are stopped and nothing can be sent until it is cleared.")
                    .font(.caption)
                    .opacity(0.9)
            }
            Spacer(minLength: 0)
        }
        .font(.subheadline)
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color.red)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("accountLocked.banner")
    }
}

/// Covers the app while the account is locked and this device can unlock
/// it: the journal froze it instead of signing it out, because it holds an
/// approval key old enough.
struct AccountLockedScreen: View {
    /// When the lock began, epoch ms.
    let since: Int64?
    /// "Face ID" or "Touch ID".
    let method: String
    let isUnlocking: Bool
    let error: String?
    let onUnlock: () -> Void
    /// For a device that cannot unlock (its key no longer works).
    var onSignOut: (() -> Void)? = nil
    @State private var confirmingSignOut = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(.red)
                    .padding(.top, 8)
                VStack(spacing: 6) {
                    Text("This account is locked")
                        .font(.title2.weight(.bold))
                    if let sinceText {
                        Text(sinceText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .multilineTextAlignment(.center)
                VStack(alignment: .leading, spacing: 10) {
                    Text("It was locked to stop it being misused. While it is locked, your boxes take no new work and no device can sign in.")
                    Text("This device can unlock it with its approval key. Unlocking signs out every other device on the account; sign them in again afterwards.")
                    Text("Only unlock it if you know why it was locked.")
                        .fontWeight(.semibold)
                }
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color.secondary.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                Button(action: onUnlock) {
                    HStack(spacing: 8) {
                        if isUnlocking {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: method == "Touch ID" ? "touchid" : "faceid")
                        }
                        Text(isUnlocking ? "Unlocking…" : "Unlock with \(method)")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isUnlocking)
                .accessibilityIdentifier("accountLocked.unlock")
                if let error {
                    Label {
                        Text(error).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill")
                    }
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("accountLocked.error")
                }
                if let onSignOut {
                    Button("Can't unlock? Sign Out of This Device") { confirmingSignOut = true }
                        .buttonStyle(.borderless)
                        .font(.footnote)
                        .padding(.top, 4)
                        .accessibilityIdentifier("accountLocked.signOut")
                        .confirmationDialog("Sign out of this device?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
                            Button("Sign Out", role: .destructive, action: onSignOut)
                        } message: {
                            Text("While the account is locked you can't sign in again. Once the lock is cleared, sign in and re-attach this device's key.")
                        }
                }
            }
            .padding(24)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .accessibilityIdentifier("accountLocked.screen")
    }

    private var sinceText: String? {
        guard let since else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(since) / 1000)
        return "Locked since " + date.formatted(date: .abbreviated, time: .shortened)
    }
}

/// Something the user must read after the lock has gone, with a button to
/// put it away.
struct AccountWarningBanner: View {
    let text: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button("OK", action: onDismiss)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("accountWarning.dismiss")
        }
        .font(.footnote)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(Color.orange.opacity(0.25))
        .accessibilityIdentifier("accountWarning.banner")
    }
}
