public enum HelperRequest: Codable, Equatable, Sendable {
    case status
    case cut
    case restore
}

public enum HelperResponse: Codable, Equatable, Sendable {
    case status(PullerSnapshot)
    case accepted(PullerSnapshot)
    case rejected(code: String, message: String, snapshot: PullerSnapshot)
}

public enum RecoveryRequest: Codable, Equatable, Sendable {
    case arm(deadlineEpochMilliseconds: Int64)
    case flushNow
    case status
}

public enum RecoveryResponse: Codable, Equatable, Sendable {
    case armed(deadlineEpochMilliseconds: Int64)
    case flushed
    case status(deadlineEpochMilliseconds: Int64?)
    case rejected(code: String, message: String)
}
