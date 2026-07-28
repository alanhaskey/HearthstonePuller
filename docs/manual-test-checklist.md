# HearthstonePuller Manual Test Checklist

Date:
macOS version:
Mac architecture:
Network type (Wi-Fi/Ethernet/hotspot/VPN):

## Observation Only

- [ ] Record `/Applications/Hearthstone/Hearthstone.app` version.
- [ ] Record the verified executable path.
- [ ] Record signing identifier and Team ID from `codesign -dvv` output.
- [ ] Record every observed in-bundle process; confirm Battle.net and beta launchers are excluded.
- [ ] Record active IPv4 and IPv6 TCP endpoints before cut.
- [ ] Record active IPv4 and IPv6 connected UDP endpoints before cut.
- [ ] Identify the original TCP `3724` tuple, including its local ephemeral port.
- [ ] Confirm the dedicated anchor is empty before enabling a real cut.

## One Non-Ranked Cut

- [ ] Use a non-ranked match or safe practice context.
- [ ] Click once and confirm the UI shows `等待连接活动` without a countdown.
- [ ] Confirm active PF rules contain only the captured TCP `3724` tuple, including its local port.
- [ ] Confirm TCP `443` and TCP `1119` do not appear in the active rules.
- [ ] Confirm the game reconnects without leaving the match.
- [ ] Confirm the replacement TCP `3724` tuple uses a different local port and is never added to the active rules.
- [ ] Confirm the anchor is cleared immediately after the original tuple disappears.
- [ ] Confirm the UI shows `等待重连` after the original tuple disappears.
- [ ] Confirm the UI returns to `一键拔线` when the replacement tuple appears.
- [ ] Confirm the anchor is empty by approximately T+10.5 seconds if the original tuple remains quiet.
- [ ] Confirm a quiet attempt ends at `未触发`, not `服务异常`, and the button can be clicked again.
- [ ] Confirm a second click cannot replace the captured targets or extend the recovery deadline.

## Reconnect Timeout

- [ ] End a safe match while the UI is `等待重连` so no replacement TCP `3724` tuple appears.
- [ ] Confirm `等待重连` lasts no more than approximately 15 seconds.
- [ ] Confirm the UI ends at `未检测到对局`, not `服务异常`.
- [ ] Confirm PF remains clear throughout the reconnect wait.

## Service Failure Distinction

- [ ] With the helper stopped, confirm the UI reports `服务异常` or `需要安装`, never `未触发`.
- [ ] Restart the helper and confirm normal status detection resumes.

## Unrelated Traffic

- [ ] Browser download remains continuous.
- [ ] Music or video stream remains continuous.
- [ ] Chat connection remains continuous.
- [ ] Voice call remains continuous.
- [ ] Record any collateral reconnect and whether it shared a Hearthstone remote address.

## Environment Matrix

- [ ] Wi-Fi.
- [ ] Ethernet.
- [ ] Mobile hotspot.
- [ ] Common VPN on and off.
- [ ] Sleep/wake during or immediately after cut.
- [ ] Hearthstone restart.
- [ ] Repeated explicit retries after `未触发`.
- [ ] UI termination during cut; recovery anchor empty afterward.
- [ ] Helper termination during cut; recovery anchor empty afterward.

## Dated Results

Commands run:

```text
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
bash scripts/integration-test.sh --dry-run
sudo pfctl -a com.apple/hearthstone-puller -sr
```

Observed results:

- 2026-07-28, macOS 26.6 (25G72), arm64, default interface `en0`.
- `swift test`: 67 tests executed, 0 failures, 2 explicitly gated tests skipped.
- `install_helper_test.sh`: fake-root install, recovery-first bootstrap, symlink refusal, and idempotent uninstall passed.
- `integration-test.sh --dry-run`: two loopback clients transferred continuously for five seconds with no gap over 500 ms.
- Universal release build: app, helper, and recovery each contain `x86_64` and `arm64`.
- Ad-hoc app signature passed `codesign --verify --deep --strict`.
- Not yet executed against a live Hearthstone session.
- Root PF integration and anchor-empty confirmation were not run; they require explicit user approval and `PF_INTEGRATION_TEST=1`.
