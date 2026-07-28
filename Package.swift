// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "HearthstonePuller",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "PullerCore", targets: ["PullerCore"]),
        .library(name: "PullerSystem", targets: ["PullerSystem"]),
        .executable(name: "hearthstone-puller-recovery", targets: ["PullerRecovery"]),
    ],
    targets: [
        .target(name: "PullerCore"),
        .target(
            name: "CProcShim",
            publicHeadersPath: "include",
            linkerSettings: [.linkedLibrary("proc")]
        ),
        .target(
            name: "PullerSystem",
            dependencies: ["PullerCore", "CProcShim"],
            linkerSettings: [.linkedFramework("Security")]
        ),
        .executableTarget(
            name: "PullerRecovery",
            dependencies: ["PullerCore", "PullerSystem"],
            linkerSettings: [.linkedFramework("AppKit")]
        ),
        .testTarget(name: "PullerCoreTests", dependencies: ["PullerCore"]),
        .testTarget(name: "PullerSystemTests", dependencies: ["PullerSystem"]),
        .testTarget(name: "PullerRecoveryTests", dependencies: ["PullerRecovery"]),
    ]
)
