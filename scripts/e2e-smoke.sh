#!/usr/bin/env bash
# AI-assisted smoke tests for the iOS app (tester.army e2e), run before each
# App Store submission. Builds the app for the simulator, rebuilds the local
# journal rig (tests/e2e/rig/rig.sh), and runs tests/e2e. See tests/e2e/README.md.
#
#   scripts/e2e-smoke.sh                 # build, rig, run every smoke test
#   scripts/e2e-smoke.sh --grep Projects # extra args go to `e2e run`
# Env:
#   E2E_SKIP_BUILD=1   reuse the last simulator build
#   ANTHROPIC_API_KEY  model key; read from ~/.config/matron-e2e/anthropic.key when unset
#   E2E_MODEL          model id (default claude-sonnet-5-5)
# Exit status is the test run's. Each run appends one line to
# ~/Library/Caches/matron-e2e/runs.tsv (time, commit, status, tests, tokens).
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT=$(pwd)
CACHE="$HOME/Library/Caches/matron-e2e"
SIM_NAME="${E2E_SIM_NAME:-Matron e2e}"
mkdir -p "$CACHE"

if ! command -v node >/dev/null || [[ "$(node -p 'process.versions.node.split(".")[0]')" -lt 22 ]]; then
  export PATH="/opt/homebrew/opt/node@22/bin:$PATH"
fi
command -v xcodegen >/dev/null || export PATH="/opt/homebrew/bin:$PATH"

if [[ -z "${ANTHROPIC_API_KEY:-}" && -f "$HOME/.config/matron-e2e/anthropic.key" ]]; then
  ANTHROPIC_API_KEY=$(tr -d '[:space:]' < "$HOME/.config/matron-e2e/anthropic.key")
  export ANTHROPIC_API_KEY
fi
if [[ -z "${ANTHROPIC_API_KEY:-}" ]]; then
  echo "e2e-smoke: set ANTHROPIC_API_KEY or write it to ~/.config/matron-e2e/anthropic.key" >&2
  exit 2
fi

# Our own simulator, created on first use, so a run never drives another one.
UDID=$(xcrun simctl list devices available | grep -F "    $SIM_NAME (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/' || true)
if [[ -z "$UDID" ]]; then UDID=$(xcrun simctl create "$SIM_NAME" "iPhone 17"); fi

if [[ "${E2E_SKIP_BUILD:-0}" != "1" ]]; then
  xcodegen generate > /dev/null
  echo "e2e-smoke: building Matron for the simulator…"
  # Signed the default way (ad hoc for the simulator): CODE_SIGNING_ALLOWED=NO
  # drops the app-group entitlement the rig injects the session into.
  if ! xcodebuild build -project Matron.xcodeproj -scheme Matron -destination "id=$UDID" \
      -derivedDataPath "$CACHE/dd" > "$CACHE/build.log" 2>&1; then
    grep -E "error:" "$CACHE/build.log" | head -20 >&2
    echo "e2e-smoke: build failed, log: $CACHE/build.log" >&2
    exit 1
  fi
fi

# Before the rig: its seed script uses packages from tests/e2e.
[[ -d tests/e2e/node_modules ]] || (cd tests/e2e && npm ci --silent)

E2E_SIM_NAME="$SIM_NAME" tests/e2e/rig/rig.sh

cd tests/e2e
set +e
E2E_SIM_NAME="$SIM_NAME" npx e2e run "$@"
status=$?
set -e

# One line per run for the trial's flake/cost report.
node -e '
const fs = require("fs");
const run = JSON.parse(fs.readFileSync(".e2e/report.json", "utf8")).run;
const tests = run.results.filter((t) => t.selected !== false);
const passed = tests.filter((t) => t.status === "passed").length;
const retried = tests.filter((t) => (t.attempts ?? []).length > 1).length;
console.log([new Date().toISOString(), process.argv[1], process.argv[2], `${passed}/${tests.length}`, `retried=${retried}`, JSON.stringify(run.usage ?? null)].join("\t"));
' "$(git -C "$ROOT" rev-parse --short HEAD)" "$status" >> "$CACHE/runs.tsv" 2>/dev/null || true
echo "e2e-smoke: report tests/e2e/.e2e/summary.md, run log $CACHE/runs.tsv"
exit $status
