# UI, App Icon, And Service Management Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver a readable `144 x 72` floating puller with Helper-authoritative reset/reconnect countdowns, a native app icon, and safe right-click service installation and uninstallation from the packaged app.

**Architecture:** `HelperEngine` owns monotonic phase deadlines and publishes remaining milliseconds through the existing snapshot IPC field. `PanelStateViewModel` converts snapshots into stable one-line or two-line presentation data, while `ServiceManager` validates fixed bundle resources and invokes one privileged script through a fixed AppleScript handler. Packaging creates the icon and embeds a self-contained service directory without changing internal launchd or PF identifiers.

**Tech Stack:** Swift 6.2, Swift Concurrency, AppKit, XCTest, Bash, AppleScript via `/usr/bin/osascript`, `sips`, `iconutil`, ad-hoc `codesign`.

---

## File Structure

- `Sources/PullerHelper/HelperEngine.swift`: owns reset/reconnect deadlines and snapshot remaining-time calculation.
- `Tests/PullerHelperTests/HelperEngineTests.swift`: deterministic monotonic deadline coverage.
- `Sources/PullerApp/HelperClient.swift`: maps snapshots to title/countdown/accessibility presentation.
- `Sources/PullerApp/PullerButtonView.swift`: fixed-size AppKit rendering and pointer feedback.
- `Sources/PullerApp/FloatingPanelController.swift`: exact panel geometry.
- `Tests/PullerAppTests/PanelStateViewModelTests.swift`: formatting, dimensions, and typography behavior.
- `Sources/PullerApp/ServiceManager.swift`: validates bundled scripts and maps bounded process results.
- `Tests/PullerAppTests/ServiceManagerTests.swift`: validates command construction, resource rejection, cancellation, failure, and concurrency without elevation.
- `Sources/PullerApp/AppDelegate.swift`: explicit service menu commands, operation gating, alerts, and status refresh.
- `Resources/AppIcon.svg`: maintainable icon source.
- `Resources/AppInfo.plist`: declares `AppIcon.icns`.
- `scripts/package-app.sh`: generates iconset, embeds service resources, signs and verifies the app.
- `Tests/Scripts/package_app_test.sh`: package-content and icon assertions.
- `README.md`, `docs/manual-test-checklist.md`: new dimensions, in-app service lifecycle, countdown acceptance steps.

### Task 1: Authoritative Helper Countdown

**Files:**
- Modify: `Sources/PullerHelper/HelperEngine.swift`
- Modify: `Tests/PullerHelperTests/HelperEngineTests.swift`

- [ ] **Step 1: Write failing deadline tests**

Add deterministic tests that assert the accepted cut snapshot starts at `10_000`, advances to `7_500`, transitions to reconnect at `15_000`, advances independently, and returns zero after timeout, restore, process disappearance, failure, and shutdown. The primary assertions are:

```swift
XCTAssertEqual(cutting.remainingMilliseconds, 10_000)
fixture.time.advance(by: .milliseconds(2_500))
XCTAssertEqual(status.remainingMilliseconds, 7_500)
XCTAssertEqual(reconnecting.remainingMilliseconds, 15_000)
XCTAssertEqual(finished.remainingMilliseconds, 0)
```

- [ ] **Step 2: Verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter HelperEngineTests
```

Expected: failures report `remainingMilliseconds` is `0` during timed states.

- [ ] **Step 3: Implement monotonic phase deadlines**

Add two optional `Duration` deadlines to `HelperEngine`. Set the reset deadline immediately before entering `.cutting`; clear it only when leaving that phase. Set reconnect deadline after PF and Recovery cleanup succeeds and the machine enters `.waitingForReconnect`. Centralize deadline cleanup for restore, timeout, failure, process change, and shutdown. Build snapshots with clamped whole milliseconds:

```swift
private func remainingMilliseconds(until deadline: Duration?, limit: Duration) -> Int {
    guard let deadline else { return 0 }
    let remaining = max(.zero, min(limit, deadline - time.elapsed))
    let components = remaining.components
    return max(0, Int(components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000))
}
```

Use the active machine state to select the applicable deadline; all non-timed states return zero.

- [ ] **Step 4: Verify GREEN and commit**

Run the Step 2 command, then:

```bash
git add Sources/PullerHelper/HelperEngine.swift Tests/PullerHelperTests/HelperEngineTests.swift
git commit -m "feat: publish reset countdowns"
```

### Task 2: Floating UI And Countdown Presentation

**Files:**
- Modify: `Sources/PullerApp/HelperClient.swift`
- Modify: `Sources/PullerApp/PullerButtonView.swift`
- Modify: `Sources/PullerApp/FloatingPanelController.swift`
- Modify: `Tests/PullerAppTests/PanelStateViewModelTests.swift`

- [ ] **Step 1: Write failing presentation tests**

Test every normal title, exact `等待连接`/`等待重连` titles, ceiling conversion, active-state minimum `1s`, accessibility text, enabled state, `144 x 72` panel size, and font constants:

```swift
viewModel.apply(snapshot(state: .cutting, remainingMilliseconds: 8_001))
XCTAssertEqual(viewModel.title, "等待连接")
XCTAssertEqual(viewModel.countdown, "9s")
XCTAssertEqual(viewModel.accessibilityText, "等待连接 9s")
XCTAssertEqual(FloatingPanelController.panelSize, NSSize(width: 144, height: 72))
XCTAssertEqual(PullerButtonView.titleFontSize, 18)
XCTAssertEqual(PullerButtonView.countdownFontSize, 20)
```

- [ ] **Step 2: Verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter PanelStateViewModelTests
```

Expected: compile/assertion failures for missing countdown presentation and old geometry.

- [ ] **Step 3: Implement presentation and stable layout**

Expose `title`, optional `countdown`, and `accessibilityText` from `PanelStateViewModel`; compute seconds as `max(1, (milliseconds + 999) / 1_000)` only for active states. Replace the single label with a centered vertical stack containing an 18 pt semibold title and 20 pt bold countdown label using tabular digits. Hide the countdown label in normal states without changing the view or panel size. Use a 10 pt corner radius and consistent hover/pressed opacity while preserving drag/click behavior.

- [ ] **Step 4: Verify GREEN and commit**

Run the Step 2 command, then:

```bash
git add Sources/PullerApp/HelperClient.swift Sources/PullerApp/PullerButtonView.swift Sources/PullerApp/FloatingPanelController.swift Tests/PullerAppTests/PanelStateViewModelTests.swift
git commit -m "feat: redesign floating countdown UI"
```

### Task 3: Safe Service Manager

**Files:**
- Create: `Sources/PullerApp/ServiceManager.swift`
- Create: `Tests/PullerAppTests/ServiceManagerTests.swift`

- [ ] **Step 1: Write failing service-operation tests**

Define tests around an injected `ServiceProcessRunning` fake. Cover only the two fixed operations, bundle-contained regular files, missing files, symlink rejection, standardized paths escaping `Contents/Resources/Service`, fixed non-interpolated AppleScript, argv script passing, 16 KiB output truncation, cancellation marker, nonzero exit diagnostics, success, and concurrent rejection:

```swift
let result = await manager.perform(.install)
XCTAssertEqual(runner.invocations.first?.executable.path, "/usr/bin/osascript")
XCTAssertEqual(runner.invocations.first?.arguments.last, installScript.path)
XCTAssertEqual(result, .succeeded(.install))
```

- [ ] **Step 2: Verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ServiceManagerTests
```

Expected: compile failure because `ServiceManager` does not exist.

- [ ] **Step 3: Implement validation and privileged invocation**

Create typed `ServiceOperation` and `ServiceOperationResult` values. Validate `Contents/Resources/Service` and the selected script with `lstat`, reject symbolic links and non-regular files, standardize and resolve symlinks, then require the script path to be a strict descendant of the service directory and service directory to be a strict descendant of the bundle. Use this constant AppleScript and pass the selected path only as argv:

```applescript
on run argv
    try
        do shell script "/bin/bash " & quoted form of (item 1 of argv) with administrator privileges
        return "__PULLER_OK__"
    on error messageText number errorNumber
        if errorNumber is -128 then return "__PULLER_CANCELLED__"
        error messageText number errorNumber
    end try
end run
```

The production runner executes and waits on a detached task, captures bounded stdout/stderr, and the actor rejects a second request while one is active.

- [ ] **Step 4: Verify GREEN and commit**

Run the Step 2 command, then:

```bash
git add Sources/PullerApp/ServiceManager.swift Tests/PullerAppTests/ServiceManagerTests.swift
git commit -m "feat: add privileged service manager"
```

### Task 4: Right-Click Service Workflow

**Files:**
- Modify: `Sources/PullerApp/AppDelegate.swift`
- Modify: `Sources/PullerApp/HelperClient.swift`
- Modify: `Tests/PullerAppTests/PanelStateViewModelTests.swift`

- [ ] **Step 1: Write failing menu and post-operation tests**

Extract a testable menu model/coordinator from `AppDelegate` as needed. Assert exact visible labels `安装服务` and `卸载服务`, both disabled during one operation, cancellation maps to `操作已取消`, install success polls every 100 ms for no more than two seconds, uninstall success immediately applies `.helperUnavailable`, and failure does not overwrite state with a false success.

- [ ] **Step 2: Verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter PullerAppTests
```

Expected: failures show the old single `安装或卸载 Helper` Finder action and missing operation handling.

- [ ] **Step 3: Implement AppDelegate integration**

Replace the Finder action with two selectors. Disable both menu items while `serviceOperationInProgress` is true, await `ServiceManager.perform`, show one concise `NSAlert`, and refresh state according to the typed result. Keep existing redetect, restore, quit, and periodic polling behavior. Make alerts user-visible only and retain all internal Helper identifiers.

- [ ] **Step 4: Verify GREEN and commit**

Run the Step 2 command, then:

```bash
git add Sources/PullerApp/AppDelegate.swift Sources/PullerApp/HelperClient.swift Tests/PullerAppTests/PanelStateViewModelTests.swift
git commit -m "feat: manage service from context menu"
```

### Task 5: App Icon, Bundled Service Package, And Documentation

**Files:**
- Create: `Resources/AppIcon.svg`
- Modify: `Resources/AppInfo.plist`
- Modify: `scripts/package-app.sh`
- Create: `Tests/Scripts/package_app_test.sh`
- Modify: `README.md`
- Modify: `docs/manual-test-checklist.md`

- [ ] **Step 1: Write failing packaging assertions**

Create a non-privileged package test that runs `package-app.sh` and asserts `CFBundleIconFile=AppIcon.icns`, the icon exists and is nonblank, and `Contents/Resources/Service` contains exactly the two executables, two plists, and three service scripts with executable modes where required. Also use `iconutil --convert iconset` and `sips` to assert 16, 32, 128, and 1024 pixel representations are nonblank.

- [ ] **Step 2: Verify RED**

Run:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash Tests/Scripts/package_app_test.sh
```

Expected: failure because the icon and bundled service directory do not exist.

- [ ] **Step 3: Add icon and deterministic packaging**

Create a flat SVG with a dark rounded-square base, red disconnect field, green recovery field, white endpoints, and an amber break/reset mark. In `package-app.sh`, rasterize 16/32/128/256/512 point 1x/2x PNGs with `sips`, compile `AppIcon.icns` with `iconutil`, embed it, and copy the existing scripts under `install-service.sh`, `uninstall-service.sh`, and `verify-installation.sh`. Continue creating the standalone `build/helper` directory with its existing names. Sign only after all resources are embedded.

- [ ] **Step 4: Update user documentation**

Document the `144 x 72` UI, both visible countdowns, right-click install/uninstall with one macOS authorization prompt, standalone terminal recovery path, and a manual checklist for real authorization, Finder/Dock icon, dragging, countdown, install, and uninstall. Keep the PF/ToS limitations unchanged.

- [ ] **Step 5: Verify GREEN and commit**

Run the Step 2 command, then:

```bash
git add Resources/AppIcon.svg Resources/AppInfo.plist scripts/package-app.sh Tests/Scripts/package_app_test.sh README.md docs/manual-test-checklist.md
git commit -m "feat: package app icon and service resources"
```

### Task 6: Full Regression Verification

**Files:**
- Modify only if verification exposes a tested regression.

- [ ] **Step 1: Run the complete safe verification matrix**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
bash Tests/Scripts/install_helper_test.sh
bash scripts/integration-test.sh --dry-run
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash scripts/build-release.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash scripts/package-app.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash Tests/Scripts/package_app_test.sh
codesign --verify --deep --strict build/HearthstonePuller.app
lipo -info build/HearthstonePuller.app/Contents/MacOS/HearthstonePuller
lipo -info build/helper/hearthstone-puller-helper
lipo -info build/helper/hearthstone-puller-recovery
```

Expected: all commands exit zero; Swift reports zero failures with only explicitly gated skips; all three binaries contain `arm64` and `x86_64`.

- [ ] **Step 2: Verify PF rule syntax without loading it**

Generate the existing exact TCP `3724` fixture rules and run `/sbin/pfctl -n` against them through the established non-mutating test path. Do not run live PF integration, `sudo`, installation, uninstallation, or a real game cut.

- [ ] **Step 3: Review requirements and working tree**

Re-read `docs/superpowers/specs/2026-07-28-ui-icon-and-service-management-design.md`, inspect `git diff`/`git status`, and confirm every approved requirement has implementation and test evidence. Leave `dev` checked out and do not merge, push, or perform real service operations.
