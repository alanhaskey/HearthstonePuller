import Darwin
import Foundation

enum ServiceInstallationStatus: Equatable, Sendable {
    case installed
    case notInstalled
}

protocol ServiceInstallationChecking: Sendable {
    func status() -> ServiceInstallationStatus
}

struct ServiceInstallationDetector: ServiceInstallationChecking {
    private static let executablePaths = [
        "Library/PrivilegedHelperTools/hearthstone-puller-helper",
        "Library/PrivilegedHelperTools/hearthstone-puller-recovery",
    ]
    private static let regularFilePaths = [
        "Library/LaunchDaemons/com.yunnn.hearthstone-puller.helper.plist",
        "Library/LaunchDaemons/com.yunnn.hearthstone-puller.recovery.plist",
        "Library/Application Support/HearthstonePuller/config.plist",
    ]

    private let rootURL: URL

    init(rootURL: URL = URL(fileURLWithPath: "/", isDirectory: true)) {
        self.rootURL = rootURL
    }

    func status() -> ServiceInstallationStatus {
        for relativePath in Self.executablePaths {
            guard isRegularFile(relativePath, requireExecutable: true) else {
                return .notInstalled
            }
        }
        for relativePath in Self.regularFilePaths {
            guard isRegularFile(relativePath, requireExecutable: false) else {
                return .notInstalled
            }
        }
        return .installed
    }

    private func isRegularFile(
        _ relativePath: String,
        requireExecutable: Bool
    ) -> Bool {
        var information = stat()
        let path = rootURL.appendingPathComponent(relativePath).path
        guard lstat(path, &information) == 0,
              information.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
        else {
            return false
        }
        return !requireExecutable || information.st_mode & 0o111 != 0
    }
}
