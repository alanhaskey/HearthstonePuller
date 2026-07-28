# UI, App Icon, And Service Management Design

Date: 2026-07-28

## 1. Purpose

Improve the daily-use surface of HearthstonePuller without changing its network targeting or privilege boundaries. The work has four outcomes:

1. Replace the square floating control with a wider, more readable control.
2. Show authoritative remaining time during both reset phases.
3. Add a recognizable macOS app icon.
4. Replace the Finder-based Helper installation handoff with explicit in-app service installation and uninstallation commands.

The internal Helper and Recovery process names, launchd labels, IPC contracts, PF anchor, and TCP `3724` selection remain unchanged.

## 2. Floating Control

The floating panel changes from `88 × 88 pt` to `144 × 72 pt`, a width-to-height ratio of `2:1`. It remains borderless, non-activating, always visible, movable by dragging, available across Spaces and full-screen apps, and clamped to the visible screen after restoring its saved origin.

Visual properties:

- Corner radius: `10 pt`.
- Normal label: 18 pt semibold system font.
- Countdown title: 18 pt semibold system font.
- Countdown value: 20 pt bold system font with tabular digits.
- Countdown layout: two centered lines.
- Existing state color meanings remain, but border, shadow, disabled opacity, hover, and pressed feedback are made consistent.
- Text uses zero letter spacing and must fit without truncation or resizing the panel.

The normal labels remain:

| State | Label |
| --- | --- |
| `helperUnavailable` | `需要安装` |
| `absent` | `未检测到对局` |
| `ready` | `一键拔线` |
| `notTriggered` | `未触发` |
| `error` | `服务异常` |

The timed states use two lines:

```text
等待连接
10s
```

```text
等待重连
15s
```

## 3. Authoritative Countdown

The existing `PullerSnapshot.remainingMilliseconds` field becomes authoritative instead of always returning zero.

The Helper already owns both monotonic deadlines and therefore owns the remaining-time calculation:

- In `cutting`, report the remaining time until the 10-second reset-attempt deadline.
- In `waitingForReconnect`, report the remaining time until the 15-second reconnect deadline.
- In every other state, report zero.

The Helper clamps remaining milliseconds to the applicable phase duration and clears the associated deadline on every success, timeout, failure, restore, process change, and shutdown path. The reconnect deadline starts only after the original tuple has disappeared and PF/recovery cleanup has succeeded.

The App does not run an independent countdown. It continues polling authoritative Helper snapshots every 100 milliseconds during timed states. It converts milliseconds to display seconds using ceiling division. An active phase displays at least `1s`, so scheduling at the exact deadline cannot flash `0s` before the state transition is observed.

The visible sequences are therefore:

```text
等待连接 10s -> ... -> 等待连接 1s -> 未触发
```

or, when reset succeeds:

```text
等待连接 Ns -> 等待重连 15s -> ... -> 一键拔线
```

If no replacement appears:

```text
等待重连 1s -> 未检测到对局
```

## 4. User-Facing Service Language

All user-visible references to Helper become `服务`. Internal names stay unchanged to avoid migration and launchd compatibility risk.

Examples:

- `服务异常` remains the technical-failure label.
- The context menu uses `安装服务` and `卸载服务`.
- Alerts say `服务安装成功`, `服务卸载成功`, `操作已取消`, or a concise service-operation failure.
- Developer documentation may still use Helper when referring to the internal executable or Swift module.

## 5. Bundled Service Package

The app bundle contains a self-sufficient service package at:

```text
HearthstonePuller.app/Contents/Resources/Service/
```

It contains:

- `hearthstone-puller-helper`
- `hearthstone-puller-recovery`
- `com.yunnn.hearthstone-puller.helper.plist`
- `com.yunnn.hearthstone-puller.recovery.plist`
- `install-service.sh`
- `uninstall-service.sh`
- `verify-installation.sh`

Packaging copies the existing root-only installer and uninstaller implementations under the service-oriented filenames above. There is one installation implementation to maintain. The standalone `build/helper/` package remains available for terminal-based recovery and development.

This makes installation independent of the repository path and remains valid if the user moves the `.app` before installing.

## 6. Installation And Uninstallation Flow

The context menu always exposes two explicit commands:

```text
安装服务
卸载服务
```

Selecting either command performs this flow:

1. Resolve the fixed script URL from `Bundle.main`.
2. Verify the service directory and script resolve inside the app bundle and are not symbolic links.
3. Disable both service commands while an operation is in progress.
4. Launch `/usr/bin/osascript` with a fixed AppleScript handler and pass the script path as an argument.
5. AppleScript runs `/bin/bash` on the quoted path using `with administrator privileges`.
6. macOS presents its administrator password or Touch ID authorization UI.
7. Capture at most 16 KiB each of stdout and stderr and wait off the main actor.
8. Return to the main actor, show the result, and refresh service status.

The AppleScript source contains no interpolated user data. The script path is passed through `argv` and shell-quoted by AppleScript's `quoted form of`. No arbitrary command, environment variable, or user-supplied argument is accepted.

The App itself continues running as the logged-in user. Only the fixed install or uninstall script runs with temporary administrator privileges.

## 7. Service Operation Results

- Successful install: show `服务安装成功`, then poll status every 100 milliseconds for at most two seconds so launchd socket startup can settle.
- Successful uninstall: show `服务卸载成功` and immediately set the UI to `需要安装`.
- Authorization cancelled: the fixed AppleScript handler catches error number `-128` and returns a private cancellation marker; show `操作已取消` and do not map it to `服务异常`.
- Missing or unsafe bundled script: refuse elevation and report that the app package is incomplete.
- Nonzero script exit: show a concise failure plus bounded diagnostic output.
- Repeated menu selection while an operation is active: both menu items are disabled, and `ServiceManager` independently rejects a concurrent programmatic request; never launch concurrent privileged scripts.
- Uninstall continues to request network restore and flush only this tool's PF anchor before removing service files.

The operation result is not sent through the Helper IPC channel because install and uninstall must also work while the Helper is absent.

## 8. App Icon

The selected direction is `断开 / 恢复`:

- Dark macOS rounded-square base.
- Red left field for disconnect.
- Green right field for recovery.
- White connection endpoints in the center.
- Small amber break/reset mark between the endpoints.
- Flat fills, no gradient, no text, no Hearthstone or Blizzard marks.
- Simplified geometry and generous padding for recognition at 16 px and 32 px.

The maintainable source is `Resources/AppIcon.svg`. Packaging uses macOS-native `sips` to rasterize all required iconset sizes and `iconutil` to create `AppIcon.icns`. `Resources/AppInfo.plist` declares `CFBundleIconFile`, and the packaging script copies the resulting icon into `Contents/Resources` before signing.

Required iconset representations are 16, 32, 128, 256, and 512 points at 1x and 2x where applicable. The 1024 px representation is the 512-point 2x source.

## 9. Components And Boundaries

- `InterruptionStateMachine`: state transitions only; it does not own clocks.
- `HelperEngine`: monotonic phase deadlines and authoritative remaining milliseconds.
- `PanelStateViewModel`: state-to-text formatting and millisecond-to-second display conversion.
- `PullerButtonView`: stable two-line/one-line presentation, pointer feedback, and accessibility text.
- `FloatingPanelController`: `144 × 72 pt` window geometry and screen clamping.
- `ServiceManager`: bundle validation, privileged script invocation, bounded output, and typed results.
- `AppDelegate`: menu construction, operation-in-progress gating, alerts, and post-operation refresh.
- Packaging scripts: service-resource embedding and deterministic `.icns` generation.

`ServiceManager` depends on an injected process-running interface so command construction and outcomes can be tested without showing an authorization dialog or running privileged commands.

## 10. Testing And Verification

Automated tests must prove:

- Panel size is exactly `144 × 72 pt`.
- Normal text uses 18 pt and countdown values use 20 pt tabular digits.
- Exact state labels and two-line countdown titles are correct.
- Reset and reconnect snapshots expose decreasing remaining milliseconds from their own monotonic deadlines.
- Remaining time is clamped and cleared on every exit path.
- UI seconds use ceiling division and never display `0s` in an active state.
- IPC JSON round-trips nonzero `remainingMilliseconds`.
- Service menu labels use `服务`, not Helper.
- Install and uninstall use only fixed scripts inside `Contents/Resources/Service`.
- Symlinked, missing, or outside-bundle scripts are rejected before elevation.
- Authorization cancellation, nonzero exit, success, and concurrent-request rejection map to distinct UI outcomes.
- The package contains the complete service directory and `AppIcon.icns`.
- The plist declares the icon and the signed app passes strict verification.
- Rendered 16, 32, 128, and 1024 px icon previews remain legible and nonblank.

The full Swift suite, fake-root installer lifecycle, network dry run, universal Intel/Apple Silicon build, and PF syntax checks must continue to pass. Automated verification must not invoke `sudo`, install real launch daemons, mutate live PF, or trigger a real game reset.

Final manual acceptance covers the real macOS authorization prompt, install, uninstall, floating panel appearance, dragging, right-click commands, both countdowns, and Finder/Dock icon rendering.

## 11. Alternatives Considered

### Keep A Square Control

Rejected because the current 88-point square wastes vertical space and forces status text to remain small. The selected `144 × 72` control provides a larger type scale while remaining a compact floating tool.

### Single-Line Countdown

Rejected because `等待连接活动...10s` requires approximately 15 pt or truncation inside the selected width. The two-line design retains the requested larger type and uses the shorter approved title `等待连接`.

### Open Finder Or Terminal For Installation

Rejected because it leaves the user to locate and run commands manually. It does not satisfy direct right-click installation.

### Permanent Privileged Installer Component

Rejected because it adds another privileged lifecycle and signing surface only to install the existing services. Temporary macOS authorization around a fixed bundled script is smaller and sufficient for personal use.

### Rename Internal Helper Identifiers

Rejected because it provides no user-visible benefit and creates upgrade, uninstall, IPC, and launchd migration risk. Only visible language changes.
