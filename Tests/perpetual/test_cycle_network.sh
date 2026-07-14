#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CYCLE="${ROOT}/scripts/run_discovery_cycle.sh"

sandbox() {  # $1 = enableNetwork (true/false)
  local d; d="$(mktemp -d)"
  mkdir -p "$d/state/inbox/processed" "$d/runs" "$d/discoveries" "$d/ref" "$d/logs" "$d/cfg" "$d/fx"
  printf '>ref\nMKTAYIAKQR\n' > "$d/ref/ref.fasta"
  # fixture: one page whose accession matches the fake pipeline's qualifying id
  printf '>tr|TESTACC1|X d\nMKTAYIAKQR\n' > "$d/fx/page-0.fasta"
  printf '{"diskFloorGB":0,"maxCandidates":20,"maxWorkspaceBytes":1073741824000,"maxLogFiles":200,"budgetSeconds":60,"maxConsecutiveFailures":5,"throttleSeconds":300,"maxDaemonLogBytes":10485760,"enableNetwork":%s,"fetchPageSize":5,"fetchRateLimitSeconds":0,"uniprotHost":"rest.uniprot.org"}' "$1" > "$d/cfg/worker.json"
  printf '{"schemaVersion":1,"queries":[{"id":"q1","uniprotQuery":"x"}]}' > "$d/cfg/query_rotation.json"
  echo "$d"
}
manifest() {  # $1=sandbox : write an approved manifest matching the fixture ref
  local d="$1" refd qrd
  refd="$(python3 -c 'import hashlib,sys;print("sha256:"+hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$d/ref/ref.fasta")"
  qrd="$(python3 -c 'import hashlib,sys;print("sha256:"+hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$d/cfg/query_rotation.json")"
  printf '{"referenceSha256":"%s","querySetDigest":"%s","exclusions":["x"]}' "$refd" "$qrd" > "$d/cfg/approved_manifest.json"
}
run() {  # $1=sandbox
  STATE_DIR="$1/state" RUNS_DIR="$1/runs" DISCOVERIES_DIR="$1/discoveries" \
  REFERENCE="$1/ref/ref.fasta" LOG_DIR="$1/logs" NOTIFY_CMD="true" \
  CONFIG="$1/cfg/worker.json" PIPELINE_CMD="bash ${ROOT}/Tests/perpetual/fake_pipeline.sh" \
  UNIPROT_FIXTURE_DIR="$1/fx" bash "$CYCLE"
}
count_actionable() { python3 "${ROOT}/scripts/discovery_db.py" count-actionable --db "$1/discoveries/ledger.db"; }

# 1) enableNetwork=false + empty inbox -> no-op (no fetch), no run
S="$(sandbox false)"; manifest "$S"; run "$S"
[[ -z "$(ls -A "$S/runs")" ]] || { echo "FAIL: fetched with network disabled"; exit 1; }

# 2) enableNetwork=true + empty inbox + manifest present -> fetch (fixture) + process
S="$(sandbox true)"; manifest "$S"; run "$S"
[[ "$(count_actionable "$S")" == "1" ]] || { echo "FAIL: network refill+process did not record actionable"; exit 1; }

# 3) enableNetwork=true + empty inbox + manifest ABSENT -> fail-closed (no fetch, nonzero)
S="$(sandbox true)"    # no manifest() call
set +e; run "$S"; rc=$?; set -e
[[ "$rc" -ne 0 ]] || { echo "FAIL: network fetch without manifest should fail-closed"; exit 1; }
[[ -z "$(ls -A "$S/state/inbox")" || ! -e "$S/state/inbox"/uniprot_* ]] 2>/dev/null || { echo "FAIL: fetched despite absent manifest"; exit 1; }

# 4) enableNetwork=true + manifest present but querySetDigest MISMATCH -> fail-closed (no fetch, nonzero)
S="$(sandbox true)";
refd="$(python3 -c 'import hashlib,sys;print("sha256:"+hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$S/ref/ref.fasta")"
# Deliberately wrong querySetDigest to simulate digest mismatch
printf '{"referenceSha256":"%s","querySetDigest":"sha256:0000000000000000000000000000000000000000000000000000000000000000","exclusions":["x"]}' "$refd" > "$S/cfg/approved_manifest.json"
set +e; run "$S"; rc=$?; set -e
[[ "$rc" -ne 0 ]] || { echo "FAIL: network fetch with querySetDigest mismatch should fail-closed"; exit 1; }
[[ -z "$(ls -A "$S/state/inbox/processed" 2>/dev/null)" ]] || { echo "FAIL: processed fetch despite querySetDigest mismatch"; exit 1; }

echo "cycle network tests OK"
