import Darwin
import Foundation
import PullerCore
import PullerSystem

signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)

final class HelperSignalRuntime: @unchecked Sendable {
    private var terminationSource: DispatchSourceSignal?
    private var interruptSource: DispatchSourceSignal?

    func install(server: HelperServer, engine: HelperEngine) {
        let terminate: @Sendable () -> Void = {
            Task {
                await server.stop()
                await engine.shutdown()
                exit(EXIT_SUCCESS)
            }
        }
        let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        termSource.setEventHandler(handler: terminate)
        intSource.setEventHandler(handler: terminate)
        termSource.resume()
        intSource.resume()
        terminationSource = termSource
        interruptSource = intSource
    }
}

let signalRuntime = HelperSignalRuntime()

private actor ResilientHelperHandler: HelperRequestHandling {
    private static let retryInterval = Duration.seconds(2)

    private let engine: HelperEngine
    private let clock = ContinuousClock()
    private var ready = false
    private var lastAttempt: ContinuousClock.Instant?
    private var startupDetail = "helper initialization has not completed"

    init(engine: HelperEngine) {
        self.engine = engine
    }

    func prepare() async {
        await attemptStartup(force: true)
    }

    func handle(_ request: HelperRequest) async -> HelperResponse {
        if !ready {
            await attemptStartup(force: false)
        }
        guard ready else {
            return .rejected(
                code: "helper_startup_failed",
                message: "helper initialization failed",
                snapshot: PullerSnapshot(
                    state: .error,
                    connectionCount: 0,
                    remainingMilliseconds: 0,
                    errorCode: .cutSetupFailed,
                    message: startupDetail
                )
            )
        }
        return await engine.handle(request)
    }

    private func attemptStartup(force: Bool) async {
        let now = clock.now
        if !force, let lastAttempt,
           lastAttempt.duration(to: now) < Self.retryInterval {
            return
        }
        lastAttempt = now
        do {
            try await engine.start()
            ready = true
        } catch {
            startupDetail = "helper startup failed: \(String(reflecting: error))"
            fputs("\(startupDetail)\n", stderr)
        }
    }
}

private func waitForRecoveryService(
    _ client: RecoveryClient,
    attempts: Int = 40,
    retryDelay: Duration = .milliseconds(250)
) async throws {
    precondition(attempts > 0)
    var lastError: (any Error)?
    for attempt in 1...attempts {
        do {
            try await client.verifyAvailable()
            return
        } catch {
            lastError = error
            guard attempt < attempts else { break }
            try await Task.sleep(for: retryDelay)
        }
    }
    throw lastError!
}

Task {
    do {
        let configuration = try HelperConfiguration.load()
        let socketObserver = ProcessSocketObserver()
        let pfController = PFController()
        let recoveryClient = RecoveryClient()
        try await waitForRecoveryService(recoveryClient)

        let engine = HelperEngine(
            locator: HearthstoneLocator(processes: socketObserver),
            sockets: socketObserver,
            pf: pfController,
            recovery: recoveryClient
        )
        let resilientHandler = ResilientHelperHandler(engine: engine)
        await resilientHandler.prepare()
        let server = HelperServer(
            handler: resilientHandler,
            allowedUID: configuration.allowedUID
        )
        signalRuntime.install(server: server, engine: engine)
        try await server.start()
    } catch {
        fputs(
            "hearthstone-puller-helper failed to start: \(String(reflecting: error))\n",
            stderr
        )
        exit(EXIT_FAILURE)
    }
}

dispatchMain()
