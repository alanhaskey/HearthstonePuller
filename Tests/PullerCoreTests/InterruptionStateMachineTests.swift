import XCTest
@testable import PullerCore

final class InterruptionStateMachineTests: XCTestCase {
    func testCutRequiresExplicitResetCompletionAndCannotBeExtended() throws {
        var machine = InterruptionStateMachine()
        machine.observe(connectionCount: 1)

        try machine.beginCut()

        XCTAssertEqual(machine.snapshot().state, .cutting)
        XCTAssertEqual(machine.snapshot().remainingMilliseconds, 0)
        XCTAssertThrowsError(try machine.beginCut())

        machine.resetCompleted()

        XCTAssertEqual(machine.snapshot().state, .waitingForReconnect)
    }

    func testNewConnectionAfterResetReturnsToReady() throws {
        var machine = InterruptionStateMachine()
        machine.observe(connectionCount: 1)
        try machine.beginCut()
        machine.resetCompleted()

        machine.observe(connectionCount: 1)

        XCTAssertEqual(machine.snapshot().state, .ready)
    }

    func testUntriggeredOutcomeStaysVisibleAndCanRetry() throws {
        var machine = InterruptionStateMachine()
        machine.observe(connectionCount: 1)
        try machine.beginCut()

        machine.markNotTriggered()
        XCTAssertEqual(machine.snapshot().state, .notTriggered)

        machine.observe(connectionCount: 1)
        XCTAssertEqual(machine.snapshot().state, .notTriggered)

        try machine.beginCut()
        XCTAssertEqual(machine.snapshot().state, .cutting)
    }

    func testReconnectTimeoutOnlyEndsWaitingState() throws {
        var machine = InterruptionStateMachine()
        machine.observe(connectionCount: 1)
        try machine.beginCut()
        machine.resetCompleted()

        machine.reconnectTimedOut()
        XCTAssertEqual(machine.snapshot().state, .absent)

        machine.observe(connectionCount: 1)
        machine.reconnectTimedOut()
        XCTAssertEqual(machine.snapshot().state, .ready)
    }
}
