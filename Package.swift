// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ReviewQueue",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "ReviewQueue", targets: ["ReviewQueue"]),
    ],
    targets: [
        .target(name: "ReviewQueueCore"),
        .executableTarget(name: "ReviewQueue", dependencies: ["ReviewQueueCore"]),
        .testTarget(name: "ReviewQueueCoreTests", dependencies: ["ReviewQueueCore"]),
    ]
)
