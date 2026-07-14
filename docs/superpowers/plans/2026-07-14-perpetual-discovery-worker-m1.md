# Perpetual Discovery Worker — M1（オフライン骨格・改訂版 v2）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** インボックスの FASTA を既存 `BioLabExplorerPipeline` で処理し、**処理した全配列を SQLite の seen-set 台帳に記録**（アクショナブルは `verdict='actionable'`）して、クラッシュ整合・単一実行・非破壊を保証するオフライン1サイクルを作る。

**Architecture:** 既存 Swift パイプラインは無改造で再利用（`--input` に任意バッチ）。新規は bash オーケストレーション（`run_discovery_cycle.sh`）＋ **stdlib SQLite** 台帳（`discovery_db.py`）＋ JSON 状態。dedup とクラッシュ整合は SQLite の PRIMARY KEY＋単一トランザクションで担保。`DISCOVERIES.md` は台帳から毎回再生成。

**Tech Stack:** bash 3.2 / BSD userland, python3（標準ライブラリのみ・`sqlite3` 含む）, 既存 Swift 6 実行体。テストは python `unittest` ＋ シェルアサーション。

## 改訂の要点（6モデルレビュー＋ユーザー決定の反映）
v1 から変更：**(1)** 台帳を JSONL→**SQLite** 化（`INSERT OR IGNORE` でバッチ内 dedup・クラッシュ整合）、**(2)** 台帳を**seen-set**化（全処理配列を `screened`／該当を `actionable`）、**(3)** `DISCOVERIES.md`/`ledger.db` を **gitignore（ローカルのみ）**、**(4)** サイクルに **atomic-mkdir ロック・一意 run dir・非上書き processed・原子的 rotation 書込・guardrail を副作用前へ・quota・prebuilt binary・NOTIFY_CMD/LOG_DIR seam**、**(5)** status の空台帳バグ修正、**(6)** fail-closed JSON パース、**(7)** バイオセキュリティ**承認マニフェスト digest** 検証。ColabFold 除外・容量 quota は spec 側で反映。

## Global Constraints（各タスクに暗黙適用）
- 既存 Swift は**改造しない**（再利用のみ）。決定論スコアが真実源。actionable の定義は `DiscoveryValidator.qualifyingCandidateIDs` を再利用。
- **M1 はネットワークに一切触れない**。結果を外部送信しない。通知は macOS ローカルのみ。
- python3 は**標準ライブラリのみ**（`sqlite3`/`hashlib`/`json`/`argparse`/`glob`/`tempfile`/`datetime`）。
- 台帳の identity＝`sha256(配列の大文字正規化)`（accession は provenance）。dedup は sha の PRIMARY KEY。
- **fail-closed**：不正 JSON/欠落キーは握り潰さず非0終了（silent-failure 禁止）。
- **非破壊**：`processed/` へは一意名で移動し、上書きしない（AGENTS.md ユーザーデータ非破壊）。
- Platform: macOS 15+, bash 3.2/BSD, Swift 6。ブランチ: `feature/perpetual-discovery-worker`。

## File Structure
- `config/worker.json` — 実行パラメータ（quota 含む・追跡）。
- `config/approved_manifest.json` — 承認済み参照/クエリ範囲の digest＋除外規定（追跡）。
- `scripts/discovery_db.py` — SQLite seen-set 台帳＋`record`/`count-actionable` CLI。
- `scripts/run_discovery_cycle.sh` — 1サイクル（ロック・一意run・guardrail・原子書込）。
- `scripts/discovery_status.sh` — 稼働状況。
- `Tests/perpetual/…` — unittest＋シェルテスト＋fake pipeline。
- `state/`（gitignore）— `rotation.json`, `inbox/`, `inbox/processed/`, `.lock/`, `STOP`。
- `discoveries/` — `ledger.db`（gitignore）, `DISCOVERIES.md`（gitignore・ローカルのみ）。

---

### Task 1: Config・承認マニフェスト・scaffolding・gitignore

**Files:** Create `config/worker.json`, `config/approved_manifest.json`, `state/inbox/.gitkeep`, `state/inbox/processed/.gitkeep`; Modify `.gitignore`; Test `Tests/perpetual/test_config.sh`.

**Interfaces:** Produces `config/worker.json`（keys: `diskFloorGB:int`, `maxCandidates:int`, `maxWorkspaceBytes:int`, `maxLogFiles:int`）と `config/approved_manifest.json`（`referenceSha256:str`, `exclusions:list`）。

- [ ] **Step 1: 失敗するテスト**

`Tests/perpetual/test_config.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 - "$ROOT" <<'PY'
import json, os, sys, hashlib
root = sys.argv[1]
cfg = json.load(open(os.path.join(root, "config/worker.json")))
for k in ("diskFloorGB", "maxCandidates", "maxWorkspaceBytes", "maxLogFiles"):
    assert k in cfg and type(cfg[k]) is int, f"bad/missing int key: {k}"
man = json.load(open(os.path.join(root, "config/approved_manifest.json")))
assert isinstance(man.get("exclusions"), list) and man["exclusions"], "exclusions must be non-empty list"
ref = os.path.join(root, "data/curated_reference/pbp_pks_reference.fasta")
digest = "sha256:" + hashlib.sha256(open(ref, "rb").read()).hexdigest()
assert man.get("referenceSha256") == digest, f"manifest digest must match reference: {digest}"
print("config OK")
PY
```

- [ ] **Step 2: 失敗確認** — Run: `bash Tests/perpetual/test_config.sh` → FAIL（config 不在）。

- [ ] **Step 3: 実装**

`mkdir -p config Tests/perpetual state/inbox/processed` を先に実行。

`config/worker.json`:
```json
{
  "diskFloorGB": 10,
  "maxCandidates": 20,
  "maxWorkspaceBytes": 21474836480,
  "maxLogFiles": 200,
  "budgetSeconds": 21600
}
```

`config/approved_manifest.json`（`referenceSha256` は下のコマンドで実値を埋める）:
```json
{
  "referenceSha256": "sha256:REPLACE_ME",
  "querySetId": "offline-inbox",
  "reviewer": "unset",
  "reviewedDate": "2026-07-14",
  "exclusions": [
    "virulence factors",
    "toxin biosynthesis gene clusters",
    "select-agent homologs"
  ]
}
```
実 digest を埋める:
```bash
python3 - <<'PY'
import json, hashlib
p = "config/approved_manifest.json"
m = json.load(open(p))
m["referenceSha256"] = "sha256:" + hashlib.sha256(open("data/curated_reference/pbp_pks_reference.fasta","rb").read()).hexdigest()
json.dump(m, open(p,"w"), indent=2)
PY
```

`state/inbox/.gitkeep`・`state/inbox/processed/.gitkeep` を空ファイルで作成。

**`.gitignore`：既存 17 行目 `state/` を、以下の1ブロックに置換**（矛盾する `!state/…` の断片は入れない）:
```
# --- Perpetual worker runtime (local only) ---
state/*
!state/inbox/
state/inbox/*
!state/inbox/.gitkeep
!state/inbox/processed/
state/inbox/processed/*
!state/inbox/processed/.gitkeep
discoveries/ledger.db
discoveries/ledger.db-wal
discoveries/ledger.db-shm
discoveries/DISCOVERIES.md
```
検証（何も出力されなければ追跡可能）: `git check-ignore -v state/inbox/.gitkeep state/inbox/processed/.gitkeep || echo "OK: trackable"`

- [ ] **Step 4: 成功確認** — Run: `bash Tests/perpetual/test_config.sh` → PASS（`config OK`）。`git check-ignore` 検証も実施。

- [ ] **Step 5: コミット**
```bash
git add config/worker.json config/approved_manifest.json state/inbox/.gitkeep state/inbox/processed/.gitkeep .gitignore Tests/perpetual/test_config.sh
git commit -m "feat(worker): config, approved manifest, inbox scaffolding, local-only gitignore"
```

---

### Task 2: SQLite seen-set 台帳 `discovery_db.py`

**Files:** Create `scripts/discovery_db.py`; Test `Tests/perpetual/test_discovery_db.py`.

**Interfaces:**
- `seq_sha256(seq)->str`, `connect(db)->sqlite3.Connection`, `parse_fasta(path)->iter[(acc,seq)]`, `load_run(run_dir)->(qualifying:set, scores:dict)`（**fail-closed**）, `record(input_fasta, run_dir, db, discoveries_md, cycle, run_id)->int`（新規 actionable 件数）, `regenerate_discoveries_md(db, md)`。
- CLI: `record --input F --run-dir D --db DB --discoveries MD --cycle N --run-id R` / `count-actionable --db DB`。

- [ ] **Step 1: 失敗するテスト**

`Tests/perpetual/test_discovery_db.py`:
```python
import json, os, sqlite3, sys, tempfile, unittest
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "scripts"))
import discovery_db as db


def _cand(acc, seq, novelty=0.9, cls="Remote PBP"):
    return {"id": "TOP_" + acc, "sequence": {"id": acc, "sequence": seq},
            "noveltyScore": novelty, "classification": cls}


def _fixture(run_dir, candidates, qualifying):
    os.makedirs(run_dir, exist_ok=True)
    json.dump({"candidates": candidates},
              open(os.path.join(run_dir, "run-2026-01-01T00-00-00-000Z.json"), "w"))
    json.dump({"passed": bool(qualifying), "qualifyingCandidateIDs": qualifying},
              open(os.path.join(run_dir, "discovery-validation.json"), "w"))


def _fasta(path, records):
    with open(path, "w") as fh:
        for acc, seq in records:
            fh.write(f">{acc} desc\n{seq}\n")


class DiscoveryDBTests(unittest.TestCase):
    def test_sha_normalized(self):
        self.assertEqual(db.seq_sha256("acdefg"), db.seq_sha256("  ACDEFG "))

    def test_within_batch_dedup(self):
        with tempfile.TemporaryDirectory() as d:
            rd = os.path.join(d, "cycle_x")
            _fixture(rd, [_cand("A1", "MKT")], ["A1"])
            fa = os.path.join(d, "in.fasta")
            _fasta(fa, [("A1", "MKT"), ("A1", "MKT")])  # duplicate in one batch
            n = db.record(fa, rd, os.path.join(d, "l.db"), os.path.join(d, "D.md"), 1, "cycle_x")
            self.assertEqual(n, 1)  # not 2

    def test_seen_set_records_screened(self):
        with tempfile.TemporaryDirectory() as d:
            rd = os.path.join(d, "cycle_x")
            _fixture(rd, [_cand("A1", "MKT")], ["A1"])
            fa = os.path.join(d, "in.fasta")
            _fasta(fa, [("A1", "MKT"), ("B2", "MMM")])  # B2 not qualifying -> screened
            dbp = os.path.join(d, "l.db")
            db.record(fa, rd, dbp, os.path.join(d, "D.md"), 1, "cycle_x")
            con = sqlite3.connect(dbp)
            verds = dict(con.execute("SELECT accession,verdict FROM processed").fetchall())
            self.assertEqual(verds, {"A1": "actionable", "B2": "screened"})

    def test_idempotent_across_cycles(self):
        with tempfile.TemporaryDirectory() as d:
            rd = os.path.join(d, "cycle_x")
            _fixture(rd, [_cand("A1", "MKT")], ["A1"])
            fa = os.path.join(d, "in.fasta")
            _fasta(fa, [("A1", "MKT")])
            dbp, md = os.path.join(d, "l.db"), os.path.join(d, "D.md")
            self.assertEqual(db.record(fa, rd, dbp, md, 1, "r1"), 1)
            self.assertEqual(db.record(fa, rd, dbp, md, 2, "r2"), 0)  # already seen

    def test_fail_closed_on_missing_validation(self):
        with tempfile.TemporaryDirectory() as d:
            rd = os.path.join(d, "cycle_x")
            os.makedirs(rd)
            json.dump({"candidates": []}, open(os.path.join(rd, "run-x.json"), "w"))
            fa = os.path.join(d, "in.fasta"); _fasta(fa, [("A1", "MKT")])
            with self.assertRaises(Exception):
                db.record(fa, rd, os.path.join(d, "l.db"), os.path.join(d, "D.md"), 1, "r")


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: 失敗確認** — Run: `python3 Tests/perpetual/test_discovery_db.py -v` → FAIL（`No module named 'discovery_db'`）。

- [ ] **Step 3: 実装**

`scripts/discovery_db.py`:
```python
#!/usr/bin/env python3
"""SQLite seen-set ledger for the perpetual worker (stdlib-only, crash-consistent).

Records EVERY processed input sequence (verdict 'screened'), upgrading those that
meet the actionable threshold (verdict 'actionable', from DiscoveryValidator's
qualifyingCandidateIDs). Identity = canonical sequence sha256 (accession = provenance).
Dedup + crash-consistency come from the PRIMARY KEY and one transaction per cycle.
DISCOVERIES.md is regenerated from the DB. Fail-closed on contract violations.
"""
import argparse
import glob
import hashlib
import json
import os
import sqlite3
import sys
import tempfile
from datetime import datetime, timezone

SCHEMA_VERSION = 1


def seq_sha256(seq):
    return hashlib.sha256(seq.strip().upper().encode("utf-8")).hexdigest()


def _utc_now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def connect(db_path):
    os.makedirs(os.path.dirname(db_path) or ".", exist_ok=True)
    conn = sqlite3.connect(db_path)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=FULL")
    conn.execute(
        """CREATE TABLE IF NOT EXISTS processed (
            seq_sha256 TEXT PRIMARY KEY,
            accession TEXT NOT NULL,
            verdict TEXT NOT NULL CHECK (verdict IN ('actionable','screened')),
            score REAL,
            classification TEXT,
            first_seen_cycle INTEGER NOT NULL,
            run_id TEXT NOT NULL,
            ts TEXT NOT NULL,
            schema_version INTEGER NOT NULL
        )"""
    )
    conn.execute("CREATE INDEX IF NOT EXISTS idx_accession ON processed(accession)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_verdict ON processed(verdict)")
    return conn


def parse_fasta(path):
    acc, seq = None, []
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            if line.startswith(">"):
                if acc is not None:
                    yield acc, "".join(seq)
                header = line[1:].strip()
                acc = header.split()[0] if header else ""
                seq = []
            else:
                seq.append(line.strip())
    if acc is not None:
        yield acc, "".join(seq)


def _require(cond, msg):
    if not cond:
        raise ValueError(f"discovery_db: {msg}")


def load_run(run_dir):
    matches = sorted(glob.glob(os.path.join(run_dir, "run-*.json")))
    _require(matches, f"no run-*.json in {run_dir}")
    with open(matches[-1], "r", encoding="utf-8") as fh:
        run = json.load(fh)  # malformed -> raises -> fail closed
    vpath = os.path.join(run_dir, "discovery-validation.json")
    _require(os.path.exists(vpath), f"missing {vpath}")
    with open(vpath, "r", encoding="utf-8") as fh:
        validation = json.load(fh)
    _require("qualifyingCandidateIDs" in validation, "validation missing qualifyingCandidateIDs")
    qualifying = set(validation["qualifyingCandidateIDs"])
    scores = {}
    for cand in run.get("candidates", []):
        # accession is sequence.id, NOT the top-level candidate id
        acc = cand.get("sequence", {}).get("id")
        if acc is not None:
            scores[acc] = (cand.get("noveltyScore"), cand.get("classification"))
    return qualifying, scores


def record(input_fasta, run_dir, db_path, discoveries_md, cycle, run_id):
    qualifying, scores = load_run(run_dir)
    ts = _utc_now()
    conn = connect(db_path)
    new_actionable = 0
    try:
        with conn:  # single transaction: commit-or-rollback atomically
            for acc, seq in parse_fasta(input_fasta):
                if not seq:
                    continue
                sha = seq_sha256(seq)
                is_actionable = acc in qualifying
                score, classification = scores.get(acc, (None, None))
                cur = conn.execute(
                    "INSERT OR IGNORE INTO processed"
                    "(seq_sha256,accession,verdict,score,classification,"
                    "first_seen_cycle,run_id,ts,schema_version)"
                    " VALUES (?,?,?,?,?,?,?,?,?)",
                    (sha, acc, "actionable" if is_actionable else "screened",
                     score, classification, cycle, run_id, ts, SCHEMA_VERSION),
                )
                if cur.rowcount == 1 and is_actionable:
                    new_actionable += 1
    finally:
        conn.close()
    regenerate_discoveries_md(db_path, discoveries_md)
    return new_actionable


def regenerate_discoveries_md(db_path, discoveries_md):
    conn = connect(db_path)
    try:
        rows = conn.execute(
            "SELECT first_seen_cycle,accession,score,classification,ts,run_id"
            " FROM processed WHERE verdict='actionable' ORDER BY first_seen_cycle,accession"
        ).fetchall()
    finally:
        conn.close()
    target_dir = os.path.dirname(discoveries_md) or "."
    os.makedirs(target_dir, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=target_dir, suffix=".tmp")
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write("# Discoveries (actionable, de-duplicated)\n\n")
        fh.write("> Local-only triage output. Unvalidated in-silico predictions; "
                 "not for external use, publication, or wet-lab handoff without review.\n\n")
        fh.write("| cycle | accession | score | classification | when | run |\n")
        fh.write("|---|---|---|---|---|---|\n")
        for c, acc, score, cls, ts, run_id in rows:
            fh.write(f"| {c} | {acc} | {score} | {cls} | {ts} | {run_id} |\n")
    os.replace(tmp, discoveries_md)


def cmd_record(a):
    print(record(a.input, a.run_dir, a.db, a.discoveries, a.cycle, a.run_id))
    return 0


def cmd_count(a):
    conn = connect(a.db)
    try:
        print(conn.execute("SELECT COUNT(*) FROM processed WHERE verdict='actionable'").fetchone()[0])
    finally:
        conn.close()
    return 0


def main(argv=None):
    p = argparse.ArgumentParser(prog="discovery_db.py")
    sub = p.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("record")
    for flag in ("--input", "--run-dir", "--db", "--discoveries", "--run-id"):
        r.add_argument(flag, required=True)
    r.add_argument("--cycle", type=int, required=True)
    r.set_defaults(func=cmd_record)
    c = sub.add_parser("count-actionable")
    c.add_argument("--db", required=True)
    c.set_defaults(func=cmd_count)
    a = p.parse_args(argv)
    # argparse maps --run-dir -> a.run_dir, --run-id -> a.run_id
    return a.func(a)


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: 成功確認** — Run: `python3 Tests/perpetual/test_discovery_db.py -v` → PASS（5 tests）。

- [ ] **Step 5: コミット**
```bash
git add scripts/discovery_db.py Tests/perpetual/test_discovery_db.py
git commit -m "feat(worker): SQLite seen-set ledger with within-batch dedup and fail-closed parsing"
```

---

### Task 3: サイクル実行 `run_discovery_cycle.sh`（堅牢化）

**Files:** Create `scripts/run_discovery_cycle.sh`, `Tests/perpetual/fake_pipeline.sh`, `Tests/perpetual/test_cycle_offline.sh`.

**Interfaces:** env seam（既定=本番値）: `PIPELINE_CMD`, `STATE_DIR`, `RUNS_DIR`, `DISCOVERIES_DIR`, `REFERENCE`, `LOG_DIR`, `NOTIFY_CMD`, `CONFIG`。保証: **run dir 生成なし・台帳書込なし・rotation 前進なし・batch 消費なし** の graceful exit を STOP/ディスク下限/quota/空 inbox/ロック衝突で返す（一時ロックの取得/解放は除く）。

- [ ] **Step 1: 失敗するテスト**

`Tests/perpetual/fake_pipeline.sh`:
```bash
#!/usr/bin/env bash
# Test double for BioLabExplorerPipeline: writes fixture outputs to --output.
set -euo pipefail
OUT=""
while [[ $# -gt 0 ]]; do case "$1" in --output) OUT="$2"; shift 2 ;; *) shift ;; esac; done
mkdir -p "$OUT"
cat > "$OUT/run-2026-01-01T00-00-00-000Z.json" <<'JSON'
{"candidates":[{"id":"TOP","sequence":{"id":"TESTACC1","sequence":"MKTAYIAKQR"},"noveltyScore":0.9,"classification":"Remote PBP"}]}
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

sandbox() {
  local d; d="$(mktemp -d)"
  mkdir -p "$d/state/inbox/processed" "$d/runs" "$d/discoveries" "$d/ref" "$d/logs"
  printf '>ref\nMKTAYIAKQR\n' > "$d/ref/ref.fasta"
  printf '{"diskFloorGB":0,"maxCandidates":20,"maxWorkspaceBytes":1073741824000,"maxLogFiles":200,"budgetSeconds":60}' > "$d/worker.json"
  echo "$d"
}
run() {  # $1=sandbox
  STATE_DIR="$1/state" RUNS_DIR="$1/runs" DISCOVERIES_DIR="$1/discoveries" \
  REFERENCE="$1/ref/ref.fasta" LOG_DIR="$1/logs" NOTIFY_CMD="true" \
  CONFIG="$1/worker.json" PIPELINE_CMD="bash ${ROOT}/Tests/perpetual/fake_pipeline.sh" \
  bash "$CYCLE"
}
count_actionable() { python3 "${ROOT}/scripts/discovery_db.py" count-actionable --db "$1/discoveries/ledger.db"; }

# 1) STOP -> no run dir, no ledger
S="$(sandbox)"; touch "$S/state/STOP"; run "$S"
[[ -z "$(ls -A "$S/runs")" ]] || { echo "FAIL: STOP made a run"; exit 1; }
[[ ! -f "$S/discoveries/ledger.db" ]] || { echo "FAIL: STOP wrote ledger"; exit 1; }

# 2) disk-floor fires -> no run (floor above real free space)
S="$(sandbox)"; printf '{"diskFloorGB":99999999,"maxCandidates":20,"maxWorkspaceBytes":1073741824000,"maxLogFiles":200,"budgetSeconds":60}' > "$S/worker.json"
printf '>TESTACC1\nMKTAYIAKQR\n' > "$S/state/inbox/b.fasta"; run "$S"
[[ -z "$(ls -A "$S/runs")" ]] || { echo "FAIL: disk-floor did not fire"; exit 1; }
[[ -f "$S/state/inbox/b.fasta" ]] || { echo "FAIL: disk-floor consumed batch"; exit 1; }

# 3) empty inbox -> no run
S="$(sandbox)"; run "$S"
[[ -z "$(ls -A "$S/runs")" ]] || { echo "FAIL: empty inbox made a run"; exit 1; }

# 4) happy path
S="$(sandbox)"; printf '>TESTACC1\nMKTAYIAKQR\n' > "$S/state/inbox/batch1.fasta"; run "$S"
[[ "$(count_actionable "$S")" == "1" ]] || { echo "FAIL: actionable != 1"; exit 1; }
ls "$S/state/inbox/processed/"*batch1.fasta >/dev/null 2>&1 || { echo "FAIL: not moved to processed"; exit 1; }
python3 -c "import json,sys; d=json.load(open('$S/state/rotation.json')); sys.exit(0 if d.get('cycle')==1 else 1)" || { echo "FAIL: cycle != 1"; exit 1; }

# 5) dedup across cycles
S="$(sandbox)"; printf '>TESTACC1\nMKTAYIAKQR\n' > "$S/state/inbox/b1.fasta"; run "$S"
printf '>TESTACC1\nMKTAYIAKQR\n' > "$S/state/inbox/b2.fasta"; run "$S"
[[ "$(count_actionable "$S")" == "1" ]] || { echo "FAIL: dedup across cycles"; exit 1; }

# 6) non-overwriting processed: a colliding basename must not clobber
S="$(sandbox)"; printf '>TESTACC1\nMKTAYIAKQR\n' > "$S/state/inbox/dup.fasta"; run "$S"
printf '>OTHER\nMMMM\n' > "$S/state/inbox/dup.fasta"; run "$S"
[[ "$(ls "$S/state/inbox/processed/" | grep -c dup.fasta)" == "2" ]] || { echo "FAIL: processed overwrite"; exit 1; }

echo "cycle offline tests OK"
```

- [ ] **Step 2: 失敗確認** — Run: `bash Tests/perpetual/test_cycle_offline.sh` → FAIL（スクリプト不在）。

- [ ] **Step 3: 実装**

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
LOG_DIR="${LOG_DIR:-${ROOT_DIR}/logs}"
NOTIFY_CMD="${NOTIFY_CMD:-}"
if [[ -z "${PIPELINE_CMD:-}" ]]; then
  if [[ -x "${ROOT_DIR}/.build/release/BioLabExplorerPipeline" ]]; then
    PIPELINE_CMD="${ROOT_DIR}/.build/release/BioLabExplorerPipeline"
  else
    PIPELINE_CMD="swift run BioLabExplorerPipeline"
  fi
fi

INBOX="${STATE_DIR}/inbox"; PROCESSED="${INBOX}/processed"
ROTATION="${STATE_DIR}/rotation.json"; LOCK_DIR="${STATE_DIR}/.lock"
LEDGER_DB="${DISCOVERIES_DIR}/ledger.db"; DISCOVERIES_MD="${DISCOVERIES_DIR}/DISCOVERIES.md"

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }
cfg() { python3 -c "import json;print(json.load(open('${CONFIG}')).get('$1','$2'))"; }

# ---------- preflight guardrails (NO run dir / ledger / rotation side effects) ----------
if [[ -f "${STATE_DIR}/STOP" ]]; then log "STOP present -> graceful stop"; exit 0; fi
if [[ ! -s "${REFERENCE}" ]]; then log "missing reference: ${REFERENCE}"; exit 2; fi

DISK_FLOOR_GB="$(cfg diskFloorGB 10)"
FREE_GB="$(df -g "${ROOT_DIR}" | awk 'NR==2 {print $4}')"
if [[ -n "${FREE_GB}" && "${FREE_GB}" -lt "${DISK_FLOOR_GB}" ]]; then
  log "disk free ${FREE_GB}GB < floor ${DISK_FLOOR_GB}GB -> pause"; exit 0
fi

MAX_WS_BYTES="$(cfg maxWorkspaceBytes 21474836480)"
if [[ -d "${RUNS_DIR}" ]]; then
  USED_KB="$(du -sk "${RUNS_DIR}" 2>/dev/null | awk '{print $1}')"
  if [[ -n "${USED_KB:-}" && $(( USED_KB * 1024 )) -ge "${MAX_WS_BYTES}" ]]; then
    log "workspace ${USED_KB}KB >= quota -> pause (prune runs/ manually)"; exit 0
  fi
fi

# batch present? (nullglob array; no error-hiding find|head)
shopt -s nullglob; batches=("${INBOX}"/*.fasta); shopt -u nullglob
if [[ ${#batches[@]} -eq 0 ]]; then log "inbox empty -> no-op"; exit 0; fi
BATCH="${batches[0]}"

# ---------- biosecurity: reference must match approved manifest digest (fail closed) ----------
MANIFEST="${ROOT_DIR}/config/approved_manifest.json"
if [[ -f "${MANIFEST}" ]]; then
  python3 - "${MANIFEST}" "${REFERENCE}" <<'PY' || { echo "reference digest != approved manifest -> abort" >&2; exit 3; }
import hashlib, json, sys
man, ref = json.load(open(sys.argv[1])), sys.argv[2]
want = man.get("referenceSha256", "")
got = "sha256:" + hashlib.sha256(open(ref, "rb").read()).hexdigest()
sys.exit(0 if want == got else 1)
PY
fi

# ---------- single-instance lock (atomic mkdir; reclaim stale) ----------
mkdir -p "${STATE_DIR}" "${LOG_DIR}"
if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
  oldpid="$(cat "${LOCK_DIR}/pid" 2>/dev/null || echo "")"
  if [[ -n "${oldpid}" ]] && ! kill -0 "${oldpid}" 2>/dev/null; then
    log "reclaiming stale lock (pid ${oldpid})"; rm -rf "${LOCK_DIR}"
    mkdir "${LOCK_DIR}" 2>/dev/null || { log "lock race -> exit"; exit 0; }
  else
    log "another cycle holds the lock -> exit"; exit 0
  fi
fi
echo "$$" > "${LOCK_DIR}/pid"

# ---------- proceed: create run dir, compute cycle ----------
mkdir -p "${INBOX}" "${PROCESSED}" "${DISCOVERIES_DIR}" "${RUNS_DIR}"
CYCLE="$(python3 - "${ROTATION}" <<'PY'
import json, os, sys
p = sys.argv[1]; c = 0
if os.path.exists(p):
    try: c = int(json.load(open(p)).get("cycle", 0))
    except Exception: c = 0
print(c + 1)
PY
)"
MAX_CAND="$(cfg maxCandidates 20)"
TS="$(date -u +%Y%m%d_%H%M%S)"
RUN_DIR="$(mktemp -d "${RUNS_DIR}/cycle_${TS}_XXXXXX")"
RUN_ID="$(basename "${RUN_DIR}")"
touch "${RUN_DIR}/.in_progress"

finish() {
  local status=$?
  rm -f "${RUN_DIR}/.in_progress"
  if [[ "${status}" -eq 0 ]]; then date -u +"%Y-%m-%dT%H:%M:%SZ" > "${RUN_DIR}/.complete"
  else echo "status=${status}" > "${RUN_DIR}/.failed"; fi
  rmdir "${LOCK_DIR}" 2>/dev/null || rm -rf "${LOCK_DIR}" 2>/dev/null || true
}
trap finish EXIT

log "cycle=${CYCLE} run=${RUN_ID} batch=$(basename "${BATCH}")"

# discovery (existing pipeline; NO --require-discovery so empty == success)
${PIPELINE_CMD} --input "${BATCH}" --reference "${REFERENCE}" --output "${RUN_DIR}" --max "${MAX_CAND}"

# record into SQLite seen-set (fail-closed); regenerates DISCOVERIES.md from DB
NEW="$(python3 "${ROOT_DIR}/scripts/discovery_db.py" record \
  --input "${BATCH}" --run-dir "${RUN_DIR}" --db "${LEDGER_DB}" \
  --discoveries "${DISCOVERIES_MD}" --cycle "${CYCLE}" --run-id "${RUN_ID}")"
log "new_actionable=${NEW}"

# non-overwriting archival of the consumed batch
DEST="${PROCESSED}/${RUN_ID}__$(basename "${BATCH}")"
[[ -e "${DEST}" ]] && { log "processed dest exists: ${DEST}"; exit 2; }
mv "${BATCH}" "${DEST}"

# atomic rotation advance (forward-compatible keys)
python3 - "${ROTATION}" "${CYCLE}" "${RUN_ID}" <<'PY'
import json, os, sys, tempfile
p, cycle, run_id = sys.argv[1], int(sys.argv[2]), sys.argv[3]
data = {}
if os.path.exists(p):
    try: data = json.load(open(p))
    except Exception: data = {}
data.update({"schemaVersion": 1, "cycle": cycle, "updatedCycle": cycle, "lastRunId": run_id})
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(p) or ".", suffix=".tmp")
with os.fdopen(fd, "w") as fh: json.dump(data, fh)
os.replace(tmp, p)
PY

# local-only notification
if [[ "${NEW}" -gt 0 ]]; then
  if [[ -n "${NOTIFY_CMD}" ]]; then "${NOTIFY_CMD}" "${NEW} new candidate(s), cycle ${CYCLE}" || true
  else osascript -e "display notification \"${NEW} new candidate(s), cycle ${CYCLE}\" with title \"BioLab Discovery\"" 2>/dev/null || true; fi
fi

# prune worker-owned logs only (never runs/; AGENTS.md non-destructive elsewhere)
MAX_LOG_FILES="$(cfg maxLogFiles 200)"
shopt -s nullglob; logs=("${LOG_DIR}"/cycle-*.log); shopt -u nullglob
if [[ ${#logs[@]} -gt ${MAX_LOG_FILES} ]]; then
  ls -1t "${LOG_DIR}"/cycle-*.log | tail -n +$((MAX_LOG_FILES + 1)) | while read -r f; do rm -f "$f"; done
fi
log "cycle ${CYCLE} complete"
```

`chmod +x scripts/run_discovery_cycle.sh Tests/perpetual/fake_pipeline.sh`

- [ ] **Step 4: 成功確認** — Run: `bash Tests/perpetual/test_cycle_offline.sh` → PASS（`cycle offline tests OK`）。

- [ ] **Step 5: コミット**
```bash
chmod +x scripts/run_discovery_cycle.sh Tests/perpetual/fake_pipeline.sh
git add scripts/run_discovery_cycle.sh Tests/perpetual/fake_pipeline.sh Tests/perpetual/test_cycle_offline.sh
git commit -m "feat(worker): hardened offline cycle (lock, unique run, atomic state, guardrails, manifest)"
```

---

### Task 4: 稼働状況 `discovery_status.sh`

**Files:** Create `scripts/discovery_status.sh`; Test `Tests/perpetual/test_status.sh`.

**Interfaces:** seam `STATE_DIR`/`DISCOVERIES_DIR`。出力に `cycles=`, `discoveries=`, `stop=`, `network=off`, `disk_free_gb=`。`discoveries` は SQLite の actionable 件数。空/欠落でも壊れない。

- [ ] **Step 1: 失敗するテスト**

`Tests/perpetual/test_status.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STATUS="${ROOT}/scripts/discovery_status.sh"

# seeded
S="$(mktemp -d)"; mkdir -p "$S/state" "$S/discoveries"
echo '{"cycle":7,"lastRunId":"cycle_x"}' > "$S/state/rotation.json"
python3 "${ROOT}/scripts/discovery_db.py" record \
  --input <(printf '>A1 d\nMKT\n') --run-dir /dev/null --db "$S/discoveries/ledger.db" \
  --discoveries "$S/discoveries/DISCOVERIES.md" --cycle 1 --run-id r 2>/dev/null || true
python3 - "$S/discoveries/ledger.db" <<'PY'
import sqlite3,sys
c=sqlite3.connect(sys.argv[1])
c.execute("CREATE TABLE IF NOT EXISTS processed(seq_sha256 TEXT PRIMARY KEY,accession TEXT,verdict TEXT,score REAL,classification TEXT,first_seen_cycle INT,run_id TEXT,ts TEXT,schema_version INT)")
c.execute("INSERT OR IGNORE INTO processed VALUES('h1','A1','actionable',0.9,'x',1,'r','t',1)")
c.execute("INSERT OR IGNORE INTO processed VALUES('h2','A2','screened',NULL,NULL,1,'r','t',1)")
c.commit()
PY
OUT="$(STATE_DIR="$S/state" DISCOVERIES_DIR="$S/discoveries" bash "$STATUS")"; echo "$OUT"
grep -q 'cycles=7' <<<"$OUT"      || { echo FAIL cycles; exit 1; }
grep -q 'discoveries=1' <<<"$OUT" || { echo FAIL discoveries; exit 1; }
grep -q 'network=off' <<<"$OUT"   || { echo FAIL network; exit 1; }
grep -q 'stop=no' <<<"$OUT"       || { echo FAIL stop; exit 1; }

# empty/missing ledger must not corrupt output
S2="$(mktemp -d)"; mkdir -p "$S2/state" "$S2/discoveries"
OUT2="$(STATE_DIR="$S2/state" DISCOVERIES_DIR="$S2/discoveries" bash "$STATUS")"
[[ "$(grep -c 'discoveries=' <<<"$OUT2")" == "1" ]] || { echo "FAIL: empty-ledger output"; exit 1; }
grep -q 'discoveries=0' <<<"$OUT2" || { echo "FAIL: empty discoveries!=0"; exit 1; }
echo "status tests OK"
```

- [ ] **Step 2: 失敗確認** — Run: `bash Tests/perpetual/test_status.sh` → FAIL（スクリプト不在）。

- [ ] **Step 3: 実装**

`scripts/discovery_status.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${STATE_DIR:-${ROOT_DIR}/state}"
DISCOVERIES_DIR="${DISCOVERIES_DIR:-${ROOT_DIR}/discoveries}"
ROTATION="${STATE_DIR}/rotation.json"; LEDGER_DB="${DISCOVERIES_DIR}/ledger.db"

CYCLES=0; LAST="none"
if [[ -f "${ROTATION}" ]]; then
  CYCLES="$(python3 -c "import json;print(json.load(open('${ROTATION}')).get('cycle',0))" 2>/dev/null || echo 0)"
  LAST="$(python3 -c "import json;print(json.load(open('${ROTATION}')).get('lastRunId') or 'none')" 2>/dev/null || echo none)"
fi
DISCOVERIES=0
if [[ -f "${LEDGER_DB}" ]]; then
  DISCOVERIES="$(python3 "${ROOT_DIR}/scripts/discovery_db.py" count-actionable --db "${LEDGER_DB}" 2>/dev/null || echo 0)"
fi
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

- [ ] **Step 4: 成功確認** — Run: `bash Tests/perpetual/test_status.sh` → PASS（`status tests OK`）。

- [ ] **Step 5: コミット**
```bash
chmod +x scripts/discovery_status.sh
git add scripts/discovery_status.sh Tests/perpetual/test_status.sh
git commit -m "feat(worker): status readout backed by SQLite ledger"
```

---

### Task 5: end-to-end スモーク（実 Pipeline）＋ README ＋ ランナー

**Files:** Create `Tests/perpetual/run_all.sh`; Modify `README.md`.

- [ ] **Step 1: 一括ランナー**

`Tests/perpetual/run_all.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "${DIR}/test_config.sh"
python3 "${DIR}/test_discovery_db.py" -v
bash "${DIR}/test_cycle_offline.sh"
bash "${DIR}/test_status.sh"
echo "ALL M1 TESTS PASSED"
```

- [ ] **Step 2: 全テスト成功** — Run: `bash Tests/perpetual/run_all.sh` → `ALL M1 TESTS PASSED`。

- [ ] **Step 3: 実 Pipeline スモーク（1回）**

```bash
swift build -c release          # prebuilt binary（cycle が優先使用・swift run のネット/再解決回避）
# 完全な20レコードを切り出す（head -N で配列を途中切断しない）
python3 - <<'PY'
recs=[]; cur=[]
for line in open("data/public_probe/unreviewed_uncharacterized_bacteria_200.fasta"):
    if line.startswith(">") and cur:
        recs.append("".join(cur)); cur=[]
        if len(recs)==20: break
    cur.append(line)
if cur and len(recs)<20: recs.append("".join(cur))
open("state/inbox/smoke_$(date +%s).fasta","w").write("".join(recs))
print("wrote", len(recs), "records")
PY
bash scripts/run_discovery_cycle.sh
bash scripts/discovery_status.sh
```
Expected: `runs/cycle_<ts>_XXXXXX/.complete` 生成、`discovery_status.sh` が `cycles>=1`、`state/inbox/processed/<run>__smoke_*.fasta` へ移動。新規件数はデータ依存（0でも正常）。

- [ ] **Step 4: README 追記**（"Next Integration Points" 直前）
```markdown
## Perpetual Discovery Worker (M1, offline)

Consumes FASTA batches in `state/inbox/` and records every processed sequence into a
local SQLite seen-set ledger (`discoveries/ledger.db`), flagging actionable ones and
regenerating `discoveries/DISCOVERIES.md` from it. Offline only; local-only outputs.

```sh
swift build -c release
cp your_batch.fasta state/inbox/
scripts/run_discovery_cycle.sh
scripts/discovery_status.sh
```

Guardrails: `state/STOP` stops gracefully; the cycle pauses under `diskFloorGB`/`maxWorkspaceBytes`
(config/worker.json) and aborts if the reference digest ≠ `config/approved_manifest.json`.
A single-instance lock (`state/.lock`) prevents overlap. Tests: `bash Tests/perpetual/run_all.sh`.
```

- [ ] **Step 5: コミット**
```bash
chmod +x Tests/perpetual/run_all.sh
git add Tests/perpetual/run_all.sh README.md
git commit -m "test(worker): M1 runner, e2e smoke, README"
```

---

## Self-Review
**Spec coverage:** cycle→T3 / rotation(atomic,fwd-compat)→T3 / seen-set ledger(SQLite,dedup,fail-closed)→T2 / recorder(regen MD, notify)→T2,T3 / status→T4 / guardrails(STOP,disk,quota,lock,manifest)→T3 / tests(within-batch dedup, seen-set, idempotent, fail-closed, disk-floor fire, empty-ledger status, non-overwrite processed)→T2,T3,T4. ✅
**6レビュー確定フィックスの反映:** within-batch dedup(PK)✅ / atomic rotation✅ / status 空台帳✅ / guardrail 順序✅ / 一意 run dir✅ / 非上書き processed✅ / fail-closed パース✅ / NOTIFY_CMD・LOG_DIR seam・floor テスト・cycle 完全一致✅ / E2E 20-record✅ / noveltyThreshold 削除✅ / gitignore 単一編集＋DISCOVERIES/db ローカル化✅ / lock✅ / prebuilt binary✅ / MD 再生成✅ / biosecurity manifest✅.
**Placeholder scan:** `approved_manifest.json` の `REPLACE_ME` は Step 3 のコマンドで実 digest に置換する手順を明記済（プレースホルダではなく生成手順）。他になし。
**Type consistency:** `record(input,run_dir,db,discoveries_md,cycle,run_id)` の引数順が実装・テスト・CLI(`--input/--run-dir/--db/--discoveries/--cycle/--run-id`)で一致。SQLite 列名が INSERT・SELECT・status で一致。
