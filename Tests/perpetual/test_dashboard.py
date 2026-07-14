import html, json, os, re, sqlite3, sys, tempfile, unittest
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


def _make_db(path, rows):
    c = sqlite3.connect(path)
    c.execute("CREATE TABLE processed(seq_sha256 TEXT PRIMARY KEY,accession TEXT,verdict TEXT,score REAL,classification TEXT,first_seen_cycle INT,run_id TEXT,ts TEXT,schema_version INT)")
    c.executemany("INSERT INTO processed VALUES(?,?,?,?,?,?,?,?,?)", rows)
    c.commit(); c.close()


def _pdb_text():
    return ("ATOM      1  CA  MET A   1      11.000  22.000  33.000  1.00 87.50           C\n"
            "END\n")


def _generate(d, db, cycle=1, enable_network=False, af=None, assets=None):
    rot = os.path.join(d, "rotation.json"); json.dump({"cycle": cycle}, open(rot, "w"))
    cfg = os.path.join(d, "worker.json"); json.dump({"enableNetwork": enable_network}, open(cfg, "w"))
    if af is None:
        af = os.path.join(d, "af"); os.makedirs(af, exist_ok=True)
    if assets is None:
        assets = os.path.join(d, "assets")  # absent by default
    out = os.path.join(d, "dashboard.html")
    gd.main(["--db", db, "--rotation", rot, "--config", cfg,
             "--alphafold-cache", af, "--assets-dir", assets, "--out", out])
    return open(out).read()


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
            html_doc = open(out).read()
            self.assertIn("<!doctype html>", html_doc.lower())
            self.assertIn("cycles", html_doc.lower())
            self.assertIn("G6AGY4", html_doc)                    # discoveries table
            self.assertIn("<svg", html_doc)                       # inline SVG chart
            self.assertIn("actionable", html_doc.lower())
            self.assertTrue("3Dmol" in html_doc or "3d viewer" in html_doc.lower())
            # assets dir absent -> a "vendor 3Dmol.js" note, and NO <script src=assets/3Dmol-min.js>
            self.assertNotIn('src="assets/3Dmol-min.js"', html_doc)
            self.assertIn("vendor", html_doc.lower())

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
            html_doc = open(out).read()
            self.assertIn('src="assets/3Dmol-min.js"', html_doc)   # vendored script referenced
            self.assertIn("87.50", html_doc)                        # PDB embedded (b-factor/pLDDT)
            self.assertIn("colorscheme", html_doc.lower())          # pLDDT (b-factor) coloring in viewer init

    def test_pdb_roundtrips_through_pre_container_and_blocks_injection(self):
        # Regression test: the PDB payload must be embedded in a <pre hidden>
        # element, NOT a <script type="text/plain"> element. <script> is an
        # HTML "raw text" element -- the parser never entity-decodes its
        # contents, so .textContent would return the still-escaped text and
        # silently corrupt any PDB line containing & < > " ' (e.g. nucleic-acid
        # atom names like O5'/C3', or a REMARK with an apostrophe/ampersand).
        # <pre> is normal content model, so the parser DOES decode entities and
        # .textContent round-trips the original bytes -- while html.escape()
        # still blocks a literal </pre> (or any tag) from breaking out.
        with tempfile.TemporaryDirectory() as d:
            db = os.path.join(d, "ledger.db"); _seed_db(db)
            rot = os.path.join(d, "rotation.json"); json.dump({"cycle": 2}, open(rot, "w"))
            cfg = os.path.join(d, "worker.json"); json.dump({"enableNetwork": True}, open(cfg, "w"))
            af = os.path.join(d, "af"); os.makedirs(af)
            pdb_text = (
                "ATOM      1  O5' MET A   1      11.000  22.000  33.000  1.00 87.50           O\n"
                "REMARK   A & B <tag> O5' </pre></script><script>alert(1)</script>\n"
                "END\n"
            )
            open(os.path.join(af, "AF-G6AGY4-F1-model_v6.pdb"), "w").write(pdb_text)
            assets = os.path.join(d, "assets"); os.makedirs(assets)
            open(os.path.join(assets, "3Dmol-min.js"), "w").write("/* vendored */")
            out = os.path.join(d, "dashboard.html")
            gd.main(["--db", db, "--rotation", rot, "--config", cfg,
                     "--alphafold-cache", af, "--assets-dir", assets, "--out", out])
            doc = open(out).read()

            # 1. container is <pre hidden ...>, NOT <script ...> (fails against
            #    the old <script type="text/plain"> container -- see counterfactual
            #    in the fix report).
            self.assertIn('<pre hidden id="viewer0-pdb"', doc)

            # 2. round-trip: extract the embedded (escaped) text and confirm
            #    html.unescape() recovers the ORIGINAL PDB byte-for-byte.
            m = re.search(r'<pre hidden id="viewer0-pdb">(.*?)</pre>', doc, re.S)
            self.assertIsNotNone(m, "embedded <pre>...</pre> block not found")
            self.assertEqual(html.unescape(m.group(1)), pdb_text)

            # 3. injection-safety: the raw breakout attempt must never appear
            #    unescaped in the output (html.escape must still be applied).
            self.assertNotIn("</pre></script><script>alert(1)</script>", doc)

    def test_recent_actionable_shows_newest_not_oldest(self):
        # Regression guard for Fix 1: read_ledger() + actionable[:200] used to
        # slice an ASC-ordered list, so once >200 discoveries existed the table
        # would freeze on the oldest 200 forever and NEVER show a new one. The
        # SQL-side recent_actionable() must order newest-first instead.
        with tempfile.TemporaryDirectory() as d:
            db = os.path.join(d, "ledger.db")
            rows = [
                (f"h{i}", f"ACC{i:04d}", "actionable", 0.5, "Remote PBP", i, f"r{i}", "t", 1)
                for i in range(250)
            ]
            _make_db(db, rows)
            doc = _generate(d, db, cycle=250)
            self.assertIn("ACC0249", doc)      # newest (cycle 249) must appear
            self.assertNotIn("ACC0000", doc)   # oldest (cycle 0) must be pushed out by the 200 cap

    def test_chart_windowed_to_last_60_cycles_and_fits_viewbox(self):
        # Regression guard for Fix 2: with 90 distinct cycles the un-windowed
        # chart computed a bar width so small the last bars' right edge fell
        # outside the fixed viewBox (clipped). Windowing to the most recent 60
        # cycles must keep every bar inside the viewBox, and tooltips must still
        # show the TRUE (non-renumbered) cycle number.
        with tempfile.TemporaryDirectory() as d:
            db = os.path.join(d, "ledger.db")
            rows = [
                (f"h{i}", f"ACC{i:04d}", "actionable", 0.5, "Remote PBP", i, f"r{i}", "t", 1)
                for i in range(90)
            ]
            _make_db(db, rows)
            doc = _generate(d, db, cycle=90)

            rects = re.findall(r'<rect x="([\d.]+)" y="([\d.]+)" width="([\d.]+)" height="([\d.]+)"', doc)
            self.assertGreater(len(rects), 0)
            self.assertLessEqual(len(rects), 60)

            # true cycle number preserved in the tooltip (not renumbered 0..59)
            self.assertIn("cycle 89:", doc)
            # the oldest 30 cycles (0..29) were windowed out of the chart
            self.assertNotIn("cycle 0:", doc)

            m = re.search(r'<svg viewBox="0 0 (\d+) (\d+)"', doc)
            self.assertIsNotNone(m)
            view_w = float(m.group(1))
            last_x, _, last_w, _ = (float(v) for v in rects[-1])
            self.assertLessEqual(last_x + last_w, view_w)

    def test_viewer_selection_uses_score_not_recency(self):
        # Regression guard for Fix 4: viewer candidates must come from
        # top_by_score(), so a higher-scored-but-older discovery still wins
        # viewer0 over a lower-scored-but-newer one.
        with tempfile.TemporaryDirectory() as d:
            db = os.path.join(d, "ledger.db")
            rows = [
                ("h1", "OLDLOW", "actionable", 0.10, "Remote PBP", 1, "r1", "t", 1),  # older, LOWER score
                ("h2", "NEWHI", "actionable", 0.99, "Remote PKS", 2, "r2", "t", 1),   # newer, HIGHER score
            ]
            _make_db(db, rows)
            af = os.path.join(d, "af"); os.makedirs(af)
            for acc in ("OLDLOW", "NEWHI"):
                open(os.path.join(af, f"AF-{acc}-F1-model_v6.pdb"), "w").write(_pdb_text())
            assets = os.path.join(d, "assets"); os.makedirs(assets)
            open(os.path.join(assets, "3Dmol-min.js"), "w").write("/* vendored */")
            doc = _generate(d, db, cycle=2, enable_network=True, af=af, assets=assets)

            m = re.search(r'<div class="card"><div class="id">([^<]+)</div><div id="(viewer\d+)"', doc)
            self.assertIsNotNone(m, "no viewer card found")
            self.assertEqual(m.group(2), "viewer0")
            self.assertTrue(m.group(1).startswith("NEWHI"), f"expected NEWHI in viewer0, got {m.group(1)!r}")

    def test_glob_escape_prevents_wrong_protein_match(self):
        # Regression guard for Fix 5: an unescaped glob (AF-*-*.pdb for
        # accession "*") would match ANY cached structure and render the WRONG
        # protein. glob.escape() must make "*" match nothing.
        with tempfile.TemporaryDirectory() as d:
            db = os.path.join(d, "ledger.db")
            rows = [("h1", "*", "actionable", 0.95, "Remote PBP", 1, "r1", "t", 1)]
            _make_db(db, rows)
            af = os.path.join(d, "af"); os.makedirs(af)
            # an unrelated cached structure a naive glob would incorrectly match
            open(os.path.join(af, "AF-UNRELATED-F1-model_v6.pdb"), "w").write(_pdb_text())
            assets = os.path.join(d, "assets"); os.makedirs(assets)
            open(os.path.join(assets, "3Dmol-min.js"), "w").write("/* vendored */")
            doc = _generate(d, db, cycle=1, enable_network=True, af=af, assets=assets)

            self.assertNotIn('id="viewer0"', doc)   # no viewer rendered for the crafted accession
            self.assertNotIn("UNRELATED", doc)       # the unrelated structure must never be embedded

    def test_score_rendered_with_three_decimals(self):
        # Regression guard for Fix 6: scores must render rounded to 3 decimals,
        # not as a raw float.
        with tempfile.TemporaryDirectory() as d:
            db = os.path.join(d, "ledger.db")
            rows = [("h1", "SCOREACC", "actionable", 0.8779999, "Remote PBP", 1, "r1", "t", 1)]
            _make_db(db, rows)
            doc = _generate(d, db, cycle=1)
            self.assertIn("0.878", doc)          # rounded to 3 decimals
            self.assertNotIn("0.8779999", doc)   # raw float must not leak through


if __name__ == "__main__":
    unittest.main()
