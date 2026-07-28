import CProcShim
import Darwin
import Foundation
import PullerCore

public struct ProcessStartIdentity: Hashable, Codable, Sendable {
    public let seconds: UInt64
    public let microseconds: UInt64

    public init(seconds: UInt64, microseconds: UInt64) {
        self.seconds = seconds
        self.microseconds = microseconds
    }
}

public protocol ProcessSocketObserving: Sendable {
    func processIDs() throws -> [pid_t]
    func executablePath(pid: pid_t) throws -> URL
    func startIdentity(pid: pid_t) throws -> ProcessStartIdentity
    func sockets(pid: pid_t, allowLoopback: Bool) throws -> [ObservedSocket]
}

public enum ProcessObservationError: Error, Equatable, Sendable {
    case systemCall(operation: String, errno: Int32)
    case invalidExecutablePath(pid: pid_t)
    case unstableSnapshot(operation: String)
}

public struct ProcessSocketObserver: ProcessSocketObserving {
    public init() {}

    public func processIDs() throws -> [pid_t] {
        let required = try checkedCount(puller_list_pids(nil, 0), operation: "proc_listpids")
        guard required > 0 else { return [] }

        var pids = Array(repeating: pid_t(0), count: required + 32)
        let count = try pids.withUnsafeMutableBufferPointer { buffer in
            try checkedCount(
                puller_list_pids(buffer.baseAddress, Int32(buffer.count)),
                operation: "proc_listpids"
            )
        }
        return pids.prefix(min(count, pids.count)).filter { $0 > 0 }.sorted()
    }

    public func executablePath(pid: pid_t) throws -> URL {
        var path = Array(repeating: CChar(0), count: 4 * Int(MAXPATHLEN))
        let byteCount = path.withUnsafeMutableBufferPointer { buffer in
            puller_process_path(pid, buffer.baseAddress, Int32(buffer.count))
        }
        _ = try checkedResult(byteCount, operation: "proc_pidpath")

        guard let terminator = path.firstIndex(of: 0), terminator > 0 else {
            throw ProcessObservationError.invalidExecutablePath(pid: pid)
        }
        return URL(fileURLWithPath: String(decoding: path[..<terminator].map(UInt8.init(bitPattern:)), as: UTF8.self))
    }

    public func startIdentity(pid: pid_t) throws -> ProcessStartIdentity {
        var seconds: UInt64 = 0
        var microseconds: UInt64 = 0
        try checkedZero(
            puller_process_start(pid, &seconds, &microseconds),
            operation: "proc_pidinfo(PROC_PIDTBSDINFO)"
        )
        return ProcessStartIdentity(seconds: seconds, microseconds: microseconds)
    }

    public func sockets(pid: pid_t, allowLoopback: Bool = false) throws -> [ObservedSocket] {
        var capacity = try checkedCount(
            puller_list_sockets(pid, nil, 0),
            operation: "proc_pidinfo(PROC_PIDLISTFDS)"
        )
        guard capacity > 0 else { return [] }

        for _ in 0..<3 {
            var records = Array(repeating: puller_socket_record(), count: capacity)
            let count = try records.withUnsafeMutableBufferPointer { buffer in
                try checkedCount(
                    puller_list_sockets(pid, buffer.baseAddress, Int32(buffer.count)),
                    operation: "proc_pidinfo(PROC_PIDLISTFDS)"
                )
            }
            if count > capacity {
                capacity = count
                continue
            }

            let sockets = records.prefix(count).compactMap { record in
                observedSocket(from: record, allowLoopback: allowLoopback)
            }
            return Array(Set(sockets)).sorted(by: socketSortOrder)
        }

        throw ProcessObservationError.unstableSnapshot(operation: "socket enumeration")
    }

    private func observedSocket(
        from record: puller_socket_record,
        allowLoopback: Bool
    ) -> ObservedSocket? {
        let family: AddressFamily
        let addressFamily: Int32
        switch record.family {
        case AF_INET:
            family = .ipv4
            addressFamily = AF_INET
        case AF_INET6:
            family = .ipv6
            addressFamily = AF_INET6
        default:
            return nil
        }

        let transport: TransportProtocol
        switch record.protocol_number {
        case IPPROTO_TCP:
            transport = .tcp
        case IPPROTO_UDP:
            transport = .udp
        default:
            return nil
        }

        guard
            let localAddress = numericAddress(record.local_address, family: addressFamily),
            let remoteAddress = numericAddress(record.remote_address, family: addressFamily)
        else {
            return nil
        }

        return try? ObservedSocket(
            family: family,
            transport: transport,
            localAddress: localAddress,
            localPort: record.local_port,
            remoteAddress: remoteAddress,
            remotePort: record.remote_port,
            allowLoopback: allowLoopback
        )
    }

    private func numericAddress<AddressBytes>(
        _ bytes: AddressBytes,
        family: Int32
    ) -> String? {
        var bytes = bytes
        var output = Array(repeating: CChar(0), count: Int(INET6_ADDRSTRLEN))
        let result = withUnsafePointer(to: &bytes) { pointer in
            pointer.withMemoryRebound(to: UInt8.self, capacity: 16) { address in
                inet_ntop(family, address, &output, socklen_t(output.count))
            }
        }
        guard result != nil else { return nil }
        guard let terminator = output.firstIndex(of: 0) else { return nil }
        return String(
            decoding: output[..<terminator].map(UInt8.init(bitPattern:)),
            as: UTF8.self
        )
    }

    private func socketSortOrder(_ lhs: ObservedSocket, _ rhs: ObservedSocket) -> Bool {
        let lhsKey = [
            lhs.family.rawValue,
            lhs.transport.rawValue,
            lhs.localAddress,
            String(format: "%05d", lhs.localPort),
            lhs.remoteAddress,
            String(format: "%05d", lhs.remotePort),
        ]
        let rhsKey = [
            rhs.family.rawValue,
            rhs.transport.rawValue,
            rhs.localAddress,
            String(format: "%05d", rhs.localPort),
            rhs.remoteAddress,
            String(format: "%05d", rhs.remotePort),
        ]
        return lhsKey.lexicographicallyPrecedes(rhsKey)
    }

    private func checkedCount(_ result: Int32, operation: String) throws -> Int {
        Int(try checkedResult(result, operation: operation))
    }

    private func checkedResult(_ result: Int32, operation: String) throws -> Int32 {
        guard result >= 0 else {
            throw ProcessObservationError.systemCall(operation: operation, errno: -result)
        }
        return result
    }

    private func checkedZero(_ result: Int32, operation: String) throws {
        guard result == 0 else {
            throw ProcessObservationError.systemCall(operation: operation, errno: -result)
        }
    }
}
