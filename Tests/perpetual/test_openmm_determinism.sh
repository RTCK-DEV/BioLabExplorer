#!/usr/bin/env bash
# OpenMM relaxation must be byte-for-byte reproducible, and its metrics must
# report what actually happened.
#
# The CPU platform sums forces per thread and reduces them in completion order,
# so a multi-threaded context lands on a different minimum every run. The
# project claims single-threaded execution for exactly this reason and
# test_config.sh asserts openmmCpuThreads == 1 — but nothing applied it: the
# thread count was only ever written into the metrics file. Two runs of the same
# structure differed by ~200 kJ/mol while both reported cpuThreads: 1.
#
# Needs OpenMM. Set SIM_BIN_DIR to the environment that has it, or the test
# skips itself.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

find_python_with_openmm() {
  local candidates=()
  [[ -n "${SIM_BIN_DIR:-}" ]] && candidates+=("${SIM_BIN_DIR}/python" "${SIM_BIN_DIR}/python3")
  [[ -n "${SIM_PYTHON:-}" ]] && candidates+=("${SIM_PYTHON}")
  candidates+=("python3")
  for conda_env in "${HOME}/miniforge3/envs/biolab-sim/bin/python" \
                   /opt/homebrew/Caskroom/miniforge/base/envs/biolab-sim/bin/python \
                   "${HOME}/miniconda3/envs/biolab-sim/bin/python"; do
    candidates+=("${conda_env}")
  done
  for candidate in "${candidates[@]}"; do
    if command -v "${candidate}" > /dev/null 2>&1 || [[ -x "${candidate}" ]]; then
      if "${candidate}" -c "import openmm, pdbfixer" > /dev/null 2>&1; then
        echo "${candidate}"
        return 0
      fi
    fi
  done
  return 1
}

if ! PYTHON="$(find_python_with_openmm)"; then
  echo "openmm determinism tests SKIPPED (no python with openmm+pdbfixer)"
  exit 0
fi

STRUCTURE="${ROOT}/data/alphafold_cache/AF-O66874-F1-model_v6.pdb"
[[ -f "${STRUCTURE}" ]] || { echo "openmm determinism tests SKIPPED (no cached structure)"; exit 0; }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

relax() {  # $1 = output tag, remaining args appended to the command
  local tag="$1"; shift
  "${PYTHON}" "${ROOT}/scripts/openmm_relax.py" \
    --input "${STRUCTURE}" \
    --output "${WORK}/${tag}.pdb" \
    --metrics "${WORK}/${tag}.json" \
    --platform CPU --max-iterations 120 "$@" > /dev/null 2>&1
}

echo "openmm: relaxing the same structure twice with default settings"
relax run_a
relax run_b

python3 - "${WORK}" <<'PY'
import hashlib, json, os, sys

work = sys.argv[1]

def digest(tag):
    with open(os.path.join(work, f"{tag}.pdb"), "rb") as handle:
        return hashlib.sha256(handle.read()).hexdigest()

def metrics(tag):
    with open(os.path.join(work, f"{tag}.json"), encoding="utf-8") as handle:
        return json.load(handle)

a, b = metrics("run_a"), metrics("run_b")

assert digest("run_a") == digest("run_b"), (
    "two default relaxations produced different PDBs; the CPU thread count is "
    "not being applied"
)
assert a["finalPotentialEnergyKJPerMol"] == b["finalPotentialEnergyKJPerMol"], (
    f"final energies differ: {a['finalPotentialEnergyKJPerMol']} vs "
    f"{b['finalPotentialEnergyKJPerMol']}"
)
print("openmm: two default runs are byte-identical")

# The metrics must describe the context that ran, not the value we hoped for.
assert a["cpuThreads"] == 1, f"default run reported cpuThreads={a['cpuThreads']}"
assert a["platformProperties"].get("Threads") == "1", a["platformProperties"]
assert a["bitReproducible"] is True, a["bitReproducible"]
# An explicit CPU request that succeeded is not a fallback.
assert a["usedCpuFallback"] is False, a["usedCpuFallback"]
assert a["outputSha256"] if "outputSha256" in a else True
print("openmm: metrics report the thread count the context actually held")
PY

echo "openmm: multi-threaded runs must declare themselves non-reproducible"
relax run_multi --cpu-threads 4

python3 - "${WORK}" <<'PY'
import json, os, sys
work = sys.argv[1]
with open(os.path.join(work, "run_multi.json"), encoding="utf-8") as handle:
    m = json.load(handle)
assert m["cpuThreads"] == 4, f"reported cpuThreads={m['cpuThreads']}, expected 4"
assert m["platformProperties"].get("Threads") == "4", m["platformProperties"]
assert m["bitReproducible"] is False, "4 threads cannot be bit reproducible"
print("openmm: a 4-thread run reports 4 threads and bitReproducible=false")
PY

# "auto" must record every attempt and must not call CPU a fallback.
echo "openmm: auto platform selection"
"${PYTHON}" "${ROOT}/scripts/openmm_relax.py" \
  --input "${STRUCTURE}" --output "${WORK}/run_auto.pdb" --metrics "${WORK}/run_auto.json" \
  --platform auto --allow-cpu-fallback --max-iterations 120 > /dev/null 2>&1

python3 - "${WORK}" <<'PY'
import json, os, sys
work = sys.argv[1]
with open(os.path.join(work, "run_auto.json"), encoding="utf-8") as handle:
    m = json.load(handle)
assert m["requestedPlatform"] == "auto", m["requestedPlatform"]
attempts = m["platformAttempts"]
assert attempts, "auto must record what it tried"
assert attempts[-1]["status"] == "selected", attempts
tried = [a["platform"] for a in attempts]
assert tried[0] == "CUDA", f"auto must try accelerated platforms first, got {tried}"
for attempt in attempts[:-1]:
    assert attempt["status"] == "failed" and attempt.get("reason"), attempt
assert m["usedCpuFallback"] is False, (
    "auto has no requested platform to fall back from; CPU is a selection"
)
assert m["platform"] in ("CUDA", "OpenCL", "CPU"), m["platform"]
print(f"openmm: auto tried {' -> '.join(tried)} and selected {m['platform']}")
PY

echo "openmm determinism tests OK"
