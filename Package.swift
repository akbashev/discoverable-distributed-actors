// swift-tools-version: 6.2
import CompilerPluginSupport
import PackageDescription

/// Swift 7 behavior adopted early.
let upcomingFeatures: [SwiftSetting] = [
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let package = Package(
    name: "discoverable-distributed-actors",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .library(name: "DiscoverableActors", targets: ["DiscoverableActors"])
    ],
    dependencies: [
        .package(url: "https://github.com/swiftlang/swift-syntax.git", "509.0.0"..<"605.0.0"),
        // Tests only: a real multi-node actor system, and its logging settings.
        .package(url: "https://github.com/apple/swift-distributed-actors.git", branch: "main"),
        .package(url: "https://github.com/apple/swift-log", from: "1.0.0"),
    ],
    targets: [
        .macro(
            name: "DiscoverableActorsMacros",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftDiagnostics", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ],
            swiftSettings: upcomingFeatures + [.strictMemorySafety()]
        ),
        .target(
            name: "DiscoverableActors",
            dependencies: [
                "DiscoverableActorsMacros"
            ],
            swiftSettings: upcomingFeatures + [.strictMemorySafety()]
        ),
        .testTarget(
            name: "DiscoverableActorsTests",
            dependencies: [
                "DiscoverableActors",
                "DiscoverableActorsMacros",
                .product(name: "DistributedCluster", package: "swift-distributed-actors"),
                .product(name: "Logging", package: "swift-log"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacroExpansion", package: "swift-syntax"),
            ],
            swiftSettings: upcomingFeatures
        ),
    ]
)
