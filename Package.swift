// swift-tools-version:6.1
// StowKit: the Stow engine. See README.md for the module dependency rule.

import PackageDescription

let package = Package(
    name: "StowKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "StowCore", targets: ["StowCore"]),
        .library(name: "StowSecrets", targets: ["StowSecrets"]),
        .library(name: "StowSync", targets: ["StowSync"]),
        .library(name: "StowStore", targets: ["StowStore"]),
        .library(name: "StowSearch", targets: ["StowSearch"]),
        .library(name: "StowRules", targets: ["StowRules"]),
        .library(name: "StowMCP", targets: ["StowMCP"]),
        .library(name: "StowEngine", targets: ["StowEngine"]),
        .executable(name: "stowmail", targets: ["stowmail"]),
    ],
    dependencies: [
        // Pre-1.0: pin to the minor version. Newer versions need macOS 15 (D-013).
        .package(url: "https://github.com/apple/swift-nio-imap.git", .upToNextMinor(from: "0.4.0")),
        .package(url: "https://github.com/apple/swift-nio-transport-services.git", from: "1.28.0"),
        // Already pulled in by the two packages above; named directly because StowSync uses NIOCore (D-101).
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.104.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.16.2"),
        // Official MCP SDK, stdio transport only. Pre-1.0: pin to the minor version (D-080).
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", .upToNextMinor(from: "0.12.1")),
        // GRDB built against SQLCipher, vendored by scripts/vendor-grdb.sh (D-011).
        .package(path: "Vendor/GRDB"),
    ],
    targets: [
        // Shared types and protocols. No package dependencies.
        .target(name: "StowCore"),
        .target(name: "StowSecrets", dependencies: ["StowCore"]),
        .target(
            name: "StowSync",
            dependencies: [
                "StowCore",
                "StowSecrets",
                .product(name: "NIOIMAP", package: "swift-nio-imap"),
                .product(name: "NIOTransportServices", package: "swift-nio-transport-services"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .target(
            name: "StowStore",
            dependencies: [
                "StowCore",
                "StowSecrets",
                .product(name: "GRDB", package: "GRDB"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .target(
            name: "StowSearch",
            dependencies: [
                "StowCore",
                "StowSecrets",
                "StowStore",
                .product(name: "GRDB", package: "GRDB"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .target(
            name: "StowRules",
            dependencies: ["StowCore"],
            resources: [.copy("Resources/rules-data.json")]
        ),
        .target(
            name: "StowMCP",
            dependencies: [
                "StowCore",
                "StowSecrets",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        // Joins sync, storage and rules: the scheduler, the daemon and everything
        // the CLI and the app both drive. Like the CLI, it may depend on every module (D-026).
        .target(
            name: "StowEngine",
            dependencies: [
                "StowCore",
                "StowSecrets",
                "StowSync",
                "StowStore",
                "StowSearch",
                "StowRules",
                .product(name: "GRDB", package: "GRDB"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .executableTarget(
            name: "stowmail",
            dependencies: [
                "StowCore",
                "StowSecrets",
                "StowSync",
                "StowStore",
                "StowSearch",
                "StowRules",
                "StowMCP",
                "StowEngine",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        // Test helpers shared by several test targets: the fake IMAP server and fixtures. Never shipped.
        .target(name: "StowTestSupport", dependencies: ["StowCore"], path: "Tests/StowTestSupport"),
        .testTarget(name: "StowCoreTests", dependencies: ["StowCore"]),
        .testTarget(name: "StowSecretsTests", dependencies: ["StowSecrets"]),
        .testTarget(
            name: "StowSyncTests",
            dependencies: [
                "StowSync",
                "StowCore",
                "StowSecrets",
                "StowTestSupport",
                .product(name: "NIOIMAP", package: "swift-nio-imap"),
                .product(name: "NIOCore", package: "swift-nio"),
            ]
        ),
        .testTarget(name: "StowStoreTests", dependencies: ["StowStore", .product(name: "GRDB", package: "GRDB")]),
        .testTarget(name: "StowSearchTests", dependencies: ["StowSearch", "StowStore", "StowSecrets", .product(name: "GRDB", package: "GRDB")]),
        .testTarget(name: "StowRulesTests", dependencies: ["StowRules"]),
        .testTarget(
            name: "StowMCPTests",
            dependencies: [
                "StowMCP", "StowCore", "StowEngine", "StowSearch", "StowStore", "StowSecrets",
                .product(name: "MCP", package: "swift-sdk"),
                .product(name: "GRDB", package: "GRDB"),
            ]
        ),
        .testTarget(
            name: "StowEngineTests",
            dependencies: [
                "StowEngine", "StowSync", "StowStore", "StowSearch", "StowRules", "StowSecrets", "StowCore", "StowTestSupport",
                .product(name: "GRDB", package: "GRDB"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
