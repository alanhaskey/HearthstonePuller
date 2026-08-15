import AppKit
import PullerCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let viewModel = PanelStateViewModel(client: HelperClient())
    private let serviceInstallationChecker: any ServiceInstallationChecking
    private let aboutCoordinator = AboutCoordinator()
    private let updateChecker: UpdateChecker
    private lazy var serviceCoordinator = ServiceOperationCoordinator(
        manager: ServiceManager(),
        viewModel: viewModel
    )
    private var panelController: FloatingPanelController?
    private var pollingTask: Task<Void, Never>?
    private var updateCheckTask: Task<Void, Never>?

    override convenience init() {
        self.init(serviceInstallationChecker: ServiceInstallationDetector())
    }

    init(serviceInstallationChecker: any ServiceInstallationChecking) {
        self.serviceInstallationChecker = serviceInstallationChecker
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        self.updateChecker = UpdateChecker(currentVersion: version)
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
        checkForUpdates(manual: false)
    }

    func applicationWillTerminate(_ notification: Notification) {
        pollingTask?.cancel()
        updateCheckTask?.cancel()
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
        if let diagnosticSummary = viewModel.diagnosticSummary {
            menu.addItem(item(diagnosticSummary, action: #selector(copyDiagnostics)))
            menu.addItem(.separator())
        }
        menu.addItem(item(L10n.text("重新检测", "Check Again"), action: #selector(redetect)))
        menu.addItem(item(L10n.text("检查更新", "Check for Updates"), action: #selector(checkForUpdatesFromMenu)))
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
        menu.addItem(item(
            L10n.text("关于 HearthstonePuller", "About HearthstonePuller"),
            action: #selector(showAbout)
        ))
        menu.addItem(item(L10n.text("退出", "Quit"), action: #selector(quit)))
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

    @objc private func copyDiagnostics() {
        guard let report = DiagnosticReportBuilder().build(
            viewModel: viewModel,
            appVersion: aboutCoordinator.metadata.version
        ) else {
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(report, forType: .string) else {
            show(.init(message: L10n.text("复制诊断信息失败", "Unable to copy diagnostics")))
            return
        }
        show(.init(message: L10n.text("诊断信息已复制", "Diagnostics copied")))
    }

    @objc private func checkForUpdatesFromMenu() {
        checkForUpdates(manual: true)
    }

    private func checkForUpdates(manual: Bool) {
        guard updateCheckTask == nil else { return }
        updateCheckTask = Task { [weak self] in
            guard let self else { return }
            let result = await updateChecker.check()
            guard !Task.isCancelled else { return }
            updateCheckTask = nil
            handleUpdateCheck(result, manual: manual)
        }
    }

    private func handleUpdateCheck(_ result: UpdateCheckResult, manual: Bool) {
        switch result {
        case let .updateAvailable(release):
            let alert = NSAlert()
            alert.messageText = L10n.text("发现新版本", "Update Available")
            let latestVersion = release.version.map {
                "\($0.major).\($0.minor).\($0.patch)"
            } ?? release.tagName
            alert.informativeText = L10n.text(
                "当前版本：\(aboutCoordinator.metadata.version)\n最新版本：\(latestVersion)",
                "Current version: \(aboutCoordinator.metadata.version)\nLatest version: \(latestVersion)"
            )
            alert.addButton(withTitle: L10n.text("前往下载", "Download"))
            alert.addButton(withTitle: L10n.text("稍后", "Later"))
            if alert.runModal() == .alertFirstButtonReturn {
                if !aboutCoordinator.open(release.htmlURL) {
                    let failureAlert = NSAlert()
                    failureAlert.messageText = AboutCoordinator.openFailureMessage
                    failureAlert.addButton(withTitle: L10n.text("确定", "OK"))
                    failureAlert.runModal()
                }
            }
        case .upToDate:
            guard manual else { return }
            show(.init(message: L10n.text("已是最新版本", "Already up to date")))
        case .unavailable:
            guard manual else { return }
            show(.init(
                message: L10n.text("暂时无法检查更新", "Update Check Unavailable"),
                informativeText: L10n.text(
                    "请检查网络连接，或稍后重试。",
                    "Check your network connection and try again later."
                )
            ))
        }
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
        alert.addButton(withTitle: L10n.text("好", "OK"))
        alert.runModal()
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = aboutCoordinator.metadata.applicationName
        alert.informativeText = aboutCoordinator.metadata.informativeText
        alert.addButton(withTitle: L10n.text("前往 GitHub", "Go to GitHub"))
        alert.addButton(withTitle: L10n.text("确定", "OK"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard aboutCoordinator.openRepository() else {
            let failureAlert = NSAlert()
            failureAlert.messageText = AboutCoordinator.openFailureMessage
            failureAlert.addButton(withTitle: L10n.text("确定", "OK"))
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
