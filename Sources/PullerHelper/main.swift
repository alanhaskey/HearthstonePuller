import Darwin
import Foundation
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

Task {
    do {
        let configuration = try HelperConfiguration.load()
        let socketObserver = ProcessSocketObserver()
        let pfController = PFController()
        let recoveryClient = RecoveryClient()
        try await recoveryClient.verifyAvailable()

        let engine = HelperEngine(
            locator: HearthstoneLocator(processes: socketObserver),
            sockets: socketObserver,
            pf: pfController,
            recovery: recoveryClient
        )
        try await engine.start()
        let server = HelperServer(
            handler: engine,
            allowedUID: configuration.allowedUID
        )
        signalRuntime.install(server: server, engine: engine)
        try await server.start()
    } catch {
        fputs("hearthstone-puller-helper failed to start\n", stderr)
        exit(EXIT_FAILURE)
    }
}

dispatchMain()
