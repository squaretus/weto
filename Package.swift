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
    ],
    targets: [
        .target(name: "WetoCore", path: "Sources/WetoCore"),
        .target(
            name: "WetoSystem",
            dependencies: ["WetoCore"],
            path: "Sources/WetoSystem"
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
            dependencies: ["WetoCore", "WetoSystem"],
            path: "Sources/WetoShared"
        ),
        .testTarget(
            name: "WetoSharedTests",
            dependencies: ["WetoShared", "WetoCore", "WetoSystem"],
            path: "Tests/WetoSharedTests"
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
