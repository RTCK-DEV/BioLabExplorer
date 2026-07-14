#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CYCLE="${ROOT}/scripts/run_discovery_cycle.sh"

sandbox() {
  local d; d="$(mktemp -d)"
  mkdir -p "$d/state/inbox/processed" "$d/runs" "$d/discoveries" "$d/ref" "$d/logs"
  printf '>ref\nMKTAYIAKQR\n' > "$d/ref/ref.fasta"
  printf '{"diskFloorGB":0,"maxCandidates":20,"maxWorkspaceBytes":1073741824000,"maxLogFiles":200,"budgetSeconds":60}' > "$d/worker.json"
  echo "$d"
}
run() {  # $1=sandbox
  STATE_DIR="$1/state" RUNS_DIR="$1/runs" DISCOVERIES_DIR="$1/discoveries" \
  REFERENCE="$1/ref/ref.fasta" LOG_DIR="$1/logs" NOTIFY_CMD="true" \
  CONFIG="$1/worker.json" PIPELINE_CMD="bash ${ROOT}/Tests/perpetual/fake_pipeline.sh" \
  bash "$CYCLE"
}
count_actionable() { python3 "${ROOT}/scripts/discovery_db.py" count-actionable --db "$1/discoveries/ledger.db"; }

# 1) STOP -> no run dir, no ledger
S="$(sandbox)"; touch "$S/state/STOP"; run "$S"
[[ -z "$(ls -A "$S/runs")" ]] || { echo "FAIL: STOP made a run"; exit 1; }
[[ ! -f "$S/discoveries/ledger.db" ]] || { echo "FAIL: STOP wrote ledger"; exit 1; }

# 2) disk-floor fires -> no run (floor above real free space)
S="$(sandbox)"; printf '{"diskFloorGB":99999999,"maxCandidates":20,"maxWorkspaceBytes":1073741824000,"maxLogFiles":200,"budgetSeconds":60}' > "$S/worker.json"
printf '>TESTACC1\nMKTAYIAKQR\n' > "$S/state/inbox/b.fasta"; run "$S"
[[ -z "$(ls -A "$S/runs")" ]] || { echo "FAIL: disk-floor did not fire"; exit 1; }
[[ -f "$S/state/inbox/b.fasta" ]] || { echo "FAIL: disk-floor consumed batch"; exit 1; }

# 3) empty inbox -> no run
S="$(sandbox)"; run "$S"
[[ -z "$(ls -A "$S/runs")" ]] || { echo "FAIL: empty inbox made a run"; exit 1; }

# 4) happy path
S="$(sandbox)"; printf '>TESTACC1\nMKTAYIAKQR\n' > "$S/state/inbox/batch1.fasta"; run "$S"
[[ "$(count_actionable "$S")" == "1" ]] || { echo "FAIL: actionable != 1"; exit 1; }
ls "$S/state/inbox/processed/"*batch1.fasta >/dev/null 2>&1 || { echo "FAIL: not moved to processed"; exit 1; }
python3 -c "import json,sys; d=json.load(open('$S/state/rotation.json')); sys.exit(0 if d.get('cycle')==1 else 1)" || { echo "FAIL: cycle != 1"; exit 1; }

# 5) dedup across cycles
S="$(sandbox)"; printf '>TESTACC1\nMKTAYIAKQR\n' > "$S/state/inbox/b1.fasta"; run "$S"
printf '>TESTACC1\nMKTAYIAKQR\n' > "$S/state/inbox/b2.fasta"; run "$S"
[[ "$(count_actionable "$S")" == "1" ]] || { echo "FAIL: dedup across cycles"; exit 1; }

# 6) non-overwriting processed: a colliding basename must not clobber
S="$(sandbox)"; printf '>TESTACC1\nMKTAYIAKQR\n' > "$S/state/inbox/dup.fasta"; run "$S"
printf '>OTHER\nMMMM\n' > "$S/state/inbox/dup.fasta"; run "$S"
[[ "$(ls "$S/state/inbox/processed/" | grep -c dup.fasta)" == "2" ]] || { echo "FAIL: processed overwrite"; exit 1; }

# 7) manifest digest MATCH -> cycle proceeds
S="$(sandbox)"; printf '>TESTACC1\nMKTAYIAKQR\n' > "$S/state/inbox/batch7.fasta"
DIGEST="$(python3 -c 'import hashlib,sys;print("sha256:"+hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$S/ref/ref.fasta")"
printf '{"referenceSha256":"%s","querySetId":"offline-inbox","exclusions":["virulence factors","select-agent homologs"]}' "$DIGEST" > "$S/approved_manifest.json"
run "$S"
[[ "$(count_actionable "$S")" == "1" ]] || { echo "FAIL: manifest match did not proceed"; exit 1; }
ls "$S/state/inbox/processed/"*batch7.fasta >/dev/null 2>&1 || { echo "FAIL: manifest match batch not moved to processed"; exit 1; }

# 8) manifest digest MISMATCH -> fail closed
S="$(sandbox)"; printf '>TESTACC1\nMKTAYIAKQR\n' > "$S/state/inbox/batch8.fasta"
WRONG="sha256:$(python3 -c "print('0'*64)")"
printf '{"referenceSha256":"%s","querySetId":"offline-inbox","exclusions":["virulence factors"]}' "$WRONG" > "$S/approved_manifest.json"
set +e; run "$S"; rc=$?; set -e
[[ "$rc" == "3" ]] || { echo "FAIL: manifest mismatch rc != 3 (got $rc)"; exit 1; }
[[ -z "$(ls -A "$S/runs")" ]] || { echo "FAIL: manifest mismatch made a run"; exit 1; }
[[ -f "$S/state/inbox/batch8.fasta" ]] || { echo "FAIL: manifest mismatch consumed batch"; exit 1; }
[[ -z "$(ls -A "$S/state/inbox/processed")" ]] || { echo "FAIL: manifest mismatch batch reached processed"; exit 1; }

# df failure must NOT abort the cycle nor falsely trip the disk-floor pause
S="$(sandbox)"; printf '>TESTACC1\nMKTAYIAKQR\n' > "$S/state/inbox/dffail.fasta"
mkdir -p "$S/fakebin"; printf '#!/bin/sh\nexit 1\n' > "$S/fakebin/df"; chmod +x "$S/fakebin/df"
STATE_DIR="$S/state" RUNS_DIR="$S/runs" DISCOVERIES_DIR="$S/discoveries" \
  REFERENCE="$S/ref/ref.fasta" LOG_DIR="$S/logs" NOTIFY_CMD="true" \
  CONFIG="$S/worker.json" PIPELINE_CMD="bash ${ROOT}/Tests/perpetual/fake_pipeline.sh" \
  PATH="$S/fakebin:$PATH" bash "$CYCLE"
[[ "$(count_actionable "$S")" == "1" ]] || { echo "FAIL: df failure aborted/false-paused the cycle"; exit 1; }
ls "$S/state/inbox/processed/"*dffail.fasta >/dev/null 2>&1 || { echo "FAIL: df failure prevented batch consumption"; exit 1; }

echo "cycle offline tests OK"
