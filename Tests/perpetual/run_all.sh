#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "${DIR}/test_config.sh"
python3 "${DIR}/test_discovery_db.py" -v
bash "${DIR}/test_cycle_offline.sh"
bash "${DIR}/test_status.sh"
bash "${DIR}/test_cycle_daemon.sh"
bash "${DIR}/test_agent.sh"
python3 "${DIR}/test_fetch_uniprot.py" -v
bash "${DIR}/test_cycle_network.sh"
echo "ALL M1+M2+M3 TESTS PASSED"
