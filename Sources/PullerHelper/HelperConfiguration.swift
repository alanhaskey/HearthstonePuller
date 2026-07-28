import Darwin
import Foundation

public struct HelperConfiguration: Codable, Equatable, Sendable {
    public static let defaultPath = "/Library/Application Support/HearthstonePuller/config.plist"

    public let allowedUID: uid_t

    public init(allowedUID: uid_t) {
        self.allowedUID = allowedUID
    }

    public static func load(path: String = defaultPath) throws -> Self {
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else {
            throw HelperConfigurationError.systemCall(operation: "lstat", errno: errno)
        }
        guard metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == 0,
              metadata.st_mode & 0o022 == 0
        else {
            throw HelperConfigurationError.unsafeConfigurationFile
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
        let configuration = try PropertyListDecoder().decode(Self.self, from: data)
        guard configuration.allowedUID >= 501 else {
            throw HelperConfigurationError.invalidAllowedUID
        }
        return configuration
    }
}

public enum HelperConfigurationError: Error, Equatable, Sendable {
    case unsafeConfigurationFile
    case invalidAllowedUID
    case systemCall(operation: String, errno: Int32)
}
