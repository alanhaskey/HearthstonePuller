public struct PullerSnapshot: Codable, Equatable, Sendable {
    public let state: PullerState
    public let connectionCount: Int
    public let remainingMilliseconds: Int
    public let message: String?

    public init(
        state: PullerState,
        connectionCount: Int,
        remainingMilliseconds: Int,
        message: String? = nil
    ) {
        self.state = state
        self.connectionCount = connectionCount
        self.remainingMilliseconds = remainingMilliseconds
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
    private var message: String?

    public init() {}

    public mutating func observe(connectionCount: Int) {
        self.connectionCount = max(0, connectionCount)

        switch state {
        case .cutting:
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
        message = nil
    }

    public mutating func resetCompleted() {
        guard state == .cutting else { return }
        state = .waitingForReconnect
        connectionCount = 0
    }

    public mutating func markNotTriggered() {
        guard state == .cutting else { return }
        state = .notTriggered
        message = nil
    }

    public mutating func reconnectTimedOut() {
        guard state == .waitingForReconnect else { return }
        markAbsent()
    }

    public mutating func restore(connectionCount: Int) {
        self.connectionCount = max(0, connectionCount)
        state = self.connectionCount > 0 ? .ready : .absent
        message = nil
    }

    public mutating func markAbsent() {
        state = .absent
        connectionCount = 0
        message = nil
    }

    public mutating func fail(_ message: String) {
        state = .error
        self.message = message
    }

    public func snapshot(remainingMilliseconds: Int = 0) -> PullerSnapshot {
        PullerSnapshot(
            state: state,
            connectionCount: connectionCount,
            remainingMilliseconds: max(0, remainingMilliseconds),
            message: message
        )
    }
}
