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
- [ ] Confirm the dedicated anchor is empty before enabling a real cut.

## One Non-Ranked Cut

- [ ] Use a non-ranked match or safe practice context.
- [ ] Click once and confirm the UI shows `断线中 0.5s`.
- [ ] Confirm the game reconnects without leaving the match.
- [ ] Confirm the anchor is empty by approximately T+2.2 seconds.
- [ ] Confirm a second click cannot extend the window.

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
- [ ] Repeated cuts with at least five seconds between attempts.
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
- `swift test`: 54 tests executed, 0 failures, 2 explicitly gated tests skipped.
- `install_helper_test.sh`: fake-root install, recovery-first bootstrap, symlink refusal, and idempotent uninstall passed.
- `integration-test.sh --dry-run`: two loopback clients transferred continuously for five seconds with no gap over 500 ms.
- Universal release build: app, helper, and recovery each contain `x86_64` and `arm64`.
- Ad-hoc app signature passed `codesign --verify --deep --strict`.
- Not yet executed against a live Hearthstone session.
- Root PF integration and anchor-empty confirmation were not run; they require explicit user approval and `PF_INTEGRATION_TEST=1`.
