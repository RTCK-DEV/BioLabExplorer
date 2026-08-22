#!/usr/bin/env bash
# End-to-end check of the optional Pfam adapter against a real HMMER install.
#
# Builds a throwaway two-family profile database with hmmbuild/hmmpress instead
# of downloading Pfam, so the whole chain — hmmscan flags, --domtblout parsing,
# report rendering, and the graceful-degradation path — is exercised for a few
# kilobytes. Skips cleanly when HMMER is not installed.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

for tool in hmmbuild hmmpress hmmscan; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    echo "pfam adapter tests SKIPPED (${tool} not installed)"
    exit 0
  fi
done

PIPELINE="${ROOT}/.build/release/BioLabExplorerPipeline"
if [[ ! -x "${PIPELINE}" ]]; then
  echo "pfam adapter tests SKIPPED (release binary missing; run: swift build -c release)"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# Two aligned members of a synthetic family, plus gaps so hmmbuild has columns
# to model. The consensus is what the query below is built from.
cat > "${WORK}/family.afa" <<'FASTA'
>member_1
MKAILVVLLGATRWEQDPNGCYSTLAKEFGVDPSTVRRWLKQGMDPKHILA-GEYVTRLGK
>member_2
MKAILVVLMGATRWEQDPNGCYSTLAKEYGVDPSSVRRWLKQGMDPKHILA-GEYVTRLGR
>member_3
MKAVLVVLLGATRWEQEPNGCYSTLAKEFGVDPSTVRRWLKQGMDPKHVLAGGEYVTRLGK
>member_4
MKAILVILLGATRWEQDPNGCYATLAKEFGVDPSTVRRWLKQGMDPKHILA-GEYVTRIGK
FASTA

hmmbuild -n TESTFAM --amino "${WORK}/testfam.hmm" "${WORK}/family.afa" > "${WORK}/hmmbuild.log" 2>&1
hmmpress "${WORK}/testfam.hmm" > "${WORK}/hmmpress.log" 2>&1

for suffix in h3f h3i h3m h3p; do
  [[ -f "${WORK}/testfam.hmm.${suffix}" ]] || { echo "FAIL: hmmpress did not write .${suffix}" >&2; exit 1; }
done

# One clear family member, one sequence that shares no motif with it.
cat > "${WORK}/query.fasta" <<'FASTA'
>tr|FAMHIT|FAMHIT_TEST Uncharacterized protein OS=Test organism OX=1
MKAILVVLLGATRWEQDPNGCYSTLAKEFGVDPSTVRRWLKQGMDPKHILAGEYVTRLGK
>tr|NOHIT|NOHIT_TEST Uncharacterized protein OS=Test organism OX=2
PPPPQQQQNNNNGGGGSSSSPPPPQQQQNNNNGGGGSSSSPPPPQQQQNNNNGGGGSSSS
FASTA

RUN="${WORK}/run"
"${PIPELINE}" --input "${WORK}/query.fasta" --output "${RUN}" --max 2 \
  --pfam-db "${WORK}/testfam.hmm" --pfam-evalue 10 > "${WORK}/pipeline.log" 2>&1 \
  || { echo "FAIL: pipeline exited non-zero"; cat "${WORK}/pipeline.log"; exit 1; }

REPORT="${RUN}/discovery-report.md"
[[ -f "${REPORT}" ]] || { echo "FAIL: no discovery report written" >&2; exit 1; }

grep -q "Pfam domains via hmmscan" "${REPORT}" || {
  echo "FAIL: report does not record the Pfam run" >&2; cat "${REPORT}" | head -40; exit 1; }
grep -q "TESTFAM" "${REPORT}" || {
  echo "FAIL: expected the TESTFAM domain in the report" >&2; grep -n "Pfam" "${REPORT}"; exit 1; }
grep -q "advisory, not scored" "${REPORT}" || {
  echo "FAIL: domain table is not labelled advisory" >&2; exit 1; }
echo "pfam: report renders the domain table"

python3 - "${RUN}" <<'PY'
import glob, json, os, sys
run_dir = sys.argv[1]
paths = sorted(glob.glob(os.path.join(run_dir, "run-*.json")))
assert paths, "no run JSON was written"
with open(paths[-1], encoding="utf-8") as handle:
    run = json.load(handle)

by_id = {c["sequence"]["id"]: c for c in run["candidates"]}
assert "FAMHIT" in by_id and "NOHIT" in by_id, f"unexpected candidates: {list(by_id)}"

hit = by_id["FAMHIT"]
assert hit["domains"], "the family member should carry at least one domain hit"
domain = hit["domains"][0]
assert domain["name"] == "TESTFAM", domain["name"]
assert domain["queryID"] == "FAMHIT", domain["queryID"]
assert domain["bitScore"] > 0, domain["bitScore"]
assert domain["independentEValue"] < 10, domain["independentEValue"]
assert 0 < domain["modelCoverage"] <= 1, domain["modelCoverage"]
assert domain["alignmentFrom"] >= 1 and domain["alignmentTo"] > domain["alignmentFrom"]

assert not by_id["NOHIT"]["domains"], "the unrelated sequence must not gain a domain"

kinds = [e["kind"] for e in hit["evidence"]]
assert "domain" in kinds, kinds
for item in hit["evidence"]:
    if item["kind"] == "domain":
        assert item["weight"] == 0, "domain evidence must be zero-weighted"
        assert "does not change the ranking scores" in item["note"]

notes = " ".join(run["notes"])
assert "Pfam domains via hmmscan" in notes, notes
assert "does not change any score" in notes, notes
print("pfam: run JSON carries auditable domain evidence")
PY

# Scores must be identical with and without the adapter: domains are advisory.
PLAIN="${WORK}/plain"
"${PIPELINE}" --input "${WORK}/query.fasta" --output "${PLAIN}" --max 2 > /dev/null 2>&1
python3 - "${RUN}" "${PLAIN}" <<'PY'
import glob, json, os, sys

def load(run_dir):
    path = sorted(glob.glob(os.path.join(run_dir, "run-*.json")))[-1]
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)

annotated, plain = load(sys.argv[1]), load(sys.argv[2])
keys = ("noveltyScore", "confidenceScore", "machineLoadScore", "classification", "rank")
a = {c["sequence"]["id"]: {k: c[k] for k in keys} for c in annotated["candidates"]}
b = {c["sequence"]["id"]: {k: c[k] for k in keys} for c in plain["candidates"]}
assert a == b, f"domain annotation changed the ranking:\n{a}\n{b}"
assert all(not c["domains"] for c in plain["candidates"]), "plain run must have no domains"
print("pfam: enabling the adapter left every score untouched")
PY

# A missing database must degrade to a note, not fail the run.
MISSING="${WORK}/missing"
"${PIPELINE}" --input "${WORK}/query.fasta" --output "${MISSING}" --max 2 \
  --pfam-db "${WORK}/does-not-exist.hmm" > "${WORK}/missing.log" 2>&1 \
  || { echo "FAIL: a missing Pfam database must not fail the run" >&2; cat "${WORK}/missing.log"; exit 1; }
grep -q "Pfam domain annotation unavailable" "${MISSING}/discovery-report.md" || {
  echo "FAIL: a missing database must be reported in the run notes" >&2; exit 1; }
echo "pfam: a missing database degrades to a visible note"

# An unindexed database must say so instead of failing obscurely.
UNPRESSED="${WORK}/unpressed"
mkdir -p "${WORK}/bare"
cp "${WORK}/testfam.hmm" "${WORK}/bare/bare.hmm"
"${PIPELINE}" --input "${WORK}/query.fasta" --output "${UNPRESSED}" --max 2 \
  --pfam-db "${WORK}/bare/bare.hmm" > /dev/null 2>&1 \
  || { echo "FAIL: an unindexed database must not fail the run" >&2; exit 1; }
grep -q "hmmpress" "${UNPRESSED}/discovery-report.md" || {
  echo "FAIL: an unindexed database must tell the user to run hmmpress" >&2; exit 1; }
echo "pfam: an unindexed database points at hmmpress"

echo "pfam adapter tests OK"
