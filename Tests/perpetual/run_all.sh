#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "${DIR}/test_config.sh"
python3 "${DIR}/test_discovery_db.py" -v
python3 "${DIR}/test_real_pipeline_integration.py" -v
bash "${DIR}/test_cycle_offline.sh"
bash "${DIR}/test_status.sh"
bash "${DIR}/test_cycle_daemon.sh"
bash "${DIR}/test_agent.sh"
python3 "${DIR}/test_fetch_uniprot.py" -v
bash "${DIR}/test_cycle_network.sh"
python3 "${DIR}/test_dashboard.py" -v
bash "${DIR}/test_dashboard_cycle.sh"
python3 "${DIR}/test_sim_queue.py" -v
bash "${DIR}/test_sim_cycle.sh"
bash "${DIR}/test_setup_stack.sh"
echo "ALL M1..M5 TESTS PASSED"
