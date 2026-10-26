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
        // libyara 4.5.4 (BSD-3, see Sources/CYara/LICENSE), built without OpenSSL
        // and without process scanning: hashes come from CommonCrypto.
        .target(
            name: "CYara",
            exclude: ["LICENSE", "modules/module_list"],
            cSettings: [
                .headerSearchPath("."),
                .headerSearchPath("modules"),
                .define("USE_NO_PROC"),
                .define("MACHO_MODULE"),
                .define("HASH_MODULE"),
                .define("HAVE_COMMONCRYPTO_COMMONCRYPTO_H"),
                .define("HAVE_STDBOOL_H"),
                .define("HAVE_CLOCK_GETTIME"),
                .define("HAVE_TIMEGM"),
                .define("HAVE_SCAN_PROC_IMPL", to: "0"),
                .define("BUCKETS_128", to: "1"),
                .define("CHECKSUM_1B", to: "1"),
            ]
        ),
        .target(
            name: "MacCleanerModules",
            dependencies: ["MacCleanerCore", "CYara"],
            resources: [.process("Resources")]
        ),
        // Read-only command line tool to try scans on the real Mac: it never removes anything.
        .executableTarget(name: "mccli", dependencies: ["MacCleanerModules"]),
        // Privileged helper embedded in the app: the only code that touches system files as root.
        .executableTarget(name: "mchelper", dependencies: ["MacCleanerCore"]),
        .testTarget(name: "MacCleanerCoreTests", dependencies: ["MacCleanerCore"]),
        .testTarget(name: "MacCleanerModulesTests", dependencies: ["MacCleanerModules"]),
    ]
)
