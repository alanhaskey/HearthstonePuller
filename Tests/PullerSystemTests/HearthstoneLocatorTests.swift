import Darwin
import Foundation
import PullerCore
import Security
import XCTest
@testable import PullerSystem

final class HearthstoneLocatorTests: XCTestCase {
    private let bundleURL = URL(fileURLWithPath: "/Applications/Hearthstone/Hearthstone.app")

    func testSelectsValidProcessInsideExactHearthstoneBundle() throws {
        let processes = FakeProcessObserver(fixtures: [
            101: .init(
                path: "/Applications/Hearthstone/Hearthstone.app/Contents/MacOS/Hearthstone",
                identities: [.init(seconds: 10, microseconds: 20)]
            ),
        ])
        let validator = try FakeRunningCodeValidator(validPIDs: [101])
        let locator = HearthstoneLocator(
            bundleURL: bundleURL,
            processes: processes,
            codeValidator: validator
        )

        let process = try XCTUnwrap(locator.locate())

        XCTAssertEqual(process.pid, 101)
        XCTAssertEqual(process.startIdentity, .init(seconds: 10, microseconds: 20))
        XCTAssertEqual(
            process.executableURL.path,
            "/Applications/Hearthstone/Hearthstone.app/Contents/MacOS/Hearthstone"
        )
    }

    func testRejectsHearthstoneBetaLauncherBundle() throws {
        let processes = FakeProcessObserver(fixtures: [
            102: .init(
                path: "/Applications/Hearthstone Beta Launcher.app/Contents/MacOS/Hearthstone",
                identities: [.init(seconds: 10, microseconds: 20)]
            ),
        ])
        let locator = HearthstoneLocator(
            bundleURL: bundleURL,
            processes: processes,
            codeValidator: try FakeRunningCodeValidator(validPIDs: [102])
        )

        XCTAssertNil(try locator.locate())
    }

    func testRejectsMatchingExecutableNameOutsideBundle() throws {
        let processes = FakeProcessObserver(fixtures: [
            103: .init(
                path: "/tmp/Hearthstone",
                identities: [.init(seconds: 10, microseconds: 20)]
            ),
        ])
        let locator = HearthstoneLocator(
            bundleURL: bundleURL,
            processes: processes,
            codeValidator: try FakeRunningCodeValidator(validPIDs: [103])
        )

        XCTAssertNil(try locator.locate())
    }

    func testRejectsPIDWhoseStartIdentityChangesDuringVerification() throws {
        let processes = FakeProcessObserver(fixtures: [
            104: .init(
                path: "/Applications/Hearthstone/Hearthstone.app/Contents/MacOS/Hearthstone",
                identities: [
                    .init(seconds: 10, microseconds: 20),
                    .init(seconds: 11, microseconds: 0),
                ]
            ),
        ])
        let locator = HearthstoneLocator(
            bundleURL: bundleURL,
            processes: processes,
            codeValidator: try FakeRunningCodeValidator(validPIDs: [104])
        )

        XCTAssertNil(try locator.locate())
    }

    func testCodeValidationFailureDoesNotFallBackToNameMatch() throws {
        let processes = FakeProcessObserver(fixtures: [
            105: .init(
                path: "/Applications/Hearthstone/Hearthstone.app/Contents/MacOS/Hearthstone",
                identities: [.init(seconds: 10, microseconds: 20)]
            ),
        ])
        let locator = HearthstoneLocator(
            bundleURL: bundleURL,
            processes: processes,
            codeValidator: try FakeRunningCodeValidator(failingPIDs: [105])
        )

        XCTAssertNil(try locator.locate())
    }

    func testObservesLocallyInstalledHearthstoneWhenExplicitlyEnabled() throws {
        guard ProcessInfo.processInfo.environment["HEARTHSTONE_OBSERVATION_TEST"] == "1" else {
            throw XCTSkip("Set HEARTHSTONE_OBSERVATION_TEST=1 for local code-signing observation")
        }

        let processes = ProcessSocketObserver()
        let locator = HearthstoneLocator(
            bundleURL: bundleURL,
            processes: processes,
            codeValidator: SecurityRunningCodeValidator()
        )
        guard let process = try locator.locate() else {
            throw XCTSkip("Hearthstone is not running")
        }

        XCTAssertEqual(try processes.startIdentity(pid: process.pid), process.startIdentity)
        XCTAssertTrue(process.executableURL.path.hasPrefix(bundleURL.path + "/Contents/MacOS/"))
    }
}

private struct ProcessFixture {
    let path: String
    let identities: [ProcessStartIdentity]
}

private final class FakeProcessObserver: ProcessSocketObserving, @unchecked Sendable {
    private let fixtures: [pid_t: ProcessFixture]
    private var identityReadCounts: [pid_t: Int] = [:]

    init(fixtures: [pid_t: ProcessFixture]) {
        self.fixtures = fixtures
    }

    func processIDs() throws -> [pid_t] {
        fixtures.keys.sorted()
    }

    func executablePath(pid: pid_t) throws -> URL {
        URL(fileURLWithPath: try fixture(pid).path)
    }

    func startIdentity(pid: pid_t) throws -> ProcessStartIdentity {
        let identities = try fixture(pid).identities
        let index = min(identityReadCounts[pid, default: 0], identities.count - 1)
        identityReadCounts[pid, default: 0] += 1
        return identities[index]
    }

    func sockets(pid: pid_t, allowLoopback: Bool) throws -> [ObservedSocket] {
        []
    }

    private func fixture(_ pid: pid_t) throws -> ProcessFixture {
        guard let fixture = fixtures[pid] else { throw FakeError.missingProcess(pid) }
        return fixture
    }
}

private final class FakeRunningCodeValidator: RunningCodeValidating, @unchecked Sendable {
    private let requirement: DesignatedRequirement
    private let validPIDs: Set<pid_t>
    private let failingPIDs: Set<pid_t>

    init(validPIDs: Set<pid_t> = [], failingPIDs: Set<pid_t> = []) throws {
        var value: SecRequirement?
        let status = SecRequirementCreateWithString("true" as CFString, [], &value)
        guard status == errSecSuccess, let value else { throw FakeError.securityStatus(status) }
        self.requirement = DesignatedRequirement(value)
        self.validPIDs = validPIDs
        self.failingPIDs = failingPIDs
    }

    func designatedRequirement(forBundle bundleURL: URL) throws -> DesignatedRequirement {
        requirement
    }

    func runningProcess(pid: pid_t, satisfies requirement: DesignatedRequirement) throws -> Bool {
        if failingPIDs.contains(pid) { throw FakeError.securityStatus(errSecCSUnsigned) }
        return validPIDs.contains(pid)
    }
}

private enum FakeError: Error {
    case missingProcess(pid_t)
    case securityStatus(OSStatus)
}
