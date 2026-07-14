#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

CONFIG="${CONFIG:-${ROOT_DIR}/config/worker.json}"
STATE_DIR="${STATE_DIR:-${ROOT_DIR}/state}"
RUNS_DIR="${RUNS_DIR:-${ROOT_DIR}/runs}"
DISCOVERIES_DIR="${DISCOVERIES_DIR:-${ROOT_DIR}/discoveries}"
REFERENCE="${REFERENCE:-${ROOT_DIR}/data/curated_reference/pbp_pks_reference.fasta}"
LOG_DIR="${LOG_DIR:-${ROOT_DIR}/logs}"
NOTIFY_CMD="${NOTIFY_CMD:-}"
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

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }
cfg() { python3 -c "import json;print(json.load(open('${CONFIG}')).get('$1','$2'))"; }

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

DISK_FLOOR_GB="$(cfg diskFloorGB 10)"
FREE_GB="$(df -g "${ROOT_DIR}" 2>/dev/null | awk 'NR==2 {print $4}' || true)"
if [[ -n "${FREE_GB}" && "${FREE_GB}" -lt "${DISK_FLOOR_GB}" ]]; then
  log "disk free ${FREE_GB}GB < floor ${DISK_FLOOR_GB}GB -> pause"; exit 0
fi

MAX_WS_BYTES="$(cfg maxWorkspaceBytes 21474836480)"
if [[ -d "${RUNS_DIR}" ]]; then
  USED_KB="$(du -sk "${RUNS_DIR}" 2>/dev/null | awk '{print $1}' || true)"
  if [[ -n "${USED_KB:-}" && $(( USED_KB * 1024 )) -ge "${MAX_WS_BYTES}" ]]; then
    log "workspace ${USED_KB}KB >= quota -> pause (prune runs/ manually)"; exit 0
  fi
fi

MANIFEST="$(dirname "${CONFIG}")/approved_manifest.json"

# batch present? (nullglob array; no error-hiding find|head)
shopt -s nullglob; batches=("${INBOX}"/*.fasta); shopt -u nullglob
if [[ ${#batches[@]} -eq 0 ]]; then
  ENABLE_NET="$(cfg enableNetwork false 2>/dev/null || echo false)"
  if [[ "${ENABLE_NET}" == "True" || "${ENABLE_NET}" == "true" ]]; then
    # network refill is FAIL-CLOSED: require an approved manifest matching BOTH the
    # curated reference and the approved query set before any fetch.
    QR="$(dirname "${CONFIG}")/query_rotation.json"
    if [[ ! -f "${MANIFEST}" ]]; then log "network refill requires approved_manifest.json (absent) -> abort"; exit 3; fi
    python3 - "${MANIFEST}" "${REFERENCE}" "${QR}" <<'PY' || { echo "manifest/query-scope mismatch -> abort" >&2; exit 3; }
import hashlib, json, sys
man = json.load(open(sys.argv[1]))
def d(p): return "sha256:" + hashlib.sha256(open(p, "rb").read()).hexdigest()
ok = man.get("referenceSha256") == d(sys.argv[2]) and man.get("querySetDigest") == d(sys.argv[3])
sys.exit(0 if ok else 1)
PY
    mkdir -p "${INBOX}"
    log "inbox empty + network enabled -> fetching UniProt page"
    python3 "${ROOT_DIR}/scripts/fetch_uniprot.py" --config "${CONFIG}" \
      --query-rotation "${QR}" --rotation "${ROTATION}" --inbox "${INBOX}" || { log "fetch failed"; exit 4; }
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
    try: c = int(json.load(open(p)).get("cycle", 0))
    except Exception: c = 0
print(c + 1)
PY
)"
MAX_CAND="$(cfg maxCandidates 20)"
TS="$(date -u +%Y%m%d_%H%M%S)"
RUN_DIR="$(mktemp -d "${RUNS_DIR}/cycle_${TS}_XXXXXX")"
RUN_ID="$(basename "${RUN_DIR}")"
touch "${RUN_DIR}/.in_progress"

FAILCOUNT_FILE="${STATE_DIR}/consecutive_failures"
MAX_FAILS="$(cfg maxConsecutiveFailures 5)"
finish() {
  local status=$?
  rm -f "${RUN_DIR}/.in_progress"
  if [[ "${status}" -eq 0 ]]; then
    date -u +"%Y-%m-%dT%H:%M:%SZ" > "${RUN_DIR}/.complete"
    rm -f "${FAILCOUNT_FILE}"
  else
    echo "status=${status}" > "${RUN_DIR}/.failed"
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

log "cycle=${CYCLE} run=${RUN_ID} batch=$(basename "${BATCH}")"

# discovery (existing pipeline; NO --require-discovery so empty == success)
${PIPELINE_CMD} --input "${BATCH}" --reference "${REFERENCE}" --output "${RUN_DIR}" --max "${MAX_CAND}"

# record into SQLite seen-set (fail-closed); regenerates DISCOVERIES.md from DB
NEW="$(python3 "${ROOT_DIR}/scripts/discovery_db.py" record \
  --input "${BATCH}" --run-dir "${RUN_DIR}" --db "${LEDGER_DB}" \
  --discoveries "${DISCOVERIES_MD}" --cycle "${CYCLE}" --run-id "${RUN_ID}")"
log "new_actionable=${NEW}"

# non-overwriting archival of the consumed batch
DEST="${PROCESSED}/${RUN_ID}__$(basename "${BATCH}")"
[[ -e "${DEST}" ]] && { log "processed dest exists: ${DEST}"; exit 2; }
mv "${BATCH}" "${DEST}"

# atomic rotation advance (forward-compatible keys)
python3 - "${ROTATION}" "${CYCLE}" "${RUN_ID}" <<'PY'
import json, os, sys, tempfile
p, cycle, run_id = sys.argv[1], int(sys.argv[2]), sys.argv[3]
data = {}
if os.path.exists(p):
    try: data = json.load(open(p))
    except Exception: data = {}
data.update({"schemaVersion": 1, "cycle": cycle, "updatedCycle": cycle, "lastRunId": run_id})
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(p) or ".", suffix=".tmp")
with os.fdopen(fd, "w") as fh: json.dump(data, fh)
os.replace(tmp, p)
PY

# local-only notification
if [[ "${NEW}" -gt 0 ]]; then
  if [[ -n "${NOTIFY_CMD}" ]]; then "${NOTIFY_CMD}" "${NEW} new candidate(s), cycle ${CYCLE}" || true
  else osascript -e "display notification \"${NEW} new candidate(s), cycle ${CYCLE}\" with title \"BioLab Discovery\"" 2>/dev/null || true; fi
fi

# prune worker-owned logs only (never runs/; AGENTS.md non-destructive elsewhere)
MAX_LOG_FILES="$(cfg maxLogFiles 200)"
shopt -s nullglob; logs=("${LOG_DIR}"/cycle-*.log); shopt -u nullglob
if [[ ${#logs[@]} -gt ${MAX_LOG_FILES} ]]; then
  ls -1t "${LOG_DIR}"/cycle-*.log | tail -n +$((MAX_LOG_FILES + 1)) | while read -r f; do rm -f "$f"; done
fi

# regenerate the self-contained dashboard (never fail the cycle over visualization)
ALPHAFOLD_CACHE="${ALPHAFOLD_CACHE:-${ROOT_DIR}/data/alphafold_cache}"
python3 "${ROOT_DIR}/scripts/generate_dashboard.py" \
  --db "${LEDGER_DB}" --rotation "${ROTATION}" --config "${CONFIG}" \
  --alphafold-cache "${ALPHAFOLD_CACHE}" --assets-dir "${DISCOVERIES_DIR}/assets" \
  --out "${DISCOVERIES_DIR}/dashboard.html" >/dev/null 2>&1 || log "dashboard generation skipped (non-fatal)"

log "cycle ${CYCLE} complete"
