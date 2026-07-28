# HearthstonePuller for macOS

个人使用的 macOS 炉石传说“拔线器”。它显示一个始终置顶的 88 × 88 悬浮按钮，点击后使用独立 PF anchor 重置当前已验证炉石进程的 TCP `3724` 对局连接。规则只匹配点击瞬间的原连接元组，重连使用的新本地端口不会被继续阻断。

## 边界

- 支持 macOS 13 及以上，Intel 与 Apple Silicon。
- 不需要付费 Apple Developer 账号，不使用 Network Extension，不关闭 SIP。
- UI 永不以 root 运行；两个最小 launch daemon 承担 PF 操作与独立超时恢复。
- 不解析、记录或修改网络 payload。
- 不修改或重载 `/etc/pf.conf`，不清空根 PF ruleset，也不操作其他 anchor。
- 这是个人本机构建，不承诺 Gatekeeper 或第三方分发体验。

## 构建

需要完整 Xcode。仓库固定通过当前 shell 的 `DEVELOPER_DIR` 使用 Xcode，不改变系统全局选择：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash scripts/build-release.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash scripts/package-app.sh
```

产物：

```text
build/HearthstonePuller.app
build/helper/
```

## 安装与运行

helper 只需安装一次。安装脚本读取当前控制台用户 UID，安装 recovery 后再安装 helper：

```bash
sudo build/helper/install-helper.sh
open build/HearthstonePuller.app
```

按钮状态为“未检测到对局”时不会执行拔线。检测到已签名且位于本机 `Hearthstone.app` 内的运行进程及 TCP `3724` 连接后，按钮变为“一键拔线”。TCP `443`、TCP `1119` 和 UDP 连接不会使按钮进入可用状态。右键可重新检测、恢复网络或退出。

## 紧急恢复

正常情况下 helper 观察到点击时捕获的原连接消失后立即清除规则。独立 recovery daemon 在约 2 秒处提供异常兜底；这不是固定断线时长。若需要手动恢复，只清理本工具专属 anchor：

```bash
sudo pfctl -a com.apple/hearthstone-puller -F all
```

不要使用全局 PF flush，也不要修改 `/etc/pf.conf`。

## 卸载

先退出悬浮应用，再执行：

```bash
sudo build/helper/uninstall-helper.sh
```

日志默认保留。需要同时删除日志时：

```bash
sudo build/helper/uninstall-helper.sh --remove-logs
```

## 已知限制与风险

macOS PF 无法按 PID 删除已有连接状态。本工具的阻断规则精确限定点击时捕获的本地地址和端口、远端地址以及 TCP `3724`，但清理既有 PF state 时，如果其他应用恰好连接同一个地址对，它也可能短暂重连。这是 PF 方案无法彻底消除的限制；要求严格的按进程隔离需要付费开发者能力下的 Network Extension。

故意制造游戏断线可能违反暴雪或相关赛事的服务条款，也可能影响账号。使用者应自行确认适用规则并承担风险。

## 开发验证

普通测试不会请求 root 或改动 PF：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

本机炉石签名观察与真实 PF 测试分别由 `HEARTHSTONE_OBSERVATION_TEST=1` 和 `PF_INTEGRATION_TEST=1` 显式开启；PF 测试还要求 root。不要在不了解测试内容时开启这些变量。
