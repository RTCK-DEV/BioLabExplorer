#!/usr/bin/env bash
# Test double for BioLabExplorerPipeline: writes fixture outputs to --output.
set -euo pipefail
OUT=""
while [[ $# -gt 0 ]]; do case "$1" in --output) OUT="$2"; shift 2 ;; *) shift ;; esac; done
mkdir -p "$OUT"
cat > "$OUT/run-2026-01-01T00-00-00-000Z.json" <<'JSON'
{"candidates":[{"id":"TOP","sequence":{"id":"TESTACC1","sequence":"MKTAYIAKQR"},"noveltyScore":0.9,"classification":"Remote PBP"}]}
JSON
cat > "$OUT/discovery-validation.json" <<'JSON'
{"passed":true,"qualifyingCandidateIDs":["TESTACC1"]}
JSON
