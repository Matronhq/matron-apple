// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "MatronShared",
    platforms: [.iOS(.v17), .macOS(.v12)],
    products: [
        .library(name: "MatronAuth", targets: ["MatronAuth"]),
        .library(name: "MatronChat", targets: ["MatronChat"]),
        .library(name: "MatronStorage", targets: ["MatronStorage"]),
        .library(name: "MatronSync", targets: ["MatronSync"]),
        .library(name: "MatronModels", targets: ["MatronModels"]),
    ],
    dependencies: [
        .package(url: "https://github.com/matrix-org/matrix-rust-components-swift", from: "26.04.01"),
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
        .testTarget(name: "StorageTests", dependencies: ["MatronStorage"], path: "Tests/StorageTests"),
        .testTarget(name: "AuthTests", dependencies: ["MatronAuth"], path: "Tests/AuthTests"),
        .testTarget(name: "SyncTests", dependencies: ["MatronSync"], path: "Tests/SyncTests"),
        .testTarget(name: "ChatTests", dependencies: ["MatronChat"], path: "Tests/ChatTests"),
    ]
)
