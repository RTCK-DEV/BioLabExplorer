#!/usr/bin/env python3
"""Simulation job queue: detect backends, admit jobs under a RAM/GPU/length budget, run, report.

Never fatal: unavailable/failed/timed-out backends are recorded in the summary and skipped.
Backends found via SIM_BIN_DIR (tests/stubs) first, then PATH, then a bundled path.
No network. python3 stdlib only.
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile

MAX_GPU_CONCURRENT = 1        # unified memory: serialise MPS work
GIB = 1 << 30

# id -> (exe, kind, bundled_relpath_or_None, python_module_or_None)
BACKENDS = {
    "mmseqs":   ("mmseqs",     "cpu", None,                                   None),
    "hmmer":    ("phmmer",     "cpu", None,                                   None),
    "foldseek": ("foldseek",   "cpu", "tools/foldseek/foldseek/bin/foldseek", None),
    "vina":     ("vina",       "cpu", None,                                   None),
    "esmfold":  ("esmfold",    "gpu", None,                                   "torch"),
    "openmm":   ("openmm",     "cpu", None,                                   "openmm"),
}


def is_gpu(backend_id):
    return BACKENDS.get(backend_id, (None, "cpu", None, None))[1] == "gpu"


def _root():
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _find_exe(exe, bundled):
    bin_dir = os.environ.get("SIM_BIN_DIR")
    if bin_dir:
        p = os.path.join(bin_dir, exe)
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return p
        return None            # SIM_BIN_DIR is authoritative for tests
    p = shutil.which(exe)
    if p:
        return p
    if bundled:
        p = os.path.join(_root(), bundled)
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    return None


def _has_module(mod):
    try:
        subprocess.run([sys.executable, "-c", f"import {mod}"], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30)
        return True
    except Exception:
        return False


def detect_backends(cfg):
    out = {}
    for bid, (exe, kind, bundled, mod) in BACKENDS.items():
        path = _find_exe(exe, bundled)
        if path:
            out[bid] = {"available": True, "path": path, "reason": "found"}
            continue
        if mod and not os.environ.get("SIM_BIN_DIR") and _has_module(mod):
            out[bid] = {"available": True, "path": None, "reason": f"python module {mod}"}
            continue
        why = f"{exe} not found" + (f" and python module {mod} not installed" if mod else "")
        out[bid] = {"available": False, "path": None, "reason": why}
    return out


def estimate_ram(backend_id, seq_len, cfg):
    """Length-aware estimates (bytes). Folding is O(L^2)-ish; others are flat-ish."""
    if backend_id == "esmfold":
        return int(5 * GIB + (seq_len ** 2) * 800)     # weights + trunk
    if backend_id == "openmm":
        return int(1.5 * GIB)
    if backend_id == "vina":
        return int(0.75 * GIB)
    if backend_id in ("mmseqs", "foldseek"):
        return int(1 * GIB)
    if backend_id == "hmmer":
        return int(0.5 * GIB)
    return int(0.5 * GIB)


def ram_budget(cfg):
    configured = int(cfg.get("simRamBudgetBytes", 16 * GIB))
    reserve = int(cfg.get("simReserveBytes", 8 * GIB))
    try:
        total = int(subprocess.run(["sysctl", "-n", "hw.memsize"], capture_output=True,
                                   text=True, timeout=10).stdout.strip())
    except Exception:
        total = configured + reserve
    return max(0, min(configured, total - reserve))


def schedule(jobs, cfg, detected):
    """Admit jobs while Σ estimated RAM <= budget; serialise GPU; gate long sequences."""
    budget = ram_budget(cfg)
    max_len = int(cfg.get("simMaxSeqLength", 700))
    admitted, skipped, used, gpu = [], [], 0, 0
    for j in jobs:
        bid = j["backend"]
        d = detected.get(bid, {"available": False, "reason": "unknown backend"})
        if not d.get("available"):
            skipped.append({**j, "reason_code": "unavailable", "reason": d.get("reason", "")})
            continue
        if is_gpu(bid) and int(j.get("seq_len", 0)) > max_len:
            skipped.append({**j, "reason_code": "too_long", "reason": f"seq_len>{max_len}"})
            continue
        need = estimate_ram(bid, int(j.get("seq_len", 0)), cfg)
        if used + need > budget:
            skipped.append({**j, "reason_code": "ram_budget", "reason": f"needs {need}B, {budget - used}B left"})
            continue
        if is_gpu(bid) and gpu >= MAX_GPU_CONCURRENT:
            skipped.append({**j, "reason_code": "gpu_serialised", "reason": "gpu slot busy"})
            continue
        admitted.append(j)
        used += need
        if is_gpu(bid):
            gpu += 1
    return admitted, skipped


def _command(job, detected, run_dir, cfg):
    """Minimal, safe invocations. Real pipelines are refined once the stack is installed."""
    bid = job["backend"]
    path = detected[bid].get("path") or bid
    out = os.path.join(run_dir, "sim", bid)
    os.makedirs(out, exist_ok=True)
    if bid in ("mmseqs", "foldseek", "hmmer", "vina"):
        return [path, "--version"]        # smoke invocation; stubs answer, real tools answer
    return [sys.executable, "-c", "pass"]


def run(candidates, run_dir, cfg):
    detected = detect_backends(cfg)
    jobs = []
    for c in candidates:
        seq_len = len(c.get("sequence", "") or "")
        for bid in BACKENDS:
            jobs.append({"backend": bid, "accession": c.get("accession"), "seq_len": seq_len})
    admitted, skipped = schedule(jobs, cfg, detected)
    timeout = int(cfg.get("simJobTimeoutSeconds", 900))
    results = []
    for j in admitted:
        cmd = _command(j, detected, run_dir, cfg)
        try:
            p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
            results.append({**j, "status": "ok" if p.returncode == 0 else "failed",
                            "rc": p.returncode})
        except subprocess.TimeoutExpired:
            results.append({**j, "status": "timeout", "rc": None})
        except Exception as exc:
            results.append({**j, "status": "failed", "rc": None, "error": str(exc)})
    summary = {
        "schemaVersion": 1,
        "backends": detected,
        "ramBudgetBytes": ram_budget(cfg),
        "ran": len([r for r in results if r["status"] == "ok"]),
        "jobs": results,
        "skipped": skipped,
    }
    sim_dir = os.path.join(run_dir, "sim")
    os.makedirs(sim_dir, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=sim_dir, suffix=".tmp")
    with os.fdopen(fd, "w") as fh:
        json.dump(summary, fh, indent=2)
    os.replace(tmp, os.path.join(sim_dir, "summary.json"))
    return summary


def main(argv=None):
    ap = argparse.ArgumentParser(prog="sim_queue.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    for f in ("--candidates", "--run-dir", "--config"):
        r.add_argument(f, required=True)
    a = ap.parse_args(argv)
    with open(a.config) as fh:
        cfg = json.load(fh)
    with open(a.candidates) as fh:
        cands = json.load(fh)
    s = run(cands, a.run_dir, cfg)
    print(s["ran"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
