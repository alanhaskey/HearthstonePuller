import XCTest
@testable import PullerCore

final class FramedConnectionTests: XCTestCase {
    func testDecoderRejectsFrameLargerThan64KiB() {
        var decoder = FrameDecoder(maximumPayloadSize: 65_536)

        XCTAssertThrowsError(try decoder.append(Data([0x00, 0x01, 0x00, 0x01]))) {
            XCTAssertEqual($0 as? FrameError, .payloadTooLarge(65_537))
        }
    }

    func testDecoderWaitsForPartialPayload() throws {
        let encoded = try FrameEncoder.encode(HelperRequest.status)
        var decoder = FrameDecoder()

        XCTAssertEqual(try decoder.append(encoded.prefix(5)), [])
        let payloads = try decoder.append(encoded.dropFirst(5))

        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(
            try JSONDecoder().decode(HelperRequest.self, from: payloads[0]),
            .status
        )
    }
}
