import AppKit
import SwiftUI

/// What the window's chat header currently shows. One per window, owned by
/// `MacChatHeaderAccessory`; `nil` draws nothing.
@Observable @MainActor
final class MacChatHeaderModel {
    var props: MacChatToolbarProps?
}

/// The capsule the system toolbar used to draw around each item. Each one
/// also reports its frame, so the space BETWEEN capsules can stay title bar
/// — see `MacChatHeaderHostingView`.
struct MacChatHeaderGlass: ViewModifier {
    func body(content: Content) -> some View {
        glass(content)
            .background {
                GeometryReader { geo in
                    Color.clear.preference(key: MacChatHeaderCapsuleFrames.self,
                                           value: [geo.frame(in: .named(MacChatHeaderBar.coordinateSpace))])
                }
            }
    }

    // `glassEffect` needs the macOS 26 SDK; CI still builds with Xcode 16.4
    // (same gate as the sidebar's `ToolbarSpacer` in `MacChatListView`).
    @ViewBuilder private func glass(_ content: Content) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .capsule)
        } else {
            content.background(.regularMaterial, in: Capsule())
        }
        #else
        content.background(.regularMaterial, in: Capsule())
        #endif
    }
}

struct MacChatHeaderCapsuleFrames: PreferenceKey {
    static let defaultValue: [CGRect] = []
    static func reduce(value: inout [CGRect], nextValue: () -> [CGRect]) {
        value.append(contentsOf: nextValue())
    }
}

/// Where the header's capsules are, in the bar's own (top-left) coordinates.
/// Plain storage, not observable: only hit testing reads it.
@MainActor
final class MacChatHeaderHitRegions {
    var capsules: [CGRect] = []

    func contains(_ point: CGPoint) -> Bool {
        capsules.contains { $0.contains(point) }
    }
}

/// The system toolbar fades its items while the window is inactive — text a
/// little, icons a lot (measured off the old toolbar: title 0 → 75, icons
/// → 176 on white). The capsules themselves stay.
struct MacChatHeaderInactiveDim: ViewModifier {
    let opacity: Double
    @Environment(\.controlActiveState) private var controlActiveState

    func body(content: Content) -> some View {
        content.opacity(controlActiveState == .inactive ? opacity : 1)
    }
}

/// The chat header row: `MacChatToolbar`'s clusters, laid out the way the
/// window toolbar placed them. Reads the model in its own body, so a room
/// switch or a status frame re-renders this row and nothing else.
struct MacChatHeaderBar: View {
    static let coordinateSpace = "MacChatHeaderBar"

    let model: MacChatHeaderModel
    let hitRegions: MacChatHeaderHitRegions

    var body: some View {
        bar
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .coordinateSpace(name: Self.coordinateSpace)
            .onPreferenceChange(MacChatHeaderCapsuleFrames.self) { frames in
                MainActor.assumeIsolated { hitRegions.capsules = frames }
            }
    }

    @ViewBuilder private var bar: some View {
        if let props = model.props {
            let toolbar = MacChatToolbar(props: props)
            // Each group sits in a stack so the layout always sees three
            // subviews — an empty cluster is otherwise no subview at all.
            MacChatHeaderLayout {
                HStack(spacing: 0) { toolbar.modelItem }
                HStack(spacing: 0) { toolbar.titleItem }
                HStack(spacing: 10) {
                    toolbar.usageItem
                    toolbar.buttonsItem
                    toolbar.subagentsCapsule
                }
            }
            .buttonStyle(.borderless)
            // Insets and capsule paddings are measured off the system toolbar
            // this replaced, so the header did not move when it changed hands.
            .padding(.horizontal, 8)
        }
    }
}

/// The bar fills the whole strip, but only its capsules are header: a click
/// between them has to reach the title bar underneath, or most of the window's
/// title bar stops dragging the window and zooming on double-click.
final class MacChatHeaderHostingView: NSHostingView<MacChatHeaderBar> {
    var hitRegions: MacChatHeaderHitRegions?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        guard hit === self, let hitRegions else { return hit }
        var local = convert(point, from: superview)
        if !isFlipped { local.y = bounds.height - local.y }
        return hitRegions.contains(local) ? hit : nil
    }
}

/// Leading group, title, trailing group — the title centred in the bar while
/// it fits, otherwise squeezed into the gap between the other two, which is
/// how the system toolbar placed its `.principal` item.
struct MacChatHeaderLayout: Layout {
    var gap: CGFloat = 10

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        return CGSize(width: proposal.width ?? 0, height: proposal.height ?? height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else { return }
        let leading = subviews[0].sizeThatFits(.unspecified).width
        let trailing = subviews[2].sizeThatFits(.unspecified).width
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: .unspecified)
        subviews[2].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: .unspecified)
        let ideal = subviews[1].sizeThatFits(.unspecified).width
        let span = Self.titleSpan(bounds: bounds.minX...bounds.maxX, leading: leading, trailing: trailing,
                                  ideal: ideal, gap: gap)
        subviews[1].place(at: CGPoint(x: (span.lowerBound + span.upperBound) / 2, y: bounds.midY), anchor: .center,
                          proposal: ProposedViewSize(width: span.upperBound - span.lowerBound, height: nil))
    }

    /// Where the title goes. Pure so the centring rule is testable without
    /// rendering.
    static func titleSpan(bounds: ClosedRange<CGFloat>, leading: CGFloat, trailing: CGFloat,
                          ideal: CGFloat, gap: CGFloat) -> ClosedRange<CGFloat> {
        let lo = bounds.lowerBound + leading + (leading > 0 ? gap : 0)
        let hi = max(lo, bounds.upperBound - trailing - (trailing > 0 ? gap : 0))
        let width = min(ideal, hi - lo)
        let mid = (bounds.lowerBound + bounds.upperBound) / 2
        let centre = min(max(mid, lo + width / 2), hi - width / 2)
        return (centre - width / 2)...(centre + width / 2)
    }
}

/// The accessory's root view — never a click target itself, for the same
/// reason as `MacChatHeaderHostingView`.
private final class MacChatHeaderContainerView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// The window's ONE chat-header accessory: a native title-bar accessory,
/// right-aligned and as wide as the chat column, hosting `MacChatHeaderBar`.
/// It is installed once per window and never removed — adding or removing an
/// accessory re-lays the title bar, which is the cost this exists to avoid —
/// only hidden while no chat column is on screen.
@MainActor
final class MacChatHeaderAccessory: NSTitlebarAccessoryViewController {
    /// The unified title bar + toolbar strip.
    static let height: CGFloat = 52

    let model = MacChatHeaderModel()
    let hitRegions = MacChatHeaderHitRegions()
    private(set) var hostingView: MacChatHeaderHostingView?
    private var widthConstraint: NSLayoutConstraint?
    private let hosts = NSHashTable<NSView>.weakObjects()

    static func existing(in window: NSWindow) -> MacChatHeaderAccessory? {
        window.titlebarAccessoryViewControllers.lazy.compactMap { $0 as? MacChatHeaderAccessory }.first
    }

    static func installed(in window: NSWindow, width: CGFloat) -> MacChatHeaderAccessory {
        if let existing = existing(in: window) { return existing }
        let accessory = MacChatHeaderAccessory(width: width)
        window.addTitlebarAccessoryViewController(accessory)
        return accessory
    }

    private init(width: CGFloat) {
        super.init(nibName: nil, bundle: nil)
        let hosting = MacChatHeaderHostingView(rootView: MacChatHeaderBar(model: model, hitRegions: hitRegions))
        hosting.hitRegions = hitRegions
        hostingView = hosting
        // The bar fills whatever the accessory is; it must not size it.
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = false
        let container = MacChatHeaderContainerView(frame: NSRect(x: 0, y: 0, width: width, height: Self.height))
        container.addSubview(hosting)
        let widthConstraint = container.widthAnchor.constraint(equalToConstant: width)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            widthConstraint,
        ])
        self.widthConstraint = widthConstraint
        layoutAttribute = .right
        view = container
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// The title bar sizes a `.right` accessory from its view's FRAME; the
    /// constraint alone leaves it at its install-time width.
    func setWidth(_ width: CGFloat) {
        guard width > 0, abs(view.frame.width - width) > 0.5 else { return }
        widthConstraint?.constant = width
        view.setFrameSize(NSSize(width: width, height: view.frame.height))
    }

    func attach(_ host: NSView) {
        hosts.add(host)
        isHidden = false
    }

    /// The last host leaving (another tab replaced the split view) empties
    /// and hides the header rather than leaving the old chat's title up.
    func detach(_ host: NSView) {
        hosts.remove(host)
        guard hosts.allObjects.isEmpty else { return }
        model.props = nil
        isHidden = true
    }
}

/// A `MacChatHeaderHost`'s line to its window's accessory. The host can
/// publish before its tracker view has reached a window, so the latest props
/// are held here and handed over on attach.
@MainActor
final class MacChatHeaderLink {
    private var latest: MacChatToolbarProps?
    weak var accessory: MacChatHeaderAccessory? {
        didSet {
            if let latest { accessory?.model.props = latest }
        }
    }

    func publish(_ props: MacChatToolbarProps?) {
        latest = props
        accessory?.model.props = props
    }
}

/// Finds (or installs) the window's accessory from inside the SwiftUI tree and
/// keeps its width on the chat column's.
struct MacChatHeaderAccessoryInstaller: NSViewRepresentable {
    let link: MacChatHeaderLink
    let width: CGFloat

    /// Every change here touches the title bar, which re-lays the window —
    /// and these callbacks arrive while the window's own hosting view is
    /// mid-render, where AppKit skips a re-entrant layout pass. So the tracker
    /// only notes what changed and reconciles on the next main-queue turn.
    final class Tracker: NSView {
        var link: MacChatHeaderLink?
        var width: CGFloat = 0 {
            didSet { if width != oldValue { scheduleSync() } }
        }
        /// Set when SwiftUI is done with this view, whether or not AppKit has
        /// taken it out of the window yet.
        var dismantled = false {
            didSet { scheduleSync() }
        }
        private weak var attached: MacChatHeaderAccessory?
        private var syncScheduled = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleSync()
        }

        func scheduleSync() {
            guard !syncScheduled else { return }
            syncScheduled = true
            DispatchQueue.main.async { [self] in
                syncScheduled = false
                sync()
            }
        }

        private func sync() {
            guard let window, !dismantled else {
                attached?.detach(self)
                attached = nil
                return
            }
            if let attached, attached !== MacChatHeaderAccessory.existing(in: window) {
                attached.detach(self)
                self.attached = nil
            }
            let accessory = MacChatHeaderAccessory.installed(in: window, width: width)
            accessory.setWidth(width)
            guard attached == nil else { return }
            accessory.attach(self)
            attached = accessory
            link?.accessory = accessory
        }
    }

    func makeNSView(context: Context) -> Tracker {
        let tracker = Tracker()
        tracker.link = link
        tracker.width = width
        return tracker
    }

    func updateNSView(_ tracker: Tracker, context: Context) {
        tracker.width = width
    }

    static func dismantleNSView(_ tracker: Tracker, coordinator: ()) {
        tracker.dismantled = true
    }
}

/// Wraps the detail column: whatever chat column is mounted inside publishes
/// `MacChatToolbarPreference`, and this forwards it to the window's header
/// accessory. The link lives in this view's own `@State` on purpose: held by
/// `MacChatListView` instead, every title / badge / status change would
/// re-evaluate that whole root view, sidebar included.
struct MacChatHeaderHost<Content: View>: View {
    @ViewBuilder let content: Content
    @State private var link = MacChatHeaderLink()

    var body: some View {
        let link = link
        content
            .background {
                GeometryReader { geo in
                    MacChatHeaderAccessoryInstaller(link: link, width: geo.size.width)
                }
            }
            .onPreferenceChange(MacChatToolbarPreference.self) { props in
                MainActor.assumeIsolated { link.publish(props) }
            }
    }
}
