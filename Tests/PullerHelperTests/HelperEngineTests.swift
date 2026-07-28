import Foundation
import PullerCore
import PullerSystem
import XCTest
@testable import PullerHelper

final class HelperEngineTests: XCTestCase {
    func testCutUsesStrictFailSafeOrderAndReachesWaitingForReconnect() async throws {
        let fixture = try HelperFixture(autoAdvanceTime: false)
        let engine = fixture.makeEngine()

        let response = await engine.handle(.cut)
        guard case let .accepted(snapshot) = response else {
            return XCTFail("Expected accepted response, got \(response)")
        }
        XCTAssertEqual(snapshot.state, .cutting)
        XCTAssertEqual(snapshot.remainingMilliseconds, 10_000)

        await fixture.time.waitUntilSleepCount(1)
        fixture.time.advance(by: .milliseconds(50))
        await fixture.events.waitFor("recovery.flushNow")
        let finished = await engine.handle(.status)
        guard case let .status(finishedSnapshot) = finished else {
            return XCTFail("Expected status response")
        }
        XCTAssertEqual(finishedSnapshot.state, .waitingForReconnect)
        XCTAssertEqual(finishedSnapshot.remainingMilliseconds, 15_000)

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
                "recovery.flushNow",
            ],
            in: events
        )
        let armCount = await fixture.recovery.armCount()
        XCTAssertEqual(armCount, 1)
        let armedDeadline = await fixture.recovery.lastDeadline()
        XCTAssertEqual(armedDeadline, Date(timeIntervalSince1970: 1_010))
        await engine.shutdown()
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
        XCTAssertEqual(firstSnapshot.remainingMilliseconds, 10_000)
        XCTAssertEqual(code, "already_cutting")
        XCTAssertEqual(secondSnapshot.remainingMilliseconds, 10_000)
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

    func testReplacementSocketIsNeverBlockedOrKilled() async throws {
        let replacement = try ObservedSocket(
            family: .ipv4,
            transport: .tcp,
            localAddress: "192.0.2.10",
            localPort: 50_124,
            remoteAddress: "198.51.100.20",
            remotePort: 3_724
        )
        let fixture = try HelperFixture(
            autoAdvanceTime: false,
            observedSockets: [[try HelperFixture.socket()], [], [replacement]]
        )
        let engine = fixture.makeEngine()

        _ = await engine.handle(.cut)
        await fixture.time.waitUntilSleepCount(1)
        fixture.time.advance(by: .milliseconds(50))
        await fixture.events.waitFor("recovery.flushNow")
        await fixture.time.waitUntilSleepCount(2)
        fixture.time.advance(by: .milliseconds(500))
        await fixture.events.waitFor("sockets.observe", count: 3)
        let response = await engine.handle(.status)

        guard case let .status(snapshot) = response else {
            return XCTFail("Expected status response")
        }
        let replaceCount = await fixture.pf.replaceCount()
        let killCount = await fixture.pf.killCount()
        XCTAssertEqual(snapshot.state, .ready)
        XCTAssertEqual(replaceCount, 1)
        XCTAssertEqual(killCount, 1)
        await engine.shutdown()
    }

    func testRejectsCutWhenOnlyNonGameConnectionsExist() async throws {
        let https = try ObservedSocket(
            family: .ipv4,
            transport: .tcp,
            localAddress: "192.0.2.10",
            localPort: 50_124,
            remoteAddress: "198.51.100.21",
            remotePort: 443
        )
        let login = try ObservedSocket(
            family: .ipv4,
            transport: .tcp,
            localAddress: "192.0.2.10",
            localPort: 50_125,
            remoteAddress: "198.51.100.22",
            remotePort: 1_119
        )
        let fixture = try HelperFixture(observedSockets: [[https, login]])
        let engine = fixture.makeEngine()

        let response = await engine.handle(.cut)

        guard case let .rejected(code, _, snapshot) = response else {
            return XCTFail("Expected non-game connections to be rejected")
        }
        let replaceCount = await fixture.pf.replaceCount()
        let killCount = await fixture.pf.killCount()
        XCTAssertEqual(code, "no_game_connection")
        XCTAssertEqual(snapshot.state, .absent)
        XCTAssertEqual(replaceCount, 0)
        XCTAssertEqual(killCount, 0)
    }

    func testResetTimesOutFailOpenWhenOriginalTupleRemains() async throws {
        let original = try HelperFixture.socket()
        let fixture = try HelperFixture(
            autoAdvanceTime: false,
            observedSockets: [[original]]
        )
        let engine = fixture.makeEngine()

        _ = await engine.handle(.cut)
        await fixture.time.waitUntilSleepCount(1)
        fixture.time.advance(by: .seconds(10))
        await fixture.events.waitFor("recovery.flushNow")
        let response = await engine.handle(.status)

        guard case let .status(snapshot) = response else {
            return XCTFail("Expected status response")
        }
        let flushCount = await fixture.pf.flushCount()
        XCTAssertEqual(snapshot.state, .notTriggered)
        XCTAssertNil(snapshot.message)
        XCTAssertGreaterThanOrEqual(flushCount, 1)
        await engine.shutdown()
    }

    func testResetAndReconnectLimitsAreIndependent() {
        XCTAssertEqual(HelperEngine.resetAttemptLimit, .seconds(10))
        XCTAssertEqual(HelperEngine.reconnectLimit, .seconds(15))
    }

    func testSetupTimeCountsAgainstSharedRecoveryAndResetDeadline() async throws {
        let fixture = try HelperFixture(
            autoAdvanceTime: false,
            pfSetupTimeAdvance: .milliseconds(250)
        )
        let engine = fixture.makeEngine()

        guard case let .accepted(snapshot) = await engine.handle(.cut) else {
            return XCTFail("Expected accepted response")
        }

        XCTAssertEqual(snapshot.state, .cutting)
        XCTAssertEqual(snapshot.remainingMilliseconds, 9_750)
        let armedDeadline = await fixture.recovery.lastDeadline()
        XCTAssertEqual(armedDeadline, Date(timeIntervalSince1970: 1_010))
        await engine.shutdown()
    }

    func testResetCountdownUsesMonotonicDeadlineAndClearsAfterTimeout() async throws {
        let original = try HelperFixture.socket()
        let fixture = try HelperFixture(
            autoAdvanceTime: false,
            observedSockets: [[original]]
        )
        let engine = fixture.makeEngine()

        _ = await engine.handle(.cut)
        await fixture.time.waitUntilSleepCount(1)
        fixture.time.advance(by: .milliseconds(2_500))

        guard case let .status(progress) = await engine.handle(.status) else {
            return XCTFail("Expected status response")
        }
        XCTAssertEqual(progress.state, .cutting)
        XCTAssertEqual(progress.remainingMilliseconds, 7_500)

        fixture.time.advance(by: .milliseconds(7_500))
        await fixture.events.waitFor("recovery.flushNow")
        guard case let .status(finished) = await engine.handle(.status) else {
            return XCTFail("Expected status response")
        }
        XCTAssertEqual(finished.state, .notTriggered)
        XCTAssertEqual(finished.remainingMilliseconds, 0)
        await engine.shutdown()
    }

    func testReconnectCountdownStartsAtFifteenSecondsAndDecreasesIndependently() async throws {
        let fixture = try HelperFixture(autoAdvanceTime: false)
        let engine = fixture.makeEngine()

        _ = await engine.handle(.cut)
        await fixture.time.waitUntilSleepCount(1)
        fixture.time.advance(by: .milliseconds(50))
        await fixture.events.waitFor("recovery.flushNow")
        await fixture.time.waitUntilSleepCount(2)

        guard case let .status(started) = await engine.handle(.status) else {
            return XCTFail("Expected status response")
        }
        XCTAssertEqual(started.state, .waitingForReconnect)
        XCTAssertEqual(started.remainingMilliseconds, 15_000)

        fixture.time.advance(by: .milliseconds(1_250))
        guard case let .status(progress) = await engine.handle(.status) else {
            return XCTFail("Expected status response")
        }
        XCTAssertEqual(progress.state, .waitingForReconnect)
        XCTAssertEqual(progress.remainingMilliseconds, 13_750)

        await engine.shutdown()
        guard case let .status(stopped) = await engine.handle(.status) else {
            return XCTFail("Expected status response")
        }
        XCTAssertEqual(stopped.remainingMilliseconds, 0)
    }

    func testNotTriggeredCanStartFreshAttempt() async throws {
        let original = try HelperFixture.socket()
        let fixture = try HelperFixture(
            autoAdvanceTime: false,
            observedSockets: [[original]]
        )
        let engine = fixture.makeEngine()

        _ = await engine.handle(.cut)
        await fixture.time.waitUntilSleepCount(1)
        fixture.time.advance(by: .seconds(10))
        await fixture.events.waitFor("recovery.flushNow")

        let retry = await engine.handle(.cut)

        guard case let .accepted(snapshot) = retry else {
            return XCTFail("Expected retry to be accepted")
        }
        let armCount = await fixture.recovery.armCount()
        let replaceCount = await fixture.pf.replaceCount()
        XCTAssertEqual(snapshot.state, .cutting)
        XCTAssertEqual(armCount, 2)
        XCTAssertEqual(replaceCount, 2)
        await engine.shutdown()
    }

    func testReconnectWaitTimesOutToAbsentAfterFifteenSeconds() async throws {
        let fixture = try HelperFixture(autoAdvanceTime: false)
        let engine = fixture.makeEngine()

        _ = await engine.handle(.cut)
        await fixture.time.waitUntilSleepCount(1)
        fixture.time.advance(by: .milliseconds(50))
        await fixture.events.waitFor("recovery.flushNow")
        await fixture.time.waitUntilSleepCount(2)

        fixture.time.advance(by: .seconds(15))
        await fixture.events.waitFor("sockets.observe", count: 3)
        let response = await engine.handle(.status)

        guard case let .status(snapshot) = response else {
            return XCTFail("Expected status response")
        }
        XCTAssertEqual(snapshot.state, .absent)
        await engine.shutdown()
    }

    func testNotTriggeredPersistsUntilTimedOutTupleIsReplaced() async throws {
        let original = try HelperFixture.socket()
        let replacement = try ObservedSocket(
            family: .ipv4,
            transport: .tcp,
            localAddress: "192.0.2.10",
            localPort: 50_124,
            remoteAddress: "198.51.100.20",
            remotePort: 3_724
        )
        let fixture = try HelperFixture(
            autoAdvanceTime: false,
            observedSockets: [[original], [original], [original], [replacement]]
        )
        let engine = fixture.makeEngine()

        _ = await engine.handle(.cut)
        await fixture.time.waitUntilSleepCount(1)
        fixture.time.advance(by: .seconds(10))
        await fixture.events.waitFor("recovery.flushNow")

        try await engine.start()

        guard case let .status(untriggered) = await engine.handle(.status) else {
            return XCTFail("Expected status response")
        }
        XCTAssertEqual(untriggered.state, .notTriggered)

        await fixture.time.waitUntilSleepCount(2)
        fixture.time.advance(by: .milliseconds(500))
        await fixture.events.waitFor("sockets.observe", count: 4)

        guard case let .status(replaced) = await engine.handle(.status) else {
            return XCTFail("Expected status response")
        }
        XCTAssertEqual(replaced.state, .ready)
        await engine.shutdown()
    }

    func testObservationFailureReportsServiceError() async throws {
        let fixture = try HelperFixture(
            autoAdvanceTime: false,
            socketFailureCall: 2
        )
        let engine = fixture.makeEngine()
        try await engine.start()

        await fixture.time.waitUntilSleepCount(1)
        fixture.time.advance(by: .milliseconds(500))
        await fixture.events.waitFor("sockets.failure")

        guard case let .status(snapshot) = await engine.handle(.status) else {
            return XCTFail("Expected status response")
        }
        XCTAssertEqual(snapshot.state, .error)
        await engine.shutdown()
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
        pfSetupTimeAdvance: Duration? = nil,
        recoveryArmFails: Bool = false,
        socketFailureCall: Int? = nil
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
            socketObservations = [[try Self.socket()], []]
        }
        self.sockets = FakeSockets(
            identity: process.startIdentity,
            observations: socketObservations,
            events: events,
            failureCall: socketFailureCall
        )
        let fakeTime = FakeHelperTime(autoAdvance: autoAdvanceTime, events: events)
        self.time = fakeTime
        let advanceSetupTime: (@Sendable () -> Void)?
        if let pfSetupTimeAdvance {
            advanceSetupTime = { fakeTime.advance(by: pfSetupTimeAdvance) }
        } else {
            advanceSetupTime = nil
        }
        self.pf = FakePF(
            failure: pfFailure,
            events: events,
            setupTimeAdvance: advanceSetupTime
        )
        self.recovery = FakeRecovery(armFails: recoveryArmFails, events: events)
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
    private var waiters: [String: [(count: Int, continuation: CheckedContinuation<Void, Never>)]] = [:]

    func append(_ event: String) {
        let continuations = lock.withLock {
            events.append(event)
            let eventCount = events.count { $0 == event }
            let ready = waiters[event, default: []].filter { $0.count <= eventCount }
            waiters[event]?.removeAll { $0.count <= eventCount }
            return ready.map(\.continuation)
        }
        continuations.forEach { $0.resume() }
    }

    func values() -> [String] {
        lock.withLock { events }
    }

    func waitFor(_ event: String, count: Int = 1) async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                if events.count(where: { $0 == event }) >= count { return true }
                waiters[event, default: []].append((count, continuation))
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
    private let failureCall: Int?
    private var observationCalls = 0

    init(
        identity: ProcessStartIdentity,
        observations: [[ObservedSocket]],
        events: HelperEventLog,
        failureCall: Int?
    ) {
        self.identity = identity
        self.observations = observations
        self.events = events
        self.failureCall = failureCall
    }

    func processIDs() throws -> [pid_t] { [] }
    func executablePath(pid: pid_t) throws -> URL { URL(fileURLWithPath: "/") }

    func startIdentity(pid: pid_t) throws -> ProcessStartIdentity {
        events.append("sockets.startIdentity")
        return identity
    }

    func sockets(pid: pid_t, allowLoopback: Bool) throws -> [ObservedSocket] {
        events.append("sockets.observe")
        return try lock.withLock {
            observationCalls += 1
            if observationCalls == failureCall {
                events.append("sockets.failure")
                throw FakeSocketError.observationFailed
            }
            guard observations.count > 1 else { return observations[0] }
            return observations.removeFirst()
        }
    }
}

private enum FakeSocketError: Error {
    case observationFailed
}

private actor FakePF: PFControlling {
    enum Failure: Error, Equatable {
        case replace(call: Int)
        case killStates
        case flush(call: Int)
    }

    private let failure: Failure?
    private let events: HelperEventLog
    private let setupTimeAdvance: (@Sendable () -> Void)?
    private var replaceCalls = 0
    private var killCalls = 0
    private var flushes = 0

    init(
        failure: Failure?,
        events: HelperEventLog,
        setupTimeAdvance: (@Sendable () -> Void)?
    ) {
        self.failure = failure
        self.events = events
        self.setupTimeAdvance = setupTimeAdvance
    }

    func verifyAppleAnchor() async throws { events.append("pf.verify") }
    func enable() async throws { events.append("pf.enable") }

    func replaceAnchor(with rules: String) async throws {
        replaceCalls += 1
        events.append("pf.replace")
        if failure == .replace(call: replaceCalls) { throw failure! }
    }

    func killStates(_ pairs: [StatePair]) async throws {
        killCalls += 1
        events.append("pf.killStates")
        if failure == .killStates { throw failure! }
        setupTimeAdvance?()
    }

    func flushAnchor() async throws {
        flushes += 1
        events.append("pf.flush")
        if failure == .flush(call: flushes) { throw failure! }
    }

    func releaseEnableReference() async { events.append("pf.release") }
    func flushCount() -> Int { flushes }
    func replaceCount() -> Int { replaceCalls }
    func killCount() -> Int { killCalls }
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
    private var sleepers: [UUID: Sleeper] = [:]
    private var sleepCount = 0
    private var sleepWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

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
        if autoAdvance {
            lock.withLock { currentElapsed += duration }
            events.append("time.sleep")
        } else {
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let readyWaiters = lock.withLock {
                        sleepers[id] = Sleeper(
                            deadline: currentElapsed + duration,
                            continuation: continuation
                        )
                        sleepCount += 1
                        let ready = sleepWaiters.filter { $0.count <= sleepCount }
                        sleepWaiters.removeAll { $0.count <= sleepCount }
                        return ready.map(\.continuation)
                    }
                    events.append("time.sleep")
                    readyWaiters.forEach { $0.resume() }
                }
            } onCancel: {
                self.cancelSleeper(id)
            }
        }
        await Task.yield()
    }

    func waitUntilSleepCount(_ count: Int) async {
        await withCheckedContinuation { continuation in
            let shouldResume = lock.withLock {
                if sleepCount >= count { return true }
                sleepWaiters.append((count, continuation))
                return false
            }
            if shouldResume { continuation.resume() }
        }
    }

    func advance(by duration: Duration) {
        let due = lock.withLock {
            currentElapsed += duration
            let ready = sleepers.filter { $0.value.deadline <= currentElapsed }
            ready.keys.forEach { sleepers[$0] = nil }
            return ready.map(\.value.continuation)
        }
        due.forEach { $0.resume() }
    }

    private func cancelSleeper(_ id: UUID) {
        let continuation = lock.withLock { sleepers.removeValue(forKey: id)?.continuation }
        continuation?.resume(throwing: CancellationError())
    }

    private struct Sleeper {
        let deadline: Duration
        let continuation: CheckedContinuation<Void, Error>
    }
}
