// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MatronShared",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "MatronAuth", targets: ["MatronAuth"]),
        .library(name: "MatronChat", targets: ["MatronChat"]),
        .library(name: "MatronStorage", targets: ["MatronStorage"]),
        .library(name: "MatronSync", targets: ["MatronSync"]),
        .library(name: "MatronModels", targets: ["MatronModels"]),
        .library(name: "MatronViewModels", targets: ["MatronViewModels"]),
        .library(name: "MatronDesignSystem", targets: ["MatronDesignSystem"]),
        .library(name: "MatronVerification", targets: ["MatronVerification"]),
        .library(name: "MatronPush", targets: ["MatronPush"]),
        .library(name: "MatronEvents", targets: ["MatronEvents"]),
        .library(name: "MatronSearch", targets: ["MatronSearch"]),
    ],
    dependencies: [
        .package(url: "https://github.com/matrix-org/matrix-rust-components-swift", from: "26.04.01"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.0"),
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.17.0"),
        // Phase 6 (Search): GRDB wraps SQLite with FTS5 + WAL + Data Protection
        // support — easier than raw sqlite3 for the content-table FTS5 index.
        // Pinned to 6.x (`from: 6.29.0` excludes 7.0) because GRDB 7 requires the
        // Swift 6 language mode; this package builds in the 5.10 mode.
        .package(url: "https://github.com/groue/GRDB.swift", from: "6.29.0"),
    ],
    targets: [
        .target(name: "MatronModels", path: "Sources/Models"),
        .target(name: "MatronStorage", path: "Sources/Storage"),
        .target(
            name: "MatronAuth",
            dependencies: [
                "MatronModels",
                "MatronStorage",
                .product(name: "MatrixRustSDK", package: "matrix-rust-components-swift"),
            ],
            path: "Sources/Auth"
        ),
        .target(
            name: "MatronSync",
            dependencies: [
                "MatronModels",
                "MatronStorage",
                .product(name: "MatrixRustSDK", package: "matrix-rust-components-swift"),
            ],
            path: "Sources/Sync"
        ),
        .target(
            name: "MatronChat",
            dependencies: [
                "MatronModels",
                "MatronSync",
                // Phase 5 Task 5: TimelineItem.Kind gains `.toolCall` /
                // `.askUser` cases that wrap MatronEvents DTOs. The
                // dependency only pulls in pure value types — no
                // SwiftUI, no SDK FFI — so MatronChat stays the same
                // weight as before.
                "MatronEvents",
                // Phase 6 (Search): TimelineServiceLive's snapshot listener
                // indexes decrypted `.text` / tool-call bodies into the
                // SearchService. MatronSearch is a leaf w.r.t. MatronChat
                // (it depends on Models/Storage/Sync/SDK, never Chat) so this
                // adds no cycle.
                "MatronSearch",
                .product(name: "MatrixRustSDK", package: "matrix-rust-components-swift"),
            ],
            path: "Sources/Chat"
        ),
        // ViewModels live in MatronShared from day 1 so both Matron (iOS) and
        // MatronMac can import the same @Observable types. No SwiftUI Views
        // here — only Foundation + service-layer dependencies.
        .target(
            name: "MatronViewModels",
            dependencies: [
                "MatronAuth",
                "MatronChat",
                // Phase 5: AskUserSheetViewModel consumes the
                // AskUserEvent DTO directly.
                "MatronEvents",
                "MatronModels",
                "MatronStorage",
                // Phase 3 Task 6: SasViewModel exposes `SasFlowState` /
                // `SasEmoji` (from `MatronVerification`) on its public
                // surface. Closure-only injection à la RecoveryKeyViewModel
                // doesn't work here because the VM's `state` property is
                // typed `SasFlowState` and views switch on it.
                "MatronVerification",
                // Phase 6 (Search): SearchViewModel drives both iOS and Mac
                // search chrome and refers to SearchService / SearchHit.
                "MatronSearch",
            ],
            path: "Sources/ViewModels"
        ),
        // DesignSystem starts empty in Phase 1 — primitives (MarkdownText,
        // CodeBlock, ToolCallCard, etc.) land in Phase 2. Declaring the target
        // now means Phase 2 just adds source files; no Package.swift churn.
        .target(
            name: "MatronDesignSystem",
            dependencies: [
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
                // `StateBridges.swift` is the single source of truth
                // for service-layer → design-system enum mappings:
                // `SyncBannerState.from(_:)` (uses `SyncConnectionState`
                // from `MatronSync`) and `SendStateGlyph.from(_:)` (uses
                // `TimelineSendState` from `MatronModels`). Both deps
                // are leaf modules with no SwiftUI / SDK surface, so
                // the bridges live next to the target enums without
                // creating a cycle or pulling MatrixRustSDK.
                "MatronModels",
                "MatronSync",
                // Phase 5: ToolCallCard / AskUserSheetBody /
                // SessionMetaHeader render the MatronEvents DTOs
                // directly. MatronEvents is a leaf module (Foundation
                // only), so the design-system target still pulls no
                // SDK surface.
                "MatronEvents",
                // Phase 6 (Search): SearchResultRow renders a SearchHit
                // (snippet with <mark> highlighting), shared by iOS + Mac.
                "MatronSearch",
            ],
            path: "Sources/DesignSystem"
        ),
        // Verification target wraps the SDK's E2EE / SAS surface. Phase 3
        // Task 1 lands DTOs only; later tasks layer on the protocol, live
        // impl, recovery key manager, and observers.
        .target(
            name: "MatronVerification",
            dependencies: [
                "MatronModels",
                "MatronStorage",
                "MatronSync",
                .product(name: "MatrixRustSDK", package: "matrix-rust-components-swift"),
            ],
            path: "Sources/Verification"
        ),
        // Phase 4 Task 1: Push protocol surface + (Task 2) the live
        // SDK-bridging impl + (Task 3) the cross-platform PushDecoder.
        // Depends on Sync for `ClientProvider` (Task 2's PushServiceLive
        // resolves a `Client` per-session) and on the SDK for the
        // notification-client APIs. Mac and iOS NSE both link this.
        .target(
            name: "MatronPush",
            dependencies: [
                // Phase 5 Task 12: PushDecoder reads the
                // MatronEventType constants for the notification-body
                // hints (tool_call / ask_user / buttons).
                "MatronEvents",
                "MatronModels",
                "MatronStorage",
                "MatronSync",
                .product(name: "MatrixRustSDK", package: "matrix-rust-components-swift"),
            ],
            path: "Sources/Push"
        ),
        // Phase 5 Task 1: parsers + DTOs for the three Matron-specific
        // event types (`chat.matron.tool_call`, `.ask_user`,
        // `.session_meta`). Pure value types — no SwiftUI, no SDK FFI —
        // so this target stays a leaf. The SDK-side mapping lives in
        // `MatronChat`'s `TimelineServiceLive` (which depends on this
        // target via the Phase 5 Task 6 wiring).
        .target(
            name: "MatronEvents",
            dependencies: ["MatronModels"],
            path: "Sources/Events"
        ),
        // Phase 6 (Search): local SQLite FTS5 index + per-room backfill.
        // The schema, service, models, and BackfillRunner are pure (GRDB +
        // Foundation) and fully unit-tested. Only `TimelinePagerLive` touches
        // the SDK — it wraps `Timeline.paginateBackwards`, so the target also
        // needs MatronSync (ClientProvider/UserSession) + MatrixRustSDK. The
        // rest of MatronSearch stays SDK-agnostic so BackfillRunner is testable
        // against a fake pager.
        .target(
            name: "MatronSearch",
            dependencies: [
                "MatronModels",
                "MatronStorage",
                "MatronSync",
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "MatrixRustSDK", package: "matrix-rust-components-swift"),
            ],
            path: "Sources/Search"
        ),
        .testTarget(name: "StorageTests", dependencies: ["MatronStorage"], path: "Tests/StorageTests"),
        .testTarget(name: "AuthTests", dependencies: ["MatronAuth", "MatronModels", "MatronStorage"], path: "Tests/AuthTests"),
        .testTarget(name: "SyncTests", dependencies: ["MatronSync", "MatronModels"], path: "Tests/SyncTests"),
        .testTarget(name: "ChatTests", dependencies: ["MatronChat", "MatronEvents", "MatronModels", "MatronSync"], path: "Tests/ChatTests"),
        .testTarget(name: "ViewModelTests", dependencies: ["MatronViewModels", "MatronAuth", "MatronChat", "MatronEvents", "MatronModels", "MatronStorage", "MatronVerification", "MatronSearch"], path: "Tests/ViewModelTests"),
        .testTarget(
            name: "DesignSystemSnapshotTests",
            dependencies: [
                "MatronDesignSystem",
                "MatronEvents",
                "MatronModels",
                "MatronSync",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing"),
            ],
            path: "Tests/DesignSystemSnapshotTests"
        ),
        .testTarget(
            name: "VerificationTests",
            dependencies: ["MatronVerification", "MatronModels", "MatronStorage"],
            path: "Tests/VerificationTests"
        ),
        .testTarget(
            name: "PushTests",
            dependencies: ["MatronPush"],
            path: "Tests/PushTests"
        ),
        .testTarget(
            name: "EventsTests",
            dependencies: ["MatronEvents", "MatronModels"],
            path: "Tests/EventsTests"
        ),
        .testTarget(name: "SearchTests", dependencies: ["MatronSearch"], path: "Tests/SearchTests"),
    ]
)
