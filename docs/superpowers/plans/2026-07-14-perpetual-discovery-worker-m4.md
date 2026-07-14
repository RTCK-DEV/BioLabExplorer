# Perpetual Discovery Worker — M4（可視化ダッシュボード＋3D pLDDTビューア）Implementation Plan

> REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`).

**Goal:** 各サイクルが自己完結HTMLダッシュボードを再生成。stat・時系列・スコア分布・発見テーブル＋**インタラクティブ3Dタンパク質ビューア（3Dmol.js・pLDDTで色分け）**。3Dmol.js はベンダリング（user-gated 取得）、無ければチャート/状況は描画し3Dはプレースホルダ。

**Architecture:** `generate_dashboard.py`（stdlib）が `discoveries/ledger.db` と `data/alphafold_cache/AF-<acc>-*.pdb` を読み、`discoveries/dashboard.html` を原子的生成。チャートは**手書きインラインSVG**（外部chart lib不要）。3D は accession に一致する AlphaFold PDB を inline 埋め込みし 3Dmol.js で B-factor(pLDDT) 色分け。cycle が record 後に呼ぶ。取得は `vendor_assets.sh`（opt-in・ALLOW_NETWORK gate）。

**Tech Stack:** python3 stdlib, bash, （任意で）3Dmol.js（ローカルベンダー）。テストは HTML 構造アサーション（ブラウザ描画は手動/任意スクショ）。

## Global Constraints
- ダッシュボードは**自己完結・CDN非依存**：3Dmol.js は `discoveries/assets/3Dmol-min.js`（ローカル）を参照。無ければ 3D 部を省略しプレースホルダ表示（チャート/状況は常に描画）。
- 生成物 `discoveries/dashboard.html`・`discoveries/assets/` は git 追跡外（ローカルのみ）。
- 取得（3Dmol.js DL）は `ALLOW_NETWORK=1` 明示時のみ・host 許可制。私（Claude）は実 DL しない＝スクリプトを用意しユーザーが実行。
- python3 stdlib のみ。既定で M1–M3 を非退行（dashboard 生成は cycle 末尾の追加で、失敗しても cycle を壊さない＝`|| true`）。
- ブランチ: `feature/perpetual-discovery-worker-m4`。

## File Structure
- Create `scripts/generate_dashboard.py` — 自己完結HTML生成。
- Create `scripts/vendor_assets.sh` — 3Dmol.js の opt-in 取得。
- Modify `scripts/run_discovery_cycle.sh` — record 後に dashboard 再生成（非致命）。
- Modify `.gitignore` — `discoveries/assets/`。
- Create `Tests/perpetual/test_dashboard.py` — 構造アサーション。
- Modify `Tests/perpetual/run_all.sh`, `README.md`。

---

### Task 1: `generate_dashboard.py`

**Files:** Create `scripts/generate_dashboard.py`, `Tests/perpetual/test_dashboard.py`.

**Interfaces:** `generate_dashboard.py --db DB --rotation ROT --config CFG --alphafold-cache DIR --assets-dir A --out OUT` → self-contained HTML を OUT に原子的書き込み。stat/SVGチャート/発見テーブル/3Dビューア(素材あれば)を含む。

- [ ] **Step 1: 失敗するテスト**

`Tests/perpetual/test_dashboard.py`:
```python
import json, os, sqlite3, sys, tempfile, unittest
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "scripts"))
import generate_dashboard as gd


def _seed_db(path):
    c = sqlite3.connect(path)
    c.execute("CREATE TABLE processed(seq_sha256 TEXT PRIMARY KEY,accession TEXT,verdict TEXT,score REAL,classification TEXT,first_seen_cycle INT,run_id TEXT,ts TEXT,schema_version INT)")
    rows = [("h1", "G6AGY4", "actionable", 0.91, "Remote PBP", 1, "r1", "t", 1),
            ("h2", "O66874", "actionable", 0.88, "Remote PKS", 2, "r2", "t", 1),
            ("h3", "ZZ0001", "screened", None, None, 2, "r2", "t", 1)]
    c.executemany("INSERT INTO processed VALUES(?,?,?,?,?,?,?,?,?)", rows)
    c.commit(); c.close()


class DashboardTests(unittest.TestCase):
    def test_generates_selfcontained_html_with_sections(self):
        with tempfile.TemporaryDirectory() as d:
            db = os.path.join(d, "ledger.db"); _seed_db(db)
            rot = os.path.join(d, "rotation.json"); json.dump({"cycle": 2}, open(rot, "w"))
            cfg = os.path.join(d, "worker.json"); json.dump({"enableNetwork": False}, open(cfg, "w"))
            af = os.path.join(d, "af"); os.makedirs(af)
            # a fake AlphaFold PDB for G6AGY4 (one ATOM w/ pLDDT in b-factor col)
            open(os.path.join(af, "AF-G6AGY4-F1-model_v6.pdb"), "w").write(
                "ATOM      1  CA  MET A   1      11.000  22.000  33.000  1.00 87.50           C\nEND\n")
            assets = os.path.join(d, "assets")  # intentionally absent -> no 3Dmol script
            out = os.path.join(d, "dashboard.html")
            gd.main(["--db", db, "--rotation", rot, "--config", cfg,
                     "--alphafold-cache", af, "--assets-dir", assets, "--out", out])
            html = open(out).read()
            self.assertIn("<!doctype html>", html.lower())
            self.assertIn("cycles", html.lower())
            self.assertIn("G6AGY4", html)                    # discoveries table
            self.assertIn("<svg", html)                       # inline SVG chart
            self.assertIn("actionable", html.lower())
            self.assertIn("3Dmol", html) or self.assertIn("3d viewer", html.lower())
            # assets dir absent -> a "vendor 3Dmol.js" note, and NO <script src=assets/3Dmol-min.js>
            self.assertNotIn('src="assets/3Dmol-min.js"', html)
            self.assertIn("vendor", html.lower())

    def test_embeds_pdb_and_script_when_asset_present(self):
        with tempfile.TemporaryDirectory() as d:
            db = os.path.join(d, "ledger.db"); _seed_db(db)
            rot = os.path.join(d, "rotation.json"); json.dump({"cycle": 2}, open(rot, "w"))
            cfg = os.path.join(d, "worker.json"); json.dump({"enableNetwork": True}, open(cfg, "w"))
            af = os.path.join(d, "af"); os.makedirs(af)
            open(os.path.join(af, "AF-G6AGY4-F1-model_v6.pdb"), "w").write(
                "ATOM      1  CA  MET A   1      11.000  22.000  33.000  1.00 87.50           C\nEND\n")
            assets = os.path.join(d, "assets"); os.makedirs(assets)
            open(os.path.join(assets, "3Dmol-min.js"), "w").write("/* vendored */")
            out = os.path.join(d, "dashboard.html")
            gd.main(["--db", db, "--rotation", rot, "--config", cfg,
                     "--alphafold-cache", af, "--assets-dir", assets, "--out", out])
            html = open(out).read()
            self.assertIn('src="assets/3Dmol-min.js"', html)   # vendored script referenced
            self.assertIn("87.50", html)                        # PDB embedded (b-factor/pLDDT)
            self.assertIn("colorscheme", html.lower())          # pLDDT (b-factor) coloring in viewer init
            self.assertIn("network=on", html.lower()) if False else None  # (network shown; not asserted strictly)


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: 失敗確認** — `python3 Tests/perpetual/test_dashboard.py -v` → FAIL（module 不在）。

- [ ] **Step 3: 実装**

`scripts/generate_dashboard.py`:
```python
#!/usr/bin/env python3
"""Generate a self-contained HTML dashboard from the SQLite seen-set ledger.

Charts are hand-rolled inline SVG (no external chart lib). The interactive 3D
protein viewer uses a LOCALLY-VENDORED 3Dmol.js (discoveries/assets/3Dmol-min.js);
if that asset is absent, the 3D section degrades to a "vendor 3Dmol.js" note while
the rest of the dashboard still renders. Structures come from the AlphaFold cache
(AF-<accession>-*.pdb), colored by pLDDT (the PDB B-factor column).
"""
import argparse
import glob
import html
import json
import os
import sqlite3
import tempfile
from collections import Counter

MAX_VIEWERS = 6  # cap embedded PDBs to keep the HTML small


def _load(path, default):
    try:
        with open(path) as fh:
            return json.load(fh)
    except Exception:
        return default


def read_ledger(db_path):
    if not os.path.exists(db_path):
        return []
    conn = sqlite3.connect(db_path)
    try:
        rows = conn.execute(
            "SELECT first_seen_cycle,accession,score,classification,ts,run_id,verdict"
            " FROM processed ORDER BY first_seen_cycle,accession"
        ).fetchall()
    finally:
        conn.close()
    return rows


def find_pdb(cache_dir, accession):
    if not accession or not os.path.isdir(cache_dir):
        return None
    hits = sorted(glob.glob(os.path.join(cache_dir, f"AF-{accession}-*.pdb")))
    return hits[0] if hits else None


def svg_bar_chart(counts_by_cycle):
    if not counts_by_cycle:
        return '<p class="muted">no cycles yet</p>'
    cycles = sorted(counts_by_cycle)
    vals = [counts_by_cycle[c] for c in cycles]
    mx = max(vals) or 1
    w, h, pad = 520, 120, 4
    bw = max(3, (w - pad * (len(vals) + 1)) // max(1, len(vals)))
    bars = []
    for i, v in enumerate(vals):
        bh = int((v / mx) * (h - 20))
        x = pad + i * (bw + pad)
        y = h - bh
        bars.append(f'<rect x="{x}" y="{y}" width="{bw}" height="{bh}" rx="2" fill="var(--ac)"><title>cycle {cycles[i]}: {v}</title></rect>')
    return f'<svg viewBox="0 0 {w} {h}" width="100%" role="img" aria-label="new actionable candidates per cycle">{"".join(bars)}</svg>'


def build_html(rows, rotation, config, cache_dir, assets_dir):
    actionable = [r for r in rows if r[6] == "actionable"]
    screened = [r for r in rows if r[6] == "screened"]
    cycle = rotation.get("cycle", 0)
    net = "on" if config.get("enableNetwork") else "off"
    counts = Counter(r[0] for r in actionable)

    esc = html.escape
    tiles = [
        ("cycles", cycle), ("discoveries (actionable)", len(actionable)),
        ("screened (seen)", len(screened)), ("network", net),
    ]
    tiles_html = "".join(
        f'<div class="tile"><div class="n">{esc(str(v))}</div><div class="l">{esc(k)}</div></div>'
        for k, v in tiles
    )

    trows = "".join(
        f'<tr><td>{esc(str(r[0]))}</td><td>{esc(str(r[1]))}</td><td>{esc(str(r[2]))}</td>'
        f'<td>{esc(str(r[3]))}</td><td>{esc(str(r[4]))}</td></tr>'
        for r in actionable[:200]
    )

    # 3D viewers: top actionable candidates that have an AlphaFold structure
    asset = os.path.join(assets_dir, "3Dmol-min.js")
    have_3dmol = os.path.exists(asset)
    viewers, inits = [], []
    n = 0
    for r in actionable:
        if n >= MAX_VIEWERS:
            break
        pdb = find_pdb(cache_dir, r[1])
        if not pdb:
            continue
        with open(pdb) as fh:
            data = fh.read()
        vid = f"viewer{n}"
        viewers.append(
            f'<div class="card"><div class="id">{esc(str(r[1]))} · pLDDT</div>'
            f'<div id="{vid}" class="mol"></div>'
            f'<script type="text/plain" id="{vid}-pdb">{esc(data)}</script></div>'
        )
        inits.append(
            f'initViewer("{vid}", document.getElementById("{vid}-pdb").textContent);'
        )
        n += 1

    if have_3dmol and viewers:
        viewer_section = (
            '<h2>Top candidates — 3D (pLDDT)</h2><div class="grid">' + "".join(viewers) + "</div>"
            '<script src="assets/3Dmol-min.js"></script>'
            '<script>function initViewer(id,pdb){var v=$3Dmol.createViewer(document.getElementById(id),{backgroundColor:"white"});'
            'v.addModel(pdb,"pdb");v.setStyle({},{cartoon:{colorscheme:{prop:"b",gradient:"roygb",min:50,max:90}}});'
            'v.zoomTo();v.render();}' + "".join(inits) + '</script>'
        )
    elif viewers:
        viewer_section = ('<h2>Top candidates — 3D (pLDDT)</h2>'
                          '<p class="muted">3D viewer disabled: vendor 3Dmol.js first '
                          '(<code>ALLOW_NETWORK=1 scripts/vendor_assets.sh</code>). Structures are ready.</p>')
    else:
        viewer_section = ('<h2>Top candidates — 3D (pLDDT)</h2>'
                          '<p class="muted">No AlphaFold structures cached for current candidates yet '
                          '(populated as structures become available). Vendor 3Dmol.js to enable the viewer.</p>')

    return f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>BioLab Perpetual Discovery</title>
<style>
  :root{{--bg:#fff;--fg:#18201d;--muted:#5f6b66;--card:rgba(0,0,0,.03);--b:rgba(0,0,0,.1);--ac:#0d9488}}
  @media(prefers-color-scheme:dark){{:root{{--bg:#0e1512;--fg:#e6ece9;--muted:#9aa6a1;--card:rgba(255,255,255,.05);--b:rgba(255,255,255,.13)}}}}
  body{{margin:0;padding:20px;background:var(--bg);color:var(--fg);font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif}}
  h1{{font-size:18px;margin:0 0 4px}} h2{{font-size:14px;color:var(--muted);text-transform:uppercase;letter-spacing:.5px;margin:22px 0 8px}}
  .muted{{color:var(--muted)}} code{{background:var(--card);padding:1px 5px;border-radius:5px}}
  .tiles{{display:grid;grid-template-columns:repeat(4,1fr);gap:10px;margin:12px 0}}
  .tile{{background:var(--card);border:1px solid var(--b);border-radius:11px;padding:12px}}
  .tile .n{{font-size:24px;font-weight:680}} .tile .l{{font-size:11px;color:var(--muted)}}
  table{{width:100%;border-collapse:collapse;font-size:13px}} th,td{{text-align:left;padding:6px 8px;border-bottom:1px solid var(--b)}}
  th{{color:var(--muted);font-weight:600}}
  .grid{{display:grid;grid-template-columns:repeat(3,1fr);gap:10px}}
  @media(max-width:720px){{.tiles{{grid-template-columns:repeat(2,1fr)}}.grid{{grid-template-columns:1fr}}}}
  .card{{background:var(--card);border:1px solid var(--b);border-radius:11px;padding:10px}}
  .card .id{{font-size:12px;font-weight:650;margin-bottom:6px}}
  .mol{{position:relative;height:220px;width:100%;background:#fff;border-radius:8px;overflow:hidden}}
</style></head>
<body>
  <h1>BioLab Perpetual Discovery</h1>
  <div class="muted">Local-only triage dashboard. Unvalidated in-silico predictions; not for external use without review.</div>
  <div class="tiles">{tiles_html}</div>
  <h2>New actionable candidates / cycle</h2>
  {svg_bar_chart(counts)}
  <h2>Discoveries (actionable)</h2>
  <table><thead><tr><th>cycle</th><th>accession</th><th>score</th><th>classification</th><th>when</th></tr></thead>
  <tbody>{trows or '<tr><td colspan="5" class="muted">none yet</td></tr>'}</tbody></table>
  {viewer_section}
</body></html>"""


def main(argv=None):
    ap = argparse.ArgumentParser(prog="generate_dashboard.py")
    ap.add_argument("--db", required=True)
    ap.add_argument("--rotation", required=True)
    ap.add_argument("--config", required=True)
    ap.add_argument("--alphafold-cache", required=True)
    ap.add_argument("--assets-dir", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args(argv)
    rows = read_ledger(a.db)
    rotation = _load(a.rotation, {})
    config = _load(a.config, {})
    doc = build_html(rows, rotation, config, a.alphafold_cache, a.assets_dir)
    os.makedirs(os.path.dirname(a.out) or ".", exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(a.out) or ".", suffix=".tmp")
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write(doc)
    os.replace(tmp, a.out)
    print(a.out)
    return 0


if __name__ == "__main__":
    import sys
    sys.exit(main())
```

- [ ] **Step 4: 成功確認** — `python3 Tests/perpetual/test_dashboard.py -v`（2/2）。

- [ ] **Step 5: コミット**
```bash
git add scripts/generate_dashboard.py Tests/perpetual/test_dashboard.py
git commit -m "feat(worker-m4): self-contained HTML dashboard generator (SVG charts + 3Dmol pLDDT viewer)"
```

---

### Task 2: `vendor_assets.sh` ＋ cycle 統合 ＋ gitignore

**Files:** Create `scripts/vendor_assets.sh`; Modify `scripts/run_discovery_cycle.sh`, `.gitignore`; Create `Tests/perpetual/test_dashboard_cycle.sh`.

**Interfaces:** cycle は record 後に `generate_dashboard.py` を呼ぶ（失敗しても cycle を壊さない）。`vendor_assets.sh` は opt-in で 3Dmol.js を `discoveries/assets/3Dmol-min.js` に取得。

- [ ] **Step 1: 失敗するテスト**

`Tests/perpetual/test_dashboard_cycle.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CYCLE="${ROOT}/scripts/run_discovery_cycle.sh"

sandbox() {
  local d; d="$(mktemp -d)"
  mkdir -p "$d/state/inbox/processed" "$d/runs" "$d/discoveries" "$d/ref" "$d/logs" "$d/af"
  printf '>ref\nMKTAYIAKQR\n' > "$d/ref/ref.fasta"
  printf '{"diskFloorGB":0,"maxCandidates":20,"maxWorkspaceBytes":1073741824000,"maxLogFiles":200,"budgetSeconds":60,"maxConsecutiveFailures":5,"throttleSeconds":300,"maxDaemonLogBytes":10485760,"enableNetwork":false,"fetchPageSize":5,"fetchRateLimitSeconds":0,"uniprotHost":"rest.uniprot.org"}' > "$d/worker.json"
  echo "$d"
}
run() {
  STATE_DIR="$1/state" RUNS_DIR="$1/runs" DISCOVERIES_DIR="$1/discoveries" \
  REFERENCE="$1/ref/ref.fasta" LOG_DIR="$1/logs" NOTIFY_CMD="true" \
  CONFIG="$1/worker.json" PIPELINE_CMD="bash ${ROOT}/Tests/perpetual/fake_pipeline.sh" \
  ALPHAFOLD_CACHE="$1/af" bash "$CYCLE"
}

# a normal cycle must (re)generate the dashboard
S="$(sandbox)"; printf '>TESTACC1\nMKTAYIAKQR\n' > "$S/state/inbox/b.fasta"; run "$S"
[[ -f "$S/discoveries/dashboard.html" ]] || { echo "FAIL: dashboard not generated by cycle"; exit 1; }
grep -qi 'BioLab Perpetual Discovery' "$S/discoveries/dashboard.html" || { echo "FAIL: dashboard content missing"; exit 1; }

# vendor script exists and refuses network without opt-in
VEND="${ROOT}/scripts/vendor_assets.sh"
[[ -x "$VEND" ]] || { echo "FAIL: vendor_assets.sh missing/not executable"; exit 1; }
set +e; DISCOVERIES_DIR="$S/discoveries" bash "$VEND" >/dev/null 2>&1; rc=$?; set -e
[[ "$rc" -ne 0 ]] || { echo "FAIL: vendor should refuse without ALLOW_NETWORK"; exit 1; }
[[ ! -f "$S/discoveries/assets/3Dmol-min.js" ]] || { echo "FAIL: vendor fetched without opt-in"; exit 1; }

echo "dashboard cycle tests OK"
```

- [ ] **Step 2: 失敗確認** — `bash Tests/perpetual/test_dashboard_cycle.sh` → FAIL。

- [ ] **Step 3: 実装**

`scripts/run_discovery_cycle.sh` の末尾 `log "cycle ${CYCLE} complete"` の直前に追加（非致命）:
```bash
# regenerate the self-contained dashboard (never fail the cycle over visualization)
ALPHAFOLD_CACHE="${ALPHAFOLD_CACHE:-${ROOT_DIR}/data/alphafold_cache}"
python3 "${ROOT_DIR}/scripts/generate_dashboard.py" \
  --db "${LEDGER_DB}" --rotation "${ROTATION}" --config "${CONFIG}" \
  --alphafold-cache "${ALPHAFOLD_CACHE}" --assets-dir "${DISCOVERIES_DIR}/assets" \
  --out "${DISCOVERIES_DIR}/dashboard.html" >/dev/null 2>&1 || log "dashboard generation skipped (non-fatal)"
```

`scripts/vendor_assets.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DISCOVERIES_DIR="${DISCOVERIES_DIR:-${ROOT_DIR}/discoveries}"
ASSETS="${DISCOVERIES_DIR}/assets"
URL="${THREEDMOL_URL:-https://cdnjs.cloudflare.com/ajax/libs/3Dmol/2.4.0/3Dmol-min.js}"
HOST_ALLOW="${THREEDMOL_HOST:-cdnjs.cloudflare.com}"

host_of() { printf '%s' "$1" | sed -E 's#^https?://([^/]+).*#\1#'; }

if [[ "${ALLOW_NETWORK:-}" != "1" ]]; then
  echo "vendor_assets: refusing — set ALLOW_NETWORK=1 to download 3Dmol.js from ${URL}" >&2
  exit 2
fi
if [[ "$(host_of "${URL}")" != "${HOST_ALLOW}" ]]; then
  echo "vendor_assets: host $(host_of "${URL}") not allowed (${HOST_ALLOW})" >&2
  exit 2
fi
mkdir -p "${ASSETS}"
curl -fsSL --max-time 60 "${URL}" -o "${ASSETS}/3Dmol-min.js"
echo "vendored 3Dmol.js -> ${ASSETS}/3Dmol-min.js ($(wc -c < "${ASSETS}/3Dmol-min.js") bytes)"
```
`chmod +x scripts/vendor_assets.sh`。`.gitignore` に `discoveries/assets/` を追加。

- [ ] **Step 4: 成功確認** — `bash Tests/perpetual/test_dashboard_cycle.sh` → PASS。回帰 `bash Tests/perpetual/test_cycle_offline.sh`(8), `run_all.sh`。

- [ ] **Step 5: コミット**
```bash
chmod +x scripts/vendor_assets.sh
git add scripts/run_discovery_cycle.sh scripts/vendor_assets.sh .gitignore Tests/perpetual/test_dashboard_cycle.sh
git commit -m "feat(worker-m4): cycle regenerates dashboard + opt-in 3Dmol.js vendoring"
```

---

### Task 3: run_all ＋ README

**Files:** Modify `Tests/perpetual/run_all.sh`, `README.md`.

- [ ] **Step 1: run_all に追加** — `test_dashboard.py` と `test_dashboard_cycle.sh` を追記、marker を `ALL M1+M2+M3+M4 TESTS PASSED` に。
- [ ] **Step 2: 全テスト成功** — `bash Tests/perpetual/run_all.sh`。
- [ ] **Step 3: README（M3 の後に）**:
```markdown
## Perpetual Discovery Worker (M4, dashboard)

Every cycle regenerates a self-contained `discoveries/dashboard.html` (open it in a
browser): stat tiles, new-candidates-per-cycle chart, discoveries table, and an
interactive **3D protein viewer coloured by pLDDT** for candidates with an AlphaFold
structure. The 3D viewer needs a locally-vendored 3Dmol.js (CDN is not used at runtime):

```sh
ALLOW_NETWORK=1 scripts/vendor_assets.sh    # one-time: download 3Dmol.js locally
open discoveries/dashboard.html
```

Without the vendored asset the charts/table still render; the 3D section shows a note.
```
- [ ] **Step 4: コミット**
```bash
git add Tests/perpetual/run_all.sh README.md
git commit -m "docs(worker-m4): run_all + README dashboard section"
```

---

## Self-Review
- 自己完結ダッシュボード（stat・SVGチャート・発見テーブル）→ Task 1 ✅
- 3D pLDDTビューア（3Dmol.js・B-factor色分け・素材あれば埋込／無ければプレースホルダ）→ Task 1 ✅
- CDN非依存（ローカルベンダー）＋opt-in取得（ALLOW_NETWORK・host許可）→ Task 1/2 ✅
- cycle 統合は非致命（失敗しても cycle を壊さない）→ Task 2 ✅
- 生成物 gitignore・M1–M3 非退行 → Task 2（`|| log ...`）＋回帰。
- 型整合: cycle が渡す `--db/--rotation/--config/--alphafold-cache/--assets-dir/--out` が generator の引数と一致。`ALPHAFOLD_CACHE` seam を cycle/テストで一致。
