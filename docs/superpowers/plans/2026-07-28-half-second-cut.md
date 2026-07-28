# Half-Second Cut Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce the fixed, non-extendable Hearthstone PF interruption window from 1.5 seconds to 0.5 seconds while retaining the independent 2.0-second recovery deadline.

**Architecture:** Keep the existing state machine and helper orchestration. Change the single authoritative cut duration to 500 milliseconds, update user-visible text and assertions, and leave `HelperEngine.recoveryDelay` unchanged at 2.0 seconds.

**Tech Stack:** Swift 6, XCTest, AppKit, macOS PF, Bash packaging scripts.

---

### Task 1: Specify The Half-Second Contract

**Files:**
- Modify: `Tests/PullerCoreTests/InterruptionStateMachineTests.swift`
- Modify: `Tests/PullerHelperTests/HelperEngineTests.swift`
- Modify: `Tests/PullerAppTests/PanelStateViewModelTests.swift`

- [x] **Step 1: Change deadline assertions to 500 milliseconds**

Require the state machine and helper snapshots to report `500`, transition at `.milliseconds(500)`, and continue rejecting a second cut without extending the deadline. Require the cutting label to equal `断线中 0.5s`.

- [x] **Step 2: Run tests to verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter 'InterruptionStateMachineTests|HelperEngineTests|PanelStateViewModelTests'
```

Expected: failures showing actual `1_500` and `断线中 1.5s`.

### Task 2: Implement The Fixed Window

**Files:**
- Modify: `Sources/PullerCore/InterruptionStateMachine.swift`
- Modify: `Sources/PullerApp/HelperClient.swift`

- [x] **Step 1: Change the authoritative duration and label**

Set:

```swift
public static let cutDuration = Duration.milliseconds(500)
```

and map `.cutting` to `断线中 0.5s`. Do not change `HelperEngine.recoveryDelay`.

- [x] **Step 2: Run targeted tests to verify GREEN**

Run the Task 1 command. Expected: all selected tests pass.

### Task 3: Synchronize Documentation And Package

**Files:**
- Modify: `README.md`
- Modify: `docs/manual-test-checklist.md`
- Modify: `docs/superpowers/specs/2026-07-28-hearthstone-puller-design.md`

- [x] **Step 1: Replace normal-path 1.5-second references with 0.5 seconds**

Keep every recovery reference at 2.0 seconds and describe the split explicitly.

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

Expected: 0 test failures, script checks pass, universal build succeeds, and the packaged App satisfies its designated requirement.

- [x] **Step 3: Commit**

```bash
git add Sources Tests README.md docs
git commit -m "fix: shorten Hearthstone cut window"
```
