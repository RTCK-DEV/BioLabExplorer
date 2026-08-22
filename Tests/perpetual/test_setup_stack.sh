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
grep -qi 'meeko' <<<"$OUT" || { echo "FAIL: --plan should list receptor preparation"; exit 1; }
grep -qi 'pdbfixer' <<<"$OUT" || { echo "FAIL: --plan should list structure repair"; exit 1; }
echo "setup stack tests OK"

F="${ROOT}/scripts/setup_esmfold_hf.sh"
[[ -x "$F" ]] || { echo "FAIL: setup_esmfold_hf.sh missing/not executable"; exit 1; }
set +e; bash "$F" >/dev/null 2>&1; rc=$?; set -e
[[ "$rc" -ne 0 ]] || { echo "FAIL: ESMFold setup should refuse without ALLOW_NETWORK"; exit 1; }
FOLD_PLAN="$(bash "$F" --plan 2>&1)" || { echo "FAIL: ESMFold --plan should work offline"; exit 1; }
grep -qi 'revision-pinned\|revision' <<<"$FOLD_PLAN" || { echo "FAIL: ESMFold plan must mention model pinning"; exit 1; }
grep -qi 'MPS' <<<"$FOLD_PLAN" || { echo "FAIL: ESMFold plan must mention MPS"; exit 1; }
echo "ESMFold setup tests OK"
