#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$repo_root"

bin_path="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
app="$repo_root/build/HearthstonePuller.app"
helper_package="$repo_root/build/helper"
rm -rf "$app" "$helper_package"
mkdir -p "$app/Contents/MacOS" "$helper_package"

/usr/bin/install -m 0644 Resources/AppInfo.plist "$app/Contents/Info.plist"
/usr/bin/install -m 0755 "$bin_path/HearthstonePuller" "$app/Contents/MacOS/HearthstonePuller"
/usr/bin/install -m 0755 "$bin_path/hearthstone-puller-helper" "$helper_package/hearthstone-puller-helper"
/usr/bin/install -m 0755 "$bin_path/hearthstone-puller-recovery" "$helper_package/hearthstone-puller-recovery"
/usr/bin/install -m 0755 scripts/install-helper.sh "$helper_package/install-helper.sh"
/usr/bin/install -m 0755 scripts/uninstall-helper.sh "$helper_package/uninstall-helper.sh"
/usr/bin/install -m 0755 scripts/verify-installation.sh "$helper_package/verify-installation.sh"
/usr/bin/install -m 0644 Resources/com.yunnn.hearthstone-puller.helper.plist "$helper_package/com.yunnn.hearthstone-puller.helper.plist"
/usr/bin/install -m 0644 Resources/com.yunnn.hearthstone-puller.recovery.plist "$helper_package/com.yunnn.hearthstone-puller.recovery.plist"

/usr/bin/codesign --force --sign - "$app"
/usr/bin/codesign --verify --deep --strict "$app"
echo "Packaged $app and $helper_package"
