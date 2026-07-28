import Darwin
import Foundation
import Security

public struct VerifiedProcess: Hashable, Sendable {
    public let pid: pid_t
    public let startIdentity: ProcessStartIdentity
    public let executableURL: URL

    public init(pid: pid_t, startIdentity: ProcessStartIdentity, executableURL: URL) {
        self.pid = pid
        self.startIdentity = startIdentity
        self.executableURL = executableURL
    }
}

public final class DesignatedRequirement: @unchecked Sendable {
    public let value: SecRequirement

    public init(_ value: SecRequirement) {
        self.value = value
    }
}

public protocol RunningCodeValidating: Sendable {
    func designatedRequirement(forBundle bundleURL: URL) throws -> DesignatedRequirement
    func runningProcess(pid: pid_t, satisfies requirement: DesignatedRequirement) throws -> Bool
}

public protocol HearthstoneLocating: Sendable {
    func locate() throws -> VerifiedProcess?
}

public struct HearthstoneLocator: HearthstoneLocating {
    private let bundleURL: URL
    private let processes: any ProcessSocketObserving
    private let codeValidator: any RunningCodeValidating

    public init(
        bundleURL: URL = URL(fileURLWithPath: "/Applications/Hearthstone/Hearthstone.app"),
        processes: any ProcessSocketObserving = ProcessSocketObserver(),
        codeValidator: any RunningCodeValidating = SecurityRunningCodeValidator()
    ) {
        self.bundleURL = bundleURL
        self.processes = processes
        self.codeValidator = codeValidator
    }

    public func locate() throws -> VerifiedProcess? {
        let normalizedBundle = Self.normalized(bundleURL)
        let executableDirectory = normalizedBundle
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
        let requirement = try codeValidator.designatedRequirement(forBundle: normalizedBundle)

        for pid in try processes.processIDs() {
            do {
                let executableURL = Self.normalized(try processes.executablePath(pid: pid))
                guard Self.isExecutable(executableURL, inside: executableDirectory) else {
                    continue
                }

                let identityBeforeValidation = try processes.startIdentity(pid: pid)
                guard try codeValidator.runningProcess(pid: pid, satisfies: requirement) else {
                    continue
                }
                let identityAfterValidation = try processes.startIdentity(pid: pid)
                guard identityBeforeValidation == identityAfterValidation else {
                    continue
                }

                return VerifiedProcess(
                    pid: pid,
                    startIdentity: identityAfterValidation,
                    executableURL: executableURL
                )
            } catch {
                continue
            }
        }

        return nil
    }

    private static func normalized(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func isExecutable(_ candidate: URL, inside directory: URL) -> Bool {
        guard candidate.isFileURL else { return false }
        let directoryPath = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
        return candidate.path.hasPrefix(directoryPath)
            && candidate.deletingLastPathComponent().path == directory.path
            && !candidate.lastPathComponent.isEmpty
    }
}

public enum SecurityCodeValidationError: Error, Equatable, Sendable {
    case operationFailed(operation: String, status: OSStatus)
    case missingResult(operation: String)
}

public struct SecurityRunningCodeValidator: RunningCodeValidating {
    public init() {}

    public func designatedRequirement(forBundle bundleURL: URL) throws -> DesignatedRequirement {
        var staticCode: SecStaticCode?
        try requireSuccess(
            SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &staticCode),
            operation: "SecStaticCodeCreateWithPath"
        )
        guard let staticCode else {
            throw SecurityCodeValidationError.missingResult(operation: "SecStaticCodeCreateWithPath")
        }

        var requirement: SecRequirement?
        try requireSuccess(
            SecCodeCopyDesignatedRequirement(staticCode, [], &requirement),
            operation: "SecCodeCopyDesignatedRequirement"
        )
        guard let requirement else {
            throw SecurityCodeValidationError.missingResult(
                operation: "SecCodeCopyDesignatedRequirement"
            )
        }
        return DesignatedRequirement(requirement)
    }

    public func runningProcess(
        pid: pid_t,
        satisfies requirement: DesignatedRequirement
    ) throws -> Bool {
        let attributes = NSDictionary(
            object: NSNumber(value: pid),
            forKey: kSecGuestAttributePid as String as NSString
        ) as CFDictionary
        var runningCode: SecCode?
        try requireSuccess(
            SecCodeCopyGuestWithAttributes(nil, attributes, [], &runningCode),
            operation: "SecCodeCopyGuestWithAttributes"
        )
        guard let runningCode else {
            throw SecurityCodeValidationError.missingResult(
                operation: "SecCodeCopyGuestWithAttributes"
            )
        }

        return SecCodeCheckValidity(runningCode, [], requirement.value) == errSecSuccess
    }

    private func requireSuccess(_ status: OSStatus, operation: String) throws {
        guard status == errSecSuccess else {
            throw SecurityCodeValidationError.operationFailed(
                operation: operation,
                status: status
            )
        }
    }
}
