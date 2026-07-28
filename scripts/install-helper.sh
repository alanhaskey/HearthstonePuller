#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd -P)"
testing="${PULLER_INSTALL_TESTING:-0}"
install_root="${PULLER_INSTALL_ROOT:-}"

if [[ -n "$install_root" && "$testing" != "1" ]]; then
  echo "PULLER_INSTALL_ROOT is test-only" >&2
  exit 1
fi
if [[ "$testing" != "1" && "$(id -u)" -ne 0 ]]; then
  echo "install-helper.sh must run as root" >&2
  exit 1
fi

root_prefix="${install_root%/}"
artifact_dir="${PULLER_ARTIFACT_DIR:-$script_dir}"
if [[ -d "$script_dir/../Resources" ]]; then
  resource_dir="$script_dir/../Resources"
else
  resource_dir="$script_dir"
fi
launchctl_bin="${PULLER_LAUNCHCTL:-/bin/launchctl}"
console_uid="${PULLER_CONSOLE_UID:-$(stat -f %u /dev/console)}"

if ! [[ "$console_uid" =~ ^[0-9]+$ ]] || (( console_uid < 501 )); then
  echo "invalid console UID" >&2
  exit 1
fi

tools_dir="$root_prefix/Library/PrivilegedHelperTools"
daemons_dir="$root_prefix/Library/LaunchDaemons"
support_dir="$root_prefix/Library/Application Support/HearthstonePuller"
logs_dir="$root_prefix/Library/Logs/HearthstonePuller"
helper_dst="$tools_dir/hearthstone-puller-helper"
recovery_dst="$tools_dir/hearthstone-puller-recovery"
helper_plist="$daemons_dir/com.yunnn.hearthstone-puller.helper.plist"
recovery_plist="$daemons_dir/com.yunnn.hearthstone-puller.recovery.plist"
config_dst="$support_dir/config.plist"

for destination in "$helper_dst" "$recovery_dst" "$helper_plist" "$recovery_plist" "$config_dst"; do
  if [[ -L "$destination" ]]; then
    echo "refusing symlink destination: $destination" >&2
    exit 1
  fi
done

mkdir -p "$tools_dir" "$daemons_dir" "$support_dir" "$logs_dir"

install_file() {
  local mode="$1" source="$2" destination="$3"
  if [[ "$testing" == "1" ]]; then
    /usr/bin/install -m "$mode" "$source" "$destination"
  else
    /usr/bin/install -o root -g wheel -m "$mode" "$source" "$destination"
  fi
}

install_file 0755 "$artifact_dir/hearthstone-puller-helper" "$helper_dst"
install_file 0755 "$artifact_dir/hearthstone-puller-recovery" "$recovery_dst"
install_file 0644 "$resource_dir/com.yunnn.hearthstone-puller.helper.plist" "$helper_plist"
install_file 0644 "$resource_dir/com.yunnn.hearthstone-puller.recovery.plist" "$recovery_plist"

config_tmp="$(mktemp "$support_dir/config.XXXXXX")"
trap 'rm -f "$config_tmp"' EXIT
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
  '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
  '<plist version="1.0"><dict><key>allowedUID</key>' \
  "<integer>$console_uid</integer></dict></plist>" > "$config_tmp"
install_file 0644 "$config_tmp" "$config_dst"
rm -f "$config_tmp"
trap - EXIT

"$launchctl_bin" bootout system/com.yunnn.hearthstone-puller.helper 2>/dev/null || true
"$launchctl_bin" bootout system/com.yunnn.hearthstone-puller.recovery 2>/dev/null || true

bootstrap_service() {
  local plist="$1" attempt
  for attempt in 1 2 3 4; do
    if "$launchctl_bin" bootstrap system "$plist" 2>/dev/null; then
      return
    fi
    /bin/sleep 0.2
  done
  "$launchctl_bin" bootstrap system "$plist"
}

bootstrap_service "$recovery_plist"
bootstrap_service "$helper_plist"

PULLER_INSTALL_ROOT="$install_root" PULLER_INSTALL_TESTING="$testing" \
  PULLER_LAUNCHCTL="$launchctl_bin" bash "$script_dir/verify-installation.sh"
echo "HearthstonePuller helper installed for UID $console_uid"
