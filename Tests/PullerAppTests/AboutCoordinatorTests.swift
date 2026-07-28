import Foundation
import XCTest
@testable import PullerApp

@MainActor
final class AboutCoordinatorTests: XCTestCase {
    func testMetadataUsesFixedIdentityAndBundleVersion() {
        let metadata = AboutMetadata(infoDictionary: [
            "CFBundleShortVersionString": "1.0.0",
        ])

        XCTAssertEqual(metadata.applicationName, "HearthstonePuller")
        XCTAssertEqual(metadata.author, "Yunnn")
        XCTAssertEqual(
            metadata.repositoryURL,
            URL(string: "https://github.com/alanhaskey/HearthstonePuller")
        )
        XCTAssertEqual(metadata.version, "1.0.0")
    }

    func testMissingOrEmptyBundleVersionUsesBilingualFallback() {
        XCTAssertEqual(AboutMetadata(infoDictionary: nil).version, "未知 / Unknown")
        XCTAssertEqual(
            AboutMetadata(infoDictionary: ["CFBundleShortVersionString": ""]).version,
            "未知 / Unknown"
        )
    }

    func testDetailsContainBilingualLabelsAndFixedValues() {
        let metadata = AboutMetadata(infoDictionary: [
            "CFBundleShortVersionString": "1.0.0",
        ])

        XCTAssertEqual(
            metadata.informativeText,
            """
            作者 / Author: Yunnn
            GitHub: https://github.com/alanhaskey/HearthstonePuller
            版本 / Version: 1.0.0
            """
        )
    }

    func testOpenRepositoryHandsOnlyFixedURLToOpener() throws {
        let opener = RecordingRepositoryOpener(result: true)
        let coordinator = AboutCoordinator(opener: opener)

        XCTAssertTrue(coordinator.openRepository())
        XCTAssertEqual(
            try XCTUnwrap(opener.openedURL),
            URL(string: "https://github.com/alanhaskey/HearthstonePuller")
        )
    }

    func testOpenRepositoryReturnsFalseAndExposesBilingualFailureMessage() {
        let coordinator = AboutCoordinator(opener: RecordingRepositoryOpener(result: false))

        XCTAssertFalse(coordinator.openRepository())
        XCTAssertEqual(
            AboutCoordinator.openFailureMessage,
            "无法打开 GitHub / Unable to open GitHub"
        )
    }
}

@MainActor
private final class RecordingRepositoryOpener: RepositoryOpening {
    private let result: Bool
    private(set) var openedURL: URL?

    init(result: Bool) {
        self.result = result
    }

    func open(_ url: URL) -> Bool {
        openedURL = url
        return result
    }
}
