import hashlib, json, os, stat, sys, tempfile, time, unittest
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


def _candidate(accession, sequence):
    normalized = "".join(sequence.split()).upper()
    return {"accession": accession, "sequence": sequence,
            "seqSha256": hashlib.sha256(normalized.encode()).hexdigest()}


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
            _stub(d, "mk_prepare_receptor.py")
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
    def test_weighted_sequence_cpu_allocation_is_exact_and_work_conserving(self):
        original = sq.os.cpu_count
        sq.os.cpu_count = lambda: 15
        try:
            both = sq._sequence_cpu_threads(
                [{"backend": "mmseqs"}, {"backend": "hmmer"}],
                {"simMmseqsCpuWeight": 1, "simHmmerCpuWeight": 2},
            )
            hmmer_only = sq._sequence_cpu_threads([{"backend": "hmmer"}], CFG)
        finally:
            sq.os.cpu_count = original
        self.assertEqual(both, {"mmseqs": 5, "hmmer": 10})
        self.assertEqual(sum(both.values()), 15)
        self.assertEqual(hmmer_only, {"hmmer": 15})

    def test_fasta_input_uses_shared_accession_and_checksum_contract(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "input.fasta")
            with open(path, "w", encoding="utf-8") as fh:
                fh.write(">tr|A0TEST|ENTRY description\nmk t\n>bare-id note\nACD\n")
            candidates = sq.load_fasta_candidates(path)
            self.assertEqual([item["accession"] for item in candidates], ["A0TEST", "bare-id"])
            self.assertEqual(candidates[0]["sequence"], "MKT")
            self.assertEqual(candidates[0]["seqSha256"], hashlib.sha256(b"MKT").hexdigest())
            self.assertEqual(sq._validated_candidates(candidates)[0]["sequence"], "MKT")

    def test_accession_filter_requires_one_exact_match(self):
        candidates = [_candidate("A1", "MKT"), _candidate("A10", "AAA")]
        self.assertEqual(sq.filter_candidates(candidates, "A1")[0]["accession"], "A1")
        with self.assertRaisesRegex(ValueError, "exactly one"):
            sq.filter_candidates(candidates, "A")
        with self.assertRaisesRegex(ValueError, "exactly one"):
            sq.filter_candidates(candidates + [_candidate("A1", "CCC")], "A1")

    def test_run_with_no_backends_reports_cleanly(self):
        with tempfile.TemporaryDirectory() as d:
            os.environ["SIM_BIN_DIR"] = os.path.join(d, "empty")
            os.makedirs(os.environ["SIM_BIN_DIR"])
            try:
                rd = os.path.join(d, "run"); os.makedirs(rd)
                cands = [_candidate("A1", "MKT" * 10)]
                summary = sq.run(cands, rd, CFG)
            finally:
                os.environ.pop("SIM_BIN_DIR", None)
            self.assertEqual(summary["ran"], 0)
            self.assertTrue(summary["backends"])           # availability reported (visible)
            self.assertTrue(os.path.exists(os.path.join(rd, "sim", "summary.json")))

    def test_run_dispatches_available_stub(self):
        with tempfile.TemporaryDirectory() as d:
            b = os.path.join(d, "bin")
            _stub(b, "mmseqs", "#!/bin/sh\ncat \"$2\" > \"$4.input\"\nprintf 'hit\\n' > \"$4\"\n")
            reference = os.path.join(d, "reference.fasta")
            with open(reference, "w") as fh:
                fh.write(">REF\nMKT\n")
            os.environ["SIM_BIN_DIR"] = b
            try:
                rd = os.path.join(d, "run"); os.makedirs(rd)
                cands = [_candidate("A1", "MKT" * 10)]
                summary = sq.run(cands, rd, CFG, reference=reference)
            finally:
                os.environ.pop("SIM_BIN_DIR", None)
            self.assertGreaterEqual(summary["ran"], 1)
            job = next(j for j in summary["jobs"] if j["backend"] == "mmseqs")
            self.assertEqual(job["status"], "ok")
            self.assertTrue(os.path.exists(job["output"] + ".input"))
            with open(job["output"] + ".input") as fh:
                self.assertIn(">A1\nMKT", fh.read())

    def test_batch_search_uses_all_candidates_and_cpu_threads(self):
        with tempfile.TemporaryDirectory() as d:
            b = os.path.join(d, "bin")
            _stub(b, "mmseqs", "#!/bin/sh\nsleep 0.1\nprintf 'hit\\n' > \"$4\"\n")
            reference = os.path.join(d, "reference.fasta")
            with open(reference, "w") as fh:
                fh.write(">REF\nMKT\n")
            os.environ["SIM_BIN_DIR"] = b
            try:
                rd = os.path.join(d, "run"); os.makedirs(rd)
                cands = [_candidate(f"A{i}", "MKT" * 10) for i in range(6)]
                summary = sq.run(cands, rd, CFG, reference=reference)
            finally:
                os.environ.pop("SIM_BIN_DIR", None)
            self.assertEqual(summary["ran"], 1)
            self.assertEqual(summary["candidateCount"], 6)
            self.assertEqual(summary["resources"]["maxConcurrentObserved"], 1)
            self.assertGreaterEqual(summary["jobs"][0]["cpuThreads"], 2)
            self.assertEqual(summary["resources"]["cpuThreadsPerJob"],
                             summary["jobs"][0]["cpuThreads"])
            self.assertEqual(summary["resources"]["maxConcurrentCpuThreadsConfigured"],
                             summary["jobs"][0]["cpuThreads"])
            self.assertLessEqual(summary["resources"]["peakEstimatedRamBytes"],
                                 summary["resources"]["ramBudgetBytes"])

    def test_dynamic_dispatch_refills_after_ram_is_released(self):
        with tempfile.TemporaryDirectory() as d:
            exe = _stub(d, "mmseqs", "#!/bin/sh\nsleep 0.05\nprintf 'hit\\n' > \"$4\"\n")
            reference = os.path.join(d, "reference.fasta")
            with open(reference, "w") as fh:
                fh.write(">REF\nMKT\n")
            rd = os.path.join(d, "run"); os.makedirs(rd)
            jobs = [
                {"accession": f"A{i}", "sequence": "MKT", "seq_len": 3, "backend": "mmseqs"}
                for i in range(3)
            ]
            cfg = {**CFG, "simRamBudgetBytes": sq.GIB, "simMinMemoryFreePercent": 0,
                   "simMaxCpuJobs": 3, "simShutdownGraceSeconds": 1}
            results, skipped, resources = sq._run_parallel(
                jobs, {"mmseqs": {"available": True, "path": exe}}, rd, cfg,
                reference, time.monotonic() + 30,
            )
            self.assertEqual(len(results), 3)
            self.assertEqual(skipped, [])
            self.assertEqual(resources["maxConcurrentObserved"], 1)
            self.assertLessEqual(resources["peakEstimatedRamBytes"], sq.GIB)

    def test_soft_budget_stops_new_admission(self):
        with tempfile.TemporaryDirectory() as d:
            b = os.path.join(d, "bin")
            _stub(b, "mmseqs", "#!/bin/sh\nprintf 'hit\\n' > \"$4\"\n")
            reference = os.path.join(d, "reference.fasta")
            with open(reference, "w") as fh:
                fh.write(">REF\nMKT\n")
            os.environ["SIM_BIN_DIR"] = b
            try:
                rd = os.path.join(d, "run"); os.makedirs(rd)
                cfg = {**CFG, "simShutdownGraceSeconds": 5}
                summary = sq.run([_candidate("A1", "MKT")], rd, cfg,
                                 reference=reference, budget_seconds=1)
            finally:
                os.environ.pop("SIM_BIN_DIR", None)
            self.assertEqual(summary["ran"], 0)
            self.assertTrue(any(item["reason_code"] == "budget_expired"
                                for item in summary["skipped"]))

    def test_timeout_kills_spawned_process_group(self):
        with tempfile.TemporaryDirectory() as d:
            exe = _stub(d, "mmseqs", "#!/bin/sh\ntrap '' TERM\nsleep 10\n")
            reference = os.path.join(d, "reference.fasta")
            with open(reference, "w") as fh:
                fh.write(">REF\nMKT\n")
            rd = os.path.join(d, "run"); os.makedirs(rd)
            job = {"accession": "TIMEOUT", "sequence": "MKT", "seq_len": 3,
                   "backend": "mmseqs"}
            cfg = {**CFG, "simTerminationGraceSeconds": 1}
            started = time.monotonic()
            result = sq._run_command(
                job, {"mmseqs": {"available": True, "path": exe}}, rd, cfg,
                reference, cpu_threads=1, timeout=1,
            )
            self.assertEqual(result["status"], "timeout")
            self.assertLess(time.monotonic() - started, 4)

    def test_candidate_checksum_is_required_and_verified(self):
        with tempfile.TemporaryDirectory() as d:
            rd = os.path.join(d, "run"); os.makedirs(rd)
            with self.assertRaisesRegex(ValueError, "checksum mismatch"):
                sq.run([{"accession": "A1", "sequence": "MKT", "seqSha256": "0" * 64}],
                       rd, CFG)
            with self.assertRaisesRegex(ValueError, "checksum mismatch"):
                sq.run([{"accession": "A1", "sequence": "MKT"}], rd, CFG)


if __name__ == "__main__":
    unittest.main()
