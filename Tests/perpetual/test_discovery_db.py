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
