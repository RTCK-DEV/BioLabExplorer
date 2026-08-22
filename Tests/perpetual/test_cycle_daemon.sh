#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CYCLE="${ROOT}/scripts/run_discovery_cycle.sh"

sandbox() {
  local d; d="$(mktemp -d)"
  mkdir -p "$d/state/inbox/processed" "$d/runs" "$d/discoveries" "$d/ref" "$d/logs"
  printf '>ref\nMKTAYIAKQR\n' > "$d/ref/ref.fasta"
  printf '{"diskFloorGB":0,"maxCandidates":20,"maxWorkspaceBytes":1073741824000,"maxLogFiles":200,"maxDaemonLogBytes":10485760,"budgetSeconds":60,"maxConsecutiveFailures":2,"throttleSeconds":300}' > "$d/worker.json"
  echo "$d"
}
ok_pipe="bash ${ROOT}/Tests/perpetual/fake_pipeline.sh"
fail_pipe="/usr/bin/false"
run() {  # $1=sandbox $2=pipeline_cmd
  STATE_DIR="$1/state" RUNS_DIR="$1/runs" DISCOVERIES_DIR="$1/discoveries" \
  REFERENCE="$1/ref/ref.fasta" LOG_DIR="$1/logs" NOTIFY_CMD="true" \
  CONFIG="$1/worker.json" PIPELINE_CMD="$2" bash "$CYCLE"
}
count_actionable() { python3 "${ROOT}/scripts/discovery_db.py" count-actionable --db "$1/discoveries/ledger.db"; }

# 1) PAUSED gate: present -> no-op, no run dir
S="$(sandbox)"; : > "$S/state/PAUSED"
printf '>TESTACC1\nMKTAYIAKQR\n' > "$S/state/inbox/b.fasta"
run "$S" "$ok_pipe"
[[ -z "$(ls -A "$S/runs")" ]] || { echo "FAIL: PAUSED ran a cycle"; exit 1; }
[[ -f "$S/state/inbox/b.fasta" ]] || { echo "FAIL: PAUSED consumed batch"; exit 1; }

# 2) pidless stale lock is reclaimed (lock dir exists, no pid file)
S="$(sandbox)"; mkdir -p "$S/state/.lock"
printf '>TESTACC1\nMKTAYIAKQR\n' > "$S/state/inbox/b.fasta"
run "$S" "$ok_pipe"
[[ "$(count_actionable "$S")" == "1" ]] || { echo "FAIL: pidless lock not reclaimed"; exit 1; }

# 3) circuit breaker: maxConsecutiveFailures=2 -> after 2 failed cycles, PAUSED written
S="$(sandbox)"
printf '>x\nMKT\n' > "$S/state/inbox/f1.fasta"; set +e; run "$S" "$fail_pipe"; set -e
[[ ! -f "$S/state/PAUSED" ]] || { echo "FAIL: paused too early (after 1)"; exit 1; }
[[ "$(cat "$S/state/consecutive_failures")" == "1" ]] || { echo "FAIL: failcount!=1"; exit 1; }
printf '>x\nMKT\n' > "$S/state/inbox/f2.fasta"; set +e; run "$S" "$fail_pipe"; set -e
[[ -f "$S/state/PAUSED" ]] || { echo "FAIL: circuit breaker did not trip at 2"; exit 1; }

# 4) success resets the failure streak
S="$(sandbox)"
printf '>x\nMKT\n' > "$S/state/inbox/f1.fasta"; set +e; run "$S" "$fail_pipe"; set -e
[[ "$(cat "$S/state/consecutive_failures")" == "1" ]] || { echo "FAIL: pre-reset failcount"; exit 1; }
printf '>TESTACC1\nMKTAYIAKQR\n' > "$S/state/inbox/ok.fasta"; run "$S" "$ok_pipe"
[[ ! -f "$S/state/consecutive_failures" ]] || { echo "FAIL: success did not reset streak"; exit 1; }

# 5) daemon log rotation: oversized launchd-appended daemon.out.log gets rotated on every cycle
S="$(sandbox)"
printf '{"diskFloorGB":0,"maxCandidates":20,"maxWorkspaceBytes":1073741824000,"maxLogFiles":200,"maxDaemonLogBytes":10,"budgetSeconds":60,"maxConsecutiveFailures":2,"throttleSeconds":300}' > "$S/worker.json"
printf 'x%.0s' {1..64} > "$S/logs/daemon.out.log"
printf '>TESTACC1\nMKTAYIAKQR\n' > "$S/state/inbox/b.fasta"
run "$S" "$ok_pipe"
[[ -f "$S/logs/daemon.out.log.1" ]] || { echo "FAIL: oversized daemon.out.log was not rotated to .1"; exit 1; }
if [[ -f "$S/logs/daemon.out.log" ]]; then
  sz="$(wc -c < "$S/logs/daemon.out.log" | tr -d ' ')"
  [[ "$sz" -lt 10 ]] || { echo "FAIL: live daemon.out.log still oversized after rotation"; exit 1; }
fi

# 5b) only generated cycle logs are pruned to maxLogFiles; daemon logs and run
# artifacts are outside this retention operation.
S="$(sandbox)"
printf '{"diskFloorGB":0,"maxCandidates":20,"maxWorkspaceBytes":1073741824000,"maxLogFiles":2,"maxDaemonLogBytes":10485760,"budgetSeconds":60,"maxConsecutiveFailures":2,"throttleSeconds":300}' > "$S/worker.json"
for n in 1 2 3 4; do printf 'old-%s\n' "$n" > "$S/logs/cycle-old-$n.log"; done
printf 'keep-me\n' > "$S/logs/daemon.out.log"
printf '>TESTACC1\nMKTAYIAKQR\n' > "$S/state/inbox/b.fasta"
run "$S" "$ok_pipe"
[[ "$(find "$S/logs" -maxdepth 1 -name 'cycle-*.log' | wc -l | tr -d ' ')" == "2" ]] || { echo "FAIL: maxLogFiles retention boundary"; exit 1; }
[[ -f "$S/logs/daemon.out.log" ]] || { echo "FAIL: cycle retention removed daemon log"; exit 1; }

# 6) STOP kill-switch must survive a broken config: cfg() must not abort before the STOP gate
S="$(sandbox)"; : > "$S/state/STOP"
printf 'not-json' > "$S/worker.json"
printf '>TESTACC1\nMKTAYIAKQR\n' > "$S/state/inbox/b.fasta"
set +e; run "$S" "$ok_pipe"; rc=$?; set -e
[[ "$rc" -eq 0 ]] || { echo "FAIL: STOP + broken config did not exit 0 (rc=$rc)"; exit 1; }
[[ -z "$(ls -A "$S/runs")" ]] || { echo "FAIL: STOP + broken config created a run dir"; exit 1; }

echo "cycle daemon tests OK"
