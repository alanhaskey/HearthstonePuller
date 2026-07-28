import Darwin
import Foundation
import XCTest
@testable import PullerSystem

final class PFControllerTests: XCTestCase {
    func testUsesOnlyFixedPFCTLCommandContracts() async throws {
        let runner = FakeCommandRunner(results: [
            .success(stdout: #"anchor "com.apple/*" all"# + "\n"),
            .success(stdout: "pf enabled\nToken : 123456789\n"),
            .success(),
            .success(),
            .success(),
            .success(),
        ])
        let controller = PFController(runner: runner)
        let rules = "block return out quick inet proto tcp from any to 203.0.113.254\n"
        let pair = StatePair(
            family: .ipv4,
            localAddress: "192.0.2.10",
            remoteAddress: "198.51.100.20"
        )

        try await controller.verifyAppleAnchor()
        try await controller.enable()
        try await controller.replaceAnchor(with: rules)
        try await controller.killStates([pair])
        try await controller.flushAnchor()
        await controller.releaseEnableReference()

        let commands = await runner.recordedCommands()
        XCTAssertEqual(commands, [
            .init(arguments: ["-sr"], stdin: nil),
            .init(arguments: ["-E"], stdin: nil),
            .init(
                arguments: ["-a", "com.apple/hearthstone-puller", "-f", "-"],
                stdin: Data(rules.utf8)
            ),
            .init(arguments: ["-k", "192.0.2.10", "-k", "198.51.100.20"], stdin: nil),
            .init(arguments: ["-a", "com.apple/hearthstone-puller", "-F", "all"], stdin: nil),
            .init(arguments: ["-X", "123456789"], stdin: nil),
        ])
        XCTAssertTrue(commands.allSatisfy { $0.executable.path == "/sbin/pfctl" })
    }

    func testRejectsMalformedEnableTokenAndDoesNotReleaseIt() async throws {
        let runner = FakeCommandRunner(results: [
            .success(stdout: "pf enabled without a token\n"),
        ])
        let controller = PFController(runner: runner)

        do {
            try await controller.enable()
            XCTFail("Expected malformed token to be rejected")
        } catch let error as PFControllerError {
            XCTAssertEqual(error, .invalidEnableToken)
        }
        await controller.releaseEnableReference()

        let commands = await runner.recordedCommands()
        XCTAssertEqual(commands.map(\.arguments), [["-E"]])
    }

    func testNonzeroExitThrowsTypedErrorWithBoundedStderr() async throws {
        let oversizedError = String(repeating: "x", count: 70_000)
        let runner = FakeCommandRunner(results: [
            .init(stdout: Data(), stderr: Data(oversizedError.utf8), exitCode: 7),
        ])
        let controller = PFController(runner: runner)

        do {
            try await controller.flushAnchor()
            XCTFail("Expected pfctl failure")
        } catch let error as PFControllerError {
            guard case let .commandFailed(exitCode, stderr) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(exitCode, 7)
            XCTAssertEqual(stderr.utf8.count, 65_536)
        }
    }

    func testRootPFIntegrationWhenExplicitlyEnabled() async throws {
        guard ProcessInfo.processInfo.environment["PF_INTEGRATION_TEST"] == "1" else {
            throw XCTSkip("Set PF_INTEGRATION_TEST=1 to run the root PF integration test")
        }
        guard geteuid() == 0 else {
            throw XCTSkip("PF integration test requires root")
        }

        let runner = ProcessCommandRunner()
        let controller = PFController(runner: runner)
        try await controller.verifyAppleAnchor()
        try await controller.flushAnchor()

        do {
            let rule = "block return out quick inet from any to 203.0.113.254\n"
            try await controller.replaceAnchor(with: rule)
            let result = try await runner.run(
                executable: URL(fileURLWithPath: "/sbin/pfctl"),
                arguments: ["-a", PFRuleSet.anchor, "-sr"],
                stdin: nil
            )
            XCTAssertEqual(result.exitCode, 0)
            XCTAssertTrue(String(decoding: result.stdout, as: UTF8.self).contains("203.0.113.254"))
            try await controller.flushAnchor()
        } catch {
            try? await controller.flushAnchor()
            throw error
        }
    }
}

private actor FakeCommandRunner: CommandRunning {
    private var results: [CommandResult]
    private var commands: [RecordedCommand] = []

    init(results: [CommandResult]) {
        self.results = results
    }

    func run(executable: URL, arguments: [String], stdin: Data?) async throws -> CommandResult {
        commands.append(.init(executable: executable, arguments: arguments, stdin: stdin))
        guard !results.isEmpty else { throw FakeRunnerError.missingResult }
        return results.removeFirst()
    }

    func recordedCommands() -> [RecordedCommand] {
        commands
    }
}

private struct RecordedCommand: Equatable {
    let executable: URL
    let arguments: [String]
    let stdin: Data?

    init(
        executable: URL = URL(fileURLWithPath: "/sbin/pfctl"),
        arguments: [String],
        stdin: Data?
    ) {
        self.executable = executable
        self.arguments = arguments
        self.stdin = stdin
    }
}

private enum FakeRunnerError: Error {
    case missingResult
}

private extension CommandResult {
    static func success(stdout: String = "", stderr: String = "") -> CommandResult {
        CommandResult(
            stdout: Data(stdout.utf8),
            stderr: Data(stderr.utf8),
            exitCode: 0
        )
    }
}
