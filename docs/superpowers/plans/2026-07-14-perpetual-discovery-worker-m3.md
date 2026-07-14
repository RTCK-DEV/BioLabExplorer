# Perpetual Discovery Worker — M3（ネット回転取得・opt-in）Implementation Plan

> REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`).

**Goal:** UniProt から **cursor ページング**で新バッチを取得して inbox を補充し、ワーカーが尽きずに回り続ける。既定 OFF、`ALLOW_NETWORK=1` 明示時のみ実ネット発火。host 許可制・レート制限・承認 manifest fail-closed。

**Architecture:** 取得は独立モジュール `fetch_uniprot.py`（1回=1ページ）。cycle は inbox 空かつ `enableNetwork` の時だけ fetch を呼んで補充→既存フローで処理。テストは **fixture トランスポート**（`UNIPROT_FIXTURE_DIR`）で実ネット非接触。実ネットは `ALLOW_NETWORK=1` gate。

**Tech Stack:** python3 stdlib（`urllib`）, bash 3.2/BSD。テストは fixture（ネット無し）。

## Global Constraints
- 既定でネット非使用。実ネットは `ALLOW_NETWORK=1` かつ host==`uniprotHost` の時のみ。fixture 時はネットに触れない。
- **ネット取得経路は承認 manifest fail-closed**：manifest 不在→abort（オフライン inbox 経路は従来どおり manifest 任意）。参照 digest ＋ query_rotation digest の両方を検証。
- 既存 M1/M2 テスト（オフライン）を壊さない：`enableNetwork` 既定 false なので cycle の fetch 分岐は既定でスキップ。
- python3 stdlib のみ。ブランチ: `feature/perpetual-discovery-worker-m3`。

## File Structure
- Create `scripts/fetch_uniprot.py` — cursor ページ取得（fixture/実ネット両対応・envelope）。
- Create `config/query_rotation.json` — 承認済みクエリ集合。
- Modify `config/worker.json` — `enableNetwork`, `fetchPageSize`, `fetchRateLimitSeconds`, `uniprotHost`。
- Modify `config/approved_manifest.json` — `querySetDigest` 追加。
- Modify `scripts/run_discovery_cycle.sh` — inbox 空＋enableNetwork で fetch 補充（manifest+scope fail-closed 前置）。
- Modify `scripts/discovery_status.sh` — `network=` を config から導出。
- Create `Tests/perpetual/test_fetch_uniprot.py`, `Tests/perpetual/test_cycle_network.sh`。
- Modify `Tests/perpetual/run_all.sh`, `Tests/perpetual/test_config.sh`, `README.md`。

---

### Task 1: `fetch_uniprot.py` ＋ query_rotation ＋ config

**Files:** Create `scripts/fetch_uniprot.py`, `config/query_rotation.json`; Modify `config/worker.json`, `Tests/perpetual/test_config.sh`; Create `Tests/perpetual/test_fetch_uniprot.py`.

**Interfaces:** `fetch_uniprot.py --config C --query-rotation QR --rotation R --inbox I` → 1ページを `I/uniprot_<qid>_<ts>.fasta` に書き、`R` の `queryIndex`/`nextCursor` を前進、出力パスを print。fixture: `UNIPROT_FIXTURE_DIR` セットで `page-<i>.fasta`(+`page-<i>.next`) を順に返す。実ネットは `ALLOW_NETWORK=1` かつ host==uniprotHost のみ。

- [ ] **Step 1: 失敗するテスト**

`Tests/perpetual/test_fetch_uniprot.py`:
```python
import json, os, sys, tempfile, unittest
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "scripts"))
import fetch_uniprot as fu


def _write(p, s):
    with open(p, "w") as fh: fh.write(s)


class FetchTests(unittest.TestCase):
    def test_no_network_without_optin(self):
        # no fixture, no ALLOW_NETWORK -> must refuse (never touch network)
        os.environ.pop("UNIPROT_FIXTURE_DIR", None); os.environ.pop("ALLOW_NETWORK", None)
        with self.assertRaises(SystemExit):
            fu.fetch_page("https://rest.uniprot.org/uniprotkb/search?x=1", "rest.uniprot.org", 0)

    def test_host_allowlist(self):
        os.environ.pop("UNIPROT_FIXTURE_DIR", None); os.environ["ALLOW_NETWORK"] = "1"
        try:
            with self.assertRaises(SystemExit):
                fu.fetch_page("https://evil.example.com/x", "rest.uniprot.org", 0)
        finally:
            os.environ.pop("ALLOW_NETWORK", None)

    def test_fixture_page_and_cursor_advance(self):
        with tempfile.TemporaryDirectory() as d:
            fx = os.path.join(d, "fx"); os.makedirs(fx)
            _write(os.path.join(fx, "page-0.fasta"), ">tr|A1|A1_X d\nMKT\n")
            _write(os.path.join(fx, "page-0.next"), "https://rest.uniprot.org/uniprotkb/search?cursor=abc")
            _write(os.path.join(fx, "page-1.fasta"), ">tr|B2|B2_X d\nMMM\n")
            # page-1 has no .next -> query should roll over
            os.environ["UNIPROT_FIXTURE_DIR"] = fx
            cfg = os.path.join(d, "worker.json"); _write(cfg, json.dumps({"uniprotHost": "rest.uniprot.org", "fetchPageSize": 200, "fetchRateLimitSeconds": 0}))
            qr = os.path.join(d, "qr.json"); _write(qr, json.dumps({"schemaVersion": 1, "queries": [{"id": "q1", "uniprotQuery": "x"}, {"id": "q2", "uniprotQuery": "y"}]}))
            rot = os.path.join(d, "rotation.json"); _write(rot, json.dumps({}))
            inbox = os.path.join(d, "inbox"); os.makedirs(inbox)
            try:
                out1 = fu.main(["--config", cfg, "--query-rotation", qr, "--rotation", rot, "--inbox", inbox])
                self.assertEqual(out1, 0)
                r = json.load(open(rot))
                self.assertEqual(r["queryIndex"], 0)          # still on q1 (has next)
                self.assertTrue(r["nextCursor"].endswith("cursor=abc"))
                self.assertEqual(len(os.listdir(inbox)), 1)
                fu.main(["--config", cfg, "--query-rotation", qr, "--rotation", rot, "--inbox", inbox])
                r = json.load(open(rot))
                self.assertEqual(r["queryIndex"], 1)          # page-1 had no next -> advanced to q2
                self.assertIsNone(r["nextCursor"])
            finally:
                os.environ.pop("UNIPROT_FIXTURE_DIR", None)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: 失敗確認** — `python3 Tests/perpetual/test_fetch_uniprot.py -v` → FAIL（module 不在）。

- [ ] **Step 3: 実装**

`config/query_rotation.json`:
```json
{
  "schemaVersion": 1,
  "queries": [
    {
      "id": "bacteria-uncharacterized",
      "uniprotQuery": "(reviewed:false) AND (protein_name:\"Uncharacterized protein\") AND (taxonomy_id:2)"
    }
  ]
}
```

`config/worker.json` に追加（既存値保持）:
```json
  "enableNetwork": false,
  "fetchPageSize": 200,
  "fetchRateLimitSeconds": 1,
  "uniprotHost": "rest.uniprot.org"
```
`test_config.sh` に int キー `fetchPageSize` を必須検証へ追加、`enableNetwork` の存在（bool）も確認。

`scripts/fetch_uniprot.py`:
```python
#!/usr/bin/env python3
"""Opt-in, cursor-paged UniProt fetcher. Refills state/inbox with ONE FASTA page.

Envelope: never touches the network unless ALLOW_NETWORK=1 AND the URL host equals
the configured uniprotHost. For tests, set UNIPROT_FIXTURE_DIR to serve canned pages
(page-0.fasta [+ page-0.next], page-1.fasta, ...) so the suite never hits UniProt.
"""
import argparse
import json
import os
import sys
import tempfile
import time
import urllib.parse
import urllib.request
from datetime import datetime, timezone


def _utc():
    return datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")


def _load(path, default):
    try:
        with open(path) as fh:
            return json.load(fh)
    except Exception:
        return default


def build_initial_url(host, query, page_size):
    qs = urllib.parse.urlencode({"query": query, "format": "fasta", "size": str(page_size)})
    return f"https://{host}/uniprotkb/search?{qs}"


def _host_of(url):
    return urllib.parse.urlparse(url).hostname or ""


def _parse_next(link_header):
    if not link_header:
        return None
    for part in link_header.split(","):
        seg = part.split(";")
        if len(seg) >= 2 and 'rel="next"' in seg[1]:
            return seg[0].strip().strip("<>")
    return None


def fetch_page(url, host_allow, rate_limit):
    """Return (body_bytes, next_url_or_None). Fixture transport for tests; real network is opt-in."""
    fx = os.environ.get("UNIPROT_FIXTURE_DIR")
    if fx:
        idx_path = os.path.join(fx, ".idx")
        i = int(_load(idx_path, {"i": 0}).get("i", 0))
        with open(os.path.join(fx, f"page-{i}.fasta"), "rb") as fh:
            body = fh.read()
        nxt_path = os.path.join(fx, f"page-{i}.next")
        nxt = open(nxt_path).read().strip() if os.path.exists(nxt_path) else None
        with open(idx_path, "w") as fh:
            json.dump({"i": i + 1}, fh)
        return body, (nxt or None)
    if os.environ.get("ALLOW_NETWORK") != "1":
        raise SystemExit("fetch_uniprot: network not allowed (set ALLOW_NETWORK=1) and no UNIPROT_FIXTURE_DIR")
    if _host_of(url) != host_allow:
        raise SystemExit(f"fetch_uniprot: host '{_host_of(url)}' not in allowlist ('{host_allow}')")
    if rate_limit > 0:
        time.sleep(rate_limit)
    req = urllib.request.Request(url, headers={"User-Agent": "BioLabExplorer/1.0 (research triage; local)"})
    with urllib.request.urlopen(req, timeout=60) as resp:
        body = resp.read()
        nxt = _parse_next(resp.headers.get("Link"))
    if nxt and _host_of(nxt) != host_allow:
        nxt = None  # never follow an off-allowlist next link
    return body, nxt


def _atomic_write_json(path, data):
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".", suffix=".tmp")
    with os.fdopen(fd, "w") as fh:
        json.dump(data, fh)
    os.replace(tmp, path)


def main(argv=None):
    ap = argparse.ArgumentParser(prog="fetch_uniprot.py")
    for flag in ("--config", "--query-rotation", "--rotation", "--inbox"):
        ap.add_argument(flag, required=True)
    a = ap.parse_args(argv)

    cfg = _load(a.config, {})
    host = cfg.get("uniprotHost", "rest.uniprot.org")
    page_size = int(cfg.get("fetchPageSize", 200))
    rate = float(cfg.get("fetchRateLimitSeconds", 1))

    qr = _load(a.query_rotation, {"queries": []})
    queries = qr.get("queries", [])
    if not queries:
        raise SystemExit("fetch_uniprot: no queries in query_rotation.json")

    rot = _load(a.rotation, {})
    qidx = int(rot.get("queryIndex", 0)) % len(queries)
    cursor = rot.get("nextCursor")
    q = queries[qidx]
    url = cursor if cursor else build_initial_url(host, q["uniprotQuery"], page_size)

    body, nxt = fetch_page(url, host, rate)

    os.makedirs(a.inbox, exist_ok=True)
    out = os.path.join(a.inbox, f"uniprot_{q['id']}_{_utc()}.fasta")
    with open(out, "wb") as fh:
        fh.write(body)

    if nxt:
        rot["queryIndex"] = qidx
        rot["nextCursor"] = nxt
    else:
        rot["queryIndex"] = (qidx + 1) % len(queries)
        rot["nextCursor"] = None
    rot["schemaVersion"] = 1
    _atomic_write_json(a.rotation, rot)
    print(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 4: 成功確認** — `python3 Tests/perpetual/test_fetch_uniprot.py -v`（3/3）, `bash Tests/perpetual/test_config.sh`。

- [ ] **Step 5: コミット**
```bash
git add scripts/fetch_uniprot.py config/query_rotation.json config/worker.json Tests/perpetual/test_config.sh Tests/perpetual/test_fetch_uniprot.py
git commit -m "feat(worker-m3): opt-in cursor-paged UniProt fetcher (fixture-testable, host-allowlisted)"
```

---

### Task 2: cycle ネット補充統合 ＋ status 導出

**Files:** Modify `scripts/run_discovery_cycle.sh`, `scripts/discovery_status.sh`; Create `Tests/perpetual/test_cycle_network.sh`.

**Interfaces:** cycle は inbox 空かつ `enableNetwork==true` の時のみ、**manifest（参照＋querySet digest）を fail-closed 検証してから** `fetch_uniprot.py` で補充→処理。status は `network=on|off` を config から導出。

- [ ] **Step 1: 失敗するテスト**

`Tests/perpetual/test_cycle_network.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CYCLE="${ROOT}/scripts/run_discovery_cycle.sh"

sandbox() {  # $1 = enableNetwork (true/false)
  local d; d="$(mktemp -d)"
  mkdir -p "$d/state/inbox/processed" "$d/runs" "$d/discoveries" "$d/ref" "$d/logs" "$d/cfg" "$d/fx"
  printf '>ref\nMKTAYIAKQR\n' > "$d/ref/ref.fasta"
  # fixture: one page whose accession matches the fake pipeline's qualifying id
  printf '>tr|TESTACC1|X d\nMKTAYIAKQR\n' > "$d/fx/page-0.fasta"
  printf '{"diskFloorGB":0,"maxCandidates":20,"maxWorkspaceBytes":1073741824000,"maxLogFiles":200,"budgetSeconds":60,"maxConsecutiveFailures":5,"throttleSeconds":300,"maxDaemonLogBytes":10485760,"enableNetwork":%s,"fetchPageSize":5,"fetchRateLimitSeconds":0,"uniprotHost":"rest.uniprot.org"}' "$1" > "$d/cfg/worker.json"
  printf '{"schemaVersion":1,"queries":[{"id":"q1","uniprotQuery":"x"}]}' > "$d/cfg/query_rotation.json"
  echo "$d"
}
manifest() {  # $1=sandbox : write an approved manifest matching the fixture ref
  local d="$1" refd qrd
  refd="$(python3 -c 'import hashlib,sys;print("sha256:"+hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$d/ref/ref.fasta")"
  qrd="$(python3 -c 'import hashlib,sys;print("sha256:"+hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$d/cfg/query_rotation.json")"
  printf '{"referenceSha256":"%s","querySetDigest":"%s","exclusions":["x"]}' "$refd" "$qrd" > "$d/cfg/approved_manifest.json"
}
run() {  # $1=sandbox
  STATE_DIR="$1/state" RUNS_DIR="$1/runs" DISCOVERIES_DIR="$1/discoveries" \
  REFERENCE="$1/ref/ref.fasta" LOG_DIR="$1/logs" NOTIFY_CMD="true" \
  CONFIG="$1/cfg/worker.json" PIPELINE_CMD="bash ${ROOT}/Tests/perpetual/fake_pipeline.sh" \
  UNIPROT_FIXTURE_DIR="$1/fx" bash "$CYCLE"
}
count_actionable() { python3 "${ROOT}/scripts/discovery_db.py" count-actionable --db "$1/discoveries/ledger.db"; }

# 1) enableNetwork=false + empty inbox -> no-op (no fetch), no run
S="$(sandbox false)"; manifest "$S"; run "$S"
[[ -z "$(ls -A "$S/runs")" ]] || { echo "FAIL: fetched with network disabled"; exit 1; }

# 2) enableNetwork=true + empty inbox + manifest present -> fetch (fixture) + process
S="$(sandbox true)"; manifest "$S"; run "$S"
[[ "$(count_actionable "$S")" == "1" ]] || { echo "FAIL: network refill+process did not record actionable"; exit 1; }

# 3) enableNetwork=true + empty inbox + manifest ABSENT -> fail-closed (no fetch, nonzero)
S="$(sandbox true)"    # no manifest() call
set +e; run "$S"; rc=$?; set -e
[[ "$rc" -ne 0 ]] || { echo "FAIL: network fetch without manifest should fail-closed"; exit 1; }
[[ -z "$(ls -A "$S/state/inbox")" || ! -e "$S/state/inbox"/uniprot_* ]] 2>/dev/null || { echo "FAIL: fetched despite absent manifest"; exit 1; }

echo "cycle network tests OK"
```

- [ ] **Step 2: 失敗確認** — `bash Tests/perpetual/test_cycle_network.sh` → FAIL。

- [ ] **Step 3: 実装**

`scripts/run_discovery_cycle.sh` の「batch present?」ブロックを次へ置換（MANIFEST 定義を前方へ移動）:
```bash
MANIFEST="$(dirname "${CONFIG}")/approved_manifest.json"

# batch present? (nullglob array; no error-hiding find|head)
shopt -s nullglob; batches=("${INBOX}"/*.fasta); shopt -u nullglob
if [[ ${#batches[@]} -eq 0 ]]; then
  ENABLE_NET="$(cfg enableNetwork false 2>/dev/null || echo false)"
  if [[ "${ENABLE_NET}" == "True" || "${ENABLE_NET}" == "true" ]]; then
    # network refill is FAIL-CLOSED: require an approved manifest matching BOTH the
    # curated reference and the approved query set before any fetch.
    QR="$(dirname "${CONFIG}")/query_rotation.json"
    if [[ ! -f "${MANIFEST}" ]]; then log "network refill requires approved_manifest.json (absent) -> abort"; exit 3; fi
    python3 - "${MANIFEST}" "${REFERENCE}" "${QR}" <<'PY' || { echo "manifest/query-scope mismatch -> abort" >&2; exit 3; }
import hashlib, json, sys
man = json.load(open(sys.argv[1]))
def d(p): return "sha256:" + hashlib.sha256(open(p, "rb").read()).hexdigest()
ok = man.get("referenceSha256") == d(sys.argv[2]) and man.get("querySetDigest") == d(sys.argv[3])
sys.exit(0 if ok else 1)
PY
    mkdir -p "${INBOX}"
    log "inbox empty + network enabled -> fetching UniProt page"
    python3 "${ROOT_DIR}/scripts/fetch_uniprot.py" --config "${CONFIG}" \
      --query-rotation "${QR}" --rotation "${ROTATION}" --inbox "${INBOX}" || { log "fetch failed"; exit 4; }
    shopt -s nullglob; batches=("${INBOX}"/*.fasta); shopt -u nullglob
  fi
  if [[ ${#batches[@]} -eq 0 ]]; then log "inbox empty -> no-op"; exit 0; fi
fi
BATCH="${batches[0]}"
```
（既存の後段 manifest reference-digest チェックはそのまま残す＝オフライン inbox 経路の互換。ネット経路は上の fail-closed が先に効く。）

`scripts/discovery_status.sh`: `echo "network=off"` を次へ:
```bash
NET="$(python3 -c "import json;print('on' if json.load(open('${ROOT_DIR}/config/worker.json')).get('enableNetwork') else 'off')" 2>/dev/null || echo off)"
echo "network=${NET}"
```
（テスト `test_status.sh` は seam の DISCOVERIES/STATE のみ上書きで config は本番を読む＝既定 false→`network=off` のままなので既存アサーション維持。）

- [ ] **Step 4: 成功確認** — `bash Tests/perpetual/test_cycle_network.sh`（3ケース）, 回帰 `bash Tests/perpetual/test_cycle_offline.sh`(8), `test_cycle_daemon.sh`, `test_status.sh`。

- [ ] **Step 5: コミット**
```bash
git add scripts/run_discovery_cycle.sh scripts/discovery_status.sh Tests/perpetual/test_cycle_network.sh
git commit -m "feat(worker-m3): fail-closed network inbox refill + status network derivation"
```

---

### Task 3: manifest querySetDigest ＋ run_all ＋ README

**Files:** Modify `config/approved_manifest.json`, `Tests/perpetual/run_all.sh`, `README.md`.

- [ ] **Step 1: manifest に querySetDigest を実値で追加**
```bash
python3 - <<'PY'
import json, hashlib
p = "config/approved_manifest.json"; m = json.load(open(p))
m["querySetDigest"] = "sha256:" + hashlib.sha256(open("config/query_rotation.json","rb").read()).hexdigest()
m["querySetId"] = "bacteria-uncharacterized"
json.dump(m, open(p, "w"), indent=2)
PY
```

- [ ] **Step 2: run_all に追加** — `test_fetch_uniprot.py` と `test_cycle_network.sh` を追記、marker を `ALL M1+M2+M3 TESTS PASSED` に更新。Run: `bash Tests/perpetual/run_all.sh` → PASS。

- [ ] **Step 3: README（M2 セクションの後に）**
```markdown
## Perpetual Discovery Worker (M3, network rotation — opt-in)

To keep finding NEW candidates, enable UniProt fetching (cursor-paged, one page/cycle):
set `enableNetwork: true` in `config/worker.json`, ensure `config/approved_manifest.json`
matches BOTH the curated reference AND `config/query_rotation.json` (digests), then run the
daemon with the network switch ON:

```sh
ALLOW_NETWORK=1 scripts/run_discovery_cycle.sh    # one networked cycle (manual)
```

Envelope: never hits the network unless `ALLOW_NETWORK=1` AND the host is `uniprotHost`;
rate-limited; fail-closed if the manifest is absent or the reference/query digests don't match.
The approved query set lives in `config/query_rotation.json` — editing it requires re-approving
the manifest digest (biosecurity scope control).
```

- [ ] **Step 4: コミット**
```bash
git add config/approved_manifest.json Tests/perpetual/run_all.sh README.md
git commit -m "docs(worker-m3): manifest querySetDigest + run_all + README network section"
```

---

## Self-Review
- opt-in fetch（fixture/実ネット・host許可・rate limit・ALLOW_NETWORK gate）→ Task 1 ✅
- cursor ページング＋query ローテ（rotation.json 前進）→ Task 1 ✅
- ネット経路 manifest fail-closed（参照＋querySet digest、不在→abort）→ Task 2 ✅
- 既定 OFF で M1/M2 非退行 → Task 2（enableNetwork=false 分岐スキップ）＋回帰確認。
- status の network をconfig導出（既定false→"off" で既存テスト維持）→ Task 2 ✅
- Placeholder/型整合: config キー（enableNetwork/fetchPageSize/…）を Task1 で追加、Task2 が enableNetwork を読む、Task3 が querySetDigest を実値化。fetch の rotation キー（queryIndex/nextCursor）と cycle の rotation キー（cycle/updatedCycle/lastRunId）は別キーで merge 共存。
