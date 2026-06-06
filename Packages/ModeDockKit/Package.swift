// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ModeDockKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ModeDockCore", targets: ["ModeDockCore"]),
        .library(name: "DisplayKit", targets: ["DisplayKit"]),
    ],
    targets: [
        .target(name: "PrivateAPI"),
        .target(name: "DisplayKit", dependencies: ["PrivateAPI"]),
        .target(name: "ModeDockCore", dependencies: ["DisplayKit"]),
        .testTarget(name: "DisplayKitTests", dependencies: ["DisplayKit"]),
        .testTarget(name: "ModeDockCoreTests", dependencies: ["ModeDockCore"]),
    ]
)
