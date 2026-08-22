#!/usr/bin/env python3
"""Minimize one protein structure with OpenMM and emit auditable metrics."""
import argparse
import hashlib
import json
import os
import random
import tempfile
import sys


def _sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            digest.update(chunk)
    return "sha256:" + digest.hexdigest()


def _atomic_json(path, value):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    fd, temp = tempfile.mkstemp(dir=os.path.dirname(path) or ".", suffix=".tmp")
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(value, fh, indent=2, sort_keys=True)
    os.replace(temp, path)


def _residue_confidence(path):
    values = {}
    with open(path, encoding="utf-8") as fh:
        for line in fh:
            if line.startswith("ATOM  ") and line[12:16].strip() == "CA":
                try:
                    key = (line[21], line[22:26], line[26])
                    values[key] = float(line[60:66])
                except ValueError:
                    continue
    return values


def _restore_residue_confidence(source_path, output_path, confidence):
    restored = set()
    with open(source_path, encoding="utf-8") as source, open(output_path, "w", encoding="utf-8") as output:
        for line in source:
            if line.startswith(("ATOM  ", "HETATM")) and len(line) >= 66:
                key = (line[21], line[22:26], line[26])
                if key in confidence:
                    line = line[:60] + f"{confidence[key]:6.2f}" + line[66:]
                    restored.add(key)
            output.write(line)
    return len(restored)


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--metrics", required=True)
    parser.add_argument("--platform", default="CPU",
                        choices=("auto", "CPU", "CUDA", "OpenCL", "Reference"))
    parser.add_argument("--allow-cpu-fallback", action="store_true")
    parser.add_argument("--precision", default="mixed", choices=("single", "mixed", "double"))
    parser.add_argument("--max-iterations", type=int, default=1000)
    parser.add_argument("--seed", type=int, default=20260715)
    args = parser.parse_args(argv)
    if args.max_iterations <= 0:
        parser.error("--max-iterations must be > 0")

    from openmm import LangevinMiddleIntegrator, Platform
    from openmm.app import ForceField, Modeller, NoCutoff, PDBFile, Simulation
    from openmm.unit import kelvin, kilojoule_per_mole, picosecond
    from pdbfixer import PDBFixer

    random.seed(args.seed)  # Modeller.addHydrogens uses Python's random module.
    fixer = PDBFixer(filename=args.input)
    fixer.platform = Platform.getPlatformByName("CPU")
    fixer.findMissingResidues()
    fixer.missingResidues = {}  # Never invent unresolved loops in this relaxation stage.
    fixer.findMissingAtoms()
    missing_heavy_atoms = sum(len(atoms) for atoms in fixer.missingAtoms.values())
    missing_terminals = sum(len(atoms) for atoms in fixer.missingTerminals.values())
    fixer.addMissingAtoms(seed=args.seed)
    forcefield = ForceField("amber14-all.xml", "amber14/tip3pfb.xml")
    modeller = Modeller(fixer.topology, fixer.positions)
    modeller.addHydrogens(forcefield, platform=Platform.getPlatformByName("CPU"))
    system = forcefield.createSystem(modeller.topology, nonbondedMethod=NoCutoff)
    requested_platform = args.platform
    if requested_platform == "auto":
        # Try accelerated platforms first, then CPU. Every attempt is recorded
        # in the metrics file, so the selected platform stays auditable.
        platform_names = ["CUDA", "OpenCL", "CPU"]
    else:
        platform_names = [requested_platform]
        if args.allow_cpu_fallback and requested_platform != "CPU":
            platform_names.append("CPU")
    attempts = []
    simulation = None
    properties = {}
    for platform_name in platform_names:
        try:
            integrator = LangevinMiddleIntegrator(300 * kelvin, 1 / picosecond, 0.002 * picosecond)
            integrator.setRandomNumberSeed(args.seed)
            platform = Platform.getPlatformByName(platform_name)
            properties = ({"Precision": args.precision}
                          if platform_name in ("OpenCL", "CUDA") else {})
            simulation = Simulation(modeller.topology, system, integrator, platform, properties)
            attempts.append({"platform": platform_name, "status": "selected"})
            break
        except Exception as exc:
            attempts.append({"platform": platform_name, "status": "failed", "reason": str(exc)})
    if simulation is None:
        raise RuntimeError("no requested OpenMM platform could create a Context: " + json.dumps(attempts))
    simulation.context.setPositions(modeller.positions)
    initial = simulation.context.getState(getEnergy=True)
    initial_energy = initial.getPotentialEnergy().value_in_unit(kilojoule_per_mole)
    simulation.minimizeEnergy(maxIterations=args.max_iterations)
    state = simulation.context.getState(getPositions=True, getEnergy=True)
    final_energy = state.getPotentialEnergy().value_in_unit(kilojoule_per_mole)

    os.makedirs(os.path.dirname(args.output) or ".", exist_ok=True)
    confidence = _residue_confidence(args.input)
    fd, raw_output = tempfile.mkstemp(dir=os.path.dirname(args.output) or ".", suffix=".raw.pdb")
    with os.fdopen(fd, "w", encoding="utf-8") as output:
        PDBFile.writeFile(modeller.topology, state.getPositions(), output, keepIds=True)
    restored_residues = _restore_residue_confidence(raw_output, args.output, confidence)
    os.unlink(raw_output)
    metrics = {
        "schemaVersion": 1,
        "method": "OpenMM energy minimization",
        "forceField": ["amber14-all.xml", "amber14/tip3pfb.xml"],
        "nonbondedMethod": "NoCutoff",
        "platform": simulation.context.getPlatform().getName(),
        "requestedPlatform": requested_platform,
        "platformAttempts": attempts,
        "usedCpuFallback": simulation.context.getPlatform().getName() != platform_names[0],
        "cpuThreads": int(os.environ.get("OPENMM_CPU_THREADS", "1")),
        "platformProperties": properties,
        "maxIterations": args.max_iterations,
        "seed": args.seed,
        "atomCount": modeller.topology.getNumAtoms(),
        "residueCount": modeller.topology.getNumResidues(),
        "pdbFixerMissingHeavyAtomsAdded": missing_heavy_atoms,
        "pdbFixerMissingTerminalAtomsAdded": missing_terminals,
        "pdbFixerMissingResiduesAdded": 0,
        "confidenceSource": "input PDB CA B-factor propagated to every atom in the relaxed residue",
        "confidenceResiduesRestored": restored_residues,
        "initialPotentialEnergyKJPerMol": initial_energy,
        "finalPotentialEnergyKJPerMol": final_energy,
        "energyDropKJPerMol": initial_energy - final_energy,
        "input": os.path.abspath(args.input),
        "inputSha256": _sha256(args.input),
        "output": os.path.abspath(args.output),
        "outputSha256": _sha256(args.output),
    }
    _atomic_json(args.metrics, metrics)
    print(json.dumps({"platform": metrics["platform"], "usedCpuFallback": metrics["usedCpuFallback"],
                      "energyDropKJPerMol": metrics["energyDropKJPerMol"]}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
