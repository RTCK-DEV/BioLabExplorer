import json, os, stat, sys, tempfile, unittest
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "scripts"))
import sim_queue as sq

CFG = {"simRamBudgetBytes": 4 * (1 << 30), "simReserveBytes": 0,
       "simMaxSeqLength": 700, "simJobTimeoutSeconds": 30,
       "enableColabFold": False, "externalMsaStorePath": ""}


def _stub(dirpath, name, body="#!/bin/sh\necho stub-ok\nexit 0\n"):
    os.makedirs(dirpath, exist_ok=True)
    p = os.path.join(dirpath, name)
    with open(p, "w") as fh:
        fh.write(body)
    os.chmod(p, os.stat(p).st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
    return p


class DetectTests(unittest.TestCase):
    def test_absent_backend_is_visible_not_fatal(self):
        with tempfile.TemporaryDirectory() as d:
            os.environ["SIM_BIN_DIR"] = d  # empty -> nothing found
            try:
                det = sq.detect_backends(CFG)
            finally:
                os.environ.pop("SIM_BIN_DIR", None)
            self.assertIn("vina", det)
            self.assertFalse(det["vina"]["available"])
            self.assertTrue(det["vina"]["reason"])  # a human-readable reason

    def test_stub_backend_detected(self):
        with tempfile.TemporaryDirectory() as d:
            _stub(d, "vina")
            os.environ["SIM_BIN_DIR"] = d
            try:
                det = sq.detect_backends(CFG)
            finally:
                os.environ.pop("SIM_BIN_DIR", None)
            self.assertTrue(det["vina"]["available"])


class ScheduleTests(unittest.TestCase):
    def test_ram_budget_admission(self):
        det = {"vina": {"available": True}, "esmfold": {"available": True}}
        # budget 4GiB; esmfold jobs estimated >1GiB each -> not all admitted
        jobs = [{"backend": "esmfold", "seq_len": 300, "accession": f"A{i}"} for i in range(10)]
        admitted, skipped = sq.schedule(jobs, CFG, det)
        total = sum(sq.estimate_ram(j["backend"], j["seq_len"], CFG) for j in admitted)
        self.assertLessEqual(total, CFG["simRamBudgetBytes"])
        self.assertTrue(skipped)  # some deferred by budget

    def test_gpu_serialised(self):
        det = {"esmfold": {"available": True}}
        jobs = [{"backend": "esmfold", "seq_len": 100, "accession": f"A{i}"} for i in range(5)]
        admitted, _ = sq.schedule(jobs, CFG, det)
        self.assertLessEqual(len([j for j in admitted if sq.is_gpu(j["backend"])]), sq.MAX_GPU_CONCURRENT)

    def test_length_gate_skips_long_sequences(self):
        det = {"esmfold": {"available": True}}
        jobs = [{"backend": "esmfold", "seq_len": 5000, "accession": "LONG"}]
        admitted, skipped = sq.schedule(jobs, CFG, det)
        self.assertEqual(admitted, [])
        self.assertEqual(skipped[0]["reason_code"], "too_long")

    def test_unavailable_backend_skipped_with_reason(self):
        det = {"esmfold": {"available": False, "reason": "torch not installed"}}
        jobs = [{"backend": "esmfold", "seq_len": 100, "accession": "A1"}]
        admitted, skipped = sq.schedule(jobs, CFG, det)
        self.assertEqual(admitted, [])
        self.assertEqual(skipped[0]["reason_code"], "unavailable")


class RunTests(unittest.TestCase):
    def test_run_with_no_backends_reports_cleanly(self):
        with tempfile.TemporaryDirectory() as d:
            os.environ["SIM_BIN_DIR"] = os.path.join(d, "empty")
            os.makedirs(os.environ["SIM_BIN_DIR"])
            try:
                rd = os.path.join(d, "run"); os.makedirs(rd)
                cands = [{"accession": "A1", "sequence": "MKT" * 10}]
                summary = sq.run(cands, rd, CFG)
            finally:
                os.environ.pop("SIM_BIN_DIR", None)
            self.assertEqual(summary["ran"], 0)
            self.assertTrue(summary["backends"])           # availability reported (visible)
            self.assertTrue(os.path.exists(os.path.join(rd, "sim", "summary.json")))

    def test_run_dispatches_available_stub(self):
        with tempfile.TemporaryDirectory() as d:
            b = os.path.join(d, "bin"); _stub(b, "mmseqs")
            os.environ["SIM_BIN_DIR"] = b
            try:
                rd = os.path.join(d, "run"); os.makedirs(rd)
                cands = [{"accession": "A1", "sequence": "MKT" * 10}]
                summary = sq.run(cands, rd, CFG)
            finally:
                os.environ.pop("SIM_BIN_DIR", None)
            self.assertGreaterEqual(summary["ran"], 1)
            self.assertTrue(any(j["backend"] == "mmseqs" and j["status"] == "ok" for j in summary["jobs"]))


if __name__ == "__main__":
    unittest.main()
