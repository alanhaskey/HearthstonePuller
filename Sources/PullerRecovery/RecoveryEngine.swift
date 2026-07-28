import Foundation
import PullerSystem

public struct RecoveryTime: Sendable {
    public let wall: Date
    public let monotonic: Duration

    public init(wall: Date, monotonic: Duration) {
        self.wall = wall
        self.monotonic = monotonic
    }
}

public protocol RecoveryTimeSource: Sendable {
    func now() async -> RecoveryTime
    func sleep(until deadline: Duration) async throws
}

public struct SystemRecoveryTimeSource: RecoveryTimeSource {
    private let clock = ContinuousClock()
    private let origin: ContinuousClock.Instant

    public init() {
        self.origin = clock.now
    }

    public func now() async -> RecoveryTime {
        RecoveryTime(
            wall: Date(),
            monotonic: origin.duration(to: clock.now)
        )
    }

    public func sleep(until deadline: Duration) async throws {
        try await clock.sleep(until: origin.advanced(by: deadline))
    }
}

public actor RecoveryEngine {
    public static let minimumDelay: TimeInterval = 0.1
    public static let maximumDelay: TimeInterval = 10.5

    private let pf: any PFControlling
    private let time: any RecoveryTimeSource
    private var armedWallDeadline: Date?
    private var armedMonotonicDeadline: Duration?
    private var timerTask: Task<Void, Never>?

    public init(
        pf: any PFControlling,
        time: any RecoveryTimeSource = SystemRecoveryTimeSource()
    ) {
        self.pf = pf
        self.time = time
    }

    public func start() async throws {
        try await flushNow()
    }

    public func arm(deadline requestedDeadline: Date) async throws -> Date {
        let now = await time.now()
        let requestedDelay = requestedDeadline.timeIntervalSince(now.wall)
        let acceptedDelay = min(
            max(requestedDelay, Self.minimumDelay),
            Self.maximumDelay
        )
        let candidateWallDeadline = now.wall.addingTimeInterval(acceptedDelay)
        let candidateMonotonicDeadline = now.monotonic + .milliseconds(
            Int64((acceptedDelay * 1_000).rounded())
        )

        if let armedMonotonicDeadline,
           let armedWallDeadline,
           armedMonotonicDeadline <= candidateMonotonicDeadline {
            return armedWallDeadline
        }

        armedWallDeadline = candidateWallDeadline
        armedMonotonicDeadline = candidateMonotonicDeadline
        scheduleTimer(for: candidateMonotonicDeadline)
        return candidateWallDeadline
    }

    public func flushNow() async throws {
        disarm()
        try await pf.flushAnchor()
    }

    public func status() -> Date? {
        armedWallDeadline
    }

    public func handleWake() async throws {
        guard let armedWallDeadline else { return }
        let now = await time.now()
        if now.wall >= armedWallDeadline {
            try await flushNow()
        }
    }

    private func scheduleTimer(for deadline: Duration) {
        timerTask?.cancel()
        let time = self.time
        timerTask = Task { [weak self] in
            do {
                try await time.sleep(until: deadline)
                guard !Task.isCancelled else { return }
                await self?.timerReached(expectedDeadline: deadline)
            } catch {
                // Cancellation is expected when a shorter deadline replaces this timer.
            }
        }
    }

    private func timerReached(expectedDeadline: Duration) async {
        guard armedMonotonicDeadline == expectedDeadline else { return }
        disarm()
        try? await pf.flushAnchor()
    }

    private func disarm() {
        timerTask?.cancel()
        timerTask = nil
        armedWallDeadline = nil
        armedMonotonicDeadline = nil
    }
}
