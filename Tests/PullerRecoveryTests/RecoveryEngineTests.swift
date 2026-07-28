import Foundation
import PullerCore
import PullerSystem
import XCTest
@testable import PullerRecovery

final class RecoveryEngineTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_000)

    func testArmAcknowledgesAfterDeadlineIsStored() async throws {
        let pf = FakePFController()
        let time = ManualRecoveryTimeSource(wallNow: epoch)
        let engine = RecoveryEngine(pf: pf, time: time)
        let requested = epoch.addingTimeInterval(2)

        let accepted = try await engine.arm(deadline: requested)
        let stored = await engine.status()

        XCTAssertEqual(accepted, requested)
        XCTAssertEqual(stored, requested)
    }

    func testLaterArmCanShortenButNeverExtendDeadline() async throws {
        let engine = RecoveryEngine(
            pf: FakePFController(),
            time: ManualRecoveryTimeSource(wallNow: epoch)
        )
        let original = try await engine.arm(deadline: epoch.addingTimeInterval(2))

        let attemptedExtension = try await engine.arm(deadline: epoch.addingTimeInterval(2.4))
        let shortened = try await engine.arm(deadline: epoch.addingTimeInterval(1))
        let stored = await engine.status()

        XCTAssertEqual(attemptedExtension, original)
        XCTAssertEqual(shortened, epoch.addingTimeInterval(1))
        XCTAssertEqual(stored, shortened)
    }

    func testDeadlineFlushesExactlyOnce() async throws {
        let pf = FakePFController()
        let time = ManualRecoveryTimeSource(wallNow: epoch)
        let engine = RecoveryEngine(pf: pf, time: time)
        _ = try await engine.arm(deadline: epoch.addingTimeInterval(2))
        await time.waitUntilTimerIsScheduled()

        await time.advance(wallBy: 2, monotonicBy: .seconds(2))
        await pf.waitForFlushCount(1)
        await time.advance(wallBy: 10, monotonicBy: .seconds(10))
        let flushCount = await pf.flushCount()
        let status = await engine.status()

        XCTAssertEqual(flushCount, 1)
        XCTAssertNil(status)
    }

    func testFlushNowFlushesAndDisarms() async throws {
        let pf = FakePFController()
        let engine = RecoveryEngine(
            pf: pf,
            time: ManualRecoveryTimeSource(wallNow: epoch)
        )
        _ = try await engine.arm(deadline: epoch.addingTimeInterval(2))

        try await engine.flushNow()
        let flushCount = await pf.flushCount()
        let status = await engine.status()

        XCTAssertEqual(flushCount, 1)
        XCTAssertNil(status)
    }

    func testStartFlushesStaleAnchorBeforeReturning() async throws {
        let pf = FakePFController()
        let engine = RecoveryEngine(
            pf: pf,
            time: ManualRecoveryTimeSource(wallNow: epoch)
        )

        try await engine.start()
        let flushCount = await pf.flushCount()
        let status = await engine.status()

        XCTAssertEqual(flushCount, 1)
        XCTAssertNil(status)
    }

    func testWakeAfterWallDeadlineFlushesImmediately() async throws {
        let pf = FakePFController()
        let time = ManualRecoveryTimeSource(wallNow: epoch)
        let engine = RecoveryEngine(pf: pf, time: time)
        _ = try await engine.arm(deadline: epoch.addingTimeInterval(2))

        await time.advance(wallBy: 3, monotonicBy: .zero)
        try await engine.handleWake()
        let flushCount = await pf.flushCount()
        let status = await engine.status()

        XCTAssertEqual(flushCount, 1)
        XCTAssertNil(status)
    }

    func testClampsRecoveryWindowToPointOneThroughTwoPointFiveSeconds() async throws {
        let time = ManualRecoveryTimeSource(wallNow: epoch)
        let early = RecoveryEngine(pf: FakePFController(), time: time)
        let late = RecoveryEngine(pf: FakePFController(), time: time)

        let earliest = try await early.arm(deadline: epoch.addingTimeInterval(-10))
        let latest = try await late.arm(deadline: epoch.addingTimeInterval(10))

        XCTAssertEqual(earliest.timeIntervalSince(epoch), 0.1, accuracy: 0.001)
        XCTAssertEqual(latest.timeIntervalSince(epoch), 2.5, accuracy: 0.001)
    }
}

final class RecoveryServerTests: XCTestCase {
    func testFlushesStaleAnchorBeforeListenerAcceptsRequests() async throws {
        let events = EventLog()
        let pf = OrderedPFController(events: events)
        let listener = FakeRecoveryListener(events: events)
        let engine = RecoveryEngine(
            pf: pf,
            time: ManualRecoveryTimeSource(wallNow: Date(timeIntervalSince1970: 1_000))
        )
        let server = RecoveryServer(engine: engine, listener: listener)

        try await server.start()
        let recordedEvents = await events.values()

        XCTAssertEqual(recordedEvents, ["flush", "listen"])
    }

    func testRejectsNonRootPeerBeforeHandlingRequest() async throws {
        let epoch = Date(timeIntervalSince1970: 1_000)
        let engine = RecoveryEngine(
            pf: FakePFController(),
            time: ManualRecoveryTimeSource(wallNow: epoch)
        )
        let listener = FakeRecoveryListener(events: EventLog())
        let server = RecoveryServer(engine: engine, listener: listener)
        try await server.start()

        let response = try await listener.send(
            .arm(deadlineEpochMilliseconds: 1_002_000),
            peerUID: 501
        )
        let status = await engine.status()

        XCTAssertEqual(response, .rejected(code: "unauthorized", message: "root peer required"))
        XCTAssertNil(status)
    }

    func testRootPeerCanArmAndQueryStatus() async throws {
        let epoch = Date(timeIntervalSince1970: 1_000)
        let engine = RecoveryEngine(
            pf: FakePFController(),
            time: ManualRecoveryTimeSource(wallNow: epoch)
        )
        let listener = FakeRecoveryListener(events: EventLog())
        let server = RecoveryServer(engine: engine, listener: listener)
        try await server.start()

        let armed = try await listener.send(
            .arm(deadlineEpochMilliseconds: 1_002_000),
            peerUID: 0
        )
        let status = try await listener.send(.status, peerUID: 0)

        XCTAssertEqual(armed, .armed(deadlineEpochMilliseconds: 1_002_000))
        XCTAssertEqual(status, .status(deadlineEpochMilliseconds: 1_002_000))
    }

    func testSocketPathPolicyRejectsRegularFileAndSymlink() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let regularFile = directory.appendingPathComponent("regular")
        XCTAssertTrue(FileManager.default.createFile(atPath: regularFile.path, contents: Data()))
        XCTAssertThrowsError(try RecoverySocketPathPolicy.validateExistingPath(regularFile.path))

        let symlink = directory.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: regularFile)
        XCTAssertThrowsError(try RecoverySocketPathPolicy.validateExistingPath(symlink.path))
    }
}

private actor ManualRecoveryTimeSource: RecoveryTimeSource {
    private var currentWall: Date
    private var currentMonotonic: Duration = .zero
    private var sleepers: [UUID: Sleeper] = [:]
    private var schedulingWaiters: [CheckedContinuation<Void, Never>] = []

    init(wallNow: Date) {
        self.currentWall = wallNow
    }

    func now() -> RecoveryTime {
        RecoveryTime(wall: currentWall, monotonic: currentMonotonic)
    }

    func sleep(until deadline: Duration) async throws {
        if currentMonotonic >= deadline { return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                let waiters = schedulingWaiters
                schedulingWaiters.removeAll()
                waiters.forEach { $0.resume() }
            }
        } onCancel: {
            Task { await self.cancelSleeper(id) }
        }
    }

    func waitUntilTimerIsScheduled() async {
        if !sleepers.isEmpty { return }
        await withCheckedContinuation { continuation in
            schedulingWaiters.append(continuation)
        }
    }

    func advance(wallBy wallInterval: TimeInterval, monotonicBy interval: Duration) {
        currentWall = currentWall.addingTimeInterval(wallInterval)
        currentMonotonic += interval
        let due = sleepers.filter { $0.value.deadline <= currentMonotonic }
        for (id, sleeper) in due {
            sleepers[id] = nil
            sleeper.continuation.resume()
        }
    }

    private func cancelSleeper(_ id: UUID) {
        guard let sleeper = sleepers.removeValue(forKey: id) else { return }
        sleeper.continuation.resume(throwing: CancellationError())
    }

    private struct Sleeper {
        let deadline: Duration
        let continuation: CheckedContinuation<Void, Error>
    }
}

private actor FakePFController: PFControlling {
    private var flushes = 0
    private var flushWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func verifyAppleAnchor() async throws {}
    func enable() async throws {}
    func replaceAnchor(with rules: String) async throws {}
    func killStates(_ pairs: [StatePair]) async throws {}

    func flushAnchor() async throws {
        flushes += 1
        let ready = flushWaiters.filter { $0.count <= flushes }
        flushWaiters.removeAll { $0.count <= flushes }
        ready.forEach { $0.continuation.resume() }
    }

    func releaseEnableReference() async {}

    func flushCount() -> Int {
        flushes
    }

    func waitForFlushCount(_ count: Int) async {
        if flushes >= count { return }
        await withCheckedContinuation { continuation in
            flushWaiters.append((count, continuation))
        }
    }
}

private actor EventLog {
    private var events: [String] = []

    func append(_ event: String) {
        events.append(event)
    }

    func values() -> [String] {
        events
    }
}

private actor OrderedPFController: PFControlling {
    private let events: EventLog

    init(events: EventLog) {
        self.events = events
    }

    func verifyAppleAnchor() async throws {}
    func enable() async throws {}
    func replaceAnchor(with rules: String) async throws {}
    func killStates(_ pairs: [StatePair]) async throws {}
    func flushAnchor() async throws { await events.append("flush") }
    func releaseEnableReference() async {}
}

private actor FakeRecoveryListener: RecoveryListening {
    typealias Handler = @Sendable (RecoveryRequest, uid_t) async -> RecoveryResponse

    private let events: EventLog
    private var handler: Handler?

    init(events: EventLog) {
        self.events = events
    }

    func start(handler: @escaping Handler) async throws {
        self.handler = handler
        await events.append("listen")
    }

    func stop() async {
        handler = nil
    }

    func send(_ request: RecoveryRequest, peerUID: uid_t) async throws -> RecoveryResponse {
        guard let handler else { throw FakeRecoveryListenerError.notStarted }
        return await handler(request, peerUID)
    }
}

private enum FakeRecoveryListenerError: Error {
    case notStarted
}
