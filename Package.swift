// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "HearthstonePuller",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "PullerCore", targets: ["PullerCore"]),
    ],
    targets: [
        .target(name: "PullerCore"),
        .testTarget(name: "PullerCoreTests", dependencies: ["PullerCore"]),
    ]
)
