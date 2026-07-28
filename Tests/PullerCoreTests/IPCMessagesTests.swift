import XCTest
@testable import PullerCore

final class IPCMessagesTests: XCTestCase {
    func testCutRequestHasNoPayload() throws {
        let data = try JSONEncoder().encode(HelperRequest.cut)

        XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"cut":{}}"#)
    }

    func testStatusResponseRoundTrips() throws {
        let response = HelperResponse.status(
            PullerSnapshot(
                state: .ready,
                connectionCount: 2,
                remainingMilliseconds: 12_345
            )
        )

        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(HelperResponse.self, from: data)

        XCTAssertEqual(decoded, response)
    }
}
