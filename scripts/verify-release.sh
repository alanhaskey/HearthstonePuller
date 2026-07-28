#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$repo_root"

source_plist="Resources/AppInfo.plist"
source_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$source_plist")"
expected_version="${EXPECTED_VERSION:-$source_version}"
if [[ "$source_version" != "$expected_version" ]]; then
  echo "version mismatch: expected $expected_version, source is $source_version" >&2
  exit 1
fi

bash scripts/build-release.sh
bash scripts/package-app.sh

app="build/HearthstonePuller.app"
info_plist="$app/Contents/Info.plist"
codesign --verify --deep --strict "$app"

binaries=(
  "$app/Contents/MacOS/HearthstonePuller"
  "$app/Contents/Resources/Service/hearthstone-puller-helper"
  "$app/Contents/Resources/Service/hearthstone-puller-recovery"
)
for binary in "${binaries[@]}"; do
  info="$(lipo -info "$binary")"
  echo "$info"
  [[ "$info" == *arm64* && "$info" == *x86_64* ]] || {
    echo "binary is not Universal: $binary" >&2
    exit 1
  }
done

packaged_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$info_plist")"
build_number="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$info_plist")"
[[ "$packaged_version" == "$expected_version" ]] || {
  echo "version mismatch: expected $expected_version, package is $packaged_version" >&2
  exit 1
}
[[ "$build_number" == "1" ]] || {
  echo "build number mismatch: expected 1, package is $build_number" >&2
  exit 1
}

echo "verify-release: PASS"
