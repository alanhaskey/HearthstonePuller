import Foundation
import PullerCore
import PullerSystem
import XCTest
@testable import PullerHelper

final class HelperEngineTests: XCTestCase {
    func testCutUsesStrictFailSafeOrderAndReachesWaitingForReconnect() async throws {
        let fixture = try HelperFixture()
        let engine = fixture.makeEngine()

        let response = await engine.handle(.cut)
        guard case let .accepted(snapshot) = response else {
            return XCTFail("Expected accepted response, got \(response)")
        }
        XCTAssertEqual(snapshot.state, .cutting)
        XCTAssertEqual(snapshot.remainingMilliseconds, 1_500)

        await fixture.events.waitFor("pf.flush")
        let finished = await engine.handle(.status)
        guard case let .status(finishedSnapshot) = finished else {
            return XCTFail("Expected status response")
        }
        XCTAssertEqual(finishedSnapshot.state, .waitingForReconnect)

        let events = fixture.events.values()
        assertOrder(
            [
                "locator.locate",
                "sockets.startIdentity",
                "sockets.observe",
                "recovery.arm",
                "pf.replace",
                "pf.killStates",
                "time.sleep",
                "pf.flush",
            ],
            in: events
        )
        let armCount = await fixture.recovery.armCount()
        XCTAssertEqual(armCount, 1)
        let armedDeadline = await fixture.recovery.lastDeadline()
        XCTAssertEqual(armedDeadline, Date(timeIntervalSince1970: 1_002))
    }

    func testStartFlushesVerifiesAndEnablesBeforeObservationLoop() async throws {
        let fixture = try HelperFixture(autoAdvanceTime: false, includeLocatedProcess: false)
        let engine = fixture.makeEngine()

        try await engine.start()

        let events = fixture.events.values()
        XCTAssertEqual(Array(events.prefix(3)), ["pf.flush", "pf.verify", "pf.enable"])
        await engine.shutdown()
    }

    func testSecondCutIsRejectedAndDoesNotRearmRecovery() async throws {
        let fixture = try HelperFixture(autoAdvanceTime: false)
        let engine = fixture.makeEngine()

        let first = await engine.handle(.cut)
        let second = await engine.handle(.cut)

        guard case let .accepted(firstSnapshot) = first else {
            return XCTFail("First cut should be accepted")
        }
        guard case let .rejected(code, _, secondSnapshot) = second else {
            return XCTFail("Second cut should be rejected")
        }
        XCTAssertEqual(firstSnapshot.remainingMilliseconds, 1_500)
        XCTAssertEqual(code, "already_cutting")
        XCTAssertEqual(secondSnapshot.remainingMilliseconds, 1_500)
        let armCount = await fixture.recovery.armCount()
        XCTAssertEqual(armCount, 1)
        await engine.shutdown()
    }

    func testFailureAfterRecoveryArmFlushesAndReportsError() async throws {
        for failure in [FakePF.Failure.replace(call: 1), .killStates] {
            let fixture = try HelperFixture(pfFailure: failure)
            let engine = fixture.makeEngine()

            let response = await engine.handle(.cut)

            guard case let .rejected(_, _, snapshot) = response else {
                XCTFail("Expected rejection for \(failure)")
                continue
            }
            let pfFlushes = await fixture.pf.flushCount()
            let recoveryFlushes = await fixture.recovery.flushCount()
            XCTAssertEqual(snapshot.state, .error)
            XCTAssertEqual(pfFlushes, 1)
            XCTAssertEqual(recoveryFlushes, 1)
        }
    }

    func testRecoveryArmFailureNeverLoadsPFRules() async throws {
        let fixture = try HelperFixture(recoveryArmFails: true)
        let engine = fixture.makeEngine()

        let response = await engine.handle(.cut)

        guard case let .rejected(_, _, snapshot) = response else {
            return XCTFail("Expected rejected response")
        }
        let replaceCount = await fixture.pf.replaceCount()
        let flushCount = await fixture.pf.flushCount()
        XCTAssertEqual(snapshot.state, .error)
        XCTAssertEqual(replaceCount, 0)
        XCTAssertEqual(flushCount, 0)
    }

    func testDeadlineFlushFailureRetriesFailOpenAndReportsError() async throws {
        let fixture = try HelperFixture(pfFailure: .flush(call: 1))
        let engine = fixture.makeEngine()

        _ = await engine.handle(.cut)
        await fixture.events.waitFor("recovery.flushNow")
        let response = await engine.handle(.status)

        guard case let .status(snapshot) = response else {
            return XCTFail("Expected status response")
        }
        let flushCount = await fixture.pf.flushCount()
        XCTAssertEqual(snapshot.state, .error)
        XCTAssertEqual(flushCount, 2)
    }

    func testPollingRuleUpdateFailureFlushesAndReportsError() async throws {
        let secondSocket = try ObservedSocket(
            family: .ipv4,
            transport: .tcp,
            localAddress: "192.0.2.10",
            localPort: 50_124,
            remoteAddress: "198.51.100.21",
            remotePort: 3_724
        )
        let fixture = try HelperFixture(
            observedSockets: [[try HelperFixture.socket()], [secondSocket]],
            pfFailure: .replace(call: 2)
        )
        let engine = fixture.makeEngine()

        _ = await engine.handle(.cut)
        await fixture.events.waitFor("recovery.flushNow")
        let response = await engine.handle(.status)

        guard case let .status(snapshot) = response else {
            return XCTFail("Expected status response")
        }
        let flushCount = await fixture.pf.flushCount()
        XCTAssertEqual(snapshot.state, .error)
        XCTAssertGreaterThanOrEqual(flushCount, 1)
    }
}

private func assertOrder(_ expected: [String], in actual: [String], file: StaticString = #filePath, line: UInt = #line) {
    var lowerBound = actual.startIndex
    for event in expected {
        guard let index = actual[lowerBound...].firstIndex(of: event) else {
            return XCTFail("Missing ordered event \(event) in \(actual)", file: file, line: line)
        }
        lowerBound = actual.index(after: index)
    }
}

private final class HelperFixture: @unchecked Sendable {
    let events = HelperEventLog()
    let locator: FakeLocator
    let sockets: FakeSockets
    let pf: FakePF
    let recovery: FakeRecovery
    let time: FakeHelperTime

    init(
        autoAdvanceTime: Bool = true,
        includeLocatedProcess: Bool = true,
        observedSockets: [[ObservedSocket]]? = nil,
        pfFailure: FakePF.Failure? = nil,
        recoveryArmFails: Bool = false
    ) throws {
        let process = VerifiedProcess(
            pid: 42,
            startIdentity: .init(seconds: 100, microseconds: 200),
            executableURL: URL(
                fileURLWithPath: "/Applications/Hearthstone/Hearthstone.app/Contents/MacOS/Hearthstone"
            )
        )
        let selectedProcess = includeLocatedProcess ? process : nil
        self.locator = FakeLocator(process: selectedProcess, events: events)
        let socketObservations: [[ObservedSocket]]
        if let observedSockets {
            socketObservations = observedSockets
        } else {
            socketObservations = [[try Self.socket()]]
        }
        self.sockets = FakeSockets(
            identity: process.startIdentity,
            observations: socketObservations,
            events: events
        )
        self.pf = FakePF(failure: pfFailure, events: events)
        self.recovery = FakeRecovery(armFails: recoveryArmFails, events: events)
        self.time = FakeHelperTime(autoAdvance: autoAdvanceTime, events: events)
    }

    func makeEngine() -> HelperEngine {
        HelperEngine(
            locator: locator,
            sockets: sockets,
            pf: pf,
            recovery: recovery,
            time: time
        )
    }

    static func socket() throws -> ObservedSocket {
        try ObservedSocket(
            family: .ipv4,
            transport: .tcp,
            localAddress: "192.0.2.10",
            localPort: 50_123,
            remoteAddress: "198.51.100.20",
            remotePort: 3_724
        )
    }
}

private final class HelperEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func append(_ event: String) {
        let continuations = lock.withLock {
            events.append(event)
            return waiters.removeValue(forKey: event) ?? []
        }
        continuations.forEach { $0.resume() }
    }

    func values() -> [String] {
        lock.withLock { events }
    }

    func waitFor(_ event: String) async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                if events.contains(event) { return true }
                waiters[event, default: []].append(continuation)
                return false
            }
            if shouldResume { continuation.resume() }
        }
    }
}

private struct FakeLocator: HearthstoneLocating {
    let process: VerifiedProcess?
    let events: HelperEventLog

    func locate() throws -> VerifiedProcess? {
        events.append("locator.locate")
        return process
    }
}

private final class FakeSockets: ProcessSocketObserving, @unchecked Sendable {
    private let lock = NSLock()
    private let identity: ProcessStartIdentity
    private var observations: [[ObservedSocket]]
    private let events: HelperEventLog

    init(identity: ProcessStartIdentity, observations: [[ObservedSocket]], events: HelperEventLog) {
        self.identity = identity
        self.observations = observations
        self.events = events
    }

    func processIDs() throws -> [pid_t] { [] }
    func executablePath(pid: pid_t) throws -> URL { URL(fileURLWithPath: "/") }

    func startIdentity(pid: pid_t) throws -> ProcessStartIdentity {
        events.append("sockets.startIdentity")
        return identity
    }

    func sockets(pid: pid_t, allowLoopback: Bool) throws -> [ObservedSocket] {
        events.append("sockets.observe")
        return lock.withLock {
            guard observations.count > 1 else { return observations[0] }
            return observations.removeFirst()
        }
    }
}

private actor FakePF: PFControlling {
    enum Failure: Error, Equatable {
        case replace(call: Int)
        case killStates
        case flush(call: Int)
    }

    private let failure: Failure?
    private let events: HelperEventLog
    private var replaceCalls = 0
    private var flushes = 0

    init(failure: Failure?, events: HelperEventLog) {
        self.failure = failure
        self.events = events
    }

    func verifyAppleAnchor() async throws { events.append("pf.verify") }
    func enable() async throws { events.append("pf.enable") }

    func replaceAnchor(with rules: String) async throws {
        replaceCalls += 1
        events.append("pf.replace")
        if failure == .replace(call: replaceCalls) { throw failure! }
    }

    func killStates(_ pairs: [StatePair]) async throws {
        events.append("pf.killStates")
        if failure == .killStates { throw failure! }
    }

    func flushAnchor() async throws {
        flushes += 1
        events.append("pf.flush")
        if failure == .flush(call: flushes) { throw failure! }
    }

    func releaseEnableReference() async { events.append("pf.release") }
    func flushCount() -> Int { flushes }
    func replaceCount() -> Int { replaceCalls }
}

private actor FakeRecovery: RecoveryArming {
    private let armFails: Bool
    private let events: HelperEventLog
    private var arms = 0
    private var flushes = 0
    private var deadline: Date?

    init(armFails: Bool, events: HelperEventLog) {
        self.armFails = armFails
        self.events = events
    }

    func arm(deadline: Date) async throws {
        arms += 1
        events.append("recovery.arm")
        if armFails { throw FakeRecoveryError.armFailed }
        self.deadline = deadline
    }

    func flushNow() async throws {
        flushes += 1
        events.append("recovery.flushNow")
    }

    func armCount() -> Int { arms }
    func flushCount() -> Int { flushes }
    func lastDeadline() -> Date? { deadline }
}

private enum FakeRecoveryError: Error {
    case armFailed
}

private final class FakeHelperTime: HelperTimeSource, @unchecked Sendable {
    private let lock = NSLock()
    private let autoAdvance: Bool
    private let baseWall = Date(timeIntervalSince1970: 1_000)
    private let events: HelperEventLog
    private var currentElapsed: Duration = .zero

    init(autoAdvance: Bool, events: HelperEventLog) {
        self.autoAdvance = autoAdvance
        self.events = events
    }

    var elapsed: Duration {
        lock.withLock { currentElapsed }
    }

    var wallNow: Date {
        let components = elapsed.components
        return baseWall.addingTimeInterval(
            Double(components.seconds) + Double(components.attoseconds) / 1e18
        )
    }

    func sleep(for duration: Duration) async throws {
        events.append("time.sleep")
        if autoAdvance {
            lock.withLock { currentElapsed += duration }
        } else {
            try await Task.sleep(for: .seconds(60))
        }
        await Task.yield()
    }
}
