#!/usr/bin/env bash
# Fetch and index the Pfam-A profile-HMM database for the optional domain adapter.
#
# Offline by default, like every other network-touching script here: it refuses
# unless ALLOW_NETWORK=1, only talks to the pinned EBI host over HTTPS, and
# verifies the archive against the checksum file EBI publishes beside it.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST_DIR="${PFAM_DIR:-${ROOT_DIR}/data/pfam}"
RELEASE="${PFAM_RELEASE:-current_release}"
HOST_ALLOW="${PFAM_HOST:-ftp.ebi.ac.uk}"
BASE_URL="${PFAM_BASE_URL:-https://ftp.ebi.ac.uk/pub/databases/Pfam/${RELEASE}}"
ARCHIVE_NAME="Pfam-A.hmm.gz"
HMM="${DEST_DIR}/Pfam-A.hmm"
MANIFEST="${DEST_DIR}/pfam_manifest.json"

plan() {
  cat <<PLAN
Pfam domain database plan
  source   : ${BASE_URL}/${ARCHIVE_NAME}
  verify   : md5 against ${BASE_URL}/md5_checksums (override with PFAM_SHA256 for a hard pin)
  install  : ${HMM}          (~1.5 GB uncompressed, ~400 MB download)
  index    : hmmpress ${HMM} (adds .h3f/.h3i/.h3m/.h3p, roughly another 1.5 GB)
  manifest : ${MANIFEST}     (release, sizes and digests actually obtained)

Used only by the optional Pfam adapter:
  BioLabExplorerPipeline --input q.fasta --pfam
Nothing else in this project needs it, and every default workflow runs without it.

Reproducible installs: pin the release, e.g. PFAM_RELEASE=Pfam37.0
Re-runnable (idempotent): an already indexed database is left alone.
PLAN
}

if [[ "${1:-}" == "--plan" ]]; then plan; exit 0; fi

host_of() { printf '%s' "$1" | sed -E 's#^https?://([^/]+).*#\1#'; }

if [[ "${BASE_URL}" != https://* || "$(host_of "${BASE_URL}")" != "${HOST_ALLOW}" ]]; then
  echo "setup_pfam: host $(host_of "${BASE_URL}") not allowed (${HOST_ALLOW})" >&2
  exit 2
fi

command -v hmmpress >/dev/null 2>&1 || {
  echo "setup_pfam: hmmpress not found. Install HMMER first (brew install hmmer)." >&2
  exit 2
}

if [[ -f "${HMM}" ]]; then
  missing=0
  for suffix in h3f h3i h3m h3p; do
    [[ -f "${HMM}.${suffix}" ]] || missing=1
  done
  if [[ "${missing}" -eq 0 ]]; then
    echo "setup_pfam: ${HMM} is already present and indexed; nothing to do."
    exit 0
  fi
  echo "setup_pfam: ${HMM} exists but is not indexed; running hmmpress only."
  hmmpress "${HMM}"
  exit 0
fi

if [[ "${ALLOW_NETWORK:-}" != "1" ]]; then
  echo "setup_pfam: refusing — this downloads roughly 400 MB and expands to ~3 GB." >&2
  echo "Review the plan first:  scripts/setup_pfam.sh --plan" >&2
  echo "Then run:               ALLOW_NETWORK=1 scripts/setup_pfam.sh" >&2
  exit 2
fi

plan
mkdir -p "${DEST_DIR}"
WORK="$(mktemp -d)"
cleanup() { rm -rf "${WORK}"; }
trap cleanup EXIT

md5_of() {
  if command -v md5sum >/dev/null 2>&1; then md5sum "$1" | awk '{print $1}'
  else md5 -q "$1"; fi
}
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

echo "== downloading ${ARCHIVE_NAME} =="
curl --fail --location --proto '=https' --tlsv1.2 \
  --output "${WORK}/${ARCHIVE_NAME}" "${BASE_URL}/${ARCHIVE_NAME}"

ACTUAL_SHA256="$(sha256_of "${WORK}/${ARCHIVE_NAME}")"
if [[ -n "${PFAM_SHA256:-}" ]]; then
  if [[ "${ACTUAL_SHA256}" != "${PFAM_SHA256}" ]]; then
    echo "setup_pfam: sha256 mismatch: got ${ACTUAL_SHA256}, expected ${PFAM_SHA256}" >&2
    exit 2
  fi
  echo "sha256 pin verified: ${ACTUAL_SHA256}"
fi

echo "== verifying against published checksums =="
if curl --fail --silent --location --proto '=https' --tlsv1.2 \
     --output "${WORK}/md5_checksums" "${BASE_URL}/md5_checksums"; then
  EXPECTED_MD5="$(awk -v name="${ARCHIVE_NAME}" '$2 == name || $2 == "*"name {print $1}' "${WORK}/md5_checksums" | head -1)"
  ACTUAL_MD5="$(md5_of "${WORK}/${ARCHIVE_NAME}")"
  if [[ -z "${EXPECTED_MD5}" ]]; then
    echo "setup_pfam: ${ARCHIVE_NAME} is not listed in md5_checksums" >&2
    exit 2
  fi
  if [[ "${ACTUAL_MD5}" != "${EXPECTED_MD5}" ]]; then
    echo "setup_pfam: md5 mismatch: got ${ACTUAL_MD5}, expected ${EXPECTED_MD5}" >&2
    exit 2
  fi
  echo "md5 verified: ${ACTUAL_MD5}"
else
  echo "setup_pfam: could not fetch md5_checksums; refusing an unverified database." >&2
  echo "Re-run with an explicit PFAM_SHA256=<digest> to accept it deliberately." >&2
  [[ -n "${PFAM_SHA256:-}" ]] || exit 2
  ACTUAL_MD5="unverified"
  EXPECTED_MD5="unverified"
fi

RESOLVED_RELEASE="${RELEASE}"
if curl --fail --silent --location --proto '=https' --tlsv1.2 \
     --output "${WORK}/Pfam.version.gz" "${BASE_URL}/Pfam.version.gz"; then
  RESOLVED_RELEASE="$(gunzip -c "${WORK}/Pfam.version.gz" | tr '\n' ' ' | sed 's/  */ /g' | sed 's/ *$//')"
fi
echo "release: ${RESOLVED_RELEASE}"

echo "== expanding =="
gunzip -c "${WORK}/${ARCHIVE_NAME}" > "${WORK}/Pfam-A.hmm"
head -1 "${WORK}/Pfam-A.hmm" | grep -q '^HMMER3' || {
  echo "setup_pfam: expanded file is not a HMMER3 profile database" >&2
  exit 2
}
mv "${WORK}/Pfam-A.hmm" "${HMM}"

echo "== indexing (hmmpress) =="
hmmpress "${HMM}"

python3 - "${MANIFEST}" "${RESOLVED_RELEASE}" "${BASE_URL}/${ARCHIVE_NAME}" \
  "${ACTUAL_MD5}" "${ACTUAL_SHA256}" "${HMM}" <<'PY'
import json, os, sys
manifest_path, release, url, md5, sha256, hmm = sys.argv[1:7]
manifest = {
    "schemaVersion": 1,
    "release": release,
    "sourceUrl": url,
    "archiveMd5": md5,
    "archiveSha256": "sha256:" + sha256,
    "hmmPath": os.path.relpath(hmm, os.path.dirname(os.path.dirname(manifest_path))),
    "hmmBytes": os.path.getsize(hmm),
}
with open(manifest_path, "w", encoding="utf-8") as handle:
    json.dump(manifest, handle, indent=2, sort_keys=True)
    handle.write("\n")
print(json.dumps(manifest, indent=2, sort_keys=True))
PY

echo "== done =="
echo "Pfam is ready. The adapter finds it automatically at data/pfam/Pfam-A.hmm, or:"
echo "  export BIOLAB_PFAM_DB=\"${HMM}\""
echo "  swift run BioLabExplorerPipeline --input query.fasta --pfam"
