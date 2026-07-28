#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$repo_root"

bin_path="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
app="$repo_root/build/HearthstonePuller.app"
helper_package="$repo_root/build/helper"
iconset="$repo_root/build/AppIcon.iconset"
app_resources="$app/Contents/Resources"
service_package="$app_resources/Service"
rm -rf "$app" "$helper_package" "$iconset"
mkdir -p "$app/Contents/MacOS" "$service_package" "$helper_package" "$iconset"

base_icon="$repo_root/build/AppIcon-1024.png"
/usr/bin/sips -s format png Resources/AppIcon.svg --out "$base_icon" >/dev/null
while read -r filename pixels; do
  /usr/bin/sips -z "$pixels" "$pixels" "$base_icon" --out "$iconset/$filename" >/dev/null
done <<'ICON_SIZES'
icon_16x16.png 16
icon_16x16@2x.png 32
icon_32x32.png 32
icon_32x32@2x.png 64
icon_128x128.png 128
icon_128x128@2x.png 256
icon_256x256.png 256
icon_256x256@2x.png 512
icon_512x512.png 512
icon_512x512@2x.png 1024
ICON_SIZES
/usr/bin/iconutil --convert icns --output "$app_resources/AppIcon.icns" "$iconset"
rm -f "$base_icon"

/usr/bin/install -m 0644 Resources/AppInfo.plist "$app/Contents/Info.plist"
/usr/bin/install -m 0755 "$bin_path/HearthstonePuller" "$app/Contents/MacOS/HearthstonePuller"

/usr/bin/install -m 0755 "$bin_path/hearthstone-puller-helper" "$service_package/hearthstone-puller-helper"
/usr/bin/install -m 0755 "$bin_path/hearthstone-puller-recovery" "$service_package/hearthstone-puller-recovery"
/usr/bin/install -m 0755 scripts/install-helper.sh "$service_package/install-service.sh"
/usr/bin/install -m 0755 scripts/uninstall-helper.sh "$service_package/uninstall-service.sh"
/usr/bin/install -m 0755 scripts/verify-installation.sh "$service_package/verify-installation.sh"
/usr/bin/install -m 0644 Resources/com.yunnn.hearthstone-puller.helper.plist "$service_package/com.yunnn.hearthstone-puller.helper.plist"
/usr/bin/install -m 0644 Resources/com.yunnn.hearthstone-puller.recovery.plist "$service_package/com.yunnn.hearthstone-puller.recovery.plist"

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
