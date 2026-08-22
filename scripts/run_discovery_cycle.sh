#!/usr/bin/env bash
set -euo pipefail
exec 3>&1 4>&2

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

CONFIG="${CONFIG:-${ROOT_DIR}/config/worker.json}"
STATE_DIR="${STATE_DIR:-${ROOT_DIR}/state}"
RUNS_DIR="${RUNS_DIR:-${ROOT_DIR}/runs}"
DISCOVERIES_DIR="${DISCOVERIES_DIR:-${ROOT_DIR}/discoveries}"
REFERENCE="${REFERENCE:-${ROOT_DIR}/data/curated_reference/pbp_pks_reference.fasta}"
LOG_DIR="${LOG_DIR:-${ROOT_DIR}/logs}"
NOTIFY_CMD="${NOTIFY_CMD:-}"
ALLOW_NETWORK="${ALLOW_NETWORK:-0}"
BUDGET_OVERRIDE=""
DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --allow-network) ALLOW_NETWORK=1 ;;
    --budget-seconds)
      shift; [[ $# -gt 0 && "$1" =~ ^[1-9][0-9]*$ ]] || { echo "--budget-seconds requires a positive integer" >&2; exit 2; }
      BUDGET_OVERRIDE="$1" ;;
    --dry-run) DRY_RUN=1 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done
if [[ -z "${PIPELINE_CMD:-}" ]]; then
  if [[ -x "${ROOT_DIR}/.build/release/BioLabExplorerPipeline" ]]; then
    PIPELINE_CMD="${ROOT_DIR}/.build/release/BioLabExplorerPipeline"
  else
    PIPELINE_CMD="swift run BioLabExplorerPipeline"
  fi
fi

INBOX="${STATE_DIR}/inbox"; PROCESSED="${INBOX}/processed"
ROTATION="${STATE_DIR}/rotation.json"; LOCK_DIR="${STATE_DIR}/.lock"
LEDGER_DB="${DISCOVERIES_DIR}/ledger.db"; DISCOVERIES_MD="${DISCOVERIES_DIR}/DISCOVERIES.md"

log() {
  # Declared first: assigning in the declaration would mask date's exit status.
  local message
  message="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
  echo "${message}"
  if [[ -n "${CYCLE_LOG:-}" ]]; then echo "${message}" >&3; fi
}
# Reads one worker-config key. Values written as "auto" are resolved from the
# running host by scripts/host_profile.py, so the checked-in config is portable.
cfg() {
  python3 - "${CONFIG}" "$1" "$2" "${ROOT_DIR}/scripts" <<'PY'
import json, sys, os
sys.path.insert(0, sys.argv[4])
with open(sys.argv[1], encoding="utf-8") as source:
    config = json.load(source)
try:
    import host_profile
    config, _ = host_profile.resolve_config(
        config, path=os.path.dirname(os.path.abspath(sys.argv[1]))
    )
except Exception as exc:  # noqa: BLE001 - config reads must never crash the cycle
    print(f"cfg: host profile unavailable, using raw config: {exc}", file=sys.stderr)
print(config.get(sys.argv[2], sys.argv[3]))
PY
}
CYCLE_STARTED_EPOCH="$(date +%s)"

# ---------- bound the daemon's launchd-appended logs (runs on EVERY invocation, incl. no-op) ----------
# launchd's StandardOutPath/StandardErrorPath append on every relaunch under KeepAlive; nothing else
# ever truncates them. Keep one rotated copy and cap the live file so it can't grow unbounded.
rotate_daemon_log() {  # $1 = log file; keep one .1, cap total to ~2x maxDaemonLogBytes
  local f="$1" max sz
  max="$(cfg maxDaemonLogBytes 10485760 2>/dev/null)" || max=10485760
  [[ -n "$max" ]] || max=10485760
  [[ -f "$f" ]] || return 0
  sz="$(wc -c < "$f" 2>/dev/null | tr -d ' ' || echo 0)"
  if [[ "${sz:-0}" -ge "$max" ]]; then mv -f "$f" "$f.1" 2>/dev/null || true; fi
}
rotate_daemon_log "${LOG_DIR}/daemon.out.log"
rotate_daemon_log "${LOG_DIR}/daemon.err.log"

# ---------- preflight guardrails (NO run dir / ledger / rotation side effects) ----------
if [[ -f "${STATE_DIR}/STOP" ]]; then log "STOP present -> graceful stop"; exit 0; fi
if [[ -f "${STATE_DIR}/PAUSED" ]]; then log "PAUSED (circuit breaker) -> no-op; resume via scripts/discovery_agent.sh resume"; exit 0; fi
if [[ ! -s "${REFERENCE}" ]]; then log "missing reference: ${REFERENCE}"; exit 2; fi
BUDGET_SECONDS="${BUDGET_OVERRIDE:-$(cfg budgetSeconds 21600)}"
[[ "${BUDGET_SECONDS}" =~ ^[1-9][0-9]*$ ]] || { log "invalid budgetSeconds=${BUDGET_SECONDS}"; exit 2; }

DISK_FLOOR_GB="$(cfg diskFloorGB 10)"
FREE_GB="$(df -g "${ROOT_DIR}" | awk 'NR==2 {print $4}')" || { log "disk capacity probe failed"; exit 2; }
[[ "${FREE_GB}" =~ ^[0-9]+$ ]] || { log "disk capacity probe returned invalid value: ${FREE_GB:-empty}"; exit 2; }
if [[ "${FREE_GB}" -lt "${DISK_FLOOR_GB}" ]]; then
  log "disk free ${FREE_GB}GB < floor ${DISK_FLOOR_GB}GB -> pause"; exit 0
fi

MAX_WS_BYTES="$(cfg maxWorkspaceBytes 21474836480)"
if [[ -d "${RUNS_DIR}" ]]; then
  USED_KB="$(du -sk "${RUNS_DIR}" | awk '{print $1}')" || { log "workspace quota probe failed"; exit 2; }
  [[ "${USED_KB}" =~ ^[0-9]+$ ]] || { log "workspace quota probe returned invalid value"; exit 2; }
  if [[ $(( USED_KB * 1024 )) -ge "${MAX_WS_BYTES}" ]]; then
    log "workspace ${USED_KB}KB >= quota -> pause (prune runs/ manually)"; exit 0
  fi
fi

MANIFEST="$(dirname "${CONFIG}")/approved_manifest.json"

# batch present? (nullglob array; no error-hiding find|head)
shopt -s nullglob; batches=("${INBOX}"/*.fasta); shopt -u nullglob
if [[ "${DRY_RUN}" == "1" ]]; then
  if [[ ${#batches[@]} -gt 0 ]]; then batch_name="$(basename "${batches[0]}")"; else batch_name="none"; fi
  log "dry-run OK: batch=${batch_name} budgetSeconds=${BUDGET_SECONDS} networkAuthorized=${ALLOW_NETWORK}"
  python3 "${ROOT_DIR}/scripts/sim_queue.py" run --help >/dev/null
  exit 0
fi
if [[ ${#batches[@]} -eq 0 ]]; then
  ENABLE_NET="$(cfg enableNetwork false 2>/dev/null || echo false)"
  if [[ "${ENABLE_NET}" == "True" || "${ENABLE_NET}" == "true" ]]; then
    if [[ "${ALLOW_NETWORK}" != "1" ]]; then
      log "network enabled in config but this invocation lacks --allow-network/ALLOW_NETWORK=1 -> no-op"
      exit 0
    fi
    # network refill is FAIL-CLOSED: require an approved manifest matching BOTH the
    # curated reference and the approved query set before any fetch.
    QR="$(dirname "${CONFIG}")/query_rotation.json"
    if [[ ! -f "${MANIFEST}" ]]; then log "network refill requires approved_manifest.json (absent) -> abort"; exit 3; fi
    python3 - "${MANIFEST}" "${REFERENCE}" "${QR}" <<'PY' || { echo "manifest/query-scope mismatch -> abort" >&2; exit 3; }
import hashlib, json, sys
man = json.load(open(sys.argv[1]))
def d(p): return "sha256:" + hashlib.sha256(open(p, "rb").read()).hexdigest()
required_exclusions = {"virulence factors", "toxin biosynthesis gene clusters", "select-agent homologs"}
reviewer = str(man.get("reviewer", "")).strip().lower()
reviewed_date = str(man.get("reviewedDate", "")).strip()
exclusions = {str(value).strip().lower() for value in man.get("exclusions", [])}
ok = (
    man.get("referenceSha256") == d(sys.argv[2])
    and man.get("querySetDigest") == d(sys.argv[3])
    and reviewer not in ("", "unset")
    and len(reviewed_date) == 10
    and required_exclusions.issubset(exclusions)
)
sys.exit(0 if ok else 1)
PY
    mkdir -p "${INBOX}"
    log "inbox empty + network enabled -> fetching UniProt page"
    if ALLOW_NETWORK="${ALLOW_NETWORK}" python3 "${ROOT_DIR}/scripts/fetch_uniprot.py" --config "${CONFIG}" \
      --query-rotation "${QR}" --rotation "${ROTATION}" --inbox "${INBOX}"; then
      FETCH_RC=0
    else
      FETCH_RC=$?
    fi
    if [[ "${FETCH_RC}" -eq 75 ]]; then
      log "temporary network failure -> soft no-op; cursor unchanged"
      exit 0
    elif [[ "${FETCH_RC}" -ne 0 ]]; then
      log "network fetch contract failed rc=${FETCH_RC} -> abort"
      exit "${FETCH_RC}"
    fi
    shopt -s nullglob; batches=("${INBOX}"/*.fasta); shopt -u nullglob
  fi
  if [[ ${#batches[@]} -eq 0 ]]; then log "inbox empty -> no-op"; exit 0; fi
fi
BATCH="${batches[0]}"

# ---------- biosecurity: reference must match approved manifest digest (fail closed) ----------
# Co-located with CONFIG (not an independent env seam): production CONFIG defaults to
# ${ROOT_DIR}/config/worker.json, so this resolves identically to ${ROOT_DIR}/config/approved_manifest.json
# there. Deriving it from CONFIG's directory (instead of hardcoding ROOT_DIR) lets offline/sandboxed
# tests that seam CONFIG elsewhere skip this check via the existing "-f" gate below, without ever
# touching the fail-closed digest comparison itself.
MANIFEST="$(dirname "${CONFIG}")/approved_manifest.json"
if [[ -f "${MANIFEST}" ]]; then
  python3 - "${MANIFEST}" "${REFERENCE}" <<'PY' || { echo "reference digest != approved manifest -> abort" >&2; exit 3; }
import hashlib, json, sys
man, ref = json.load(open(sys.argv[1])), sys.argv[2]
want = man.get("referenceSha256", "")
got = "sha256:" + hashlib.sha256(open(ref, "rb").read()).hexdigest()
sys.exit(0 if want == got else 1)
PY
fi

# ---------- single-instance lock (atomic mkdir; reclaim stale incl. pidless) ----------
mkdir -p "${STATE_DIR}" "${LOG_DIR}"
if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
  oldpid="$(cat "${LOCK_DIR}/pid" 2>/dev/null || echo "")"
  # Reclaim if no pid was ever written (died between mkdir and pid write) OR the pid is dead.
  if [[ -z "${oldpid}" ]] || ! kill -0 "${oldpid}" 2>/dev/null; then
    log "reclaiming stale lock (pid='${oldpid:-none}')"; rm -rf "${LOCK_DIR}"
    mkdir "${LOCK_DIR}" 2>/dev/null || { log "lock race -> exit"; exit 0; }
  else
    log "another live cycle holds the lock (pid ${oldpid}) -> exit"; exit 0
  fi
fi
echo "$$" > "${LOCK_DIR}/pid"
# Release the lock even if we die before the main finish trap is installed.
trap 'rmdir "${LOCK_DIR}" 2>/dev/null || rm -rf "${LOCK_DIR}" 2>/dev/null || true' EXIT

# ---------- proceed: create run dir, compute cycle ----------
mkdir -p "${INBOX}" "${PROCESSED}" "${DISCOVERIES_DIR}" "${RUNS_DIR}"
CYCLE="$(python3 - "${ROTATION}" <<'PY'
import json, os, sys
p = sys.argv[1]; c = 0
if os.path.exists(p):
    try:
        with open(p, encoding="utf-8") as source:
            c = int(json.load(source).get("cycle", 0))
    except (OSError, ValueError, TypeError, json.JSONDecodeError) as error:
        raise SystemExit(f"invalid rotation state {p}: {error}")
print(c + 1)
PY
)"
MAX_CAND="$(cfg maxCandidates 20)"
TS="$(date -u +%Y%m%d_%H%M%S)"
RUN_DIR="$(mktemp -d "${RUNS_DIR}/cycle_${TS}_XXXXXX")"
RUN_ID="$(basename "${RUN_DIR}")"
CYCLE_LOG="${LOG_DIR}/cycle-${TS}-${RUN_ID}.log"
touch "${RUN_DIR}/.in_progress"
exec >>"${CYCLE_LOG}" 2>&1

FAILCOUNT_FILE="${STATE_DIR}/consecutive_failures"
MAX_FAILS="$(cfg maxConsecutiveFailures 5)"
finish() {
  local status=$?
  rm -f "${RUN_DIR}/.in_progress"
  if [[ "${status}" -eq 0 ]]; then
    date -u +"%Y-%m-%dT%H:%M:%SZ" > "${RUN_DIR}/.complete"
    rm -f "${FAILCOUNT_FILE}"
  else
    {
      echo "status=${status}"
      echo "failed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      echo "log=${CYCLE_LOG}"
    } > "${RUN_DIR}/.failed"
    local n; n="$(cat "${FAILCOUNT_FILE}" 2>/dev/null || echo 0)"; n=$((n + 1))
    echo "${n}" > "${FAILCOUNT_FILE}"
    if [[ "${n}" -ge "${MAX_FAILS}" ]]; then
      date -u +"%Y-%m-%dT%H:%M:%SZ" > "${STATE_DIR}/PAUSED"
      log "consecutive failures ${n} >= ${MAX_FAILS} -> circuit breaker PAUSED"
    fi
  fi
  rmdir "${LOCK_DIR}" 2>/dev/null || rm -rf "${LOCK_DIR}" 2>/dev/null || true
}
trap finish EXIT

log "cycle=${CYCLE} run=${RUN_ID} batch=$(basename "${BATCH}") log=${CYCLE_LOG}"

# discovery (existing pipeline; NO --require-discovery so empty == success)
${PIPELINE_CMD} --input "${BATCH}" --reference "${REFERENCE}" --output "${RUN_DIR}" --max "${MAX_CAND}"

# record into SQLite seen-set (fail-closed); regenerates DISCOVERIES.md from DB
NEW="$(python3 "${ROOT_DIR}/scripts/discovery_db.py" record \
  --input "${BATCH}" --run-dir "${RUN_DIR}" --db "${LEDGER_DB}" \
  --discoveries "${DISCOVERIES_MD}" --cycle "${CYCLE}" --run-id "${RUN_ID}")"
log "new_actionable=${NEW}"

# prune worker-owned logs only (never runs/; AGENTS.md non-destructive elsewhere)
MAX_LOG_FILES="$(cfg maxLogFiles 200)"
shopt -s nullglob; logs=("${LOG_DIR}"/cycle-*.log); shopt -u nullglob
if [[ ${#logs[@]} -gt ${MAX_LOG_FILES} ]]; then
  ls -1t "${LOG_DIR}"/cycle-*.log | tail -n +$((MAX_LOG_FILES + 1)) | while read -r f; do rm -f "$f"; done
fi

# Optional scientific backends degrade per job, but queue/contract failures fail
# the cycle before the input batch is archived and rotation is committed.
ENABLE_SIM="$(cfg enableSimulation false 2>/dev/null || echo false)"
if [[ "${ENABLE_SIM}" == "True" || "${ENABLE_SIM}" == "true" ]]; then
  CAND_JSON="${RUN_DIR}/sim_candidates.json"
  python3 "${ROOT_DIR}/scripts/discovery_db.py" export-new-actionable \
    --db "${LEDGER_DB}" --cycle "${CYCLE}" --out "${CAND_JSON}" \
    >"${RUN_DIR}/simulation-export.log" 2>&1 || {
      log "simulation candidate export failed; see ${RUN_DIR}/simulation-export.log"; exit 5;
    }
  ELAPSED=$(( $(date +%s) - CYCLE_STARTED_EPOCH ))
  REMAINING=$(( BUDGET_SECONDS - ELAPSED ))
  if [[ "${REMAINING}" -gt 0 ]]; then
    mkdir -p "${RUN_DIR}/sim"
    python3 "${ROOT_DIR}/scripts/sim_queue.py" run --candidates "${CAND_JSON}" \
      --run-dir "${RUN_DIR}" --config "${CONFIG}" --reference "${REFERENCE}" \
      --budget-seconds "${REMAINING}" >"${RUN_DIR}/sim/queue.log" 2>&1 || {
        log "simulation queue infrastructure failed; see ${RUN_DIR}/sim/queue.log"; exit 5;
      }
  else
    log "cycle budget exhausted before simulation; no new simulation jobs admitted"
  fi
fi

# Build the prospective rotation state first. Dashboard generation uses it so
# the published stats and the subsequently committed cursor are byte-consistent.
NEXT_ROTATION="${RUN_DIR}/rotation.next.json"
python3 - "${ROTATION}" "${NEXT_ROTATION}" "${CYCLE}" "${RUN_ID}" <<'PY'
import json, os, sys, tempfile
p, out, cycle, run_id = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
data = {}
if os.path.exists(p):
    with open(p, encoding="utf-8") as source:
        data = json.load(source)
data.update({"schemaVersion": 1, "cycle": cycle, "updatedCycle": cycle, "lastRunId": run_id})
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(out) or ".", suffix=".tmp")
with os.fdopen(fd, "w", encoding="utf-8") as fh:
    json.dump(data, fh)
os.replace(tmp, out)
PY

# Regenerate the dashboard. This is stdlib-only and required by M4, so an actual
# generator failure is a cycle failure rather than a silently missing product.
ALPHAFOLD_CACHE="${ALPHAFOLD_CACHE:-${ROOT_DIR}/data/alphafold_cache}"
python3 "${ROOT_DIR}/scripts/generate_dashboard.py" \
  --db "${LEDGER_DB}" --rotation "${NEXT_ROTATION}" --config "${CONFIG}" \
  --alphafold-cache "${ALPHAFOLD_CACHE}" --assets-dir "${DISCOVERIES_DIR}/assets" \
  --runs-dir "${RUNS_DIR}" \
  --out "${DISCOVERIES_DIR}/dashboard.html" >"${RUN_DIR}/dashboard.log" 2>&1 || {
    log "dashboard generation failed; see ${RUN_DIR}/dashboard.log"; exit 6;
  }

# Commit only after required post-processing infrastructure has succeeded. The
# rotation is committed before archival: a crash in the tiny gap causes at most
# one deduplicated replay, never a permanently unaccounted consumed batch.
mkdir -p "$(dirname "${ROTATION}")"
mv "${NEXT_ROTATION}" "${ROTATION}"
DEST="${PROCESSED}/${RUN_ID}__$(basename "${BATCH}")"
[[ -e "${DEST}" ]] && { log "processed dest exists: ${DEST}"; exit 2; }
mv "${BATCH}" "${DEST}"

# local-only notification after durable commit
if [[ "${NEW}" -gt 0 ]]; then
  if [[ -n "${NOTIFY_CMD}" ]]; then "${NOTIFY_CMD}" "${NEW} new candidate(s), cycle ${CYCLE}" || log "local notification command failed"
  else osascript -e "display notification \"${NEW} new candidate(s), cycle ${CYCLE}\" with title \"BioLab Discovery\"" 2>/dev/null || log "local notification unavailable"; fi
fi

log "cycle ${CYCLE} complete"
