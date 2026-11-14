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
