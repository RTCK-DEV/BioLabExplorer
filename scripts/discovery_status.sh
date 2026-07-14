#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${STATE_DIR:-${ROOT_DIR}/state}"
DISCOVERIES_DIR="${DISCOVERIES_DIR:-${ROOT_DIR}/discoveries}"
ROTATION="${STATE_DIR}/rotation.json"; LEDGER_DB="${DISCOVERIES_DIR}/ledger.db"

CYCLES=0; LAST="none"
if [[ -f "${ROTATION}" ]]; then
  CYCLES="$(python3 -c "import json;print(json.load(open('${ROTATION}')).get('cycle',0))" 2>/dev/null || echo 0)"
  LAST="$(python3 -c "import json;print(json.load(open('${ROTATION}')).get('lastRunId') or 'none')" 2>/dev/null || echo none)"
fi
DISCOVERIES=0
if [[ -f "${LEDGER_DB}" ]]; then
  DISCOVERIES="$(python3 "${ROOT_DIR}/scripts/discovery_db.py" count-actionable --db "${LEDGER_DB}" 2>/dev/null || echo 0)"
fi
STOP="no"; [[ -f "${STATE_DIR}/STOP" ]] && STOP="yes"
FREE_GB="$(df -g "${ROOT_DIR}" 2>/dev/null | awk 'NR==2 {print $4}')"; FREE_GB="${FREE_GB:-unknown}"

echo "BioLab Perpetual Discovery — status"
echo "cycles=${CYCLES}"
echo "discoveries=${DISCOVERIES}"
echo "last_run=${LAST}"
echo "stop=${STOP}"
echo "network=off"
echo "disk_free_gb=${FREE_GB}"
