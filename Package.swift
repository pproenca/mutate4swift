// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "mutate4swift",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "mutate4swift", targets: ["mutate4swift"]),
        .library(name: "MutationEngine", targets: ["MutationEngine"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", from: "600.0.0"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(
            url: "https://github.com/swiftlang/indexstore-db.git",
            revision: "0cd9a889a3d3743bd4d309c8f89ff73a805c6474"
        ),
    ],
    targets: [
        .target(
            name: "MutationEngine",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "IndexStoreDB", package: "indexstore-db"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "mutate4swift",
            dependencies: [
                "MutationEngine",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MutationEngineTests",
            dependencies: ["MutationEngine"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
