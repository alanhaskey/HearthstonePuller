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
    private let sleep: @Sendable (Duration) async -> Void

    init(
        manager: any ServiceManaging,
        viewModel: PanelStateViewModel,
        sleep: @escaping @Sendable (Duration) async -> Void = {
            try? await Task.sleep(for: $0)
        }
    ) {
        self.manager = manager
        self.viewModel = viewModel
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
        for attempt in 0..<20 {
            await viewModel.refresh()
            if viewModel.state != .helperUnavailable { return }
            if attempt < 19 { await sleep(.milliseconds(100)) }
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
