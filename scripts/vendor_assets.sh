#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DISCOVERIES_DIR="${DISCOVERIES_DIR:-${ROOT_DIR}/discoveries}"
ASSETS="${DISCOVERIES_DIR}/assets"
URL="${THREEDMOL_URL:-https://cdnjs.cloudflare.com/ajax/libs/3Dmol/2.4.0/3Dmol-min.js}"
HOST_ALLOW="${THREEDMOL_HOST:-cdnjs.cloudflare.com}"

host_of() { printf '%s' "$1" | sed -E 's#^https?://([^/]+).*#\1#'; }

if [[ "${ALLOW_NETWORK:-}" != "1" ]]; then
  echo "vendor_assets: refusing — set ALLOW_NETWORK=1 to download 3Dmol.js from ${URL}" >&2
  exit 2
fi
if [[ "$(host_of "${URL}")" != "${HOST_ALLOW}" ]]; then
  echo "vendor_assets: host $(host_of "${URL}") not allowed (${HOST_ALLOW})" >&2
  exit 2
fi
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

mkdir -p "${ASSETS}"
TMP="${ASSETS}/3Dmol-min.js.tmp"
curl -fsSL --max-time 60 --max-redirs 2 "${URL}" -o "${TMP}"

SHA="$(sha256_of "${TMP}")"
echo "downloaded sha256=${SHA} (pin it with THREEDMOL_SHA256=${SHA} to verify future downloads)"
if [[ -n "${THREEDMOL_SHA256:-}" && "${SHA}" != "${THREEDMOL_SHA256}" ]]; then
  echo "vendor_assets: sha256 mismatch: got ${SHA}, expected ${THREEDMOL_SHA256}" >&2
  rm -f "${TMP}"
  exit 3
fi

mv "${TMP}" "${ASSETS}/3Dmol-min.js"
echo "vendored 3Dmol.js -> ${ASSETS}/3Dmol-min.js ($(wc -c < "${ASSETS}/3Dmol-min.js") bytes)"

# Refresh the dashboard so the 3D viewer appears immediately, without waiting
# for the next successful cycle (non-fatal: never fail vendoring over this).
python3 "${ROOT_DIR}/scripts/generate_dashboard.py" \
  --db "${DISCOVERIES_DIR}/ledger.db" --rotation "${ROOT_DIR}/state/rotation.json" \
  --config "${ROOT_DIR}/config/worker.json" --alphafold-cache "${ROOT_DIR}/data/alphafold_cache" \
  --assets-dir "${ASSETS}" --out "${DISCOVERIES_DIR}/dashboard.html" >/dev/null 2>&1 \
  && echo "dashboard regenerated with the 3D viewer enabled" || echo "note: run a cycle (or the generator) to refresh dashboard.html"
