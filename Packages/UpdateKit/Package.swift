// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "UpdateKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "UpdateKitCore", targets: ["UpdateKitCore"]),
        .library(name: "UpdateKitXPC", targets: ["UpdateKitXPC"]),
        .library(name: "UpdateKitHelper", targets: ["UpdateKitHelper"]),
        .library(name: "UpdateKit", targets: ["UpdateKit"]),
    ],
    targets: [
        // Ноль I/O: политика, версии, разбор ответа GitHub, тексты.
        .target(name: "UpdateKitCore"),
        // Зависимостей нет намеренно: через границу демона ходят только
        // числа и строки, доменные типы её не пересекают.
        .target(name: "UpdateKitXPC"),
        .target(name: "UpdateKitHelper", dependencies: ["UpdateKitCore", "UpdateKitXPC"]),
        .target(name: "UpdateKit", dependencies: ["UpdateKitCore", "UpdateKitXPC"]),
        .testTarget(name: "UpdateKitCoreTests", dependencies: ["UpdateKitCore"]),
        .testTarget(name: "UpdateKitXPCTests", dependencies: ["UpdateKitXPC"]),
        .testTarget(
            name: "UpdateKitHelperTests",
            dependencies: ["UpdateKitHelper", "UpdateKitCore"]
        ),
        .testTarget(
            name: "UpdateKitTests",
            dependencies: ["UpdateKit", "UpdateKitCore", "UpdateKitXPC"]
        ),
    ]
)
