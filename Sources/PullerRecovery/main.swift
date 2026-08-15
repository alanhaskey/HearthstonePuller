import Darwin
import Foundation
import PullerSystem

let pfController = PFController()
let recoveryEngine = RecoveryEngine(pf: pfController)
let recoveryServer = RecoveryServer(engine: recoveryEngine)

signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)

let terminationSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
let interruptSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)

func terminateRecoveryDaemon() {
    Task {
        try? await recoveryEngine.flushNow()
        await recoveryServer.stop()
        exit(EXIT_SUCCESS)
    }
}

terminationSource.setEventHandler(handler: terminateRecoveryDaemon)
interruptSource.setEventHandler(handler: terminateRecoveryDaemon)
terminationSource.resume()
interruptSource.resume()

Task {
    do {
        try await recoveryServer.start()
    } catch {
        fputs(
            "hearthstone-puller-recovery failed to start: \(String(reflecting: error))\n",
            stderr
        )
        exit(EXIT_FAILURE)
    }
}

dispatchMain()
