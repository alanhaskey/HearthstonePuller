# macOS Hearthstone Puller Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a personal-use macOS floating button that asks a narrowly privileged helper to interrupt only the currently observed Hearthstone endpoints for a fixed 1.5 seconds, with independent PF recovery.

**Architecture:** A SwiftPM workspace produces an unprivileged AppKit UI, a root helper, and an independent root recovery daemon. Pure Swift libraries own state, IPC models, process identity abstractions, and PF rule generation; small macOS adapters use Security.framework, `libproc`, launchd, and `/sbin/pfctl`. All privileged behavior is exercised through fakes before opt-in root integration tests.

**Tech Stack:** Swift 6.3, Swift Package Manager, AppKit, Security.framework, Network.framework address types, Darwin/libproc, Unix domain sockets, launchd, PF, XCTest, shell packaging scripts.

---

## Prerequisites

The installed Xcode is `/Applications/Xcode.app` version 26.6, while the global developer directory currently points at Command Line Tools. Every command in this plan assumes:

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
```

Do not run `sudo xcode-select --switch`; keeping the selection local to the shell avoids changing unrelated projects.

The current local Hearthstone bundle reports:

```text
Path:       /Applications/Hearthstone/Hearthstone.app
Identifier: unity.Blizzard Entertainment.Hearthstone
Team ID:    G847MC6JZ5
Architectures: arm64, x86_64
```

These values are test observations, not production constants. Production identity matching derives a designated requirement from the locally installed app bundle.

## File Map

```text
Package.swift
Sources/
  PullerCore/
    PullerState.swift              UI/helper state and status snapshots
    InterruptionStateMachine.swift authoritative state transitions
    ConnectionModels.swift         validated socket metadata
    IPCMessages.swift              closed request/response protocol
    FramedConnection.swift         length-delimited Codable transport
  PullerSystem/
    HearthstoneLocator.swift       process discovery and running-code validation
    ProcessSocketObserver.swift    libproc socket enumeration adapter
    PFRuleRenderer.swift           deterministic PF rules
    PFController.swift             fixed pfctl invocation boundary
    UnixPeerCredentials.swift      getpeereid wrapper
  CProcShim/
    include/PullerProc.h           stable C structs for Swift
    PullerProc.c                   libproc-to-model conversion
  PullerHelper/
    HelperEngine.swift             cut orchestration
    HelperServer.swift             authenticated UI socket
    main.swift                     launch daemon entry point
  PullerRecovery/
    RecoveryEngine.swift           independent absolute-deadline flush
    RecoveryServer.swift           root-only arm protocol
    main.swift                     recovery daemon entry point
  PullerApp/
    AppDelegate.swift              application lifecycle
    FloatingPanelController.swift  non-activating draggable panel
    PullerButtonView.swift         state rendering and interactions
    HelperClient.swift             status/cut/restore client
    main.swift                     AppKit entry point
Tests/
  PullerCoreTests/
  PullerSystemTests/
  PullerHelperTests/
  PullerRecoveryTests/
  PullerAppTests/
Fixtures/
  EchoServer/main.swift            local TCP fixture
  SocketClient/main.swift          target/control client fixture
Resources/
  com.yunnn.hearthstone-puller.helper.plist
  com.yunnn.hearthstone-puller.recovery.plist
  AppInfo.plist
scripts/
  build-release.sh
  package-app.sh
  install-helper.sh
  uninstall-helper.sh
  verify-installation.sh
```

## Task 1: Scaffold the SwiftPM Workspace

**Files:**
- Create: `Package.swift`
- Create: `Sources/PullerCore/PullerState.swift`
- Create: `Tests/PullerCoreTests/PullerStateTests.swift`
- Create: `.gitignore`

- [ ] **Step 1: Write the package manifest and first failing test**

Use a macOS 13 deployment target. Add later products when their first source files are introduced so every intermediate commit remains buildable:

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "HearthstonePuller",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "PullerCore", targets: ["PullerCore"]),
    ],
    targets: [
        .target(name: "PullerCore"),
        .testTarget(name: "PullerCoreTests", dependencies: ["PullerCore"]),
    ]
)
```

Create `PullerStateTests.swift`:

```swift
import XCTest
@testable import PullerCore

final class PullerStateTests: XCTestCase {
    func testReadyIsActionable() {
        XCTAssertTrue(PullerState.ready.isActionable)
        XCTAssertFalse(PullerState.absent.isActionable)
    }
}
```

- [ ] **Step 2: Run the test and verify the missing type failure**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter PullerStateTests
```

Expected: compilation fails because `PullerState` is undefined.

- [ ] **Step 3: Add the minimal state type and ignore build output**

```swift
public enum PullerState: String, Codable, Sendable, Equatable {
    case helperUnavailable
    case absent
    case ready
    case cutting
    case waitingForReconnect
    case error

    public var isActionable: Bool {
        self == .ready
    }
}
```

Create `.gitignore`:

```gitignore
.build/
build/
.swiftpm/
*.xcuserstate
.DS_Store
```

- [ ] **Step 4: Run the test suite**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`

Expected: `PullerStateTests.testReadyIsActionable` passes.

- [ ] **Step 5: Commit**

```bash
git add Package.swift Sources Tests .gitignore
git commit -m "build: scaffold Swift workspace"
```

## Task 2: Define Connection Models and the Authoritative State Machine

**Files:**
- Create: `Sources/PullerCore/ConnectionModels.swift`
- Create: `Sources/PullerCore/InterruptionStateMachine.swift`
- Create: `Tests/PullerCoreTests/ConnectionModelsTests.swift`
- Create: `Tests/PullerCoreTests/InterruptionStateMachineTests.swift`

- [ ] **Step 1: Write failing validation and transition tests**

```swift
import XCTest
@testable import PullerCore

final class ConnectionModelsTests: XCTestCase {
    func testRejectsUnspecifiedRemoteAddress() {
        XCTAssertThrowsError(try ObservedSocket(
            family: .ipv4, transport: .tcp,
            localAddress: "192.0.2.10", localPort: 50123,
            remoteAddress: "0.0.0.0", remotePort: 3724
        ))
    }
}

final class InterruptionStateMachineTests: XCTestCase {
    func testCutHasFixedDeadlineAndCannotBeExtended() throws {
        var machine = InterruptionStateMachine()
        machine.observe(connectionCount: 1)
        try machine.beginCut(now: .seconds(10))
        XCTAssertEqual(machine.snapshot(now: .seconds(10)).remainingMilliseconds, 1500)
        XCTAssertThrowsError(try machine.beginCut(now: .seconds(10.2)))
        machine.deadlineReached(now: .seconds(11.5))
        XCTAssertEqual(machine.snapshot(now: .seconds(11.5)).state, .waitingForReconnect)
    }
}
```

- [ ] **Step 2: Verify both tests fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'ConnectionModelsTests|InterruptionStateMachineTests'`

Expected: missing `ObservedSocket` and `InterruptionStateMachine` symbols.

- [ ] **Step 3: Implement validated value types**

Define `AddressFamily`, `TransportProtocol`, and `ObservedSocket`. Validate numeric addresses with `inet_pton`, require nonzero remote ports, and reject IPv4 `0.0.0.0`, IPv6 `::`, multicast, broadcast, and loopback endpoints. Keep local loopback available only to test fixtures through an explicit `allowLoopback` initializer parameter that defaults to false.

```swift
public struct ObservedSocket: Codable, Hashable, Sendable {
    public let family: AddressFamily
    public let transport: TransportProtocol
    public let localAddress: String
    public let localPort: UInt16
    public let remoteAddress: String
    public let remotePort: UInt16
}
```

- [ ] **Step 4: Implement the state machine with no wall-clock dependency**

```swift
public struct PullerSnapshot: Codable, Equatable, Sendable {
    public let state: PullerState
    public let connectionCount: Int
    public let remainingMilliseconds: Int
    public let message: String?
}

public struct InterruptionStateMachine: Sendable {
    public static let cutDuration = Duration.milliseconds(1500)
    private var state: PullerState = .absent
    private var connectionCount = 0
    private var deadline: Duration?

    public mutating func observe(connectionCount: Int)
    public mutating func beginCut(now: Duration) throws
    public mutating func deadlineReached(now: Duration)
    public mutating func restore(connectionCount: Int)
    public mutating func fail(_ message: String)
    public func snapshot(now: Duration) -> PullerSnapshot
}
```

Use `ContinuousClock` only in adapters; tests pass elapsed `Duration` values directly.

- [ ] **Step 5: Run tests and commit**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter PullerCoreTests`

Expected: all model and transition tests pass.

```bash
git add Sources/PullerCore Tests/PullerCoreTests
git commit -m "feat: add connection models and cut state machine"
```

## Task 3: Close and Frame the IPC Protocol

**Files:**
- Create: `Sources/PullerCore/IPCMessages.swift`
- Create: `Sources/PullerCore/FramedConnection.swift`
- Create: `Tests/PullerCoreTests/IPCMessagesTests.swift`
- Create: `Tests/PullerCoreTests/FramedConnectionTests.swift`

- [ ] **Step 1: Write tests proving the protocol cannot carry arbitrary PF input**

```swift
func testCutRequestHasNoPayload() throws {
    let data = try JSONEncoder().encode(HelperRequest.cut)
    XCTAssertEqual(String(decoding: data, as: UTF8.self), #"{"cut":{}}"#)
}

func testDecoderRejectsFrameLargerThan64KiB() {
    var decoder = FrameDecoder(maximumPayloadSize: 65_536)
    XCTAssertThrowsError(try decoder.append(Data(repeating: 0xff, count: 4)))
}
```

- [ ] **Step 2: Verify tests fail, then implement the closed message enums**

```swift
public enum HelperRequest: Codable, Equatable, Sendable {
    case status
    case cut
    case restore
}

public enum HelperResponse: Codable, Equatable, Sendable {
    case status(PullerSnapshot)
    case accepted(PullerSnapshot)
    case rejected(code: String, message: String, snapshot: PullerSnapshot)
}

public enum RecoveryRequest: Codable, Equatable, Sendable {
    case arm(deadlineEpochMilliseconds: Int64)
    case flushNow
    case status
}
```

There is deliberately no generic command, PID, path, address, duration, or rule case.

- [ ] **Step 3: Implement four-byte big-endian framing**

`FramedConnection` must prefix every JSON payload with an unsigned 32-bit length, enforce 64 KiB before allocation, support partial reads, emit exactly one decoded message at a time, and reject trailing invalid JSON without closing unrelated file descriptors.

- [ ] **Step 4: Run focused tests**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'IPCMessagesTests|FramedConnectionTests'`

Expected: round trips, partial frames, oversize frames, and malformed JSON cases pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/PullerCore Tests/PullerCoreTests
git commit -m "feat: define restricted framed IPC protocol"
```

## Task 4: Add the libproc C Shim and Socket Observer

**Files:**
- Modify: `Package.swift`
- Create: `Sources/CProcShim/include/PullerProc.h`
- Create: `Sources/CProcShim/PullerProc.c`
- Create: `Sources/PullerSystem/ProcessSocketObserver.swift`
- Create: `Tests/PullerSystemTests/ProcessSocketObserverTests.swift`

- [ ] **Step 1: Define a stable C boundary**

Add the `PullerSystem` product, `CProcShim` and `PullerSystem` targets, and `PullerSystemTests` target to `Package.swift`:

```swift
.library(name: "PullerSystem", targets: ["PullerSystem"])

.target(
    name: "CProcShim",
    publicHeadersPath: "include",
    linkerSettings: [.linkedLibrary("proc")]
),
.target(name: "PullerSystem", dependencies: ["PullerCore", "CProcShim"]),
.testTarget(name: "PullerSystemTests", dependencies: ["PullerSystem"])
```

Expose only fixed-size numeric records so Swift never depends on private struct layout:

```c
#ifndef PULLER_PROC_H
#define PULLER_PROC_H
#include <stdint.h>
#include <sys/types.h>
#include <netinet/in.h>

typedef struct {
    int32_t family;
    int32_t socket_type;
    int32_t protocol_number;
    uint8_t local_address[16];
    uint8_t remote_address[16];
    uint16_t local_port;
    uint16_t remote_port;
    int32_t tcp_state;
} puller_socket_record;

int puller_list_pids(pid_t *buffer, int capacity);
int puller_process_path(pid_t pid, char *buffer, int capacity);
int puller_process_start(pid_t pid, uint64_t *seconds, uint64_t *microseconds);
int puller_list_sockets(pid_t pid, puller_socket_record *buffer, int capacity);
#endif
```

Implement the functions with `proc_listpids`, `proc_pidpath`, `PROC_PIDTBSDINFO`, `PROC_PIDLISTFDS`, `PROC_PIDFDSOCKETINFO`, `socket_fdinfo`, and network-byte-order conversion. Return a nonnegative record count or `-errno`; skip unconnected sockets whose remote port is zero.

- [ ] **Step 2: Write an integration test around the current test process**

The test opens a POSIX TCP listener on `127.0.0.1`, connects a client socket, accepts it, calls `ProcessSocketObserver.sockets(pid: getpid(), allowLoopback: true)`, and asserts that the client-side local/remote ports appear. Close all three descriptors in `defer` blocks.

- [ ] **Step 3: Verify the test fails before the Swift adapter exists**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ProcessSocketObserverTests`

Expected: missing `ProcessSocketObserver`.

- [ ] **Step 4: Implement the adapter**

```swift
public struct ProcessStartIdentity: Hashable, Codable, Sendable {
    public let seconds: UInt64
    public let microseconds: UInt64
}

public protocol ProcessSocketObserving: Sendable {
    func processIDs() throws -> [pid_t]
    func executablePath(pid: pid_t) throws -> URL
    func startIdentity(pid: pid_t) throws -> ProcessStartIdentity
    func sockets(pid: pid_t, allowLoopback: Bool) throws -> [ObservedSocket]
}
```

Convert addresses with `inet_ntop`, validate every result through `ObservedSocket`, deduplicate identical records, and sort deterministically for tests and PF generation.

- [ ] **Step 5: Run all tests and commit**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ProcessSocketObserverTests
git add Sources/CProcShim Sources/PullerSystem Tests/PullerSystemTests
git commit -m "feat: observe process sockets through libproc"
```

## Task 5: Verify the Running Hearthstone Code

**Files:**
- Create: `Sources/PullerSystem/HearthstoneLocator.swift`
- Create: `Tests/PullerSystemTests/HearthstoneLocatorTests.swift`

- [ ] **Step 1: Write tests using injected process and code validators**

Cover these exact cases:

- A candidate under `Hearthstone.app/Contents/MacOS/Hearthstone` with matching designated requirement is selected.
- `Hearthstone Beta Launcher.app` is rejected.
- A matching filename outside the bundle is rejected.
- A PID whose start identity changes between discovery and socket observation is rejected.
- A failed `SecCodeCheckValidity` returns no target rather than a fallback name match.

- [ ] **Step 2: Define the boundary before implementing Security.framework calls**

```swift
public struct VerifiedProcess: Hashable, Sendable {
    public let pid: pid_t
    public let startIdentity: ProcessStartIdentity
    public let executableURL: URL
}

public final class DesignatedRequirement: @unchecked Sendable {
    public let value: SecRequirement
    public init(_ value: SecRequirement) { self.value = value }
}

public protocol RunningCodeValidating: Sendable {
    func designatedRequirement(forBundle bundleURL: URL) throws -> DesignatedRequirement
    func runningProcess(pid: pid_t, satisfies requirement: DesignatedRequirement) throws -> Bool
}

public protocol HearthstoneLocating: Sendable {
    func locate() throws -> VerifiedProcess?
}
```

- [ ] **Step 3: Implement dynamic requirement derivation**

Use `SecStaticCodeCreateWithPath` and `SecCodeCopyDesignatedRequirement` for `/Applications/Hearthstone/Hearthstone.app`. For each candidate PID, use `SecCodeCopyGuestWithAttributes` with `kSecGuestAttributePid`, then `SecCodeCheckValidity` against the derived requirement. Resolve and standardize paths before confirming membership in the exact bundle.

Do not hard-code the current Team ID, CDHash, version, or bundle hash. Log the current signing identifier and Team ID only in opt-in diagnostics.

- [ ] **Step 4: Add an opt-in local observation test**

Gate a test with `HEARTHSTONE_OBSERVATION_TEST=1`. When enabled and Hearthstone is running, assert that the locator returns the main executable and the start identity remains stable across two immediate reads. When the variable is absent, skip with `XCTSkip`.

- [ ] **Step 5: Run tests and commit**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter HearthstoneLocatorTests
git add Sources/PullerSystem Tests/PullerSystemTests
git commit -m "feat: verify the running Hearthstone process"
```

## Task 6: Render Deterministic, Narrow PF Rules

**Files:**
- Create: `Sources/PullerSystem/PFRuleRenderer.swift`
- Create: `Tests/PullerSystemTests/PFRuleRendererTests.swift`

- [ ] **Step 1: Write exact-output tests**

For a TCP connection from `192.0.2.10` to `198.51.100.20:3724`, require:

```text
block drop quick out inet proto tcp from 192.0.2.10 to 198.51.100.20 port = 3724
block drop quick in inet proto tcp from 198.51.100.20 port = 3724 to 192.0.2.10
```

Add equivalent `inet6` and UDP cases. Assert deduplication, stable sorting, a final newline, and rejection of unspecified/multicast endpoints.

- [ ] **Step 2: Verify tests fail, then implement a pure renderer**

```swift
public struct PFRuleSet: Equatable, Sendable {
    public static let anchor = "com.apple/hearthstone-puller"
    public let rules: String
    public let statePairs: [StatePair]
}

public struct StatePair: Hashable, Sendable {
    public let family: AddressFamily
    public let localAddress: String
    public let remoteAddress: String
}

public enum PFRuleRenderer {
    public static func render(_ sockets: [ObservedSocket]) throws -> PFRuleSet
}
```

Never interpolate process names, paths, shell fragments, hostnames, or user input.

- [ ] **Step 3: Run focused and full tests**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter PFRuleRendererTests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

Expected: exact PF output tests and all preceding tests pass.

- [ ] **Step 4: Commit**

```bash
git add Sources/PullerSystem Tests/PullerSystemTests
git commit -m "feat: generate narrow Hearthstone PF rules"
```

## Task 7: Isolate pfctl Behind a Fixed Command Runner

**Files:**
- Create: `Sources/PullerSystem/PFController.swift`
- Create: `Tests/PullerSystemTests/PFControllerTests.swift`

- [ ] **Step 1: Write fake-runner tests for every privileged command**

Assert these executable/argument contracts exactly:

```text
/sbin/pfctl -sr
/sbin/pfctl -E
/sbin/pfctl -a com.apple/hearthstone-puller -f -
/sbin/pfctl -a com.apple/hearthstone-puller -F all
/sbin/pfctl -k <local-address> -k <remote-address>
/sbin/pfctl -X <owned-token>
```

Verify that rules travel through standard input, a nonzero exit throws a typed error with bounded stderr, enable-token parsing rejects malformed output, and release only accepts the token returned by this controller instance.

- [ ] **Step 2: Implement the execution boundary**

```swift
public struct CommandResult: Sendable {
    public let stdout: Data
    public let stderr: Data
    public let exitCode: Int32
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
```

Use `Process` with the hard-coded `/sbin/pfctl` URL, pipes drained concurrently, a 64 KiB output cap, and no shell.

- [ ] **Step 3: Add an opt-in root integration test**

Gate with both `PF_INTEGRATION_TEST=1` and `geteuid() == 0`. It verifies the `com.apple/*` anchor, loads only a harmless block rule for documentation-only TEST-NET-3 address `203.0.113.254`, confirms it appears under the dedicated anchor, and flushes in `defer`. It must not kill states or touch the root ruleset.

- [ ] **Step 4: Run non-root tests and commit**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter PFControllerTests
git add Sources/PullerSystem Tests/PullerSystemTests
git commit -m "feat: add fixed PF controller boundary"
```

## Task 8: Implement the Independent Recovery Engine

**Files:**
- Modify: `Package.swift`
- Create: `Sources/PullerRecovery/RecoveryEngine.swift`
- Create: `Sources/PullerRecovery/RecoveryServer.swift`
- Create: `Sources/PullerRecovery/main.swift`
- Create: `Tests/PullerRecoveryTests/RecoveryEngineTests.swift`

- [ ] **Step 1: Write deadline and fail-open tests with a manual clock**

Add the recovery executable and test target to `Package.swift`:

```swift
.executable(name: "hearthstone-puller-recovery", targets: ["PullerRecovery"])

.executableTarget(name: "PullerRecovery", dependencies: ["PullerCore", "PullerSystem"]),
.testTarget(name: "PullerRecoveryTests", dependencies: ["PullerRecovery"])
```

Test that:

- `arm(deadline)` acknowledges only after the deadline is stored.
- A later arm request may shorten but never extend an existing armed deadline.
- Reaching the deadline calls `flushAnchor()` exactly once.
- `flushNow` flushes and disarms.
- Startup flushes before the server accepts requests.
- Sleep/wake with an expired wall deadline flushes immediately.

- [ ] **Step 2: Implement the recovery actor**

```swift
public actor RecoveryEngine {
    private let pf: PFControlling
    private var armedWallDeadline: Date?
    private var armedMonotonicDeadline: ContinuousClock.Instant?
    private var timerTask: Task<Void, Never>?

    public func start() async throws
    public func arm(deadline: Date) async throws -> Date
    public func flushNow() async throws
    public func status() -> Date?
}
```

Clamp accepted deadlines to `now + 0.1 ... now + 2.5 seconds`; the helper normally sends `now + 2.0 seconds`. Convert the accepted interval into a `ContinuousClock` deadline so changing the wall clock cannot extend an armed cut. Retain the wall deadline only to detect an expired deadline immediately after sleep/wake. Cancellation of an old timer must not suppress the earlier deadline.

- [ ] **Step 3: Implement the root-only recovery socket**

Bind `/var/run/hearthstone-puller/recovery.sock`, set owner `root:wheel` and mode `0600`, verify peer UID is zero with `getpeereid`, and support only `RecoveryRequest`. Refuse to start if the socket path exists but is not a socket owned by root.

- [ ] **Step 4: Add the executable entry point and run tests**

`main.swift` creates `PFController`, starts `RecoveryEngine`, then starts `RecoveryServer`. On SIGTERM it flushes before exit.

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter PullerRecoveryTests`

Expected: all deadline, startup, and peer-authorization tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/PullerRecovery Tests/PullerRecoveryTests
git commit -m "feat: add independent PF recovery daemon"
```

## Task 9: Orchestrate Cuts in the Privileged Helper

**Files:**
- Modify: `Package.swift`
- Create: `Sources/PullerHelper/HelperEngine.swift`
- Create: `Tests/PullerHelperTests/HelperEngineTests.swift`

- [ ] **Step 1: Write an end-to-end fake dependency test**

Add the helper executable and test target to `Package.swift`:

```swift
.executable(name: "hearthstone-puller-helper", targets: ["PullerHelper"])

.executableTarget(name: "PullerHelper", dependencies: ["PullerCore", "PullerSystem"]),
.testTarget(name: "PullerHelperTests", dependencies: ["PullerHelper"])
```

The fake scenario supplies one verified process and one TCP socket. Assert this strict event order:

```text
locate process
read start identity
observe sockets
arm recovery for now + 2.0s
replace dedicated anchor
kill matching state pairs
enter CUTTING
poll for new sockets during window
flush anchor at 1.5s
enter WAITING_RECONNECT
```

Add failures at every privileged step and assert that any failure after arming invokes `flushAnchor`, reports `.error`, and never lengthens the deadline. Assert a second cut is rejected.

- [ ] **Step 2: Define explicit dependencies**

```swift
public protocol RecoveryArming: Sendable {
    func arm(deadline: Date) async throws
    func flushNow() async throws
}

public protocol HelperTimeSource: Sendable {
    var elapsed: Duration { get }
    var wallNow: Date { get }
    func sleep(for duration: Duration) async throws
}

public actor HelperEngine {
    public init(
        locator: HearthstoneLocating,
        sockets: ProcessSocketObserving,
        pf: PFControlling,
        recovery: RecoveryArming,
        time: HelperTimeSource
    )

    public func start() async throws
    public func handle(_ request: HelperRequest) async -> HelperResponse
}
```

- [ ] **Step 3: Implement cut orchestration**

On startup, flush the anchor, verify `com.apple/*`, enable PF with an owned token, and begin a low-frequency status observation loop. On cut, revalidate the PID start identity immediately before rule installation. Poll only during CUTTING at a 50-millisecond interval; atomically replace rules when the deduplicated socket set changes.

At 1.5 seconds, flush before transitioning. At approximately two seconds the recovery daemon independently flushes again. If the target exits, flush and transition to absent.

- [ ] **Step 4: Run helper tests and commit**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter PullerHelperTests
git add Sources/PullerHelper Tests/PullerHelperTests
git commit -m "feat: orchestrate fixed Hearthstone cuts"
```

## Task 10: Authenticate the UI Socket and Finish Helper Entry Points

**Files:**
- Create: `Sources/PullerSystem/UnixPeerCredentials.swift`
- Create: `Sources/PullerHelper/HelperServer.swift`
- Create: `Sources/PullerHelper/main.swift`
- Create: `Tests/PullerHelperTests/HelperServerTests.swift`

- [ ] **Step 1: Write socket security tests**

Test refusal of:

- A pre-existing regular file or symlink at the socket path.
- A peer UID different from the configured installer UID.
- Oversized frames, malformed JSON, and more than eight concurrent clients.
- More than ten requests per second from one connection.

Test that `status`, `cut`, and `restore` reach `HelperEngine` and no other operation exists.

- [ ] **Step 2: Implement Unix peer credential lookup**

Wrap `getpeereid` in:

```swift
public struct UnixPeerCredentials: Equatable, Sendable {
    public let uid: uid_t
    public let gid: gid_t

    public static func read(from descriptor: Int32) throws -> Self
}
```

- [ ] **Step 3: Implement the helper server**

Bind `/var/run/hearthstone-puller/helper.sock` only after creating `/var/run/hearthstone-puller` as `root:wheel` mode `0755`. Chown the socket to the configured UID and set mode `0600`; still verify `getpeereid` for every accepted connection.

Read the allowed UID from `/Library/Application Support/HearthstonePuller/config.plist`, which must be root-owned and not group/world writable.

- [ ] **Step 4: Finish `main.swift`**

Construct real locator, observer, PF controller, and recovery client. Startup order is: validate configuration, flush stale anchor, connect to recovery, start engine, then accept UI clients. SIGTERM requests restore, releases only the owned PF enable token, removes the socket, and exits.

- [ ] **Step 5: Run tests and commit**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter PullerHelperTests
git add Sources/PullerSystem Sources/PullerHelper Tests/PullerHelperTests
git commit -m "feat: secure privileged helper IPC"
```

## Task 11: Build the Non-Activating Floating App

**Files:**
- Modify: `Package.swift`
- Create: `Sources/PullerApp/HelperClient.swift`
- Create: `Sources/PullerApp/PullerButtonView.swift`
- Create: `Sources/PullerApp/FloatingPanelController.swift`
- Create: `Sources/PullerApp/AppDelegate.swift`
- Create: `Sources/PullerApp/main.swift`
- Create: `Tests/PullerAppTests/PanelStateViewModelTests.swift`

- [ ] **Step 1: Write view-model tests before AppKit code**

Add the UI executable and test target to `Package.swift`:

```swift
.executable(name: "HearthstonePuller", targets: ["PullerApp"])

.executableTarget(name: "PullerApp", dependencies: ["PullerCore"]),
.testTarget(name: "PullerAppTests", dependencies: ["PullerApp"])
```

Test exact labels and enabled behavior:

```text
helperUnavailable -> 需要安装, enabled
absent            -> 未检测到炉石, disabled
ready             -> 一键拔线, enabled
cutting           -> 断线中 1.5s, disabled
waitingReconnect  -> 等待重连, disabled
error             -> 服务异常, enabled
```

Test that one click sends one `.cut`, cutting ignores additional clicks, restore sends `.restore`, and a 100-millisecond UI timer only redraws from helper snapshots rather than changing the authoritative state.

- [ ] **Step 2: Implement the helper client and view model**

The client connects to `/var/run/hearthstone-puller/helper.sock`, uses the framed protocol, polls status at 500 milliseconds while Hearthstone is absent and 100 milliseconds while cutting/waiting, and applies a two-second response timeout. Connection failure maps to `.helperUnavailable` or `.error`; it never invokes `sudo` or `pfctl`.

- [ ] **Step 3: Implement the panel**

Create an 88 by 88 point `NSPanel` with:

```swift
panel.styleMask = [.borderless, .nonactivatingPanel]
panel.level = .floating
panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
panel.isOpaque = false
panel.hasShadow = true
panel.hidesOnDeactivate = false
```

Use an 8-point corner radius. Keep font sizes fixed; use two lines where labels require it. A pointer movement threshold of 4 points switches a press into dragging and suppresses the click.

- [ ] **Step 4: Persist and clamp position**

Store the panel origin in `UserDefaults`. On launch, screen parameter change, and display removal, choose the screen containing the largest panel intersection and clamp the complete 88 by 88 frame to `visibleFrame`.

- [ ] **Step 5: Add the context menu and app lifecycle**

The right-click menu shows live helper/Hearthstone status plus `重新检测`, `恢复网络`, `安装或卸载 Helper`, and `退出`. Exit sends restore with a one-second bound, then terminates regardless; independent recovery remains authoritative.

- [ ] **Step 6: Run app tests and commit**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter PullerAppTests
git add Sources/PullerApp Tests/PullerAppTests
git commit -m "feat: add floating one-click puller UI"
```

## Task 12: Add launchd Resources and Safe Installation Scripts

**Files:**
- Create: `Resources/com.yunnn.hearthstone-puller.helper.plist`
- Create: `Resources/com.yunnn.hearthstone-puller.recovery.plist`
- Create: `scripts/install-helper.sh`
- Create: `scripts/uninstall-helper.sh`
- Create: `scripts/verify-installation.sh`
- Create: `Tests/Scripts/install_helper_test.sh`

- [ ] **Step 1: Write shell tests against a temporary fake root**

The script test sets `PULLER_INSTALL_ROOT` to a `mktemp -d` directory and supplies a fake `launchctl`. Verify exact destinations, owner/mode requests, recovery-before-helper bootstrap order, rejection of symlink destinations, and idempotent uninstall. The production script refuses `PULLER_INSTALL_ROOT` unless `PULLER_INSTALL_TESTING=1` is also set.

- [ ] **Step 2: Add launchd plists**

Use labels:

```text
com.yunnn.hearthstone-puller.recovery
com.yunnn.hearthstone-puller.helper
```

Both use fixed `/Library/PrivilegedHelperTools/...` program paths, `RunAtLoad`, `KeepAlive` on abnormal exit, root user/group, `ProcessType=Interactive`, and bounded stdout/stderr log files under `/Library/Logs/HearthstonePuller`. The recovery plist starts first during installation.

- [ ] **Step 3: Implement installation**

The script requires `EUID=0`, resolves its source directory without following untrusted destination symlinks, obtains the active console UID with `stat -f %u /dev/console`, validates it is at least 501, installs root-owned mode `0755` executables and mode `0644` plists/configuration, bootstraps recovery then helper, and calls verification. It never edits `/etc/pf.conf` or downloads content.

- [ ] **Step 4: Implement removal**

Removal sends restore if the helper socket exists, bootouts helper then recovery, directly flushes the hard-coded anchor as a final safeguard, removes only the known installed files, and leaves logs unless `--remove-logs` is explicitly provided.

- [ ] **Step 5: Run shell tests, validate plists, and commit**

```bash
bash Tests/Scripts/install_helper_test.sh
plutil -lint Resources/*.plist
git add Resources scripts Tests/Scripts
git commit -m "feat: add safe helper installation lifecycle"
```

## Task 13: Package a Universal Personal-Use App

**Files:**
- Create: `Resources/AppInfo.plist`
- Create: `scripts/build-release.sh`
- Create: `scripts/package-app.sh`
- Create: `README.md`

- [ ] **Step 1: Add the app metadata**

Set `CFBundleIdentifier` to `com.yunnn.hearthstone-puller`, `CFBundleExecutable` to `HearthstonePuller`, `LSMinimumSystemVersion` to `13.0`, and `LSUIElement` to true. Architecture support is verified from the packaged Mach-O rather than declared in the plist. Do not request Accessibility, Network Extension, App Sandbox exceptions, or other entitlements.

- [ ] **Step 2: Implement universal builds**

`build-release.sh` must run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
swift build -c release --arch arm64 --arch x86_64
```

Then use `lipo -info` to require both architectures in all three executables.

- [ ] **Step 3: Package and ad-hoc sign locally**

`package-app.sh` creates:

```text
build/HearthstonePuller.app/Contents/Info.plist
build/HearthstonePuller.app/Contents/MacOS/HearthstonePuller
build/helper/hearthstone-puller-helper
build/helper/hearthstone-puller-recovery
build/helper/install-helper.sh
build/helper/uninstall-helper.sh
build/helper/*.plist
```

Ad-hoc sign only the local app with `codesign --force --sign -`; verify with `codesign --verify --deep --strict`. Do not claim Gatekeeper or third-party distribution support.

- [ ] **Step 4: Document install, emergency recovery, and limitations**

README must include:

- macOS 13+ and personal-use scope.
- Full Xcode build prerequisite and `DEVELOPER_DIR` command.
- One-time `sudo build/helper/install-helper.sh` installation.
- Manual `sudo pfctl -a com.apple/hearthstone-puller -F all` recovery.
- Exact uninstall command.
- PF state deletion may affect an unrelated connection to the same remote address.
- The tool does not parse payloads and does not disable SIP.
- The game-account/terms-of-service risk of intentional disconnect behavior.

- [ ] **Step 5: Build, inspect, and commit**

```bash
bash scripts/build-release.sh
bash scripts/package-app.sh
lipo -info build/HearthstonePuller.app/Contents/MacOS/HearthstonePuller
codesign --verify --deep --strict build/HearthstonePuller.app
git add Resources/AppInfo.plist scripts README.md
git commit -m "build: package personal-use macOS app"
```

Expected: both architectures are reported and code-sign verification exits zero.

## Task 14: Add Local Network Fixtures and End-to-End Verification

**Files:**
- Create: `Fixtures/EchoServer/main.swift`
- Create: `Fixtures/SocketClient/main.swift`
- Modify: `Package.swift`
- Create: `scripts/integration-test.sh`
- Create: `docs/manual-test-checklist.md`

- [ ] **Step 1: Add deterministic fixtures**

Add executable targets `EchoServer` and `SocketClient`. The server binds an explicitly supplied loopback or LAN test address and echoes monotonically numbered lines. The client sends one line every 50 milliseconds, records acknowledgements, and exits nonzero if a gap exceeds 500 milliseconds.

- [ ] **Step 2: Test orchestration without PF first**

`integration-test.sh --dry-run` starts one server and two clients, verifies both transfer continuously for five seconds, and terminates them through trapped PIDs. It never uses broad `pkill` or an unresolved glob.

- [ ] **Step 3: Add an explicitly gated PF test mode**

`sudo -E PF_INTEGRATION_TEST=1 scripts/integration-test.sh --pf` installs the helper into the test root, configures the target identity abstraction to select only fixture client A, triggers cut, and verifies:

- A observes a disconnect/reconnect window.
- B has no gap over 500 milliseconds.
- The dedicated anchor is empty by T+2.2 seconds.
- Helper termination at T+0.5 still leaves the anchor empty by T+2.2.
- `pfctl -a '*' -sr` before/after differs only during the dedicated anchor window.

Always trap cleanup that flushes the dedicated anchor and terminates only recorded child PIDs.

- [ ] **Step 4: Write the real Hearthstone checklist**

The manual checklist records:

- Hearthstone executable path, signing identifier, Team ID, and observed in-bundle process.
- Active IPv4/IPv6 TCP/UDP endpoints before a cut.
- Whether 1.5 seconds triggers reconnect without leaving the match.
- Browser download, music, chat, and voice continuity.
- Wi-Fi, Ethernet, hotspot, VPN, sleep/wake, game restart, and repeated cut results.
- Any collateral reconnect caused by a shared remote address.

- [ ] **Step 5: Run non-root verification and commit**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
bash scripts/integration-test.sh --dry-run
git diff --check
git add Package.swift Fixtures scripts/integration-test.sh docs/manual-test-checklist.md
git commit -m "test: add end-to-end network fixtures"
```

## Task 15: Final Safety and Acceptance Pass

**Files:**
- Modify only files required by failures found in this task.

- [ ] **Step 1: Run all non-root checks**

```bash
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift test
bash Tests/Scripts/install_helper_test.sh
plutil -lint Resources/*.plist Resources/AppInfo.plist
bash scripts/build-release.sh
bash scripts/package-app.sh
codesign --verify --deep --strict build/HearthstonePuller.app
git diff --check
```

Expected: every command exits zero.

- [ ] **Step 2: Audit privileged strings and paths**

Run:

```bash
rg -n 'Process\(|/sbin/pfctl|/bin/sh|sudo|pf\.conf|com\.apple/hearthstone-puller' Sources scripts Resources
```

Expected: `Process` and `/sbin/pfctl` occur only inside `PFController`; shell scripts contain no download commands and never reload `/etc/pf.conf`; the anchor spelling is identical everywhere.

- [ ] **Step 3: Run opt-in root integration on a disposable network session**

Close sensitive transfers first, then run:

```bash
sudo -E DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  PF_INTEGRATION_TEST=1 bash scripts/integration-test.sh --pf
```

Expected: target A reconnects, control B remains continuous, and `sudo pfctl -a com.apple/hearthstone-puller -sr` is empty afterward.

- [ ] **Step 4: Run the Hearthstone observation checklist before enabling a real cut**

First launch in observation-only mode and record the verified process and endpoints. Confirm Battle.net is excluded. Only then enable `cut`, perform one test in a non-ranked context, and execute the checklist. Stop and flush the anchor immediately if any unrelated application reconnects.

- [ ] **Step 5: Commit fixes and record verification evidence**

Add a dated result section to `docs/manual-test-checklist.md` containing commands, OS version, network type, and observed outcomes. Commit only after the anchor is confirmed empty:

```bash
sudo pfctl -a com.apple/hearthstone-puller -sr
git add -A
git commit -m "test: verify personal-use puller acceptance"
git status --short
```

Expected: PF prints no rules for the anchor and Git reports a clean working tree after the commit.
