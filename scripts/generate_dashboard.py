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

MAX_VIEWERS = 6  # cap embedded PDBs to keep the HTML small


def _load(path, default):
    try:
        with open(path) as fh:
            return json.load(fh)
    except Exception:
        return default


def counts(db):
    """(n_actionable, n_screened) via one GROUP BY query. Tolerates a missing DB."""
    if not os.path.exists(db):
        return (0, 0)
    conn = sqlite3.connect(db)
    try:
        rows = conn.execute("SELECT verdict, COUNT(*) FROM processed GROUP BY verdict").fetchall()
    finally:
        conn.close()
    by_verdict = dict(rows)
    return (by_verdict.get("actionable", 0), by_verdict.get("screened", 0))


def recent_actionable(db, limit=200):
    """Newest-first actionable rows for the discoveries table (bounded + indexed)."""
    if not os.path.exists(db):
        return []
    conn = sqlite3.connect(db)
    try:
        return conn.execute(
            "SELECT first_seen_cycle,accession,score,classification,ts,run_id"
            " FROM processed WHERE verdict='actionable'"
            " ORDER BY first_seen_cycle DESC, accession DESC LIMIT ?",
            (limit,),
        ).fetchall()
    finally:
        conn.close()


def per_cycle_counts(db):
    """{cycle: new-actionable-count}, for the chart."""
    if not os.path.exists(db):
        return {}
    conn = sqlite3.connect(db)
    try:
        rows = conn.execute(
            "SELECT first_seen_cycle, COUNT(*) FROM processed"
            " WHERE verdict='actionable' GROUP BY first_seen_cycle"
        ).fetchall()
    finally:
        conn.close()
    return dict(rows)


def top_by_score(db, limit=32):
    """Highest-score-first actionable rows: candidates for the 3D viewer."""
    if not os.path.exists(db):
        return []
    conn = sqlite3.connect(db)
    try:
        return conn.execute(
            "SELECT first_seen_cycle,accession,score,classification,ts,run_id"
            " FROM processed WHERE verdict='actionable'"
            " ORDER BY score DESC, accession ASC LIMIT ?",
            (limit,),
        ).fetchall()
    finally:
        conn.close()


def find_pdb(cache_dir, accession):
    if not accession or not os.path.isdir(cache_dir):
        return None
    hits = sorted(glob.glob(os.path.join(cache_dir, f"AF-{glob.escape(accession)}-*.pdb")))
    return hits[0] if hits else None


def svg_bar_chart(counts_by_cycle):
    if not counts_by_cycle:
        return '<p class="muted">no cycles yet</p>'
    # Window to the most recent cycles so bars always fit the fixed viewBox,
    # no matter how long the worker has been running.
    cycles = sorted(counts_by_cycle)[-60:]
    vals = [counts_by_cycle[c] for c in cycles]
    mx = max(vals) or 1
    w, h, pad = 520, 120, 4
    bw = max(3, (w - pad * (len(vals) + 1)) // max(1, len(vals)))
    bars = []
    for i, v in enumerate(vals):
        bh = int((v / mx) * (h - 20))
        x = pad + i * (bw + pad)
        y = h - bh
        title = f"cycle {html.escape(str(cycles[i]))}: {html.escape(str(v))}"
        bars.append(f'<rect x="{x}" y="{y}" width="{bw}" height="{bh}" rx="2" fill="var(--ac)"><title>{title}</title></rect>')
    return f'<svg viewBox="0 0 {w} {h}" width="100%" role="img" aria-label="new actionable candidates per cycle">{"".join(bars)}</svg>'


def _fmt_score(v):
    """Render scores rounded to 3 decimals so the dashboard and DISCOVERIES.md
    agree; non-numeric/missing scores render as an em dash. Display-only -- the
    DB value itself is left untouched."""
    if isinstance(v, (int, float)) and not isinstance(v, bool):
        return f"{v:.3f}"
    return "—"


def build_html(n_actionable, n_screened, table_rows, cycle_counts, top_candidates,
                rotation, config, cache_dir, assets_dir):
    cycle = rotation.get("cycle", 0)
    net = "on" if config.get("enableNetwork") else "off"

    esc = html.escape
    tiles = [
        ("cycles", cycle), ("discoveries (actionable)", n_actionable),
        ("screened (seen)", n_screened), ("network", net),
    ]
    tiles_html = "".join(
        f'<div class="tile"><div class="n">{esc(str(v))}</div><div class="l">{esc(k)}</div></div>'
        for k, v in tiles
    )

    trows = "".join(
        f'<tr><td>{esc(str(r[0]))}</td><td>{esc(str(r[1]))}</td><td>{esc(_fmt_score(r[2]))}</td>'
        f'<td>{esc(str(r[3]))}</td><td>{esc(str(r[4]))}</td></tr>'
        for r in table_rows
    )

    # 3D viewers: highest-SCORING actionable candidates that have an AlphaFold
    # structure (top_by_score, not merely the most recently seen).
    asset = os.path.join(assets_dir, "3Dmol-min.js")
    have_3dmol = os.path.exists(asset)
    viewers, inits = [], []
    n = 0
    for r in top_candidates:
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
            f'<pre hidden id="{vid}-pdb">{esc(data)}</pre></div>'
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
  {svg_bar_chart(cycle_counts)}
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
    n_actionable, n_screened = counts(a.db)
    table_rows = recent_actionable(a.db, limit=200)
    cycle_counts = per_cycle_counts(a.db)
    top_candidates = top_by_score(a.db, limit=32)
    rotation = _load(a.rotation, {})
    config = _load(a.config, {})
    doc = build_html(n_actionable, n_screened, table_rows, cycle_counts, top_candidates,
                      rotation, config, a.alphafold_cache, a.assets_dir)
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
