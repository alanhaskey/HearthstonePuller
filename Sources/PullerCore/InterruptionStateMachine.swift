public enum PullerErrorCode: String, Codable, Equatable, Sendable {
    case helperSocketUnavailable = "HSP-101"
    case helperConnectionInterrupted = "HSP-102"
    case helperResponseInvalid = "HSP-103"
    case statusObservationFailed = "HSP-201"
    case cutSetupFailed = "HSP-202"
    case restoreFailed = "HSP-203"
    case connectionResetFailed = "HSP-204"
    case resetCleanupFailed = "HSP-205"
    case unauthorizedClient = "HSP-206"
}

public struct PullerSnapshot: Codable, Equatable, Sendable {
    public let state: PullerState
    public let connectionCount: Int
    public let remainingMilliseconds: Int
    public let errorCode: PullerErrorCode?
    public let message: String?

    public init(
        state: PullerState,
        connectionCount: Int,
        remainingMilliseconds: Int,
        errorCode: PullerErrorCode? = nil,
        message: String? = nil
    ) {
        self.state = state
        self.connectionCount = connectionCount
        self.remainingMilliseconds = remainingMilliseconds
        self.errorCode = errorCode
        self.message = message
    }
}

public enum InterruptionStateError: Error, Equatable {
    case notReady
    case alreadyCutting
}

public struct InterruptionStateMachine: Sendable {
    private var state: PullerState = .absent
    private var connectionCount = 0
    private var errorCode: PullerErrorCode?
    private var message: String?

    public init() {}

    public mutating func observe(connectionCount: Int) {
        self.connectionCount = max(0, connectionCount)

        switch state {
        case .cutting:
            break
        case .waitingForGameResponse:
            break
        case .notTriggered:
            break
        case .waitingForReconnect:
            if self.connectionCount > 0 {
                state = .ready
            }
        default:
            state = self.connectionCount > 0 ? .ready : .absent
        }
        errorCode = nil
        message = nil
    }

    public mutating func beginCut() throws {
        if state == .cutting {
            throw InterruptionStateError.alreadyCutting
        }
        guard state.isActionable else {
            throw InterruptionStateError.notReady
        }

        state = .cutting
        errorCode = nil
        message = nil
    }

    public mutating func resetCompleted() {
        guard state == .cutting || state == .waitingForGameResponse else { return }
        state = .waitingForReconnect
        connectionCount = 0
    }

    public mutating func beginWaitingForGameResponse() {
        guard state == .cutting else { return }
        state = .waitingForGameResponse
        errorCode = nil
        message = nil
    }

    public mutating func markNotTriggered() {
        guard state == .waitingForGameResponse else { return }
        state = .notTriggered
        errorCode = nil
        message = nil
    }

    public mutating func reconnectTimedOut() {
        guard state == .waitingForReconnect else { return }
        markAbsent()
    }

    public mutating func restore(connectionCount: Int) {
        self.connectionCount = max(0, connectionCount)
        state = self.connectionCount > 0 ? .ready : .absent
        errorCode = nil
        message = nil
    }

    public mutating func markAbsent() {
        state = .absent
        connectionCount = 0
        errorCode = nil
        message = nil
    }

    public mutating func fail(_ code: PullerErrorCode, message: String) {
        state = .error
        errorCode = code
        self.message = message
    }

    public func snapshot(remainingMilliseconds: Int = 0) -> PullerSnapshot {
        PullerSnapshot(
            state: state,
            connectionCount: connectionCount,
            remainingMilliseconds: max(0, remainingMilliseconds),
            errorCode: errorCode,
            message: message
        )
    }
}
