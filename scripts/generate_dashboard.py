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
import re
import sqlite3
import tempfile

MAX_VIEWERS = 6  # cap embedded PDBs to keep the HTML small


def _load_required(path):
    with open(path, encoding="utf-8") as fh:
        value = json.load(fh)
    if not isinstance(value, dict):
        raise ValueError(f"expected JSON object: {path}")
    return value


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


def find_generated_pdb(runs_dir, accession):
    if not accession or not os.path.isdir(runs_dir):
        return None
    safe_accession = re.sub(r"[^A-Za-z0-9_.-]+", "_", str(accession))[:160]
    pattern = os.path.join(runs_dir, "*", "sim", "candidates", safe_accession, "*", "*.pdb")
    hits = sorted(glob.glob(pattern), key=lambda path: (os.path.getmtime(path), path), reverse=True)
    return hits[0] if hits else None


def find_simulation_artifacts(runs_dir, accession):
    """Return the newest digest-backed evidence bundle for one exact candidate."""
    if not accession or not os.path.isdir(runs_dir):
        return None
    safe_accession = re.sub(r"[^A-Za-z0-9_.-]+", "_", str(accession))[:160]
    pattern = os.path.join(runs_dir, "*", "sim", "candidates", safe_accession,
                           "structure_evidence.json")
    paths = sorted(glob.glob(pattern), key=lambda path: (os.path.getmtime(path), path), reverse=True)
    for path in paths:
        evidence = _load_required(path)
        structure = evidence.get("relaxedStructure")
        pose = evidence.get("dockingPose")
        if structure and os.path.isfile(structure):
            return {"structure": structure, "pose": pose if pose and os.path.isfile(pose) else None,
                    "evidence": evidence}
    return None


def latest_simulation_summary(runs_dir):
    if not os.path.isdir(runs_dir):
        return None
    paths = glob.glob(os.path.join(runs_dir, "*", "sim", "summary.json"))
    if not paths:
        return None
    latest = max(paths, key=lambda path: (os.path.getmtime(path), path))
    return _load_required(latest)


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
        bh = max(1, int((v / mx) * (h - 20)))
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
                rotation, config, cache_dir, assets_dir, runs_dir=None, simulation=None):
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
        artifacts = find_simulation_artifacts(runs_dir, r[1]) if runs_dir else None
        pdb = artifacts["structure"] if artifacts else (find_generated_pdb(runs_dir, r[1]) if runs_dir else None)
        pose = artifacts["pose"] if artifacts else None
        pdb = pdb or find_pdb(cache_dir, r[1])
        if not pdb:
            continue
        with open(pdb) as fh:
            data = fh.read()
        pose_data = ""
        if pose:
            with open(pose) as fh:
                pose_data = fh.read()
        vid = f"viewer{n}"
        evidence = artifacts["evidence"] if artifacts else {}
        openmm = evidence.get("openmm") or {}
        vina = evidence.get("vina") or {}
        source = (evidence.get("structureInput") or {}).get("source", "structure-cache")
        energy = openmm.get("energyDropKJPerMol")
        affinity = vina.get("bestAffinityKcalPerMol")
        value = evidence.get("realizedComputeValue")
        detail = (f"source={source} · compute evidence={_fmt_score(value)}"
                  + (f" · ΔE={energy:.1f} kJ/mol" if isinstance(energy, (int, float)) else "")
                  + (f" · Vina={affinity:.2f} kcal/mol" if isinstance(affinity, (int, float)) else ""))
        docking_button = (f'<button type="button" onclick="focusViewer(\'{vid}\',true)">Docking site</button>'
                          if pose_data else "")
        viewers.append(
            f'<div class="card"><div class="id">{esc(str(r[1]))} · relaxed protein'
            f'{" + docked " + esc(str(vina.get("ligand", {}).get("name", "ligand"))) if pose_data else ""}</div>'
            f'<div id="{vid}" class="mol"></div>'
            f'<div class="evidence">{esc(detail)}</div>'
            f'<button type="button" onclick="focusViewer(\'{vid}\',false)">Full protein</button>'
            f'{docking_button}'
            f'<button type="button" data-filename="{esc(str(r[1]))}" '
            f'onclick="downloadViewerPNG(\'{vid}\',this.dataset.filename)">Export PNG</button>'
            f'<pre hidden id="{vid}-pdb">{esc(data)}</pre>'
            f'<pre hidden id="{vid}-pose">{esc(pose_data)}</pre></div>'
        )
        inits.append(
            f'initViewer("{vid}",document.getElementById("{vid}-pdb").textContent,'
            f'document.getElementById("{vid}-pose").textContent);'
        )
        n += 1

    if have_3dmol and viewers:
        viewer_section = (
            '<h2>Top candidates — relaxed protein + docking pose</h2><div class="grid">' + "".join(viewers) + "</div>"
            '<script src="assets/3Dmol-min.js"></script>'
            '<script>var biolabViewers={};function initViewer(id,pdb,pose){var v=$3Dmol.createViewer(document.getElementById(id),{backgroundColor:"white"});'
            'var protein=v.addModel(pdb,"pdb");protein.setStyle({},{cartoon:{colorscheme:{prop:"b",gradient:"roygb",min:50,max:90}}});'
            'var ligand=null;if(pose){ligand=v.addModel(pose,"pdbqt");ligand.setStyle({},{stick:{colorscheme:"Jmol",radius:.22},sphere:{scale:.28}});}'
            'v.zoomTo();v.render();biolabViewers[id]={viewer:v,ligand:ligand};}'
            'function focusViewer(id,site){var item=biolabViewers[id];item.viewer.zoomTo(site&&item.ligand?{model:item.ligand}:{});item.viewer.render();}'
            'function downloadViewerPNG(id,name){var uri=biolabViewers[id].viewer.pngURI();var a=document.createElement("a");'
            'a.href=uri;a.download=name+"-relaxed-docked.png";a.click();}' + "".join(inits)
            + 'if(location.hash==="#docking-site"&&biolabViewers.viewer0){focusViewer("viewer0",true);}'
            + '</script>'
        )
    elif viewers:
        viewer_section = ('<h2>Top candidates — 3D (pLDDT)</h2>'
                          '<p class="muted">3D viewer disabled: vendor 3Dmol.js first '
                          '(<code>ALLOW_NETWORK=1 scripts/vendor_assets.sh</code>). Structures are ready.</p>')
    else:
        viewer_section = ('<h2>Top candidates — 3D (pLDDT)</h2>'
                          '<p class="muted">No AlphaFold structures cached for current candidates yet '
                          '(populated as structures become available). Vendor 3Dmol.js to enable the viewer.</p>')

    if simulation:
        backend_rows = "".join(
            f'<tr><td>{esc(name)}</td><td>{"on" if status.get("available") else "off"}</td>'
            f'<td>{esc(str(status.get("reason", "")))}</td></tr>'
            for name, status in sorted(simulation.get("backends", {}).items())
        )
        resources = simulation.get("resources", {})
        resource_text = (
            f'jobs ok={simulation.get("ran", 0)}, failed={simulation.get("failed", 0)}, '
            f'max concurrent={resources.get("maxConcurrentObserved", 0)}/'
            f'{resources.get("logicalCpuCount", "?")}, estimated RAM peak='
            f'{resources.get("peakEstimatedRamBytes", 0)}/{resources.get("ramBudgetBytes", 0)} bytes'
        )
        skipped_reasons = []
        seen_reasons = set()
        for item in simulation.get("skipped", []):
            key = (str(item.get("backend", "unknown")), str(item.get("reason", "unspecified")))
            if key not in seen_reasons:
                seen_reasons.add(key)
                skipped_reasons.append(f"{key[0]}: {key[1]}")
        skipped_html = "".join(f"<li>{esc(reason)}</li>" for reason in skipped_reasons[:12])
        simulation_section = (
            '<h2>Simulation backends / resource use</h2>'
            f'<p class="muted">{esc(resource_text)}</p>'
            '<table><thead><tr><th>backend</th><th>state</th><th>reason</th></tr></thead>'
            f'<tbody>{backend_rows}</tbody></table>'
            + (f'<p class="muted">Skipped/degraded:</p><ul>{skipped_html}</ul>' if skipped_html else '')
        )
    else:
        simulation_section = ('<h2>Simulation backends / resource use</h2>'
                              '<p class="muted">No simulation cycle has run yet.</p>')

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
  .grid{{display:grid;grid-template-columns:repeat(auto-fit,minmax(420px,1fr));gap:10px}}
  @media(max-width:720px){{.tiles{{grid-template-columns:repeat(2,1fr)}}.grid{{grid-template-columns:1fr}}}}
  .card{{background:var(--card);border:1px solid var(--b);border-radius:11px;padding:10px}}
  .card .id{{font-size:12px;font-weight:650;margin-bottom:6px}}
  .evidence{{font-size:10px;color:var(--muted);min-height:28px;margin-bottom:5px}}
  .mol{{position:relative;height:420px;width:100%;background:#fff;border-radius:8px;overflow:hidden}}
  button{{margin-top:7px;border:1px solid var(--b);border-radius:7px;padding:5px 9px;background:var(--card);color:var(--fg);cursor:pointer}}
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
  {simulation_section}
  {viewer_section}
</body></html>"""


def main(argv=None):
    ap = argparse.ArgumentParser(prog="generate_dashboard.py")
    ap.add_argument("--db", required=True)
    ap.add_argument("--rotation", required=True)
    ap.add_argument("--config", required=True)
    ap.add_argument("--alphafold-cache", required=True)
    ap.add_argument("--assets-dir", required=True)
    ap.add_argument("--runs-dir", default="")
    ap.add_argument("--out", required=True)
    a = ap.parse_args(argv)
    rotation = _load_required(a.rotation)
    current_cycle = int(rotation.get("cycle", 0))
    n_actionable, n_screened = counts(a.db)
    table_rows = recent_actionable(a.db, limit=200)
    observed_counts = per_cycle_counts(a.db)
    if current_cycle > 0:
        first_cycle = max(1, current_cycle - 59)
        cycle_counts = {cycle: observed_counts.get(cycle, 0)
                        for cycle in range(first_cycle, current_cycle + 1)}
    else:
        cycle_counts = observed_counts
    top_candidates = top_by_score(a.db, limit=32)
    config = _load_required(a.config)
    simulation = latest_simulation_summary(a.runs_dir)
    doc = build_html(n_actionable, n_screened, table_rows, cycle_counts, top_candidates,
                      rotation, config, a.alphafold_cache, a.assets_dir, a.runs_dir, simulation)
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
