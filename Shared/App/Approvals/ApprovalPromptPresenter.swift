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
    #if os(iOS)
    private weak var controller: UIViewController?
    #else
    private var sheet: NSWindow?
    private weak var parent: NSWindow?
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

    private func sync() {
        let prompt = center.prompt
        guard prompt?.id != shownID else { return }
        dismiss()
        shownID = prompt?.id
        if prompt != nil { present() }
    }

    #if os(iOS)
    private func present() {
        guard let top = Self.topController() else {
            // Nothing to present on (no scene yet): the request cannot be
            // shown, so it is not signed.
            center.cancel()
            return
        }
        let host = Self.sheetController(ApprovalConfirmHost(center: center))
        controller = host
        top.present(host, animated: true)
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

    private func dismiss() {
        controller?.dismiss(animated: true)
        controller = nil
    }

    private static func topController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
        var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController ?? scene?.windows.first?.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed { top = presented }
        return top
    }
    #else
    private func present() {
        let host = NSHostingController(rootView: ApprovalConfirmHost(center: center)
            .frame(width: Self.sheetSize.width, height: Self.sheetSize.height))
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled]
        window.title = ApprovalConfirmView.title
        guard let key = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: \.isVisible) else {
            center.cancel()
            return
        }
        // A window that already shows a sheet takes the next one only
        // after the first closes: present on the sheet itself.
        let target = key.attachedSheet ?? key
        sheet = window
        parent = target
        target.beginSheet(window)
    }

    /// The confirm sheet's size on the Mac.
    static let sheetSize = CGSize(width: 460, height: 540)

    private func dismiss() {
        if let sheet { parent?.endSheet(sheet) }
        sheet = nil
        parent = nil
    }
    #endif
}
