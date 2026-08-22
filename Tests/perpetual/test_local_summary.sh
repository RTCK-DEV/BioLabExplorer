#!/usr/bin/env bash
# The optional local-LLM summary must shell out correctly, stay advisory, and
# degrade to a note when ollama or the model is absent.
#
# ollama is not a dependency of this project and is usually not installed, so
# the whole chain is exercised against a stub on PATH: argument order, prompt
# delivery on stdin, model matching, report rendering, and failure handling.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PIPELINE="${ROOT}/.build/release/BioLabExplorerPipeline"

if [[ ! -x "${PIPELINE}" ]]; then
  echo "local summary tests SKIPPED (release binary missing; run: swift build -c release)"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
BIN="${WORK}/bin"
mkdir -p "${BIN}"

cat > "${WORK}/query.fasta" <<'FASTA'
>tr|SUM0001|SUM0001_TEST Uncharacterized protein OS=Test organism OX=1
MKAILVVLLGATRWEQDPNGCYSTLAKEFGVDPSTVRRWLKQGMDPKHILAGEYVTRLGN
>tr|SUM0002|SUM0002_TEST Hypothetical protein OS=Test organism OX=2
MQTIFSNDVKACGHWLPTYRENMLGADVSQKPFHIRTYWCEDNAVLGSKPMQRTYVDHAC
FASTA

make_stub() {  # $1 = model name reported by `ollama list`
  cat > "${BIN}/ollama" <<STUB
#!/bin/sh
if [ "\$1" = "list" ]; then
  printf 'NAME\tID\tSIZE\tMODIFIED\n'
  printf '$1\tabc123\t2.0 GB\t3 days ago\n'
  exit 0
fi
if [ "\$1" = "run" ]; then
  # The real client word-wraps with cursor-motion escapes even into a pipe,
  # and prints them alongside the answer. Reproduce that here so the
  # sanitiser is exercised end to end.
  for arg in "\$@"; do echo "\$arg" >> "${WORK}/run_args"; done
  shift
  while [ "\$1" != "\${1#--}" ]; do shift; done
  echo "\$1" > "${WORK}/model_arg"
  cat > "${WORK}/prompt"
  printf 'Two weakly annotated candidates were\033[4D\033[K\nwere ranked; \033[32mevidence\033[0m is thin.\n'
  exit 0
fi
echo "unexpected ollama invocation: \$*" >&2
exit 9
STUB
  chmod +x "${BIN}/ollama"
}

# --- happy path -------------------------------------------------------------
make_stub "llama3.2:latest"
rm -f "${WORK}/run_args"
RUN="${WORK}/run"
PATH="${BIN}:${PATH}" "${PIPELINE}" --input "${WORK}/query.fasta" --output "${RUN}" --max 2 \
  --summarize llama3.2 > "${WORK}/pipeline.log" 2>&1 \
  || { echo "FAIL: pipeline exited non-zero"; cat "${WORK}/pipeline.log"; exit 1; }

[[ "$(cat "${WORK}/model_arg")" == "llama3.2" ]] || {
  echo "FAIL: model argument not forwarded, got '$(cat "${WORK}/model_arg")'" >&2; exit 1; }
[[ -s "${WORK}/prompt" ]] || { echo "FAIL: no prompt reached the model on stdin" >&2; exit 1; }
grep -q "Restate only what the numbers below say" "${WORK}/prompt" || {
  echo "FAIL: prompt lost its constraint" >&2; head -5 "${WORK}/prompt"; exit 1; }
grep -q "SUM0001" "${WORK}/prompt" || {
  echo "FAIL: prompt does not describe the ranked candidates" >&2; exit 1; }
echo "local summary: the prompt reaches the model on stdin"

grep -q "Advisory Summary (not evidence)" "${RUN}/discovery-report.md" || {
  echo "FAIL: the report does not label the summary as advisory" >&2; exit 1; }
grep -q "Two weakly annotated candidates" "${RUN}/discovery-report.md" || {
  echo "FAIL: the summary text is missing from the report" >&2; exit 1; }
if LC_ALL=C grep -q $'\033' "${RUN}/discovery-report.md"; then
  echo "FAIL: terminal escape bytes reached the report" >&2; exit 1
fi
grep -q "were ranked; evidence is thin." "${RUN}/discovery-report.md" || {
  echo "FAIL: cursor motions were not applied when rendering the model output" >&2
  grep -n "weakly" "${RUN}/discovery-report.md"; exit 1; }
echo "local summary: the report renders it behind an explicit disclaimer"
echo "local summary: terminal control sequences are rendered away, not stored"

grep -q -- "--nowordwrap" "${WORK}/run_args" || {
  echo "FAIL: the client is not asked to stop word-wrapping" >&2; cat "${WORK}/run_args"; exit 1; }
echo "local summary: the client is invoked with --nowordwrap"

python3 - "${RUN}" <<'PY'
import glob, json, os, sys
run_dir = sys.argv[1]
with open(sorted(glob.glob(os.path.join(run_dir, "run-*.json")))[-1], encoding="utf-8") as handle:
    run = json.load(handle)
summary = run.get("advisorySummary")
assert summary, "run JSON carries no advisory summary"
assert summary["model"] == "llama3.2", summary["model"]
assert summary["backend"] == "ollama", summary["backend"]
assert "not evidence" in summary["disclaimer"], summary["disclaimer"]
notes = " ".join(run["notes"])
assert "was not used in any score" in notes, notes
print("local summary: run JSON records model, backend and disclaimer")
PY

# --- the summary must not touch the ranking ---------------------------------
PLAIN="${WORK}/plain"
"${PIPELINE}" --input "${WORK}/query.fasta" --output "${PLAIN}" --max 2 > /dev/null 2>&1
python3 - "${RUN}" "${PLAIN}" <<'PY'
import glob, json, os, sys

def candidates(run_dir):
    with open(sorted(glob.glob(os.path.join(run_dir, "run-*.json")))[-1], encoding="utf-8") as handle:
        run = json.load(handle)
    keys = ("noveltyScore", "confidenceScore", "machineLoadScore", "classification", "rank")
    return {c["sequence"]["id"]: {k: repr(c[k]) for k in keys} for c in run["candidates"]}

a, b = candidates(sys.argv[1]), candidates(sys.argv[2])
assert a == b, f"summarising changed the ranking:\n{a}\n{b}"

def verdict(run_dir):
    with open(os.path.join(run_dir, "discovery-validation.json"), encoding="utf-8") as handle:
        return json.dumps(json.load(handle), sort_keys=True)

assert verdict(sys.argv[1]) == verdict(sys.argv[2]), "summarising changed the validation verdict"
print("local summary: enabling it left every score and the verdict untouched")
PY

# --- model not installed ----------------------------------------------------
make_stub "mistral:latest"
MISSING_MODEL="${WORK}/missing_model"
PATH="${BIN}:${PATH}" "${PIPELINE}" --input "${WORK}/query.fasta" --output "${MISSING_MODEL}" --max 2 \
  --summarize llama3.2 > /dev/null 2>&1 \
  || { echo "FAIL: an uninstalled model must not fail the run" >&2; exit 1; }
grep -q "Local summary unavailable" "${MISSING_MODEL}/discovery-report.md" || {
  echo "FAIL: an uninstalled model must be reported" >&2; exit 1; }
grep -q "ollama pull llama3.2" "${MISSING_MODEL}/discovery-report.md" || {
  echo "FAIL: the report must say how to install the model" >&2; exit 1; }
echo "local summary: an uninstalled model degrades to an actionable note"

# --- daemon failing ---------------------------------------------------------
cat > "${BIN}/ollama" <<'STUB'
#!/bin/sh
echo "could not connect to ollama app" >&2
exit 1
STUB
chmod +x "${BIN}/ollama"
BROKEN="${WORK}/broken"
PATH="${BIN}:${PATH}" "${PIPELINE}" --input "${WORK}/query.fasta" --output "${BROKEN}" --max 2 \
  --summarize > /dev/null 2>&1 \
  || { echo "FAIL: a failing ollama must not fail the run" >&2; exit 1; }
grep -q "Local summary unavailable" "${BROKEN}/discovery-report.md" || {
  echo "FAIL: a failing daemon must be reported" >&2; exit 1; }
echo "local summary: a failing daemon degrades to a visible note"

# --- a different tag of the same model is NOT the model ----------------------
# ollama resolves a bare name to :latest, so having llama3.2:1b installed does
# not mean `ollama run llama3.2` will answer — it would start a download.
make_stub "llama3.2:1b"
WRONG_TAG="${WORK}/wrong_tag"
PATH="${BIN}:${PATH}" "${PIPELINE}" --input "${WORK}/query.fasta" --output "${WRONG_TAG}" --max 2 \
  --summarize llama3.2 > /dev/null 2>&1 \
  || { echo "FAIL: a differently tagged model must not fail the run" >&2; exit 1; }
grep -q "Model llama3.2 is not installed" "${WRONG_TAG}/discovery-report.md" || {
  echo "FAIL: llama3.2:1b must not satisfy a request for llama3.2" >&2
  grep -n "summary" "${WRONG_TAG}/discovery-report.md"; exit 1; }
echo "local summary: a different tag does not count as the requested model"

# --- ollama absent entirely -------------------------------------------------
# BIOLAB_TOOL_SEARCH_PATHS empties the package-manager prefixes the probe would
# otherwise search, so this case holds on a machine that really has ollama.
rm -f "${BIN}/ollama"
ABSENT="${WORK}/absent"
BIOLAB_TOOL_SEARCH_PATHS="" PATH="${BIN}:/usr/bin:/bin" "${PIPELINE}" --input "${WORK}/query.fasta" --output "${ABSENT}" --max 2 \
  --summarize > /dev/null 2>&1 \
  || { echo "FAIL: a missing ollama must not fail the run" >&2; exit 1; }
grep -q "Local summary unavailable" "${ABSENT}/discovery-report.md" || {
  echo "FAIL: a missing ollama must be reported" >&2; exit 1; }
python3 - "${ABSENT}" <<'PY'
import glob, json, os, sys
with open(sorted(glob.glob(os.path.join(sys.argv[1], "run-*.json")))[-1], encoding="utf-8") as handle:
    run = json.load(handle)
assert run.get("advisorySummary") is None, "no summary must be recorded when ollama is absent"
print("local summary: absent ollama leaves the run JSON clean")
PY

echo "local summary tests OK"
