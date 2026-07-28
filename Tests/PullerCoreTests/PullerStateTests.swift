import XCTest
@testable import PullerCore

final class PullerStateTests: XCTestCase {
    func testReadyAndNotTriggeredAreActionable() {
        XCTAssertTrue(PullerState.ready.isActionable)
        XCTAssertTrue(PullerState.notTriggered.isActionable)
        XCTAssertFalse(PullerState.absent.isActionable)
        XCTAssertFalse(PullerState.cutting.isActionable)
        XCTAssertFalse(PullerState.waitingForReconnect.isActionable)
    }
}
