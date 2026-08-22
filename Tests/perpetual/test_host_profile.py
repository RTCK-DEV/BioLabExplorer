"""Auto-resolution must be deterministic for a given host description.

Every test supplies a synthetic host dict, so the assertions hold on any
machine that runs the suite (including CI runners with different core counts).
"""

import json, os, subprocess, sys, tempfile, unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "..", "scripts"))
import host_profile as hp

GIB = 1 << 30
ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


def host(memory=24 * GIB, disk=200 * GIB, system="Darwin", machine="arm64", nvidia=False):
    return {
        "system": system,
        "machine": machine,
        "release": "test",
        "logicalCpuCount": 15,
        "physicalMemoryBytes": memory,
        "physicalMemoryDetected": memory is not None,
        "freeDiskBytes": disk,
        "freeDiskDetected": disk is not None,
        "appleSilicon": system == "Darwin" and machine == "arm64",
        "nvidiaGpuDetected": nvidia,
    }


AUTO_CFG = {
    "simReserveBytes": "auto",
    "simRamBudgetBytes": "auto",
    "maxWorkspaceBytes": "auto",
    "simMaxCpuJobs": "auto",
    "esmfoldDevice": "auto",
    "openmmPlatform": "auto",
}


class ResolutionTests(unittest.TestCase):
    def test_explicit_values_are_never_overridden(self):
        cfg = {**AUTO_CFG, "simRamBudgetBytes": 3 * GIB, "esmfoldDevice": "cpu"}
        resolved, notes = hp.resolve_config(cfg, host=host())
        self.assertEqual(resolved["simRamBudgetBytes"], 3 * GIB)
        self.assertEqual(resolved["esmfoldDevice"], "cpu")
        self.assertNotIn("simRamBudgetBytes", {n["key"] for n in notes})

    def test_input_mapping_is_not_mutated(self):
        cfg = dict(AUTO_CFG)
        hp.resolve_config(cfg, host=host())
        self.assertEqual(cfg["simRamBudgetBytes"], "auto")

    def test_reserve_and_budget_partition_physical_memory(self):
        resolved, _ = hp.resolve_config(AUTO_CFG, host=host(memory=24 * GIB))
        self.assertEqual(resolved["simReserveBytes"], 8 * GIB)
        self.assertEqual(resolved["simRamBudgetBytes"], 16 * GIB)
        self.assertEqual(
            resolved["simReserveBytes"] + resolved["simRamBudgetBytes"], 24 * GIB
        )

    def test_small_host_keeps_a_four_gib_floor_for_the_system(self):
        resolved, _ = hp.resolve_config(AUTO_CFG, host=host(memory=8 * GIB))
        self.assertEqual(resolved["simReserveBytes"], 4 * GIB)
        self.assertEqual(resolved["simRamBudgetBytes"], 4 * GIB)

    def test_large_host_scales_up(self):
        resolved, _ = hp.resolve_config(AUTO_CFG, host=host(memory=128 * GIB))
        self.assertGreater(resolved["simRamBudgetBytes"], 64 * GIB)
        self.assertLess(resolved["simRamBudgetBytes"], 128 * GIB)

    def test_undetected_memory_falls_back_without_raising(self):
        resolved, _ = hp.resolve_config(AUTO_CFG, host=host(memory=None))
        self.assertEqual(resolved["simReserveBytes"], 4 * GIB)
        self.assertGreater(resolved["simRamBudgetBytes"], 0)

    def test_workspace_cap_is_clamped_to_five_and_twenty_gib(self):
        tiny, _ = hp.resolve_config(AUTO_CFG, host=host(disk=1 * GIB))
        huge, _ = hp.resolve_config(AUTO_CFG, host=host(disk=4000 * GIB))
        mid, _ = hp.resolve_config(AUTO_CFG, host=host(disk=40 * GIB))
        self.assertEqual(tiny["maxWorkspaceBytes"], 5 * GIB)
        self.assertEqual(huge["maxWorkspaceBytes"], 20 * GIB)
        self.assertEqual(mid["maxWorkspaceBytes"], 10 * GIB)

    def test_esmfold_device_follows_apple_silicon(self):
        mac, _ = hp.resolve_config(AUTO_CFG, host=host())
        intel_mac, _ = hp.resolve_config(AUTO_CFG, host=host(machine="x86_64"))
        linux, _ = hp.resolve_config(AUTO_CFG, host=host(system="Linux", machine="x86_64"))
        self.assertEqual(mac["esmfoldDevice"], "mps")
        self.assertEqual(intel_mac["esmfoldDevice"], "cpu")
        self.assertEqual(linux["esmfoldDevice"], "cpu")

    def test_openmm_platform_prefers_cuda_then_falls_back_by_os(self):
        cuda, _ = hp.resolve_config(AUTO_CFG, host=host(system="Linux", machine="x86_64", nvidia=True))
        linux, _ = hp.resolve_config(AUTO_CFG, host=host(system="Linux", machine="x86_64"))
        mac, _ = hp.resolve_config(AUTO_CFG, host=host())
        self.assertEqual(cuda["openmmPlatform"], "CUDA")
        self.assertEqual(linux["openmmPlatform"], "OpenCL")
        self.assertEqual(mac["openmmPlatform"], "CPU")

    def test_every_auto_key_is_reported_with_a_reason(self):
        resolved, notes = hp.resolve_config(AUTO_CFG, host=host())
        self.assertEqual({n["key"] for n in notes}, set(AUTO_CFG))
        for note in notes:
            self.assertTrue(note["reason"].strip(), f"{note['key']} has no reason")
            self.assertNotEqual(resolved[note["key"]], "auto")

    def test_no_auto_value_survives_resolution(self):
        resolved, _ = hp.resolve_config(AUTO_CFG, host=host())
        self.assertNotIn("auto", [v for v in resolved.values() if isinstance(v, str)])

    def test_unknown_keys_pass_through_untouched(self):
        cfg = {**AUTO_CFG, "uniprotHost": "rest.uniprot.org", "enableNetwork": True}
        resolved, _ = hp.resolve_config(cfg, host=host())
        self.assertEqual(resolved["uniprotHost"], "rest.uniprot.org")
        self.assertIs(resolved["enableNetwork"], True)


class DetectionTests(unittest.TestCase):
    def test_detect_reports_the_real_host_without_raising(self):
        facts = hp.detect()
        self.assertGreaterEqual(facts["logicalCpuCount"], 1)
        self.assertIn("system", facts)
        self.assertIsInstance(facts["appleSilicon"], bool)
        if facts["physicalMemoryDetected"]:
            self.assertGreater(facts["physicalMemoryBytes"], 0)

    def test_load_resolved_reads_a_file_and_leaves_no_auto(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "worker.json")
            with open(path, "w", encoding="utf-8") as fh:
                json.dump(AUTO_CFG, fh)
            resolved = hp.load_resolved(path)
            self.assertNotIn("auto", [v for v in resolved.values() if isinstance(v, str)])


class CommandLineTests(unittest.TestCase):
    script = os.path.join(ROOT, "scripts", "host_profile.py")

    def _run(self, *args):
        return subprocess.run(
            [sys.executable, self.script, *args], capture_output=True, text=True, timeout=60
        )

    def test_bare_invocation_emits_host_json(self):
        result = self._run()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("logicalCpuCount", json.loads(result.stdout))

    def test_key_lookup_prints_a_resolved_scalar(self):
        result = self._run("--config", os.path.join(ROOT, "config", "worker.json"),
                           "--key", "simRamBudgetBytes")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertGreater(int(result.stdout.strip()), 0)

    def test_unknown_key_fails_loudly(self):
        result = self._run("--config", os.path.join(ROOT, "config", "worker.json"),
                           "--key", "nope")
        self.assertEqual(result.returncode, 2)
        self.assertIn("unknown key", result.stderr)

    def test_explain_names_every_derived_key(self):
        result = self._run("--config", os.path.join(ROOT, "config", "worker.json"), "--explain")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("simRamBudgetBytes", result.stdout)

    def test_checked_in_config_resolves_to_a_usable_configuration(self):
        result = self._run("--config", os.path.join(ROOT, "config", "worker.json"))
        self.assertEqual(result.returncode, 0, result.stderr)
        resolved = json.loads(result.stdout)
        self.assertIsInstance(resolved["simRamBudgetBytes"], int)
        self.assertIn(resolved["esmfoldDevice"], ("mps", "cpu"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
