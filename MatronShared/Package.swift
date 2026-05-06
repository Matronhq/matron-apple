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
    ],
    dependencies: [
        .package(url: "https://github.com/matrix-org/matrix-rust-components-swift", from: "26.04.01"),
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.0"),
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", from: "1.17.0"),
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
                "MatronModels",
                "MatronStorage",
                // Phase 3 Task 6: SasViewModel exposes `SasFlowState` /
                // `SasEmoji` (from `MatronVerification`) on its public
                // surface. Closure-only injection à la RecoveryKeyViewModel
                // doesn't work here because the VM's `state` property is
                // typed `SasFlowState` and views switch on it.
                "MatronVerification",
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
        .testTarget(name: "StorageTests", dependencies: ["MatronStorage"], path: "Tests/StorageTests"),
        .testTarget(name: "AuthTests", dependencies: ["MatronAuth", "MatronModels", "MatronStorage"], path: "Tests/AuthTests"),
        .testTarget(name: "SyncTests", dependencies: ["MatronSync", "MatronModels"], path: "Tests/SyncTests"),
        .testTarget(name: "ChatTests", dependencies: ["MatronChat", "MatronModels", "MatronSync"], path: "Tests/ChatTests"),
        .testTarget(name: "ViewModelTests", dependencies: ["MatronViewModels", "MatronAuth", "MatronChat", "MatronModels", "MatronStorage", "MatronVerification"], path: "Tests/ViewModelTests"),
        .testTarget(
            name: "DesignSystemSnapshotTests",
            dependencies: [
                "MatronDesignSystem",
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
    ]
)
