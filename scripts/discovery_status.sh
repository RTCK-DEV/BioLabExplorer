#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${STATE_DIR:-${ROOT_DIR}/state}"
DISCOVERIES_DIR="${DISCOVERIES_DIR:-${ROOT_DIR}/discoveries}"
CONFIG="${CONFIG:-${ROOT_DIR}/config/worker.json}"
ROTATION="${STATE_DIR}/rotation.json"; LEDGER_DB="${DISCOVERIES_DIR}/ledger.db"

CYCLES=0; LAST="none"
if [[ -f "${ROTATION}" ]]; then
  read -r CYCLES LAST < <(python3 - "${ROTATION}" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as source:
    data = json.load(source)
print(int(data.get("cycle", 0)), data.get("lastRunId") or "none")
PY
  ) || { echo "status: invalid rotation state: ${ROTATION}" >&2; exit 2; }
fi
DISCOVERIES=0
if [[ -f "${LEDGER_DB}" ]]; then
  DISCOVERIES="$(python3 "${ROOT_DIR}/scripts/discovery_db.py" count-actionable --db "${LEDGER_DB}")" \
    || { echo "status: cannot read ledger: ${LEDGER_DB}" >&2; exit 2; }
fi
STOP="no"; [[ -f "${STATE_DIR}/STOP" ]] && STOP="yes"
PAUSED="no"; [[ -f "${STATE_DIR}/PAUSED" ]] && PAUSED="yes"
LOCKED="no"; [[ -d "${STATE_DIR}/.lock" ]] && LOCKED="yes"
FREE_GB="$(df -g "${ROOT_DIR}" | awk 'NR==2 {print $4}')" \
  || { echo "status: disk capacity probe failed" >&2; exit 2; }
NET="$(python3 - "${CONFIG}" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as source:
    print("on" if json.load(source).get("enableNetwork") else "off")
PY
)" || { echo "status: invalid config: ${CONFIG}" >&2; exit 2; }

echo "BioLab Perpetual Discovery — status"
echo "cycles=${CYCLES}"
echo "discoveries=${DISCOVERIES}"
echo "last_run=${LAST}"
echo "stop=${STOP}"
echo "paused=${PAUSED}"
echo "locked=${LOCKED}"
echo "network=${NET}"
echo "disk_free_gb=${FREE_GB}"
