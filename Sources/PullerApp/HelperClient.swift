import Darwin
import Foundation
import PullerCore

public protocol HelperRequestSending: Sendable {
    func send(_ request: HelperRequest) async throws -> HelperResponse
}

public actor HelperClient: HelperRequestSending {
    public static let socketPath = "/var/run/hearthstone-puller/helper.sock"

    public init() {}

    public func send(_ request: HelperRequest) async throws -> HelperResponse {
        let descriptor = try connectSocket()
        defer { close(descriptor) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        _ = setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))

        let frame = try FrameEncoder.encode(request)
        guard Self.writeAll(frame, descriptor: descriptor) else { throw HelperClientError.disconnected }
        var decoder = FrameDecoder()
        var buffer = Array(repeating: UInt8(0), count: 4_096)
        while true {
            let count = recv(descriptor, &buffer, buffer.count, 0)
            if count < 0 { throw HelperClientError.systemCall(errno) }
            guard count > 0 else { throw HelperClientError.disconnected }
            if let payload = try decoder.append(buffer.prefix(count)).first {
                return try JSONDecoder().decode(HelperResponse.self, from: payload)
            }
        }
    }

    private func connectSocket() throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw HelperClientError.systemCall(errno) }
        do {
            var address = sockaddr_un()
            let bytes = Array(Self.socketPath.utf8CString)
            guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
                throw HelperClientError.pathTooLong
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
            guard result == 0 else { throw HelperClientError.systemCall(errno) }
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
                let count = Darwin.send(descriptor, pointer, remaining, 0)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { return false }
                pointer = pointer.advanced(by: count)
                remaining -= count
            }
            return true
        }
    }
}

public enum HelperClientError: Error, Equatable, Sendable {
    case pathTooLong
    case disconnected
    case systemCall(Int32)
}

@MainActor
public final class PanelStateViewModel {
    private let client: any HelperRequestSending
    public var onChange: (@MainActor @Sendable () -> Void)?

    public private(set) var snapshot = PullerSnapshot(
        state: .helperUnavailable,
        connectionCount: 0,
        remainingMilliseconds: 0
    ) {
        didSet { onChange?() }
    }

    public init(client: any HelperRequestSending) {
        self.client = client
    }

    public var state: PullerState { snapshot.state }

    public var title: String {
        switch state {
        case .helperUnavailable: "需要安装"
        case .absent: "未检测到对局"
        case .ready: "一键拔线"
        case .cutting: "正在断线"
        case .waitingForGameResponse: "等待游戏响应"
        case .notTriggered: "未触发"
        case .waitingForReconnect: "等待重连"
        case .error:
            snapshot.errorCode.map { "错误 \($0.rawValue)" } ?? "未知错误"
        }
    }

    public var label: String { title }

    public var diagnosticSummary: String? {
        guard let code = snapshot.errorCode else { return nil }
        return "\(code.rawValue)：\(Self.localizedReason(for: code))"
    }

    public var countdown: String? {
        guard state == .cutting
                || state == .waitingForGameResponse
                || state == .waitingForReconnect
        else { return nil }
        let seconds = max(1, (snapshot.remainingMilliseconds + 999) / 1_000)
        return "\(seconds)s"
    }

    public var accessibilityText: String {
        guard let countdown else { return title }
        return "\(title) \(countdown)"
    }

    public var isEnabled: Bool {
        switch state {
        case .helperUnavailable, .ready, .notTriggered, .error: true
        case .absent, .cutting, .waitingForGameResponse, .waitingForReconnect: false
        }
    }

    public func apply(_ snapshot: PullerSnapshot) {
        self.snapshot = snapshot
    }

    public func performPrimaryAction() async {
        switch state {
        case .ready, .notTriggered:
            await send(.cut)
        case .helperUnavailable, .error:
            await refresh()
        default:
            break
        }
    }

    public func restore() async {
        await send(.restore)
    }

    public func refresh() async {
        await send(.status)
    }

    private func send(_ request: HelperRequest) async {
        do {
            apply(try await client.send(request).snapshot)
        } catch {
            let diagnostic = Self.diagnostic(for: error)
            snapshot = PullerSnapshot(
                state: state == .helperUnavailable ? .helperUnavailable : .error,
                connectionCount: 0,
                remainingMilliseconds: 0,
                errorCode: diagnostic.code,
                message: diagnostic.detail
            )
        }
    }

    private static func diagnostic(for error: Error) -> (
        code: PullerErrorCode,
        detail: String
    ) {
        if let clientError = error as? HelperClientError {
            switch clientError {
            case .pathTooLong:
                return (.helperResponseInvalid, "helper socket path is invalid")
            case .disconnected:
                return (.helperConnectionInterrupted, "helper connection closed unexpectedly")
            case let .systemCall(systemError):
                let code: PullerErrorCode = switch systemError {
                case ENOENT, ECONNREFUSED: .helperSocketUnavailable
                default: .helperConnectionInterrupted
                }
                return (code, "helper IPC failed with errno \(systemError)")
            }
        }
        return (
            .helperResponseInvalid,
            "invalid helper response: \(String(reflecting: error))"
        )
    }

    private static func localizedReason(for code: PullerErrorCode) -> String {
        switch code {
        case .helperSocketUnavailable: "无法连接后台服务"
        case .helperConnectionInterrupted: "后台服务连接中断或超时"
        case .helperResponseInvalid: "后台服务响应无效"
        case .statusObservationFailed: "无法读取炉石进程或连接状态"
        case .cutSetupFailed: "无法配置断线规则"
        case .restoreFailed: "无法恢复网络规则"
        case .connectionResetFailed: "断线流程执行失败"
        case .resetCleanupFailed: "断线清理失败"
        case .unauthorizedClient: "当前用户与服务配置不匹配"
        }
    }
}

private extension HelperResponse {
    var snapshot: PullerSnapshot {
        switch self {
        case let .status(snapshot), let .accepted(snapshot): snapshot
        case let .rejected(_, _, snapshot): snapshot
        }
    }
}
