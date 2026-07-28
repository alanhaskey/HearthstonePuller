# Reset Attempt And Reconnect Timeouts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Distinguish a quiet, untriggered Hearthstone connection from technical failure, allow explicit retry for 10 seconds, and stop waiting for a replacement connection after 15 seconds.

**Architecture:** `PullerCore` owns state transitions and actionability, while `HelperEngine` owns exact socket-tuple identity and both monotonic deadlines. The existing reset task continues into the reconnect phase so the observation loop cannot race it; the independent recovery daemon remains a fail-open PF cleanup guard.

**Tech Stack:** Swift 6.2, Swift Concurrency actors/tasks, XCTest, macOS PF through the existing controller, AppKit.

---

### Task 1: Add The Retryable Outcome To Core And UI

**Files:**
- Modify: `Sources/PullerCore/PullerState.swift`
- Modify: `Sources/PullerCore/InterruptionStateMachine.swift`
- Modify: `Sources/PullerApp/HelperClient.swift`
- Modify: `Sources/PullerApp/PullerButtonView.swift`
- Test: `Tests/PullerCoreTests/PullerStateTests.swift`
- Test: `Tests/PullerCoreTests/InterruptionStateMachineTests.swift`
- Test: `Tests/PullerAppTests/PanelStateViewModelTests.swift`

- [ ] **Step 1: Write failing core and UI tests**

Add assertions that `notTriggered` is actionable, `markNotTriggered()` moves an active attempt into that state, ordinary count observation preserves it, a retry re-enters `cutting`, and the UI maps it to enabled label `未触发`. Change the expected cutting label to `等待连接活动` and assert that clicking `notTriggered` sends exactly one `.cut` request.

```swift
XCTAssertTrue(PullerState.notTriggered.isActionable)

machine.markNotTriggered()
XCTAssertEqual(machine.snapshot().state, .notTriggered)
machine.observe(connectionCount: 1)
XCTAssertEqual(machine.snapshot().state, .notTriggered)
try machine.beginCut()
XCTAssertEqual(machine.snapshot().state, .cutting)

(.cutting, "等待连接活动", false),
(.notTriggered, "未触发", true),
```

- [ ] **Step 2: Run focused tests and verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'PullerStateTests|InterruptionStateMachineTests|PanelStateViewModelTests'
```

Expected: compilation fails because `PullerState.notTriggered` and `markNotTriggered()` do not exist.

- [ ] **Step 3: Implement the minimal state and UI behavior**

Add `case notTriggered`, make `.ready` and `.notTriggered` actionable, preserve `notTriggered` in `observe`, accept `beginCut` from both actionable states, and add a guarded reconnect-timeout transition.

```swift
public enum PullerState: String, Codable, Sendable, Equatable {
    case helperUnavailable, absent, ready, cutting, notTriggered, waitingForReconnect, error

    public var isActionable: Bool {
        self == .ready || self == .notTriggered
    }
}

public mutating func markNotTriggered() {
    guard state == .cutting else { return }
    state = .notTriggered
    message = nil
}

public mutating func reconnectTimedOut() {
    guard state == .waitingForReconnect else { return }
    markAbsent()
}
```

Map `.cutting` to `等待连接活动`, `.notTriggered` to `未触发`, and make the view model send `.cut` from either actionable state. Give `notTriggered` a distinct button color using the existing restrained palette.

- [ ] **Step 4: Run focused tests and verify GREEN**

Run the Step 2 command. Expected: all selected tests pass.

- [ ] **Step 5: Commit the core and UI state change**

```bash
git add Sources/PullerCore Sources/PullerApp Tests/PullerCoreTests Tests/PullerAppTests
git commit -m "feat: expose retryable reset outcome"
```

### Task 2: Implement The 10-Second Reset Outcome And 15-Second Reconnect Bound

**Files:**
- Modify: `Sources/PullerHelper/HelperEngine.swift`
- Modify: `Tests/PullerHelperTests/HelperEngineTests.swift`

- [ ] **Step 1: Write failing helper orchestration tests**

Extend the manual helper clock so tests can await scheduled sleeps and advance monotonic time deterministically. Add tests for these observable behaviors:

```swift
XCTAssertEqual(HelperEngine.resetAttemptLimit, .seconds(10))
XCTAssertEqual(HelperEngine.reconnectLimit, .seconds(15))
XCTAssertEqual(armedDeadline, Date(timeIntervalSince1970: 1_010))

// Original remains through reset deadline.
XCTAssertEqual(snapshot.state, .notTriggered)
XCTAssertNil(snapshot.message)

// A retry recaptures current tuples and arms recovery a second time.
XCTAssertEqual(await fixture.recovery.armCount(), 2)

// Replacement appears before reconnect deadline.
XCTAssertEqual(snapshot.state, .ready)

// No replacement appears by reconnect deadline.
XCTAssertEqual(snapshot.state, .absent)
```

Also test tuple-aware persistence: `notTriggered` remains while any timed-out captured tuple is still present, then becomes `ready` for a different tuple or `absent` for no tuple. Add a throwing socket fixture and assert observation errors produce `.error` rather than being converted to zero connections.

- [ ] **Step 2: Run helper tests and verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter HelperEngineTests
```

Expected: failures show the old two-second constants, timeout state `.error`, no reconnect deadline, and no tuple-aware `notTriggered` behavior.

- [ ] **Step 3: Implement one authoritative two-phase task**

Set the reset and recovery request to 10 seconds and the reconnect limit to 15 seconds:

```swift
public static let recoveryDelay: TimeInterval = 10.0
public static let resetAttemptLimit = Duration.seconds(10)
public static let reconnectLimit = Duration.seconds(15)
```

Retain the timed-out tuple set in the helper. At reset timeout, perform checked cleanup before publishing the normal outcome:

```swift
private func completeUntriggeredReset(capturedTargets: Set<ObservedSocket>) async throws {
    try await pf.flushAnchor()
    try await recovery.flushNow()
    notTriggeredTargets = capturedTargets
    machine.markNotTriggered()
    cutTask = nil
}
```

When captured tuples disappear, clear PF and recovery immediately, enter `waitingForReconnect`, then continue the same task with a fresh monotonic 15-second deadline. Observe only qualifying TCP `3724` tuples; transition to `ready` as soon as one appears, or call `reconnectTimedOut()` at the deadline.

```swift
private func runReconnectWait(process: VerifiedProcess, startedAt: Duration) async throws {
    let deadline = startedAt + Self.reconnectLimit
    while time.elapsed < deadline {
        try await time.sleep(for: min(Self.idlePollInterval, deadline - time.elapsed))
        let targets = try currentGameConnections(for: process)
        if !targets.isEmpty {
            machine.restore(connectionCount: targets.count)
            cutTask = nil
            return
        }
    }
    machine.reconnectTimedOut()
    cutTask = nil
}
```

Make socket enumeration throwing rather than silently returning zero. Skip ordinary observation while either active phase owns state. In `notTriggered`, preserve the state while a timed-out captured tuple remains; after all such tuples disappear, clear the retained set and restore to `ready` for different tuples or `absent` for none. A retry always recaptures tuples and clears retained timeout identity only once the new attempt is accepted.

- [ ] **Step 4: Run helper tests and verify GREEN**

Run the Step 2 command. Expected: all `HelperEngineTests` pass with deterministic 10-second and 15-second transitions.

- [ ] **Step 5: Run the core/app/helper test subset**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'PullerStateTests|InterruptionStateMachineTests|PanelStateViewModelTests|HelperEngineTests'
```

Expected: all selected tests pass.

- [ ] **Step 6: Commit helper orchestration**

```bash
git add Sources/PullerHelper/HelperEngine.swift Tests/PullerHelperTests/HelperEngineTests.swift
git commit -m "fix: bound reset and reconnect waits"
```

### Task 3: Extend The Independent Recovery Guard

**Files:**
- Modify: `Sources/PullerRecovery/RecoveryEngine.swift`
- Modify: `Tests/PullerRecoveryTests/RecoveryEngineTests.swift`

- [ ] **Step 1: Write the failing recovery deadline test**

Change the deadline-clamp test to require that the recovery daemon accepts the helper's 10-second request while retaining the minimum bound and non-extension rule.

```swift
let latest = try await late.arm(deadline: epoch.addingTimeInterval(20))
XCTAssertEqual(latest.timeIntervalSince(epoch), 10.5, accuracy: 0.001)

let requested = epoch.addingTimeInterval(10)
XCTAssertEqual(try await engine.arm(deadline: requested), requested)
```

- [ ] **Step 2: Run recovery tests and verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter RecoveryEngineTests
```

Expected: the maximum-delay assertion fails because the current cap is 2.5 seconds.

- [ ] **Step 3: Raise only the recovery acceptance cap**

```swift
public static let maximumDelay: TimeInterval = 10.5
```

The helper still requests exactly 10 seconds. The extra half-second only tolerates IPC/scheduling skew and is not used as the normal reset deadline.

- [ ] **Step 4: Run recovery tests and verify GREEN**

Run the Step 2 command. Expected: all `RecoveryEngineTests` pass, including monotonic firing, wake handling, and refusal to extend an earlier deadline.

- [ ] **Step 5: Commit the recovery bound**

```bash
git add Sources/PullerRecovery/RecoveryEngine.swift Tests/PullerRecoveryTests/RecoveryEngineTests.swift
git commit -m "fix: extend reset recovery guard"
```

### Task 4: Update Operator Documentation And Verify The Package

**Files:**
- Modify: `README.md`
- Modify: `docs/manual-test-checklist.md`

- [ ] **Step 1: Update user-visible behavior and manual checks**

Document `等待连接活动`, retryable `未触发` after 10 seconds, `等待重连`, and `未检测到对局` after 15 seconds. Replace the obsolete T+2.2 anchor check with event-driven immediate cleanup plus a T+10.5 fail-open check. Add manual cases for quiet traffic, explicit retry, match-end/no-replacement, and true service failure.

- [ ] **Step 2: Run the complete non-privileged verification suite**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
bash Tests/Scripts/install_helper_test.sh
bash scripts/integration-test.sh --dry-run
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash scripts/build-release.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash scripts/package-app.sh
codesign --verify --deep --strict build/HearthstonePuller.app
lipo -info build/HearthstonePuller.app/Contents/MacOS/HearthstonePuller
lipo -info build/helper/hearthstone-puller-helper
lipo -info build/helper/hearthstone-puller-recovery
```

Expected: Swift tests have zero failures with only explicitly gated skips; fake-root installation and dry run pass; all three binaries contain `arm64` and `x86_64`; strict signature verification succeeds.

- [ ] **Step 3: Validate generated PF syntax without changing live PF**

Use the existing dry-run/parser path only. Do not enable `PF_INTEGRATION_TEST`, run `sudo`, install daemons, or issue a real cut. Expected: exact local/remote TCP `3724` rules parse successfully and no `443`, `1119`, or UDP rules are generated.

- [ ] **Step 4: Commit documentation**

```bash
git add README.md docs/manual-test-checklist.md
git commit -m "docs: explain reset outcome timeouts"
```

- [ ] **Step 5: Inspect final diff and installation handoff**

```bash
git status --short --branch
git log -6 --oneline
```

Expected: the `dev` worktree contains no unintended changes. Report that live validation still requires the user to reinstall the newly packaged helper and reopen the app.

