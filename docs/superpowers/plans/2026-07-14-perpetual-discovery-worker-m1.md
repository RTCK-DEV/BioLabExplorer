# Perpetual Discovery Worker — M1（オフライン骨格）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** インボックスに置かれた FASTA を既存 `BioLabExplorerPipeline` で処理し、**新規のアクショナブル候補だけ**を dedup 台帳に蓄積する、オフラインで完結する1サイクル実行を作る。

**Architecture:** 既存 Swift パイプラインは無改造で再利用（`--input` に任意バッチを渡す）。新規は「bash オーケストレーション（`run_discovery_cycle.sh`）＋ python3 標準ライブラリの台帳ロジック（`discovery_lib.py`）＋ JSON 状態ファイル」の薄い層のみ。ネットワーク・シミュレーション・可視化・常駐化は後続マイルストーン（M2〜M5）。

**Tech Stack:** bash, python3（標準ライブラリのみ）, 既存 Swift 6 実行体（`swift run BioLabExplorerPipeline`）。テストは python `unittest` ＋ シェルアサーション。

## Global Constraints

各タスクの要件に暗黙的に以下を含む（仕様書§3からの写し）:
- `BioLabExplorerCore` は SwiftUI 非依存。既存 Swift コードは M1 では**改造しない**（再利用のみ）。
- 決定論的な Swift-native スコアが真実源。台帳は既存 `DiscoveryValidator.qualifyingCandidateIDs` を「アクショナブル」の定義として再利用する。
- ネットワークは既定 OFF。**M1 はネットワークに一切触れない**（インボックス消費のみ）。
- 結果を外部送信しない。通知は macOS ローカル通知（`osascript`）のみ。
- 新規の重依存を足さない：python3 は**標準ライブラリのみ**（`hashlib`/`json`/`argparse`/`glob`/`datetime`）。
- 台帳の dedup キー：`accession = candidate.sequence.id` と `seqSha256 = sha256(candidate.sequence.sequence を大文字正規化)`。
- Platform: macOS 15+, Swift 6。作業ブランチ: `feature/perpetual-discovery-worker`。

---

## File Structure

- `config/worker.json` — 実行パラメータ（追跡）。責務: 閾値・ディスク下限・最大候補数の単一設定源。
- `scripts/discovery_lib.py` — python3 台帳ライブラリ＋`record` CLI。責務: run出力のパース・dedup・台帳/DISCOVERIES追記。
- `scripts/run_discovery_cycle.sh` — 1サイクルのオーケストレーション。責務: preflight→バッチ選択→Pipeline呼出→記録→状態前進。
- `scripts/discovery_status.sh` — 稼働状況の可読サマリ。責務: サイクル数・新規累計・ディスク・STOP・ネット可否の表示。
- `Tests/perpetual/test_discovery_lib.py` — `discovery_lib.py` の unittest。
- `Tests/perpetual/fake_pipeline.sh` — テスト用のダミー Pipeline（fixture出力）。
- `Tests/perpetual/test_cycle_offline.sh` — サイクルのガードレール＋ハッピーパスのシェルテスト。
- `Tests/perpetual/test_status.sh` — status のシェルテスト。
- `state/`（gitignore済）— `rotation.json`, `inbox/`, `inbox/processed/`, `STOP`。
- `discoveries/` — `ledger.jsonl`（gitignore追加）, `DISCOVERIES.md`（追跡）。
- `.gitignore` — `discoveries/ledger.jsonl` を追加。

---

### Task 1: Worker config ＋ scaffolding ＋ gitignore

**Files:**
- Create: `config/worker.json`
- Create: `state/inbox/.gitkeep`, `state/inbox/processed/.gitkeep`
- Modify: `.gitignore`（`discoveries/ledger.jsonl` を追加。`state/` は既に無視済のため `.gitkeep` は `!` で明示追跡）
- Test: `Tests/perpetual/test_config.sh`

**Interfaces:**
- Produces: `config/worker.json` に少なくとも `diskFloorGB:int`, `maxCandidates:int`, `noveltyThreshold:number`, `budgetSeconds:int` を持つ。後続タスクが `python3 -c "json.load(...)"` で読む。

- [ ] **Step 1: 失敗するテストを書く**

`Tests/perpetual/test_config.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 - "$ROOT/config/worker.json" <<'PY'
import json, sys
cfg = json.load(open(sys.argv[1]))
for k, t in {"diskFloorGB": int, "maxCandidates": int, "budgetSeconds": int}.items():
    assert k in cfg, f"missing key: {k}"
    assert isinstance(cfg[k], t), f"{k} wrong type"
assert "noveltyThreshold" in cfg
print("config OK")
PY
```

- [ ] **Step 2: テストが失敗するのを確認**

Run: `bash Tests/perpetual/test_config.sh`
Expected: FAIL（`config/worker.json` が無いため `FileNotFoundError`）

- [ ] **Step 3: 最小実装**

`config/worker.json`:
```json
{
  "diskFloorGB": 10,
  "maxCandidates": 20,
  "noveltyThreshold": 0.85,
  "budgetSeconds": 21600,
  "inboxDir": "state/inbox"
}
```

`state/inbox/.gitkeep` と `state/inbox/processed/.gitkeep`（空ファイル）を作成。

`.gitignore` に追記（`# --- Python environments ---` の直前）:
```
# --- Perpetual-worker ledger (runtime, unbounded) ---
discoveries/ledger.jsonl

# keep empty inbox scaffolding tracked despite state/ ignore
!state/inbox/.gitkeep
!state/inbox/processed/.gitkeep
```
注: `state/` 全体を無視しているため `!state/inbox/.gitkeep` はネスト無視配下で効かない。代わりに `.gitignore` の `state/` 行を `state/*` に変更し、直後に `!state/inbox/` `state/inbox/*` `!state/inbox/.gitkeep` を追加する:
```
state/*
!state/inbox/
state/inbox/*
!state/inbox/.gitkeep
!state/inbox/processed/
state/inbox/processed/*
!state/inbox/processed/.gitkeep
```
（既存の `state/` 行を上記ブロックへ置換する）

- [ ] **Step 4: テストが通るのを確認**

Run: `bash Tests/perpetual/test_config.sh`
Expected: PASS（`config OK`）

- [ ] **Step 5: コミット**

```bash
git add config/worker.json state/inbox/.gitkeep state/inbox/processed/.gitkeep .gitignore Tests/perpetual/test_config.sh
git commit -m "feat(worker): add worker config and inbox scaffolding"
```

---

### Task 2: 台帳ライブラリ `discovery_lib.py`（dedup＋記録）

**Files:**
- Create: `scripts/discovery_lib.py`
- Test: `Tests/perpetual/test_discovery_lib.py`

**Interfaces:**
- Consumes: run出力ディレクトリ（`run-*.json` と `discovery-validation.json`）。
- Produces:
  - `seq_sha256(seq: str) -> str`
  - `load_ledger(path: str) -> tuple[set, set]`（accession集合, sha集合）
  - `extract_actionable(run_dir: str) -> list[dict]`（各要素 `{accession, seqSha256, novelty, classification}`）
  - `record(run_dir, ledger_path, discoveries_md, cycle:int) -> int`（新規件数を返し、台帳/DISCOVERIESに追記）
  - CLI: `python3 scripts/discovery_lib.py record --run-dir D --ledger L --discoveries M --cycle N` → stdout に新規件数を print。

- [ ] **Step 1: 失敗するテストを書く**

`Tests/perpetual/test_discovery_lib.py`:
```python
import json, os, sys, tempfile, unittest
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "scripts"))
import discovery_lib as dl


def _cand(acc, seq, novelty=0.9, cls="Remote PBP"):
    return {"sequence": {"id": acc, "sequence": seq},
            "noveltyScore": novelty, "classification": cls}


def _write_fixture(run_dir, candidates, qualifying):
    os.makedirs(run_dir, exist_ok=True)
    with open(os.path.join(run_dir, "run-2026-01-01T00-00-00-000Z.json"), "w") as fh:
        json.dump({"candidates": candidates}, fh)
    with open(os.path.join(run_dir, "discovery-validation.json"), "w") as fh:
        json.dump({"passed": bool(qualifying),
                   "qualifyingCandidateIDs": qualifying}, fh)


class DiscoveryLibTests(unittest.TestCase):
    def test_sha_is_normalized(self):
        self.assertEqual(dl.seq_sha256("acdefg"), dl.seq_sha256("  ACDEFG "))

    def test_extract_only_qualifying(self):
        with tempfile.TemporaryDirectory() as d:
            rd = os.path.join(d, "cycle_x")
            _write_fixture(rd, [_cand("A1", "MKT"), _cand("B2", "MMM")], ["A1"])
            got = [c["accession"] for c in dl.extract_actionable(rd)]
            self.assertEqual(got, ["A1"])

    def test_record_is_idempotent(self):
        with tempfile.TemporaryDirectory() as d:
            rd = os.path.join(d, "cycle_x")
            _write_fixture(rd, [_cand("A1", "MKT")], ["A1"])
            ledger = os.path.join(d, "ledger.jsonl")
            md = os.path.join(d, "DISCOVERIES.md")
            self.assertEqual(dl.record(rd, ledger, md, 1), 1)
            self.assertEqual(dl.record(rd, ledger, md, 2), 0)
            with open(ledger) as fh:
                self.assertEqual(sum(1 for _ in fh), 1)
            self.assertTrue(os.path.exists(md))


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: テストが失敗するのを確認**

Run: `python3 -m unittest Tests.perpetual.test_discovery_lib -v`
（`Tests/__init__.py` と `Tests/perpetual/__init__.py` が無い場合は `python3 Tests/perpetual/test_discovery_lib.py -v`）
Expected: FAIL（`ModuleNotFoundError: No module named 'discovery_lib'`）

- [ ] **Step 3: 最小実装**

`scripts/discovery_lib.py`:
```python
#!/usr/bin/env python3
"""Dedup ledger + actionable-discovery recording for the perpetual worker.

Offline, stdlib-only. Reuses existing BioLabExplorerPipeline outputs:
  run-<ts>.json              full DiscoveryRun (candidates[].sequence.{id,sequence}, noveltyScore, classification)
  discovery-validation.json  DiscoveryValidation (passed, qualifyingCandidateIDs)
"""
import argparse
import glob
import hashlib
import json
import os
import sys
from datetime import datetime, timezone


def seq_sha256(seq: str) -> str:
    return hashlib.sha256(seq.strip().upper().encode("utf-8")).hexdigest()


def _utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def load_ledger(path):
    accs, shas = set(), set()
    if not os.path.exists(path):
        return accs, shas
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue
            if entry.get("accession"):
                accs.add(entry["accession"])
            if entry.get("seqSha256"):
                shas.add(entry["seqSha256"])
    return accs, shas


def _find_run_json(run_dir):
    matches = sorted(glob.glob(os.path.join(run_dir, "run-*.json")))
    if not matches:
        raise FileNotFoundError(f"no run-*.json in {run_dir}")
    return matches[-1]


def extract_actionable(run_dir):
    with open(_find_run_json(run_dir), "r", encoding="utf-8") as fh:
        run = json.load(fh)
    with open(os.path.join(run_dir, "discovery-validation.json"), "r", encoding="utf-8") as fh:
        validation = json.load(fh)
    qualifying = set(validation.get("qualifyingCandidateIDs", []))
    out = []
    for cand in run.get("candidates", []):
        seq = cand.get("sequence", {})
        acc = seq.get("id")
        if acc in qualifying:
            out.append({
                "accession": acc,
                "seqSha256": seq_sha256(seq.get("sequence", "")),
                "novelty": cand.get("noveltyScore"),
                "classification": cand.get("classification"),
            })
    return out


def _append_discoveries_md(path, new, cycle, run_dir, ts):
    exists = os.path.exists(path)
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "a", encoding="utf-8") as fh:
        if not exists:
            fh.write("# Discoveries (actionable, de-duplicated)\n\n")
            fh.write("| cycle | accession | novelty | classification | when | run |\n")
            fh.write("|---|---|---|---|---|---|\n")
        for a in new:
            fh.write(f"| {cycle} | {a['accession']} | {a['novelty']} | "
                     f"{a['classification']} | {ts} | {os.path.basename(run_dir)} |\n")


def record(run_dir, ledger_path, discoveries_md, cycle):
    accs, shas = load_ledger(ledger_path)
    actionable = extract_actionable(run_dir)
    new = [a for a in actionable
           if a["accession"] not in accs and a["seqSha256"] not in shas]
    os.makedirs(os.path.dirname(ledger_path) or ".", exist_ok=True)
    ts = _utc_now()
    with open(ledger_path, "a", encoding="utf-8") as fh:
        for a in new:
            fh.write(json.dumps({
                "seqSha256": a["seqSha256"],
                "accession": a["accession"],
                "firstSeenCycle": cycle,
                "novelty": a["novelty"],
                "classification": a["classification"],
                "verdict": "actionable",
                "ts": ts,
            }, ensure_ascii=False) + "\n")
    if new:
        _append_discoveries_md(discoveries_md, new, cycle, run_dir, ts)
    return len(new)


def main(argv=None):
    parser = argparse.ArgumentParser(prog="discovery_lib.py")
    sub = parser.add_subparsers(dest="cmd", required=True)
    rec = sub.add_parser("record")
    rec.add_argument("--run-dir", required=True)
    rec.add_argument("--ledger", required=True)
    rec.add_argument("--discoveries", required=True)
    rec.add_argument("--cycle", type=int, required=True)
    args = parser.parse_args(argv)
    if args.cmd == "record":
        print(record(args.run_dir, args.ledger, args.discoveries, args.cycle))
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: テストが通るのを確認**

Run: `python3 Tests/perpetual/test_discovery_lib.py -v`
Expected: PASS（3 tests OK）

- [ ] **Step 5: コミット**

```bash
git add scripts/discovery_lib.py Tests/perpetual/test_discovery_lib.py
git commit -m "feat(worker): dedup ledger library with actionable-discovery recording"
```

---

### Task 3: サイクル実行 `run_discovery_cycle.sh`（オフライン）

**Files:**
- Create: `scripts/run_discovery_cycle.sh`
- Create: `Tests/perpetual/fake_pipeline.sh`
- Test: `Tests/perpetual/test_cycle_offline.sh`

**Interfaces:**
- Consumes: `config/worker.json`, `scripts/discovery_lib.py record`, 既存 `swift run BioLabExplorerPipeline`。
- テスト用シーム（env override、既定は本番値）: `PIPELINE_CMD`, `STATE_DIR`, `RUNS_DIR`, `DISCOVERIES_DIR`, `REFERENCE`。
- Produces: 1サイクルを実行し、新規アクショナブル候補を台帳へ追記、処理済 FASTA を `inbox/processed/` へ移動、`rotation.json` の `cycle` を前進。副作用ゼロの graceful exit を STOP/ディスク下限/空インボックスで返す。

- [ ] **Step 1: 失敗するテストを書く**

`Tests/perpetual/fake_pipeline.sh`:
```bash
#!/usr/bin/env bash
# Test double for BioLabExplorerPipeline: writes fixture outputs to --output.
set -euo pipefail
OUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --output) OUT="$2"; shift 2 ;;
    *) shift ;;
  esac
done
mkdir -p "$OUT"
cat > "$OUT/run-2026-01-01T00-00-00-000Z.json" <<'JSON'
{"candidates":[{"sequence":{"id":"TESTACC1","sequence":"MKTAYIAKQR"},"noveltyScore":0.9,"classification":"Remote PBP"}]}
JSON
cat > "$OUT/discovery-validation.json" <<'JSON'
{"passed":true,"qualifyingCandidateIDs":["TESTACC1"]}
JSON
```

`Tests/perpetual/test_cycle_offline.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CYCLE="${ROOT}/scripts/run_discovery_cycle.sh"

new_sandbox() {
  local d; d="$(mktemp -d)"
  mkdir -p "$d/state/inbox/processed" "$d/runs" "$d/discoveries" "$d/ref"
  printf '>ref\nMKTAYIAKQR\n' > "$d/ref/ref.fasta"
  echo "$d"
}
run_cycle() {  # $1=sandbox
  STATE_DIR="$1/state" RUNS_DIR="$1/runs" DISCOVERIES_DIR="$1/discoveries" \
  REFERENCE="$1/ref/ref.fasta" \
  PIPELINE_CMD="bash ${ROOT}/Tests/perpetual/fake_pipeline.sh" \
  CONFIG="${ROOT}/config/worker.json" \
  bash "$CYCLE"
}

# 1) STOP -> graceful, no run dir
S="$(new_sandbox)"; touch "$S/state/STOP"
run_cycle "$S"
[[ -z "$(ls -A "$S/runs")" ]] || { echo "FAIL: STOP produced a run"; exit 1; }

# 2) empty inbox -> no-op
S="$(new_sandbox)"
run_cycle "$S"
[[ -z "$(ls -A "$S/runs")" ]] || { echo "FAIL: empty inbox produced a run"; exit 1; }

# 3) happy path -> 1 ledger entry, processed moved, cycle advanced
S="$(new_sandbox)"
printf '>TESTACC1\nMKTAYIAKQR\n' > "$S/state/inbox/batch1.fasta"
run_cycle "$S"
[[ "$(wc -l < "$S/discoveries/ledger.jsonl" | tr -d ' ')" == "1" ]] || { echo "FAIL: ledger != 1"; exit 1; }
[[ -f "$S/state/inbox/processed/batch1.fasta" ]] || { echo "FAIL: not moved to processed"; exit 1; }
grep -q '"cycle": 1' <(python3 -c "import json;print(json.dumps(json.load(open('$S/state/rotation.json'))))") || { echo "FAIL: cycle not advanced"; exit 1; }

# 4) dedup -> same sequence in a new batch yields 0 new
printf '>TESTACC1\nMKTAYIAKQR\n' > "$S/state/inbox/batch2.fasta"
run_cycle "$S"
[[ "$(wc -l < "$S/discoveries/ledger.jsonl" | tr -d ' ')" == "1" ]] || { echo "FAIL: dedup failed"; exit 1; }

echo "cycle offline tests OK"
```

- [ ] **Step 2: テストが失敗するのを確認**

Run: `bash Tests/perpetual/test_cycle_offline.sh`
Expected: FAIL（`run_discovery_cycle.sh` が無く `bash: .../run_discovery_cycle.sh: No such file`）

- [ ] **Step 3: 最小実装**

`scripts/run_discovery_cycle.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

CONFIG="${CONFIG:-${ROOT_DIR}/config/worker.json}"
STATE_DIR="${STATE_DIR:-${ROOT_DIR}/state}"
RUNS_DIR="${RUNS_DIR:-${ROOT_DIR}/runs}"
DISCOVERIES_DIR="${DISCOVERIES_DIR:-${ROOT_DIR}/discoveries}"
REFERENCE="${REFERENCE:-${ROOT_DIR}/data/curated_reference/pbp_pks_reference.fasta}"
LOG_DIR="${ROOT_DIR}/logs"
PIPELINE_CMD="${PIPELINE_CMD:-swift run BioLabExplorerPipeline}"

INBOX="${STATE_DIR}/inbox"
PROCESSED="${INBOX}/processed"
ROTATION="${STATE_DIR}/rotation.json"
LEDGER="${DISCOVERIES_DIR}/ledger.jsonl"
DISCOVERIES_MD="${DISCOVERIES_DIR}/DISCOVERIES.md"

mkdir -p "${INBOX}" "${PROCESSED}" "${LOG_DIR}" "${DISCOVERIES_DIR}" "${RUNS_DIR}"
[[ -f "${ROTATION}" ]] || echo '{"cycle": 0, "lastRunDir": null}' > "${ROTATION}"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }
cfg() { python3 -c "import json;print(json.load(open('${CONFIG}')).get('$1','$2'))"; }

DISK_FLOOR_GB="$(cfg diskFloorGB 10)"
MAX_CAND="$(cfg maxCandidates 20)"
CYCLE="$(python3 -c "import json;print(json.load(open('${ROTATION}')).get('cycle',0)+1)")"

# --- preflight ---
if [[ -f "${STATE_DIR}/STOP" ]]; then log "STOP present -> graceful stop"; exit 0; fi
FREE_GB="$(df -g "${ROOT_DIR}" | awk 'NR==2 {print $4}')"
if [[ "${FREE_GB}" -lt "${DISK_FLOOR_GB}" ]]; then
  log "disk free ${FREE_GB}GB < floor ${DISK_FLOOR_GB}GB -> pause"; exit 0
fi
if [[ ! -s "${REFERENCE}" ]]; then log "missing reference: ${REFERENCE}"; exit 2; fi

# --- pick next inbox batch ---
BATCH="$(find "${INBOX}" -maxdepth 1 -name '*.fasta' -type f | sort | head -1 || true)"
if [[ -z "${BATCH}" ]]; then log "inbox empty -> no-op"; exit 0; fi
log "cycle=${CYCLE} batch=$(basename "${BATCH}")"

TS="$(date -u +%Y%m%d_%H%M%S)"
RUN_DIR="${RUNS_DIR}/cycle_${TS}"
mkdir -p "${RUN_DIR}"
touch "${RUN_DIR}/.in_progress"
finish() {
  local status=$?
  rm -f "${RUN_DIR}/.in_progress"
  if [[ "${status}" -eq 0 ]]; then
    date -u +"%Y-%m-%dT%H:%M:%SZ" > "${RUN_DIR}/.complete"
  else
    echo "status=${status}" > "${RUN_DIR}/.failed"
  fi
}
trap finish EXIT

# --- discovery (reuse existing pipeline; NO --require-discovery so empty is normal) ---
${PIPELINE_CMD} --input "${BATCH}" --reference "${REFERENCE}" --output "${RUN_DIR}" --max "${MAX_CAND}"

# --- record only NEW actionable discoveries ---
NEW="$(python3 "${ROOT_DIR}/scripts/discovery_lib.py" record \
  --run-dir "${RUN_DIR}" --ledger "${LEDGER}" --discoveries "${DISCOVERIES_MD}" --cycle "${CYCLE}")"
log "new_actionable=${NEW}"

# --- advance state ---
mv "${BATCH}" "${PROCESSED}/"
python3 - "$ROTATION" "$CYCLE" "$RUN_DIR" <<'PY'
import json, sys
path, cycle, run_dir = sys.argv[1], int(sys.argv[2]), sys.argv[3]
data = json.load(open(path))
data["cycle"] = cycle
data["lastRunDir"] = run_dir
json.dump(data, open(path, "w"))
PY

# --- notify (local only) ---
if [[ "${NEW}" -gt 0 ]]; then
  osascript -e "display notification \"${NEW} new candidate(s), cycle ${CYCLE}\" with title \"BioLab Discovery\"" 2>/dev/null || true
fi
log "cycle ${CYCLE} complete"
```

`chmod +x scripts/run_discovery_cycle.sh Tests/perpetual/fake_pipeline.sh`

- [ ] **Step 4: テストが通るのを確認**

Run: `bash Tests/perpetual/test_cycle_offline.sh`
Expected: PASS（`cycle offline tests OK`）

- [ ] **Step 5: コミット**

```bash
chmod +x scripts/run_discovery_cycle.sh Tests/perpetual/fake_pipeline.sh
git add scripts/run_discovery_cycle.sh Tests/perpetual/fake_pipeline.sh Tests/perpetual/test_cycle_offline.sh
git commit -m "feat(worker): offline discovery cycle with STOP/disk guardrails and dedup"
```

---

### Task 4: 稼働状況 `discovery_status.sh`

**Files:**
- Create: `scripts/discovery_status.sh`
- Test: `Tests/perpetual/test_status.sh`

**Interfaces:**
- Consumes: `state/rotation.json`, `discoveries/ledger.jsonl`, `state/STOP`。テストシーム: `STATE_DIR`, `DISCOVERIES_DIR`。
- Produces: 人間可読の複数行サマリを stdout に出力（`cycles=`, `discoveries=`, `stop=`, `network=off`, `disk_free_gb=` を含む）。

- [ ] **Step 1: 失敗するテストを書く**

`Tests/perpetual/test_status.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STATUS="${ROOT}/scripts/discovery_status.sh"
S="$(mktemp -d)"; mkdir -p "$S/state" "$S/discoveries"
echo '{"cycle": 7, "lastRunDir": "runs/cycle_x"}' > "$S/state/rotation.json"
printf '%s\n' '{"accession":"A1"}' '{"accession":"A2"}' > "$S/discoveries/ledger.jsonl"

OUT="$(STATE_DIR="$S/state" DISCOVERIES_DIR="$S/discoveries" bash "$STATUS")"
echo "$OUT"
grep -q 'cycles=7' <<<"$OUT"       || { echo "FAIL: cycles"; exit 1; }
grep -q 'discoveries=2' <<<"$OUT"  || { echo "FAIL: discoveries"; exit 1; }
grep -q 'network=off' <<<"$OUT"    || { echo "FAIL: network"; exit 1; }
grep -q 'stop=no' <<<"$OUT"        || { echo "FAIL: stop"; exit 1; }
echo "status tests OK"
```

- [ ] **Step 2: テストが失敗するのを確認**

Run: `bash Tests/perpetual/test_status.sh`
Expected: FAIL（`discovery_status.sh` が無い）

- [ ] **Step 3: 最小実装**

`scripts/discovery_status.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${STATE_DIR:-${ROOT_DIR}/state}"
DISCOVERIES_DIR="${DISCOVERIES_DIR:-${ROOT_DIR}/discoveries}"
ROTATION="${STATE_DIR}/rotation.json"
LEDGER="${DISCOVERIES_DIR}/ledger.jsonl"

CYCLES=0; LAST="none"
if [[ -f "${ROTATION}" ]]; then
  CYCLES="$(python3 -c "import json;print(json.load(open('${ROTATION}')).get('cycle',0))")"
  LAST="$(python3 -c "import json;print(json.load(open('${ROTATION}')).get('lastRunDir') or 'none')")"
fi
DISCOVERIES=0
[[ -f "${LEDGER}" ]] && DISCOVERIES="$(grep -c '' "${LEDGER}" 2>/dev/null || echo 0)"
STOP="no"; [[ -f "${STATE_DIR}/STOP" ]] && STOP="yes"
FREE_GB="$(df -g "${ROOT_DIR}" | awk 'NR==2 {print $4}')"

echo "BioLab Perpetual Discovery — status"
echo "cycles=${CYCLES}"
echo "discoveries=${DISCOVERIES}"
echo "last_run=${LAST}"
echo "stop=${STOP}"
echo "network=off"
echo "disk_free_gb=${FREE_GB}"
```

- [ ] **Step 4: テストが通るのを確認**

Run: `bash Tests/perpetual/test_status.sh`
Expected: PASS（`status tests OK`）

- [ ] **Step 5: コミット**

```bash
chmod +x scripts/discovery_status.sh
git add scripts/discovery_status.sh Tests/perpetual/test_status.sh
git commit -m "feat(worker): discovery status readout"
```

---

### Task 5: 実 Pipeline での end-to-end スモーク ＋ README

**Files:**
- Create: `Tests/perpetual/run_all.sh`（全 M1 テストの一括ランナー）
- Modify: `README.md`（"Perpetual Discovery Worker (M1)" セクション追記）

**Interfaces:**
- Consumes: Task 1〜4 の全成果物、実 `swift run BioLabExplorerPipeline`。
- Produces: `Tests/perpetual/run_all.sh` が全テストを実行。README に手動 e2e 手順を記載。

- [ ] **Step 1: 一括ランナーを書く**

`Tests/perpetual/run_all.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "${DIR}/test_config.sh"
python3 "${DIR}/test_discovery_lib.py" -v
bash "${DIR}/test_cycle_offline.sh"
bash "${DIR}/test_status.sh"
echo "ALL M1 TESTS PASSED"
```

- [ ] **Step 2: 全テストが通るのを確認**

Run: `bash Tests/perpetual/run_all.sh`
Expected: PASS（`ALL M1 TESTS PASSED`）

- [ ] **Step 3: 実 Pipeline での手動 e2e（1回のみ）**

Run:
```bash
# 既存の検証済みクエリセットの先頭20件をインボックスへ（小さく速く）
mkdir -p state/inbox
head -80 data/public_probe/unreviewed_uncharacterized_bacteria_200.fasta > state/inbox/smoke.fasta 2>/dev/null \
  || cp data/curated_reference/pbp_pks_reference.fasta state/inbox/smoke.fasta
bash scripts/run_discovery_cycle.sh
bash scripts/discovery_status.sh
```
Expected: `runs/cycle_<ts>/.complete` が生成され、`discovery_status.sh` が `cycles=1` 以上を表示。`state/inbox/processed/smoke.fasta` へ移動済。（新規件数はデータ依存で0でも正常。）

- [ ] **Step 4: README にセクション追記**

`README.md` の "Next Integration Points" セクションの直前に追記:
```markdown
## Perpetual Discovery Worker (M1, offline)

Consumes FASTA batches dropped into `state/inbox/` and records only
**new, de-duplicated actionable candidates** into `discoveries/ledger.jsonl`
and `discoveries/DISCOVERIES.md`. Offline only; no network in M1.

```sh
# drop a FASTA batch, then run one cycle
cp your_batch.fasta state/inbox/
scripts/run_discovery_cycle.sh
scripts/discovery_status.sh
```

Guardrails: create `state/STOP` to stop gracefully; the cycle pauses when
free disk falls below `config/worker.json:diskFloorGB`. Tests: `bash Tests/perpetual/run_all.sh`.
```

- [ ] **Step 5: コミット**

```bash
chmod +x Tests/perpetual/run_all.sh
git add Tests/perpetual/run_all.sh README.md
git commit -m "test(worker): M1 test runner and README section"
```

---

## Self-Review

**1. Spec coverage（仕様書§8 M1 の要件）:**
- cycle runner → Task 3 ✓
- rotation（カーソル前進）→ Task 3（`rotation.json` の `cycle`）✓
- ledger（dedup）→ Task 2 ✓
- recorder（runs/・DISCOVERIES・通知）→ Task 2＋3 ✓
- status → Task 4 ✓
- inbox 消費で新規のみ蓄積 → Task 3 ✓
- テスト1 dedup 冪等性 → Task 2 `test_record_is_idempotent` ✓
- テスト2 カーソル前進 → Task 3 happy-path の cycle=1 検証 ✓
- テスト3 オフライン no-op（ネット非接触）→ Task 3 empty-inbox no-op ＋ Global Constraints でネット未使用 ✓
- テスト4 ガードレール発火（STOP・ディスク下限）→ Task 3 STOP ケース ✓（ディスク下限は実装済・巨大floorでの発火テストは M2 の launchd テストで統合するか、必要なら Task 3 に追加）

**2. Placeholder scan:** "TBD"/"TODO"/"適切に実装" 等なし。各コード手順に実コードを記載。✓

**3. Type consistency:** `record(run_dir, ledger_path, discoveries_md, cycle)` の引数順が Task 2 の実装・テスト・Task 3 の CLI 呼出（`--run-dir/--ledger/--discoveries/--cycle`）で一致。`seqSha256`/`accession` のキー名が lib・ledger 書込・`load_ledger` 読取で一致。✓

**ギャップ修正:** ディスク下限「発火」の自動テストが未カバー。Task 3 の `test_cycle_offline.sh` に次を追加してよい（任意・低リスク）: `CONFIG` を `diskFloorGB` 巨大値の一時JSONに差し替えて `run_cycle` → run ディレクトリ非生成をアサート。実装は既にあるため追加はテストのみ。
