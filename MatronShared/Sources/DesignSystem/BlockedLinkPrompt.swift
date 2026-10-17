import Foundation
#if canImport(UIKit) && !os(macOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// What the user sees after tapping a link the app won't open
/// (`MatronItemLink.Action.blocked`): a short alert saying so, with the link
/// itself and a way to copy it. Nothing is opened from here.
///
/// One presenter for every host — the message renderers on both platforms,
/// item link chips and SwiftUI `openURL` handlers — so they all say the same
/// thing.
public enum BlockedLinkPrompt {
    public static let title = "This link can't be opened from Matron"
    public static let copyTitle = "Copy Link"
    public static let cancelTitle = "Cancel"

    /// Longest stretch of the link shown in the alert. A `data:` link can
    /// run to megabytes; Copy Link still copies all of it.
    static let maxShownLength = 300

    /// The alert's message: the link as written, shortened if it is long.
    public static func message(for url: URL) -> String {
        let text = url.absoluteString
        guard text.count > maxShownLength else { return text }
        return String(text.prefix(maxShownLength)) + "…"
    }

    /// Test seam. Replaced in tests to record presentations instead of
    /// putting up a real alert.
    @MainActor public static var presenter: (URL) -> Void = { presentAlert(for: $0) }

    /// Shows the prompt for `url` over the app's frontmost window.
    @MainActor public static func present(_ url: URL) {
        presenter(url)
    }

    #if canImport(UIKit) && !os(macOS)
    /// The alert itself, built apart from presenting it so tests can check
    /// its title and actions.
    @MainActor public static func makeAlert(for url: URL) -> UIAlertController {
        let alert = UIAlertController(title: title, message: message(for: url), preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: copyTitle, style: .default) { _ in
            Pasteboard.copy(url.absoluteString)
        })
        alert.addAction(UIAlertAction(title: cancelTitle, style: .cancel))
        return alert
    }

    @MainActor private static func presentAlert(for url: URL) {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows)
        guard var top = (windows.first(where: \.isKeyWindow) ?? windows.first)?.rootViewController else { return }
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
        top.present(makeAlert(for: url), animated: true)
    }
    #elseif os(macOS)
    /// The alert itself, built apart from presenting it so tests can check
    /// its title and buttons.
    @MainActor public static func makeAlert(for url: URL) -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = message(for: url)
        alert.addButton(withTitle: copyTitle)
        alert.addButton(withTitle: cancelTitle)
        return alert
    }

    @MainActor private static func presentAlert(for url: URL) {
        let alert = makeAlert(for: url)
        let copy: (NSApplication.ModalResponse) -> Void = { response in
            if response == .alertFirstButtonReturn { Pasteboard.copy(url.absoluteString) }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow, window.attachedSheet == nil {
            alert.beginSheetModal(for: window, completionHandler: copy)
        } else {
            copy(alert.runModal())
        }
    }
    #endif
}
