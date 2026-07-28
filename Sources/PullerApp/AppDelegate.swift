import AppKit
import PullerCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let viewModel = PanelStateViewModel(client: HelperClient())
    private var panelController: FloatingPanelController?
    private var pollingTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let panelController = FloatingPanelController()
        self.panelController = panelController
        viewModel.onChange = { [weak self] in self?.render() }
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
                case .cutting, .waitingForReconnect: .milliseconds(100)
                default: .milliseconds(500)
                }
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        let status = NSMenuItem(title: viewModel.label, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        menu.addItem(item("重新检测", action: #selector(redetect)))
        menu.addItem(item("恢复网络", action: #selector(restore)))
        menu.addItem(item("安装或卸载 Helper", action: #selector(showInstallationFiles)))
        menu.addItem(.separator())
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

    @objc private func showInstallationFiles() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
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
