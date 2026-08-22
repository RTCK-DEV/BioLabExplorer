#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DISCOVERIES_DIR="${DISCOVERIES_DIR:-${ROOT_DIR}/discoveries}"
ASSETS="${DISCOVERIES_DIR}/assets"
DEFAULT_URL="https://cdnjs.cloudflare.com/ajax/libs/3Dmol/2.4.0/3Dmol-min.js"
DEFAULT_SHA256="e46d1a006a87d0255b384e6bdf8e831344f2e8e0a2b34468fc125cfc5b3da00f"
DEFAULT_LICENSE_URL="https://raw.githubusercontent.com/3dmol/3Dmol.js/2.4.0/LICENSE"
DEFAULT_LICENSE_SHA256="4c6eaaed856f3f28a3b1a98e74f4a8a71618de7d51ea4155c29f6f793bcef861"
URL="${THREEDMOL_URL:-${DEFAULT_URL}}"
HOST_ALLOW="${THREEDMOL_HOST:-cdnjs.cloudflare.com}"
LICENSE_URL="${THREEDMOL_LICENSE_URL:-${DEFAULT_LICENSE_URL}}"
LICENSE_HOST="${THREEDMOL_LICENSE_HOST:-raw.githubusercontent.com}"

host_of() { printf '%s' "$1" | sed -E 's#^https?://([^/]+).*#\1#'; }

if [[ "${ALLOW_NETWORK:-}" != "1" ]]; then
  echo "vendor_assets: refusing — set ALLOW_NETWORK=1 to download 3Dmol.js from ${URL}" >&2
  exit 2
fi
if [[ "${URL}" != https://* || "$(host_of "${URL}")" != "${HOST_ALLOW}" ]]; then
  echo "vendor_assets: host $(host_of "${URL}") not allowed (${HOST_ALLOW})" >&2
  exit 2
fi
if [[ "${LICENSE_URL}" != https://* || "$(host_of "${LICENSE_URL}")" != "${LICENSE_HOST}" ]]; then
  echo "vendor_assets: license host $(host_of "${LICENSE_URL}") not allowed (${LICENSE_HOST})" >&2
  exit 2
fi
EXPECTED_SHA="${THREEDMOL_SHA256:-}"
if [[ -z "${EXPECTED_SHA}" && "${URL}" == "${DEFAULT_URL}" ]]; then EXPECTED_SHA="${DEFAULT_SHA256}"; fi
[[ -n "${EXPECTED_SHA}" ]] || { echo "vendor_assets: custom URL requires THREEDMOL_SHA256" >&2; exit 2; }
EXPECTED_LICENSE_SHA="${THREEDMOL_LICENSE_SHA256:-}"
if [[ -z "${EXPECTED_LICENSE_SHA}" && "${LICENSE_URL}" == "${DEFAULT_LICENSE_URL}" ]]; then EXPECTED_LICENSE_SHA="${DEFAULT_LICENSE_SHA256}"; fi
[[ -n "${EXPECTED_LICENSE_SHA}" ]] || { echo "vendor_assets: custom license URL requires THREEDMOL_LICENSE_SHA256" >&2; exit 2; }
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

mkdir -p "${ASSETS}"
TMP="${ASSETS}/3Dmol-min.js.tmp"
LICENSE_TMP="${ASSETS}/3Dmol-LICENSE.txt.tmp"
trap 'rm -f "${TMP}" "${LICENSE_TMP}"' EXIT
curl --fail --silent --show-error --proto '=https' --max-time 60 --max-redirs 0 "${URL}" -o "${TMP}"
curl --fail --silent --show-error --proto '=https' --max-time 60 --max-redirs 0 "${LICENSE_URL}" -o "${LICENSE_TMP}"

SHA="$(sha256_of "${TMP}")"
LICENSE_SHA="$(sha256_of "${LICENSE_TMP}")"
if [[ "${SHA}" != "${EXPECTED_SHA}" ]]; then
  echo "vendor_assets: sha256 mismatch: got ${SHA}, expected ${EXPECTED_SHA}" >&2
  exit 3
fi
if [[ "${LICENSE_SHA}" != "${EXPECTED_LICENSE_SHA}" ]]; then
  echo "vendor_assets: license sha256 mismatch: got ${LICENSE_SHA}, expected ${EXPECTED_LICENSE_SHA}" >&2
  exit 3
fi
echo "verified 3Dmol.js sha256=${SHA} license_sha256=${LICENSE_SHA}"

mv "${TMP}" "${ASSETS}/3Dmol-min.js"
mv "${LICENSE_TMP}" "${ASSETS}/3Dmol-LICENSE.txt"
trap - EXIT
echo "vendored 3Dmol.js -> ${ASSETS}/3Dmol-min.js ($(wc -c < "${ASSETS}/3Dmol-min.js") bytes)"

# Refresh the dashboard so the 3D viewer appears immediately, without waiting
# for the next successful cycle. A broken generated product is a hard failure.
python3 "${ROOT_DIR}/scripts/generate_dashboard.py" \
  --db "${DISCOVERIES_DIR}/ledger.db" --rotation "${ROOT_DIR}/state/rotation.json" \
  --config "${ROOT_DIR}/config/worker.json" --alphafold-cache "${ROOT_DIR}/data/alphafold_cache" \
  --assets-dir "${ASSETS}" --runs-dir "${ROOT_DIR}/runs" \
  --out "${DISCOVERIES_DIR}/dashboard.html" \
  && echo "dashboard regenerated with the 3D viewer enabled"
