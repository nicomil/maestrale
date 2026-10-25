// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacCleanerKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MacCleanerCore", targets: ["MacCleanerCore"]),
        .library(name: "MacCleanerModules", targets: ["MacCleanerModules"]),
    ],
    targets: [
        .target(name: "MacCleanerCore"),
        .target(
            name: "MacCleanerModules",
            dependencies: ["MacCleanerCore"],
            resources: [.process("Resources")]
        ),
        // Read-only command line tool to try scans on the real Mac: it never removes anything.
        .executableTarget(name: "mccli", dependencies: ["MacCleanerModules"]),
        .testTarget(name: "MacCleanerCoreTests", dependencies: ["MacCleanerCore"]),
        .testTarget(name: "MacCleanerModulesTests", dependencies: ["MacCleanerModules"]),
    ]
)
