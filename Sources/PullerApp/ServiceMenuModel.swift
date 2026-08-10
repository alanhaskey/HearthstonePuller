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
            title = "卸载服务"
            operation = .uninstall
        case .notInstalled:
            title = "安装服务"
            operation = .install
        case .installedButUnavailable:
            title = "重新启动服务"
            operation = .install
        }
        isEnabled = !isOperationInProgress
    }
}
