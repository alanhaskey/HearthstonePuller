#!/bin/bash
set -euo pipefail

mode="${1:-}"
if [[ "$mode" != "--dry-run" && "$mode" != "--pf" ]]; then
  echo "usage: integration-test.sh --dry-run|--pf" >&2
  exit 1
fi
if [[ "$mode" == "--pf" ]]; then
  if [[ "${PF_INTEGRATION_TEST:-0}" != "1" || "$(id -u)" -ne 0 ]]; then
    echo "--pf requires root and PF_INTEGRATION_TEST=1" >&2
    exit 1
  fi
  echo "PF fixture mode intentionally does not bypass Hearthstone code identity." >&2
  echo "Run the gated PFController test plus docs/manual-test-checklist.md." >&2
  DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
    swift test --filter PFControllerTests.testRootPFIntegrationWhenExplicitlyEnabled
  exit 0
fi

repo_root="$(cd "$(dirname "$0")/.." && pwd -P)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
cd "$repo_root"
swift build --product EchoServer >/dev/null
swift build --product SocketClient >/dev/null
bin_path="$(swift build --show-bin-path)"
port=$((39000 + ($$ % 1000)))
run_dir="$(mktemp -d)"
pids=()

cleanup() {
  for pid in "${pids[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  for pid in "${pids[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
  rm -rf "$run_dir"
}
trap cleanup EXIT INT TERM

"$bin_path/EchoServer" --host 127.0.0.1 --port "$port" >"$run_dir/server.log" 2>&1 &
pids+=("$!")
sleep 0.2
"$bin_path/SocketClient" --host 127.0.0.1 --port "$port" --id A --duration 5 >"$run_dir/a.log" &
pids+=("$!")
"$bin_path/SocketClient" --host 127.0.0.1 --port "$port" --id B --duration 5 >"$run_dir/b.log" &
pids+=("$!")

wait "${pids[1]}"
wait "${pids[2]}"
test "$(grep -c '^ack A ' "$run_dir/a.log")" -ge 80
test "$(grep -c '^ack B ' "$run_dir/b.log")" -ge 80
echo "integration-test --dry-run: PASS"
