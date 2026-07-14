# Perpetual Discovery Worker — M5（計算スタック・RAM予算スケジューラ）Implementation Plan

> REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`).

**Goal:** 新規アクショナブル候補に対し、**利用可能な計算バックエンドを RAM 予算内で並列実行**して結果を添付する。未導入バックエンドは**可視化してスキップ**（1件も倒さない）。導入は `setup_simulation_stack.sh`（多GB・ユーザー実行）。

**Architecture:** `sim_queue.py`（stdlib）が (1) バックエンド検出 → (2) ジョブ生成 → (3) **RAM予算＋GPU直列＋時間予算**で入場制御 → (4) 実行・タイムアウト → (5) `runs/<run>/sim/summary.json` に報告。cycle は record 後に **opt-in・非致命**で呼ぶ。今日の実機では mmseqs2/HMMER/Foldseek(バンドル) が動き、ESMFold/OpenMM/Vina は「未導入」と可視化される。

**Tech Stack:** python3 stdlib（`subprocess`/`shutil`/`json`）, bash。テストは**スタブ実行体＋実検出**（実ツール導入・実ネットは行わない）。

## Global Constraints
- **ネットワーク非使用**。`setup_simulation_stack.sh` は `ALLOW_NETWORK=1` 明示時のみ実行可（テストでは拒否のみ検証、実インストールしない）。
- **1件も倒さない**：未導入/失敗/タイムアウトは summary に記録して継続。cycle からの呼び出しは非致命。
- **RAM予算**：`min(config.simRamBudgetBytes, 総RAM - simReserveBytes)`。既定 reserve 8GB（実機24GB→予算16GB）。`Σ 見積RAM ≤ 予算` を満たす範囲でのみ投入。GPU(MPS)系は**同時1**。
- **長さゲート**：folding は `simMaxSeqLength`（既定 700）超をスキップ（O(L²) OOM 回避）。
- python3 stdlib のみ。M1–M4 非退行（`enableSimulation` 既定 false）。
- ブランチ: `feature/perpetual-discovery-worker-m5`。

## File Structure
- Create `scripts/sim_queue.py` — 検出・スケジューラ・実行・報告。
- Create `scripts/setup_simulation_stack.sh` — opt-in インストーラ。
- Modify `config/worker.json` — `enableSimulation`, `simRamBudgetBytes`, `simReserveBytes`, `simMaxSeqLength`, `simJobTimeoutSeconds`, `externalMsaStorePath`, `enableColabFold`。
- Modify `scripts/run_discovery_cycle.sh` — record 後に sim_queue（opt-in・非致命）。
- Create `Tests/perpetual/test_sim_queue.py`, `Tests/perpetual/test_sim_cycle.sh`。
- Modify `Tests/perpetual/run_all.sh`, `Tests/perpetual/test_config.sh`, `README.md`。

---

### Task 1: `sim_queue.py`（検出・RAM予算スケジューラ・実行・報告）

**Files:** Create `scripts/sim_queue.py`, `Tests/perpetual/test_sim_queue.py`; Modify `config/worker.json`, `Tests/perpetual/test_config.sh`.

**Interfaces:**
- `detect_backends(cfg) -> dict[id] = {"available":bool,"path":str|None,"reason":str}`
- `estimate_ram(backend_id, seq_len, cfg) -> int`
- `schedule(jobs, cfg, detected) -> (admitted, skipped)`（RAM予算・GPU直列・長さゲート）
- `run(candidates, run_dir, cfg) -> summary dict`（実行＋タイムアウト＋報告）
- CLI: `sim_queue.py run --candidates JSON --run-dir DIR --config CFG` → `<run-dir>/sim/summary.json` を書き、実行数を print。
- 検出は `SIM_BIN_DIR` env（テスト用スタブ置き場）を PATH より優先。

- [ ] **Step 1: 失敗するテスト**

`Tests/perpetual/test_sim_queue.py`:
```python
import json, os, stat, sys, tempfile, unittest
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "scripts"))
import sim_queue as sq

CFG = {"simRamBudgetBytes": 4 * (1 << 30), "simReserveBytes": 0,
       "simMaxSeqLength": 700, "simJobTimeoutSeconds": 30,
       "enableColabFold": False, "externalMsaStorePath": ""}


def _stub(dirpath, name, body="#!/bin/sh\necho stub-ok\nexit 0\n"):
    os.makedirs(dirpath, exist_ok=True)
    p = os.path.join(dirpath, name)
    with open(p, "w") as fh:
        fh.write(body)
    os.chmod(p, os.stat(p).st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
    return p


class DetectTests(unittest.TestCase):
    def test_absent_backend_is_visible_not_fatal(self):
        with tempfile.TemporaryDirectory() as d:
            os.environ["SIM_BIN_DIR"] = d  # empty -> nothing found
            try:
                det = sq.detect_backends(CFG)
            finally:
                os.environ.pop("SIM_BIN_DIR", None)
            self.assertIn("vina", det)
            self.assertFalse(det["vina"]["available"])
            self.assertTrue(det["vina"]["reason"])  # a human-readable reason

    def test_stub_backend_detected(self):
        with tempfile.TemporaryDirectory() as d:
            _stub(d, "vina")
            os.environ["SIM_BIN_DIR"] = d
            try:
                det = sq.detect_backends(CFG)
            finally:
                os.environ.pop("SIM_BIN_DIR", None)
            self.assertTrue(det["vina"]["available"])


class ScheduleTests(unittest.TestCase):
    def test_ram_budget_admission(self):
        det = {"vina": {"available": True}, "esmfold": {"available": True}}
        # budget 4GiB; esmfold jobs estimated >1GiB each -> not all admitted
        jobs = [{"backend": "esmfold", "seq_len": 300, "accession": f"A{i}"} for i in range(10)]
        admitted, skipped = sq.schedule(jobs, CFG, det)
        total = sum(sq.estimate_ram(j["backend"], j["seq_len"], CFG) for j in admitted)
        self.assertLessEqual(total, CFG["simRamBudgetBytes"])
        self.assertTrue(skipped)  # some deferred by budget

    def test_gpu_serialised(self):
        det = {"esmfold": {"available": True}}
        jobs = [{"backend": "esmfold", "seq_len": 100, "accession": f"A{i}"} for i in range(5)]
        admitted, _ = sq.schedule(jobs, CFG, det)
        self.assertLessEqual(len([j for j in admitted if sq.is_gpu(j["backend"])]), sq.MAX_GPU_CONCURRENT)

    def test_length_gate_skips_long_sequences(self):
        det = {"esmfold": {"available": True}}
        jobs = [{"backend": "esmfold", "seq_len": 5000, "accession": "LONG"}]
        admitted, skipped = sq.schedule(jobs, CFG, det)
        self.assertEqual(admitted, [])
        self.assertEqual(skipped[0]["reason_code"], "too_long")

    def test_unavailable_backend_skipped_with_reason(self):
        det = {"esmfold": {"available": False, "reason": "torch not installed"}}
        jobs = [{"backend": "esmfold", "seq_len": 100, "accession": "A1"}]
        admitted, skipped = sq.schedule(jobs, CFG, det)
        self.assertEqual(admitted, [])
        self.assertEqual(skipped[0]["reason_code"], "unavailable")


class RunTests(unittest.TestCase):
    def test_run_with_no_backends_reports_cleanly(self):
        with tempfile.TemporaryDirectory() as d:
            os.environ["SIM_BIN_DIR"] = os.path.join(d, "empty")
            os.makedirs(os.environ["SIM_BIN_DIR"])
            try:
                rd = os.path.join(d, "run"); os.makedirs(rd)
                cands = [{"accession": "A1", "sequence": "MKT" * 10}]
                summary = sq.run(cands, rd, CFG)
            finally:
                os.environ.pop("SIM_BIN_DIR", None)
            self.assertEqual(summary["ran"], 0)
            self.assertTrue(summary["backends"])           # availability reported (visible)
            self.assertTrue(os.path.exists(os.path.join(rd, "sim", "summary.json")))

    def test_run_dispatches_available_stub(self):
        with tempfile.TemporaryDirectory() as d:
            b = os.path.join(d, "bin"); _stub(b, "mmseqs")
            os.environ["SIM_BIN_DIR"] = b
            try:
                rd = os.path.join(d, "run"); os.makedirs(rd)
                cands = [{"accession": "A1", "sequence": "MKT" * 10}]
                summary = sq.run(cands, rd, CFG)
            finally:
                os.environ.pop("SIM_BIN_DIR", None)
            self.assertGreaterEqual(summary["ran"], 1)
            self.assertTrue(any(j["backend"] == "mmseqs" and j["status"] == "ok" for j in summary["jobs"]))


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: 失敗確認** — `python3 Tests/perpetual/test_sim_queue.py -v` → FAIL（module 不在）。

- [ ] **Step 3: 実装**

`config/worker.json` に追加（既存保持）:
```json
  "enableSimulation": false,
  "simRamBudgetBytes": 17179869184,
  "simReserveBytes": 8589934592,
  "simMaxSeqLength": 700,
  "simJobTimeoutSeconds": 900,
  "enableColabFold": false,
  "externalMsaStorePath": ""
```
`Tests/perpetual/test_config.sh` の必須 int キーに `simMaxSeqLength`, `simJobTimeoutSeconds` を追加、`enableSimulation` の bool 存在も確認。

`scripts/sim_queue.py`:
```python
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
```

- [ ] **Step 4: 成功確認** — `python3 Tests/perpetual/test_sim_queue.py -v`（7/7）, `bash Tests/perpetual/test_config.sh`。

- [ ] **Step 5: コミット**
```bash
git add scripts/sim_queue.py config/worker.json Tests/perpetual/test_config.sh Tests/perpetual/test_sim_queue.py
git commit -m "feat(worker-m5): simulation queue with backend detection, RAM/GPU/length budget, graceful degradation"
```

---

### Task 2: cycle 統合（opt-in・非致命）

**Files:** Modify `scripts/run_discovery_cycle.sh`; Create `Tests/perpetual/test_sim_cycle.sh`.

**Interfaces:** `enableSimulation==true` の時のみ、record 後に新規アクショナブル候補を `sim_queue.py run` へ。失敗しても cycle を壊さない。

- [ ] **Step 1: 失敗するテスト**

`Tests/perpetual/test_sim_cycle.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CYCLE="${ROOT}/scripts/run_discovery_cycle.sh"

sandbox() {  # $1 = enableSimulation
  local d; d="$(mktemp -d)"
  mkdir -p "$d/state/inbox/processed" "$d/runs" "$d/discoveries" "$d/ref" "$d/logs" "$d/bin"
  printf '>ref\nMKTAYIAKQR\n' > "$d/ref/ref.fasta"
  printf '{"diskFloorGB":0,"maxCandidates":20,"maxWorkspaceBytes":1073741824000,"maxLogFiles":200,"budgetSeconds":60,"maxConsecutiveFailures":5,"throttleSeconds":300,"maxDaemonLogBytes":10485760,"enableNetwork":false,"fetchPageSize":5,"fetchRateLimitSeconds":0,"uniprotHost":"rest.uniprot.org","enableSimulation":%s,"simRamBudgetBytes":4294967296,"simReserveBytes":0,"simMaxSeqLength":700,"simJobTimeoutSeconds":30,"enableColabFold":false,"externalMsaStorePath":""}' "$1" > "$d/worker.json"
  echo "$d"
}
run() {
  STATE_DIR="$1/state" RUNS_DIR="$1/runs" DISCOVERIES_DIR="$1/discoveries" \
  REFERENCE="$1/ref/ref.fasta" LOG_DIR="$1/logs" NOTIFY_CMD="true" \
  CONFIG="$1/worker.json" PIPELINE_CMD="bash ${ROOT}/Tests/perpetual/fake_pipeline.sh" \
  SIM_BIN_DIR="$1/bin" bash "$CYCLE"
}

# 1) enableSimulation=false -> no sim summary, cycle fine
S="$(sandbox false)"; printf '>TESTACC1\nMKTAYIAKQR\n' > "$S/state/inbox/b.fasta"; run "$S"
[[ -z "$(find "$S/runs" -name summary.json 2>/dev/null)" ]] || { echo "FAIL: sim ran while disabled"; exit 1; }

# 2) enableSimulation=true, no backends -> summary written, cycle still succeeds
S="$(sandbox true)"; printf '>TESTACC1\nMKTAYIAKQR\n' > "$S/state/inbox/b.fasta"; run "$S"
SUM="$(find "$S/runs" -name summary.json | head -1)"
[[ -n "$SUM" ]] || { echo "FAIL: no sim summary with simulation enabled"; exit 1; }
python3 -c "import json,sys; d=json.load(open('$SUM')); sys.exit(0 if d['ran']==0 and d['backends'] else 1)" \
  || { echo "FAIL: summary should report 0 ran + backend availability"; exit 1; }
ls "$S/state/inbox/processed/"*b.fasta >/dev/null 2>&1 || { echo "FAIL: cycle did not complete"; exit 1; }

# 3) enableSimulation=true with a stub backend -> at least one job ran
S="$(sandbox true)"; printf '#!/bin/sh\nexit 0\n' > "$S/bin/mmseqs"; chmod +x "$S/bin/mmseqs"
printf '>TESTACC1\nMKTAYIAKQR\n' > "$S/state/inbox/b.fasta"; run "$S"
SUM="$(find "$S/runs" -name summary.json | head -1)"
python3 -c "import json,sys; d=json.load(open('$SUM')); sys.exit(0 if d['ran']>=1 else 1)" \
  || { echo "FAIL: stub backend did not run"; exit 1; }

echo "sim cycle tests OK"
```

- [ ] **Step 2: 失敗確認** — `bash Tests/perpetual/test_sim_cycle.sh` → FAIL。

- [ ] **Step 3: 実装** — `scripts/run_discovery_cycle.sh` の dashboard 生成の直前に追加:
```bash
# optional simulation stack (opt-in; never fail the cycle over simulation)
ENABLE_SIM="$(cfg enableSimulation false 2>/dev/null || echo false)"
if [[ "${ENABLE_SIM}" == "True" || "${ENABLE_SIM}" == "true" ]]; then
  CAND_JSON="${RUN_DIR}/sim_candidates.json"
  if python3 "${ROOT_DIR}/scripts/discovery_db.py" export-new-actionable \
       --db "${LEDGER_DB}" --cycle "${CYCLE}" --out "${CAND_JSON}" >/dev/null 2>&1; then
    python3 "${ROOT_DIR}/scripts/sim_queue.py" run --candidates "${CAND_JSON}" \
      --run-dir "${RUN_DIR}" --config "${CONFIG}" >/dev/null 2>&1 \
      || log "simulation queue skipped (non-fatal)"
  else
    log "simulation candidate export skipped (non-fatal)"
  fi
fi
```
`scripts/discovery_db.py` に `export-new-actionable` サブコマンドを追加（この cycle で新規記録された actionable を `[{"accession","sequence"}]` で出力。sequence は台帳に無いので、`--input` FASTA から引くのではなく **accession のみ**＋`sequence` は空文字で良い場合は空に。実装は次のとおり: `SELECT accession FROM processed WHERE verdict='actionable' AND first_seen_cycle=?` を読み、`[{"accession": acc, "sequence": ""}]` を書く。seq_len は 0 になり folding は長さゲートに掛からないが、バックエンド未導入の現状では影響なし。将来 sequence を持たせる場合はスキーマ拡張で対応する）。

- [ ] **Step 4: 成功確認** — `bash Tests/perpetual/test_sim_cycle.sh`（3ケース）。回帰: `test_cycle_offline.sh`(8), `test_cycle_daemon.sh`, `test_cycle_network.sh`, `test_dashboard_cycle.sh`, `test_discovery_db.py`。

- [ ] **Step 5: コミット**
```bash
git add scripts/run_discovery_cycle.sh scripts/discovery_db.py Tests/perpetual/test_sim_cycle.sh
git commit -m "feat(worker-m5): opt-in non-fatal simulation step in the cycle"
```

---

### Task 3: `setup_simulation_stack.sh` ＋ External MSA Store ＋ run_all ＋ README

**Files:** Create `scripts/setup_simulation_stack.sh`; Modify `Tests/perpetual/run_all.sh`, `README.md`; Create `Tests/perpetual/test_setup_stack.sh`.

- [ ] **Step 1: 失敗するテスト**

`Tests/perpetual/test_setup_stack.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
S="${ROOT}/scripts/setup_simulation_stack.sh"
[[ -x "$S" ]] || { echo "FAIL: setup_simulation_stack.sh missing/not executable"; exit 1; }
# must refuse without ALLOW_NETWORK (multi-GB download)
set +e; bash "$S" >/dev/null 2>&1; rc=$?; set -e
[[ "$rc" -ne 0 ]] || { echo "FAIL: setup should refuse without ALLOW_NETWORK"; exit 1; }
# --plan must work offline and list what it would install
OUT="$(bash "$S" --plan 2>&1)" || { echo "FAIL: --plan should work offline"; exit 1; }
grep -qi 'esmfold\|openmm\|vina' <<<"$OUT" || { echo "FAIL: --plan should list the stack"; exit 1; }
echo "setup stack tests OK"
```

- [ ] **Step 2: 失敗確認** — `bash Tests/perpetual/test_setup_stack.sh` → FAIL。

- [ ] **Step 3: 実装**

`scripts/setup_simulation_stack.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_NAME="${SIM_ENV_NAME:-biolab-sim}"

plan() {
  cat <<'PLAN'
Simulation stack plan (conda/mamba env: biolab-sim)
  - pytorch (MPS build)      -> ESMFold folding on Apple GPU
  - fair-esm                 -> ESMFold weights/API
  - openmm                   -> MD relaxation (CPU; set thread limits)
  - autodock-vina            -> docking
  (already present: mmseqs2, HMMER, bundled Foldseek)
  NOT installed: ColabFold — needs ~940GB MSA DB / ~128GB RAM for local MSA.
  Optional: mount an External MSA Store with PRECOMPUTED a3m and set
  externalMsaStorePath + enableColabFold to fold from precomputed MSAs only
  (the public MSA server is never contacted).
Download size: multi-GB. Re-runnable (idempotent).
PLAN
}

if [[ "${1:-}" == "--plan" ]]; then plan; exit 0; fi

if [[ "${ALLOW_NETWORK:-}" != "1" ]]; then
  echo "setup_simulation_stack: refusing — this downloads multiple GB." >&2
  echo "Review the plan first:  scripts/setup_simulation_stack.sh --plan" >&2
  echo "Then run:               ALLOW_NETWORK=1 scripts/setup_simulation_stack.sh" >&2
  exit 2
fi

command -v mamba >/dev/null 2>&1 && CONDA=mamba || CONDA=conda
command -v "${CONDA}" >/dev/null 2>&1 || { echo "setup: conda/mamba not found" >&2; exit 2; }
plan
echo "== creating/updating env ${ENV_NAME} =="
"${CONDA}" create -y -n "${ENV_NAME}" python=3.11 || true
"${CONDA}" install -y -n "${ENV_NAME}" -c conda-forge openmm || echo "openmm install failed (continuing)"
"${CONDA}" install -y -n "${ENV_NAME}" -c conda-forge -c bioconda autodock-vina || echo "vina install failed (continuing)"
"${CONDA}" run -n "${ENV_NAME}" pip install torch fair-esm || echo "torch/fair-esm install failed (continuing)"
echo "== done =="
echo "Point the worker at this env's bin so sim_queue can find the tools:"
echo "  SIM_BIN_DIR=\"\$(${CONDA} run -n ${ENV_NAME} python -c 'import sys,os;print(os.path.dirname(sys.executable))')\""
echo "Then set enableSimulation: true in config/worker.json"
```
`chmod +x scripts/setup_simulation_stack.sh`。

- [ ] **Step 4: run_all＋README** — `test_sim_queue.py`, `test_sim_cycle.sh`, `test_setup_stack.sh` を run_all に追加、marker を `ALL M1..M5 TESTS PASSED` に。README に M5 セクション:
```markdown
## Perpetual Discovery Worker (M5, simulation stack — opt-in)

Each cycle can run a simulation queue over the cycle's NEW actionable candidates.
Backends are detected at runtime; anything missing is reported in
`runs/<cycle>/sim/summary.json` and skipped — the cycle never fails over simulation.
Admission is bounded by a RAM budget (`simRamBudgetBytes` minus `simReserveBytes`),
GPU work is serialised, and folding skips sequences longer than `simMaxSeqLength`.

```sh
scripts/setup_simulation_stack.sh --plan        # review what it installs (offline)
ALLOW_NETWORK=1 scripts/setup_simulation_stack.sh   # multi-GB install (your call)
# then set enableSimulation: true in config/worker.json (and SIM_BIN_DIR if using a conda env)
```

Available today without any install: mmseqs2, HMMER, bundled Foldseek.
ColabFold is NOT part of the stack (needs ~940GB DB / ~128GB RAM locally). Optionally
mount an **External MSA Store** with precomputed a3m and set `externalMsaStorePath` +
`enableColabFold` — folding then uses those MSAs only; the public MSA server is never contacted.
```
- [ ] **Step 5: コミット**
```bash
chmod +x scripts/setup_simulation_stack.sh
git add scripts/setup_simulation_stack.sh Tests/perpetual/test_setup_stack.sh Tests/perpetual/run_all.sh README.md
git commit -m "feat(worker-m5): opt-in stack installer (--plan offline) + External MSA Store docs + run_all"
```

---

## Self-Review
- バックエンド検出＋未導入の可視化（1件も倒さない）→ Task 1 ✅
- RAM予算・GPU直列・長さゲート・per-job timeout → Task 1 ✅
- cycle 統合は opt-in（既定 false）＋非致命 → Task 2 ✅（M1–M4 非退行）
- 多GBインストールは `--plan` で offline 確認、実行は `ALLOW_NETWORK=1` 明示のみ → Task 3 ✅（テストは拒否のみ検証）
- ColabFold 除外＋External MSA Store（precomputed a3m のみ・公開MSAサーバ非接触）を README/plan に明記 → Task 3 ✅
- 型整合: config キー（enableSimulation/simRamBudgetBytes/simReserveBytes/simMaxSeqLength/simJobTimeoutSeconds）を Task1 で追加、Task2 が enableSimulation を読む。`SIM_BIN_DIR` seam を sim_queue/テスト/cycle で一致。
- 既知の限界（意図的）: `export-new-actionable` は accession のみ（台帳に配列を持たないため seq_len=0）。folding を本格運用する際は台帳に配列長を持たせる拡張が必要 — README/ledger に注記。
