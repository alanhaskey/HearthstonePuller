import PullerCore

public struct PFRuleSet: Equatable, Sendable {
    public static let anchor = "com.apple/hearthstone-puller"

    public let rules: String
    public let statePairs: [StatePair]

    public init(rules: String, statePairs: [StatePair]) {
        self.rules = rules
        self.statePairs = statePairs
    }
}

public struct StatePair: Hashable, Sendable {
    public let family: AddressFamily
    public let localAddress: String
    public let remoteAddress: String

    public init(family: AddressFamily, localAddress: String, remoteAddress: String) {
        self.family = family
        self.localAddress = localAddress
        self.remoteAddress = remoteAddress
    }
}

public enum PFRuleRendererError: Error, Equatable, Sendable {
    case unsafeSocket
}

public enum PFRuleRenderer {
    public static func render(_ sockets: [ObservedSocket]) throws -> PFRuleSet {
        let uniqueSockets = try Set(sockets.map(validated)).sorted(by: socketOrder)
        let lines = uniqueSockets.flatMap(ruleLines)
        let statePairs = Set(uniqueSockets.map { socket in
            StatePair(
                family: socket.family,
                localAddress: socket.localAddress,
                remoteAddress: socket.remoteAddress
            )
        }).sorted(by: statePairOrder)

        return PFRuleSet(
            rules: lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n",
            statePairs: statePairs
        )
    }

    private static func validated(_ socket: ObservedSocket) throws -> ObservedSocket {
        do {
            let validated = try ObservedSocket(
                family: socket.family,
                transport: socket.transport,
                localAddress: socket.localAddress,
                localPort: socket.localPort,
                remoteAddress: socket.remoteAddress,
                remotePort: socket.remotePort
            )
            _ = try ObservedSocket(
                family: socket.family,
                transport: socket.transport,
                localAddress: socket.remoteAddress,
                localPort: socket.remotePort,
                remoteAddress: socket.localAddress,
                remotePort: socket.localPort
            )
            return validated
        } catch {
            throw PFRuleRendererError.unsafeSocket
        }
    }

    private static func ruleLines(for socket: ObservedSocket) -> [String] {
        let family = socket.family == .ipv4 ? "inet" : "inet6"
        let transport = socket.transport.rawValue
        let localPort = socket.localPort
        let remotePort = socket.remotePort

        return [
            "block return out quick \(family) proto \(transport) "
                + "from \(socket.localAddress) port = \(localPort) "
                + "to \(socket.remoteAddress) port = \(remotePort)",
            "block return in quick \(family) proto \(transport) "
                + "from \(socket.remoteAddress) port = \(remotePort) "
                + "to \(socket.localAddress) port = \(localPort)",
        ]
    }

    private static func socketOrder(_ lhs: ObservedSocket, _ rhs: ObservedSocket) -> Bool {
        if lhs.family.rawValue != rhs.family.rawValue {
            return lhs.family.rawValue < rhs.family.rawValue
        }
        if lhs.remoteAddress != rhs.remoteAddress {
            return lhs.remoteAddress < rhs.remoteAddress
        }
        if lhs.transport.rawValue != rhs.transport.rawValue {
            return lhs.transport.rawValue < rhs.transport.rawValue
        }
        if lhs.remotePort != rhs.remotePort {
            return lhs.remotePort < rhs.remotePort
        }
        if lhs.localAddress != rhs.localAddress {
            return lhs.localAddress < rhs.localAddress
        }
        return lhs.localPort < rhs.localPort
    }

    private static func statePairOrder(_ lhs: StatePair, _ rhs: StatePair) -> Bool {
        if lhs.family.rawValue != rhs.family.rawValue {
            return lhs.family.rawValue < rhs.family.rawValue
        }
        if lhs.localAddress != rhs.localAddress {
            return lhs.localAddress < rhs.localAddress
        }
        return lhs.remoteAddress < rhs.remoteAddress
    }
}
