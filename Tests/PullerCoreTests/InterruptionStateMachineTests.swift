import XCTest
@testable import PullerCore

final class InterruptionStateMachineTests: XCTestCase {
    func testCutHasFixedDeadlineAndCannotBeExtended() throws {
        var machine = InterruptionStateMachine()
        machine.observe(connectionCount: 1)

        try machine.beginCut(now: .seconds(10))

        XCTAssertEqual(machine.snapshot(now: .seconds(10)).remainingMilliseconds, 500)
        XCTAssertThrowsError(try machine.beginCut(now: .seconds(10.2)))

        machine.deadlineReached(now: .seconds(10.5))

        XCTAssertEqual(machine.snapshot(now: .seconds(10.5)).state, .waitingForReconnect)
    }

    func testNewConnectionAfterDeadlineReturnsToReady() throws {
        var machine = InterruptionStateMachine()
        machine.observe(connectionCount: 1)
        try machine.beginCut(now: .zero)
        machine.deadlineReached(now: .milliseconds(500))

        machine.observe(connectionCount: 1)

        XCTAssertEqual(machine.snapshot(now: .milliseconds(500)).state, .ready)
    }
}
