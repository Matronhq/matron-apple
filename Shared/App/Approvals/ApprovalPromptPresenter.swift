import SwiftUI
import MatronDesignSystem
import MatronJournal
import MatronViewModels
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// The confirm sheet's content, bound to the approval centre.
struct ApprovalConfirmHost: View {
    let center: ApprovalCenter

    var body: some View {
        if let prompt = center.prompt {
            ApprovalConfirmView(
                model: Self.model(prompt, isSigning: center.isSigning, error: center.promptError),
                onConfirm: { center.confirm() },
                onCancel: { center.cancel() })
        }
    }

    static func model(_ prompt: ApprovalCenter.Prompt, isSigning: Bool, error: String?) -> ApprovalConfirmView.Model {
        let request = prompt.request
        return ApprovalConfirmView.Model(
            reference: request.reference, headline: request.headline, button: request.button, detail: request.detail,
            box: request.box,
            subject: request.subjectLines.map { ApprovalConfirmView.Model.Line(key: $0.key, value: $0.value) },
            method: prompt.method, fingerprint: prompt.fingerprint, attachesFirst: prompt.attachesFirst,
            isSigning: isSigning, error: error)
    }
}

/// Shows the confirm sheet whenever the approval centre has a request
/// waiting, over whatever is on screen: a signature can be asked for from
/// inside another sheet (changing the password, linking a device), where a
/// sheet declared on the app's root view could not present.
@MainActor
final class ApprovalPromptPresenter {
    private let center: ApprovalCenter
    private var shownID: UUID?
    /// A sheet is going up or coming down. Changes wait for it: UIKit and
    /// AppKit both refuse, or lose, a presentation made during another.
    private var transitioning = false
    /// The request changed during a transition; look again once it ends.
    private var changedMeanwhile = false
    /// Counts transitions, so a late completion or the watchdog of an
    /// earlier one cannot end a later one.
    private var transition = 0
    /// How many times in a row the system has not shown the sheet.
    private var failedPresentations = 0
    /// Long enough for any sheet animation; after it a transition whose
    /// completion never came is taken as over.
    private static let transitionLimit: Duration = .seconds(2)
    #if os(iOS)
    private weak var controller: UIViewController?
    #else
    private var sheet: NSWindow?
    private weak var parent: NSWindow?
    private var afterSheetEnds: (() -> Void)?
    #endif

    init(center: ApprovalCenter) {
        self.center = center
        observe()
    }

    private func observe() {
        withObservationTracking {
            _ = center.prompt?.id
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.sync()
                self?.observe()
            }
        }
    }

    /// Brings what is on screen in line with the request that is waiting:
    /// the sheet for another request goes first, then this one's comes up.
    /// One transition at a time.
    private func sync() {
        guard !transitioning else {
            changedMeanwhile = true
            return
        }
        guard center.prompt?.id != shownID else { return }
        transitioning = true
        transition += 1
        let number = transition
        // The system does not always call back: a presentation it refuses
        // (something else was mid-transition) can end in silence. The
        // transition is then taken as over, and checked.
        Task { [weak self] in
            try? await Task.sleep(for: Self.transitionLimit)
            self?.transitionEnded(number)
        }
        dismissShown { [weak self] in
            guard let self, self.transition == number, self.transitioning else { return }
            // Read again: the request may have changed while the last
            // sheet was going.
            let current = self.center.prompt
            self.shownID = current?.id
            if current != nil {
                self.present { [weak self] in self?.transitionEnded(number) }
            } else {
                self.transitionEnded(number)
            }
        }
    }

    private func transitionEnded(_ number: Int) {
        guard transitioning, transition == number else { return }
        transitioning = false
        // A request is waiting and its sheet is not on screen: the system
        // did not show it. Try again a few times, then give the request
        // up, unsigned: it must never wait for ever behind nothing.
        if center.prompt != nil, center.prompt?.id == shownID, !isShowingSheet {
            shownID = nil
            forgetSheet()
            failedPresentations += 1
            if failedPresentations > 3 {
                failedPresentations = 0
                center.cancel()
                return
            }
            changedMeanwhile = true
        } else {
            failedPresentations = 0
        }
        if changedMeanwhile {
            changedMeanwhile = false
            sync()
        }
    }

    #if os(iOS)
    private func present(then done: @escaping () -> Void) {
        guard let top = Self.topController() else {
            // Nothing to present on (no scene yet): the request cannot be
            // shown, so it is not signed.
            center.cancel()
            return done()
        }
        let host = Self.sheetController(ApprovalConfirmHost(center: center))
        controller = host
        top.present(host, animated: true, completion: done)
    }

    /// The confirm sheet's controller. Full height, so every line of what
    /// is being signed is on screen above the button, not under a fold.
    static func sheetController<Content: View>(_ content: Content) -> UIViewController {
        let host = UIHostingController(rootView: content)
        host.modalPresentationStyle = .pageSheet
        // Only the sheet's own Cancel ends it: a stray swipe must not be
        // read as an answer either way.
        host.isModalInPresentation = true
        host.sheetPresentationController?.detents = [.large()]
        return host
    }

    private func dismissShown(then next: @escaping () -> Void) {
        guard let shown = controller, shown.presentingViewController != nil else {
            controller = nil
            return next()
        }
        controller = nil
        shown.dismiss(animated: true, completion: next)
    }

    /// Whether the confirm sheet is really on screen.
    private var isShowingSheet: Bool {
        guard let controller else { return false }
        return controller.presentingViewController != nil && !controller.isBeingDismissed
    }

    private func forgetSheet() { controller = nil }

    private static func topController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController ?? scene?.windows.first?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed { top = presented }
        return top
    }
    #else
    /// The confirm sheet's size on the Mac.
    static let sheetSize = CGSize(width: 460, height: 640)

    private func present(then done: @escaping () -> Void) {
        let host = NSHostingController(rootView: ApprovalConfirmHost(center: center)
            .frame(width: Self.sheetSize.width, height: Self.sheetSize.height))
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled]
        window.title = ApprovalConfirmView.title
        guard let key = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: \.isVisible) else {
            center.cancel()
            return done()
        }
        // A window that already shows a sheet takes the next one only
        // after the first closes: present on the sheet itself.
        let target = key.attachedSheet ?? key
        sheet = window
        parent = target
        target.beginSheet(window) { [weak self] _ in
            // The sheet has fully gone: what waited for that may go on.
            guard let self else { return }
            let next = self.afterSheetEnds
            self.afterSheetEnds = nil
            next?()
        }
        done()
    }

    private func dismissShown(then next: @escaping () -> Void) {
        // A sheet that is no longer attached has no end handler left to
        // call: go straight on.
        guard let sheet, let parent, sheet.sheetParent != nil else {
            self.sheet = nil
            self.parent = nil
            return next()
        }
        self.sheet = nil
        self.parent = nil
        afterSheetEnds = next
        parent.endSheet(sheet)
    }

    /// Whether the confirm sheet is really on screen.
    private var isShowingSheet: Bool { sheet?.sheetParent != nil }

    private func forgetSheet() {
        sheet = nil
        parent = nil
        afterSheetEnds = nil
    }
    #endif
}
