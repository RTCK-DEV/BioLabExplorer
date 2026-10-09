#!/usr/bin/env bash
# Build the downloadable artifacts for a release.
#
#   scripts/package_release.sh              universal (arm64 + x86_64)
#   scripts/package_release.sh --native     this machine's architecture only
#
# Writes to dist/release/:
#   BioLabExplorer-<version>-macos-<arch>.tar.gz   the command line tools
#   BioLabExplorer-<version>-macos-<arch>-app.zip  the app bundle
#   SHA256SUMS                                     digests for both
#
# The binaries are signed ad-hoc, not notarized: this project has no Apple
# Developer certificate. macOS will refuse them on first open until the
# quarantine flag is cleared. The README says so, and so does the text this
# script writes next to them.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}" || { echo "cannot enter ${ROOT}" >&2; exit 1; }

VERSION="$(sed -n 's/.*static let current = "\(.*\)".*/\1/p' Sources/BioLabExplorerCore/Version.swift)"
[[ -n "${VERSION}" ]] || { echo "package_release: cannot read the version" >&2; exit 1; }

ARCH_LABEL="universal"
BUILD_FLAGS=(--arch arm64 --arch x86_64)
if [[ "${1:-}" == "--native" ]]; then
  ARCH_LABEL="$(uname -m)"
  BUILD_FLAGS=()
fi

OUT="${ROOT}/dist/release"
STAGE="$(mktemp -d)"
trap 'rm -rf "${STAGE}"' EXIT
rm -rf "${OUT}"
mkdir -p "${OUT}"

echo "== building ${ARCH_LABEL} =="
swift build -c release "${BUILD_FLAGS[@]}"

# SwiftPM puts a multi-arch build somewhere other than .build/release.
BIN_DIR=""
for candidate in ".build/out/Products/Release" ".build/apple/Products/Release" ".build/release"; do
  if [[ -x "${candidate}/BioLabExplorerPipeline" ]]; then BIN_DIR="${candidate}"; break; fi
done
[[ -n "${BIN_DIR}" ]] || { echo "package_release: cannot find the built binaries" >&2; exit 1; }
echo "   binaries: ${BIN_DIR}"

TOOLS=(BioLabExplorerPipeline BioLabExplorerChecks BioLabExplorerStructureCheck BioLabExplorerAchievementReport)
PKG="BioLabExplorer-${VERSION}-macos-${ARCH_LABEL}"
mkdir -p "${STAGE}/${PKG}/bin"
for tool in "${TOOLS[@]}"; do
  [[ -x "${BIN_DIR}/${tool}" ]] || { echo "package_release: missing ${tool}" >&2; exit 1; }
  cp "${BIN_DIR}/${tool}" "${STAGE}/${PKG}/bin/${tool}"
done
cp LICENSE THIRD_PARTY_NOTICES.md "${STAGE}/${PKG}/"

cat > "${STAGE}/${PKG}/READ-ME-FIRST.txt" <<TXT
BioLabExplorer ${VERSION} — command line tools (${ARCH_LABEL})

These binaries are signed ad-hoc and are NOT notarized: notarizing requires a
paid Apple Developer certificate this project does not have. macOS quarantines
anything downloaded from the internet, so the first run will be refused until
you clear that flag.

Before you do, verify where these bytes came from. Every release is built by a
GitHub Actions workflow that signs a provenance attestation naming the exact
commit:

    gh attestation verify <the file you downloaded> --repo RTCK-DEV/BioLabExplorer
    shasum -a 256 -c SHA256SUMS

Only then:

    xattr -dr com.apple.quarantine "\$(pwd)"

If you would rather not make that trade, build from source instead — it takes
about a minute and skips the question entirely:

    git clone https://github.com/RTCK-DEV/BioLabExplorer.git
    cd BioLabExplorer
    scripts/doctor.sh --build

Then:

    bin/BioLabExplorerPipeline --help
    bin/BioLabExplorerPipeline --version

The tools need no external dependency. MMseqs2, HMMER, OpenMM and Ollama are
optional and are reported as unavailable when absent.
TXT

( cd "${STAGE}" && tar -czf "${OUT}/${PKG}.tar.gz" "${PKG}" )
echo "   wrote ${PKG}.tar.gz"

echo "== packaging the app =="
if [[ "${ARCH_LABEL}" == "universal" ]]; then
  APP_ARCHS="--arch arm64 --arch x86_64" scripts/package_app.sh > /dev/null
else
  scripts/package_app.sh > /dev/null
fi
APP="dist/BioLab Explorer.app"
[[ -d "${APP}" ]] || { echo "package_release: package_app.sh produced no bundle" >&2; exit 1; }
# Never let the file name promise an architecture the binary does not have:
# an "universal" download that will not start on an Intel Mac is worse than no
# download at all.
verify_arch() {  # $1 = mach-o path, $2 = what it is
  local info; info="$(lipo -info "$1" 2>&1)"
  if [[ "${ARCH_LABEL}" == "universal" ]]; then
    [[ "${info}" == *"x86_64"* && "${info}" == *"arm64"* ]] || {
      echo "package_release: $2 is not universal: ${info}" >&2; exit 1; }
  else
    [[ "${info}" == *"${ARCH_LABEL}"* ]] || {
      echo "package_release: $2 is not ${ARCH_LABEL}: ${info}" >&2; exit 1; }
  fi
}
verify_arch "${APP}/Contents/MacOS/BioLabExplorer" "the app binary"
for tool in "${TOOLS[@]}"; do
  verify_arch "${STAGE}/${PKG}/bin/${tool}" "${tool}"
done
echo "   architectures verified: ${ARCH_LABEL}"

# ditto preserves the bundle's symlinks and resource forks; zip does not.
ditto -c -k --sequesterRsrc --keepParent "${APP}" "${OUT}/${PKG}-app.zip"
echo "   wrote ${PKG}-app.zip"

( cd "${OUT}" && shasum -a 256 ./*.tar.gz ./*.zip > SHA256SUMS )

echo
echo "== dist/release =="
ls -lh "${OUT}" | tail -n +2 | awk '{printf "   %-52s %s\n", $9, $5}'
echo
cat "${OUT}/SHA256SUMS"
