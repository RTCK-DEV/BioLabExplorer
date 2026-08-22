#!/usr/bin/env bash
# The ranking must be bit-for-bit reproducible ACROSS PROCESSES.
#
# Swift seeds its hashing per process, so any float accumulated by iterating a
# Dictionary or Set drifts by an ULP between runs. That is exactly how
# confidenceScore once wobbled: shannonEntropy summed over `counts.values`.
# A single-process test cannot see this, so this test compares separate runs.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PIPELINE="${ROOT}/.build/release/BioLabExplorerPipeline"
RUNS="${DETERMINISM_RUNS:-6}"

if [[ ! -x "${PIPELINE}" ]]; then
  echo "determinism tests SKIPPED (release binary missing; run: swift build -c release)"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# Deliberately varied residue composition: entropy, low-complexity and motif
# scores all need enough spread to expose an unstable summation.
cat > "${WORK}/query.fasta" <<'FASTA'
>tr|DET0001|DET0001_TEST Uncharacterized protein OS=Test organism OX=1
MKAILVVLLGATRWEQDPNGCYSTLAKEFGVDPSTVRRWLKQGMDPKHILAGEYVTRLGNCCHHEEDDKKRRWWYYFF
>tr|DET0002|DET0002_TEST Hypothetical protein OS=Test organism OX=2
MQTIFSNDVKACGHWLPTYRENMLGADVSQKPFHIRTYWCEDNAVLGSKPMQRTYVDHACFGWLNEIPSQRTYVMDKA
>tr|DET0003|DET0003_TEST Putative transporter OS=Test organism OX=3
PPPPQQQQNNNNGGGGSSSSPPPPQQQQNNNNGGGGSSSSPPPPQQQQNNNNGGGGSSSSAAAALLLLIIIIVVVV
>tr|DET0004|DET0004_TEST Uncharacterized protein OS=Test organism OX=4
MCCHCCGHCCDGCCHGCCWACCYGCCFGCCMGCCPGCCVGCCLGCCIGCCTGCCSGCCNGCCQGCCKGCCRGCCEG
FASTA

for index in $(seq 1 "${RUNS}"); do
  "${PIPELINE}" --input "${WORK}/query.fasta" --output "${WORK}/run_${index}" --max 4 \
    > /dev/null 2>&1 || { echo "FAIL: pipeline run ${index} exited non-zero" >&2; exit 1; }
done

python3 - "${WORK}" "${RUNS}" <<'PY'
import glob, json, os, sys

work, runs = sys.argv[1], int(sys.argv[2])

def signature(run_dir):
    paths = sorted(glob.glob(os.path.join(run_dir, "run-*.json")))
    assert paths, f"no run JSON in {run_dir}"
    with open(paths[-1], encoding="utf-8") as handle:
        run = json.load(handle)
    # id and startedAt are expected to differ; everything derived from the
    # input must not. repr() keeps full float precision, so a one-ULP drift
    # still fails.
    return json.dumps(
        [
            {
                "id": c["sequence"]["id"],
                "rank": c["rank"],
                "classification": c["classification"],
                "novelty": repr(c["noveltyScore"]),
                "confidence": repr(c["confidenceScore"]),
                "machineLoad": repr(c["machineLoadScore"]),
                "features": {k: repr(v) for k, v in c["features"].items() if not isinstance(v, list)},
                "motifs": [(m["name"], repr(m["strength"])) for m in c["features"]["motifHits"]],
                "evidence": [(e["kind"], e["title"], e["value"], repr(e["weight"])) for e in c["evidence"]],
            }
            for c in run["candidates"]
        ],
        sort_keys=True,
    )

signatures = {signature(os.path.join(work, f"run_{i}")) for i in range(1, runs + 1)}
if len(signatures) != 1:
    print(f"FAIL: {len(signatures)} distinct results across {runs} processes", file=sys.stderr)
    for item in sorted(signatures):
        print(item[:600], file=sys.stderr)
    sys.exit(1)
print(f"determinism: {runs} separate processes produced bit-identical rankings")

# Markdown must be stable too, apart from the run timestamp.
def report(run_dir):
    with open(os.path.join(run_dir, "discovery-report.md"), encoding="utf-8") as handle:
        return [line for line in handle if not line.startswith("- Started:")]

reports = {tuple(report(os.path.join(work, f"run_{i}"))) for i in range(1, runs + 1)}
assert len(reports) == 1, f"{len(reports)} distinct Markdown reports across {runs} processes"
print("determinism: the Markdown report is stable across processes")

# Validation verdicts must be stable.
def validation(run_dir):
    with open(os.path.join(run_dir, "discovery-validation.json"), encoding="utf-8") as handle:
        return json.dumps(json.load(handle), sort_keys=True)

verdicts = {validation(os.path.join(work, f"run_{i}")) for i in range(1, runs + 1)}
assert len(verdicts) == 1, f"{len(verdicts)} distinct validation verdicts across {runs} processes"
print("determinism: the validation verdict is stable across processes")
PY

echo "determinism tests OK"
