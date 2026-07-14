import json, os, sqlite3, sys, tempfile, unittest
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "scripts"))
import discovery_db as db


def _cand(acc, seq, novelty=0.9, cls="Remote PBP"):
    return {"id": "TOP_" + acc, "sequence": {"id": acc, "sequence": seq},
            "noveltyScore": novelty, "classification": cls}


def _fixture(run_dir, candidates, qualifying):
    os.makedirs(run_dir, exist_ok=True)
    with open(os.path.join(run_dir, "run-2026-01-01T00-00-00-000Z.json"), "w") as fh:
        json.dump({"candidates": candidates}, fh)
    with open(os.path.join(run_dir, "discovery-validation.json"), "w") as fh:
        json.dump({"passed": bool(qualifying), "qualifyingCandidateIDs": qualifying}, fh)


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
            with open(os.path.join(rd, "run-x.json"), "w") as fh:
                json.dump({"candidates": []}, fh)
            fa = os.path.join(d, "in.fasta"); _fasta(fa, [("A1", "MKT")])
            with self.assertRaises(Exception):
                db.record(fa, rd, os.path.join(d, "l.db"), os.path.join(d, "D.md"), 1, "r")

    def test_fail_closed_on_malformed_run_json(self):
        # run-*.json is present but is not valid JSON -> json.load raises -> fail closed
        with tempfile.TemporaryDirectory() as d:
            rd = os.path.join(d, "cycle_x")
            os.makedirs(rd)
            with open(os.path.join(rd, "run-x.json"), "w") as fh:
                fh.write("{not json")
            with open(os.path.join(rd, "discovery-validation.json"), "w") as fh:
                json.dump({"passed": True, "qualifyingCandidateIDs": ["A1"]}, fh)
            fa = os.path.join(d, "in.fasta"); _fasta(fa, [("A1", "MKT")])
            with self.assertRaises(Exception):
                db.record(fa, rd, os.path.join(d, "l.db"), os.path.join(d, "D.md"), 1, "r")

    def test_fail_closed_on_missing_run_json(self):
        # no run-*.json at all (only the validation file) -> glob is empty -> fail closed
        with tempfile.TemporaryDirectory() as d:
            rd = os.path.join(d, "cycle_x")
            os.makedirs(rd)
            with open(os.path.join(rd, "discovery-validation.json"), "w") as fh:
                json.dump({"passed": True, "qualifyingCandidateIDs": ["A1"]}, fh)
            fa = os.path.join(d, "in.fasta"); _fasta(fa, [("A1", "MKT")])
            with self.assertRaises(Exception):
                db.record(fa, rd, os.path.join(d, "l.db"), os.path.join(d, "D.md"), 1, "r")

    def test_fail_closed_on_validation_missing_qualifying_key(self):
        # discovery-validation.json is valid JSON but lacks qualifyingCandidateIDs -> fail closed
        with tempfile.TemporaryDirectory() as d:
            rd = os.path.join(d, "cycle_x")
            os.makedirs(rd)
            with open(os.path.join(rd, "run-x.json"), "w") as fh:
                json.dump({"candidates": []}, fh)
            with open(os.path.join(rd, "discovery-validation.json"), "w") as fh:
                json.dump({"passed": True}, fh)  # missing qualifyingCandidateIDs
            fa = os.path.join(d, "in.fasta"); _fasta(fa, [("A1", "MKT")])
            with self.assertRaises(Exception):
                db.record(fa, rd, os.path.join(d, "l.db"), os.path.join(d, "D.md"), 1, "r")

    def test_regenerate_discoveries_md(self):
        with tempfile.TemporaryDirectory() as d:
            rd = os.path.join(d, "cycle_x")
            _fixture(rd, [_cand("A1", "MKT")], ["A1"])
            fa = os.path.join(d, "in.fasta")
            _fasta(fa, [("A1", "MKT")])
            dbp, md = os.path.join(d, "l.db"), os.path.join(d, "D.md")
            db.record(fa, rd, dbp, md, 1, "cycle_x")

            self.assertTrue(os.path.exists(md))
            with open(md, encoding="utf-8") as fh:
                content = fh.read()
            # Stable local-only intended-use header substring, copied verbatim from
            # regenerate_discoveries_md() in scripts/discovery_db.py.
            self.assertIn("Local-only triage output", content)
            self.assertIn("| A1 |", content)  # table row for the actionable accession

            # Regenerating directly from the DB (no new record() call) must reproduce
            # byte-identical content: regeneration is a pure function of DB state.
            db.regenerate_discoveries_md(dbp, md)
            with open(md, encoding="utf-8") as fh:
                content2 = fh.read()
            self.assertEqual(content, content2)


if __name__ == "__main__":
    unittest.main()
