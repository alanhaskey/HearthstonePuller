import Foundation
import PullerCore
import PullerSystem

public protocol RecoveryArming: Sendable {
    func arm(deadline: Date) async throws
    func flushNow() async throws
}

public protocol HelperTimeSource: Sendable {
    var elapsed: Duration { get }
    var wallNow: Date { get }
    func sleep(for duration: Duration) async throws
}

public struct SystemHelperTimeSource: HelperTimeSource {
    private let clock = ContinuousClock()
    private let origin: ContinuousClock.Instant

    public init() {
        self.origin = clock.now
    }

    public var elapsed: Duration {
        origin.duration(to: clock.now)
    }

    public var wallNow: Date {
        Date()
    }

    public func sleep(for duration: Duration) async throws {
        try await clock.sleep(for: duration)
    }
}

public actor HelperEngine {
    public static let recoveryDelay: TimeInterval = 10.0
    public static let resetAttemptLimit = Duration.seconds(10)
    public static let reconnectLimit = Duration.seconds(15)
    public static let resetPollInterval = Duration.milliseconds(50)
    public static let idlePollInterval = Duration.milliseconds(500)

    private let locator: any HearthstoneLocating
    private let sockets: any ProcessSocketObserving
    private let pf: any PFControlling
    private let recovery: any RecoveryArming
    private let time: any HelperTimeSource

    private var machine = InterruptionStateMachine()
    private var provisioningCut = false
    private var cutTask: Task<Void, Never>?
    private var observationTask: Task<Void, Never>?
    private var notTriggeredTargets: Set<ObservedSocket> = []
    private var resetDeadline: Duration?
    private var reconnectDeadline: Duration?

    public init(
        locator: any HearthstoneLocating,
        sockets: any ProcessSocketObserving,
        pf: any PFControlling,
        recovery: any RecoveryArming,
        time: any HelperTimeSource = SystemHelperTimeSource()
    ) {
        self.locator = locator
        self.sockets = sockets
        self.pf = pf
        self.recovery = recovery
        self.time = time
    }

    public func start() async throws {
        try await pf.flushAnchor()
        try await pf.verifyAppleAnchor()
        try await pf.enable()
        refreshObservedStatus()

        observationTask?.cancel()
        observationTask = Task { [weak self] in
            await self?.runObservationLoop()
        }
    }

    public func handle(_ request: HelperRequest) async -> HelperResponse {
        switch request {
        case .status:
            return .status(snapshot())
        case .cut:
            return await beginCut()
        case .restore:
            return await restore()
        }
    }

    public func shutdown() async {
        observationTask?.cancel()
        observationTask = nil
        cutTask?.cancel()
        cutTask = nil
        provisioningCut = false
        notTriggeredTargets.removeAll()
        clearPhaseDeadlines()
        try? await pf.flushAnchor()
        try? await recovery.flushNow()
        await pf.releaseEnableReference()
        machine.restore(connectionCount: 0)
    }

    private func beginCut() async -> HelperResponse {
        let currentSnapshot = snapshot()
        guard !provisioningCut, currentSnapshot.state != .cutting else {
            return .rejected(
                code: "already_cutting",
                message: "a cut is already active",
                snapshot: currentSnapshot
            )
        }

        provisioningCut = true
        var recoveryArmed = false
        defer { provisioningCut = false }

        do {
            guard let process = try locator.locate() else {
                machine.markAbsent()
                return .rejected(
                    code: "hearthstone_absent",
                    message: "Hearthstone is not running",
                    snapshot: snapshot()
                )
            }
            guard try sockets.startIdentity(pid: process.pid) == process.startIdentity else {
                machine.markAbsent()
                return .rejected(
                    code: "process_changed",
                    message: "Hearthstone process changed",
                    snapshot: snapshot()
                )
            }

            let observed = try sockets.sockets(pid: process.pid, allowLoopback: false)
            let targets = HearthstoneGameConnectionSelector.select(from: observed)
            guard !targets.isEmpty else {
                machine.markAbsent()
                return .rejected(
                    code: "no_game_connection",
                    message: "No Hearthstone game connection found",
                    snapshot: snapshot()
                )
            }
            let rules = try PFRuleRenderer.render(targets)

            let resetStartedAt = time.elapsed
            let recoveryDeadline = time.wallNow.addingTimeInterval(Self.recoveryDelay)
            try await recovery.arm(deadline: recoveryDeadline)
            recoveryArmed = true
            try await pf.replaceAnchor(with: rules.rules)
            try await pf.killStates(rules.statePairs)

            machine.observe(connectionCount: targets.count)
            resetDeadline = resetStartedAt + Self.resetAttemptLimit
            reconnectDeadline = nil
            try machine.beginCut()
            notTriggeredTargets.removeAll()
            cutTask = Task { [weak self] in
                await self?.runResetAttempt(
                    process: process,
                    capturedTargets: Set(targets)
                )
            }
            return .accepted(snapshot())
        } catch {
            if recoveryArmed {
                await failOpen(message: "cut setup failed")
            } else {
                machine.fail("cut setup failed")
            }
            return .rejected(
                code: "cut_failed",
                message: "unable to start cut",
                snapshot: snapshot()
            )
        }
    }

    private func runResetAttempt(
        process: VerifiedProcess,
        capturedTargets: Set<ObservedSocket>
    ) async {
        guard let deadline = resetDeadline else { return }

        do {
            while time.elapsed < deadline {
                let remaining = deadline - time.elapsed
                try await time.sleep(for: min(Self.resetPollInterval, remaining))
                guard !Task.isCancelled else { return }

                guard try sockets.startIdentity(pid: process.pid) == process.startIdentity else {
                    await targetDisappeared()
                    return
                }
                let observed = try sockets.sockets(pid: process.pid, allowLoopback: false)
                let currentTargets = Set(
                    HearthstoneGameConnectionSelector.select(from: observed)
                )
                if capturedTargets.isDisjoint(with: currentTargets) {
                    try await completeReset()
                    try await runReconnectWait(process: process)
                    return
                }
            }

            try await completeUntriggeredReset(capturedTargets: capturedTargets)
        } catch is CancellationError {
            return
        } catch {
            await failOpen(message: "game connection reset failed")
        }
    }

    private func completeReset() async throws {
        try await pf.flushAnchor()
        try await recovery.flushNow()
        machine.resetCompleted()
        resetDeadline = nil
        reconnectDeadline = time.elapsed + Self.reconnectLimit
    }

    private func completeUntriggeredReset(
        capturedTargets: Set<ObservedSocket>
    ) async throws {
        try await pf.flushAnchor()
        try await recovery.flushNow()
        notTriggeredTargets = capturedTargets
        machine.markNotTriggered()
        clearPhaseDeadlines()
        cutTask = nil
    }

    private func runReconnectWait(process: VerifiedProcess) async throws {
        guard let deadline = reconnectDeadline else { return }

        while time.elapsed < deadline {
            let remaining = deadline - time.elapsed
            try await time.sleep(for: min(Self.idlePollInterval, remaining))
            guard !Task.isCancelled else { return }

            guard try sockets.startIdentity(pid: process.pid) == process.startIdentity else {
                machine.markAbsent()
                clearPhaseDeadlines()
                cutTask = nil
                return
            }
            let targets = try currentGameConnections(for: process)
            if !targets.isEmpty {
                machine.restore(connectionCount: targets.count)
                clearPhaseDeadlines()
                cutTask = nil
                return
            }
        }

        machine.reconnectTimedOut()
        clearPhaseDeadlines()
        cutTask = nil
    }

    private func restore() async -> HelperResponse {
        cutTask?.cancel()
        cutTask = nil
        provisioningCut = false
        clearPhaseDeadlines()
        do {
            try await pf.flushAnchor()
            try await recovery.flushNow()
            notTriggeredTargets.removeAll()
            let count = try currentGameConnections().count
            machine.restore(connectionCount: count)
            return .accepted(snapshot())
        } catch {
            machine.fail("restore failed")
            return .rejected(
                code: "restore_failed",
                message: "unable to restore network",
                snapshot: snapshot()
            )
        }
    }

    private func runObservationLoop() async {
        while !Task.isCancelled {
            do {
                try await time.sleep(for: Self.idlePollInterval)
                guard !Task.isCancelled else { return }
                if ![.cutting, .waitingForReconnect].contains(snapshot().state),
                   !provisioningCut {
                    refreshObservedStatus()
                }
            } catch is CancellationError {
                return
            } catch {
                machine.fail("status observation failed")
            }
        }
    }

    private func refreshObservedStatus() {
        do {
            let targets = Set(try currentGameConnections())
            if snapshot().state == .notTriggered {
                guard notTriggeredTargets.isDisjoint(with: targets) else { return }
                notTriggeredTargets.removeAll()
                machine.restore(connectionCount: targets.count)
                return
            }
            machine.observe(connectionCount: targets.count)
        } catch {
            machine.fail("status observation failed")
        }
    }

    private func currentGameConnections() throws -> [ObservedSocket] {
        guard let process = try locator.locate(),
              try sockets.startIdentity(pid: process.pid) == process.startIdentity
        else {
            return []
        }
        return try currentGameConnections(for: process)
    }

    private func currentGameConnections(
        for process: VerifiedProcess
    ) throws -> [ObservedSocket] {
        let observed = try sockets.sockets(pid: process.pid, allowLoopback: false)
        return HearthstoneGameConnectionSelector.select(from: observed)
    }

    private func targetDisappeared() async {
        do {
            try await pf.flushAnchor()
            try await recovery.flushNow()
            notTriggeredTargets.removeAll()
            clearPhaseDeadlines()
            cutTask = nil
            machine.markAbsent()
        } catch {
            await failOpen(message: "reset cleanup failed")
        }
    }

    private func failOpen(message: String) async {
        try? await pf.flushAnchor()
        cutTask = nil
        notTriggeredTargets.removeAll()
        clearPhaseDeadlines()
        machine.fail(message)
        try? await recovery.flushNow()
    }

    private func snapshot() -> PullerSnapshot {
        let state = machine.snapshot().state
        let remaining: Int
        switch state {
        case .cutting:
            remaining = remainingMilliseconds(
                until: resetDeadline,
                limit: Self.resetAttemptLimit
            )
        case .waitingForReconnect:
            remaining = remainingMilliseconds(
                until: reconnectDeadline,
                limit: Self.reconnectLimit
            )
        default:
            remaining = 0
        }
        return machine.snapshot(remainingMilliseconds: remaining)
    }

    private func remainingMilliseconds(until deadline: Duration?, limit: Duration) -> Int {
        guard let deadline else { return 0 }
        let remaining = max(.zero, min(limit, deadline - time.elapsed))
        let components = remaining.components
        return max(
            0,
            Int(components.seconds * 1_000)
                + Int(components.attoseconds / 1_000_000_000_000_000)
        )
    }

    private func clearPhaseDeadlines() {
        resetDeadline = nil
        reconnectDeadline = nil
    }
}
