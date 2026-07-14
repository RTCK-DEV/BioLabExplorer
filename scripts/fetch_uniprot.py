#!/usr/bin/env python3
"""Opt-in, cursor-paged UniProt fetcher. Refills state/inbox with ONE FASTA page.

Envelope: never touches the network unless ALLOW_NETWORK=1 AND the URL host equals
the configured uniprotHost. For tests, set UNIPROT_FIXTURE_DIR to serve canned pages
(page-0.fasta [+ page-0.next], page-1.fasta, ...) so the suite never hits UniProt.
"""
import argparse
import json
import os
import sys
import tempfile
import time
import urllib.parse
import urllib.request
from datetime import datetime, timezone


def _utc():
    return datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")


def _load(path, default):
    try:
        with open(path) as fh:
            return json.load(fh)
    except Exception:
        return default


def build_initial_url(host, query, page_size):
    qs = urllib.parse.urlencode({"query": query, "format": "fasta", "size": str(page_size)})
    return f"https://{host}/uniprotkb/search?{qs}"


def _host_of(url):
    return urllib.parse.urlparse(url).hostname or ""


def _parse_next(link_header):
    if not link_header:
        return None
    for part in link_header.split(","):
        seg = part.split(";")
        if len(seg) >= 2 and 'rel="next"' in seg[1]:
            return seg[0].strip().strip("<>")
    return None


def fetch_page(url, host_allow, rate_limit):
    """Return (body_bytes, next_url_or_None). Fixture transport for tests; real network is opt-in."""
    fx = os.environ.get("UNIPROT_FIXTURE_DIR")
    if fx:
        idx_path = os.path.join(fx, ".idx")
        i = int(_load(idx_path, {"i": 0}).get("i", 0))
        with open(os.path.join(fx, f"page-{i}.fasta"), "rb") as fh:
            body = fh.read()
        nxt_path = os.path.join(fx, f"page-{i}.next")
        nxt = None
        if os.path.exists(nxt_path):
            with open(nxt_path) as fh:
                nxt = fh.read().strip()
        with open(idx_path, "w") as fh:
            json.dump({"i": i + 1}, fh)
        return body, (nxt or None)
    if os.environ.get("ALLOW_NETWORK") != "1":
        raise SystemExit("fetch_uniprot: network not allowed (set ALLOW_NETWORK=1) and no UNIPROT_FIXTURE_DIR")
    if _host_of(url) != host_allow:
        raise SystemExit(f"fetch_uniprot: host '{_host_of(url)}' not in allowlist ('{host_allow}')")
    if rate_limit > 0:
        time.sleep(rate_limit)
    req = urllib.request.Request(url, headers={"User-Agent": "BioLabExplorer/1.0 (research triage; local)"})
    with urllib.request.urlopen(req, timeout=60) as resp:
        body = resp.read()
        nxt = _parse_next(resp.headers.get("Link"))
    if nxt and _host_of(nxt) != host_allow:
        nxt = None  # never follow an off-allowlist next link
    return body, nxt


def _atomic_write_json(path, data):
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".", suffix=".tmp")
    with os.fdopen(fd, "w") as fh:
        json.dump(data, fh)
    os.replace(tmp, path)


def main(argv=None):
    ap = argparse.ArgumentParser(prog="fetch_uniprot.py")
    for flag in ("--config", "--query-rotation", "--rotation", "--inbox"):
        ap.add_argument(flag, required=True)
    a = ap.parse_args(argv)

    cfg = _load(a.config, {})
    host = cfg.get("uniprotHost", "rest.uniprot.org")
    page_size = int(cfg.get("fetchPageSize", 200))
    rate = float(cfg.get("fetchRateLimitSeconds", 1))

    qr = _load(a.query_rotation, {"queries": []})
    queries = qr.get("queries", [])
    if not queries:
        raise SystemExit("fetch_uniprot: no queries in query_rotation.json")

    rot = _load(a.rotation, {})
    qidx = int(rot.get("queryIndex", 0)) % len(queries)
    cursor = rot.get("nextCursor")
    q = queries[qidx]
    url = cursor if cursor else build_initial_url(host, q["uniprotQuery"], page_size)

    body, nxt = fetch_page(url, host, rate)

    os.makedirs(a.inbox, exist_ok=True)
    fd, out = tempfile.mkstemp(prefix=f"uniprot_{q['id']}_{_utc()}_", suffix=".fasta", dir=a.inbox)
    with os.fdopen(fd, "wb") as fh:
        fh.write(body)

    if nxt:
        rot["queryIndex"] = qidx
        rot["nextCursor"] = nxt
    else:
        rot["queryIndex"] = (qidx + 1) % len(queries)
        rot["nextCursor"] = None
    rot["schemaVersion"] = 1
    _atomic_write_json(a.rotation, rot)
    print(out)
    return 0


if __name__ == "__main__":
    sys.exit(main())
