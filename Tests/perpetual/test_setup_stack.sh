#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
S="${ROOT}/scripts/setup_simulation_stack.sh"
[[ -x "$S" ]] || { echo "FAIL: setup_simulation_stack.sh missing/not executable"; exit 1; }
# must refuse without ALLOW_NETWORK (multi-GB download)
set +e; bash "$S" >/dev/null 2>&1; rc=$?; set -e
[[ "$rc" -ne 0 ]] || { echo "FAIL: setup should refuse without ALLOW_NETWORK"; exit 1; }
# --plan must work offline and list what it would install
OUT="$(bash "$S" --plan 2>&1)" || { echo "FAIL: --plan should work offline"; exit 1; }
grep -qi 'esmfold\|openmm\|vina' <<<"$OUT" || { echo "FAIL: --plan should list the stack"; exit 1; }
echo "setup stack tests OK"
