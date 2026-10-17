import AppKit
import SwiftUI
import MatronModels

/// `MacListHost` in SwiftUI: the host fed from a stream of
/// `ListPublication`s, with its selection bound to SwiftUI state.
///
/// The selection binding is guarded against echo both ways: the user's
/// selection is written to the binding, and the update SwiftUI sends back
/// with that same value does nothing (no re-select, no scroll); a value
/// that really comes from SwiftUI (search, a link, a notification) is a
/// selection from outside, applied without calling back into the binding,
/// and scrolls its row into view.
///
/// The host keeps the rows provider and the stream it was made with; a
/// surface that needs another list gives the view a new identity.
struct MacListView<Rows: MacListRows>: NSViewControllerRepresentable {
    typealias ID = Rows.Row.ID
    typealias Publication = ListPublication<Rows.Row, ID>

    let rows: Rows
    @Binding var selection: Set<ID>
    var style: MacListStyle
    var allowsMultipleSelection: Bool
    var accessibilityIdentifier: String
    /// Called once, when the host is made; the host applies every
    /// publication until it goes away.
    let publications: () -> AsyncStream<Publication>

    init(rows: Rows, selection: Binding<Set<ID>>, style: MacListStyle = .plain,
         allowsMultipleSelection: Bool = false, accessibilityIdentifier: String,
         publications: @escaping () -> AsyncStream<Publication>) {
        self.rows = rows
        self._selection = selection
        self.style = style
        self.allowsMultipleSelection = allowsMultipleSelection
        self.accessibilityIdentifier = accessibilityIdentifier
        self.publications = publications
    }

    /// A single-selection list bound to an optional id.
    init(rows: Rows, selection single: Binding<ID?>, style: MacListStyle = .plain,
         accessibilityIdentifier: String, publications: @escaping () -> AsyncStream<Publication>) {
        self.init(rows: rows,
                  selection: Binding(get: { single.wrappedValue.map { [$0] } ?? [] },
                                     set: { single.wrappedValue = $0.first }),
                  style: style, allowsMultipleSelection: false,
                  accessibilityIdentifier: accessibilityIdentifier, publications: publications)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSViewController(context: Context) -> MacListHost<Rows> {
        let host = MacListHost(rows: rows, style: style, allowsMultipleSelection: allowsMultipleSelection,
                               accessibilityIdentifier: accessibilityIdentifier)
        context.coordinator.attach(host, selection: $selection, publications: publications())
        return host
    }

    func updateNSViewController(_ host: MacListHost<Rows>, context: Context) {
        context.coordinator.selectionBinding = $selection
        context.coordinator.setAllowsMultipleSelection(allowsMultipleSelection)
        context.coordinator.bindingChanged(to: selection)
    }

    static func dismantleNSViewController(_ host: MacListHost<Rows>, coordinator: Coordinator) {
        coordinator.detach()
    }

    /// Owns the publication task and the selection's echo guard.
    @MainActor
    final class Coordinator {
        var selectionBinding: Binding<Set<ID>>?
        private(set) weak var host: MacListHost<Rows>?
        private var task: Task<Void, Never>?
        /// The binding is being written with the host's own selection: an
        /// update SwiftUI runs from inside that write is the echo.
        private var isWritingBinding = false
        /// Binding writes (test seam).
        private(set) var bindingWriteCountForTesting = 0

        func attach(_ host: MacListHost<Rows>, selection: Binding<Set<ID>>,
                    publications: AsyncStream<Publication>) {
            self.host = host
            selectionBinding = selection
            host.selection = selection.wrappedValue
            host.onSelectionChange = { [weak self] ids in self?.hostChanged(ids) }
            task = Task { @MainActor [weak host] in
                for await publication in publications {
                    guard let host else { return }
                    host.apply(publication)
                }
            }
        }

        func detach() {
            task?.cancel()
            task = nil
            host?.onSelectionChange = nil
        }

        /// Inside `updateNSViewController`: a selection the host reports
        /// now is written to SwiftUI after the update, not during it.
        private var isUpdatingView = false
        /// The host's selection waiting to be written. Until it is, a
        /// binding value equal to `staleSelection` is older than the
        /// host's and is not applied; any other value is the parent's own
        /// change and wins.
        private var pendingWrite: Set<ID>?
        private var staleSelection: Set<ID>?

        /// SwiftUI changed the selection mode. Leaving multiple selection
        /// narrows the host, which reports the kept row; SwiftUI's
        /// selection in this same update is still the wider one.
        func setAllowsMultipleSelection(_ multiple: Bool) {
            guard let host, host.allowsMultipleSelection != multiple else { return }
            let before = host.selection
            isUpdatingView = true
            defer { isUpdatingView = false }
            host.allowsMultipleSelection = multiple
            if pendingWrite != nil { staleSelection = before }
        }

        /// The user selected: write it to SwiftUI.
        func hostChanged(_ ids: Set<ID>) {
            if isUpdatingView {
                pendingWrite = ids
                DispatchQueue.main.async { [weak self] in self?.flushPendingWrite() }
                return
            }
            write(ids)
        }

        func flushPendingWrite() {
            guard let ids = pendingWrite else { return }
            pendingWrite = nil
            staleSelection = nil
            write(ids)
        }

        private func write(_ ids: Set<ID>) {
            guard let selectionBinding, selectionBinding.wrappedValue != ids else { return }
            isWritingBinding = true
            defer { isWritingBinding = false }
            bindingWriteCountForTesting += 1
            selectionBinding.wrappedValue = ids
        }

        /// SwiftUI's value: applied unless it is the host's own echo, or
        /// the older value a host selection still waiting to be written
        /// replaces.
        func bindingChanged(to value: Set<ID>) {
            guard !isWritingBinding, let host else { return }
            if pendingWrite != nil {
                if value == staleSelection { return }
                pendingWrite = nil
                staleSelection = nil
            }
            guard host.selection != value else { return }
            host.selection = value
        }
    }
}
