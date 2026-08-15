struct ServiceMenuModel: Equatable, Sendable {
    let title: String
    let operation: ServiceOperation
    let isEnabled: Bool

    init(
        installationStatus: ServiceInstallationStatus,
        isOperationInProgress: Bool
    ) {
        switch installationStatus {
        case .installed:
            title = L10n.text("卸载服务", "Uninstall Service")
            operation = .uninstall
        case .notInstalled:
            title = L10n.text("安装服务", "Install Service")
            operation = .install
        case .installedButUnavailable:
            title = L10n.text("重新启动服务", "Restart Service")
            operation = .install
        }
        isEnabled = !isOperationInProgress
    }
}
