// swift-tools-version: 6.2

import PackageDescription
import Foundation

var targets: [Target] = [
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
    .executableTarget(
        name: "PullerHelper",
        dependencies: ["PullerCore", "PullerSystem"]
    ),
    .executableTarget(
        name: "PullerApp",
        dependencies: ["PullerCore"],
        linkerSettings: [.linkedFramework("AppKit")]
    ),
    .executableTarget(name: "EchoServer", path: "Fixtures/EchoServer"),
    .executableTarget(name: "SocketClient", path: "Fixtures/SocketClient"),
]

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
if FileManager.default.fileExists(atPath: packageRoot.appendingPathComponent("Tests").path) {
    targets += [
        .testTarget(name: "PullerCoreTests", dependencies: ["PullerCore"]),
        .testTarget(name: "PullerSystemTests", dependencies: ["PullerSystem"]),
        .testTarget(name: "PullerRecoveryTests", dependencies: ["PullerRecovery"]),
        .testTarget(name: "PullerHelperTests", dependencies: ["PullerHelper"]),
        .testTarget(name: "PullerAppTests", dependencies: ["PullerApp"]),
    ]
}

let package = Package(
    name: "HearthstonePuller",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "PullerCore", targets: ["PullerCore"]),
        .library(name: "PullerSystem", targets: ["PullerSystem"]),
        .executable(name: "hearthstone-puller-recovery", targets: ["PullerRecovery"]),
        .executable(name: "hearthstone-puller-helper", targets: ["PullerHelper"]),
        .executable(name: "HearthstonePuller", targets: ["PullerApp"]),
        .executable(name: "EchoServer", targets: ["EchoServer"]),
        .executable(name: "SocketClient", targets: ["SocketClient"]),
    ],
    targets: targets
)
