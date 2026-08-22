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
        self.assertEqual(db.seq_sha256("AC D\nEFG"), db.seq_sha256("ACDEFG"))

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

    def test_sequence_payload_roundtrips_for_simulation(self):
        with tempfile.TemporaryDirectory() as d:
            rd = os.path.join(d, "cycle_x")
            _fixture(rd, [_cand("A1", "MKT")], ["A1"])
            fa = os.path.join(d, "in.fasta")
            _fasta(fa, [("A1", "mkt")])
            dbp = os.path.join(d, "l.db")
            db.record(fa, rd, dbp, os.path.join(d, "D.md"), 7, "cycle_x")
            out = os.path.join(d, "candidates.json")
            self.assertEqual(db.export_new_actionable(dbp, 7, out), 1)
            with open(out, encoding="utf-8") as fh:
                payload = json.load(fh)
            self.assertEqual(payload[0]["sequence"], "MKT")
            self.assertEqual(payload[0]["seqSha256"], db.seq_sha256("MKT"))
            self.assertEqual(payload[0]["classification"], "Remote PBP")
            self.assertEqual(payload[0]["score"], 0.9)

    def test_v1_database_migrates_without_losing_rows(self):
        with tempfile.TemporaryDirectory() as d:
            dbp = os.path.join(d, "v1.db")
            con = sqlite3.connect(dbp)
            con.execute("""CREATE TABLE processed (
                seq_sha256 TEXT PRIMARY KEY, accession TEXT NOT NULL,
                verdict TEXT NOT NULL, score REAL, classification TEXT,
                first_seen_cycle INTEGER NOT NULL, run_id TEXT NOT NULL,
                ts TEXT NOT NULL, schema_version INTEGER NOT NULL)""")
            con.execute("INSERT INTO processed VALUES (?,?,?,?,?,?,?,?,?)",
                        ("abc", "OLD", "screened", None, None, 1, "r", "t", 1))
            con.commit(); con.close()
            migrated = db.connect(dbp)
            try:
                columns = {row[1] for row in migrated.execute("PRAGMA table_info(processed)")}
                self.assertIn("sequence", columns)
                self.assertEqual(migrated.execute("SELECT COUNT(*) FROM processed").fetchone()[0], 1)
            finally:
                migrated.close()

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

    def test_accession_from_header_matches_swift_rule(self):
        # Mirrors Sources/BioLabExplorerCore/FASTAParser.swift identifier(from:)
        # (lines 70-77): first space-token, then the middle field of a
        # db|ACCESSION|ENTRY header, omitting empty subsequences on both splits.
        self.assertEqual(db.accession_from_header("tr|A0A123|A0A123_BACT x"), "A0A123")
        self.assertEqual(db.accession_from_header("A0A123 desc"), "A0A123")
        # Space-only split, like Swift split(separator: " "): a header with a TAB
        # (not a space) has no space to split on, so the whole string is the first
        # token, and (no pipe) is returned as-is -- it must NOT be truncated to
        # "A0A123" the way an all-whitespace split() would.
        self.assertEqual(db.accession_from_header("A0A123\tdesc"), "A0A123\tdesc")

    def test_uniprot_pipe_header_recorded_actionable(self):
        # Real UniProt headers are "db|ACCESSION|ENTRY description", e.g.
        # ">tr|A0A123|A0A123_BACT some description". qualifyingCandidateIDs holds
        # the BARE accession (candidate.sequence.id = "A0A123"), so the ledger must
        # extract "A0A123" from the pipe-delimited header to match it -- not the
        # whole first whitespace token ("tr|A0A123|A0A123_BACT").
        with tempfile.TemporaryDirectory() as d:
            rd = os.path.join(d, "cycle_x")
            _fixture(rd, [_cand("A0A123", "MKT")], ["A0A123"])
            fa = os.path.join(d, "in.fasta")
            with open(fa, "w") as fh:
                fh.write(">tr|A0A123|A0A123_BACT some description\nMKT\n")
            dbp = os.path.join(d, "l.db")
            n = db.record(fa, rd, dbp, os.path.join(d, "D.md"), 1, "cycle_x")
            self.assertEqual(n, 1)
            con = sqlite3.connect(dbp)
            row = con.execute(
                "SELECT verdict FROM processed WHERE accession=?", ("A0A123",)
            ).fetchone()
            self.assertIsNotNone(row, "no row recorded for bare accession A0A123")
            self.assertEqual(row[0], "actionable")

    def test_bare_header_recorded_actionable(self):
        # Same qualifying accession, but via a bare ">ACC desc" header (no pipes),
        # to prove both header forms map to the same accession and verdict.
        with tempfile.TemporaryDirectory() as d:
            rd = os.path.join(d, "cycle_x")
            _fixture(rd, [_cand("A0A123", "MKT")], ["A0A123"])
            fa = os.path.join(d, "in.fasta")
            _fasta(fa, [("A0A123", "MKT")])
            dbp = os.path.join(d, "l.db")
            n = db.record(fa, rd, dbp, os.path.join(d, "D.md"), 1, "cycle_x")
            self.assertEqual(n, 1)
            con = sqlite3.connect(dbp)
            row = con.execute(
                "SELECT verdict FROM processed WHERE accession=?", ("A0A123",)
            ).fetchone()
            self.assertIsNotNone(row, "no row recorded for bare accession A0A123")
            self.assertEqual(row[0], "actionable")

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
