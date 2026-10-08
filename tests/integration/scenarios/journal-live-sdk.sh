#!/usr/bin/env bash
# Runs MatronIntegrationTests/JournalServerTests against a real
# matron-journal server subprocess (JournalServerHarness boots it per-test;
# this script does not manage the server itself).
#
# Precondition (one-time): cd ~/Dev/matron-journal && npm install
#
# MATRON_JOURNAL_PATH may override the checkout location; defaults to
# $HOME/Dev/matron-journal (an absolute path — JournalServerHarness resolves
# the same default independently, so this export is a convenience/override,
# not load-bearing for the harness itself).
set -euo pipefail
cd "$(dirname "$0")/../../.."

: "${MATRON_JOURNAL_PATH:=$HOME/Dev/matron-journal}"
export MATRON_JOURNAL_PATH

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen not found on PATH" >&2
  exit 1
fi
xcodegen generate

pkill -f 'xctest' >/dev/null 2>&1 || true

# `|| true` is load-bearing under `set -e -o pipefail`: xcodebuild exits
# non-zero on any real test failure, which (via pipefail, through the
# `tail` stage) would otherwise abort the script right here — before the
# grep gate below ever runs — turning a real failure into silent success.
OUTPUT=$(xcodebuild test -project Matron.xcodeproj -scheme MatronMac \
  -destination 'platform=macOS' \
  -only-testing:MatronIntegrationTests/JournalServerTests 2>&1 | tail -40) || true
echo "$OUTPUT"
echo "$OUTPUT" | grep -qE "Executed [0-9]+ tests?, with 0 failures" || { echo "FAIL: tests did not pass"; exit 1; }
