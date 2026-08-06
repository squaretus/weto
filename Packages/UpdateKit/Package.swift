// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "UpdateKit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "UpdateKitCore", targets: ["UpdateKitCore"]),
    ],
    targets: [
        // Ноль I/O: политика, версии, разбор ответа GitHub, тексты.
        .target(name: "UpdateKitCore"),
        .testTarget(name: "UpdateKitCoreTests", dependencies: ["UpdateKitCore"]),
    ]
)
