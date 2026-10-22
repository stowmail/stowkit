// swift-tools-version:6.0
// Zetetic's official SQLCipher xcframework as a local binary target (D-011).
// The framework is not committed: scripts/fetch-sqlcipher.sh downloads it and
// checks its SHA-256 and Zetetic's code signature. Same contents as
// https://github.com/sqlcipher/SQLCipher.swift (BSD-style licence, see LICENSE.md).

import PackageDescription

let package = Package(
    name: "SQLCipher",
    platforms: [.macOS(.v10_13)],
    products: [
        .library(name: "SQLCipher", targets: ["SQLCipher"]),
    ],
    targets: [
        .binaryTarget(name: "SQLCipher", path: "SQLCipher.xcframework"),
    ]
)
