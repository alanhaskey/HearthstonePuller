import PullerCore
import XCTest
@testable import PullerApp

@MainActor
final class ServiceOperationCoordinatorTests: XCTestCase {
    func testMenuUsesExplicitServiceLanguage() {
        XCTAssertEqual(ServiceOperationCoordinator.installMenuTitle, "安装服务")
        XCTAssertEqual(ServiceOperationCoordinator.uninstallMenuTitle, "卸载服务")
        XCTAssertFalse(ServiceOperationCoordinator.installMenuTitle.contains("Helper"))
        XCTAssertFalse(ServiceOperationCoordinator.uninstallMenuTitle.contains("Helper"))
    }

    func testCancellationShowsOnlyCancellationNotice() async {
        let client = SequencedHelperClient([])
        let viewModel = PanelStateViewModel(client: client)
        let manager = ImmediateServiceManager(result: .cancelled)
        let coordinator = ServiceOperationCoordinator(
            manager: manager,
            viewModel: viewModel,
            sleep: { _ in }
        )
        var notices: [ServiceOperationNotice] = []
        coordinator.onNotice = { notices.append($0) }

        await coordinator.perform(.install)

        XCTAssertEqual(notices, [.init(message: "操作已取消")])
        XCTAssertEqual(viewModel.state, .helperUnavailable)
    }

    func testUninstallSuccessImmediatelyMarksServiceUnavailable() async {
        let client = SequencedHelperClient([])
        let viewModel = PanelStateViewModel(client: client)
        viewModel.apply(snapshot(.ready))
        let coordinator = ServiceOperationCoordinator(
            manager: ImmediateServiceManager(result: .succeeded(.uninstall)),
            viewModel: viewModel,
            sleep: { _ in }
        )
        var notices: [ServiceOperationNotice] = []
        coordinator.onNotice = { notices.append($0) }

        await coordinator.perform(.uninstall)

        XCTAssertEqual(viewModel.state, .helperUnavailable)
        XCTAssertEqual(notices, [.init(message: "服务卸载成功")])
    }

    func testInstallSuccessPollsUntilHelperResponds() async {
        let client = SequencedHelperClient([
            .status(snapshot(.helperUnavailable)),
            .status(snapshot(.helperUnavailable)),
            .status(snapshot(.absent)),
        ])
        let viewModel = PanelStateViewModel(client: client)
        let sleepRecorder = SleepRecorder()
        let coordinator = ServiceOperationCoordinator(
            manager: ImmediateServiceManager(result: .succeeded(.install)),
            viewModel: viewModel,
            sleep: { duration in await sleepRecorder.record(duration) }
        )
        var notices: [ServiceOperationNotice] = []
        coordinator.onNotice = { notices.append($0) }

        await coordinator.perform(.install)

        XCTAssertEqual(viewModel.state, .absent)
        XCTAssertEqual(notices, [.init(message: "服务安装成功")])
        let requests = await client.requests()
        XCTAssertEqual(requests, [.status, .status, .status])
        let sleeps = await sleepRecorder.values()
        XCTAssertEqual(sleeps, [.milliseconds(100), .milliseconds(100)])
    }

    func testOperationStateRemainsBusyUntilManagerCompletes() async {
        let manager = PausingServiceManager()
        let coordinator = ServiceOperationCoordinator(
            manager: manager,
            viewModel: PanelStateViewModel(client: SequencedHelperClient([])),
            sleep: { _ in }
        )

        let task = Task { await coordinator.perform(.install) }
        await manager.waitUntilStarted()
        XCTAssertTrue(coordinator.isOperationInProgress)

        await manager.release(with: .cancelled)
        await task.value
        XCTAssertFalse(coordinator.isOperationInProgress)
    }
}

private func snapshot(_ state: PullerState) -> PullerSnapshot {
    PullerSnapshot(
        state: state,
        connectionCount: state == .ready ? 1 : 0,
        remainingMilliseconds: 0
    )
}

private actor ImmediateServiceManager: ServiceManaging {
    let result: ServiceOperationResult

    init(result: ServiceOperationResult) {
        self.result = result
    }

    func perform(_ operation: ServiceOperation) async -> ServiceOperationResult { result }
}

private actor PausingServiceManager: ServiceManaging {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var resultContinuation: CheckedContinuation<ServiceOperationResult, Never>?

    func perform(_ operation: ServiceOperation) async -> ServiceOperationResult {
        started = true
        startWaiters.forEach { $0.resume() }
        startWaiters.removeAll()
        return await withCheckedContinuation { resultContinuation = $0 }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func release(with result: ServiceOperationResult) {
        resultContinuation?.resume(returning: result)
        resultContinuation = nil
    }
}

private actor SequencedHelperClient: HelperRequestSending {
    private var responses: [HelperResponse]
    private var received: [HelperRequest] = []

    init(_ responses: [HelperResponse]) {
        self.responses = responses
    }

    func send(_ request: HelperRequest) async throws -> HelperResponse {
        received.append(request)
        guard !responses.isEmpty else {
            return .status(snapshot(.helperUnavailable))
        }
        return responses.removeFirst()
    }

    func requests() -> [HelperRequest] { received }
}

private actor SleepRecorder {
    private var durations: [Duration] = []

    func record(_ duration: Duration) { durations.append(duration) }
    func values() -> [Duration] { durations }
}
