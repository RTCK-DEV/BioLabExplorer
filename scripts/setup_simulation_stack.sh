#!/usr/bin/env bash
set -euo pipefail
ENV_NAME="${SIM_ENV_NAME:-biolab-sim}"

plan() {
  cat <<'PLAN'
Simulation stack plan (conda/mamba env: biolab-sim)
  - openmm + pdbfixer        -> structure repair + energy minimization
  - vina + meeko             -> docking + receptor/ligand PDBQT preparation
  - foldseek                 -> structure search
  (mmseqs2/HMMER are detected from PATH and are not reinstalled here)
  NOT installed: ESMFold — Meta's supported fair-esm ESMFold environment requires
  Python <=3.9 plus CUDA/NVCC/OpenFold; this Apple Silicon installer does not claim
  an unverified MPS path. sim_queue still detects a separately supplied esm-fold CLI.
  NOT installed: ColabFold — needs ~940GB MSA DB / ~128GB RAM for local MSA.
  NOT active: External MSA Store/ColabFold reserved config keys (post-M5 design only).
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
if ! "${CONDA}" run -n "${ENV_NAME}" python --version >/dev/null 2>&1; then
  "${CONDA}" create -y -n "${ENV_NAME}" python=3.11
fi
"${CONDA}" install -y -n "${ENV_NAME}" -c conda-forge openmm pdbfixer
"${CONDA}" install -y -n "${ENV_NAME}" -c conda-forge -c bioconda 'setuptools<81' vina meeko foldseek
"${CONDA}" run -n "${ENV_NAME}" python -m openmm.testInstallation
"${CONDA}" run -n "${ENV_NAME}" python -c 'import pdbfixer; print("pdbfixer OK")'
"${CONDA}" run -n "${ENV_NAME}" vina --version
"${CONDA}" run -n "${ENV_NAME}" mk_prepare_receptor.py --help >/dev/null
"${CONDA}" run -n "${ENV_NAME}" mk_prepare_ligand.py --help >/dev/null
"${CONDA}" run -n "${ENV_NAME}" foldseek version
echo "== done =="
echo "Point the worker at this env's bin so sim_queue can find the tools:"
echo "  SIM_BIN_DIR=\"\$(${CONDA} run -n ${ENV_NAME} python -c 'import sys,os;print(os.path.dirname(sys.executable))')\""
echo "Then set enableSimulation: true in config/worker.json"
