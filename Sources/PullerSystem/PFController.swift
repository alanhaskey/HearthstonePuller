import Darwin
import Foundation
import PullerCore

public struct CommandResult: Sendable {
    public let stdout: Data
    public let stderr: Data
    public let exitCode: Int32

    public init(stdout: Data, stderr: Data, exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

public protocol CommandRunning: Sendable {
    func run(executable: URL, arguments: [String], stdin: Data?) async throws -> CommandResult
}

public protocol PFControlling: Sendable {
    func verifyAppleAnchor() async throws
    func enable() async throws
    func replaceAnchor(with rules: String) async throws
    func killStates(_ pairs: [StatePair]) async throws
    func flushAnchor() async throws
    func releaseEnableReference() async
}

public struct ProcessCommandRunner: CommandRunning {
    public static let outputLimit = 65_536

    public init() {}

    public func run(
        executable: URL,
        arguments: [String],
        stdin: Data?
    ) async throws -> CommandResult {
        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let stdoutTask = Task.detached {
            try Self.drain(outputPipe.fileHandleForReading, limit: Self.outputLimit)
        }
        let stderrTask = Task.detached {
            try Self.drain(errorPipe.fileHandleForReading, limit: Self.outputLimit)
        }

        do {
            try process.run()
            if let stdin {
                try inputPipe.fileHandleForWriting.write(contentsOf: stdin)
            }
            try inputPipe.fileHandleForWriting.close()
        } catch {
            try? inputPipe.fileHandleForWriting.close()
            try? outputPipe.fileHandleForWriting.close()
            try? errorPipe.fileHandleForWriting.close()
            stdoutTask.cancel()
            stderrTask.cancel()
            throw error
        }

        process.waitUntilExit()
        return try await CommandResult(
            stdout: stdoutTask.value,
            stderr: stderrTask.value,
            exitCode: process.terminationStatus
        )
    }

    private static func drain(_ handle: FileHandle, limit: Int) throws -> Data {
        var retained = Data()
        while let chunk = try handle.read(upToCount: 8_192), !chunk.isEmpty {
            let remaining = limit - retained.count
            if remaining > 0 {
                retained.append(chunk.prefix(remaining))
            }
        }
        return retained
    }
}

public enum PFControllerError: Error, Equatable, Sendable {
    case appleAnchorUnavailable
    case invalidEnableToken
    case unsafeStatePair
    case commandFailed(exitCode: Int32, stderr: String)
}

public actor PFController: PFControlling {
    private static let executable = URL(fileURLWithPath: "/sbin/pfctl")
    private static let outputLimit = 65_536

    private let runner: any CommandRunning
    private var ownedEnableToken: String?

    public init(runner: any CommandRunning = ProcessCommandRunner()) {
        self.runner = runner
    }

    public func verifyAppleAnchor() async throws {
        let result = try await run(arguments: ["-sr"])
        let rules = Self.boundedString(result.stdout)
        guard rules.contains(#"anchor "com.apple/*""#) else {
            throw PFControllerError.appleAnchorUnavailable
        }
    }

    public func enable() async throws {
        guard ownedEnableToken == nil else { return }
        let result = try await run(arguments: ["-E"])
        guard let token = Self.enableToken(stdout: result.stdout, stderr: result.stderr) else {
            throw PFControllerError.invalidEnableToken
        }
        ownedEnableToken = token
    }

    public func replaceAnchor(with rules: String) async throws {
        _ = try await run(
            arguments: ["-a", PFRuleSet.anchor, "-f", "-"],
            stdin: Data(rules.utf8)
        )
    }

    public func killStates(_ pairs: [StatePair]) async throws {
        for pair in Set(pairs).sorted(by: Self.statePairOrder) {
            guard Self.isNumeric(pair.localAddress, family: pair.family),
                  Self.isNumeric(pair.remoteAddress, family: pair.family)
            else {
                throw PFControllerError.unsafeStatePair
            }
            _ = try await run(arguments: [
                "-k", pair.localAddress,
                "-k", pair.remoteAddress,
            ])
        }
    }

    public func flushAnchor() async throws {
        _ = try await run(arguments: ["-a", PFRuleSet.anchor, "-F", "all"])
    }

    public func releaseEnableReference() async {
        guard let token = ownedEnableToken else { return }
        do {
            _ = try await run(arguments: ["-X", token])
            ownedEnableToken = nil
        } catch {
            // Keep the token so a later shutdown attempt can retry the same owned reference.
        }
    }

    private func run(arguments: [String], stdin: Data? = nil) async throws -> CommandResult {
        let result = try await runner.run(
            executable: Self.executable,
            arguments: arguments,
            stdin: stdin
        )
        guard result.exitCode == 0 else {
            throw PFControllerError.commandFailed(
                exitCode: result.exitCode,
                stderr: Self.boundedString(result.stderr)
            )
        }
        return result
    }

    private static func boundedString(_ data: Data) -> String {
        String(decoding: data.prefix(outputLimit), as: UTF8.self)
    }

    private static func enableToken(stdout: Data, stderr: Data) -> String? {
        let output = boundedString(stdout) + "\n" + boundedString(stderr)
        let tokens = output.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let fields = line.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard fields.count == 2, fields[0] == "Token" else { return nil }
            let token = fields[1]
            guard !token.isEmpty, token.allSatisfy(\.isNumber) else { return nil }
            return token
        }
        guard tokens.count == 1 else { return nil }
        return tokens[0]
    }

    private static func isNumeric(_ address: String, family: AddressFamily) -> Bool {
        switch family {
        case .ipv4:
            var value = in_addr()
            return address.withCString { inet_pton(AF_INET, $0, &value) } == 1
        case .ipv6:
            var value = in6_addr()
            return address.withCString { inet_pton(AF_INET6, $0, &value) } == 1
        }
    }

    private static func statePairOrder(_ lhs: StatePair, _ rhs: StatePair) -> Bool {
        if lhs.family.rawValue != rhs.family.rawValue {
            return lhs.family.rawValue < rhs.family.rawValue
        }
        if lhs.localAddress != rhs.localAddress {
            return lhs.localAddress < rhs.localAddress
        }
        return lhs.remoteAddress < rhs.remoteAddress
    }
}
