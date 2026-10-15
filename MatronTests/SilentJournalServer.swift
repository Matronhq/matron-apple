import Foundation

/// A journal server that never answers, for tests that render the real
/// shell with `AppDependencies()`. Its session points at a host that does
/// not exist, so every refresh the shell starts used to fail, at a moment
/// set by the runner's DNS. A failure is no quiet log line: the Projects
/// and For you view models put it up as an alert, and a push that lands
/// while that alert is presenting is dropped by UIKit ("setViewControllers
/// … while an existing transition or presentation is occurring"). The
/// path says the page is pushed; the stack never shows it.
///
/// With this installed a request simply waits, as on a slow network, until
/// `uninstall()` fails it as cancelled. Nothing the shell tests check
/// depends on an answer, and nothing presents over them.
final class SilentJournalServer: URLProtocol {
    private static let lock = NSLock()
    private static var waiting: [SilentJournalServer] = []

    static func install() {
        URLProtocol.registerClass(SilentJournalServer.self)
    }

    /// Unregisters, then fails what is still waiting so no request (or the
    /// task awaiting it) outlives the test.
    static func uninstall() {
        URLProtocol.unregisterClass(SilentJournalServer.self)
        let pending = lock.withLock { () -> [SilentJournalServer] in
            defer { waiting = [] }
            return waiting
        }
        for request in pending { request.failFromItsOwnThread() }
    }

    /// The loading thread, for the client calls: URL loading expects them
    /// on the thread that called `startLoading()`.
    private var thread: Thread?

    private func failFromItsOwnThread() {
        guard let thread else { return }
        perform(#selector(fail), on: thread, with: nil, waitUntilDone: false,
                modes: [RunLoop.Mode.common.rawValue])
    }

    @objc private func fail() {
        client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
    }

    override class func canInit(with request: URLRequest) -> Bool {
        ["http", "https"].contains(request.url?.scheme)
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        thread = .current
        Self.lock.withLock { Self.waiting.append(self) }
    }

    override func stopLoading() {
        Self.lock.withLock { Self.waiting.removeAll { $0 === self } }
    }
}
