# One-Shot Game Connection Reset Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the fixed-duration Hearthstone network block with a one-shot reset of only the verified TCP `3724` game tuples captured at click time.

**Architecture:** Introduce a pure game-connection selector, render PF rules for exact local and remote ports, and make the helper finish when the captured tuples disappear. Replacement tuples are observed only as evidence of reconnection and are never added to active PF rules; the existing recovery daemon remains the two-second fail-open bound.

**Tech Stack:** Swift 6, XCTest, AppKit, macOS PF, Bash packaging scripts.

---

### Task 1: Select Only Supported Game Connections

**Files:**
- Create: `Sources/PullerSystem/HearthstoneGameConnectionSelector.swift`
- Create: `Tests/PullerSystemTests/HearthstoneGameConnectionSelectorTests.swift`

- [x] **Step 1: Write the failing selector tests**

Test that only non-loopback TCP sockets whose remote port is `3724` are returned, while TCP `443`, TCP `1119`, and UDP `3724` are rejected. Test deterministic deduplication and ordering.

- [x] **Step 2: Run the selector tests to verify RED**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter HearthstoneGameConnectionSelectorTests
```

Expected: compilation fails because `HearthstoneGameConnectionSelector` does not exist.

- [x] **Step 3: Implement the pure selector**

Add a stateless API:

```swift
public enum HearthstoneGameConnectionSelector {
    public static func select(from sockets: [ObservedSocket]) -> [ObservedSocket]
}
```

Filter to `.tcp` and remote port `3_724`, then deduplicate and sort by the full tuple.

- [x] **Step 4: Run the selector tests to verify GREEN**

Run the Step 2 command. Expected: all selector tests pass.

### Task 2: Bind PF Rules To Captured Tuples

**Files:**
- Modify: `Tests/PullerSystemTests/PFRuleRendererTests.swift`
- Modify: `Sources/PullerSystem/PFRuleRenderer.swift`

- [x] **Step 1: Change expected PF rules first**

Require outbound and inbound rules to include both the local ephemeral port and remote port:

```pf
block return out quick inet proto tcp from 192.0.2.10 port = 50123 to 198.51.100.20 port = 3724
block return in quick inet proto tcp from 198.51.100.20 port = 3724 to 192.0.2.10 port = 50123
```

- [x] **Step 2: Run PF renderer tests to verify RED**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter PFRuleRendererTests
```

Expected: exact rule assertions fail because local ports are absent.

- [x] **Step 3: Render exact forward and reverse tuples**

Update `PFRuleRenderer.ruleLines(for:)` to constrain `socket.localPort` in both directions without changing the dedicated anchor or broad-address state-removal limitation.

- [x] **Step 4: Run PF renderer tests to verify GREEN**

Run the Step 2 command. Expected: all PF renderer tests pass.

### Task 3: Remove Fixed Duration From State Semantics

**Files:**
- Modify: `Tests/PullerCoreTests/InterruptionStateMachineTests.swift`
- Modify: `Sources/PullerCore/InterruptionStateMachine.swift`
- Modify: `Tests/PullerAppTests/PanelStateViewModelTests.swift`
- Modify: `Sources/PullerApp/HelperClient.swift`

- [x] **Step 1: Write event-driven state tests**

Require `beginCut()` to enter `CUTTING` with zero remaining milliseconds, reject a second call, and require `resetCompleted()` to enter `WAITING_RECONNECT`. Require labels `未检测到对局` and `拔线中`.

- [x] **Step 2: Run core and app tests to verify RED**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'InterruptionStateMachineTests|PanelStateViewModelTests'
```

Expected: compilation or assertions fail because the old deadline API and labels remain.

- [x] **Step 3: Implement event-driven state APIs**

Remove `cutDuration` and the state-machine deadline. Replace `beginCut(now:)` with `beginCut()`, add `resetCompleted()`, and keep the IPC `remainingMilliseconds` field at zero for compatibility.

- [x] **Step 4: Run core and app tests to verify GREEN**

Run the Step 2 command. Expected: all selected tests pass.

### Task 4: Reset Captured Tuples Without Chasing Reconnects

**Files:**
- Modify: `Tests/PullerHelperTests/HelperEngineTests.swift`
- Modify: `Sources/PullerHelper/HelperEngine.swift`

- [x] **Step 1: Write failing helper behavior tests**

Require the helper to:

- Reject a cut when only TCP `443` or `1119` is observed.
- Install and kill state once for captured TCP `3724` tuples.
- Flush immediately when the captured tuples disappear.
- Never replace rules or kill state for a newly observed replacement tuple.
- Fail open and report an error if captured tuples remain until the two-second bound.
- Keep repeated clicks non-extendable.

- [x] **Step 2: Run helper tests to verify RED**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter HelperEngineTests
```

Expected: new assertions fail because the helper currently selects every socket and accumulates replacements.

- [x] **Step 3: Implement the one-shot reset loop**

Use `HearthstoneGameConnectionSelector` both for readiness and click-time capture. Arm recovery for two seconds, install exact rules once, and retain the immutable captured tuple set. Poll until the captured set has no intersection with current selected tuples, then immediately flush the anchor, disarm recovery, and call `resetCompleted()`. At the safety deadline, fail open and report an unconfirmed reset.

- [x] **Step 4: Run helper tests to verify GREEN**

Run the Step 2 command. Expected: all helper tests pass.

### Task 5: Synchronize Documentation And Verify The Package

**Files:**
- Modify: `README.md`
- Modify: `docs/manual-test-checklist.md`
- Modify: `docs/superpowers/specs/2026-07-28-hearthstone-puller-design.md`
- Modify: `docs/superpowers/plans/2026-07-28-one-shot-connection-reset.md`

- [x] **Step 1: Remove fixed-duration product claims**

Document TCP `3724` selection, exact captured-tuple reset, immediate replacement-flow allowance, `拔线中`, `未检测到对局`, and the two-second recovery-only boundary.

- [x] **Step 2: Run full verification**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
bash Tests/Scripts/install_helper_test.sh
bash scripts/integration-test.sh --dry-run
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash scripts/build-release.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash scripts/package-app.sh
codesign --verify --deep --strict --verbose=4 build/HearthstonePuller.app
git diff --check
```

Expected: all non-privileged tests pass, only explicitly gated live/root tests skip, all three binaries are universal, and the packaged App satisfies its designated requirement.

- [x] **Step 3: Commit the implementation**

```bash
git add README.md Sources Tests docs/manual-test-checklist.md docs/superpowers
git commit -m "fix: reset only the active Hearthstone game flow"
```

Do not add `.vscode/`, do not merge, and do not push.
