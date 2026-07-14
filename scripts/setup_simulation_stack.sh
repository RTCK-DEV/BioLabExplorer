#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_NAME="${SIM_ENV_NAME:-biolab-sim}"

plan() {
  cat <<'PLAN'
Simulation stack plan (conda/mamba env: biolab-sim)
  - pytorch (MPS build)      -> ESMFold folding on Apple GPU
  - fair-esm                 -> ESMFold weights/API
  - openmm                   -> MD relaxation (CPU; set thread limits)
  - autodock-vina            -> docking
  (already present: mmseqs2, HMMER, bundled Foldseek)
  NOT installed: ColabFold — needs ~940GB MSA DB / ~128GB RAM for local MSA.
  Optional: mount an External MSA Store with PRECOMPUTED a3m and set
  externalMsaStorePath + enableColabFold to fold from precomputed MSAs only
  (the public MSA server is never contacted).
Download size: multi-GB. Re-runnable (idempotent).
PLAN
}

if [[ "${1:-}" == "--plan" ]]; then plan; exit 0; fi

if [[ "${ALLOW_NETWORK:-}" != "1" ]]; then
  echo "setup_simulation_stack: refusing — this downloads multiple GB." >&2
  echo "Review the plan first:  scripts/setup_simulation_stack.sh --plan" >&2
  echo "Then run:               ALLOW_NETWORK=1 scripts/setup_simulation_stack.sh" >&2
  exit 2
fi

command -v mamba >/dev/null 2>&1 && CONDA=mamba || CONDA=conda
command -v "${CONDA}" >/dev/null 2>&1 || { echo "setup: conda/mamba not found" >&2; exit 2; }
plan
echo "== creating/updating env ${ENV_NAME} =="
"${CONDA}" create -y -n "${ENV_NAME}" python=3.11 || true
"${CONDA}" install -y -n "${ENV_NAME}" -c conda-forge openmm || echo "openmm install failed (continuing)"
"${CONDA}" install -y -n "${ENV_NAME}" -c conda-forge -c bioconda autodock-vina || echo "vina install failed (continuing)"
"${CONDA}" run -n "${ENV_NAME}" pip install torch fair-esm || echo "torch/fair-esm install failed (continuing)"
echo "== done =="
echo "Point the worker at this env's bin so sim_queue can find the tools:"
echo "  SIM_BIN_DIR=\"\$(${CONDA} run -n ${ENV_NAME} python -c 'import sys,os;print(os.path.dirname(sys.executable))')\""
echo "Then set enableSimulation: true in config/worker.json"
