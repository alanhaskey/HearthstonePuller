import PullerCore
import XCTest
@testable import PullerApp

@MainActor
final class PanelStateViewModelTests: XCTestCase {
    func testExactLabelsAndEnabledStates() {
        let cases: [(PullerState, String, Bool)] = [
            (.helperUnavailable, "需要安装", true),
            (.absent, "未检测到炉石", false),
            (.ready, "一键拔线", true),
            (.cutting, "断线中 0.5s", false),
            (.waitingForReconnect, "等待重连", false),
            (.error, "服务异常", true),
        ]

        let viewModel = PanelStateViewModel(client: FakeHelperClient())
        for (state, label, enabled) in cases {
            viewModel.apply(snapshot(state: state))
            XCTAssertEqual(viewModel.label, label)
            XCTAssertEqual(viewModel.isEnabled, enabled)
        }
    }

    func testReadyClickSendsOneCutAndCuttingIgnoresAdditionalClicks() async {
        let client = FakeHelperClient(response: .accepted(snapshot(state: .cutting)))
        let viewModel = PanelStateViewModel(client: client)
        viewModel.apply(snapshot(state: .ready))

        await viewModel.performPrimaryAction()
        await viewModel.performPrimaryAction()

        let requests = await client.requests()
        XCTAssertEqual(requests, [.cut])
        XCTAssertEqual(viewModel.state, .cutting)
    }

    func testRestoreSendsRestoreRequest() async {
        let client = FakeHelperClient(response: .accepted(snapshot(state: .ready)))
        let viewModel = PanelStateViewModel(client: client)

        await viewModel.restore()

        let requests = await client.requests()
        XCTAssertEqual(requests, [.restore])
    }

    func testRefreshOnlyAppliesAuthoritativeHelperSnapshot() async {
        let helperSnapshot = snapshot(state: .waitingForReconnect)
        let client = FakeHelperClient(response: .status(helperSnapshot))
        let viewModel = PanelStateViewModel(client: client)
        viewModel.apply(snapshot(state: .cutting))

        await viewModel.refresh()

        let requests = await client.requests()
        XCTAssertEqual(viewModel.snapshot, helperSnapshot)
        XCTAssertEqual(requests, [.status])
    }
}

@MainActor
private func snapshot(state: PullerState) -> PullerSnapshot {
    PullerSnapshot(
        state: state,
        connectionCount: state == .absent ? 0 : 1,
        remainingMilliseconds: state == .cutting ? 500 : 0
    )
}

private actor FakeHelperClient: HelperRequestSending {
    private let response: HelperResponse
    private var received: [HelperRequest] = []

    init(response: HelperResponse = .status(PullerSnapshot(
        state: .absent,
        connectionCount: 0,
        remainingMilliseconds: 0
    ))) {
        self.response = response
    }

    func send(_ request: HelperRequest) async throws -> HelperResponse {
        received.append(request)
        return response
    }

    func requests() -> [HelperRequest] {
        received
    }
}
