#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CYCLE="${ROOT}/scripts/run_discovery_cycle.sh"

sandbox() {  # $1 = enableSimulation
  local d; d="$(mktemp -d)"
  mkdir -p "$d/state/inbox/processed" "$d/runs" "$d/discoveries" "$d/ref" "$d/logs" "$d/bin"
  printf '>ref\nMKTAYIAKQR\n' > "$d/ref/ref.fasta"
  printf '{"diskFloorGB":0,"maxCandidates":20,"maxWorkspaceBytes":1073741824000,"maxLogFiles":200,"budgetSeconds":60,"maxConsecutiveFailures":5,"throttleSeconds":300,"maxDaemonLogBytes":10485760,"enableNetwork":false,"fetchPageSize":5,"fetchRateLimitSeconds":0,"uniprotHost":"rest.uniprot.org","enableSimulation":%s,"simRamBudgetBytes":4294967296,"simReserveBytes":0,"simMaxSeqLength":700,"simJobTimeoutSeconds":30,"enableColabFold":false,"externalMsaStorePath":""}' "$1" > "$d/worker.json"
  echo "$d"
}
run() {
  STATE_DIR="$1/state" RUNS_DIR="$1/runs" DISCOVERIES_DIR="$1/discoveries" \
  REFERENCE="$1/ref/ref.fasta" LOG_DIR="$1/logs" NOTIFY_CMD="true" \
  CONFIG="$1/worker.json" PIPELINE_CMD="bash ${ROOT}/Tests/perpetual/fake_pipeline.sh" \
  SIM_BIN_DIR="$1/bin" bash "$CYCLE"
}

# 1) enableSimulation=false -> no sim summary, cycle fine
S="$(sandbox false)"; printf '>TESTACC1\nMKTAYIAKQR\n' > "$S/state/inbox/b.fasta"; run "$S"
[[ -z "$(find "$S/runs" -name summary.json 2>/dev/null)" ]] || { echo "FAIL: sim ran while disabled"; exit 1; }

# 2) enableSimulation=true, no backends -> summary written, cycle still succeeds
S="$(sandbox true)"; printf '>TESTACC1\nMKTAYIAKQR\n' > "$S/state/inbox/b.fasta"; run "$S"
SUM="$(find "$S/runs" -name summary.json | head -1)"
[[ -n "$SUM" ]] || { echo "FAIL: no sim summary with simulation enabled"; exit 1; }
python3 -c "import json,sys; d=json.load(open('$SUM')); sys.exit(0 if d['ran']==0 and d['backends'] else 1)" \
  || { echo "FAIL: summary should report 0 ran + backend availability"; exit 1; }
ls "$S/state/inbox/processed/"*b.fasta >/dev/null 2>&1 || { echo "FAIL: cycle did not complete"; exit 1; }

# 3) enableSimulation=true with a stub backend -> at least one job ran
S="$(sandbox true)"; printf '#!/bin/sh\nprintf "hit\\n" > "$4"\n' > "$S/bin/mmseqs"; chmod +x "$S/bin/mmseqs"
printf '>TESTACC1\nMKTAYIAKQR\n' > "$S/state/inbox/b.fasta"; run "$S"
SUM="$(find "$S/runs" -name summary.json | head -1)"
python3 -c "import json,sys; d=json.load(open('$SUM')); sys.exit(0 if d['ran']>=1 else 1)" \
  || { echo "FAIL: stub backend did not run"; exit 1; }

echo "sim cycle tests OK"
