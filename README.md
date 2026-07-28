# HearthstonePuller for macOS

[中文](#中文) | [English](#english)

## 中文

HearthstonePuller 是一个 macOS 炉石传说连接重置工具。检测到对局后，点击悬浮按钮即可让游戏进入重连流程。

### 功能

- 始终置顶的一键操作按钮。
- 自动检测炉石传说对局。
- 显示连接重置和等待重连的剩余时间。
- 右键菜单可安装或卸载服务。
- 支持 Apple Silicon 和 Intel Mac。

### 系统要求

- macOS 13 或更高版本。
- 安装或卸载服务时需要管理员授权。
- 从源码构建需要完整 Xcode。

### 下载

可从 [GitHub Releases](https://github.com/alanhaskey/HearthstonePuller/releases) 下载最新的 macOS ZIP 包，解压后运行 `HearthstonePuller.app`。

### 从源码构建

```bash
git clone https://github.com/alanhaskey/HearthstonePuller.git
cd HearthstonePuller
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash scripts/build-release.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash scripts/package-app.sh
open build/HearthstonePuller.app
```

### 使用

1. 启动 App，右键悬浮按钮并选择“安装服务”。
2. 启动炉石传说并进入对局，等待按钮显示“一键拔线”。
3. 点击按钮，等待游戏重新连接。

### 卸载

右键悬浮按钮，选择“卸载服务”并完成管理员授权，然后退出并删除 App。

### 注意

App 使用本地签名且未经过 Apple 公证。首次打开下载版本时，macOS Gatekeeper 可能要求在“系统设置 → 隐私与安全性”中手动允许。

主动中断游戏连接可能违反游戏、平台或赛事规则，并可能影响账号。使用者应自行承担风险。本项目与 Blizzard Entertainment 无关。

### 作者

- Yunnn
- <https://github.com/alanhaskey/HearthstonePuller>

## English

HearthstonePuller is a macOS connection reset utility for Hearthstone. Once a match is detected, click the floating button to make the game enter its reconnect flow.

### Features

- Always-on-top one-click control.
- Automatic Hearthstone match detection.
- Remaining-time display while resetting and reconnecting.
- Service installation and removal from the context menu.
- Apple Silicon and Intel Mac support.

### Requirements

- macOS 13 or later.
- Administrator authorization when installing or removing the service.
- Full Xcode when building from source.

### Download

Download the latest macOS ZIP from [GitHub Releases](https://github.com/alanhaskey/HearthstonePuller/releases), extract it, and run `HearthstonePuller.app`.

### Build From Source

```bash
git clone https://github.com/alanhaskey/HearthstonePuller.git
cd HearthstonePuller
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash scripts/build-release.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash scripts/package-app.sh
open build/HearthstonePuller.app
```

### Usage

1. Launch the app, right-click the floating button, and choose Install Service.
2. Start Hearthstone and enter a match. Wait until the button shows `一键拔线`.
3. Click the button and wait for the game to reconnect.

### Uninstall

Right-click the floating button, choose Uninstall Service, approve administrator authorization, then quit and delete the app.

### Notice

The app is locally signed and is not notarized by Apple. On first launch, macOS Gatekeeper may require manual approval under System Settings → Privacy & Security.

Intentionally disrupting a game connection may violate game, platform, or tournament rules and may affect an account. Use it at your own risk. This project is not affiliated with Blizzard Entertainment.

### Author

- Yunnn
- <https://github.com/alanhaskey/HearthstonePuller>
