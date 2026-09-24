import SwiftUI

/// "Open the Coordinator" as an environment value (Coordinator redesign
/// §3c): the shell installs it once; a chat's ⓘ-sheet row and tasks-page
/// button read it; `InsideCoordinatorSheet` clears it so the Coordinator's
/// own chat offers no entry. Equal to every other instance on purpose: it
/// is stored once per shell, and a closure SwiftUI cannot compare must not
/// invalidate every chat that reads it.
struct OpenCoordinatorAction: Equatable {
    private let perform: @MainActor () -> Void

    init(_ perform: @escaping @MainActor () -> Void) { self.perform = perform }

    @MainActor func callAsFunction() { perform() }

    static func == (lhs: Self, rhs: Self) -> Bool { true }
}

private struct OpenCoordinatorKey: EnvironmentKey {
    static let defaultValue: OpenCoordinatorAction? = nil
}

extension EnvironmentValues {
    var openCoordinator: OpenCoordinatorAction? {
        get { self[OpenCoordinatorKey.self] }
        set { self[OpenCoordinatorKey.self] = newValue }
    }
}

/// Set on the Coordinator sheet's ROOT chat only: its header adds Find in
/// Chat and "Your requests" (tracker #2864). Chats pushed on top of it in
/// the sheet don't get them.
private struct CoordinatorChatToolsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var showsCoordinatorChatTools: Bool {
        get { self[CoordinatorChatToolsKey.self] }
        set { self[CoordinatorChatToolsKey.self] = newValue }
    }
}

/// `AppShellNavigation.uncoverRequest`, published by the shell: a
/// Coordinator presentation is waiting for the sheets covering the shell to
/// leave (final review I2). Views owning a closable sheet close it on change.
private struct ShellUncoverRequestKey: EnvironmentKey {
    static let defaultValue = 0
}

extension EnvironmentValues {
    var shellUncoverRequest: Int {
        get { self[ShellUncoverRequestKey.self] }
        set { self[ShellUncoverRequestKey.self] = newValue }
    }
}

private struct CloseOnShellUncoverRequest: ViewModifier {
    @Environment(\.shellUncoverRequest) private var request
    let close: () -> Void

    func body(content: Content) -> some View {
        content.onChange(of: request) { _, _ in close() }
    }
}

extension View {
    /// Runs `close` (set this view's sheet flags false) when the shell asks
    /// covering sheets to leave so the Coordinator can present.
    func closesOnShellUncoverRequest(_ close: @escaping () -> Void) -> some View {
        modifier(CloseOnShellUncoverRequest(close: close))
    }
}

/// "This sheet is holding a parked Coordinator presentation" — reported by
/// sheets that keep user work open instead of closing for it, so the
/// shell's give-up clock stops while they do. Equal to every instance for
/// the same reason as `OpenCoordinatorAction`.
struct HoldCoordinatorAction: Equatable {
    private let perform: @MainActor (UUID, Bool) -> Void

    init(_ perform: @escaping @MainActor (UUID, Bool) -> Void) { self.perform = perform }

    @MainActor func callAsFunction(_ token: UUID, holding: Bool) { perform(token, holding) }

    static func == (lhs: Self, rhs: Self) -> Bool { true }
}

private struct HoldCoordinatorKey: EnvironmentKey {
    static let defaultValue: HoldCoordinatorAction? = nil
}

extension EnvironmentValues {
    var holdCoordinatorPresentation: HoldCoordinatorAction? {
        get { self[HoldCoordinatorKey.self] }
        set { self[HoldCoordinatorKey.self] = newValue }
    }
}

private struct ReportsCoordinatorHold: ViewModifier {
    @Environment(\.holdCoordinatorPresentation) private var hold
    @State private var token = UUID()
    let holding: Bool

    func body(content: Content) -> some View {
        content
            .onChange(of: holding, initial: true) { _, isHolding in hold?(token, holding: isHolding) }
            .onDisappear { hold?(token, holding: false) }
    }
}

extension View {
    /// Reports whether this sheet would stay open over a parked Coordinator
    /// presentation (unsaved input, a start in flight).
    func reportsCoordinatorHold(_ holding: Bool) -> some View {
        modifier(ReportsCoordinatorHold(holding: holding))
    }
}

/// Whether anything is presented over the shell's root right now —
/// including a sheet still animating away, which SwiftUI would drop a
/// second presentation behind.
@MainActor
enum ShellPresentation {
    static func isCovered() -> Bool {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
        guard let root = windows.first(where: \.isKeyWindow)?.rootViewController else { return false }
        return root.presentedViewController != nil
    }
}

/// Wraps the Coordinator sheet's content: no Coordinator entry inside it.
struct InsideCoordinatorSheet<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content.environment(\.openCoordinator, nil)
    }
}

/// The floating Coordinator button on each tab's ROOT screen (spec §3c):
/// bottom trailing, above the tab bar, with the unread dot the tab had.
/// Never inside a chat — it would sit over the composer.
struct CoordinatorFloatingButton: View {
    let hasUnread: Bool
    let action: () -> Void

    init(hasUnread: Bool, action: @escaping () -> Void) {
        self.hasUnread = hasUnread
        self.action = action
    }

    static func accessibilityLabel(hasUnread: Bool) -> String {
        hasUnread ? "Coordinator, unread messages" : "Coordinator"
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.title2)
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Color.accentColor, in: Circle())
                .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
                .overlay(alignment: .topTrailing) {
                    if hasUnread {
                        Circle().fill(Color.red).frame(width: 12, height: 12)
                            .overlay(Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 2))
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.accessibilityLabel(hasUnread: hasUnread))
        .accessibilityIdentifier("coordinator.floatingButton")
    }
}

/// The Coordinator button at the top of a chat's tasks page (Dan, #2757).
struct CoordinatorEntryButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Coordinator", systemImage: "person.crop.circle.badge.checkmark")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .accessibilityIdentifier("coordinator.tasksPageButton")
    }
}
