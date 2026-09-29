// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "LingoMend",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "CoachCore", targets: ["CoachCore"]),
        .library(name: "LearningCore", targets: ["LearningCore"]),
        .library(name: "PlatformBridge", targets: ["PlatformBridge"]),
        .library(name: "MVPFlow", targets: ["MVPFlow"]),
        .executable(name: "LingoMendApp", targets: ["LingoMendApp"])
    ],
    targets: [
        .target(name: "CoachCore"),
        .target(
            name: "LearningCore",
            dependencies: ["CoachCore"]
        ),
        .target(name: "PlatformBridge"),
        .target(
            name: "MVPFlow",
            dependencies: ["CoachCore", "PlatformBridge"]
        ),
        .executableTarget(
            name: "LingoMendApp",
            dependencies: ["CoachCore", "LearningCore", "MVPFlow", "PlatformBridge"]
        ),
        .testTarget(
            name: "CoachCoreTests",
            dependencies: ["CoachCore"]
        ),
        .testTarget(
            name: "LearningCoreTests",
            dependencies: ["CoachCore", "LearningCore"]
        ),
        .testTarget(
            name: "PlatformBridgeTests",
            dependencies: ["PlatformBridge"]
        ),
        .testTarget(
            name: "MVPFlowTests",
            dependencies: ["CoachCore", "MVPFlow", "PlatformBridge"]
        )
    ]
)
