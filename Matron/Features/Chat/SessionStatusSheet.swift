import SwiftUI
import MatronModels
import MatronViewModels
import MatronDesignSystem

/// iOS session-status sheet — surfaced from `ChatView`'s ⓘ toolbar button.
/// Shows the context-window gauge and the stacked usage bars from the
/// last journal `status` frame; replaces the old bot-profile sheet.
/// Reads `viewModel.sessionStatus` in its own body — a value snapshot
/// passed through the `.sheet` closure isn't observation-tracked, so an
/// open sheet would never refresh when the first status frame lands.
struct SessionStatusSheet: View {
    let viewModel: ChatViewModel
    /// The agent box this session runs on, or nil when the user has fewer
    /// than two boxes (the chip gate — see `JournalChatService.boxName`).
    var boxName: String? = nil
    /// Ride-along to the media browser: the ⓘ sheet is the chat's one
    /// utility surface now (the toolbar is back to a single info button —
    /// Dan, 2026-08-16), so the media panel opens from here. The closure
    /// only FLAGS the intent; `ChatView` presents the browser from its
    /// `onDismiss`, because presenting a second sheet while this one is
    /// still up is a silent no-op.
    var onOpenMedia: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    private var status: SessionStatus? { viewModel.sessionStatus }

    /// Any known part counts — a model-only status (first turn after a
    /// bridge boot whose turn errored before usage arrived) shows the model
    /// footnote rather than claiming "no usage data yet".
    private var hasContent: Bool {
        status?.model != nil || status?.context != nil || !(status?.limits ?? []).isEmpty
            || status?.email != nil || status?.workdir != nil || status?.vitals != nil
            || boxName != nil
    }

    /// The footer's own gate. Split out because the box name is known from
    /// the chat list, not the status frame: open the sheet before the first
    /// `status` lands and the footer is the only thing there is to show.
    private var hasFooter: Bool {
        status?.email != nil || status?.model != nil
            || status?.workdir != nil || status?.vitals != nil || boxName != nil
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                // Above the gauge/usage content and OUTSIDE the
                // `hasContent` gate — the media browser is reachable even
                // before the first status frame lands.
                if onOpenMedia != nil {
                    Button {
                        onOpenMedia?()
                        dismiss()
                    } label: {
                        Label("Media, Files & Links", systemImage: "photo.on.rectangle.angled")
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                }
                sheetContent
            }
            .navigationTitle("Session")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
    }

    @ViewBuilder
    private var sheetContent: some View {
            Group {
                // Gated on `hasContent` alone, not on a non-nil `status`:
                // requiring a status frame here hid the box name behind
                // "No usage data yet" until the first reply landed.
                if hasContent {
                    VStack(alignment: .leading, spacing: 24) {
                        if let context = status?.context {
                            HStack(spacing: 12) {
                                ContextGaugeLabel(context: context)
                                Spacer()
                                // Sends /compact for the user (Dan,
                                // 2026-07-16: "so you don't have to type
                                // it"), then dismisses so the command —
                                // and the bridge's compaction reply —
                                // are visible in the chat.
                                Button {
                                    Task { await viewModel.sendCommand("/compact") }
                                    dismiss()
                                } label: {
                                    Label("Compact", systemImage: "arrow.down.right.and.arrow.up.left")
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                        if let limits = status?.limits, !limits.isEmpty {
                            UsageBarsView(limits: limits, scale: .regular)
                        }
                        if hasFooter {
                            // Session footer: the bridge machine's logged-in
                            // email, model, workdir (home-abbreviated — the
                            // BRIDGE machine's path) and host CPU/RAM, all
                            // quiet.
                            VStack(alignment: .leading, spacing: 2) {
                                // Leads the block: "which machine am I
                                // talking to" outranks the account and path.
                                if let boxName {
                                    Text(boxName)
                                }
                                if let email = status?.email {
                                    Text(email)
                                }
                                if let model = status?.model {
                                    Text(UsageMetersFormat.modelLine(
                                        model: model, effort: status?.effort))
                                }
                                if let workdir = status?.workdir {
                                    Text(UsageMetersFormat.homeAbbreviated(workdir))
                                }
                                if let vitals = status?.vitals,
                                   let line = UsageMetersFormat.vitalsLine(vitals) {
                                    Text(line)
                                        .accessibilityLabel("Bridge host: \(line)")
                                }
                            }
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                } else {
                    ContentUnavailableView(
                        "No usage data yet",
                        systemImage: "gauge",
                        description: Text("Appears after the next reply.")
                    )
                }
            }
    }
}
