import XCTest
@testable import PullerCore

final class PullerStateTests: XCTestCase {
    func testReadyIsActionable() {
        XCTAssertTrue(PullerState.ready.isActionable)
        XCTAssertFalse(PullerState.absent.isActionable)
    }
}
