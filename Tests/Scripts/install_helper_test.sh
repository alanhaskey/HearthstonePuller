#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd -P)"
test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT

artifacts="$test_root/artifacts"
fake_root="$test_root/root"
mkdir -p "$artifacts" "$fake_root" "$test_root/bin"
printf '#!/bin/sh\nexit 0\n' > "$artifacts/hearthstone-puller-helper"
printf '#!/bin/sh\nexit 0\n' > "$artifacts/hearthstone-puller-recovery"
chmod 755 "$artifacts/hearthstone-puller-helper" "$artifacts/hearthstone-puller-recovery"

launch_log="$test_root/launch.log"
cat > "$test_root/bin/launchctl" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$PULLER_LAUNCH_LOG"
if [ "${PULLER_LAUNCH_FAIL_ONCE:-0}" = "1" ] \
  && [ "${1:-}" = "bootstrap" ] \
  && echo "$*" | grep -q recovery \
  && [ ! -e "$PULLER_LAUNCH_FAILURE_MARKER" ]; then
  : > "$PULLER_LAUNCH_FAILURE_MARKER"
  exit 5
fi
exit 0
SH
chmod 755 "$test_root/bin/launchctl"

common_env=(
  PULLER_INSTALL_TESTING=1
  PULLER_INSTALL_ROOT="$fake_root"
  PULLER_ARTIFACT_DIR="$artifacts"
  PULLER_LAUNCHCTL="$test_root/bin/launchctl"
  PULLER_LAUNCH_LOG="$launch_log"
  PULLER_LAUNCH_FAIL_ONCE=1
  PULLER_LAUNCH_FAILURE_MARKER="$test_root/launch-failed-once"
  PULLER_CONSOLE_UID=501
)

env "${common_env[@]}" bash "$repo_root/scripts/install-helper.sh"

helper="$fake_root/Library/PrivilegedHelperTools/hearthstone-puller-helper"
recovery="$fake_root/Library/PrivilegedHelperTools/hearthstone-puller-recovery"
helper_plist="$fake_root/Library/LaunchDaemons/com.yunnn.hearthstone-puller.helper.plist"
recovery_plist="$fake_root/Library/LaunchDaemons/com.yunnn.hearthstone-puller.recovery.plist"
config="$fake_root/Library/Application Support/HearthstonePuller/config.plist"

test -x "$helper"
test -x "$recovery"
test -f "$helper_plist"
test -f "$recovery_plist"
test -f "$config"
test "$(stat -f %Lp "$helper")" = "755"
test "$(stat -f %Lp "$helper_plist")" = "644"
test "$(stat -f %Lp "$config")" = "644"
grep -q '<integer>501</integer>' "$config"

recovery_line="$(grep -n 'bootstrap.*recovery' "$launch_log" | head -1 | cut -d: -f1)"
helper_line="$(grep -n 'bootstrap.*helper' "$launch_log" | head -1 | cut -d: -f1)"
test "$recovery_line" -lt "$helper_line"
test "$(grep -c 'bootstrap.*recovery' "$launch_log")" = "2"
test "$(grep -c 'bootstrap.*helper' "$launch_log")" = "1"

env "${common_env[@]}" bash "$repo_root/scripts/uninstall-helper.sh"
env "${common_env[@]}" bash "$repo_root/scripts/uninstall-helper.sh"
test ! -e "$helper"
test ! -e "$recovery"

mkdir -p "$(dirname "$helper")"
ln -s "$artifacts/hearthstone-puller-helper" "$helper"
if env "${common_env[@]}" bash "$repo_root/scripts/install-helper.sh"; then
  echo "install unexpectedly accepted a symlink destination" >&2
  exit 1
fi

echo "install_helper_test: PASS"
