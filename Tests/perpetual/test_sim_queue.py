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
        # ram_budget(cfg) = min(configured, sysctl hw.memsize - reserve), so with
        # CFG's real 4 GiB budget this test would depend on the host's actual RAM.
        # Worse, esmfold's floor (>=5 GiB, see estimate_ram) always exceeds a 4 GiB
        # budget, so every job would be skipped and "admitted" would stay empty --
        # both assertions below would pass vacuously. Patch ram_budget to a known
        # value and use vina (flat 0.75 GiB/job) so PARTIAL admission actually
        # happens and the boundary is exact: don't let a future edit "simplify"
        # this back to relying on CFG/real RAM.
        det = {"vina": {"available": True}}
        jobs = [{"backend": "vina", "seq_len": 100, "accession": f"A{i}"} for i in range(10)]
        orig = sq.ram_budget
        sq.ram_budget = lambda cfg: 2 * sq.GIB        # vina est = 0.75 GiB -> exactly 2 fit
        try:
            admitted, skipped = sq.schedule(jobs, CFG, det)
        finally:
            sq.ram_budget = orig
        self.assertEqual(len(admitted), 2)                            # partial admission actually happens
        total = sum(sq.estimate_ram(j["backend"], j["seq_len"], CFG) for j in admitted)
        self.assertLessEqual(total, 2 * sq.GIB)
        self.assertTrue(all(s["reason_code"] == "ram_budget" for s in skipped))

    def test_gpu_serialised(self):
        # With CFG's real 4 GiB budget, esmfold's >=5 GiB floor (see estimate_ram)
        # means every job is skipped for ram_budget before the GPU-serialisation
        # branch in schedule() is ever reached -- admitted stays empty and
        # `0 <= MAX_GPU_CONCURRENT` passes vacuously without exercising the
        # serialisation logic at all. Patch ram_budget so RAM is nowhere near the
        # binding constraint, then assert the GPU cap is hit exactly (not just
        # "under"), and that the overflow is skipped specifically for
        # gpu_serialised (not some other reason): don't let a future edit
        # "simplify" this back to relying on CFG/real RAM.
        det = {"esmfold": {"available": True}}
        jobs = [{"backend": "esmfold", "seq_len": 100, "accession": f"A{i}"} for i in range(5)]
        orig = sq.ram_budget
        sq.ram_budget = lambda cfg: 100 * sq.GIB      # RAM is not the constraint here
        try:
            admitted, skipped = sq.schedule(jobs, CFG, det)
        finally:
            sq.ram_budget = orig
        gpu_admitted = [j for j in admitted if sq.is_gpu(j["backend"])]
        self.assertEqual(len(gpu_admitted), sq.MAX_GPU_CONCURRENT)   # exactly the cap, not 0
        self.assertTrue(any(s["reason_code"] == "gpu_serialised" for s in skipped))

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
