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
mkdir -p "${ASSETS}"
curl -fsSL --max-time 60 "${URL}" -o "${ASSETS}/3Dmol-min.js"
echo "vendored 3Dmol.js -> ${ASSETS}/3Dmol-min.js ($(wc -c < "${ASSETS}/3Dmol-min.js") bytes)"
