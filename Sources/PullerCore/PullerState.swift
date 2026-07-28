public enum PullerState: String, Codable, Sendable, Equatable {
    case helperUnavailable
    case absent
    case ready
    case cutting
    case waitingForReconnect
    case error

    public var isActionable: Bool {
        self == .ready
    }
}
