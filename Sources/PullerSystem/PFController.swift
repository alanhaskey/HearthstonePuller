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
    func resetRuleStatistics() async throws
    func diagnoseAnchor(for pairs: [StatePair]) async throws -> PFAnchorDiagnostics
    func flushAnchor() async throws
    func releaseEnableReference() async
}

public extension PFControlling {
    /// Older test doubles and alternate controllers may not expose pfctl counters.
    /// The real PFController overrides both methods; the defaults keep the protocol
    /// source-compatible for callers that only need the original operations.
    func resetRuleStatistics() async throws {}

    func diagnoseAnchor(for pairs: [StatePair]) async throws -> PFAnchorDiagnostics {
        .unavailable
    }
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
    case anchorNotAttached
    case anchorRulesNotLoaded
    case invalidEnableToken
    case unsafeStatePair
    case commandFailed(exitCode: Int32, stderr: String)
}

public struct PFAnchorDiagnostics: Equatable, Sendable {
    public let anchorAttached: Bool
    public let loadedRuleCount: Int
    public let evaluations: UInt64
    public let packets: UInt64
    public let bytes: UInt64
    public let matchingStateCount: Int?

    public static let unavailable = PFAnchorDiagnostics(
        anchorAttached: false,
        loadedRuleCount: 0,
        evaluations: 0,
        packets: 0,
        bytes: 0,
        matchingStateCount: nil
    )

    public init(
        anchorAttached: Bool,
        loadedRuleCount: Int,
        evaluations: UInt64,
        packets: UInt64,
        bytes: UInt64,
        matchingStateCount: Int?
    ) {
        self.anchorAttached = anchorAttached
        self.loadedRuleCount = loadedRuleCount
        self.evaluations = evaluations
        self.packets = packets
        self.bytes = bytes
        self.matchingStateCount = matchingStateCount
    }

    public var matched: Bool { packets > 0 }

    public var status: String {
        if !anchorAttached { return "anchor-not-attached" }
        if loadedRuleCount == 0 { return "rules-not-visible" }
        if packets == 0 { return "rule-not-hit" }
        if let matchingStateCount, matchingStateCount > 0 {
            return "state-remained"
        }
        return "rule-hit"
    }

    public var summary: String {
        let states = matchingStateCount.map(String.init) ?? "unknown"
        return "status=\(status) anchorAttached=\(anchorAttached) rules=\(loadedRuleCount) evaluations=\(evaluations) packets=\(packets) bytes=\(bytes) matchingStates=\(states)"
    }
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
        let loaded = try await run(arguments: ["-a", PFRuleSet.anchor, "-sr"])
        let loadedRules = Self.normalizedRules(Self.boundedString(loaded.stdout))
        let expectedRules = rules
            .split(whereSeparator: \Character.isNewline)
            .map(String.init)
            .map(Self.normalizedRules)
        guard !expectedRules.isEmpty,
              expectedRules.allSatisfy({ loadedRules.contains($0) })
        else {
            throw PFControllerError.anchorRulesNotLoaded
        }

        // Loading a named anchor only creates its ruleset. It is effective only
        // when its parent anchor is attached to the active root ruleset.
        try await verifyAnchorAttachment()
    }

    public func killStates(_ pairs: [StatePair]) async throws {
        let uniquePairs = Set(pairs).sorted(by: Self.statePairOrder)
        for attempt in 0..<3 {
            for pair in uniquePairs {
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
            guard attempt < 2 else { continue }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    public func resetRuleStatistics() async throws {
        _ = try await run(arguments: ["-a", PFRuleSet.anchor, "-z"])
    }

    public func diagnoseAnchor(for pairs: [StatePair]) async throws -> PFAnchorDiagnostics {
        let attached = try await anchorIsAttached()
        let verboseRules = try await run(arguments: ["-a", PFRuleSet.anchor, "-vv", "-sr"])
        let labels = try await run(arguments: ["-a", PFRuleSet.anchor, "-s", "labels"])
        let states = try await run(arguments: ["-s", "states"])

        let verboseText = Self.boundedString(verboseRules.stdout)
        let labelText = Self.boundedString(labels.stdout)
        let verboseRuleCount = verboseText
            .split(whereSeparator: \.isNewline)
            .filter { $0.contains("label \"\(PFRuleRenderer.ruleLabel)\"") }
            .count
        let loadedRuleCount = max(
            verboseRuleCount,
            labelText.split(whereSeparator: \.isNewline)
                .filter { $0.contains(PFRuleRenderer.ruleLabel) }
                .count
        )

        let labelCounters = Self.labelCounters(in: labelText)
        let matchingStateCount = Self.matchingStateCount(
            in: Self.boundedString(states.stdout),
            pairs: pairs
        )

        return PFAnchorDiagnostics(
            anchorAttached: attached,
            loadedRuleCount: loadedRuleCount,
            evaluations: labelCounters.evaluations,
            packets: labelCounters.packets,
            bytes: labelCounters.bytes,
            matchingStateCount: matchingStateCount
        )
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

    private func verifyAnchorAttachment() async throws {
        guard try await anchorIsAttached() else {
            throw PFControllerError.anchorNotAttached
        }
    }

    private func anchorIsAttached() async throws -> Bool {
        if let parent = try? await run(arguments: ["-a", "com.apple", "-s", "Anchors"]) {
            let parentText = Self.boundedString(parent.stdout)
            if parentText
                .split(whereSeparator: \.isNewline)
                .contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "hearthstone-puller" })
            {
                return true
            }
        }

        // Apple ships the com.apple/* wildcard in the root ruleset on supported
        // macOS versions. Keep this fallback for versions that do not print child
        // anchors from `-s Anchors`.
        let root = try await run(arguments: ["-sr"])
        return Self.boundedString(root.stdout).contains(#"anchor "com.apple/*""#)
    }

    private static func boundedString(_ data: Data) -> String {
        String(decoding: data.prefix(outputLimit), as: UTF8.self)
    }

    private static func normalizedRules(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func labelCounters(in output: String) -> (evaluations: UInt64, packets: UInt64, bytes: UInt64) {
        var totals = (evaluations: UInt64(0), packets: UInt64(0), bytes: UInt64(0))
        for line in output.split(whereSeparator: \.isNewline) {
            guard line.contains(PFRuleRenderer.ruleLabel) else { continue }
            let values = line
                .split(whereSeparator: { $0 == " " || $0 == "\t" })
                .compactMap { UInt64($0.filter(\.isNumber)) }
            guard values.count >= 3 else { continue }
            totals.evaluations += values[values.count - 3]
            totals.packets += values[values.count - 2]
            totals.bytes += values[values.count - 1]
        }
        return totals
    }

    private static func matchingStateCount(in output: String, pairs: [StatePair]) -> Int? {
        guard !pairs.isEmpty else { return 0 }
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        let matches = lines.filter { line in
            pairs.contains { pair in
                line.contains(pair.localAddress) && line.contains(pair.remoteAddress)
            }
        }
        return Set(matches).count
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
