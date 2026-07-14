#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AGENT="${ROOT}/scripts/discovery_agent.sh"

# generate a plist and validate it (no launchctl load in tests)
TMP="$(mktemp -d)"; PLIST="$TMP/com.biolab.discovery.plist"
bash "$AGENT" generate "$PLIST"
plutil -lint "$PLIST" >/dev/null || { echo "FAIL: plist not valid"; exit 1; }
grep -q '<key>KeepAlive</key>' "$PLIST" || { echo "FAIL: no KeepAlive"; exit 1; }
grep -q '<key>ThrottleInterval</key>' "$PLIST" || { echo "FAIL: no ThrottleInterval"; exit 1; }
grep -q 'run_discovery_cycle.sh' "$PLIST" || { echo "FAIL: plist does not invoke the cycle"; exit 1; }
grep -q '<key>Label</key>' "$PLIST" || { echo "FAIL: no Label"; exit 1; }

# resume clears PAUSED + failure streak
S="$(mktemp -d)"; mkdir -p "$S/state"; : > "$S/state/PAUSED"; echo 3 > "$S/state/consecutive_failures"
LABEL="com.biolab.test.$$" STATE_DIR="$S/state" bash "$AGENT" resume
[[ ! -f "$S/state/PAUSED" ]] || { echo "FAIL: resume left PAUSED"; exit 1; }
[[ ! -f "$S/state/consecutive_failures" ]] || { echo "FAIL: resume left failcount"; exit 1; }

echo "agent tests OK"
