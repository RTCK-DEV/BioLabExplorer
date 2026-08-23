#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="BioLab Explorer"
APP_DIR="${ROOT_DIR}/dist/${APP_NAME}.app"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

cd "${ROOT_DIR}"
# APP_ARCHS lets a release build produce a universal bundle:
#   APP_ARCHS="--arch arm64 --arch x86_64" scripts/package_app.sh
# Empty (the default) builds for this machine only.
APP_ARCH_FLAGS=()
if [[ -n "${APP_ARCHS:-}" ]]; then
  read -r -a APP_ARCH_FLAGS <<< "${APP_ARCHS}"
fi
# macOS ships bash 3.2, where "${array[@]}" on an EMPTY array trips `set -u`.
# The ${x[@]+...} guard expands to nothing at all when the array is empty.
swift build -c release --product BioLabExplorer ${APP_ARCH_FLAGS[@]+"${APP_ARCH_FLAGS[@]}"}

# A multi-architecture build lands outside .build/release.
BUILT=""
for candidate in "${ROOT_DIR}/.build/out/Products/Release/BioLabExplorer" \
                 "${ROOT_DIR}/.build/apple/Products/Release/BioLabExplorer" \
                 "${ROOT_DIR}/.build/release/BioLabExplorer"; do
  if [[ -x "${candidate}" ]]; then BUILT="${candidate}"; break; fi
done
[[ -n "${BUILT}" ]] || { echo "package_app: cannot find the built executable" >&2; exit 1; }

mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"
cp "${BUILT}" "${MACOS_DIR}/BioLabExplorer"
chmod +x "${MACOS_DIR}/BioLabExplorer"

cat > "${CONTENTS_DIR}/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>BioLabExplorer</string>
  <key>CFBundleIdentifier</key>
  <string>local.rtck.BioLabExplorer</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>BioLab Explorer</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>15.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

LATEST_ACHIEVEMENT=""
while IFS= read -r -d '' candidate; do
  if [[ -z "${LATEST_ACHIEVEMENT}" || "${candidate}" -nt "${LATEST_ACHIEVEMENT}" ]]; then
    LATEST_ACHIEVEMENT="${candidate}"
  fi
done < <(find "${ROOT_DIR}/runs" -path '*/automation-achievement.md' -type f -print0 2>/dev/null || true)
if [[ -n "${LATEST_ACHIEVEMENT}" ]]; then
  LATEST_RUN_DIR="$(dirname "${LATEST_ACHIEVEMENT}")"
  LATEST_RUN_RESOURCES="${RESOURCES_DIR}/LatestRun"
  rm -rf "${LATEST_RUN_RESOURCES}"
  mkdir -p "${LATEST_RUN_RESOURCES}"
  for artifact in \
    automation-achievement.md \
    discovery-report.md \
    discovery-validation.json \
    native_structure_summary.md \
    native_structure_result.json
  do
    if [[ -f "${LATEST_RUN_DIR}/${artifact}" ]]; then
      cp "${LATEST_RUN_DIR}/${artifact}" "${LATEST_RUN_RESOURCES}/${artifact}"
    fi
  done
  echo "Bundled latest achievement: ${LATEST_ACHIEVEMENT}"
fi

codesign --force --deep --sign - "${APP_DIR}"

echo "${APP_DIR}"
