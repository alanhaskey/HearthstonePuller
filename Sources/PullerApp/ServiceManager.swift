import Darwin
import Foundation

enum ServiceOperation: Equatable, Sendable {
    case install
    case uninstall

    var scriptName: String {
        switch self {
        case .install: "install-service.sh"
        case .uninstall: "uninstall-service.sh"
        }
    }
}

enum ServiceOperationFailure: Equatable, Sendable {
    case incompletePackage(String)
    case launchFailed(String)
    case scriptFailed(String)
}

enum ServiceOperationResult: Equatable, Sendable {
    case succeeded(ServiceOperation)
    case cancelled
    case failed(ServiceOperationFailure)
    case busy
}

struct ServiceProcessInvocation: Equatable, Sendable {
    let executable: URL
    let arguments: [String]
    let outputLimit: Int
}

struct ServiceProcessResult: Equatable, Sendable {
    let terminationStatus: Int32
    let standardOutput: String
    let standardError: String
}

protocol ServiceProcessRunning: Sendable {
    func run(_ invocation: ServiceProcessInvocation) async throws -> ServiceProcessResult
}

protocol ServiceManaging: Sendable {
    func perform(_ operation: ServiceOperation) async -> ServiceOperationResult
}

struct DefaultServiceProcessRunner: ServiceProcessRunning {
    func run(_ invocation: ServiceProcessInvocation) async throws -> ServiceProcessResult {
        try await Task.detached(priority: .userInitiated) {
            let fileManager = FileManager.default
            let outputDirectory = fileManager.temporaryDirectory
                .appendingPathComponent("HearthstonePuller-Service-\(UUID().uuidString)", isDirectory: true)
            try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: false)
            defer { try? fileManager.removeItem(at: outputDirectory) }

            let standardOutputURL = outputDirectory.appendingPathComponent("stdout")
            let standardErrorURL = outputDirectory.appendingPathComponent("stderr")
            guard fileManager.createFile(atPath: standardOutputURL.path, contents: nil),
                  fileManager.createFile(atPath: standardErrorURL.path, contents: nil)
            else {
                throw ServiceProcessRunnerError.cannotCreateOutputFiles
            }

            let standardOutput = try FileHandle(forWritingTo: standardOutputURL)
            let standardError = try FileHandle(forWritingTo: standardErrorURL)
            let process = Process()
            process.executableURL = invocation.executable
            process.arguments = invocation.arguments
            process.standardOutput = standardOutput
            process.standardError = standardError

            do {
                try process.run()
                process.waitUntilExit()
                try standardOutput.close()
                try standardError.close()
            } catch {
                try? standardOutput.close()
                try? standardError.close()
                throw error
            }

            return ServiceProcessResult(
                terminationStatus: process.terminationStatus,
                standardOutput: try readPrefix(
                    of: standardOutputURL,
                    maximumByteCount: invocation.outputLimit
                ),
                standardError: try readPrefix(
                    of: standardErrorURL,
                    maximumByteCount: invocation.outputLimit
                )
            )
        }.value
    }
}

private enum ServiceProcessRunnerError: Error {
    case cannotCreateOutputFiles
}

private func readPrefix(of url: URL, maximumByteCount: Int) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: max(0, maximumByteCount)) ?? Data()
    return String(decoding: data, as: UTF8.self)
}

actor ServiceManager {
    static let outputLimit = 16 * 1_024
    static let successMarker = "__PULLER_OK__"
    static let cancellationMarker = "__PULLER_CANCELLED__"
    static let appleScript = """
    on run argv
        try
            do shell script "/bin/bash " & quoted form of (item 1 of argv) & " " & quoted form of (item 2 of argv) with administrator privileges
            return "__PULLER_OK__"
        on error messageText number errorNumber
            if errorNumber is -128 then return "__PULLER_CANCELLED__"
            error messageText number errorNumber
        end try
    end run
    """

    private let bundleURL: URL
    private let runner: any ServiceProcessRunning
    private var operationInProgress = false

    init(
        bundleURL: URL = Bundle.main.bundleURL,
        runner: any ServiceProcessRunning = DefaultServiceProcessRunner()
    ) {
        self.bundleURL = bundleURL
        self.runner = runner
    }

    func perform(_ operation: ServiceOperation) async -> ServiceOperationResult {
        guard !operationInProgress else { return .busy }
        operationInProgress = true
        defer { operationInProgress = false }

        let scriptURL: URL
        do {
            scriptURL = try validatedScriptURL(for: operation)
        } catch {
            return .failed(.incompletePackage("应用程序包不完整"))
        }

        let invocation = ServiceProcessInvocation(
            executable: URL(fileURLWithPath: "/usr/bin/osascript"),
            arguments: ["-e", Self.appleScript, "--", scriptURL.path, String(getuid())],
            outputLimit: Self.outputLimit
        )

        do {
            let processResult = try await runner.run(invocation)
            let standardOutput = Self.bounded(processResult.standardOutput)
            let standardError = Self.bounded(processResult.standardError)
            if standardOutput.contains(Self.cancellationMarker) {
                return .cancelled
            }
            guard processResult.terminationStatus == 0,
                  standardOutput.contains(Self.successMarker)
            else {
                let diagnostics = [standardOutput, standardError]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
                return .failed(.scriptFailed(diagnostics))
            }
            return .succeeded(operation)
        } catch {
            return .failed(.launchFailed(String(describing: error)))
        }
    }

    private func validatedScriptURL(for operation: ServiceOperation) throws -> URL {
        let resolvedBundle = bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        try requireType(.directory, at: bundleURL)

        let serviceURL = bundleURL
            .appendingPathComponent("Contents/Resources/Service", isDirectory: true)
        try requireType(.directory, at: serviceURL)
        let resolvedService = serviceURL.standardizedFileURL.resolvingSymlinksInPath()
        guard Self.isStrictDescendant(resolvedService, of: resolvedBundle) else {
            throw ServicePackageError.pathEscapesBundle
        }

        let executableNames = [
            "hearthstone-puller-helper",
            "hearthstone-puller-recovery",
            "install-service.sh",
            "uninstall-service.sh",
            "verify-installation.sh",
        ]
        let plistNames = [
            "com.yunnn.hearthstone-puller.helper.plist",
            "com.yunnn.hearthstone-puller.recovery.plist",
        ]
        for name in executableNames {
            let url = serviceURL.appendingPathComponent(name)
            try requireType(.regularFile, at: url)
            guard FileManager.default.isExecutableFile(atPath: url.path),
                  Self.isStrictDescendant(
                    url.standardizedFileURL.resolvingSymlinksInPath(),
                    of: resolvedService
                  )
            else {
                throw ServicePackageError.unsafeResource
            }
        }
        for name in plistNames {
            let url = serviceURL.appendingPathComponent(name)
            try requireType(.regularFile, at: url)
            guard Self.isStrictDescendant(
                url.standardizedFileURL.resolvingSymlinksInPath(),
                of: resolvedService
            ) else {
                throw ServicePackageError.unsafeResource
            }
        }

        return serviceURL.appendingPathComponent(operation.scriptName).standardizedFileURL
    }

    private func requireType(_ expected: ServicePackageFileType, at url: URL) throws {
        var information = stat()
        guard lstat(url.path, &information) == 0 else {
            throw ServicePackageError.missingResource
        }
        let actual = information.st_mode & mode_t(S_IFMT)
        let expectedMode: mode_t = switch expected {
        case .directory: mode_t(S_IFDIR)
        case .regularFile: mode_t(S_IFREG)
        }
        guard actual == expectedMode else { throw ServicePackageError.unsafeResource }
    }

    private static func isStrictDescendant(_ child: URL, of parent: URL) -> Bool {
        child.path.hasPrefix(parent.path + "/")
    }

    private static func bounded(_ text: String) -> String {
        String(decoding: Data(text.utf8).prefix(outputLimit), as: UTF8.self)
    }
}

extension ServiceManager: ServiceManaging {}

private enum ServicePackageFileType {
    case directory
    case regularFile
}

private enum ServicePackageError: Error {
    case missingResource
    case unsafeResource
    case pathEscapesBundle
}
