// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "UpdateKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "UpdateKitCore", targets: ["UpdateKitCore"]),
        .library(name: "UpdateKitXPC", targets: ["UpdateKitXPC"]),
    ],
    targets: [
        // Ноль I/O: политика, версии, разбор ответа GitHub, тексты.
        .target(name: "UpdateKitCore"),
        // Зависимостей нет намеренно: через границу демона ходят только
        // числа и строки, доменные типы её не пересекают.
        .target(name: "UpdateKitXPC"),
        .testTarget(name: "UpdateKitCoreTests", dependencies: ["UpdateKitCore"]),
        .testTarget(name: "UpdateKitXPCTests", dependencies: ["UpdateKitXPC"]),
    ]
)
