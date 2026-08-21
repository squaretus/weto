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
    dependencies: [
        // Механизм обновления живёт отдельным пакетом: он переносится между
        // проектами целиком, и компилятор не даёт утечь в него weto-типам.
        .package(path: "Packages/UpdateKit"),
    ],
    targets: [
        .target(
            name: "WetoCore",
            dependencies: [.product(name: "UpdateKitCore", package: "UpdateKit")],
            path: "Sources/WetoCore"
        ),
        .target(
            name: "WetoSystem",
            dependencies: ["WetoCore"],
            path: "Sources/WetoSystem"
        ),
        .executableTarget(
            name: "WetoHelper",
            dependencies: [
                "WetoCore",
                .product(name: "UpdateKitCore", package: "UpdateKit"),
                .product(name: "UpdateKitHelper", package: "UpdateKit"),
            ],
            path: "Sources/WetoHelper"
        ),
        .target(
            name: "WetoDesign",
            path: "Sources/WetoDesign",
            // Флаги — `copy`, а не `process`: их 265, они не нуждаются
            // ни в какой обработке, и раскладка каталогом читается дешевле,
            // чем 265 файлов в корне ресурсного бандла.
            resources: [.process("Resources"), .copy("Flags")]
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
            dependencies: [
                "WetoCore", "WetoSystem", "WetoDesign",
                .product(name: "UpdateKitCore", package: "UpdateKit"),
                .product(name: "UpdateKitXPC", package: "UpdateKit"),
                .product(name: "UpdateKit", package: "UpdateKit"),
                .product(name: "UpdateKitUI", package: "UpdateKit"),
            ],
            path: "Sources/WetoShared"
        ),
        .testTarget(
            name: "WetoSharedTests",
            dependencies: [
                "WetoShared", "WetoCore", "WetoSystem", "WetoDesign",
                .product(name: "UpdateKitCore", package: "UpdateKit"),
                .product(name: "UpdateKitXPC", package: "UpdateKit"),
                .product(name: "UpdateKit", package: "UpdateKit"),
                .product(name: "UpdateKitUI", package: "UpdateKit"),
            ],
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
