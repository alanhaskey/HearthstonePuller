import Darwin
import Foundation
import PullerCore

public typealias RecoveryRequestHandler = @Sendable (
    RecoveryRequest,
    uid_t
) async -> RecoveryResponse

public protocol RecoveryListening: Sendable {
    func start(handler: @escaping RecoveryRequestHandler) async throws
    func stop() async
}

public actor RecoveryServer {
    private let engine: RecoveryEngine
    private let listener: any RecoveryListening

    public init(
        engine: RecoveryEngine,
        listener: any RecoveryListening = UnixRecoveryListener()
    ) {
        self.engine = engine
        self.listener = listener
    }

    public func start() async throws {
        try await engine.start()
        let engine = self.engine
        try await listener.start { request, peerUID in
            guard peerUID == 0 else {
                return .rejected(code: "unauthorized", message: "root peer required")
            }

            do {
                switch request {
                case let .arm(deadlineEpochMilliseconds):
                    let requested = Date(
                        timeIntervalSince1970: Double(deadlineEpochMilliseconds) / 1_000
                    )
                    let accepted = try await engine.arm(deadline: requested)
                    return .armed(
                        deadlineEpochMilliseconds: Self.epochMilliseconds(accepted)
                    )
                case .flushNow:
                    try await engine.flushNow()
                    return .flushed
                case .status:
                    let deadline = await engine.status().map(Self.epochMilliseconds)
                    return .status(deadlineEpochMilliseconds: deadline)
                }
            } catch {
                return .rejected(code: "recovery_failed", message: "recovery operation failed")
            }
        }
    }

    public func stop() async {
        await listener.stop()
    }

    private static func epochMilliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded())
    }
}

public enum RecoverySocketError: Error, Equatable, Sendable {
    case unsafeExistingPath
    case unsafeParentDirectory
    case pathTooLong
    case systemCall(operation: String, errno: Int32)
}

public enum RecoverySocketPathPolicy {
    public static func validateExistingPath(_ path: String) throws {
        var metadata = stat()
        if lstat(path, &metadata) != 0 {
            guard errno == ENOENT else {
                throw RecoverySocketError.systemCall(operation: "lstat", errno: errno)
            }
            return
        }

        let fileType = metadata.st_mode & S_IFMT
        guard fileType == S_IFSOCK, metadata.st_uid == 0 else {
            throw RecoverySocketError.unsafeExistingPath
        }
    }
}

public actor UnixRecoveryListener: RecoveryListening {
    public static let defaultPath = "/var/run/hearthstone-puller/recovery.sock"

    private let path: String
    private var listeningDescriptor: Int32 = -1
    private var acceptTask: Task<Void, Never>?

    public init(path: String = UnixRecoveryListener.defaultPath) {
        self.path = path
    }

    public func start(handler: @escaping RecoveryRequestHandler) async throws {
        guard listeningDescriptor < 0 else { return }
        let descriptor = try Self.makeListeningSocket(path: path)
        listeningDescriptor = descriptor
        acceptTask = Task.detached {
            await Self.acceptConnections(on: descriptor, handler: handler)
        }
    }

    public func stop() async {
        acceptTask?.cancel()
        acceptTask = nil
        if listeningDescriptor >= 0 {
            close(listeningDescriptor)
            listeningDescriptor = -1
        }
        unlink(path)
    }

    private static func makeListeningSocket(path: String) throws -> Int32 {
        let parent = (path as NSString).deletingLastPathComponent
        try ensureParentDirectory(parent)
        try RecoverySocketPathPolicy.validateExistingPath(path)
        if unlink(path) != 0 && errno != ENOENT {
            throw RecoverySocketError.systemCall(operation: "unlink", errno: errno)
        }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw RecoverySocketError.systemCall(operation: "socket", errno: errno)
        }

        do {
            var noSigPipe: Int32 = 1
            guard setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &noSigPipe,
                socklen_t(MemoryLayout<Int32>.size)
            ) == 0 else {
                throw RecoverySocketError.systemCall(operation: "setsockopt", errno: errno)
            }

            var address = sockaddr_un()
            let pathBytes = Array(path.utf8CString)
            let pathCapacity = MemoryLayout.size(ofValue: address.sun_path)
            guard pathBytes.count <= pathCapacity else {
                throw RecoverySocketError.pathTooLong
            }
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            withUnsafeMutableBytes(of: &address.sun_path) { destination in
                pathBytes.withUnsafeBytes { source in
                    destination.copyBytes(from: source)
                }
            }

            let bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    Darwin.bind(
                        descriptor,
                        socketAddress,
                        socklen_t(MemoryLayout<sockaddr_un>.size)
                    )
                }
            }
            guard bindResult == 0 else {
                throw RecoverySocketError.systemCall(operation: "bind", errno: errno)
            }
            guard chown(path, 0, 0) == 0 else {
                throw RecoverySocketError.systemCall(operation: "chown", errno: errno)
            }
            guard chmod(path, 0o600) == 0 else {
                throw RecoverySocketError.systemCall(operation: "chmod", errno: errno)
            }
            guard listen(descriptor, 8) == 0 else {
                throw RecoverySocketError.systemCall(operation: "listen", errno: errno)
            }
            return descriptor
        } catch {
            close(descriptor)
            unlink(path)
            throw error
        }
    }

    private static func ensureParentDirectory(_ path: String) throws {
        var metadata = stat()
        if lstat(path, &metadata) != 0 {
            guard errno == ENOENT else {
                throw RecoverySocketError.systemCall(operation: "lstat(parent)", errno: errno)
            }
            guard mkdir(path, 0o755) == 0 else {
                throw RecoverySocketError.systemCall(operation: "mkdir", errno: errno)
            }
            guard chown(path, 0, 0) == 0 else {
                throw RecoverySocketError.systemCall(operation: "chown(parent)", errno: errno)
            }
            return
        }

        let isDirectory = metadata.st_mode & S_IFMT == S_IFDIR
        let isWritableByOthers = metadata.st_mode & 0o022 != 0
        guard isDirectory,
              metadata.st_uid == 0,
              metadata.st_gid == 0,
              !isWritableByOthers
        else {
            throw RecoverySocketError.unsafeParentDirectory
        }
    }

    private static func acceptConnections(
        on descriptor: Int32,
        handler: @escaping RecoveryRequestHandler
    ) async {
        while !Task.isCancelled {
            let client = accept(descriptor, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            Task.detached {
                await handleClient(client, handler: handler)
                close(client)
            }
        }
    }

    private static func handleClient(
        _ descriptor: Int32,
        handler: @escaping RecoveryRequestHandler
    ) async {
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(descriptor, &peerUID, &peerGID) == 0 else { return }

        var decoder = FrameDecoder()
        var buffer = Array(repeating: UInt8(0), count: 4_096)
        while true {
            let count = recv(descriptor, &buffer, buffer.count, 0)
            guard count > 0 else { return }
            let payloads: [Data]
            do {
                payloads = try decoder.append(buffer.prefix(count))
            } catch {
                return
            }

            for payload in payloads {
                guard let request = try? JSONDecoder().decode(RecoveryRequest.self, from: payload)
                else {
                    return
                }
                let response = await handler(request, peerUID)
                guard let frame = try? FrameEncoder.encode(response),
                      writeAll(frame, to: descriptor)
                else {
                    return
                }
            }
        }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) -> Bool {
        data.withUnsafeBytes { rawBuffer in
            guard var pointer = rawBuffer.baseAddress else { return true }
            var remaining = rawBuffer.count
            while remaining > 0 {
                let written = send(descriptor, pointer, remaining, 0)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { return false }
                pointer = pointer.advanced(by: written)
                remaining -= written
            }
            return true
        }
    }
}
