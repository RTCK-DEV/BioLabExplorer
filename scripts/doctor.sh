#!/usr/bin/env bash
# One command that tells you whether this machine can run BioLabExplorer,
# and gives you the exact command for anything that is missing.
#
#   scripts/doctor.sh          check and report
#   scripts/doctor.sh --build  also build, then run the bundled example
#
# Offline. Touches nothing, installs nothing, and never needs sudo.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}" || { echo "cannot enter ${ROOT}" >&2; exit 1; }

BUILD=0
[[ "${1:-}" == "--build" ]] && BUILD=1

if [[ -t 1 ]]; then
  GREEN=$'\033[32m'; RED=$'\033[31m'; YELLOW=$'\033[33m'; DIM=$'\033[2m'; BOLD=$'\033[1m'; OFF=$'\033[0m'
else
  GREEN=""; RED=""; YELLOW=""; DIM=""; BOLD=""; OFF=""
fi

BLOCKERS=0

ok()      { printf '  %s✓%s %s\n' "${GREEN}" "${OFF}" "$1"; }
warn()    { printf '  %s—%s %s\n' "${YELLOW}" "${OFF}" "$1"; }
bad()     { printf '  %s✗%s %s\n' "${RED}" "${OFF}" "$1"; BLOCKERS=$((BLOCKERS + 1)); }
hint()    { printf '      %s%s%s\n' "${DIM}" "$1" "${OFF}"; }
heading() { printf '\n%s%s%s\n' "${BOLD}" "$1" "${OFF}"; }

printf '%sBioLabExplorer — machine check%s\n' "${BOLD}" "${OFF}"
printf '%s%s%s\n' "${DIM}" "$(sw_vers -productName 2>/dev/null || uname -s) $(sw_vers -productVersion 2>/dev/null || uname -r) on $(uname -m)" "${OFF}"

# A non-macOS user should get the answer in one screen, not after reading a
# checklist of things that cannot help them.
if [[ "$(uname -s)" != "Darwin" ]]; then
  printf '\n%sThis project does not run on %s.%s\n\n' "${RED}" "$(uname -s)" "${OFF}"
  cat <<'WHY'
  BioLabExplorer is macOS 15 or later, and not by accident:

    - the app is SwiftUI, which exists only on Apple platforms
    - the scoring engine is Swift, built against the macOS SDK
    - the optional structure chain targets Apple Silicon (Metal / MPS)

  There is no Linux or Windows build, and porting it would mean replacing the
  interface layer entirely. Nothing you install will change this check.

  If you only want the ranking algorithm, the scoring lives in
  Sources/BioLabExplorerCore/ and depends on Foundation alone — readable, and
  portable in principle, but not built or tested anywhere but macOS.
WHY
  exit 1
fi

# ---------------------------------------------------------------- required --
heading "Required"

major="$(sw_vers -productVersion | cut -d. -f1)"
if [[ "${major}" -ge 15 ]]; then
  ok "macOS ${major} (15 or later needed)"
else
  bad "macOS ${major}; 15 or later is needed"
  hint "Update macOS, or use an older release of this project."
fi

if command -v swift > /dev/null 2>&1; then
  ok "Swift — $(swift --version 2>&1 | head -1 | sed 's/^ *//')"
else
  bad "Swift is not installed"
  hint "Run: xcode-select --install     (then re-run this script)"
fi

if command -v python3 > /dev/null 2>&1; then
  ok "Python — $(python3 --version 2>&1)"
else
  bad "python3 is not installed"
  hint "Run: xcode-select --install"
fi

# ------------------------------------------------------------ project data --
heading "Bundled data"

for pair in \
  "data/public_probe/unreviewed_uncharacterized_bacteria_200.fasta|the 200-sequence example query set" \
  "data/curated_reference/pbp_pks_reference.fasta|the curated reference database" \
  "config/worker.json|the worker configuration"; do
  path="${pair%%|*}"; label="${pair##*|}"
  if [[ -f "${path}" ]]; then
    ok "${label}"
  else
    bad "missing: ${path}"
    hint "Re-clone the repository; this file ships with it."
  fi
done

# -------------------------------------------------------------- this build --
heading "Build"

if [[ -x ".build/release/BioLabExplorerPipeline" ]]; then
  ok "release binary built"
elif [[ -d ".build/debug" ]]; then
  warn "debug build only — the integration tests need a release build"
  hint "Run: swift build -c release"
else
  warn "not built yet"
  hint "Run: swift build -c release      (or re-run this script with --build)"
fi

# ---------------------------------------------------------- optional tools --
heading "Optional tools — everything below is genuinely optional"
printf '  %sMissing ones are reported in every run and skipped. Nothing breaks.%s\n' "${DIM}" "${OFF}"

optional_tool() {  # name, what it enables, install command
  if command -v "$1" > /dev/null 2>&1; then
    ok "$1 — $2"
  else
    warn "$1 not installed — $2"
    hint "Run: $3"
  fi
}

optional_tool mmseqs   "faster reference search (--use-mmseqs)"      "brew install mmseqs2"
optional_tool hmmscan  "Pfam domain evidence (--pfam)"               "brew install hmmer"
optional_tool foldseek "structure comparison"                        "scripts/setup_simulation_stack.sh --plan"

PFAM_DB="${BIOLAB_PFAM_DB:-${ROOT}/data/pfam/Pfam-A.hmm}"
if [[ -f "${PFAM_DB}" ]]; then
  pressed=1
  for suffix in h3f h3i h3m h3p; do [[ -f "${PFAM_DB}.${suffix}" ]] || pressed=0; done
  if [[ "${pressed}" -eq 1 ]]; then
    ok "Pfam database — indexed and ready"
  else
    warn "Pfam database present but not indexed"
    hint "Run: hmmpress \"${PFAM_DB}\""
  fi
else
  warn "no Pfam database — needed only for --pfam"
  hint "Review first: scripts/setup_pfam.sh --plan"
fi

if command -v ollama > /dev/null 2>&1; then
  if models="$(ollama list 2>/dev/null)" && [[ -n "${models}" ]]; then
    installed="$(printf '%s\n' "${models}" | awk 'NR>1 {print $1}' | paste -sd', ' -)"
    if [[ -n "${installed}" ]]; then
      ok "ollama — running, models: ${installed}"
      hint "Use one with: --summarize ${installed%%,*}"
    else
      warn "ollama is running but has no models"
      hint "Run: ollama pull llama3.2"
    fi
  else
    warn "ollama is installed but its server is not answering"
    hint "Run: ollama serve      (to keep it running: brew services start ollama)"
  fi
else
  warn "ollama not installed — needed only for --summarize"
  hint "See https://ollama.com — this is optional and never used by default."
fi

for candidate in "${SIM_BIN_DIR:-}/python" \
                 /opt/homebrew/Caskroom/miniforge/base/envs/biolab-sim/bin/python \
                 "${HOME}/miniforge3/envs/biolab-sim/bin/python"; do
  if [[ -x "${candidate}" ]] && "${candidate}" -c "import openmm" > /dev/null 2>&1; then
    ok "OpenMM — $("${candidate}" -c 'import openmm;print(openmm.version.version)' 2>/dev/null)"
    FOUND_OPENMM=1
    break
  fi
done
if [[ -z "${FOUND_OPENMM:-}" ]]; then
  warn "OpenMM not found — needed only for the M5 structure chain"
  hint "Review first: scripts/setup_simulation_stack.sh --plan"
fi

# ------------------------------------------------------------ this machine --
heading "What this machine resolves to"
python3 scripts/host_profile.py --config config/worker.json --explain 2>/dev/null \
  | sed 's/^/  /' || warn "could not read the host profile"

# -------------------------------------------------------------------- exit --
if [[ "${BLOCKERS}" -gt 0 ]]; then
  printf '\n%s%d blocker(s).%s Fix the ✗ lines above, then run this again.\n' "${RED}" "${BLOCKERS}" "${OFF}"
  exit 1
fi

if [[ "${BUILD}" -eq 1 ]]; then
  heading "Building"
  swift build -c release || { printf '\n%sBuild failed.%s\n' "${RED}" "${OFF}"; exit 1; }
  ok "built"

  heading "Running the bundled example"
  ./.build/release/BioLabExplorerPipeline \
    --input data/public_probe/unreviewed_uncharacterized_bacteria_200.fasta \
    --reference data/curated_reference/pbp_pks_reference.fasta \
    --output runs/doctor --max 20 || {
      printf '\n%sThe example run failed.%s\n' "${RED}" "${OFF}"; exit 1; }
  printf '\n%sIt works.%s Read the report:\n' "${GREEN}" "${OFF}"
  printf '  open runs/doctor/discovery-report.md\n'
  printf '\nThen try the app:\n'
  printf '  swift run BioLabExplorer\n'
  exit 0
fi

printf '\n%sNothing is blocking you.%s Next:\n' "${GREEN}" "${OFF}"
printf '  scripts/doctor.sh --build      %sbuild and run the bundled example%s\n' "${DIM}" "${OFF}"
printf '  swift run BioLabExplorer       %sopen the app%s\n' "${DIM}" "${OFF}"
