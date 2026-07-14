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

# networked vs offline plist: EnvironmentVariables/ALLOW_NETWORK gated on config enableNetwork
# (generate only; no install/bootstrap)
NET_TMP="$(mktemp -d)"

CFG_ON="$NET_TMP/worker_on.json"; printf '{"enableNetwork": true}' > "$CFG_ON"
PLIST_ON="$NET_TMP/com.biolab.discovery.on.plist"
CONFIG="$CFG_ON" bash "$AGENT" generate "$PLIST_ON"
plutil -lint "$PLIST_ON" >/dev/null || { echo "FAIL: networked plist not valid"; exit 1; }
grep -q '<key>EnvironmentVariables</key>' "$PLIST_ON" || { echo "FAIL: networked plist missing EnvironmentVariables"; exit 1; }
grep -q 'ALLOW_NETWORK' "$PLIST_ON" || { echo "FAIL: networked plist missing ALLOW_NETWORK"; exit 1; }

CFG_OFF="$NET_TMP/worker_off.json"; printf '{"enableNetwork": false}' > "$CFG_OFF"
PLIST_OFF="$NET_TMP/com.biolab.discovery.off.plist"
CONFIG="$CFG_OFF" bash "$AGENT" generate "$PLIST_OFF"
plutil -lint "$PLIST_OFF" >/dev/null || { echo "FAIL: offline plist not valid"; exit 1; }
if grep -q 'ALLOW_NETWORK' "$PLIST_OFF"; then echo "FAIL: offline plist should not contain ALLOW_NETWORK"; exit 1; fi

# resume clears PAUSED + failure streak
S="$(mktemp -d)"; mkdir -p "$S/state"; : > "$S/state/PAUSED"; echo 3 > "$S/state/consecutive_failures"
LABEL="com.biolab.test.$$" STATE_DIR="$S/state" bash "$AGENT" resume
[[ ! -f "$S/state/PAUSED" ]] || { echo "FAIL: resume left PAUSED"; exit 1; }
[[ ! -f "$S/state/consecutive_failures" ]] || { echo "FAIL: resume left failcount"; exit 1; }

echo "agent tests OK"
