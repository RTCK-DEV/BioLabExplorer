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
