// swift-tools-version: 6.2
import CompilerPluginSupport
import PackageDescription

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
        // Tests only: a real multi-node actor system.
        .package(url: "https://github.com/apple/swift-distributed-actors.git", branch: "main"),
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
            ]
        ),
        .target(
            name: "DiscoverableActors",
            dependencies: [
                "DiscoverableActorsMacros"
            ]
        ),
        .testTarget(
            name: "DiscoverableActorsTests",
            dependencies: [
                "DiscoverableActors",
                .product(name: "DistributedCluster", package: "swift-distributed-actors"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
