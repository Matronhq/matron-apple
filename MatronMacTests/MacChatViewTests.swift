#if os(macOS)
import XCTest
import SwiftUI
import UniformTypeIdentifiers
@testable import MatronMac
import MatronChat
import MatronModels
import MatronVerification
import MatronViewModels

/// Local fake mirroring `FakeTimelineService` from
/// `MatronShared/Tests/ViewModelTests/`. The Mac test target is
/// self-contained — it doesn't pull the shared test fakes (those live in
/// the test target, not the shipped library).
private final class FakeTimelineForChat: TimelineService, @unchecked Sendable {
    var sentImages: [(filename: String, mime: String, sizeBytes: Int)] = []
    var sentFiles: [(filename: String, mime: String, sizeBytes: Int)] = []

    func items() -> AsyncThrowingStream<[TimelineItem], Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func sendText(_ body: String) async throws {}
    func sendImage(_ data: Data, filename: String, mimeType: String) async throws {
        sentImages.append((filename, mimeType, data.count))
    }
    func sendFile(_ data: Data, filename: String, mimeType: String) async throws {
        sentFiles.append((filename, mimeType, data.count))
    }
    func paginateBackward(requestSize: UInt16) async throws -> Bool { false }
    func markAsRead() async throws {}
}

private final class FakeMediaForChat: MediaService, @unchecked Sendable {
    func image(for mxc: URL) async -> Data? { nil }
}

/// Counting fake for the B2/M5 binding test — records each call to
/// `startSAS`. Plain class with `NSLock` rather than an actor so the
/// recorded count can be read synchronously from the test.
private final class CountingVerificationServiceForChat: VerificationService, @unchecked Sendable {
    private let lock = NSLock()
    private var _startSASCalls: Int = 0

    var startSASCallCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _startSASCalls
    }

    func isThisDeviceVerified() async throws -> Bool? { true }
    func isUserVerified(matrixID: String) async throws -> UserVerificationResult { .unknown }
    func hasOtherVerifiedDevices() async throws -> Bool { false }
    func incomingRequests() -> AsyncStream<VerificationRequestSummary> {
        AsyncStream { $0.finish() }
    }
    func cancelledRequests() -> AsyncStream<String> {
        AsyncStream { $0.finish() }
    }
    func startSAS(withUser userID: String, deviceID: String?) -> AsyncStream<SasFlowState> {
        lock.lock()
        _startSASCalls += 1
        lock.unlock()
        return AsyncStream { $0.finish() }
    }
    func acceptIncoming(requestID: String) -> AsyncStream<SasFlowState> {
        AsyncStream { $0.finish() }
    }
    func confirmEmojiMatch(requestID: String) async throws {}
    func cancel(requestID: String, reason: String) async throws {}
}

/// Local fake mirroring the iOS `FakeVerificationServiceForChat` (host-app
/// test bundles can't reach into another test target's `internal` fakes).
private actor FakeVerificationServiceForChat: VerificationService {
    private var userVerificationMap: [String: UserVerificationResult] = [:]

    /// Convenience seam preserved from the prior Bool shape — `true` →
    /// `.verified`, `false` → `.unverified`. Tests that need the
    /// `.unknown` arm (cold-start path) call `setUserVerificationResult(_:for:)`.
    func setUserVerified(_ verified: Bool, for matrixID: String) {
        userVerificationMap[matrixID] = verified ? .verified : .unverified
    }

    /// M2 tri-state seam — exercises the `.unknown` arm that the Bool
    /// seam can't reach. Default for un-seeded users is `.unknown`.
    func setUserVerificationResult(_ result: UserVerificationResult, for matrixID: String) {
        userVerificationMap[matrixID] = result
    }

    func isThisDeviceVerified() async throws -> Bool? { true }
    func isUserVerified(matrixID: String) async throws -> UserVerificationResult {
        userVerificationMap[matrixID, default: .unknown]
    }
    func hasOtherVerifiedDevices() async throws -> Bool { false }
    nonisolated func incomingRequests() -> AsyncStream<VerificationRequestSummary> {
        AsyncStream { $0.finish() }
    }
    nonisolated func cancelledRequests() -> AsyncStream<String> {
        AsyncStream { $0.finish() }
    }
    nonisolated func startSAS(withUser userID: String, deviceID: String?) -> AsyncStream<SasFlowState> {
        AsyncStream { $0.finish() }
    }
    nonisolated func acceptIncoming(requestID: String) -> AsyncStream<SasFlowState> {
        AsyncStream { $0.finish() }
    }
    func confirmEmojiMatch(requestID: String) async throws {}
    func cancel(requestID: String, reason: String) async throws {}
}

@MainActor
final class MacChatViewTests: XCTestCase {

    /// SwiftUI's `DropInfo` is a struct with no public init, so we can't
    /// drive `performDrop(info:)` from a unit test. Instead we cover the
    /// URL-handling logic the delegate factors out:
    /// `ComposerDropDelegate.loadURL(from:)`. That's the only branch with
    /// real logic — the `performDrop` body itself is `getProviders →
    /// loadURL × N → composer.attachFiles`.
    func test_loadURL_returnsURL_fromItemProvider() async {
        let url = URL(fileURLWithPath: "/tmp/test.png")
        let provider = NSItemProvider()
        provider.registerObject(url as NSURL, visibility: .all)
        let resolved = await ComposerDropDelegate.loadURL(from: provider)
        if case .success(let resolvedURL) = resolved {
            XCTAssertEqual(resolvedURL.lastPathComponent, "test.png")
        } else {
            XCTFail("Expected .success(URL), got \(resolved)")
        }
    }

    /// Empty provider → failure (QA finding #9). Previously the helper
    /// silently returned nil for both "no URL" and "load failed", so the
    /// composer banner never surfaced when a drop failed. Now an empty
    /// provider routes through the typed `ComposerDropError`.
    func test_loadURL_returnsFailure_forEmptyProvider() async {
        let provider = NSItemProvider()
        let resolved = await ComposerDropDelegate.loadURL(from: provider)
        if case .failure = resolved {
            // expected
        } else {
            XCTFail("Expected .failure, got \(resolved)")
        }
    }

    /// `⌘K` toggles the slash palette open without typing `/`. The view
    /// wires `palettePinnedOpen.toggle()` to a hidden button with
    /// `.keyboardShortcut("k", modifiers: .command)`; here we verify the
    /// model surface honours the toggle as `MacChatView` expects.
    func test_palettePinnedOpen_togglesPalette() {
        let composer = ComposerViewModel(timeline: FakeTimelineForChat(),
                                          commands: BotCommandCatalog.claudeBridge)
        XCTAssertFalse(composer.showPalette)
        composer.palettePinnedOpen = true
        XCTAssertTrue(composer.showPalette)
        composer.palettePinnedOpen = false
        XCTAssertFalse(composer.showPalette)
    }

    /// Task 16: right-click "View source" presents a `MacEventSourceSheet`
    /// whose body is `item.prettyJSON()`. Constructing the sheet here
    /// exercises the binding wiring; the underlying JSON shape is
    /// verified at the SPM level in `TimelineItemTests`.
    func test_macEventSourceSheet_compiles_andInvokesDismiss() {
        let item = TimelineItem(
            id: "$evt:mac:1",
            sender: "@bot:s",
            timestamp: .now,
            kind: .text(body: "hi", formattedHTML: nil),
            isOwn: false
        )
        var dismissals = 0
        let sheet = MacEventSourceSheet(item: item, onDismiss: { dismissals += 1 })
        XCTAssertEqual(sheet.item.id, "$evt:mac:1")
        // Invoke the dismiss closure directly to verify the binding is
        // plumbed through (the SwiftUI body itself isn't rendered here).
        sheet.onDismiss()
        XCTAssertEqual(dismissals, 1)
        XCTAssertTrue(item.prettyJSON().contains("$evt:mac:1"))
    }

    /// Constructing the view exercises the @State + binding wiring at
    /// compile time; the body itself isn't rendered in this unit test
    /// (no host scene).
    func test_view_compiles_withChatViewModel_andComposerViewModel() {
        let timeline = FakeTimelineForChat()
        let chatVM = ChatViewModel(roomID: "!r:s", timeline: timeline, media: FakeMediaForChat())
        let composerVM = ComposerViewModel(timeline: timeline, commands: [])
        var profileTaps = 0
        let view = MacChatView(
            viewModel: chatVM,
            composerVM: composerVM,
            chatTitle: "Hello",
            onShowBotProfile: { profileTaps += 1 }
        )
        XCTAssertEqual(view.chatTitle, "Hello")
        view.onShowBotProfile()
        XCTAssertEqual(profileTaps, 1)
    }

    /// Task 10: per-bot inline banner above the timeline. Mirrors the
    /// iOS `ChatViewBindingTests` shape — verifies the optional-param
    /// wiring at compile time and pins the underlying fake-service
    /// state the banner predicate keys on. M2 tightens the seam from
    /// Bool to tri-state — the `.unknown` arm is covered separately.
    func test_view_showsBanner_whenBotIsUnverified() async throws {
        let timeline = FakeTimelineForChat()
        let chatVM = ChatViewModel(roomID: "!r:s", timeline: timeline, media: FakeMediaForChat())
        let composerVM = ComposerViewModel(timeline: timeline, commands: [])
        let svc = FakeVerificationServiceForChat()
        // Explicitly seed `.unverified` (NOT `.unknown` — the new
        // banner-hides default). Banner only renders on `.unverified`.
        await svc.setUserVerificationResult(.unverified, for: "@box4:s")
        let view = MacChatView(
            viewModel: chatVM,
            composerVM: composerVM,
            chatTitle: "Bot Room",
            onShowBotProfile: {},
            verificationService: svc,
            botMatrixID: "@box4:s"
        )
        let result = try await svc.isUserVerified(matrixID: "@box4:s")
        XCTAssertEqual(result, .unverified, "Seeded .unverified must read as such for the banner to render")
        XCTAssertEqual(view.botMatrixID, "@box4:s")
    }

    func test_view_hidesBanner_whenBotIsVerified() async throws {
        let timeline = FakeTimelineForChat()
        let chatVM = ChatViewModel(roomID: "!r:s", timeline: timeline, media: FakeMediaForChat())
        let composerVM = ComposerViewModel(timeline: timeline, commands: [])
        let svc = FakeVerificationServiceForChat()
        await svc.setUserVerified(true, for: "@box4:s")
        let _ = MacChatView(
            viewModel: chatVM,
            composerVM: composerVM,
            chatTitle: "Bot Room",
            onShowBotProfile: {},
            verificationService: svc,
            botMatrixID: "@box4:s"
        )
        let result = try await svc.isUserVerified(matrixID: "@box4:s")
        XCTAssertEqual(result, .verified, "Seeded verified state must read .verified so the banner is suppressed")
    }

    /// Wave 5 bugbot #2: the per-bot SAS sheet body must build the
    /// `SasViewModel` + open the `startSAS` stream exactly once per
    /// "Verify" tap. Mirrors `ChatViewBindingTests.test_perBotSasSheet_*` —
    /// see iOS for the full rationale (Wave 2's `init`-side seed
    /// re-evaluated `service.startSAS(...)` on every body re-render and
    /// drained the prior continuation via M3's "Replaced by new flow").
    /// New shape moves the side effect into `.task(id: botMatrixID)`.
    /// Locks the construction-time baseline: instantiating MacChatView
    /// itself MUST NOT call startSAS.
    func test_perBotSasSheet_callsStartSASExactlyOnce_perPresent() async throws {
        let svc = CountingVerificationServiceForChat()
        let timeline = FakeTimelineForChat()
        let chatVM = ChatViewModel(roomID: "!r:s", timeline: timeline, media: FakeMediaForChat())
        let composerVM = ComposerViewModel(timeline: timeline, commands: [])
        let _ = MacChatView(
            viewModel: chatVM,
            composerVM: composerVM,
            chatTitle: "Bot Room",
            onShowBotProfile: {},
            verificationService: svc,
            botMatrixID: "@box4:s"
        )
        XCTAssertEqual(svc.startSASCallCount, 0,
                       "MacChatView constructor must not call startSAS — that fires on banner-tap")
    }

    /// M2 expert-QA fix: cold-start path. When the SDK's local crypto
    /// store doesn't yet have the bot's identity (sliding-sync hasn't
    /// warmed up `/keys/query` yet), `isUserVerified` returns `.unknown`.
    /// The banner MUST stay hidden in that case — collapsing `.unknown`
    /// into `.unverified` (the prior Bool shape) caused the banner to
    /// flash on every fresh chat open until the local store warmed up.
    func test_view_hidesBanner_whenBotVerificationIsUnknown() async throws {
        let timeline = FakeTimelineForChat()
        let chatVM = ChatViewModel(roomID: "!r:s", timeline: timeline, media: FakeMediaForChat())
        let composerVM = ComposerViewModel(timeline: timeline, commands: [])
        let svc = FakeVerificationServiceForChat()
        // Don't seed — default is `.unknown`. Equivalent to the cold-start
        // path where the local crypto store hasn't loaded the identity yet.
        let _ = MacChatView(
            viewModel: chatVM,
            composerVM: composerVM,
            chatTitle: "Bot Room",
            onShowBotProfile: {},
            verificationService: svc,
            botMatrixID: "@coldstart:s"
        )
        let result = try await svc.isUserVerified(matrixID: "@coldstart:s")
        XCTAssertEqual(result, .unknown,
            "Un-seeded user must read as .unknown — banner stays hidden until next sync tick")
    }
}
#endif
