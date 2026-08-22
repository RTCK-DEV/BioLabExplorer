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
  printf '{"referenceSha256":"%s","querySetDigest":"%s","reviewer":"test-reviewer","reviewedDate":"2026-07-15","exclusions":["virulence factors","toxin biosynthesis gene clusters","select-agent homologs"]}' "$refd" "$qrd" > "$d/cfg/approved_manifest.json"
}
run() {  # $1=sandbox
  STATE_DIR="$1/state" RUNS_DIR="$1/runs" DISCOVERIES_DIR="$1/discoveries" \
  REFERENCE="$1/ref/ref.fasta" LOG_DIR="$1/logs" NOTIFY_CMD="true" \
  CONFIG="$1/cfg/worker.json" PIPELINE_CMD="bash ${ROOT}/Tests/perpetual/fake_pipeline.sh" \
  UNIPROT_FIXTURE_DIR="$1/fx" bash "$CYCLE" --allow-network
}
run_no_auth() {
  STATE_DIR="$1/state" RUNS_DIR="$1/runs" DISCOVERIES_DIR="$1/discoveries" \
  REFERENCE="$1/ref/ref.fasta" LOG_DIR="$1/logs" NOTIFY_CMD="true" \
  CONFIG="$1/cfg/worker.json" PIPELINE_CMD="bash ${ROOT}/Tests/perpetual/fake_pipeline.sh" \
  UNIPROT_FIXTURE_DIR="$1/fx" bash "$CYCLE"
}
count_actionable() { python3 "${ROOT}/scripts/discovery_db.py" count-actionable --db "$1/discoveries/ledger.db"; }

# 1) enableNetwork=false + empty inbox -> no-op (no fetch), no run
S="$(sandbox false)"; manifest "$S"; run "$S"
[[ -z "$(ls -A "$S/runs")" ]] || { echo "FAIL: fetched with network disabled"; exit 1; }

# 1b) config alone is insufficient: each manual invocation must be authorized
S="$(sandbox true)"; manifest "$S"; run_no_auth "$S"
[[ -z "$(ls -A "$S/runs")" ]] || { echo "FAIL: fetched without invocation authorization"; exit 1; }

# 2) enableNetwork=true + empty inbox + manifest present -> fetch (fixture) + process
S="$(sandbox true)"; manifest "$S"; run "$S"
[[ "$(count_actionable "$S")" == "1" ]] || { echo "FAIL: network refill+process did not record actionable"; exit 1; }

# 3) enableNetwork=true + empty inbox + manifest ABSENT -> fail-closed (no fetch, nonzero)
S="$(sandbox true)"    # no manifest() call
set +e; run "$S"; rc=$?; set -e
[[ "$rc" -ne 0 ]] || { echo "FAIL: network fetch without manifest should fail-closed"; exit 1; }
# `[[ -e dir/glob* ]]` does not expand the glob, so the previous form tested a
# literal path that never exists and could never fail. Expand it properly.
shopt -s nullglob; fetched=("$S"/state/inbox/uniprot_*); shopt -u nullglob
[[ "${#fetched[@]}" -eq 0 ]] || { echo "FAIL: fetched despite absent manifest"; exit 1; }

# 4) enableNetwork=true + manifest present but querySetDigest MISMATCH -> fail-closed (no fetch, nonzero)
S="$(sandbox true)";
refd="$(python3 -c 'import hashlib,sys;print("sha256:"+hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$S/ref/ref.fasta")"
# Deliberately wrong querySetDigest to simulate digest mismatch
printf '{"referenceSha256":"%s","querySetDigest":"sha256:0000000000000000000000000000000000000000000000000000000000000000","reviewer":"test-reviewer","reviewedDate":"2026-07-15","exclusions":["virulence factors","toxin biosynthesis gene clusters","select-agent homologs"]}' "$refd" > "$S/cfg/approved_manifest.json"
set +e; run "$S"; rc=$?; set -e
[[ "$rc" -ne 0 ]] || { echo "FAIL: network fetch with querySetDigest mismatch should fail-closed"; exit 1; }
[[ -z "$(ls -A "$S/state/inbox/processed" 2>/dev/null)" ]] || { echo "FAIL: processed fetch despite querySetDigest mismatch"; exit 1; }

# 5) matching digests without a named human reviewer still fail closed
S="$(sandbox true)"
refd="$(python3 -c 'import hashlib,sys;print("sha256:"+hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$S/ref/ref.fasta")"
qrd="$(python3 -c 'import hashlib,sys;print("sha256:"+hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$S/cfg/query_rotation.json")"
printf '{"referenceSha256":"%s","querySetDigest":"%s","reviewer":"unset","reviewedDate":"2026-07-15","exclusions":["virulence factors","toxin biosynthesis gene clusters","select-agent homologs"]}' "$refd" "$qrd" > "$S/cfg/approved_manifest.json"
set +e; run "$S"; rc=$?; set -e
[[ "$rc" -ne 0 ]] || { echo "FAIL: unreviewed network scope should fail closed"; exit 1; }
[[ -z "$(ls -A "$S/state/inbox/processed" 2>/dev/null)" ]] || { echo "FAIL: unreviewed scope processed a fetch"; exit 1; }

# 6) a same-host cursor that changes the approved query is a hard contract
# failure, not a temporary network no-op disguised as success.
S="$(sandbox true)"; manifest "$S"
printf '%s\n' 'https://rest.uniprot.org/uniprotkb/search?query=wrong&format=fasta&size=5&cursor=x' > "$S/fx/page-0.next"
set +e; run "$S"; rc=$?; set -e
[[ "$rc" -eq 3 ]] || { echo "FAIL: unsafe next cursor should exit 3 (got $rc)"; exit 1; }
[[ -z "$(find "$S/state/inbox" -maxdepth 1 -name '*.fasta' -print -quit)" ]] || { echo "FAIL: unsafe cursor left a fetched batch"; exit 1; }
[[ -z "$(ls -A "$S/runs")" ]] || { echo "FAIL: unsafe cursor created a run"; exit 1; }

echo "cycle network tests OK"
