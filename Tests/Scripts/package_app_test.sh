#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/../.." && pwd -P)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$repo_root"

bash scripts/package-app.sh

app="$repo_root/build/HearthstonePuller.app"
resources="$app/Contents/Resources"
service="$resources/Service"
icon="$resources/AppIcon.icns"

test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$app/Contents/Info.plist")" = "AppIcon.icns"
test -s "$icon"

expected_service_files=(
  hearthstone-puller-helper
  hearthstone-puller-recovery
  com.yunnn.hearthstone-puller.helper.plist
  com.yunnn.hearthstone-puller.recovery.plist
  install-service.sh
  uninstall-service.sh
  verify-installation.sh
)
test "$(find "$service" -type f | wc -l | tr -d ' ')" = "${#expected_service_files[@]}"
for name in "${expected_service_files[@]}"; do
  test -f "$service/$name"
done
for name in \
  hearthstone-puller-helper \
  hearthstone-puller-recovery \
  install-service.sh \
  uninstall-service.sh \
  verify-installation.sh; do
  test -x "$service/$name"
done

inspection_root="$(mktemp -d)"
trap 'rm -rf "$inspection_root"' EXIT
/usr/bin/iconutil --convert iconset --output "$inspection_root/AppIcon.iconset" "$icon"

for entry in \
  'icon_16x16.png:16' \
  'icon_16x16@2x.png:32' \
  'icon_128x128.png:128' \
  'icon_512x512@2x.png:1024'; do
  file="${entry%%:*}"
  expected="${entry##*:}"
  png="$inspection_root/AppIcon.iconset/$file"
  test -s "$png"
  width="$(/usr/bin/sips -g pixelWidth "$png" | awk '/pixelWidth/ {print $2}')"
  height="$(/usr/bin/sips -g pixelHeight "$png" | awk '/pixelHeight/ {print $2}')"
  test "$width" = "$expected"
  test "$height" = "$expected"
done

/usr/bin/codesign --verify --deep --strict "$app"
echo "package_app_test: PASS"
