#!/usr/bin/env python3
"""Hugging Face ESMFold adapter with revision and provenance pinning."""
import argparse
import hashlib
import json
import os
import re
import sys
import tempfile
import time


def _atomic_json(path, value):
    fd, temp = tempfile.mkstemp(dir=os.path.dirname(path) or ".", suffix=".tmp")
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(value, fh, indent=2, sort_keys=True)
    os.replace(temp, path)


def _load_one_fasta(path):
    records, header, sequence = [], None, []
    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.strip()
            if not line:
                continue
            if line.startswith(">"):
                if header is not None:
                    records.append((header, "".join(sequence)))
                header, sequence = line[1:].split(maxsplit=1)[0], []
            else:
                if header is None:
                    raise ValueError("FASTA sequence before header")
                sequence.append(line.upper())
    if header is not None:
        records.append((header, "".join(sequence)))
    if len(records) != 1:
        raise ValueError(f"ESMFold adapter requires exactly one FASTA record, found {len(records)}")
    accession, sequence = records[0]
    if not sequence or re.search(r"[^ACDEFGHIKLMNPQRSTVWYX]", sequence):
        raise ValueError("FASTA contains an empty or unsupported protein sequence")
    return accession, sequence


def _normalize_plddt_b_factors(pdb_text):
    ca_values = []
    for line in pdb_text.splitlines():
        if line.startswith("ATOM  ") and line[12:16].strip() == "CA":
            try: ca_values.append(float(line[60:66]))
            except ValueError: pass
    scale = 100.0 if ca_values and max(ca_values) <= 1.5 else 1.0
    if scale == 1.0:
        return pdb_text, scale
    lines = []
    for line in pdb_text.splitlines(keepends=True):
        if line.startswith("ATOM  ") and len(line) >= 66:
            try: line = line[:60] + f"{float(line[60:66]) * scale:6.2f}" + line[66:]
            except ValueError: pass
        lines.append(line)
    return "".join(lines), scale


def _validate_checkpoint_keys(loading_info):
    allowed_missing = {"esm.contact_head.regression.bias", "esm.contact_head.regression.weight"}
    missing_keys = set(loading_info.get("missing_keys", []))
    unexpected_keys = set(loading_info.get("unexpected_keys", []))
    if missing_keys - allowed_missing or unexpected_keys:
        raise RuntimeError(f"checkpoint key contract mismatch: missing={sorted(missing_keys)} "
                           f"unexpected={sorted(unexpected_keys)}")
    return missing_keys, unexpected_keys


def main(argv=None):
    ap = argparse.ArgumentParser()
    ap.add_argument("-i", "--input", required=True)
    ap.add_argument("-o", "--output", required=True)
    ap.add_argument("--manifest", default=os.path.join(os.path.dirname(os.path.dirname(__file__)),
                                                       "config", "folding_manifest.json"))
    ap.add_argument("--device", choices=("auto", "mps", "cpu"), default="auto")
    ap.add_argument("--allow-network", action="store_true")
    args = ap.parse_args(argv)
    with open(args.manifest, encoding="utf-8") as fh:
        manifest = json.load(fh)
    if manifest.get("schemaVersion") != 1:
        raise ValueError("unsupported folding manifest schema")
    accession, sequence = _load_one_fasta(args.input)
    if len(sequence) > int(manifest["maxSequenceLength"]):
        raise ValueError(f"sequence length {len(sequence)} exceeds reviewed limit {manifest['maxSequenceLength']}")

    import torch
    from transformers import AutoTokenizer, EsmForProteinFolding

    have_mps = torch.backends.mps.is_available() and torch.backends.mps.is_built()
    device = "mps" if args.device == "auto" and have_mps else ("cpu" if args.device == "auto" else args.device)
    if device == "mps" and not have_mps:
        raise RuntimeError("MPS requested but torch reports it unavailable")
    started = time.monotonic()
    seed = 20260715
    torch.manual_seed(seed)
    if have_mps:
        torch.mps.manual_seed(seed)
    common = {"revision": manifest["revision"], "local_files_only": not args.allow_network}
    tokenizer = AutoTokenizer.from_pretrained(manifest["modelId"], **common)
    model, loading_info = EsmForProteinFolding.from_pretrained(
        manifest["modelId"], low_cpu_mem_usage=True, output_loading_info=True, **common
    )
    missing_keys, unexpected_keys = _validate_checkpoint_keys(loading_info)
    model.trunk.set_chunk_size(int(manifest["chunkSize"]))
    if device == "mps":
        model.esm = model.esm.half()
    model = model.eval().to(device)
    input_ids = tokenizer([sequence], return_tensors="pt", add_special_tokens=False)["input_ids"].to(device)
    with torch.no_grad():
        output = model(input_ids)
    pdb_text, plddt_scale = _normalize_plddt_b_factors(model.output_to_pdb(output)[0])
    os.makedirs(args.output, exist_ok=True)
    pdb_path = os.path.join(args.output, re.sub(r"[^A-Za-z0-9_.-]+", "_", accession) + ".pdb")
    with open(pdb_path, "w", encoding="utf-8") as fh:
        fh.write(pdb_text)
    plddt = []
    for line in pdb_text.splitlines():
        if line.startswith("ATOM  ") and line[12:16].strip() == "CA":
            try: plddt.append(float(line[60:66]))
            except ValueError: pass
    metrics = {
        "schemaVersion": 1, "backend": manifest["backend"], "modelId": manifest["modelId"],
        "revision": manifest["revision"], "device": device, "torchVersion": torch.__version__,
        "seed": seed, "checkpointMissingKeys": sorted(missing_keys),
        "checkpointAllowedMissingReason": "ESM contact-prediction head is not called by the ESMFold forward path",
        "checkpointUnexpectedKeys": sorted(unexpected_keys),
        "sequenceLength": len(sequence),
        "sequenceSha256": "sha256:" + hashlib.sha256(sequence.encode()).hexdigest(),
        "chunkSize": manifest["chunkSize"], "durationSeconds": round(time.monotonic() - started, 3),
        "meanPlddt": sum(plddt) / len(plddt) if plddt else None,
        "minPlddt": min(plddt) if plddt else None, "maxPlddt": max(plddt) if plddt else None,
        "pdbConfidenceScaleApplied": plddt_scale,
        "output": os.path.abspath(pdb_path),
        "outputSha256": "sha256:" + hashlib.sha256(pdb_text.encode()).hexdigest(),
        "interpretation": manifest["interpretation"],
    }
    _atomic_json(os.path.join(args.output, "prediction_metrics.json"), metrics)
    print(json.dumps({"output": pdb_path, "device": device, "meanPlddt": metrics["meanPlddt"]}))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        print(f"esmfold_hf: {exc}", file=sys.stderr)
        sys.exit(2)
