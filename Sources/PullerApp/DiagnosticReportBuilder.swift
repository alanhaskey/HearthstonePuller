import Foundation

@MainActor
struct DiagnosticReportBuilder {
    static let logPaths = [
        "/Library/Logs/HearthstonePuller/helper.log",
        "/Library/Logs/HearthstonePuller/recovery.log",
    ]
    static let maximumBytesPerLog: UInt64 = 32 * 1_024

    func build(viewModel: PanelStateViewModel, appVersion: String) -> String? {
        guard let code = viewModel.snapshot.errorCode else { return nil }

        var sections = [
            "HearthstonePuller \(L10n.text("诊断报告", "Diagnostic Report"))",
            "\(L10n.text("错误码", "Error Code")): \(code.rawValue)",
            "\(L10n.text("错误原因", "Reason")): \(viewModel.localizedErrorReason(for: code))",
            "\(L10n.text("详细信息", "Details")): \(viewModel.snapshot.message ?? L10n.text("无", "None"))",
            "\(L10n.text("应用版本", "App Version")): \(appVersion)",
            "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "\(L10n.text("生成时间", "Generated At")): \(ISO8601DateFormatter().string(from: Date()))",
        ]

        for path in Self.logPaths {
            sections.append("\n===== \((path as NSString).lastPathComponent) =====")
            sections.append(readLogTail(path: path))
        }
        return sections.joined(separator: "\n")
    }

    private func readLogTail(path: String) -> String {
        do {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            let size = try handle.seekToEnd()
            let offset = size > Self.maximumBytesPerLog
                ? size - Self.maximumBytesPerLog
                : 0
            try handle.seek(toOffset: offset)
            let data = try handle.readToEnd() ?? Data()
            let contents = String(decoding: data, as: UTF8.self)
            if offset > 0 {
                return L10n.text("[仅包含日志末尾]\n", "[Log tail only]\n") + contents
            }
            return contents.isEmpty ? L10n.text("[日志为空]", "[Log is empty]") : contents
        } catch {
            return L10n.text(
                "[无法读取日志：\(String(reflecting: error))]",
                "[Unable to read log: \(String(reflecting: error))]"
            )
        }
    }
}
