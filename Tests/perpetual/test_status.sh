#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STATUS="${ROOT}/scripts/discovery_status.sh"

# seeded
S="$(mktemp -d)"; mkdir -p "$S/state" "$S/discoveries"
echo '{"cycle":7,"lastRunId":"cycle_x"}' > "$S/state/rotation.json"
python3 - "$S/discoveries/ledger.db" <<'PY'
import sqlite3,sys
c=sqlite3.connect(sys.argv[1])
c.execute("CREATE TABLE IF NOT EXISTS processed(seq_sha256 TEXT PRIMARY KEY,accession TEXT,verdict TEXT,score REAL,classification TEXT,first_seen_cycle INT,run_id TEXT,ts TEXT,schema_version INT)")
c.execute("INSERT OR IGNORE INTO processed VALUES('h1','A1','actionable',0.9,'x',1,'r','t',1)")
c.execute("INSERT OR IGNORE INTO processed VALUES('h2','A2','screened',NULL,NULL,1,'r','t',1)")
c.commit()
PY
OUT="$(STATE_DIR="$S/state" DISCOVERIES_DIR="$S/discoveries" bash "$STATUS")"; echo "$OUT"
grep -q '^cycles=7$' <<<"$OUT"      || { echo FAIL cycles; exit 1; }
grep -q '^discoveries=1$' <<<"$OUT" || { echo FAIL discoveries; exit 1; }
grep -q '^network=off$' <<<"$OUT"   || { echo FAIL network; exit 1; }
grep -q '^stop=no$' <<<"$OUT"       || { echo FAIL stop; exit 1; }

# empty/missing ledger must not corrupt output
S2="$(mktemp -d)"; mkdir -p "$S2/state" "$S2/discoveries"
OUT2="$(STATE_DIR="$S2/state" DISCOVERIES_DIR="$S2/discoveries" bash "$STATUS")"
[[ "$(grep -c 'discoveries=' <<<"$OUT2")" == "1" ]] || { echo "FAIL: empty-ledger output"; exit 1; }
grep -q '^discoveries=0$' <<<"$OUT2" || { echo "FAIL: empty discoveries!=0"; exit 1; }

# df failure must degrade to disk_free_gb=unknown, not blank the whole readout
S4="$(mktemp -d)"; mkdir -p "$S4/state" "$S4/discoveries" "$S4/fakebin"
printf '#!/bin/sh\nexit 1\n' > "$S4/fakebin/df"; chmod +x "$S4/fakebin/df"
set +e
OUT4="$(PATH="$S4/fakebin:$PATH" STATE_DIR="$S4/state" DISCOVERIES_DIR="$S4/discoveries" bash "$STATUS")"
rc4=$?
set -e
[[ "$rc4" -eq 0 ]] || { echo "FAIL: df failure aborted status (rc=$rc4)"; exit 1; }
grep -q '^disk_free_gb=unknown$' <<<"$OUT4" || { echo "FAIL: df failure did not degrade to unknown"; exit 1; }
grep -q '^discoveries=0$' <<<"$OUT4" || { echo "FAIL: df failure blanked the readout"; exit 1; }

echo "status tests OK"
