#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ID=""
ALLOW_NETWORK=0

for arg in "$@"; do
  case "${arg}" in
    --allow-network)
      ALLOW_NETWORK=1
      ;;
    *)
      if [[ -z "${RUN_ID}" ]]; then
        RUN_ID="${arg}"
      else
        echo "Unexpected argument: ${arg}" >&2
        exit 2
      fi
      ;;
  esac
done

RUN_ID="${RUN_ID:-autonomous_discovery_$(date +%Y%m%d_%H%M%S)}"
RUN_DIR="${ROOT_DIR}/runs/${RUN_ID}"
LOG_DIR="${ROOT_DIR}/logs"
LOG_FILE="${LOG_DIR}/${RUN_ID}.log"
CACHE_DIR="${ROOT_DIR}/data/alphafold_cache"
QUERY_FASTA="${ROOT_DIR}/data/public_probe/unreviewed_uncharacterized_bacteria_200.fasta"
REFERENCE_FASTA="${ROOT_DIR}/data/curated_reference/pbp_pks_reference.fasta"

mkdir -p "${LOG_DIR}"
exec > >(tee -a "${LOG_FILE}") 2>&1

if [[ -d "${RUN_DIR}" ]] && find "${RUN_DIR}" -mindepth 1 -maxdepth 1 | read -r _; then
  echo "Run directory already contains files: ${RUN_DIR}" >&2
  echo "Use a new run id to avoid overwriting existing results." >&2
  exit 2
fi

RUNNING_JOBS="$(pgrep -fl 'BioLabExplorer(Pipeline|StructureCheck)' || true)"
if [[ -n "${RUNNING_JOBS}" ]]; then
  echo "Another BioLabExplorer analysis job appears to be running:" >&2
  echo "${RUNNING_JOBS}" >&2
  exit 2
fi

mkdir -p "${RUN_DIR}"
touch "${RUN_DIR}/.in_progress"

finish() {
  local status=$?
  rm -f "${RUN_DIR}/.in_progress"
  if [[ "${status}" -eq 0 ]]; then
    date -u +"%Y-%m-%dT%H:%M:%SZ" > "${RUN_DIR}/.complete"
  else
    {
      echo "status=${status}"
      date -u +"failed_at=%Y-%m-%dT%H:%M:%SZ"
      echo "log=${LOG_FILE}"
    } > "${RUN_DIR}/.failed"
  fi
  exit "${status}"
}
trap finish EXIT

if [[ ! -s "${REFERENCE_FASTA}" ]]; then
  echo "Curated local reference FASTA is missing: ${REFERENCE_FASTA}" >&2
  exit 2
fi

if [[ ! -s "${QUERY_FASTA}" && "${ALLOW_NETWORK}" != "1" ]]; then
  echo "Query FASTA is missing: ${QUERY_FASTA}" >&2
  echo "Re-run with --allow-network to fetch the public UniProt probe dataset." >&2
  exit 2
fi

cd "${ROOT_DIR}"

echo "BioLabExplorer autonomous discovery"
echo "run_id=${RUN_ID}"
echo "run_dir=${RUN_DIR}"
echo "log=${LOG_FILE}"
echo "network=${ALLOW_NETWORK}"
echo

echo "== Static/runtime checks =="
swift run BioLabExplorerChecks

echo
echo "== Discovery probe =="
if [[ "${ALLOW_NETWORK}" == "1" ]]; then
  scripts/run_public_probe.sh "${RUN_ID}" --allow-network
else
  scripts/run_public_probe.sh "${RUN_ID}"
fi

echo
echo "== Native structure validation =="
if [[ "${ALLOW_NETWORK}" == "1" ]]; then
  swift run BioLabExplorerStructureCheck --run "${RUN_DIR}" --cache "${CACHE_DIR}" --allow-network
else
  swift run BioLabExplorerStructureCheck --run "${RUN_DIR}" --cache "${CACHE_DIR}"
fi

echo
echo "== Achievement report =="
ACHIEVEMENT_REPORT="$(swift run BioLabExplorerAchievementReport --run "${RUN_DIR}")"
echo "${ACHIEVEMENT_REPORT}"

echo
echo "== App package =="
scripts/package_app.sh

echo
echo "Autonomous discovery complete"
echo "achievement_report=${ACHIEVEMENT_REPORT}"
echo "run_dir=${RUN_DIR}"
echo "app=${ROOT_DIR}/dist/BioLab Explorer.app"
