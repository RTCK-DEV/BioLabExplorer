#!/usr/bin/env python3
"""Host capability detection and "auto" resolution for config/worker.json.

Machine-specific tuning values in config/worker.json may be written as the
string "auto". resolve_config() replaces them with concrete values derived from
the running host, so one checked-in config works on any machine instead of
encoding the original author's 15-core / 24 GiB workstation.

Explicit values always win: a key that is not "auto" is never overridden.
Detection failures fall back to conservative constants rather than raising, so
a resolved config is always produced.

CLI:
    python3 scripts/host_profile.py                      # host facts as JSON
    python3 scripts/host_profile.py --config c.json      # resolved config JSON
    python3 scripts/host_profile.py --config c.json --explain
    python3 scripts/host_profile.py --config c.json --key simRamBudgetBytes
"""

import argparse
import json
import os
import platform
import shutil
import subprocess
import sys

GIB = 1024 ** 3
AUTO = "auto"

# Keys that accept "auto". Order matters: simReserveBytes is resolved before
# simRamBudgetBytes because the budget is derived from the reserve.
AUTO_KEYS = (
    "simReserveBytes",
    "simRamBudgetBytes",
    "maxWorkspaceBytes",
    "simMaxCpuJobs",
    "esmfoldDevice",
)

# openmmPlatform is deliberately NOT resolved here. openmm_relax.py probes the
# platforms for real, in order, and records every attempt in its metrics file.
# Guessing here as well produced two different "auto" answers for one question,
# and the guess was the one that could be wrong.

# Conservative fallbacks used when the host cannot be probed.
FALLBACK_MEMORY_BYTES = 8 * GIB
FALLBACK_FREE_DISK_BYTES = 20 * GIB

MIN_RESERVE_BYTES = 4 * GIB
MIN_RAM_BUDGET_BYTES = 1 * GIB
MIN_WORKSPACE_BYTES = 5 * GIB
MAX_WORKSPACE_BYTES = 20 * GIB


def _root():
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def logical_cpus():
    return max(1, os.cpu_count() or 1)


def physical_memory_bytes():
    """Total physical RAM in bytes, or None when it cannot be determined."""
    system = platform.system()
    if system == "Darwin":
        try:
            probe = subprocess.run(
                ["sysctl", "-n", "hw.memsize"], capture_output=True, text=True, timeout=10
            )
        except (OSError, subprocess.SubprocessError):
            return None
        value = probe.stdout.strip()
        if probe.returncode == 0 and value.isdigit():
            return int(value)
        return None
    if system == "Linux":
        try:
            with open("/proc/meminfo", encoding="utf-8") as handle:
                for line in handle:
                    if line.startswith("MemTotal:"):
                        parts = line.split()
                        if len(parts) >= 2 and parts[1].isdigit():
                            return int(parts[1]) * 1024
        except OSError:
            return None
    return None


def free_disk_bytes(path=None):
    """Free bytes on the volume holding `path`, or None when unavailable."""
    target = path or _root()
    try:
        return shutil.disk_usage(target).free
    except OSError:
        return None


def has_nvidia_gpu():
    return shutil.which("nvidia-smi") is not None


def is_apple_silicon():
    return platform.system() == "Darwin" and platform.machine() == "arm64"


def detect(path=None):
    """Return the raw host facts the auto rules are derived from."""
    memory = physical_memory_bytes()
    disk = free_disk_bytes(path)
    return {
        "system": platform.system(),
        "machine": platform.machine(),
        "release": platform.release(),
        "logicalCpuCount": logical_cpus(),
        "physicalMemoryBytes": memory,
        "physicalMemoryDetected": memory is not None,
        "freeDiskBytes": disk,
        "freeDiskDetected": disk is not None,
        "appleSilicon": is_apple_silicon(),
        "nvidiaGpuDetected": has_nvidia_gpu(),
    }


def _clamp(value, low, high):
    return max(low, min(high, value))


def _auto_reserve_bytes(host):
    total = host.get("physicalMemoryBytes") or FALLBACK_MEMORY_BYTES
    return max(MIN_RESERVE_BYTES, total // 3)


def _auto_ram_budget_bytes(host, reserve):
    total = host.get("physicalMemoryBytes") or FALLBACK_MEMORY_BYTES
    return max(MIN_RAM_BUDGET_BYTES, total - reserve)


def _auto_workspace_bytes(host):
    free = host.get("freeDiskBytes") or FALLBACK_FREE_DISK_BYTES
    return _clamp(free // 4, MIN_WORKSPACE_BYTES, MAX_WORKSPACE_BYTES)


def _auto_esmfold_device(host):
    return "mps" if host.get("appleSilicon") else "cpu"


def resolve_config(cfg, path=None, host=None):
    """Return (resolved_config, notes). The input mapping is not mutated."""
    resolved = dict(cfg)
    host = host or detect(path)
    notes = []

    def record(key, value, reason):
        resolved[key] = value
        notes.append({"key": key, "value": value, "reason": reason})

    if resolved.get("simReserveBytes") == AUTO:
        reserve = _auto_reserve_bytes(host)
        record(
            "simReserveBytes",
            reserve,
            "one third of physical RAM, at least 4 GiB, left to the rest of the system",
        )

    if resolved.get("simRamBudgetBytes") == AUTO:
        reserve_value = resolved.get("simReserveBytes")
        reserve = reserve_value if isinstance(reserve_value, int) else _auto_reserve_bytes(host)
        record(
            "simRamBudgetBytes",
            _auto_ram_budget_bytes(host, reserve),
            "physical RAM minus the reserve",
        )

    if resolved.get("maxWorkspaceBytes") == AUTO:
        record(
            "maxWorkspaceBytes",
            _auto_workspace_bytes(host),
            "one quarter of free disk, clamped to 5-20 GiB",
        )

    if resolved.get("simMaxCpuJobs") == AUTO:
        record("simMaxCpuJobs", 0, "0 means every logical CPU may take a job")

    if resolved.get("esmfoldDevice") == AUTO:
        record(
            "esmfoldDevice",
            _auto_esmfold_device(host),
            "Metal (mps) on Apple Silicon, CPU elsewhere",
        )

    return resolved, notes


def load_resolved(config_path, host=None):
    """Load a worker config from disk with every "auto" value resolved."""
    with open(config_path, encoding="utf-8") as handle:
        cfg = json.load(handle)
    resolved, _ = resolve_config(cfg, path=os.path.dirname(os.path.abspath(config_path)), host=host)
    return resolved


def _format_bytes(value):
    if not isinstance(value, int) or value < 0:
        return str(value)
    if value >= GIB:
        return f"{value / GIB:.2f} GiB"
    return f"{value} B"


def main(argv=None):
    parser = argparse.ArgumentParser(prog="host_profile.py")
    parser.add_argument("--config", help="worker config whose auto values should be resolved")
    parser.add_argument("--key", help="print a single resolved config value and exit")
    parser.add_argument("--explain", action="store_true", help="describe every auto resolution")
    args = parser.parse_args(argv)

    host = detect()
    if not args.config:
        print(json.dumps(host, indent=2, sort_keys=True))
        return 0

    with open(args.config, encoding="utf-8") as handle:
        cfg = json.load(handle)
    resolved, notes = resolve_config(
        cfg, path=os.path.dirname(os.path.abspath(args.config)), host=host
    )

    if args.key:
        if args.key not in resolved:
            print(f"host_profile: unknown key: {args.key}", file=sys.stderr)
            return 2
        print(resolved[args.key])
        return 0

    if args.explain:
        print(f"host: {host['system']} {host['machine']}, {host['logicalCpuCount']} logical CPUs, "
              f"RAM {_format_bytes(host['physicalMemoryBytes'] or 0)}"
              f"{'' if host['physicalMemoryDetected'] else ' (undetected, fallback used)'}")
        if not notes:
            print("no auto values in this config; nothing was derived")
        for note in notes:
            value = note["value"]
            shown = _format_bytes(value) if note["key"].endswith("Bytes") else value
            print(f"  {note['key']} = {shown}  ({note['reason']})")
        return 0

    print(json.dumps(resolved, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
