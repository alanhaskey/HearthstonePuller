#!/bin/bash
set -euo pipefail

testing="${PULLER_INSTALL_TESTING:-0}"
install_root="${PULLER_INSTALL_ROOT:-}"
if [[ -n "$install_root" && "$testing" != "1" ]]; then
  echo "PULLER_INSTALL_ROOT is test-only" >&2
  exit 1
fi
root_prefix="${install_root%/}"
launchctl_bin="${PULLER_LAUNCHCTL:-/bin/launchctl}"

test -x "$root_prefix/Library/PrivilegedHelperTools/hearthstone-puller-helper"
test -x "$root_prefix/Library/PrivilegedHelperTools/hearthstone-puller-recovery"
test -f "$root_prefix/Library/LaunchDaemons/com.yunnn.hearthstone-puller.helper.plist"
test -f "$root_prefix/Library/LaunchDaemons/com.yunnn.hearthstone-puller.recovery.plist"
test -f "$root_prefix/Library/Application Support/HearthstonePuller/config.plist"

"$launchctl_bin" print system/com.yunnn.hearthstone-puller.recovery >/dev/null
"$launchctl_bin" print system/com.yunnn.hearthstone-puller.helper >/dev/null
echo "HearthstonePuller helper installation verified"
