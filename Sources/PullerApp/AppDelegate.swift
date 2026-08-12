import AppKit
import PullerCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let viewModel = PanelStateViewModel(client: HelperClient())
    private let serviceInstallationChecker: any ServiceInstallationChecking
    private let aboutCoordinator = AboutCoordinator()
    private lazy var serviceCoordinator = ServiceOperationCoordinator(
        manager: ServiceManager(),
        viewModel: viewModel
    )
    private var panelController: FloatingPanelController?
    private var pollingTask: Task<Void, Never>?

    override convenience init() {
        self.init(serviceInstallationChecker: ServiceInstallationDetector())
    }

    init(serviceInstallationChecker: any ServiceInstallationChecking) {
        self.serviceInstallationChecker = serviceInstallationChecker
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let panelController = FloatingPanelController()
        self.panelController = panelController
        viewModel.onChange = { [weak self] in self?.render() }
        serviceCoordinator.onNotice = { [weak self] notice in
            self?.show(notice)
        }
        panelController.buttonView.onClick = { [weak self] in
            Task { await self?.viewModel.performPrimaryAction() }
        }
        panelController.buttonView.menuProvider = { [weak self] in self?.makeMenu() ?? NSMenu() }
        render()
        panelController.show()
        startPolling()
    }

    func applicationWillTerminate(_ notification: Notification) {
        pollingTask?.cancel()
    }

    private func render() {
        panelController?.buttonView.render(viewModel)
    }

    private func startPolling() {
        pollingTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.viewModel.refresh()
                let interval: Duration = switch self.viewModel.state {
                case .cutting, .waitingForGameResponse, .waitingForReconnect: .milliseconds(100)
                default: .milliseconds(500)
                }
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("重新检测", action: #selector(redetect)))
        let serviceModel = ServiceMenuModel(
            installationStatus: serviceInstallationChecker.status(),
            isOperationInProgress: serviceCoordinator.isOperationInProgress
        )
        let serviceAction: Selector = switch serviceModel.operation {
        case .install: #selector(installService)
        case .uninstall: #selector(uninstallService)
        }
        let serviceItem = item(serviceModel.title, action: serviceAction)
        serviceItem.isEnabled = serviceModel.isEnabled
        menu.addItem(serviceItem)
        menu.addItem(.separator())
        menu.addItem(item("关于 HearthstonePuller", action: #selector(showAbout)))
        menu.addItem(item("退出", action: #selector(quit)))
        return menu
    }

    private func item(_ title: String, action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func redetect() {
        Task { await viewModel.refresh() }
    }

    @objc private func restore() {
        Task { await viewModel.restore() }
    }

    @objc private func installService() {
        Task { await serviceCoordinator.perform(.install) }
    }

    @objc private func uninstallService() {
        Task { await serviceCoordinator.perform(.uninstall) }
    }

    private func show(_ notice: ServiceOperationNotice) {
        let alert = NSAlert()
        alert.messageText = notice.message
        if let informativeText = notice.informativeText {
            alert.informativeText = informativeText
        }
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = aboutCoordinator.metadata.applicationName
        alert.informativeText = aboutCoordinator.metadata.informativeText
        alert.addButton(withTitle: "Go GitHub")
        alert.addButton(withTitle: "OK")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard aboutCoordinator.openRepository() else {
            let failureAlert = NSAlert()
            failureAlert.messageText = AboutCoordinator.openFailureMessage
            failureAlert.addButton(withTitle: "OK")
            failureAlert.runModal()
            return
        }
    }

    @objc private func quit() {
        Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.viewModel.restore() }
                group.addTask { try? await Task.sleep(for: .seconds(1)) }
                await group.next()
                group.cancelAll()
            }
            NSApp.terminate(nil)
        }
    }
}
