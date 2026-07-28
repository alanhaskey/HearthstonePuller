# HearthstonePuller for macOS

[中文](#中文) | [English](#english)

## 中文

HearthstonePuller 是一个供个人使用的 macOS 炉石传说连接重置工具。它提供始终置顶的悬浮按钮，通过独立 PF anchor 重置当前已验证炉石进程的 TCP `3724` 对局连接，使游戏自行进入重连流程。

它不是通用断网工具：不关闭整机网络、不影响无关端口、不解析或修改网络内容，也不使用 Network Extension。PF 规则只匹配点击瞬间捕获的原连接元组；游戏使用新本地端口重连时不会继续被该规则阻断。

### 功能

- 原生 macOS App，提供 144 x 72 始终置顶悬浮按钮。
- 只接受本机 `Hearthstone.app` 中通过代码签名验证的进程及其 TCP `3724` 连接。
- UI 始终以普通用户运行；最小权限 Helper 和独立 Recovery 服务负责 PF 操作与超时恢复。
- 右键菜单按实际安装状态只显示“安装服务”或“卸载服务”，每次打开菜单都会重新检测。
- 显示等待连接和等待重连的剩余时间，并提供重新检测、恢复网络和关于信息。
- 支持 Apple Silicon 与 Intel 的 Universal Binary。

### 要求与边界

- macOS 13 或更高版本。
- 完整 Xcode，默认路径为 `/Applications/Xcode.app`。
- 安装或卸载服务时需要本机管理员授权。
- 不需要付费 Apple Developer 账号，不关闭 SIP；App 使用 ad-hoc 签名，适合本机构建和个人使用，不承诺 Gatekeeper 或第三方分发体验。
- 不修改或重载 `/etc/pf.conf`，不清空根 PF ruleset，也不操作其他 PF anchor。

### 构建与打包

```bash
git clone https://github.com/alanhaskey/HearthstonePuller.git
cd HearthstonePuller
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash scripts/build-release.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash scripts/package-app.sh
```

产物位于：

```text
build/HearthstonePuller.app
build/helper/
```

启动 App：

```bash
open build/HearthstonePuller.app
```

### 服务安装流程

首次启动后，右键悬浮按钮并选择“安装服务”，再在 macOS 系统窗口中完成一次管理员授权。App 显示安装成功后即可启动或切回炉石传说。

每次打开右键菜单时，App 都会检查两个可执行文件、两个 LaunchDaemon plist 和服务配置文件。五项均为安全的普通文件且两个二进制可执行时，只显示“卸载服务”；缺失、安装不完整或存在符号链接等不安全状态时，只显示“安装服务”。操作执行期间，该菜单项暂时禁用。

App 包含完整安装资源，移动 `.app` 后不依赖仓库路径或 `build/helper/`。按钮显示“需要安装”代表 Helper 不可用；显示“服务异常”代表请求失败，它与磁盘上的安装状态不是同一概念。

### 使用与倒计时

按钮显示“未检测到对局”时不会执行连接重置。检测到目标连接后显示“一键拔线”。TCP `443`、TCP `1119` 和 UDP 连接不会使按钮进入可用状态。

点击后显示“等待连接”和最多 `10s` 的剩余时间。PF 规则等待点击时捕获的原连接再次发包，并在原连接消失后立即清除；因此 `10s` 是重置尝试上限，不是固定断线时间。若原连接一直安静且未消失，按钮显示可再次点击的“未触发”。

原连接成功重置后显示“等待重连”和最多 `15s` 的剩余时间。检测到新的 TCP `3724` 连接后恢复为“一键拔线”；若对局已经结束或超时仍未出现新连接，则回到“未检测到对局”。倒计时使用 Helper 的权威状态，活动状态最少显示 `1s`，不会闪出 `0s`。

### 恢复与卸载

正常情况下 Helper 会立即清除专属规则；独立 Recovery 服务在约 `10s` 的尝试截止时间提供失效开放兜底。也可以右键选择“恢复网络”。紧急情况下只清理本工具的 anchor：

```bash
sudo pfctl -a com.apple/hearthstone-puller -F all
```

不要执行全局 PF flush，也不要修改 `/etc/pf.conf`。

卸载时右键选择“卸载服务”并完成管理员授权。无法通过 App 操作时，可使用打包生成的终端备用脚本：

```bash
sudo build/helper/uninstall-helper.sh
sudo build/helper/uninstall-helper.sh --remove-logs
```

第二条命令会同时删除日志。

### 风险

macOS PF 无法按 PID 删除已有连接状态。阻断规则已限定本地地址和端口、远端地址以及 TCP `3724`，但清理既有 PF state 时，若其他应用恰好使用同一地址对，也可能短暂重连。严格的按进程网络隔离需要具备相应 Apple 权限的 Network Extension。

故意制造游戏断线可能违反暴雪、平台或赛事的服务条款，并可能影响账号。使用者应自行确认适用规则并承担风险。本项目与 Blizzard Entertainment 无关。

### 公开验证

以下命令只使用发行分支包含的文件，不安装服务、不修改 PF：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash scripts/integration-test.sh --dry-run
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash scripts/build-release.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash scripts/package-app.sh
codesign --verify --deep --strict build/HearthstonePuller.app
lipo -info build/HearthstonePuller.app/Contents/MacOS/HearthstonePuller
lipo -info build/helper/hearthstone-puller-helper
lipo -info build/helper/hearthstone-puller-recovery
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build/HearthstonePuller.app/Contents/Info.plist
```

最后一条命令应输出 `1.0.0`。

### 作者

- Author: Yunnn
- Repository: <https://github.com/alanhaskey/HearthstonePuller>

## English

HearthstonePuller is a personal macOS utility for resetting a Hearthstone game connection. It provides an always-on-top floating button and uses a dedicated PF anchor to reset the verified Hearthstone process's TCP `3724` match connection, allowing the game to enter its normal reconnect flow.

It is not a general network switch: it does not disable system-wide networking, affect unrelated ports, inspect payloads, or use Network Extension. A PF rule matches only the original connection tuple captured at click time, so a reconnect using a new local port is not continuously blocked.

### Features

- Native macOS app with a 144 x 72 always-on-top floating control.
- Accepts only code-signature-validated processes inside the local `Hearthstone.app` and their TCP `3724` connections.
- Keeps the UI unprivileged; a minimal Helper and independent Recovery service perform PF operations and fail-open timeout recovery.
- Shows only Install Service or Uninstall Service according to current installation state, checked whenever the context menu opens.
- Displays remaining time while waiting for connection activity and reconnection, with redetect, network recovery, and About actions.
- Builds Universal Binaries for Apple Silicon and Intel.

### Requirements And Boundaries

- macOS 13 or later.
- Full Xcode, expected at `/Applications/Xcode.app` by default.
- Local administrator authorization when installing or uninstalling the service.
- No paid Apple Developer account and no SIP changes are required. The app is ad-hoc signed for local builds and personal use; Gatekeeper behavior and third-party distribution are not guaranteed.
- The tool does not modify or reload `/etc/pf.conf`, flush the root PF ruleset, or touch other PF anchors.

### Build And Package

```bash
git clone https://github.com/alanhaskey/HearthstonePuller.git
cd HearthstonePuller
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash scripts/build-release.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash scripts/package-app.sh
```

Outputs:

```text
build/HearthstonePuller.app
build/helper/
```

Launch the app with:

```bash
open build/HearthstonePuller.app
```

### Service Workflow

After the first launch, right-click the floating button, choose Install Service, and approve the single macOS administrator prompt. Once installation succeeds, start or return to Hearthstone.

Whenever the context menu opens, the app checks two executable files, two LaunchDaemon plists, and the service configuration. It shows only Uninstall Service when all five are safe regular files and both binaries are executable. Missing, partial, or unsafe installations such as symlinked artifacts show only Install Service. The applicable action is disabled while an operation is running.

The app bundle contains the complete service package and does not depend on the repository path or `build/helper/` after being moved. “需要安装” means the Helper is unavailable; “服务异常” means a request failed. Runtime availability and on-disk installation state are intentionally separate.

### Usage And Countdowns

The button does nothing while it shows “未检测到对局” (No Match Detected). Once a target connection is found, it shows “一键拔线” (Reset Connection). TCP `443`, TCP `1119`, and UDP traffic do not enable the button.

After a click, “等待连接” (Waiting for Connection) displays up to `10s` remaining. The PF rule waits for the captured original connection to send again and is removed as soon as that connection disappears. The `10s` value is an attempt deadline, not a fixed disconnection duration. If the original connection stays quiet and does not disappear, the button becomes the retryable “未触发” (Not Triggered) state.

After a successful reset, “等待重连” (Waiting to Reconnect) displays up to `15s` remaining. A new TCP `3724` connection returns the app to “一键拔线”; if the match has ended or no new connection appears before the deadline, it returns to “未检测到对局”. Countdowns use authoritative Helper state and active states show at least `1s`, never a transient `0s`.

### Recovery And Uninstall

The Helper normally clears its dedicated rules immediately. The independent Recovery service provides a fail-open fallback around the `10s` attempt deadline. The context menu also provides Restore Network. In an emergency, flush only this tool's anchor:

```bash
sudo pfctl -a com.apple/hearthstone-puller -F all
```

Do not flush PF globally or modify `/etc/pf.conf`.

To uninstall, right-click the button, choose Uninstall Service, and approve administrator authorization. If the app cannot perform the operation, use the packaged terminal fallback:

```bash
sudo build/helper/uninstall-helper.sh
sudo build/helper/uninstall-helper.sh --remove-logs
```

The second command also removes logs.

### Risks

macOS PF cannot remove existing connection state by PID. Rules are scoped to the local address and port, remote address, and TCP `3724`, but another app using the same address pair could also reconnect briefly when existing PF state is cleared. Strict per-process network isolation requires Network Extension with the corresponding Apple entitlement.

Intentionally disrupting a game connection may violate Blizzard, platform, or tournament terms and may affect an account. Users are responsible for evaluating and accepting those risks. This project is not affiliated with Blizzard Entertainment.

### Public Verification

These commands use only files included in the release branch and do not install the service or modify PF:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash scripts/integration-test.sh --dry-run
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash scripts/build-release.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash scripts/package-app.sh
codesign --verify --deep --strict build/HearthstonePuller.app
lipo -info build/HearthstonePuller.app/Contents/MacOS/HearthstonePuller
lipo -info build/helper/hearthstone-puller-helper
lipo -info build/helper/hearthstone-puller-recovery
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build/HearthstonePuller.app/Contents/Info.plist
```

The final command should print `1.0.0`.

### Author

- Author: Yunnn
- Repository: <https://github.com/alanhaskey/HearthstonePuller>
