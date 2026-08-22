#!/usr/bin/env python3
"""Resource-bounded local scientific job queue for perpetual discovery.

The queue performs real candidate work: MMseqs2/HMMER consume candidate FASTA,
folding consumes sequence, and structure stages consume produced structures.
Unavailable tools and unmet prerequisites are explicit skipped records. Queue
infrastructure errors are fatal; individual scientific backend failures remain
visible in summary.json and do not discard the Swift-native discovery result.
"""
import argparse
import concurrent.futures
import hashlib
import json
import os
import re
import signal
import shutil
import subprocess
import sys
import tempfile
import time

import host_profile
from discovery_db import parse_fasta, seq_sha256

MAX_GPU_CONCURRENT = 1
GIB = 1 << 30
BACKENDS = {
    "mmseqs": ("mmseqs", "cpu", None),
    "hmmer": ("phmmer", "cpu", None),
    "foldseek": ("foldseek", "cpu", "tools/foldseek/foldseek/bin/foldseek"),
    "vina": ("vina", "cpu", None),
    "esmfold": ("esmfold", "gpu", None),
    "openmm": (None, "cpu", None),
}


def is_gpu(backend_id):
    return BACKENDS.get(backend_id, (None, "cpu", None))[1] == "gpu"


def _root():
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _safe_name(value):
    return re.sub(r"[^A-Za-z0-9_.-]+", "_", str(value or "unknown"))[:160]


def _public_job(job):
    return {key: value for key, value in job.items() if key not in ("sequence", "records")}


def _find_exe(exe, bundled=None):
    if not exe:
        return None
    bin_dir = os.environ.get("SIM_BIN_DIR")
    if bin_dir:
        path = os.path.join(bin_dir, exe)
        return path if os.path.isfile(path) and os.access(path, os.X_OK) else None
    path = shutil.which(exe)
    if path:
        return path
    if bundled:
        path = os.path.join(_root(), bundled)
        if os.path.isfile(path) and os.access(path, os.X_OK):
            return path
    return None


def _python_with_module(module):
    candidates = []
    if os.environ.get("SIM_BIN_DIR"):
        candidates.append(os.path.join(os.environ["SIM_BIN_DIR"], "python"))
        candidates.append(os.path.join(os.environ["SIM_BIN_DIR"], "python3"))
    candidates.append(sys.executable)
    for python in candidates:
        if not os.path.isfile(python) and not shutil.which(python):
            continue
        try:
            probe = subprocess.run(
                [python, "-c", f"import {module}"], capture_output=True, text=True, timeout=30
            )
        except (OSError, subprocess.SubprocessError):
            continue
        if probe.returncode == 0:
            return python
    return None


def detect_backends(cfg):
    detected = {}
    for backend_id, (exe, _kind, bundled) in BACKENDS.items():
        if backend_id == "openmm":
            python = _python_with_module("openmm")
            detected[backend_id] = {
                "available": python is not None,
                "path": python,
                "reason": "python module openmm" if python else "python module openmm not installed",
            }
            continue
        if backend_id == "esmfold" and os.environ.get("ESMFOLD_PYTHON"):
            python = os.environ["ESMFOLD_PYTHON"]
            try:
                probe = subprocess.run([python, "-c", "import torch, transformers"],
                                       capture_output=True, text=True, timeout=30)
            except (OSError, subprocess.SubprocessError):
                probe = None
            available = bool(probe and probe.returncode == 0)
            detected[backend_id] = {
                "available": available, "path": python,
                "wrapper": os.path.join(_root(), "scripts", "esmfold_hf.py"),
                "reason": "Hugging Face ESMFold environment" if available else
                          "ESMFOLD_PYTHON cannot import torch and transformers",
            }
            continue
        path = _find_exe(exe, bundled)
        # fair-esm commonly installs `esm-fold`; accept it, but never mistake
        # torch alone for a usable folding backend.
        if backend_id == "esmfold" and not path:
            path = _find_exe("esm-fold")
        if backend_id == "vina":
            meeko = _find_exe("mk_prepare_receptor.py")
            detected[backend_id] = {
                "available": path is not None and meeko is not None,
                "path": path,
                "meekoPath": meeko,
                "reason": "found Vina and Meeko" if path and meeko else
                          "vina and/or mk_prepare_receptor.py executable not found",
            }
            continue
        detected[backend_id] = {
            "available": path is not None,
            "path": path,
            "reason": "found" if path else f"{exe} executable not found",
        }
    return detected


def estimate_ram(backend_id, seq_len, cfg):
    """Conservative unified-memory reservation in bytes."""
    if backend_id == "esmfold":
        return int(5 * GIB + (seq_len ** 2) * 800)
    if backend_id == "openmm":
        return int(1.5 * GIB)
    if backend_id == "vina":
        return int(0.75 * GIB)
    if backend_id in ("mmseqs", "foldseek"):
        return int(1 * GIB)
    if backend_id == "hmmer":
        return int(0.5 * GIB)
    return int(0.5 * GIB)


def _physical_memory_bytes():
    probe = subprocess.run(
        ["sysctl", "-n", "hw.memsize"], capture_output=True, text=True, timeout=10
    )
    if probe.returncode != 0 or not probe.stdout.strip().isdigit():
        raise RuntimeError(f"cannot determine physical memory: rc={probe.returncode} stderr={probe.stderr.strip()}")
    return int(probe.stdout.strip())


def ram_budget(cfg):
    configured = int(cfg.get("simRamBudgetBytes", 16 * GIB))
    reserve = int(cfg.get("simReserveBytes", 8 * GIB))
    if configured <= 0 or reserve < 0:
        raise ValueError("simRamBudgetBytes must be >0 and simReserveBytes must be >=0")
    try:
        total = _physical_memory_bytes()
    except (FileNotFoundError, RuntimeError, subprocess.SubprocessError):
        # Non-macOS unit-test/CI fallback remains bounded by the explicit config.
        total = configured + reserve
    return max(0, min(configured, total - reserve))


def schedule(jobs, cfg, detected):
    """Static admission preview used by checks and dry-run diagnostics."""
    budget = ram_budget(cfg)
    max_len = int(cfg.get("simMaxSeqLength", 700))
    admitted, skipped, used, gpu = [], [], 0, 0
    for job in jobs:
        backend_id = job["backend"]
        status = detected.get(backend_id, {"available": False, "reason": "unknown backend"})
        if not status.get("available"):
            skipped.append({**job, "reason_code": "unavailable", "reason": status.get("reason", "")})
            continue
        if is_gpu(backend_id) and int(job.get("seq_len", 0)) > max_len:
            skipped.append({**job, "reason_code": "too_long", "reason": f"seq_len>{max_len}"})
            continue
        need = estimate_ram(backend_id, int(job.get("seq_len", 0)), cfg)
        if used + need > budget:
            skipped.append({**job, "reason_code": "ram_budget", "reason": f"needs {need}B, {budget-used}B left"})
            continue
        if is_gpu(backend_id) and gpu >= MAX_GPU_CONCURRENT:
            skipped.append({**job, "reason_code": "gpu_serialised", "reason": "GPU slot is serial"})
            continue
        admitted.append(job)
        used += need
        gpu += int(is_gpu(backend_id))
    return admitted, skipped


def _memory_free_percent():
    try:
        probe = subprocess.run(["memory_pressure"], capture_output=True, text=True, timeout=10)
        if probe.returncode != 0:
            return None
        match = re.search(r"System-wide memory free percentage:\s*(\d+)%", probe.stdout)
        return int(match.group(1)) if match else None
    except (FileNotFoundError, subprocess.SubprocessError):
        return None


def _write_candidate_fasta(job, run_dir):
    candidate_dir = os.path.join(run_dir, "sim", "candidates", _safe_name(job["accession"]))
    os.makedirs(candidate_dir, exist_ok=True)
    fasta = os.path.join(candidate_dir, "query.fasta")
    with open(fasta, "w", encoding="utf-8") as fh:
        for record in job.get("records") or [job]:
            fh.write(f">{record['accession']}\n{record['sequence']}\n")
    return candidate_dir, fasta


def _command(job, detected, run_dir, cfg, reference, cpu_threads):
    backend_id = job["backend"]
    path = detected[backend_id].get("path")
    candidate_dir, fasta = _write_candidate_fasta(job, run_dir)
    output_dir = os.path.join(candidate_dir, backend_id)
    os.makedirs(output_dir, exist_ok=True)
    if backend_id == "mmseqs":
        output = os.path.join(output_dir, "hits.m8")
        tmp = os.path.join(output_dir, "tmp")
        return [path, "easy-search", fasta, reference, output, tmp, "--threads", str(cpu_threads)], output
    if backend_id == "hmmer":
        output = os.path.join(output_dir, "hits.tbl")
        return [path, "--cpu", str(cpu_threads), "--tblout", output, fasta, reference], output
    if backend_id == "esmfold":
        # Both fair-esm's esm-fold and the supported wrapper accept input/output flags.
        if detected[backend_id].get("wrapper"):
            manifest = cfg.get("foldingManifest", os.path.join(_root(), "config", "folding_manifest.json"))
            if not os.path.isabs(manifest):
                manifest = os.path.join(_root(), manifest)
            return [path, detected[backend_id]["wrapper"], "-i", fasta, "-o", output_dir,
                    "--manifest", manifest, "--device", str(cfg.get("esmfoldDevice", "mps"))], output_dir
        return [path, "-i", fasta, "-o", output_dir], output_dir
    structure = job.get("structure")
    if backend_id == "openmm":
        output = os.path.join(output_dir, "relaxed.pdb")
        metrics = os.path.join(output_dir, "relaxation_metrics.json")
        helper = os.path.join(_root(), "scripts", "openmm_relax.py")
        command = [path, helper, "--input", structure, "--output", output,
                "--metrics", metrics, "--platform", str(cfg.get("openmmPlatform", "CPU")),
                "--precision", str(cfg.get("openmmPrecision", "mixed")),
                "--max-iterations", str(int(cfg.get("openmmMaxIterations", 1000))),
                "--seed", str(int(cfg.get("openmmSeed", 20260715))),
                "--cpu-threads", str(max(1, int(cfg.get("openmmCpuThreads", 1))))]
        if cfg.get("openmmAllowCpuFallback", True):
            command.append("--allow-cpu-fallback")
        return command, output
    if backend_id == "foldseek":
        database = cfg.get("foldseekStructureDatabase", "")
        output = os.path.join(output_dir, "hits.m8")
        tmp = os.path.join(output_dir, "tmp")
        return [path, "easy-search", structure, database, output, tmp, "--threads", str(cpu_threads)], output
    if backend_id == "vina":
        output = os.path.join(output_dir, "pose.pdbqt")
        helper = os.path.join(_root(), "scripts", "vina_dock.py")
        manifest = cfg.get("dockingManifest", os.path.join(_root(), "config", "docking_manifest.json"))
        if not os.path.isabs(manifest):
            manifest = os.path.join(_root(), manifest)
        return [sys.executable, helper, "--receptor-pdb", structure,
                "--sequence-file", fasta, "--classification", job.get("classification", ""),
                "--manifest", manifest, "--output-dir", output_dir,
                "--vina", path, "--meeko", detected[backend_id]["meekoPath"],
                "--cpu", str(cpu_threads)], output
    raise ValueError(f"unsupported backend: {backend_id}")


def _prerequisite_error(job, cfg, reference):
    backend_id = job["backend"]
    if not job.get("sequence"):
        return "candidate sequence is empty"
    if backend_id in ("mmseqs", "hmmer") and (not reference or not os.path.isfile(reference)):
        return f"reference FASTA missing: {reference or '<unset>'}"
    if backend_id in ("openmm", "foldseek", "vina") and not job.get("structure"):
        return "structure unavailable"
    if backend_id == "foldseek" and not os.path.exists(cfg.get("foldseekStructureDatabase", "")):
        return "foldseekStructureDatabase is not configured or missing"
    if backend_id == "vina":
        manifest = cfg.get("dockingManifest", os.path.join(_root(), "config", "docking_manifest.json"))
        if not os.path.isabs(manifest):
            manifest = os.path.join(_root(), manifest)
        if not os.path.isfile(manifest):
            return f"docking manifest missing: {manifest}"
        if not job.get("classification"):
            return "candidate classification missing for manifest-gated docking"
    return None


def _run_command(job, detected, run_dir, cfg, reference, cpu_threads, timeout):
    command, expected_output = _command(job, detected, run_dir, cfg, reference, cpu_threads)
    started = time.monotonic()
    env = os.environ.copy()
    env.update({"OMP_NUM_THREADS": str(cpu_threads), "OPENMM_CPU_THREADS": str(cpu_threads)})
    # Scientific CLIs often spawn workers. Isolate one process group so timeout
    # cleanup cannot leave orphan CPU/RAM consumers behind.
    process = subprocess.Popen(
        command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
        env=env, start_new_session=True,
    )
    timed_out = False
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            stdout, stderr = process.communicate(timeout=int(cfg.get("simTerminationGraceSeconds", 10)))
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            stdout, stderr = process.communicate()
    log_dir = os.path.join(run_dir, "sim", "logs")
    os.makedirs(log_dir, exist_ok=True)
    stem = f"{_safe_name(job['accession'])}.{job['backend']}"
    with open(os.path.join(log_dir, stem + ".stdout.log"), "w", encoding="utf-8") as fh:
        fh.write(stdout)
    with open(os.path.join(log_dir, stem + ".stderr.log"), "w", encoding="utf-8") as fh:
        fh.write(stderr)
    status = "timeout" if timed_out else ("ok" if process.returncode == 0 else "failed")
    resolved_output = expected_output if os.path.isfile(expected_output) else None
    if status == "ok" and os.path.isdir(expected_output):
        pdbs = sorted(os.path.join(expected_output, name) for name in os.listdir(expected_output)
                      if name.endswith(".pdb"))
        resolved_output = pdbs[0] if pdbs else None
    if status == "ok" and not resolved_output:
        status = "failed"
        stderr = (stderr + f"\nexpected output missing: {expected_output}").strip()
    artifact_sha = None
    if resolved_output and os.path.isfile(resolved_output):
        artifact_sha = _file_sha256(resolved_output)
    metrics = None
    if resolved_output:
        metrics_name = {"esmfold": "prediction_metrics.json", "openmm": "relaxation_metrics.json",
                        "vina": "docking_metrics.json"}.get(job["backend"])
        metrics_path = os.path.join(os.path.dirname(resolved_output), metrics_name) if metrics_name else None
        if metrics_path and os.path.isfile(metrics_path):
            with open(metrics_path, encoding="utf-8") as fh:
                metrics = json.load(fh)
    return {
        **_public_job(job),
        "status": status,
        "rc": process.returncode,
        "durationSeconds": round(time.monotonic() - started, 3),
        "estimatedRamBytes": estimate_ram(job["backend"], job["seq_len"], cfg),
        "cpuThreads": cpu_threads,
        "command": command,
        "output": resolved_output,
        "outputSha256": artifact_sha,
        "metrics": metrics,
        "stderrTail": stderr[-2000:],
    }


def _run_parallel(jobs, detected, run_dir, cfg, reference, deadline):
    """Work-conserving dispatcher: completed jobs release RAM for pending work."""
    if not jobs:
        return [], [], {"maxConcurrentObserved": 0, "peakEstimatedRamBytes": 0}
    budget = ram_budget(cfg)
    min_free = int(cfg.get("simMinMemoryFreePercent", 15))
    requested = int(cfg.get("simMaxCpuJobs", 0))
    max_workers = requested if requested > 0 else max(1, os.cpu_count() or 1)
    max_workers = min(max_workers, len(jobs), max(1, os.cpu_count() or 1))
    threads = max(1, (os.cpu_count() or 1) // max_workers)
    pending = list(jobs)
    active = {}
    results, skipped = [], []
    used = 0
    max_concurrent = 0
    peak_ram = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as pool:
        while pending or active:
            launched = False
            free_percent = _memory_free_percent()
            pressure_ok = free_percent is None or free_percent >= min_free
            index = 0
            while pressure_ok and len(active) < max_workers and index < len(pending):
                job = pending[index]
                need = estimate_ram(job["backend"], job["seq_len"], cfg)
                if need > budget:
                    skipped.append({**_public_job(job),
                                    "reason_code": "ram_budget", "reason": f"job needs {need}B > budget {budget}B"})
                    pending.pop(index)
                    continue
                remaining = deadline - time.monotonic()
                if remaining <= int(cfg.get("simShutdownGraceSeconds", 30)):
                    skipped.extend({**_public_job(item),
                                    "reason_code": "budget_expired", "reason": "cycle soft budget reached"}
                                   for item in pending)
                    pending.clear()
                    break
                if used + need > budget:
                    index += 1
                    continue
                pending.pop(index)
                timeout = min(int(cfg.get("simJobTimeoutSeconds", 900)),
                              max(1, int(remaining - int(cfg.get("simShutdownGraceSeconds", 30)))))
                job_threads = max(1, int(job.get("cpuThreads", threads)))
                future = pool.submit(_run_command, job, detected, run_dir, cfg,
                                     reference, job_threads, timeout)
                active[future] = (job, need)
                used += need
                launched = True
                max_concurrent = max(max_concurrent, len(active))
                peak_ram = max(peak_ram, used)
            if active:
                done, _ = concurrent.futures.wait(
                    active, timeout=1, return_when=concurrent.futures.FIRST_COMPLETED
                )
                for future in done:
                    _job, need = active.pop(future)
                    used -= need
                    results.append(future.result())
            elif pending and not launched:
                reason = "memory pressure below dispatch threshold" if not pressure_ok else "no job fits RAM budget"
                code = "memory_pressure" if not pressure_ok else "ram_budget"
                skipped.extend({**_public_job(item),
                                "reason_code": code, "reason": reason} for item in pending)
                pending.clear()
    allocations = [max(1, int(job.get("cpuThreads", threads))) for job in jobs]
    uniform_threads = allocations[0] if len(set(allocations)) == 1 else None
    return results, skipped, {
        "configuredMaxCpuJobs": requested,
        "workerCount": max_workers,
        "cpuThreadsPerJob": uniform_threads,
        "defaultCpuThreadsPerJob": threads,
        "cpuThreadAllocations": {
            job["backend"]: max(1, int(job.get("cpuThreads", threads))) for job in jobs
        },
        "maxConcurrentCpuThreadsConfigured": sum(sorted(allocations, reverse=True)[:max_workers]),
        "maxConcurrentObserved": max_concurrent,
        "peakEstimatedRamBytes": peak_ram,
    }


def _atomic_json(path, value):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd, temp = tempfile.mkstemp(dir=os.path.dirname(path), suffix=".tmp")
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(value, fh, indent=2, sort_keys=True)
    os.replace(temp, path)


def _file_sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            digest.update(chunk)
    return "sha256:" + digest.hexdigest()


def _cached_structure(cfg, accession):
    directory = cfg.get("structureFallbackDirectory", "")
    if directory and not os.path.isabs(directory):
        directory = os.path.join(_root(), directory)
    if not directory or not os.path.isdir(directory):
        return None
    safe = _safe_name(accession)
    names = (f"AF-{safe}-F1-model_v6.pdb", f"AF-{safe}-F1-model_v4.pdb", f"{safe}.pdb")
    for name in names:
        path = os.path.join(directory, name)
        if os.path.isfile(path):
            return path
    return None


def _validated_candidates(candidates):
    result = []
    for candidate in candidates:
        accession = str(candidate.get("accession", "")).strip()
        sequence = re.sub(r"\s+", "", str(candidate.get("sequence", ""))).upper()
        if not accession or not sequence or re.search(r"[^A-Z]", sequence):
            raise ValueError(f"invalid simulation candidate payload for accession={accession!r}")
        expected_sha = str(candidate.get("seqSha256", "")).strip().lower()
        actual_sha = hashlib.sha256(sequence.encode("utf-8")).hexdigest()
        if not re.fullmatch(r"[0-9a-f]{64}", expected_sha) or expected_sha != actual_sha:
            raise ValueError(f"simulation candidate checksum mismatch for accession={accession!r}")
        result.append({"accession": accession, "sequence": sequence, "seq_len": len(sequence),
                       "classification": str(candidate.get("classification", "")),
                       "score": candidate.get("score")})
    return result


def load_fasta_candidates(path):
    """Build checksum-bound simulation payloads from the shared FASTA contract."""
    candidates = []
    for accession, sequence in parse_fasta(path):
        canonical = re.sub(r"\s+", "", sequence).upper()
        candidates.append({
            "accession": accession,
            "sequence": canonical,
            "seqSha256": seq_sha256(canonical),
        })
    return candidates


def filter_candidates(candidates, accession):
    if not accession:
        return candidates
    selected = [item for item in candidates if str(item.get("accession", "")) == accession]
    if len(selected) != 1:
        raise ValueError(f"--accession must match exactly one candidate, found {len(selected)}: {accession}")
    return selected


def _sequence_cpu_threads(jobs, cfg):
    """Allocate all logical CPUs across available sequence-search backends by weight."""
    if not jobs:
        return {}
    logical_cpus = max(1, os.cpu_count() or 1)
    backend_ids = [job["backend"] for job in jobs]
    if len(backend_ids) == 1:
        return {backend_ids[0]: logical_cpus}
    weights = {
        "mmseqs": max(1, int(cfg.get("simMmseqsCpuWeight", 1))),
        "hmmer": max(1, int(cfg.get("simHmmerCpuWeight", 2))),
    }
    # Give every concurrently runnable backend one thread, then distribute the
    # remainder by weight using largest remainders so the total is exact.
    allocation = {backend_id: 1 for backend_id in backend_ids}
    remaining = max(0, logical_cpus - len(backend_ids))
    total_weight = sum(weights.get(backend_id, 1) for backend_id in backend_ids)
    fractions = []
    for backend_id in backend_ids:
        exact = remaining * weights.get(backend_id, 1) / total_weight
        whole = int(exact)
        allocation[backend_id] += whole
        fractions.append((exact - whole, weights.get(backend_id, 1), backend_id))
    leftovers = logical_cpus - sum(allocation.values())
    for _, _, backend_id in sorted(fractions, reverse=True)[:leftovers]:
        allocation[backend_id] += 1
    return allocation


def run(candidates, run_dir, cfg, reference=None, budget_seconds=None):
    started = time.monotonic()
    # Machine-specific tuning keys may be the string "auto"; resolve them from
    # the running host before anything reads a RAM budget or device name.
    cfg, host_resolutions = host_profile.resolve_config(cfg)
    host_facts = host_profile.detect()
    budget_seconds = int(budget_seconds or cfg.get("budgetSeconds", 21600))
    if budget_seconds <= 0:
        raise ValueError("budgetSeconds must be > 0")
    deadline = started + budget_seconds
    candidates = _validated_candidates(candidates)
    detected = detect_backends(cfg)
    skipped = []

    sequence_jobs = []
    if candidates:
        batch = {
            "accession": f"batch-{len(candidates)}",
            "sequence": "".join(candidate["sequence"] for candidate in candidates),
            "records": candidates,
            "seq_len": max(candidate["seq_len"] for candidate in candidates),
        }
        for backend_id in ("mmseqs", "hmmer"):
            job = {**batch, "backend": backend_id}
            if not detected[backend_id]["available"]:
                skipped.append({**_public_job(job),
                                "reason_code": "unavailable", "reason": detected[backend_id]["reason"]})
            elif (reason := _prerequisite_error(job, cfg, reference)):
                skipped.append({**_public_job(job),
                                "reason_code": "prerequisite", "reason": reason})
            else:
                sequence_jobs.append(job)
    thread_allocation = _sequence_cpu_threads(sequence_jobs, cfg)
    for job in sequence_jobs:
        job["cpuThreads"] = thread_allocation[job["backend"]]
    sequence_results, sequence_skipped, resources = _run_parallel(
        sequence_jobs, detected, run_dir, cfg, reference, deadline
    )
    skipped.extend(sequence_skipped)

    # Unified-memory GPU folding is intentionally serial. The next candidate is
    # admitted only after the previous model releases its reservation.
    fold_results = []
    structures = {}
    structure_inputs = {}
    for candidate in candidates:
        job = {**candidate, "backend": "esmfold"}
        if not detected["esmfold"]["available"]:
            skipped.append({**_public_job(job),
                            "reason_code": "unavailable", "reason": detected["esmfold"]["reason"]})
            continue
        if candidate["seq_len"] > int(cfg.get("simMaxSeqLength", 700)):
            skipped.append({**_public_job(job),
                            "reason_code": "too_long", "reason": f"seq_len>{cfg.get('simMaxSeqLength', 700)}"})
            continue
        need = estimate_ram("esmfold", candidate["seq_len"], cfg)
        if need > ram_budget(cfg):
            skipped.append({**_public_job(job),
                            "reason_code": "ram_budget", "reason": f"job needs {need}B"})
            continue
        remaining = deadline - time.monotonic()
        if remaining <= int(cfg.get("simShutdownGraceSeconds", 30)):
            skipped.append({**_public_job(job),
                            "reason_code": "budget_expired", "reason": "cycle soft budget reached"})
            continue
        result = _run_command(job, detected, run_dir, cfg, reference, 1,
                              min(int(cfg.get("simJobTimeoutSeconds", 900)), max(1, int(remaining))))
        fold_results.append(result)
        if result["status"] == "ok" and result.get("output"):
            # Wrappers may choose their own PDB name; prefer expected output then
            # scan the candidate fold directory deterministically.
            expected = result["output"]
            pdbs = [expected] if expected.endswith(".pdb") else []
            fold_dir = os.path.dirname(expected)
            if os.path.isdir(fold_dir):
                pdbs.extend(os.path.join(fold_dir, name) for name in sorted(os.listdir(fold_dir)) if name.endswith(".pdb"))
            if pdbs:
                structures[candidate["accession"]] = pdbs[0]
                structure_inputs[candidate["accession"]] = {
                    "source": "local-folding-backend", "path": pdbs[0],
                    "sha256": _file_sha256(pdbs[0]),
                }

    # A pre-existing AlphaFold structure is a provenance-labelled input fallback,
    # not a substitute claim that local folding ran. It still enables the strictly
    # serial relax -> dock chain on hosts without a validated folding backend.
    for candidate in candidates:
        accession = candidate["accession"]
        if accession not in structures and (cached := _cached_structure(cfg, accession)):
            structures[accession] = cached
            structure_inputs[accession] = {
                "source": "alphafold-cache", "path": cached, "sha256": _file_sha256(cached),
            }

    relaxation_jobs = []
    for candidate in candidates:
        structure = structures.get(candidate["accession"])
        job = {**candidate, "backend": "openmm", "structure": structure,
               "structureSource": structure_inputs.get(candidate["accession"], {}).get("source"),
               "cpuThreads": max(1, int(cfg.get("openmmCpuThreads", 1)))}
        if not detected["openmm"]["available"]:
            skipped.append({**_public_job(job), "reason_code": "unavailable",
                            "reason": detected["openmm"]["reason"]})
        elif (reason := _prerequisite_error(job, cfg, reference)):
            skipped.append({**_public_job(job), "reason_code": "prerequisite", "reason": reason})
        else:
            relaxation_jobs.append(job)
    relaxation_results, relaxation_skipped, relaxation_resources = _run_parallel(
        relaxation_jobs, detected, run_dir, cfg, reference, deadline
    )
    skipped.extend(relaxation_skipped)
    relaxed = {item["accession"]: item["output"] for item in relaxation_results
               if item["status"] == "ok" and item.get("output")}

    post_jobs = []
    for candidate in candidates:
        structure = relaxed.get(candidate["accession"])
        for backend_id in ("foldseek", "vina"):
            job = {**candidate, "backend": backend_id, "structure": structure,
                   "structureSource": "openmm-relaxed" if structure else None}
            if not detected[backend_id]["available"]:
                skipped.append({**_public_job(job), "reason_code": "unavailable",
                                "reason": detected[backend_id]["reason"]})
            elif (reason := _prerequisite_error(job, cfg, reference)):
                skipped.append({**_public_job(job), "reason_code": "prerequisite", "reason": reason})
            else:
                post_jobs.append(job)
    post_results, post_skipped, post_resources = _run_parallel(
        post_jobs, detected, run_dir, cfg, reference, deadline
    )
    skipped.extend(post_skipped)
    results = sequence_results + fold_results + relaxation_results + post_results
    resources["maxConcurrentObserved"] = max(
        resources["maxConcurrentObserved"], relaxation_resources["maxConcurrentObserved"],
        post_resources["maxConcurrentObserved"])
    resources["peakEstimatedRamBytes"] = max(
        resources["peakEstimatedRamBytes"], relaxation_resources["peakEstimatedRamBytes"],
        post_resources["peakEstimatedRamBytes"])
    resources["logicalCpuCount"] = os.cpu_count() or 1
    resources["ramBudgetBytes"] = ram_budget(cfg)
    resources["memoryFreePercentAtFinish"] = _memory_free_percent()

    candidate_evidence = []
    for candidate in candidates:
        accession = candidate["accession"]
        input_info = structure_inputs.get(accession)
        fold = next((item for item in fold_results if item["accession"] == accession), None)
        relax = next((item for item in relaxation_results if item["accession"] == accession), None)
        dock = next((item for item in post_results if item["accession"] == accession and item["backend"] == "vina"), None)
        fold_credit = 0.20 if input_info and input_info["source"] == "local-folding-backend" else (0.10 if input_info else 0.0)
        relax_credit = 0.30 if relax and relax["status"] == "ok" and relax.get("metrics") else 0.0
        dock_credit = 0.35 if dock and dock["status"] == "ok" and dock.get("metrics") else 0.0
        render_credit = 0.15 if relax_credit and dock_credit else 0.0
        evidence = {
            "schemaVersion": 1,
            "accession": accession,
            "structureInput": input_info,
            "folding": fold.get("metrics") if fold else None,
            "relaxedStructure": relax.get("output") if relax else None,
            "relaxedStructureSha256": relax.get("outputSha256") if relax else None,
            "dockingPose": dock.get("output") if dock else None,
            "dockingPoseSha256": dock.get("outputSha256") if dock else None,
            "openmm": relax.get("metrics") if relax else None,
            "vina": dock.get("metrics") if dock else None,
            "realizedComputeValue": round(fold_credit + relax_credit + dock_credit + render_credit, 3),
            "realizedComputeValueDefinition": "artifact/provenance completeness; not biological confidence",
        }
        evidence_path = os.path.join(run_dir, "sim", "candidates", _safe_name(accession), "structure_evidence.json")
        _atomic_json(evidence_path, evidence)
        evidence["evidencePath"] = evidence_path
        candidate_evidence.append(evidence)

    summary = {
        "schemaVersion": 4,
        "host": host_facts,
        "hostResolvedConfig": host_resolutions,
        "durationSeconds": round(time.monotonic() - started, 3),
        "budgetSeconds": budget_seconds,
        "candidateCount": len(candidates),
        "backends": detected,
        "resources": resources,
        "ran": sum(result["status"] == "ok" for result in results),
        "failed": sum(result["status"] != "ok" for result in results),
        "jobs": results,
        "skipped": skipped,
        "structureInputs": structure_inputs,
        "candidateEvidence": candidate_evidence,
    }
    _atomic_json(os.path.join(run_dir, "sim", "summary.json"), summary)
    return summary


def main(argv=None):
    parser = argparse.ArgumentParser(prog="sim_queue.py")
    sub = parser.add_subparsers(dest="cmd", required=True)
    command = sub.add_parser("run")
    source = command.add_mutually_exclusive_group(required=True)
    source.add_argument("--candidates", help="checksum-bound candidate JSON")
    source.add_argument("--candidates-fasta", help="multi-record FASTA using the shared parser")
    for flag in ("--run-dir", "--config"):
        command.add_argument(flag, required=True)
    command.add_argument("--reference")
    command.add_argument("--accession", help="run exactly one accession from the selected input")
    command.add_argument("--budget-seconds", type=int)
    args = parser.parse_args(argv)
    with open(args.config, encoding="utf-8") as fh:
        cfg = json.load(fh)
    if args.candidates_fasta:
        candidates = load_fasta_candidates(args.candidates_fasta)
    else:
        with open(args.candidates, encoding="utf-8") as fh:
            candidates = json.load(fh)
    candidates = filter_candidates(candidates, args.accession)
    summary = run(candidates, args.run_dir, cfg, args.reference, args.budget_seconds)
    print(json.dumps({"ran": summary["ran"], "failed": summary["failed"],
                      "skipped": len(summary["skipped"])}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
