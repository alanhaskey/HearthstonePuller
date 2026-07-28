import PullerCore
import XCTest
@testable import PullerSystem

final class HearthstoneGameConnectionSelectorTests: XCTestCase {
    func testSelectsOnlyNonLoopbackTCP3724Connections() throws {
        let game = try socket(transport: .tcp, localPort: 50_123, remotePort: 3_724)
        let https = try socket(transport: .tcp, localPort: 50_124, remotePort: 443)
        let login = try socket(transport: .tcp, localPort: 50_125, remotePort: 1_119)
        let udp = try socket(transport: .udp, localPort: 50_126, remotePort: 3_724)
        let loopback = try ObservedSocket(
            family: .ipv4,
            transport: .tcp,
            localAddress: "127.0.0.1",
            localPort: 50_127,
            remoteAddress: "127.0.0.1",
            remotePort: 3_724,
            allowLoopback: true
        )

        let selected = HearthstoneGameConnectionSelector.select(
            from: [https, game, login, udp, loopback]
        )

        XCTAssertEqual(selected, [game])
    }

    func testDeduplicatesAndSortsByFullTuple() throws {
        let later = try socket(transport: .tcp, localPort: 50_124, remotePort: 3_724)
        let earlier = try socket(transport: .tcp, localPort: 50_123, remotePort: 3_724)

        let selected = HearthstoneGameConnectionSelector.select(
            from: [later, earlier, later]
        )

        XCTAssertEqual(selected, [earlier, later])
    }

    private func socket(
        transport: TransportProtocol,
        localPort: UInt16,
        remotePort: UInt16
    ) throws -> ObservedSocket {
        try ObservedSocket(
            family: .ipv4,
            transport: transport,
            localAddress: "192.0.2.10",
            localPort: localPort,
            remoteAddress: "198.51.100.20",
            remotePort: remotePort
        )
    }
}
