// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "weto",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "WetoCore", targets: ["WetoCore"]),
        .library(name: "WetoSystem", targets: ["WetoSystem"]),
        .library(name: "WetoShared", targets: ["WetoShared"]),
        .library(name: "WetoDesign", targets: ["WetoDesign"]),
        .library(name: "WetoXPC", targets: ["WetoXPC"]),
    ],
    targets: [
        .target(name: "WetoCore", path: "Sources/WetoCore"),
        .target(
            name: "WetoSystem",
            dependencies: ["WetoCore"],
            path: "Sources/WetoSystem"
        ),
        .target(
            name: "WetoXPC",
            dependencies: ["WetoCore"],
            path: "Sources/WetoXPC"
        ),
        .executableTarget(
            name: "WetoHelper",
            dependencies: ["WetoCore", "WetoXPC"],
            path: "Sources/WetoHelper"
        ),
        .target(
            name: "WetoDesign",
            path: "Sources/WetoDesign",
            resources: [.process("Resources")]
        ),
        .executableTarget(
            name: "WetoMenuBar",
            dependencies: [
                "WetoCore", "WetoSystem", "WetoShared", "WetoDesign",
            ],
            path: "Sources/WetoMenuBar"
        ),
        .testTarget(
            name: "WetoDesignTests",
            dependencies: ["WetoDesign"],
            path: "Tests/WetoDesignTests"
        ),
        .target(
            name: "WetoShared",
            dependencies: ["WetoCore", "WetoSystem", "WetoXPC"],
            path: "Sources/WetoShared"
        ),
        .testTarget(
            name: "WetoSharedTests",
            dependencies: ["WetoShared", "WetoCore", "WetoSystem", "WetoXPC"],
            path: "Tests/WetoSharedTests"
        ),
        .testTarget(
            name: "WetoXPCTests",
            dependencies: ["WetoXPC", "WetoCore"],
            path: "Tests/WetoXPCTests"
        ),
        .testTarget(
            name: "WetoCoreTests",
            dependencies: ["WetoCore"],
            path: "Tests/WetoCoreTests"
        ),
        .testTarget(
            name: "WetoSystemTests",
            dependencies: ["WetoSystem", "WetoCore"],
            path: "Tests/WetoSystemTests"
        ),
    ]
)
