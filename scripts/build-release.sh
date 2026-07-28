#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$repo_root"

swift build -c release --arch arm64 --arch x86_64
bin_path="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

for executable in HearthstonePuller hearthstone-puller-helper hearthstone-puller-recovery; do
  info="$(lipo -info "$bin_path/$executable")"
  echo "$info"
  [[ "$info" == *arm64* && "$info" == *x86_64* ]] || {
    echo "$executable is not universal" >&2
    exit 1
  }
done
