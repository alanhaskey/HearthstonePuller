import Darwin
import Foundation
import PullerCore

public enum RecoveryClientError: Error, Equatable, Sendable {
    case unsafeSocketPath
    case pathTooLong
    case systemCall(operation: String, errno: Int32)
    case disconnected
    case unexpectedResponse
}

public actor RecoveryClient: RecoveryArming {
    public static let defaultPath = "/var/run/hearthstone-puller/recovery.sock"

    private let path: String

    public init(path: String = RecoveryClient.defaultPath) {
        self.path = path
    }

    public func verifyAvailable() async throws {
        guard case .status = try request(.status) else {
            throw RecoveryClientError.unexpectedResponse
        }
    }

    public func arm(deadline: Date) async throws {
        let milliseconds = Int64((deadline.timeIntervalSince1970 * 1_000).rounded())
        guard case .armed = try request(
            .arm(deadlineEpochMilliseconds: milliseconds)
        ) else {
            throw RecoveryClientError.unexpectedResponse
        }
    }

    public func flushNow() async throws {
        guard case .flushed = try request(.flushNow) else {
            throw RecoveryClientError.unexpectedResponse
        }
    }

    private func request(_ request: RecoveryRequest) throws -> RecoveryResponse {
        try validateSocketPath()
        let descriptor = try connectSocket()
        defer { close(descriptor) }

        var noSigPipe: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            throw RecoveryClientError.systemCall(operation: "setsockopt", errno: errno)
        }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        _ = setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )

        let frame = try FrameEncoder.encode(request)
        guard Self.writeAll(frame, descriptor: descriptor) else {
            throw RecoveryClientError.systemCall(operation: "send", errno: errno)
        }

        var decoder = FrameDecoder()
        var buffer = Array(repeating: UInt8(0), count: 4_096)
        while true {
            let count = recv(descriptor, &buffer, buffer.count, 0)
            guard count > 0 else { throw RecoveryClientError.disconnected }
            let payloads = try decoder.append(buffer.prefix(count))
            if let payload = payloads.first {
                return try JSONDecoder().decode(RecoveryResponse.self, from: payload)
            }
        }
    }

    private func validateSocketPath() throws {
        var metadata = stat()
        guard lstat(path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFSOCK,
              metadata.st_uid == 0,
              metadata.st_mode & 0o022 == 0
        else {
            throw RecoveryClientError.unsafeSocketPath
        }
    }

    private func connectSocket() throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw RecoveryClientError.systemCall(operation: "socket", errno: errno)
        }
        do {
            var address = sockaddr_un()
            let bytes = Array(path.utf8CString)
            guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
                throw RecoveryClientError.pathTooLong
            }
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            withUnsafeMutableBytes(of: &address.sun_path) { destination in
                bytes.withUnsafeBytes { destination.copyBytes(from: $0) }
            }
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else {
                throw RecoveryClientError.systemCall(operation: "connect", errno: errno)
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private static func writeAll(_ data: Data, descriptor: Int32) -> Bool {
        data.withUnsafeBytes { bytes in
            guard var pointer = bytes.baseAddress else { return true }
            var remaining = bytes.count
            while remaining > 0 {
                let count = send(descriptor, pointer, remaining, 0)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                pointer = pointer.advanced(by: count)
                remaining -= count
            }
            return true
        }
    }
}
