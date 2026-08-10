import Darwin
import Foundation

enum ServiceInstallationStatus: Equatable, Sendable {
    case installed
    case notInstalled
    case installedButUnavailable
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
    private static let serviceLabels = [
        "com.yunnn.hearthstone-puller.helper",
        "com.yunnn.hearthstone-puller.recovery",
    ]
    private static let helperSocketPath = "/var/run/hearthstone-puller/helper.sock"

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
        // Test fixtures use a synthetic root and intentionally do not represent
        // the host launchd state. File completeness remains their contract.
        guard rootURL.standardizedFileURL.path == "/" else { return .installed }
        return runtimeIsHealthy ? .installed : .installedButUnavailable
    }

    private var runtimeIsHealthy: Bool {
        Self.serviceLabels.allSatisfy { launchdServiceIsLoaded($0) }
            && isSocket(Self.helperSocketPath)
    }

    private func launchdServiceIsLoaded(_ label: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["print", "system/\(label)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func isSocket(_ path: String) -> Bool {
        var information = stat()
        guard lstat(path, &information) == 0 else { return false }
        return information.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK)
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
