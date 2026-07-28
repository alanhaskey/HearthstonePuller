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
    public static let cutDuration = Duration.milliseconds(500)

    private var state: PullerState = .absent
    private var connectionCount = 0
    private var deadline: Duration?
    private var message: String?

    public init() {}

    public mutating func observe(connectionCount: Int) {
        self.connectionCount = max(0, connectionCount)

        switch state {
        case .cutting:
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

    public mutating func beginCut(now: Duration) throws {
        if state == .cutting {
            throw InterruptionStateError.alreadyCutting
        }
        guard state == .ready else {
            throw InterruptionStateError.notReady
        }

        state = .cutting
        deadline = now + Self.cutDuration
        message = nil
    }

    public mutating func deadlineReached(now: Duration) {
        guard state == .cutting, let deadline, now >= deadline else { return }
        state = .waitingForReconnect
        self.deadline = nil
        connectionCount = 0
    }

    public mutating func restore(connectionCount: Int) {
        self.connectionCount = max(0, connectionCount)
        state = self.connectionCount > 0 ? .ready : .absent
        deadline = nil
        message = nil
    }

    public mutating func markAbsent() {
        state = .absent
        connectionCount = 0
        deadline = nil
        message = nil
    }

    public mutating func fail(_ message: String) {
        state = .error
        deadline = nil
        self.message = message
    }

    public func snapshot(now: Duration) -> PullerSnapshot {
        let remaining: Int
        if state == .cutting, let deadline {
            remaining = Self.milliseconds(max(.zero, deadline - now))
        } else {
            remaining = 0
        }

        return PullerSnapshot(
            state: state,
            connectionCount: connectionCount,
            remainingMilliseconds: remaining,
            message: message
        )
    }

    private static func milliseconds(_ duration: Duration) -> Int {
        let components = duration.components
        let whole = components.seconds.multipliedReportingOverflow(by: 1_000)
        guard !whole.overflow else { return Int.max }
        let fractional = components.attoseconds / 1_000_000_000_000_000
        return Int(clamping: whole.partialValue + fractional)
    }
}
