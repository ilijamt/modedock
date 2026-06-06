// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ModeDockKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ModeDockCore", targets: ["ModeDockCore"])
    ],
    targets: [
        .target(name: "ModeDockCore"),
        .testTarget(name: "ModeDockCoreTests", dependencies: ["ModeDockCore"]),
    ]
)
