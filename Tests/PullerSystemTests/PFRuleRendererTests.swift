import Foundation
import PullerCore
import XCTest
@testable import PullerSystem

final class PFRuleRendererTests: XCTestCase {
    func testRendersExactBidirectionalIPv4TCPRules() throws {
        let socket = try ObservedSocket(
            family: .ipv4,
            transport: .tcp,
            localAddress: "192.0.2.10",
            localPort: 50_123,
            remoteAddress: "198.51.100.20",
            remotePort: 3_724
        )

        let result = try PFRuleRenderer.render([socket])

        XCTAssertEqual(PFRuleSet.anchor, "com.apple/hearthstone-puller")
        XCTAssertEqual(
            result.rules,
            """
            block drop out quick inet proto tcp from 192.0.2.10 to 198.51.100.20 port = 3724
            block drop in quick inet proto tcp from 198.51.100.20 port = 3724 to 192.0.2.10

            """
        )
        XCTAssertEqual(
            result.statePairs,
            [.init(family: .ipv4, localAddress: "192.0.2.10", remoteAddress: "198.51.100.20")]
        )
    }

    func testRendersExactBidirectionalIPv6UDPRules() throws {
        let socket = try ObservedSocket(
            family: .ipv6,
            transport: .udp,
            localAddress: "2001:db8::10",
            localPort: 50_124,
            remoteAddress: "2001:db8::20",
            remotePort: 1_112
        )

        let result = try PFRuleRenderer.render([socket])

        XCTAssertEqual(
            result.rules,
            """
            block drop out quick inet6 proto udp from 2001:db8::10 to 2001:db8::20 port = 1112
            block drop in quick inet6 proto udp from 2001:db8::20 port = 1112 to 2001:db8::10

            """
        )
    }

    func testDeduplicatesAndSortsRulesAndStatePairs() throws {
        let tcp = try ObservedSocket(
            family: .ipv4,
            transport: .tcp,
            localAddress: "192.0.2.10",
            localPort: 50_123,
            remoteAddress: "198.51.100.20",
            remotePort: 3_724
        )
        let udp = try ObservedSocket(
            family: .ipv4,
            transport: .udp,
            localAddress: "192.0.2.10",
            localPort: 50_124,
            remoteAddress: "198.51.100.10",
            remotePort: 1_112
        )

        let forward = try PFRuleRenderer.render([tcp, udp, tcp])
        let reverse = try PFRuleRenderer.render([udp, tcp])

        XCTAssertEqual(forward, reverse)
        XCTAssertEqual(forward.statePairs.count, 2)
        XCTAssertTrue(forward.rules.hasSuffix("\n"))
        XCTAssertEqual(forward.rules.components(separatedBy: "\n").filter { !$0.isEmpty }.count, 4)
        XCTAssertLessThan(
            try XCTUnwrap(forward.rules.range(of: "198.51.100.10")?.lowerBound),
            try XCTUnwrap(forward.rules.range(of: "198.51.100.20")?.lowerBound)
        )
    }

    func testRejectsUnsafeSocketDecodedWithoutInitializerValidation() throws {
        let json = Data(
            #"{"family":"ipv4","transport":"tcp","localAddress":"192.0.2.10","localPort":50123,"remoteAddress":"224.0.0.1","remotePort":3724}"#.utf8
        )
        let unsafeSocket = try JSONDecoder().decode(ObservedSocket.self, from: json)

        XCTAssertThrowsError(try PFRuleRenderer.render([unsafeSocket]))
    }
}
