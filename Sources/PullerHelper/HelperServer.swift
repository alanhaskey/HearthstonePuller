import Darwin
import Foundation
import PullerCore
import PullerSystem

public protocol HelperRequestHandling: Sendable {
    func handle(_ request: HelperRequest) async -> HelperResponse
}

extension HelperEngine: HelperRequestHandling {}

public typealias HelperPeerRequestHandler = @Sendable (
    HelperRequest,
    uid_t
) async -> HelperResponse

public protocol HelperListening: Sendable {
    func start(handler: @escaping HelperPeerRequestHandler) async throws
    func stop() async
}

public actor HelperServer {
    private let handler: any HelperRequestHandling
    private let allowedUID: uid_t
    private let listener: any HelperListening

    public init(
        handler: any HelperRequestHandling,
        allowedUID: uid_t,
        listener: (any HelperListening)? = nil
    ) {
        self.handler = handler
        self.allowedUID = allowedUID
        self.listener = listener ?? UnixHelperListener(allowedUID: allowedUID)
    }

    public func start() async throws {
        let handler = self.handler
        let allowedUID = self.allowedUID
        try await listener.start { request, peerUID in
            guard peerUID == allowedUID else {
                return .rejected(
                    code: "unauthorized",
                    message: "configured local user required",
                    snapshot: PullerSnapshot(
                        state: .error,
                        connectionCount: 0,
                        remainingMilliseconds: 0,
                        errorCode: .unauthorizedClient,
                        message: "unauthorized local peer"
                    )
                )
            }
            return await handler.handle(request)
        }
    }

    public func stop() async {
        await listener.stop()
    }
}

public enum HelperConnectionError: Error, Equatable, Sendable {
    case malformedRequest
    case rateLimited
}

public struct HelperFrameSession: Sendable {
    private var decoder = FrameDecoder()
    private var requestTimes: [TimeInterval] = []

    public init() {}

    public mutating func ingest(
        _ bytes: Data,
        now: TimeInterval
    ) throws -> [HelperRequest] {
        let payloads = try decoder.append(bytes)
        let requests: [HelperRequest]
        do {
            requests = try payloads.map {
                try JSONDecoder().decode(HelperRequest.self, from: $0)
            }
        } catch {
            throw HelperConnectionError.malformedRequest
        }

        requestTimes.removeAll { $0 <= now - 1 }
        guard requestTimes.count + requests.count <= 10 else {
            throw HelperConnectionError.rateLimited
        }
        requestTimes.append(contentsOf: repeatElement(now, count: requests.count))
        return requests
    }
}

public actor HelperClientLimiter {
    private let maximumClients: Int
    private var activeClients = 0

    public init(maximumClients: Int = 8) {
        self.maximumClients = maximumClients
    }

    public func acquire() -> Bool {
        guard activeClients < maximumClients else { return false }
        activeClients += 1
        return true
    }

    public func release() {
        activeClients = max(0, activeClients - 1)
    }
}

public enum HelperSocketError: Error, Equatable, Sendable {
    case unsafeExistingPath
    case unsafeParentDirectory
    case pathTooLong
    case systemCall(operation: String, errno: Int32)
}

public enum HelperSocketPathPolicy {
    public static func validateExistingPath(
        _ path: String,
        allowedOwner: uid_t = 0
    ) throws {
        var metadata = stat()
        if lstat(path, &metadata) != 0 {
            guard errno == ENOENT else {
                throw HelperSocketError.systemCall(operation: "lstat", errno: errno)
            }
            return
        }
        let ownerAllowed = metadata.st_uid == 0 || metadata.st_uid == allowedOwner
        guard metadata.st_mode & S_IFMT == S_IFSOCK, ownerAllowed else {
            throw HelperSocketError.unsafeExistingPath
        }
    }
}

public actor UnixHelperListener: HelperListening {
    public static let defaultPath = "/var/run/hearthstone-puller/helper.sock"

    private let path: String
    private let allowedUID: uid_t
    private let limiter: HelperClientLimiter
    private var descriptor: Int32 = -1
    private var acceptTask: Task<Void, Never>?

    public init(
        path: String = UnixHelperListener.defaultPath,
        allowedUID: uid_t,
        limiter: HelperClientLimiter = HelperClientLimiter()
    ) {
        self.path = path
        self.allowedUID = allowedUID
        self.limiter = limiter
    }

    public func start(handler: @escaping HelperPeerRequestHandler) async throws {
        guard descriptor < 0 else { return }
        let socket = try Self.makeSocket(path: path, allowedUID: allowedUID)
        descriptor = socket
        let limiter = self.limiter
        acceptTask = Task.detached {
            await Self.acceptConnections(on: socket, limiter: limiter, handler: handler)
        }
    }

    public func stop() async {
        acceptTask?.cancel()
        acceptTask = nil
        if descriptor >= 0 {
            close(descriptor)
            descriptor = -1
        }
        unlink(path)
    }

    private static func makeSocket(path: String, allowedUID: uid_t) throws -> Int32 {
        let parent = (path as NSString).deletingLastPathComponent
        try ensureParent(parent)
        try HelperSocketPathPolicy.validateExistingPath(path, allowedOwner: allowedUID)
        if unlink(path) != 0 && errno != ENOENT {
            throw HelperSocketError.systemCall(operation: "unlink", errno: errno)
        }

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw HelperSocketError.systemCall(operation: "socket", errno: errno)
        }
        do {
            var address = sockaddr_un()
            let bytes = Array(path.utf8CString)
            guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
                throw HelperSocketError.pathTooLong
            }
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            withUnsafeMutableBytes(of: &address.sun_path) { destination in
                bytes.withUnsafeBytes { destination.copyBytes(from: $0) }
            }
            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else {
                throw HelperSocketError.systemCall(operation: "bind", errno: errno)
            }
            guard chown(path, allowedUID, 0) == 0 else {
                throw HelperSocketError.systemCall(operation: "chown", errno: errno)
            }
            guard chmod(path, 0o600) == 0 else {
                throw HelperSocketError.systemCall(operation: "chmod", errno: errno)
            }
            guard listen(descriptor, 8) == 0 else {
                throw HelperSocketError.systemCall(operation: "listen", errno: errno)
            }
            return descriptor
        } catch {
            close(descriptor)
            unlink(path)
            throw error
        }
    }

    private static func ensureParent(_ path: String) throws {
        var metadata = stat()
        if lstat(path, &metadata) != 0 {
            guard errno == ENOENT else {
                throw HelperSocketError.systemCall(operation: "lstat(parent)", errno: errno)
            }
            if mkdir(path, 0o755) == 0 {
                guard chown(path, 0, 0) == 0 else {
                    throw HelperSocketError.systemCall(operation: "chown(parent)", errno: errno)
                }
            } else if errno != EEXIST {
                throw HelperSocketError.systemCall(operation: "mkdir", errno: errno)
            }
            guard lstat(path, &metadata) == 0 else {
                throw HelperSocketError.systemCall(operation: "lstat(parent after mkdir)", errno: errno)
            }
        }
        let safe = metadata.st_mode & S_IFMT == S_IFDIR
            && metadata.st_uid == 0
            && metadata.st_gid == 0
            && metadata.st_mode & 0o022 == 0
        guard safe else { throw HelperSocketError.unsafeParentDirectory }
    }

    private static func acceptConnections(
        on descriptor: Int32,
        limiter: HelperClientLimiter,
        handler: @escaping HelperPeerRequestHandler
    ) async {
        while !Task.isCancelled {
            let client = accept(descriptor, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            guard await limiter.acquire() else {
                close(client)
                continue
            }
            var noSigPipe: Int32 = 1
            _ = setsockopt(
                client,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                &noSigPipe,
                socklen_t(MemoryLayout<Int32>.size)
            )
            Task.detached {
                await handleClient(client, handler: handler)
                close(client)
                await limiter.release()
            }
        }
    }

    private static func handleClient(
        _ descriptor: Int32,
        handler: @escaping HelperPeerRequestHandler
    ) async {
        guard let credentials = try? UnixPeerCredentials.read(from: descriptor) else { return }
        var session = HelperFrameSession()
        var buffer = Array(repeating: UInt8(0), count: 4_096)

        while true {
            let count = recv(descriptor, &buffer, buffer.count, 0)
            guard count > 0 else { return }
            let requests: [HelperRequest]
            do {
                requests = try session.ingest(
                    Data(buffer.prefix(count)),
                    now: Date.timeIntervalSinceReferenceDate
                )
            } catch {
                return
            }
            for request in requests {
                let response = await handler(request, credentials.uid)
                guard let frame = try? FrameEncoder.encode(response),
                      writeAll(frame, descriptor: descriptor)
                else {
                    return
                }
            }
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
