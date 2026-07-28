#!/bin/bash
set -euo pipefail

testing="${PULLER_INSTALL_TESTING:-0}"
install_root="${PULLER_INSTALL_ROOT:-}"
if [[ -n "$install_root" && "$testing" != "1" ]]; then
  echo "PULLER_INSTALL_ROOT is test-only" >&2
  exit 1
fi
if [[ "$testing" != "1" && "$(id -u)" -ne 0 ]]; then
  echo "uninstall-helper.sh must run as root" >&2
  exit 1
fi

root_prefix="${install_root%/}"
launchctl_bin="${PULLER_LAUNCHCTL:-/bin/launchctl}"
helper_socket="$root_prefix/var/run/hearthstone-puller/helper.sock"
helper_plist="$root_prefix/Library/LaunchDaemons/com.yunnn.hearthstone-puller.helper.plist"
recovery_plist="$root_prefix/Library/LaunchDaemons/com.yunnn.hearthstone-puller.recovery.plist"

if [[ -S "$helper_socket" && "$testing" != "1" ]]; then
  printf '\0\0\0\016{"restore":{}}' | /usr/bin/nc -U "$helper_socket" >/dev/null 2>&1 || true
fi

"$launchctl_bin" bootout system/com.yunnn.hearthstone-puller.helper 2>/dev/null || true
"$launchctl_bin" bootout system/com.yunnn.hearthstone-puller.recovery 2>/dev/null || true
if [[ "$testing" != "1" ]]; then
  /sbin/pfctl -a com.apple/hearthstone-puller -F all >/dev/null 2>&1 || true
fi

rm -f \
  "$root_prefix/Library/PrivilegedHelperTools/hearthstone-puller-helper" \
  "$root_prefix/Library/PrivilegedHelperTools/hearthstone-puller-recovery" \
  "$helper_plist" \
  "$recovery_plist" \
  "$root_prefix/Library/Application Support/HearthstonePuller/config.plist" \
  "$root_prefix/var/run/hearthstone-puller/helper.sock" \
  "$root_prefix/var/run/hearthstone-puller/recovery.sock"

if [[ "${1:-}" == "--remove-logs" ]]; then
  rm -rf "$root_prefix/Library/Logs/HearthstonePuller"
fi
echo "HearthstonePuller helper uninstalled"
