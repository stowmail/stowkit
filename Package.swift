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
        .executable(name: "stowmail", targets: ["stowmail"]),
    ],
    dependencies: [
        // Pre-1.0: pin to the minor version. Newer versions need macOS 15 (D-013).
        .package(url: "https://github.com/apple/swift-nio-imap.git", .upToNextMinor(from: "0.4.0")),
        .package(url: "https://github.com/apple/swift-nio-transport-services.git", from: "1.28.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.16.2"),
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
        .target(name: "StowMCP", dependencies: ["StowCore", "StowSecrets"]),
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
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .testTarget(name: "StowCoreTests", dependencies: ["StowCore"]),
        .testTarget(name: "StowSecretsTests", dependencies: ["StowSecrets"]),
        .testTarget(name: "StowSyncTests", dependencies: ["StowSync"]),
        .testTarget(name: "StowStoreTests", dependencies: ["StowStore", .product(name: "GRDB", package: "GRDB")]),
        .testTarget(name: "StowSearchTests", dependencies: ["StowSearch", "StowStore", "StowSecrets", .product(name: "GRDB", package: "GRDB")]),
        .testTarget(name: "StowRulesTests", dependencies: ["StowRules"]),
        .testTarget(name: "StowMCPTests", dependencies: ["StowMCP"]),
    ],
    swiftLanguageModes: [.v6]
)
