#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DATA_DIR="${ROOT_DIR}/data/public_probe"
REFERENCE_FASTA="${ROOT_DIR}/data/curated_reference/pbp_pks_reference.fasta"
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
RUN_ID="${RUN_ID:-public_probe_$(date +%Y%m%d_%H%M%S)}"
RUN_DIR="${ROOT_DIR}/runs/${RUN_ID}"
QUERY_FASTA="${DATA_DIR}/unreviewed_uncharacterized_bacteria_200.fasta"

mkdir -p "${DATA_DIR}" "${RUN_DIR}"

if [[ ! -s "${REFERENCE_FASTA}" ]]; then
  echo "Curated local reference FASTA is missing: ${REFERENCE_FASTA}" >&2
  exit 2
fi

if [[ ! -s "${QUERY_FASTA}" ]]; then
  if [[ "${ALLOW_NETWORK}" != "1" ]]; then
    echo "Query FASTA is missing: ${QUERY_FASTA}" >&2
    echo "Re-run with --allow-network to fetch the public UniProt probe dataset." >&2
    exit 2
  fi
  curl -L --fail --retry 3 --get 'https://rest.uniprot.org/uniprotkb/search' \
    --data-urlencode 'query=(reviewed:false) AND (protein_name:"Uncharacterized protein") AND (taxonomy_id:2)' \
    --data-urlencode 'format=fasta' \
    --data-urlencode 'size=200' \
    -o "${QUERY_FASTA}"
fi

cd "${ROOT_DIR}"
swift run BioLabExplorerPipeline \
  --input "${QUERY_FASTA}" \
  --reference "${REFERENCE_FASTA}" \
  --output "${RUN_DIR}" \
  --max 20 \
  --require-discovery

echo "${RUN_DIR}"
