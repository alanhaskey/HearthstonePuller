import Darwin
import Foundation
import PullerCore

public struct HearthstoneGameEndpoint: Equatable, Sendable {
    public let family: AddressFamily
    public let address: String
    public let port: UInt16

    public init(address: String, port: UInt16) throws {
        guard port != 0 else { throw SocketModelError.invalidPort(port) }

        if let normalized = try? Self.normalize(address, family: .ipv4, port: port) {
            family = .ipv4
            self.address = normalized
        } else if let normalized = try? Self.normalize(address, family: .ipv6, port: port) {
            family = .ipv6
            self.address = normalized
        } else {
            throw SocketModelError.invalidAddress(address)
        }
        self.port = port
    }

    private static func normalize(
        _ address: String,
        family: AddressFamily,
        port: UInt16
    ) throws -> String {
        let localAddress = family == .ipv4 ? "192.0.2.1" : "2001:db8::1"
        _ = try ObservedSocket(
            family: family,
            transport: .tcp,
            localAddress: localAddress,
            localPort: 1,
            remoteAddress: address,
            remotePort: port
        )

        var output = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        switch family {
        case .ipv4:
            var value = in_addr()
            guard address.withCString({ inet_pton(AF_INET, $0, &value) }) == 1,
                  inet_ntop(AF_INET, &value, &output, socklen_t(output.count)) != nil
            else {
                throw SocketModelError.invalidAddress(address)
            }
        case .ipv6:
            var value = in6_addr()
            guard address.withCString({ inet_pton(AF_INET6, $0, &value) }) == 1,
                  inet_ntop(AF_INET6, &value, &output, socklen_t(output.count)) != nil
            else {
                throw SocketModelError.invalidAddress(address)
            }
        }
        return String(
            decoding: output.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
    }
}

public protocol HearthstoneGameEndpointProviding: Sendable {
    func activeEndpoint() -> HearthstoneGameEndpoint?
}

public struct HearthstoneGameLogEndpointProvider: HearthstoneGameEndpointProviding {
    public static let defaultLogRoot = URL(fileURLWithPath: "/Applications/Hearthstone/Logs")
    static let maximumLogBytes: UInt64 = 256 * 1_024

    private let logRoot: URL

    public init(logRoot: URL = Self.defaultLogRoot) {
        self.logRoot = logRoot.standardizedFileURL
    }

    public func activeEndpoint() -> HearthstoneGameEndpoint? {
        guard let logURL = newestLogURL(),
              let contents = readBoundedTail(of: logURL)
        else {
            return nil
        }
        return Self.activeEndpoint(in: contents)
    }

    static func activeEndpoint(in contents: String) -> HearthstoneGameEndpoint? {
        var endpoint: HearthstoneGameEndpoint?
        for line in contents.split(whereSeparator: \Character.isNewline) {
            if line.contains("Network.DisconnectFromGameServer()"),
               line.contains("Reason: EndGameScreen") {
                endpoint = nil
                continue
            }
            guard let marker = line.range(of: "Network.GotoGameServe() - address=") else {
                continue
            }
            let remainder = line[marker.upperBound...].drop(while: \Character.isWhitespace)
            let token = remainder.prefix { !$0.isWhitespace && $0 != "," }
            if let parsed = parseEndpoint(String(token)) {
                endpoint = parsed
            }
        }
        return endpoint
    }

    private static func parseEndpoint(_ value: String) -> HearthstoneGameEndpoint? {
        let address: String
        let portText: Substring

        if value.hasPrefix("[") {
            guard let closingBracket = value.firstIndex(of: "]"),
                  value.index(after: closingBracket) < value.endIndex,
                  value[value.index(after: closingBracket)] == ":"
            else {
                return nil
            }
            address = String(value[value.index(after: value.startIndex)..<closingBracket])
            portText = value[value.index(closingBracket, offsetBy: 2)...]
        } else {
            guard let separator = value.lastIndex(of: ":") else { return nil }
            address = String(value[..<separator])
            portText = value[value.index(after: separator)...]
        }

        guard let port = UInt16(portText) else { return nil }
        return try? HearthstoneGameEndpoint(address: address, port: port)
    }

    private func newestLogURL() -> URL? {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: logRoot,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        return entries.compactMap { entry -> URL? in
            guard entry.lastPathComponent.hasPrefix("Hearthstone_") else { return nil }
            guard let values = try? entry.resourceValues(forKeys: keys),
                  values.isDirectory == true,
                  values.isSymbolicLink != true
            else {
                return nil
            }
            return entry.appendingPathComponent("GameNetLogger.log", isDirectory: false)
        }
        .sorted { $0.deletingLastPathComponent().lastPathComponent < $1.deletingLastPathComponent().lastPathComponent }
        .last
    }

    private func readBoundedTail(of url: URL) -> String? {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let values = try? url.resourceValues(forKeys: keys),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              let handle = try? FileHandle(forReadingFrom: url)
        else {
            return nil
        }
        defer { try? handle.close() }

        let byteCount = UInt64(max(0, size))
        if byteCount > Self.maximumLogBytes {
            try? handle.seek(toOffset: byteCount - Self.maximumLogBytes)
        }
        return String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
    }
}
