import Foundation
import PullerCore

public enum HearthstoneGameConnectionSelector {
    /// Hearthstone has used both ports over different client generations/regions.
    /// Keep this list narrow: selecting every TCP socket would also block Battle.net,
    /// telemetry, and update traffic belonging to other parts of the client.
    public static let knownGamePorts: Set<UInt16> = [1_119, 3_724]

    public static func select(
        from sockets: [ObservedSocket],
        activeEndpoint: HearthstoneGameEndpoint? = nil
    ) -> [ObservedSocket] {
        let candidates = sockets.filter { isSupportedTransport($0) }
        let selected: [ObservedSocket]
        if let activeEndpoint {
            // Prefer the exact endpoint from GameNetLogger. During reconnects the
            // log can lag behind the socket table (or contain the previous server
            // address), so fall back to the game-server port rather than reporting
            // that no game connection exists.
            let exact = candidates.filter {
                $0.family == activeEndpoint.family
                    && $0.remoteAddress == activeEndpoint.address
                    && $0.remotePort == activeEndpoint.port
            }
            selected = exact.isEmpty && Self.knownGamePorts.contains(activeEndpoint.port)
                ? candidates.filter { $0.remotePort == activeEndpoint.port }
                : exact
        } else {
            selected = candidates.filter { Self.knownGamePorts.contains($0.remotePort) }
        }

        let fallback = selected.isEmpty
            ? candidates.filter { Self.knownGamePorts.contains($0.remotePort) }
            : selected

        return Set(fallback)
            .sorted(by: socketOrder)
    }

    private static func isSupportedTransport(_ socket: ObservedSocket) -> Bool {
        socket.transport == .tcp
            && !isLoopback(socket.remoteAddress, family: socket.family)
    }

    private static func isLoopback(_ address: String, family: AddressFamily) -> Bool {
        switch family {
        case .ipv4: address.hasPrefix("127.")
        case .ipv6: address == "::1"
        }
    }

    private static func socketOrder(_ lhs: ObservedSocket, _ rhs: ObservedSocket) -> Bool {
        let lhsKey = [
            lhs.family.rawValue,
            lhs.localAddress,
            String(format: "%05d", lhs.localPort),
            lhs.remoteAddress,
            String(format: "%05d", lhs.remotePort),
        ]
        let rhsKey = [
            rhs.family.rawValue,
            rhs.localAddress,
            String(format: "%05d", rhs.localPort),
            rhs.remoteAddress,
            String(format: "%05d", rhs.remotePort),
        ]
        return lhsKey.lexicographicallyPrecedes(rhsKey)
    }
}
