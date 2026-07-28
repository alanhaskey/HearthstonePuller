import Foundation
import PullerCore

struct ServiceOperationNotice: Equatable, Sendable {
    let message: String
    let informativeText: String?

    init(message: String, informativeText: String? = nil) {
        self.message = message
        self.informativeText = informativeText
    }
}

@MainActor
final class ServiceOperationCoordinator {
    static let installMenuTitle = "安装服务"
    static let uninstallMenuTitle = "卸载服务"

    var onNotice: ((ServiceOperationNotice) -> Void)?
    private(set) var isOperationInProgress = false

    private let manager: any ServiceManaging
    private let viewModel: PanelStateViewModel
    private let elapsed: @Sendable () -> Duration
    private let sleep: @Sendable (Duration) async -> Void

    init(
        manager: any ServiceManaging,
        viewModel: PanelStateViewModel,
        elapsed: @escaping @Sendable () -> Duration = {
            ServiceOperationClock.elapsed
        },
        sleep: @escaping @Sendable (Duration) async -> Void = {
            try? await Task.sleep(for: $0)
        }
    ) {
        self.manager = manager
        self.viewModel = viewModel
        self.elapsed = elapsed
        self.sleep = sleep
    }

    func perform(_ operation: ServiceOperation) async {
        guard !isOperationInProgress else { return }
        isOperationInProgress = true
        defer { isOperationInProgress = false }

        switch await manager.perform(operation) {
        case .succeeded(.install):
            onNotice?(.init(message: "服务安装成功"))
            await waitForInstalledService()
        case .succeeded(.uninstall):
            viewModel.apply(PullerSnapshot(
                state: .helperUnavailable,
                connectionCount: 0,
                remainingMilliseconds: 0
            ))
            onNotice?(.init(message: "服务卸载成功"))
        case .cancelled:
            onNotice?(.init(message: "操作已取消"))
        case .failed(.incompletePackage):
            onNotice?(.init(message: "应用程序包不完整"))
        case let .failed(failure):
            onNotice?(.init(
                message: operation == .install ? "服务安装失败" : "服务卸载失败",
                informativeText: diagnostics(for: failure)
            ))
        case .busy:
            onNotice?(.init(message: "服务操作正在进行"))
        }
    }

    private func waitForInstalledService() async {
        let deadline = elapsed() + .seconds(2)
        while elapsed() < deadline {
            await viewModel.refresh()
            if viewModel.state != .helperUnavailable { return }
            let remaining = deadline - elapsed()
            guard remaining > .zero else { return }
            await sleep(min(.milliseconds(100), remaining))
        }
    }

    private func diagnostics(for failure: ServiceOperationFailure) -> String? {
        switch failure {
        case let .incompletePackage(message),
             let .launchFailed(message),
             let .scriptFailed(message):
            message.isEmpty ? nil : message
        }
    }
}

private enum ServiceOperationClock {
    static let clock = ContinuousClock()
    static let origin = clock.now

    static var elapsed: Duration {
        origin.duration(to: clock.now)
    }
}
