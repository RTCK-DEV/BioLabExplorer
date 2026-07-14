#!/usr/bin/env python3
"""Real-pipeline Swift<->Python accession contract test.

Every other perpetual-worker test drives the fake pipeline
(Tests/perpetual/fake_pipeline.sh); none of them ever run the actual Swift
binary. This test is the one exception: it runs the REAL
BioLabExplorerPipeline on a tiny UniProt-style pipe-header FASTA fixture and
proves the accession-extraction contract holds between:

  - Swift: FASTAParser.identifier(from:)
    (Sources/BioLabExplorerCore/FASTAParser.swift:70-77)
  - Python: accession_from_header(header)
    (scripts/discovery_db.py)

discovery_db.record() matches qualifyingCandidateIDs (accessions computed by
Swift, via candidate.sequence.id) against accessions it derives itself in
Python from the raw FASTA header. If the two implementations ever diverge,
actionable discoveries silently stop being recorded into the ledger -- this
is the exact bug class that reached real data before being fixed in commit
3b85158. A pure-Python mirror test (test_accession_from_header_matches_swift_rule
in test_discovery_db.py) guards the Python side's own logic, but only running
the real Swift binary can catch a *future* divergence introduced on the Swift
side.

Skips (does not fail) if a working
`.build/release/BioLabExplorerPipeline` binary cannot be obtained in this
environment -- this keeps the test from blocking CI in a stripped-down
environment while still trying `swift build -c release` (local toolchain,
no network) first.
"""
import glob
import json
import os
import subprocess
import sys
import tempfile
import unittest

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "scripts"))
import discovery_db as db  # noqa: E402

BINARY = os.path.join(ROOT, ".build", "release", "BioLabExplorerPipeline")
REFERENCE = os.path.join(ROOT, "data", "curated_reference", "pbp_pks_reference.fasta")

# Genuine UniProt-style pipe header: "db|ACCESSION|ENTRY description".
FIXTURE_HEADER = "tr|A0A9999|A0A9999_TEST test protein"
FIXTURE_ACCESSION = "A0A9999"
FIXTURE_SEQUENCE = (
    "MKTAYIAKQRQISFVKSHFSRQLEERLGLIEVQAPILSRVGDGTQDNLSGAEKAVQVKVKALPDAQFEVVHSLAKWKRQ"
    "TLGQHDFSAGEGLYTHMKALRPDEDRLSPLHSVYVDQWDWELVMGDGERQFSTLKSTVEAIWAGIKATEAAVSEEFGLA"
    "PFLPDQIHFVHSQELLSRYPDLDAKGRERAIAKDLGAVFLVGIGGKLSDGHRHDVRAPDYDDWSTPSELGHAGLNGDIL"
    "VWNPVLEDAFELSSMGIRVDADTLKHQLALTGDEDRLELEWHQALLRGEMPQTIGGGIGQSRLTMLLLQLPHIGQVQAG"
    "VWPAAVRESVPSLL"
)


def _binary_ready():
    return os.path.isfile(BINARY) and os.access(BINARY, os.X_OK)


def _ensure_binary():
    """Return True if the real release binary is available, building it with
    the local Swift toolchain (no network) if it isn't already present."""
    if _binary_ready():
        return True
    try:
        subprocess.run(
            ["swift", "build", "-c", "release"],
            cwd=ROOT,
            check=True,
            capture_output=True,
            text=True,
            timeout=1800,
        )
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        return False
    return _binary_ready()


class RealPipelineAccessionContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not _ensure_binary():
            raise unittest.SkipTest(
                "BioLabExplorerPipeline release binary is unavailable and "
                "`swift build -c release` could not produce one in this "
                "environment; skipping the real-pipeline contract test"
            )
        if not os.path.isfile(REFERENCE):
            raise unittest.SkipTest(f"reference FASTA missing: {REFERENCE}")

    def test_real_swift_and_python_accession_extraction_agree(self):
        with tempfile.TemporaryDirectory() as d:
            fixture = os.path.join(d, "query.fasta")
            with open(fixture, "w", encoding="utf-8") as fh:
                fh.write(f">{FIXTURE_HEADER}\n{FIXTURE_SEQUENCE}\n")
            out_dir = os.path.join(d, "run_out")

            # Mirror the exact CLI scripts/run_discovery_cycle.sh invokes.
            proc = subprocess.run(
                [
                    BINARY,
                    "--input", fixture,
                    "--reference", REFERENCE,
                    "--output", out_dir,
                    "--max", "20",
                ],
                capture_output=True,
                text=True,
                timeout=300,
            )
            self.assertEqual(
                proc.returncode, 0,
                f"real BioLabExplorerPipeline invocation failed: "
                f"stdout={proc.stdout!r} stderr={proc.stderr!r}",
            )

            # Independent check #1: Python's accession_from_header on the raw
            # fixture header, exactly as discovery_db.parse_fasta() would
            # compute it while walking the same input FASTA.
            python_accession = db.accession_from_header(FIXTURE_HEADER)
            self.assertEqual(python_accession, FIXTURE_ACCESSION)

            # Independent check #2: read what the REAL Swift binary actually
            # computed, straight from its own real run-*.json output -- this
            # is Swift's FASTAParser.identifier(from:) result, not a
            # hardcoded expectation. Our fixture has exactly one input
            # record, so there is exactly one candidate.
            run_matches = sorted(glob.glob(os.path.join(out_dir, "run-*.json")))
            self.assertTrue(run_matches, f"no run-*.json written to {out_dir}")
            with open(run_matches[-1], "r", encoding="utf-8") as fh:
                run_json = json.load(fh)
            candidates = run_json.get("candidates", [])
            self.assertEqual(
                len(candidates), 1,
                f"expected exactly 1 candidate for the single-record fixture, "
                f"got {len(candidates)}: {candidates!r}",
            )
            swift_accession = candidates[0].get("sequence", {}).get("id")

            # The actual regression guard: Swift's real computed output and
            # Python's independently-derived value, from the same input
            # header, must be equal. If FASTAParser.identifier(from:) and
            # accession_from_header ever diverge again, this fails --
            # without needing UniProt data or the fake pipeline.
            self.assertEqual(swift_accession, python_accession)
            self.assertEqual(swift_accession, FIXTURE_ACCESSION)

            # Sanity check on the higher-level API too: discovery_db.load_run()
            # (used by record() in the real cycle) must expose the same
            # accession as a scores key, sourced from the same run-*.json.
            _qualifying, scores = db.load_run(out_dir)
            self.assertIn(swift_accession, scores)


if __name__ == "__main__":
    unittest.main()
