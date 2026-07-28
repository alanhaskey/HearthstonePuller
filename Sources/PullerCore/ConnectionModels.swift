import Darwin

public enum AddressFamily: String, Codable, Sendable, Hashable {
    case ipv4
    case ipv6
}

public enum TransportProtocol: String, Codable, Sendable, Hashable {
    case tcp
    case udp
}

public enum SocketModelError: Error, Equatable {
    case invalidAddress(String)
    case addressFamilyMismatch(String)
    case unsafeRemoteAddress(String)
    case invalidPort(UInt16)
}

public struct ObservedSocket: Codable, Hashable, Sendable {
    public let family: AddressFamily
    public let transport: TransportProtocol
    public let localAddress: String
    public let localPort: UInt16
    public let remoteAddress: String
    public let remotePort: UInt16

    public init(
        family: AddressFamily,
        transport: TransportProtocol,
        localAddress: String,
        localPort: UInt16,
        remoteAddress: String,
        remotePort: UInt16,
        allowLoopback: Bool = false
    ) throws {
        guard localPort != 0 else { throw SocketModelError.invalidPort(localPort) }
        guard remotePort != 0 else { throw SocketModelError.invalidPort(remotePort) }

        _ = try Self.addressBytes(localAddress, family: family)
        let remoteBytes = try Self.addressBytes(remoteAddress, family: family)
        guard Self.isSafeRemote(remoteBytes, family: family, allowLoopback: allowLoopback) else {
            throw SocketModelError.unsafeRemoteAddress(remoteAddress)
        }

        self.family = family
        self.transport = transport
        self.localAddress = localAddress
        self.localPort = localPort
        self.remoteAddress = remoteAddress
        self.remotePort = remotePort
    }

    private static func addressBytes(_ value: String, family: AddressFamily) throws -> [UInt8] {
        switch family {
        case .ipv4:
            var address = in_addr()
            let result = value.withCString { inet_pton(AF_INET, $0, &address) }
            guard result == 1 else { throw SocketModelError.invalidAddress(value) }
            return withUnsafeBytes(of: &address) { Array($0) }
        case .ipv6:
            var address = in6_addr()
            let result = value.withCString { inet_pton(AF_INET6, $0, &address) }
            guard result == 1 else { throw SocketModelError.invalidAddress(value) }
            return withUnsafeBytes(of: &address) { Array($0) }
        }
    }

    private static func isSafeRemote(
        _ bytes: [UInt8],
        family: AddressFamily,
        allowLoopback: Bool
    ) -> Bool {
        guard !bytes.allSatisfy({ $0 == 0 }) else { return false }

        switch family {
        case .ipv4:
            guard bytes.count == 4 else { return false }
            if bytes.allSatisfy({ $0 == 255 }) { return false }
            if bytes[0] >= 224 && bytes[0] <= 239 { return false }
            if bytes[0] == 127 && !allowLoopback { return false }
        case .ipv6:
            guard bytes.count == 16 else { return false }
            if bytes[0] == 255 { return false }
            let isLoopback = bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes.last == 1
            if isLoopback && !allowLoopback { return false }
        }

        return true
    }
}
