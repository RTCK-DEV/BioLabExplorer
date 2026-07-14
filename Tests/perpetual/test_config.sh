#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 - "$ROOT" <<'PY'
import json, os, sys, hashlib
root = sys.argv[1]
cfg = json.load(open(os.path.join(root, "config/worker.json")))
for k in ("diskFloorGB", "maxCandidates", "maxWorkspaceBytes", "maxLogFiles", "maxConsecutiveFailures", "throttleSeconds", "maxDaemonLogBytes", "fetchPageSize", "simMaxSeqLength", "simJobTimeoutSeconds"):
    assert k in cfg and type(cfg[k]) is int, f"bad/missing int key: {k}"
assert "enableNetwork" in cfg and type(cfg["enableNetwork"]) is bool, "enableNetwork must be bool"
assert "enableSimulation" in cfg and type(cfg["enableSimulation"]) is bool, "enableSimulation must be bool"
man = json.load(open(os.path.join(root, "config/approved_manifest.json")))
assert isinstance(man.get("exclusions"), list) and man["exclusions"], "exclusions must be non-empty list"
ref = os.path.join(root, "data/curated_reference/pbp_pks_reference.fasta")
digest = "sha256:" + hashlib.sha256(open(ref, "rb").read()).hexdigest()
assert man.get("referenceSha256") == digest, f"manifest digest must match reference: {digest}"
print("config OK")
PY
