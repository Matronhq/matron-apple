import SwiftUI
import UIKit
import MatronShare
import MatronStorage

/// The share sheet's "Matron" entry: hosts `ShareView` and hands the shared
/// items to its view model.
final class ShareViewController: UIViewController {
    private var model: ShareViewModel?

    override func viewDidLoad() {
        super.viewDidLoad()
        // Without the app group there is no session to find, and the sheet
        // says "signed out" rather than failing: a temporary directory
        // stands in for the container.
        let container = StoragePaths.groupContainer
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("matron-share")
        let model = ShareViewModel(environment: .live(container: container))
        self.model = model

        let root = ShareView(
            model: model,
            onCancel: { [weak self] in self?.finish(cancelled: true) },
            onDone: { [weak self] in self?.finish(cancelled: false) })
        let host = UIHostingController(rootView: root)
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)

        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
        Task { await model.load(providers) }
    }

    private func finish(cancelled: Bool) {
        model?.cleanUp()
        if cancelled {
            extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
        } else {
            extensionContext?.completeRequest(returningItems: nil)
        }
    }
}
