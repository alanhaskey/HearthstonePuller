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
    public static let recoveryDelay: TimeInterval = 2.0
    public static let cuttingPollInterval = Duration.milliseconds(50)
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
            guard !observed.isEmpty else {
                machine.markAbsent()
                return .rejected(
                    code: "no_connection",
                    message: "No Hearthstone connection found",
                    snapshot: snapshot()
                )
            }
            let rules = try PFRuleRenderer.render(observed)

            try await recovery.arm(
                deadline: time.wallNow.addingTimeInterval(Self.recoveryDelay)
            )
            recoveryArmed = true
            try await pf.replaceAnchor(with: rules.rules)
            try await pf.killStates(rules.statePairs)

            machine.observe(connectionCount: observed.count)
            let startedAt = time.elapsed
            try machine.beginCut(now: startedAt)
            let initialSockets = Set(observed)
            cutTask = Task { [weak self] in
                await self?.runCutWindow(
                    process: process,
                    startedAt: startedAt,
                    observedSockets: initialSockets
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

    private func runCutWindow(
        process: VerifiedProcess,
        startedAt: Duration,
        observedSockets initialSockets: Set<ObservedSocket>
    ) async {
        let deadline = startedAt + InterruptionStateMachine.cutDuration
        var accumulatedSockets = initialSockets

        do {
            while time.elapsed < deadline {
                let remaining = deadline - time.elapsed
                try await time.sleep(for: min(Self.cuttingPollInterval, remaining))
                guard !Task.isCancelled else { return }

                guard try sockets.startIdentity(pid: process.pid) == process.startIdentity else {
                    await targetDisappeared()
                    return
                }
                let latest = try sockets.sockets(pid: process.pid, allowLoopback: false)
                let merged = accumulatedSockets.union(latest)
                if merged != accumulatedSockets {
                    let rules = try PFRuleRenderer.render(Array(merged))
                    try await pf.replaceAnchor(with: rules.rules)
                    try await pf.killStates(rules.statePairs)
                    accumulatedSockets = merged
                }
            }

            try await pf.flushAnchor()
            machine.deadlineReached(now: time.elapsed)
            cutTask = nil
        } catch is CancellationError {
            return
        } catch {
            await failOpen(message: "cut polling failed")
        }
    }

    private func restore() async -> HelperResponse {
        cutTask?.cancel()
        cutTask = nil
        provisioningCut = false
        do {
            try await pf.flushAnchor()
            try await recovery.flushNow()
            let count = currentConnectionCount()
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
                if snapshot().state != .cutting, !provisioningCut {
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
        machine.observe(connectionCount: currentConnectionCount())
    }

    private func currentConnectionCount() -> Int {
        do {
            guard let process = try locator.locate(),
                  try sockets.startIdentity(pid: process.pid) == process.startIdentity
            else {
                return 0
            }
            return try sockets.sockets(pid: process.pid, allowLoopback: false).count
        } catch {
            return 0
        }
    }

    private func targetDisappeared() async {
        try? await pf.flushAnchor()
        try? await recovery.flushNow()
        cutTask = nil
        machine.markAbsent()
    }

    private func failOpen(message: String) async {
        try? await pf.flushAnchor()
        try? await recovery.flushNow()
        cutTask = nil
        machine.fail(message)
    }

    private func snapshot() -> PullerSnapshot {
        machine.snapshot(now: time.elapsed)
    }
}
