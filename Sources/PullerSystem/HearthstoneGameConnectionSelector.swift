import Foundation
import PullerCore

public enum HearthstoneGameConnectionSelector {
    public static func select(from sockets: [ObservedSocket]) -> [ObservedSocket] {
        Set(sockets.filter(isSupportedGameConnection)).sorted(by: socketOrder)
    }

    private static func isSupportedGameConnection(_ socket: ObservedSocket) -> Bool {
        socket.transport == .tcp
            && socket.remotePort == 3_724
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
