#!/usr/bin/env python3
"""Opt-in, cursor-paged UniProt fetcher. Refills state/inbox with ONE FASTA page.

Envelope: never touches the network unless ALLOW_NETWORK=1 AND the URL host equals
the configured uniprotHost. For tests, set UNIPROT_FIXTURE_DIR to serve canned pages
(page-0.fasta [+ page-0.next], page-1.fasta, ...) so the suite never hits UniProt.
"""
import argparse
import hashlib
import json
import os
import sys
import tempfile
import time
import urllib.parse
import urllib.error
import urllib.request
from datetime import datetime, timezone


EXIT_CONTRACT = 3
EXIT_TEMPFAIL = 75


class ContractError(RuntimeError):
    """Approved-scope or response contract violation; retrying unchanged is unsafe."""


class TransientFetchError(RuntimeError):
    """Temporary transport/server failure; the cursor must remain unchanged."""


def _utc():
    return datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")


def _load_required(path):
    with open(path, encoding="utf-8") as fh:
        value = json.load(fh)
    if not isinstance(value, dict):
        raise ValueError(f"expected JSON object: {path}")
    return value


def _load_optional(path, default):
    if not os.path.exists(path):
        return default
    return _load_required(path)


def build_initial_url(host, query, page_size):
    qs = urllib.parse.urlencode({"query": query, "format": "fasta", "size": str(page_size)})
    return f"https://{host}/uniprotkb/search?{qs}"


def _host_of(url):
    return urllib.parse.urlparse(url).hostname or ""


def _query_digest(path):
    with open(path, "rb") as source:
        return "sha256:" + hashlib.sha256(source.read()).hexdigest()


def _validate_search_url(url, host_allow, approved_query, page_size):
    """Bind an opaque cursor to the exact approved UniProt search envelope."""
    try:
        parsed = urllib.parse.urlparse(url)
        port = parsed.port
    except ValueError as error:
        raise ContractError(f"invalid cursor URL: {error}") from error
    if (
        parsed.scheme != "https"
        or parsed.hostname != host_allow
        or port not in (None, 443)
        or parsed.username is not None
        or parsed.password is not None
        or parsed.path != "/uniprotkb/search"
        or parsed.fragment
    ):
        raise ContractError("cursor URL is outside the approved UniProt HTTPS search endpoint")
    params = urllib.parse.parse_qs(parsed.query, keep_blank_values=True)
    if set(params) - {"query", "format", "size", "cursor"}:
        raise ContractError("cursor URL contains unapproved query parameters")
    if params.get("query") != [approved_query] or params.get("format") != ["fasta"]:
        raise ContractError("cursor URL query/format does not match the approved query")
    try:
        sizes = params.get("size", [])
        size = int(sizes[0]) if len(sizes) == 1 else 0
    except ValueError as error:
        raise ContractError("cursor URL has an invalid page size") from error
    if not 1 <= size <= page_size:
        raise ContractError(f"cursor URL page size {size} exceeds approved limit {page_size}")
    if len(params.get("cursor", [])) > 1:
        raise ContractError("cursor URL contains multiple cursor values")


def _parse_next(link_header):
    if not link_header:
        return None
    for part in link_header.split(","):
        seg = part.split(";")
        if len(seg) >= 2 and any('rel="next"' in item for item in seg[1:]):
            return seg[0].strip().strip("<>")
    return None


def fetch_page(url, host_allow, rate_limit):
    """Return (body_bytes, next_url_or_None). Fixture transport for tests; real network is opt-in."""
    fx = os.environ.get("UNIPROT_FIXTURE_DIR")
    if fx:
        idx_path = os.path.join(fx, ".idx")
        i = int(_load_optional(idx_path, {"i": 0}).get("i", 0))
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
        raise ContractError("network not allowed (set ALLOW_NETWORK=1) and no UNIPROT_FIXTURE_DIR")
    if _host_of(url) != host_allow:
        raise ContractError(f"host '{_host_of(url)}' not in allowlist ('{host_allow}')")
    req = urllib.request.Request(url, headers={"User-Agent": "BioLabExplorer/1.0 (research triage; local)"})
    last_error = None
    for attempt in range(3):
        if rate_limit > 0:
            time.sleep(rate_limit)
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                body = resp.read()
                nxt = _parse_next(resp.headers.get("Link"))
            break
        except urllib.error.HTTPError as exc:
            last_error = exc
            if exc.code not in (408, 429, 500, 502, 503, 504):
                raise ContractError(f"UniProt rejected the approved request with HTTP {exc.code}") from exc
            if attempt == 2:
                raise TransientFetchError(f"UniProt temporarily unavailable: HTTP {exc.code}") from exc
        except urllib.error.URLError as exc:
            last_error = exc
            if attempt == 2:
                raise TransientFetchError(f"UniProt transport failure: {exc.reason}") from exc
        time.sleep(2 ** attempt)
    else:
        raise TransientFetchError(f"UniProt fetch failed: {last_error}")
    if nxt and _host_of(nxt) != host_allow:
        raise ContractError(f"next-page host '{_host_of(nxt)}' is outside allowlist")
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

    cfg = _load_required(a.config)
    host = cfg.get("uniprotHost", "rest.uniprot.org")
    if host != "rest.uniprot.org":
        raise ContractError(f"configured host is not approved: {host}")
    rate = float(cfg.get("fetchRateLimitSeconds", 1))
    if rate < 1 and not os.environ.get("UNIPROT_FIXTURE_DIR"):
        raise ContractError("production rate limit must be >= 1 second")

    qr = _load_required(a.query_rotation)
    if qr.get("schemaVersion") != 1:
        raise ContractError("unsupported query rotation schemaVersion")
    queries = qr.get("queries", [])
    if not queries:
        raise ContractError("no queries in query_rotation.json")

    approved_digest = _query_digest(a.query_rotation)

    rot = _load_optional(a.rotation, {})
    qidx = int(rot.get("queryIndex", 0)) % len(queries)
    cursor = rot.get("nextCursor")
    expected_query_id = str(queries[qidx].get("id", ""))
    scope_bound = (
        rot.get("approvedQueryDigest") == approved_digest
        and rot.get("queryId") == expected_query_id
    )
    if not scope_bound:
        if cursor or "approvedQueryDigest" in rot or "queryId" in rot:
            print("fetch_uniprot: discarding cursor not bound to the approved query digest", file=sys.stderr)
        qidx = 0
        cursor = None
    q = queries[qidx]
    if not isinstance(q.get("id"), str) or not q["id"] or not isinstance(q.get("uniprotQuery"), str) or not q["uniprotQuery"]:
        raise ContractError("query entries require non-empty id and uniprotQuery strings")
    page_size = min(int(q.get("pageSize", cfg.get("fetchPageSize", 200))), 200)
    if page_size <= 0:
        raise ContractError("pageSize must be in 1...200")
    url = cursor if cursor else build_initial_url(host, q["uniprotQuery"], page_size)
    _validate_search_url(url, host, q["uniprotQuery"], page_size)

    body, nxt = fetch_page(url, host, rate)
    if nxt:
        _validate_search_url(nxt, host, q["uniprotQuery"], page_size)
    if not body.lstrip().startswith(b">"):
        raise ContractError("response is not FASTA")
    record_count = sum(1 for line in body.splitlines() if line.startswith(b">"))
    if record_count == 0 or record_count > page_size:
        raise ContractError(f"invalid record count {record_count} (limit {page_size})")

    os.makedirs(a.inbox, exist_ok=True)
    fd, out = tempfile.mkstemp(prefix=f"uniprot_{q['id']}_{_utc()}_", suffix=".fasta", dir=a.inbox)
    with os.fdopen(fd, "wb") as fh:
        fh.write(body)

    if nxt:
        next_index = qidx
        rot["nextCursor"] = nxt
    else:
        next_index = (qidx + 1) % len(queries)
        rot["nextCursor"] = None
    rot["queryIndex"] = next_index
    rot["queryId"] = queries[next_index]["id"]
    rot["approvedQueryDigest"] = approved_digest
    rot["schemaVersion"] = 1
    _atomic_write_json(a.rotation, rot)
    print(out)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except ContractError as error:
        print(f"fetch_uniprot: contract violation: {error}", file=sys.stderr)
        sys.exit(EXIT_CONTRACT)
    except TransientFetchError as error:
        print(f"fetch_uniprot: temporary failure: {error}", file=sys.stderr)
        sys.exit(EXIT_TEMPFAIL)
