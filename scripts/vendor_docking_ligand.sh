#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="${ROOT}/config/docking_manifest.json"
if [[ "${ALLOW_NETWORK:-}" != "1" ]]; then
  echo "vendor_docking_ligand: refusing network download; set ALLOW_NETWORK=1 after manifest review" >&2
  exit 2
fi
PYTHON="${SIM_BIN_DIR:+${SIM_BIN_DIR}/python}"
PYTHON="${PYTHON:-python3}"
IFS=$'\t' read -r URL REL_SDF EXPECTED REL_PDBQT PREPARED_EXPECTED < <("${PYTHON}" - "${MANIFEST}" <<'PY'
import json, sys
m=json.load(open(sys.argv[1]))["ligand"]
print("\t".join((m["sourceUrl"], m["sourceSdf"], m["sourceSha256"].removeprefix("sha256:"),
                 m["preparedPdbqt"], m["preparedSha256"].removeprefix("sha256:"))))
PY
)
SDF="${ROOT}/${REL_SDF}"; PDBQT="${ROOT}/${REL_PDBQT}"
mkdir -p "$(dirname "${SDF}")"
TMP="$(mktemp "${TMPDIR:-/tmp}/biolab-ligand.XXXXXX")"
trap 'rm -f "${TMP}"' EXIT
curl --fail --silent --show-error --location --proto '=https' --max-redirs 3 "${URL}" -o "${TMP}"
"${PYTHON}" - "${TMP}" <<'PY'
import re, sys
path = sys.argv[1]
with open(path, encoding="utf-8", newline="") as fh:
    lines = fh.readlines()
if len(lines) < 4 or not re.fullmatch(r"\s*-OEChem-\d+3D\r?\n", lines[1]):
    raise SystemExit("unexpected PubChem SDF header; refusing canonicalization")
newline = "\r\n" if lines[1].endswith("\r\n") else "\n"
lines[1] = "  BioLabExplorer-PubChem-CID5904-3D" + newline
with open(path, "w", encoding="utf-8", newline="") as fh:
    fh.writelines(lines)
PY
ACTUAL="$(shasum -a 256 "${TMP}" | awk '{print $1}')"
[[ "${ACTUAL}" == "${EXPECTED}" ]] || { echo "ligand digest mismatch: expected=${EXPECTED} actual=${ACTUAL}" >&2; exit 3; }
mv "${TMP}" "${SDF}"
trap - EXIT
PREP="${SIM_BIN_DIR:+${SIM_BIN_DIR}/mk_prepare_ligand.py}"
PREP="${PREP:-$(command -v mk_prepare_ligand.py || true)}"
[[ -x "${PREP}" ]] || { echo "mk_prepare_ligand.py unavailable (set SIM_BIN_DIR)" >&2; exit 4; }
"${PREP}" -i "${SDF}" -o "${PDBQT}"
[[ -s "${PDBQT}" ]] || { echo "prepared ligand missing: ${PDBQT}" >&2; exit 5; }
PREPARED_ACTUAL="$(shasum -a 256 "${PDBQT}" | awk '{print $1}')"
[[ "${PREPARED_ACTUAL}" == "${PREPARED_EXPECTED}" ]] || {
  echo "prepared ligand digest mismatch: expected=${PREPARED_EXPECTED} actual=${PREPARED_ACTUAL}" >&2; exit 6;
}
echo "ligand ready: ${PDBQT} (source sha256=${ACTUAL}, prepared sha256=${PREPARED_ACTUAL})"
