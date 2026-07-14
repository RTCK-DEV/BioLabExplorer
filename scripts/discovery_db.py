#!/usr/bin/env python3
"""SQLite seen-set ledger for the perpetual worker (stdlib-only, crash-consistent).

Records EVERY processed input sequence (verdict 'screened'), upgrading those that
meet the actionable threshold (verdict 'actionable', from DiscoveryValidator's
qualifyingCandidateIDs). Identity = canonical sequence sha256 (accession = provenance).
Dedup + crash-consistency come from the PRIMARY KEY and one transaction per cycle.
DISCOVERIES.md is regenerated from the DB. Fail-closed on contract violations.
"""
import argparse
import glob
import hashlib
import json
import os
import sqlite3
import sys
import tempfile
from datetime import datetime, timezone

SCHEMA_VERSION = 1


def seq_sha256(seq):
    return hashlib.sha256(seq.strip().upper().encode("utf-8")).hexdigest()


def _utc_now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def connect(db_path):
    os.makedirs(os.path.dirname(db_path) or ".", exist_ok=True)
    conn = sqlite3.connect(db_path)
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=FULL")
    conn.execute(
        """CREATE TABLE IF NOT EXISTS processed (
            seq_sha256 TEXT PRIMARY KEY,
            accession TEXT NOT NULL,
            verdict TEXT NOT NULL CHECK (verdict IN ('actionable','screened')),
            score REAL,
            classification TEXT,
            first_seen_cycle INTEGER NOT NULL,
            run_id TEXT NOT NULL,
            ts TEXT NOT NULL,
            schema_version INTEGER NOT NULL
        )"""
    )
    conn.execute("CREATE INDEX IF NOT EXISTS idx_accession ON processed(accession)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_verdict ON processed(verdict)")
    return conn


def accession_from_header(header):
    # Mirror Swift FASTAParser.identifier: first space-token, then the middle
    # pipe field of a db|ACCESSION|ENTRY header. Omit empty subsequences to
    # match Swift's split(...) defaults.
    tokens = [t for t in header.split(" ") if t]  # space-only split (matches Swift split(sep:" "))
    first_token = tokens[0] if tokens else header
    pipe_parts = [p for p in first_token.split("|") if p]   # omit empties like Swift split(sep:"|")
    if len(pipe_parts) >= 2:
        return pipe_parts[1]
    return first_token


def parse_fasta(path):
    acc, seq = None, []
    with open(path, "r", encoding="utf-8") as fh:
        for line in fh:
            if line.startswith(">"):
                if acc is not None:
                    yield acc, "".join(seq)
                header = line[1:].strip()
                acc = accession_from_header(header) if header else ""
                seq = []
            else:
                seq.append(line.strip())
    if acc is not None:
        yield acc, "".join(seq)


def _require(cond, msg):
    if not cond:
        raise ValueError(f"discovery_db: {msg}")


def load_run(run_dir):
    matches = sorted(glob.glob(os.path.join(run_dir, "run-*.json")))
    _require(matches, f"no run-*.json in {run_dir}")
    with open(matches[-1], "r", encoding="utf-8") as fh:
        run = json.load(fh)  # malformed -> raises -> fail closed
    vpath = os.path.join(run_dir, "discovery-validation.json")
    _require(os.path.exists(vpath), f"missing {vpath}")
    with open(vpath, "r", encoding="utf-8") as fh:
        validation = json.load(fh)
    _require("qualifyingCandidateIDs" in validation, "validation missing qualifyingCandidateIDs")
    qualifying = set(validation["qualifyingCandidateIDs"])
    scores = {}
    for cand in run.get("candidates", []):
        # accession is sequence.id, NOT the top-level candidate id
        acc = cand.get("sequence", {}).get("id")
        if acc is not None:
            scores[acc] = (cand.get("noveltyScore"), cand.get("classification"))
    return qualifying, scores


def record(input_fasta, run_dir, db_path, discoveries_md, cycle, run_id):
    qualifying, scores = load_run(run_dir)
    ts = _utc_now()
    conn = connect(db_path)
    new_actionable = 0
    try:
        with conn:  # single transaction: commit-or-rollback atomically
            for acc, seq in parse_fasta(input_fasta):
                if not seq:
                    continue
                sha = seq_sha256(seq)
                is_actionable = acc in qualifying
                score, classification = scores.get(acc, (None, None))
                cur = conn.execute(
                    "INSERT OR IGNORE INTO processed"
                    "(seq_sha256,accession,verdict,score,classification,"
                    "first_seen_cycle,run_id,ts,schema_version)"
                    " VALUES (?,?,?,?,?,?,?,?,?)",
                    (sha, acc, "actionable" if is_actionable else "screened",
                     score, classification, cycle, run_id, ts, SCHEMA_VERSION),
                )
                if cur.rowcount == 1 and is_actionable:
                    new_actionable += 1
    finally:
        conn.close()
    regenerate_discoveries_md(db_path, discoveries_md)
    return new_actionable


def _fmt_score(score):
    """Round to 3 decimals so DISCOVERIES.md agrees with the dashboard table;
    None (no score recorded) renders as an em dash. Display-only -- the DB
    value itself is left untouched."""
    return f"{score:.3f}" if score is not None else "—"


def regenerate_discoveries_md(db_path, discoveries_md):
    conn = connect(db_path)
    try:
        rows = conn.execute(
            "SELECT first_seen_cycle,accession,score,classification,ts,run_id"
            " FROM processed WHERE verdict='actionable' ORDER BY first_seen_cycle,accession,seq_sha256"
        ).fetchall()
    finally:
        conn.close()
    target_dir = os.path.dirname(discoveries_md) or "."
    os.makedirs(target_dir, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=target_dir, suffix=".tmp")
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fh.write("# Discoveries (actionable, de-duplicated)\n\n")
        fh.write("> Local-only triage output. Unvalidated in-silico predictions; "
                 "not for external use, publication, or wet-lab handoff without review.\n\n")
        fh.write("| cycle | accession | score | classification | when | run |\n")
        fh.write("|---|---|---|---|---|---|\n")
        for c, acc, score, cls, ts, run_id in rows:
            fh.write(f"| {c} | {acc} | {_fmt_score(score)} | {cls} | {ts} | {run_id} |\n")
    os.replace(tmp, discoveries_md)


def export_new_actionable(db_path, cycle, out_path):
    """Write [{"accession","sequence"}] for rows first recorded actionable THIS cycle.

    Known limitation (deliberate, see brief): the ledger has no sequence column,
    so sequence is always "" (seq_len 0). This does not gate folding today since
    no backend is installed by default; a future schema extension can carry the
    sequence if/when that matters.
    """
    conn = connect(db_path)
    try:
        rows = conn.execute(
            "SELECT accession FROM processed WHERE verdict='actionable' AND first_seen_cycle=?",
            (cycle,),
        ).fetchall()
    finally:
        conn.close()
    candidates = [{"accession": acc, "sequence": ""} for (acc,) in rows]
    target_dir = os.path.dirname(out_path) or "."
    os.makedirs(target_dir, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=target_dir, suffix=".tmp")
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(candidates, fh)
    os.replace(tmp, out_path)
    return len(candidates)


def cmd_record(a):
    print(record(a.input, a.run_dir, a.db, a.discoveries, a.cycle, a.run_id))
    return 0


def cmd_count(a):
    conn = connect(a.db)
    try:
        print(conn.execute("SELECT COUNT(*) FROM processed WHERE verdict='actionable'").fetchone()[0])
    finally:
        conn.close()
    return 0


def cmd_export_new_actionable(a):
    print(export_new_actionable(a.db, a.cycle, a.out))
    return 0


def main(argv=None):
    p = argparse.ArgumentParser(prog="discovery_db.py")
    sub = p.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("record")
    for flag in ("--input", "--run-dir", "--db", "--discoveries", "--run-id"):
        r.add_argument(flag, required=True)
    r.add_argument("--cycle", type=int, required=True)
    r.set_defaults(func=cmd_record)
    c = sub.add_parser("count-actionable")
    c.add_argument("--db", required=True)
    c.set_defaults(func=cmd_count)
    e = sub.add_parser("export-new-actionable")
    e.add_argument("--db", required=True)
    e.add_argument("--cycle", type=int, required=True)
    e.add_argument("--out", required=True)
    e.set_defaults(func=cmd_export_new_actionable)
    a = p.parse_args(argv)
    # argparse maps --run-dir -> a.run_dir, --run-id -> a.run_id
    return a.func(a)


if __name__ == "__main__":
    sys.exit(main())
