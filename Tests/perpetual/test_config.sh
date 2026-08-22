#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 - "$ROOT" <<'PY'
import json, os, sys, hashlib
root = sys.argv[1]
sys.path.insert(0, os.path.join(root, "scripts"))
import host_profile

cfg = json.load(open(os.path.join(root, "config/worker.json")))

# Keys that must always be concrete integers: they are policy, not hardware.
for k in ("diskFloorGB", "maxCandidates", "maxLogFiles", "maxConsecutiveFailures", "throttleSeconds", "maxDaemonLogBytes", "fetchPageSize", "simMaxSeqLength", "simJobTimeoutSeconds", "simTerminationGraceSeconds", "simShutdownGraceSeconds", "simMinMemoryFreePercent", "simMmseqsCpuWeight", "simHmmerCpuWeight", "openmmMaxIterations", "openmmSeed", "openmmCpuThreads"):
    assert k in cfg and type(cfg[k]) is int, f"bad/missing int key: {k}"

# Hardware-dependent keys: either "auto" or an explicit int/str override.
for k in ("maxWorkspaceBytes", "simMaxCpuJobs", "simRamBudgetBytes", "simReserveBytes"):
    assert k in cfg, f"missing key: {k}"
    assert cfg[k] == "auto" or type(cfg[k]) is int, f"{k} must be \"auto\" or an int"
for k in ("esmfoldDevice", "openmmPlatform"):
    assert k in cfg and type(cfg[k]) is str, f"missing str key: {k}"

assert "enableNetwork" in cfg and type(cfg["enableNetwork"]) is bool, "enableNetwork must be bool"
assert "enableSimulation" in cfg and type(cfg["enableSimulation"]) is bool, "enableSimulation must be bool"
assert cfg["simMmseqsCpuWeight"] > 0 and cfg["simHmmerCpuWeight"] > 0, "CPU weights must be positive"
assert type(cfg.get("openmmAllowCpuFallback")) is bool, "openmmAllowCpuFallback must be bool"
assert cfg["openmmCpuThreads"] == 1, "OpenMM must be single-threaded for bit reproducibility"
assert cfg.get("openmmPrecision") in ("single", "mixed", "double"), "invalid OpenMM precision"

# The resolved config is what every backend actually consumes; it must be valid
# on THIS host, whatever the checked-in file says.
resolved, notes = host_profile.resolve_config(cfg, path=os.path.join(root, "config"))
# openmmPlatform is passed through untouched: openmm_relax.py probes the
# platforms for real and records every attempt, so nothing here should guess.
assert resolved["openmmPlatform"] == cfg["openmmPlatform"], "openmmPlatform must not be resolved here"
assert resolved["openmmPlatform"] in ("auto", "CPU", "CUDA", "OpenCL", "Reference"), \
    f"invalid OpenMM platform: {resolved['openmmPlatform']}"
assert resolved["esmfoldDevice"] in ("mps", "cpu"), \
    f"invalid resolved ESMFold device: {resolved['esmfoldDevice']}"
for k in ("maxWorkspaceBytes", "simRamBudgetBytes", "simReserveBytes", "simMaxCpuJobs"):
    assert type(resolved[k]) is int, f"{k} did not resolve to an int"
assert resolved["simRamBudgetBytes"] > 0, "resolved RAM budget must be positive"
assert resolved["simReserveBytes"] >= 0, "resolved reserve must be non-negative"
assert resolved["simMaxCpuJobs"] >= 0, "resolved simMaxCpuJobs must be non-negative"
assert resolved["maxWorkspaceBytes"] > 0, "resolved workspace cap must be positive"
# Every substitution must be explainable, not silent.
resolved_keys = {note["key"] for note in notes}
auto_keys = {k for k, v in cfg.items() if v == "auto"} - {"openmmPlatform"}
assert resolved_keys == auto_keys, f"unexplained resolution: {resolved_keys ^ auto_keys}"

folding = json.load(open(os.path.join(root, cfg["foldingManifest"])))
assert len(folding.get("revision", "")) == 40, "ESMFold revision must be commit pinned"
docking = json.load(open(os.path.join(root, cfg["dockingManifest"])))
assert docking.get("schemaVersion") == 1 and docking.get("allowedClassifications"), "invalid docking manifest"
assert docking["ligand"]["sourceSha256"].startswith("sha256:"), "ligand source must be digest pinned"
assert docking["ligand"]["preparedSha256"].startswith("sha256:"), "prepared ligand must be digest pinned"
man = json.load(open(os.path.join(root, "config/approved_manifest.json")))
assert isinstance(man.get("exclusions"), list) and man["exclusions"], "exclusions must be non-empty list"
assert isinstance(man.get("reviewer"), str) and man["reviewer"], "reviewer provenance must be present"
ref = os.path.join(root, "data/curated_reference/pbp_pks_reference.fasta")
digest = "sha256:" + hashlib.sha256(open(ref, "rb").read()).hexdigest()
assert man.get("referenceSha256") == digest, f"manifest digest must match reference: {digest}"
print("config OK")
PY
