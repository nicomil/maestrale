// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MaestraleKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MaestraleCore", targets: ["MaestraleCore"]),
        .library(name: "MaestraleModules", targets: ["MaestraleModules"]),
    ],
    targets: [
        .target(name: "MaestraleCore"),
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
            name: "MaestraleModules",
            dependencies: ["MaestraleCore", "CYara"],
            resources: [.process("Resources")]
        ),
        // Read-only command line tool to try scans on the real Mac: it never removes anything.
        .executableTarget(name: "mscli", dependencies: ["MaestraleModules"]),
        // Privileged helper embedded in the app: the only code that touches system files as root.
        .executableTarget(name: "mshelper", dependencies: ["MaestraleCore"]),
        .testTarget(name: "MaestraleCoreTests", dependencies: ["MaestraleCore"]),
        .testTarget(name: "MaestraleModulesTests", dependencies: ["MaestraleModules"]),
    ]
)
