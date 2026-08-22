import hashlib, json, os, sys, tempfile, unittest
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "scripts"))
import sim_queue as sq
import vina_dock as vd
import openmm_relax as omr
import esmfold_hf as ehf


class ScientificPipelineTests(unittest.TestCase):
    def test_motif_anchor_and_supporting_positions(self):
        residue, motif, supporting = vd._anchor(
            "AAAASTFKAAAAKTGAAAASIN", {"anchorPattern": "S..K", "anchorResidueOffset": 0,
                                      "supportingPatterns": ["KTG", "S.N"]})
        self.assertEqual((residue, motif), (5, "STFK"))
        self.assertEqual(supporting, {"KTG": [13], "S.N": [20]})

    def test_ca_coordinate_requires_unambiguous_residue(self):
        with tempfile.TemporaryDirectory() as d:
            pdb = os.path.join(d, "x.pdb")
            with open(pdb, "w") as fh:
                fh.write("ATOM      1  CA  SER A 484      12.545   0.831 -19.870  1.00 90.00           C  \n")
            self.assertEqual(vd._ca_coordinate(pdb, 484), (12.545, 0.831, -19.87, "A"))
            with self.assertRaisesRegex(ValueError, "exactly one CA"):
                vd._ca_coordinate(pdb, 485)

    def test_candidate_metadata_is_preserved_for_manifest_gate(self):
        sequence = "MKT"
        item = {"accession": "A1", "sequence": sequence,
                "seqSha256": hashlib.sha256(sequence.encode()).hexdigest(),
                "classification": "Remote PBP", "score": 0.91}
        validated = sq._validated_candidates([item])[0]
        self.assertEqual(validated["classification"], "Remote PBP")
        self.assertEqual(validated["score"], 0.91)

    def test_cached_structure_is_exact_accession_only(self):
        with tempfile.TemporaryDirectory() as d:
            wanted = os.path.join(d, "AF-A1-F1-model_v6.pdb")
            with open(wanted, "w") as fh: fh.write("END\n")
            with open(os.path.join(d, "AF-A10-F1-model_v6.pdb"), "w") as fh: fh.write("END\n")
            self.assertEqual(sq._cached_structure({"structureFallbackDirectory": d}, "A1"), wanted)
            self.assertIsNone(sq._cached_structure({"structureFallbackDirectory": d}, "*"))

    def test_relaxed_pdb_restores_residue_plddt_to_added_atoms(self):
        with tempfile.TemporaryDirectory() as d:
            source = os.path.join(d, "source.pdb")
            raw = os.path.join(d, "raw.pdb")
            output = os.path.join(d, "output.pdb")
            with open(source, "w") as fh:
                fh.write("ATOM      1  CA  SER A 484      12.545   0.831 -19.870  1.00 87.25           C  \n")
            with open(raw, "w") as fh:
                fh.write("ATOM      1  CA  SER A 484      12.500   0.900 -19.800  1.00  0.00           C  \n")
                fh.write("ATOM      2  HA  SER A 484      12.600   0.800 -19.700  1.00  0.00           H  \n")
            confidence = omr._residue_confidence(source)
            self.assertEqual(omr._restore_residue_confidence(raw, output, confidence), 1)
            with open(output) as fh:
                lines = fh.readlines()
            self.assertEqual([float(line[60:66]) for line in lines], [87.25, 87.25])

    def test_esmfold_adapter_rejects_multiple_or_invalid_records_before_model_load(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "x.fasta")
            with open(path, "w") as fh: fh.write(">A\nMKT\n>B\nAAA\n")
            with self.assertRaisesRegex(ValueError, "exactly one"):
                ehf._load_one_fasta(path)
            with open(path, "w") as fh: fh.write(">A\nMK*\n")
            with self.assertRaisesRegex(ValueError, "unsupported"):
                ehf._load_one_fasta(path)

    def test_esmfold_plddt_normalizes_fractional_b_factors(self):
        pdb = ("ATOM      1  CA  ALA A   1       0.000   0.000   0.000  1.00  0.62           C  \n"
               "ATOM      2  CB  ALA A   1       0.000   0.000   0.000  1.00  0.58           C  \n")
        normalized, scale = ehf._normalize_plddt_b_factors(pdb)
        self.assertEqual(scale, 100.0)
        self.assertEqual([float(line[60:66]) for line in normalized.splitlines()], [62.0, 58.0])

    def test_esmfold_checkpoint_allows_only_unused_contact_head(self):
        allowed = ["esm.contact_head.regression.bias", "esm.contact_head.regression.weight"]
        self.assertEqual(ehf._validate_checkpoint_keys({"missing_keys": allowed}), (set(allowed), set()))
        with self.assertRaisesRegex(RuntimeError, "checkpoint key contract mismatch"):
            ehf._validate_checkpoint_keys({"missing_keys": ["folding_trunk.required_weight"]})
        with self.assertRaisesRegex(RuntimeError, "checkpoint key contract mismatch"):
            ehf._validate_checkpoint_keys({"unexpected_keys": ["unknown.weight"]})


if __name__ == "__main__":
    unittest.main()
