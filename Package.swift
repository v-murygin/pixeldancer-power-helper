// swift-tools-version:5.10
import PackageDescription

// PixelDancer Power Helper — Swift Package
//
// Produces two executables that get assembled into a single .app bundle:
//   • PixelDancerPowerHelper        — the user-facing GUI (installer/status)
//   • PixelDancerPowerHelperDaemon  — the privileged LaunchDaemon
//
// Both targets share the XPC protocol via the PowerHelperShared library.
//
// The bundle is assembled by `build.sh` (next to this Package.swift).

let package = Package(
    name: "PixelDancerPowerHelper",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "PixelDancerPowerHelper", targets: ["PowerHelperApp"]),
        .executable(name: "PixelDancerPowerHelperDaemon", targets: ["PowerHelperDaemon"]),
    ],
    targets: [
        .target(
            name: "PowerHelperShared",
            path: "Shared"
        ),
        .executableTarget(
            name: "PowerHelperApp",
            dependencies: ["PowerHelperShared"],
            path: "Sources/PowerHelperApp",
            resources: [
                .process("Resources")
            ]
        ),
        .executableTarget(
            name: "PowerHelperDaemon",
            dependencies: ["PowerHelperShared"],
            path: "Sources/PowerHelperDaemon"
        ),
    ]
)
