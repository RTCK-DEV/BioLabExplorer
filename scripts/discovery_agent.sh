#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${CONFIG:-${ROOT_DIR}/config/worker.json}"
STATE_DIR="${STATE_DIR:-${ROOT_DIR}/state}"
LOG_DIR="${LOG_DIR:-${ROOT_DIR}/logs}"
LABEL="${LABEL:-com.biolab.discovery}"
PLIST_INSTALLED="${HOME}/Library/LaunchAgents/${LABEL}.plist"

cfg() { python3 -c "import json;print(json.load(open('${CONFIG}')).get('$1','$2'))"; }

gen_plist() {  # $1 = output path
  local out="$1"
  local throttle; throttle="$(cfg throttleSeconds 300)"
  mkdir -p "$(dirname "${out}")" "${LOG_DIR}"
  cat > "${out}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${ROOT_DIR}/scripts/run_discovery_cycle.sh</string>
  </array>
  <key>WorkingDirectory</key><string>${ROOT_DIR}</string>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>${throttle}</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>${LOG_DIR}/daemon.out.log</string>
  <key>StandardErrorPath</key><string>${LOG_DIR}/daemon.err.log</string>
  <key>ProcessType</key><string>Background</string>
</dict>
</plist>
PLIST
}

case "${1:-}" in
  generate) gen_plist "${2:?usage: generate <out.plist>}"; echo "wrote ${2}" ;;
  install)
    gen_plist "${PLIST_INSTALLED}"
    launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "${PLIST_INSTALLED}"
    echo "installed + loaded ${LABEL} (throttle=$(cfg throttleSeconds 300)s). Stop: scripts/discovery_agent.sh uninstall" ;;
  uninstall)
    launchctl bootout "gui/$(id -u)/${LABEL}" 2>/dev/null || true
    rm -f "${PLIST_INSTALLED}"
    echo "unloaded + removed ${LABEL}" ;;
  status)
    echo "label=${LABEL}"
    launchctl print "gui/$(id -u)/${LABEL}" 2>/dev/null | grep -E 'state =|pid =' || echo "not loaded"
    [[ -f "${STATE_DIR}/PAUSED" ]] && echo "PAUSED=yes (resume to clear)" || echo "PAUSED=no"
    bash "${ROOT_DIR}/scripts/discovery_status.sh" ;;
  resume)
    rm -f "${STATE_DIR}/PAUSED" "${STATE_DIR}/consecutive_failures"
    launchctl kickstart -k "gui/$(id -u)/${LABEL}" 2>/dev/null || true
    echo "resumed (cleared PAUSED + failure streak)" ;;
  *) echo "usage: $0 {generate <out.plist>|install|uninstall|status|resume}" >&2; exit 2 ;;
esac
