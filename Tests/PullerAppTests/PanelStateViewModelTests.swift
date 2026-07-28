import PullerCore
import XCTest
@testable import PullerApp

@MainActor
final class PanelStateViewModelTests: XCTestCase {
    func testExactLabelsAndEnabledStates() {
        let cases: [(PullerState, String, Bool)] = [
            (.helperUnavailable, "需要安装", true),
            (.absent, "未检测到对局", false),
            (.ready, "一键拔线", true),
            (.cutting, "等待连接", false),
            (.notTriggered, "未触发", true),
            (.waitingForReconnect, "等待重连", false),
            (.error, "服务异常", true),
        ]

        let viewModel = PanelStateViewModel(client: FakeHelperClient())
        for (state, label, enabled) in cases {
            viewModel.apply(snapshot(state: state))
            XCTAssertEqual(viewModel.title, label)
            XCTAssertEqual(viewModel.isEnabled, enabled)
        }
    }

    func testTimedStatesFormatAuthoritativeMillisecondsWithCeilingDivision() {
        let viewModel = PanelStateViewModel(client: FakeHelperClient())

        viewModel.apply(snapshot(state: .cutting, remainingMilliseconds: 8_001))
        XCTAssertEqual(viewModel.title, "等待连接")
        XCTAssertEqual(viewModel.countdown, "9s")
        XCTAssertEqual(viewModel.accessibilityText, "等待连接 9s")

        viewModel.apply(snapshot(state: .waitingForReconnect, remainingMilliseconds: 14_000))
        XCTAssertEqual(viewModel.title, "等待重连")
        XCTAssertEqual(viewModel.countdown, "14s")
        XCTAssertEqual(viewModel.accessibilityText, "等待重连 14s")
    }

    func testTimedStatesNeverDisplayZeroSeconds() {
        let viewModel = PanelStateViewModel(client: FakeHelperClient())

        for milliseconds in [0, 1, 999, 1_000] {
            viewModel.apply(snapshot(state: .cutting, remainingMilliseconds: milliseconds))
            XCTAssertEqual(viewModel.countdown, "1s")
        }
    }

    func testNormalStatesDoNotExposeCountdownText() {
        let viewModel = PanelStateViewModel(client: FakeHelperClient())

        viewModel.apply(snapshot(state: .ready, remainingMilliseconds: 9_999))

        XCTAssertNil(viewModel.countdown)
        XCTAssertEqual(viewModel.accessibilityText, "一键拔线")
    }

    func testPanelGeometryAndTypographyConstants() {
        XCTAssertEqual(FloatingPanelController.panelSize, NSSize(width: 144, height: 72))
        XCTAssertEqual(PullerButtonView.titleFontSize, 18)
        XCTAssertEqual(PullerButtonView.countdownFontSize, 20)
        XCTAssertEqual(PullerButtonView.cornerRadius, 10)
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

    func testNotTriggeredClickRetriesCut() async {
        let client = FakeHelperClient(response: .accepted(snapshot(state: .cutting)))
        let viewModel = PanelStateViewModel(client: client)
        viewModel.apply(snapshot(state: .notTriggered))

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
private func snapshot(
    state: PullerState,
    remainingMilliseconds: Int = 0
) -> PullerSnapshot {
    PullerSnapshot(
        state: state,
        connectionCount: state == .absent ? 0 : 1,
        remainingMilliseconds: remainingMilliseconds
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
