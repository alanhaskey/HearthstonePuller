import XCTest
@testable import PullerCore

final class ConnectionModelsTests: XCTestCase {
    func testRejectsUnspecifiedRemoteAddress() {
        XCTAssertThrowsError(
            try ObservedSocket(
                family: .ipv4,
                transport: .tcp,
                localAddress: "192.0.2.10",
                localPort: 50_123,
                remoteAddress: "0.0.0.0",
                remotePort: 3_724
            )
        )
    }

    func testAcceptsPublicIPv6Endpoint() throws {
        let socket = try ObservedSocket(
            family: .ipv6,
            transport: .udp,
            localAddress: "2001:db8::10",
            localPort: 50_123,
            remoteAddress: "2001:db8::20",
            remotePort: 3_724
        )

        XCTAssertEqual(socket.remoteAddress, "2001:db8::20")
    }
}
