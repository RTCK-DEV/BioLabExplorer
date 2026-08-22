#!/usr/bin/env python3
"""Manifest-gated receptor preparation and AutoDock Vina execution."""
import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile


def _sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return "sha256:" + h.hexdigest()


def _atomic_json(path, value):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    fd, temp = tempfile.mkstemp(dir=os.path.dirname(path) or ".", suffix=".tmp")
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(value, fh, indent=2, sort_keys=True)
    os.replace(temp, path)


def _require(condition, message):
    if not condition:
        raise ValueError(message)


def _tool_version(command):
    probe = subprocess.run(command, capture_output=True, text=True, timeout=30)
    return (probe.stdout or probe.stderr).strip().splitlines()[0] if probe.returncode == 0 else "unknown"


def _anchor(sequence, site):
    match = re.search(site["anchorPattern"], sequence)
    _require(match is not None, f"required docking anchor motif absent: {site['anchorPattern']}")
    residue = match.start() + 1 + int(site.get("anchorResidueOffset", 0))
    supporting = {pattern: [m.start() + 1 for m in re.finditer(pattern, sequence)]
                  for pattern in site.get("supportingPatterns", [])}
    return residue, match.group(0), supporting


def _ca_coordinate(pdb_path, residue_number):
    hits = []
    with open(pdb_path, encoding="utf-8") as fh:
        for line in fh:
            if line.startswith(("ATOM  ", "HETATM")) and line[12:16].strip() == "CA":
                try:
                    if int(line[22:26]) == residue_number:
                        hits.append((float(line[30:38]), float(line[38:46]), float(line[46:54]), line[21].strip()))
                except ValueError:
                    continue
    _require(len(hits) == 1, f"expected exactly one CA for anchor residue {residue_number}, found {len(hits)}")
    return hits[0]


def _run(command, label):
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError(f"{label} failed rc={result.returncode}: {(result.stderr or result.stdout)[-2000:]}")
    return result


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("--receptor-pdb", required=True)
    ap.add_argument("--sequence-file", required=True)
    ap.add_argument("--classification", required=True)
    ap.add_argument("--manifest", required=True)
    ap.add_argument("--output-dir", required=True)
    ap.add_argument("--vina", required=True)
    ap.add_argument("--meeko", required=True)
    ap.add_argument("--cpu", required=True, type=int)
    args = ap.parse_args(argv)
    _require(args.cpu > 0, "cpu must be > 0")
    with open(args.manifest, encoding="utf-8") as fh:
        manifest = json.load(fh)
    _require(manifest.get("schemaVersion") == 1, "unsupported docking manifest schema")
    _require(args.classification in manifest.get("allowedClassifications", []),
             f"classification outside reviewed docking scope: {args.classification}")
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    ligand = manifest["ligand"]
    source_sdf = os.path.join(root, ligand["sourceSdf"])
    ligand_pdbqt = os.path.join(root, ligand["preparedPdbqt"])
    _require(os.path.isfile(source_sdf), f"vendored ligand SDF missing: {source_sdf}")
    _require(_sha256(source_sdf) == ligand["sourceSha256"], "vendored ligand SDF digest mismatch")
    _require(os.path.isfile(ligand_pdbqt), f"prepared ligand PDBQT missing: {ligand_pdbqt}")
    _require(_sha256(ligand_pdbqt) == ligand["preparedSha256"], "prepared ligand PDBQT digest mismatch")

    with open(args.sequence_file, encoding="utf-8") as fh:
        sequence = "".join(line.strip() for line in fh if not line.startswith(">"))
    _require(bool(sequence), "sequence file contains no residues")
    anchor_residue, anchor_motif, supporting = _anchor(sequence, manifest["siteSelection"])
    x, y, z, chain = _ca_coordinate(args.receptor_pdb, anchor_residue)
    size = [float(value) for value in manifest["siteSelection"]["boxSizeAngstrom"]]
    _require(len(size) == 3 and all(8 <= value <= 40 for value in size), "invalid docking box size")
    os.makedirs(args.output_dir, exist_ok=True)
    receptor_prefix = os.path.join(args.output_dir, "receptor")
    prep_command = [args.meeko, "-i", args.receptor_pdb, "-o", receptor_prefix, "-p"]
    prep = _run(prep_command, "Meeko receptor preparation")
    receptor_pdbqt = receptor_prefix + ".pdbqt"
    _require(os.path.isfile(receptor_pdbqt), f"Meeko receptor output missing: {receptor_pdbqt}")
    output = os.path.join(args.output_dir, "pose.pdbqt")
    vcfg = manifest["vina"]
    command = [args.vina, "--receptor", receptor_pdbqt, "--ligand", ligand_pdbqt,
               "--out", output, "--scoring", str(vcfg["scoring"]),
               "--center_x", str(x), "--center_y", str(y), "--center_z", str(z),
               "--size_x", str(size[0]), "--size_y", str(size[1]), "--size_z", str(size[2]),
               "--cpu", str(args.cpu), "--exhaustiveness", str(vcfg["exhaustiveness"]),
               "--num_modes", str(vcfg["numModes"]), "--energy_range", str(vcfg["energyRangeKcalPerMol"]),
               "--seed", str(vcfg["seed"])]
    vina = _run(command, "AutoDock Vina")
    _require(os.path.isfile(output), f"Vina pose output missing: {output}")
    affinities = []
    with open(output, encoding="utf-8") as fh:
        for line in fh:
            match = re.match(r"REMARK VINA RESULT:\s+(-?[0-9.]+)", line)
            if match:
                affinities.append(float(match.group(1)))
    _require(affinities, "Vina output contains no parseable affinity")
    metrics_path = os.path.join(args.output_dir, "docking_metrics.json")
    metrics = {
        "schemaVersion": 1,
        "method": "AutoDock Vina hypothesis-ranking docking",
        "interpretation": manifest["interpretation"],
        "classification": args.classification,
        "ligand": ligand,
        "site": {"anchorPattern": manifest["siteSelection"]["anchorPattern"],
                 "anchorMotif": anchor_motif, "anchorResidue": anchor_residue, "chain": chain,
                 "centerAngstrom": [x, y, z], "sizeAngstrom": size,
                 "supportingPatternPositions": supporting},
        "bestAffinityKcalPerMol": min(affinities),
        "modeAffinitiesKcalPerMol": affinities,
        "receptorInput": os.path.abspath(args.receptor_pdb),
        "receptorInputSha256": _sha256(args.receptor_pdb),
        "preparedReceptorSha256": _sha256(receptor_pdbqt),
        "pose": os.path.abspath(output),
        "poseSha256": _sha256(output),
        "manifestSha256": _sha256(args.manifest),
        "tools": {"vina": _tool_version([args.vina, "--version"]), "meeko": os.path.abspath(args.meeko)},
        "commands": {"receptorPreparation": prep_command, "vina": command},
        "stdoutTail": vina.stdout[-4000:],
        "receptorPreparationStderrTail": prep.stderr[-2000:],
    }
    _atomic_json(metrics_path, metrics)
    print(json.dumps({"bestAffinityKcalPerMol": metrics["bestAffinityKcalPerMol"], "anchorResidue": anchor_residue}))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        print(f"vina_dock: {exc}", file=sys.stderr)
        sys.exit(2)
