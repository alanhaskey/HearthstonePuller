import Foundation
import XCTest
@testable import PullerApp

final class ServiceInstallationDetectorTests: XCTestCase {
    func testCompleteInstallationIsInstalled() throws {
        let fixture = try InstalledServiceFixture()
        defer { fixture.remove() }

        XCTAssertEqual(
            ServiceInstallationDetector(rootURL: fixture.rootURL).status(),
            .installed
        )
    }

    func testEachMissingArtifactMakesInstallationIncomplete() throws {
        for relativePath in InstalledServiceFixture.requiredPaths {
            let fixture = try InstalledServiceFixture()
            defer { fixture.remove() }
            try FileManager.default.removeItem(
                at: fixture.rootURL.appendingPathComponent(relativePath)
            )

            XCTAssertEqual(
                ServiceInstallationDetector(rootURL: fixture.rootURL).status(),
                .notInstalled,
                "Expected missing \(relativePath) to be incomplete"
            )
        }
    }

    func testSymlinkedArtifactIsNotInstalled() throws {
        let fixture = try InstalledServiceFixture()
        defer { fixture.remove() }
        let helper = fixture.rootURL.appendingPathComponent(InstalledServiceFixture.helperPath)
        let target = fixture.rootURL.appendingPathComponent(InstalledServiceFixture.recoveryPath)
        try FileManager.default.removeItem(at: helper)
        try FileManager.default.createSymbolicLink(at: helper, withDestinationURL: target)

        XCTAssertEqual(
            ServiceInstallationDetector(rootURL: fixture.rootURL).status(),
            .notInstalled
        )
    }

    func testDirectoryInPlaceOfArtifactIsNotInstalled() throws {
        let fixture = try InstalledServiceFixture()
        defer { fixture.remove() }
        let config = fixture.rootURL.appendingPathComponent(InstalledServiceFixture.configPath)
        try FileManager.default.removeItem(at: config)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: false)

        XCTAssertEqual(
            ServiceInstallationDetector(rootURL: fixture.rootURL).status(),
            .notInstalled
        )
    }

    func testNonExecutableServiceBinaryIsNotInstalled() throws {
        let fixture = try InstalledServiceFixture()
        defer { fixture.remove() }
        let helper = fixture.rootURL.appendingPathComponent(InstalledServiceFixture.helperPath)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: helper.path
        )

        XCTAssertEqual(
            ServiceInstallationDetector(rootURL: fixture.rootURL).status(),
            .notInstalled
        )
    }
}

private struct InstalledServiceFixture {
    static let helperPath = "Library/PrivilegedHelperTools/hearthstone-puller-helper"
    static let recoveryPath = "Library/PrivilegedHelperTools/hearthstone-puller-recovery"
    static let helperPlistPath = "Library/LaunchDaemons/com.yunnn.hearthstone-puller.helper.plist"
    static let recoveryPlistPath = "Library/LaunchDaemons/com.yunnn.hearthstone-puller.recovery.plist"
    static let configPath = "Library/Application Support/HearthstonePuller/config.plist"
    static let requiredPaths = [
        helperPath,
        recoveryPath,
        helperPlistPath,
        recoveryPlistPath,
        configPath,
    ]

    let rootURL: URL

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServiceInstallationDetectorTests-\(UUID().uuidString)", isDirectory: true)
        for relativePath in Self.requiredPaths {
            let url = rootURL.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data("fixture".utf8).write(to: url)
        }
        for relativePath in [Self.helperPath, Self.recoveryPath] {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: rootURL.appendingPathComponent(relativePath).path
            )
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}
