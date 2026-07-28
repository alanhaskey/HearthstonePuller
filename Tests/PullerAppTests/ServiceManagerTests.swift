import Foundation
import XCTest
@testable import PullerApp

final class ServiceManagerTests: XCTestCase {
    func testInstallUsesFixedAppleScriptAndBundleScriptArgument() async throws {
        let package = try ServicePackageFixture()
        defer { package.remove() }
        let runner = RecordingServiceProcessRunner(result: .init(
            terminationStatus: 0,
            standardOutput: "__PULLER_OK__\n",
            standardError: ""
        ))
        let manager = ServiceManager(bundleURL: package.bundleURL, runner: runner)

        let result = await manager.perform(.install)

        XCTAssertEqual(result, .succeeded(.install))
        let invocations = await runner.invocations()
        let invocation = try XCTUnwrap(invocations.first)
        XCTAssertEqual(invocation.executable.path, "/usr/bin/osascript")
        XCTAssertEqual(invocation.arguments.prefix(2), ["-e", ServiceManager.appleScript])
        XCTAssertEqual(invocation.arguments.last, package.serviceURL.appendingPathComponent("install-service.sh").path)
        XCTAssertFalse(ServiceManager.appleScript.contains(package.bundleURL.path))
        XCTAssertEqual(invocation.outputLimit, 16 * 1_024)
    }

    func testUninstallSelectsOnlyFixedUninstallScript() async throws {
        let package = try ServicePackageFixture()
        defer { package.remove() }
        let runner = RecordingServiceProcessRunner(result: .init(
            terminationStatus: 0,
            standardOutput: "__PULLER_OK__",
            standardError: ""
        ))
        let manager = ServiceManager(bundleURL: package.bundleURL, runner: runner)

        let result = await manager.perform(.uninstall)
        XCTAssertEqual(result, .succeeded(.uninstall))
        let invocations = await runner.invocations()
        let invocation = try XCTUnwrap(invocations.first)
        XCTAssertEqual(invocation.arguments.last, package.serviceURL.appendingPathComponent("uninstall-service.sh").path)
    }

    func testMissingPackageIsRejectedBeforeLaunchingProcess() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServiceManagerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let runner = RecordingServiceProcessRunner.successful()
        let manager = ServiceManager(bundleURL: root.appendingPathComponent("Missing.app"), runner: runner)

        let result = await manager.perform(.install)

        guard case .failed(.incompletePackage) = result else {
            return XCTFail("Expected incomplete package, got \(result)")
        }
        let invocations = await runner.invocations()
        XCTAssertTrue(invocations.isEmpty)
    }

    func testSymlinkedScriptIsRejectedBeforeLaunchingProcess() async throws {
        let package = try ServicePackageFixture()
        defer { package.remove() }
        let script = package.serviceURL.appendingPathComponent("install-service.sh")
        try FileManager.default.removeItem(at: script)
        try FileManager.default.createSymbolicLink(
            at: script,
            withDestinationURL: package.serviceURL.appendingPathComponent("uninstall-service.sh")
        )
        let runner = RecordingServiceProcessRunner.successful()
        let manager = ServiceManager(bundleURL: package.bundleURL, runner: runner)

        let result = await manager.perform(.install)

        guard case .failed(.incompletePackage) = result else {
            return XCTFail("Expected incomplete package, got \(result)")
        }
        let invocations = await runner.invocations()
        XCTAssertTrue(invocations.isEmpty)
    }

    func testAuthorizationCancellationHasDistinctResult() async throws {
        let package = try ServicePackageFixture()
        defer { package.remove() }
        let runner = RecordingServiceProcessRunner(result: .init(
            terminationStatus: 0,
            standardOutput: "__PULLER_CANCELLED__\n",
            standardError: ""
        ))
        let manager = ServiceManager(bundleURL: package.bundleURL, runner: runner)

        let result = await manager.perform(.install)
        XCTAssertEqual(result, .cancelled)
    }

    func testNonzeroExitReturnsBoundedDiagnostics() async throws {
        let package = try ServicePackageFixture()
        defer { package.remove() }
        let runner = RecordingServiceProcessRunner(result: .init(
            terminationStatus: 1,
            standardOutput: String(repeating: "o", count: 20_000),
            standardError: String(repeating: "e", count: 20_000)
        ))
        let manager = ServiceManager(bundleURL: package.bundleURL, runner: runner)

        let result = await manager.perform(.install)

        guard case let .failed(.scriptFailed(diagnostics)) = result else {
            return XCTFail("Expected script failure, got \(result)")
        }
        XCTAssertLessThanOrEqual(diagnostics.utf8.count, 32 * 1_024 + 1)
    }

    func testConcurrentOperationIsRejected() async throws {
        let package = try ServicePackageFixture()
        defer { package.remove() }
        let runner = PausingServiceProcessRunner()
        let manager = ServiceManager(bundleURL: package.bundleURL, runner: runner)

        let first = Task { await manager.perform(.install) }
        await runner.waitUntilStarted()

        let concurrentResult = await manager.perform(.uninstall)
        XCTAssertEqual(concurrentResult, .busy)

        await runner.release()
        let firstResult = await first.value
        XCTAssertEqual(firstResult, .succeeded(.install))
    }
}

private struct ServicePackageFixture {
    let rootURL: URL
    let bundleURL: URL
    let serviceURL: URL

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServiceManagerTests-\(UUID().uuidString)", isDirectory: true)
        bundleURL = rootURL.appendingPathComponent("HearthstonePuller.app", isDirectory: true)
        serviceURL = bundleURL.appendingPathComponent("Contents/Resources/Service", isDirectory: true)
        try FileManager.default.createDirectory(at: serviceURL, withIntermediateDirectories: true)

        let executableNames = [
            "hearthstone-puller-helper",
            "hearthstone-puller-recovery",
            "install-service.sh",
            "uninstall-service.sh",
            "verify-installation.sh",
        ]
        for name in executableNames {
            let url = serviceURL.appendingPathComponent(name)
            try Data("#!/bin/bash\nexit 0\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        for name in [
            "com.yunnn.hearthstone-puller.helper.plist",
            "com.yunnn.hearthstone-puller.recovery.plist",
        ] {
            try Data("<plist/>\n".utf8).write(to: serviceURL.appendingPathComponent(name))
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private actor RecordingServiceProcessRunner: ServiceProcessRunning {
    private let result: ServiceProcessResult
    private var received: [ServiceProcessInvocation] = []

    init(result: ServiceProcessResult) {
        self.result = result
    }

    static func successful() -> RecordingServiceProcessRunner {
        RecordingServiceProcessRunner(result: .init(
            terminationStatus: 0,
            standardOutput: "__PULLER_OK__",
            standardError: ""
        ))
    }

    func run(_ invocation: ServiceProcessInvocation) async throws -> ServiceProcessResult {
        received.append(invocation)
        return result
    }

    func invocations() -> [ServiceProcessInvocation] { received }
}

private actor PausingServiceProcessRunner: ServiceProcessRunning {
    private var started = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func run(_ invocation: ServiceProcessInvocation) async throws -> ServiceProcessResult {
        started = true
        startedWaiters.forEach { $0.resume() }
        startedWaiters.removeAll()
        await withCheckedContinuation { releaseContinuation = $0 }
        return ServiceProcessResult(
            terminationStatus: 0,
            standardOutput: "__PULLER_OK__",
            standardError: ""
        )
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}
