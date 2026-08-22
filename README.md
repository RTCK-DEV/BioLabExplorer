# BioLabExplorer

[![CI](https://github.com/RTCK-reina/BioLabExplorer/actions/workflows/ci.yml/badge.svg)](https://github.com/RTCK-reina/BioLabExplorer/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
![Platform: macOS 15+](https://img.shields.io/badge/platform-macOS%2015%2B-lightgrey)
![Swift 6](https://img.shields.io/badge/swift-6-orange)

A local-first macOS tool for semi-automated scientific prospecting. It reads
protein FASTA and ranks candidates by novelty, structural interest, evidence
quality, and how much compute they are worth spending, so a human can decide
what to look at next.

Everything on a default path is deterministic, offline, and local. External
tools are optional adapters: if MMseqs2, HMMER, Foldseek, OpenMM or Ollama are
missing, the run says so and continues with the native Swift implementation.
No cloud LLM is contacted on any code path.

![The BioLabExplorer window: settings and tool readiness on the left, ranked
candidates in the middle, evidence for the selected candidate on the
right.](docs/images/app-layout.svg)

## Start here

```sh
git clone https://github.com/RTCK-reina/BioLabExplorer.git
cd BioLabExplorer
scripts/doctor.sh --build
```

`doctor.sh` checks whether this machine can run the project, prints the exact
command for anything that is missing, builds, and then ranks a real
200-sequence UniProt query set from files already in the repository. It
downloads nothing, installs nothing, and never asks for an administrator
password.

If it finishes, you have a working install and a report to read:

```sh
open runs/doctor/discovery-report.md     # the ranking and the evidence behind it
swift run BioLabExplorer                 # the same thing as an app
```

Run `scripts/doctor.sh` on its own any time to see what is installed, what is
missing, and what each missing piece would enable. Nothing in that list is
required: the default path uses no external tool at all.

Stuck? Jump to [Troubleshooting](#troubleshooting).

## Is this for you?

| You want to… | This project |
| --- | --- |
| Narrow thousands of uncharacterized proteins down to a shortlist worth a human afternoon | **Yes.** That is the whole job. |
| Run it on your own machine, offline, with results reproducible byte for byte | **Yes.** Nothing leaves the machine without `--allow-network`. |
| Predict what a protein *does* | **No.** It ranks how *worth looking at* a sequence is. |
| Point it at your own FASTA | **Yes.** `--input your.fasta`, or Import FASTA in the app. |
| Run it on Windows or Linux | **No.** macOS 15+ only. |
| Use it without MMseqs2, HMMER, OpenMM or a local LLM | **Yes.** Each one is optional and reported when absent. |

## What this is, and what it is not

**It is** a prioritisation aid. It answers "of these ten thousand
uncharacterized proteins, which twenty are worth a human afternoon?"

**It is not** a function predictor. A high novelty score means "weakly annotated
and distant from anything in the reference set", not "does something
interesting". `realizedComputeValue` measures how complete the evidence chain
is, not how confident the biology is. Optional Pfam domains and optional local
LLM wording are advisory: neither can move a score, a classification, or the
validation verdict, and the tests enforce that.

### Reading the result

`discovery-report.md` lists candidates best first. For each one:

- **Novelty** — how far it sits from anything in the reference set. High means
  "nothing known looks much like this", not "this is important".
- **Confidence** — how well the evidence hangs together. Low confidence with
  high novelty usually means a junk sequence, not a discovery.
- **Compute value** — how likely heavier analysis is to pay off, so an
  expensive structure prediction goes where it counts.
- **Evidence** — the specific reasons behind those numbers, each with its own
  weight, so a score is never a figure you have to take on trust.
- **Run Notes** — what happened, including every tool that was unavailable and
  every transformation applied to your input.

A candidate marked *actionable* in `discovery-validation.json` cleared every
threshold listed in that same file. Nothing else is a recommendation.

## Quickstart, step by step

```sh
swift build
swift run BioLabExplorerChecks                 # ~15 s, no external tools needed

# Rank the bundled 200-sequence UniProt query set against the curated reference
swift run BioLabExplorerPipeline \
  --input data/public_probe/unreviewed_uncharacterized_bacteria_200.fasta \
  --reference data/curated_reference/pbp_pks_reference.fasta \
  --output runs/quickstart --max 20

open runs/quickstart/discovery-report.md
```

That runs entirely from files in the repository. Nothing is downloaded and no
external tool is required.

For the GUI:

```sh
swift run BioLabExplorer
```

## Requirements

- macOS 15 or later, Apple Silicon or Intel.
- Swift 6 (Xcode 16 or the matching Command Line Tools).
- Python 3.9+ for the worker scripts and the test suite (macOS ships this).

Everything else is optional and detected at runtime:

| Tool | Enables | Install |
| --- | --- | --- |
| HMMER | Pfam domain evidence (`--pfam`), `phmmer` in the sim queue | `brew install hmmer` |
| MMseqs2 | faster reference search (`--use-mmseqs`) | `brew install mmseqs2` |
| Foldseek | structure comparison | `scripts/setup_simulation_stack.sh` |
| OpenMM, PDBFixer, Vina, Meeko | the M5 structure chain | `scripts/setup_simulation_stack.sh` |
| Ollama | advisory local summaries (`--summarize`) | https://ollama.com |

## Command line

```
BioLabExplorerPipeline --input <query.fasta> [options]

REQUIRED
  --input <path>          Protein FASTA to rank.

OUTPUT
  --output <dir>          Run directory for reports (default: runs/latest).
  --max <n>               Maximum ranked candidates (default: 20).
  --require-discovery     Exit 2 when no candidate meets the actionable threshold.

REFERENCE SEARCH
  --reference <path>      Reference FASTA for known-hit identity.
  --use-mmseqs            Prefer MMseqs2 over the native Swift k-mer search.

OPTIONAL EVIDENCE (never changes a score)
  --pfam                  Annotate candidates with Pfam domains via hmmscan.
  --pfam-db <path>        Pfam-A.hmm location (else $BIOLAB_PFAM_DB, else data/pfam/Pfam-A.hmm).
  --pfam-evalue <x>       Use an E-value cutoff instead of Pfam gathering thresholds.
  --summarize [model]     Advisory local-LLM wording via ollama (default: llama3.2).
```

Unknown options are rejected rather than ignored, so a typo cannot quietly
produce a run with the wrong settings.

### Input validation

The parser is strict about what it accepts, and explicit about what it changes:

- Alignment gaps (`-`, `.`, `~`) are removed, counted, and reported.
- A single trailing `*` is trimmed and reported. An **internal** stop codon fails
  with the residue position — that translation is wrong.
- IUPAC ambiguity codes (`B Z J X O U`) are accepted; anything else fails with
  the offending character and its position.
- Whitespace and residue numbering are ignored; `;` comment lines are skipped.
- Nucleotide FASTA is **rejected**, not ranked as protein.
- Duplicate record identifiers are kept as separate candidates, and reported.

Every transformation appears in the run notes and in `discovery-report.md`.

## The app

`swift run BioLabExplorer` opens a three-pane window: run settings and tool
readiness on the left, ranked candidates in the middle, and the evidence for the
selected candidate on the right.

- **Import FASTA** runs your file through exactly the command-line pipeline, so
  the app and the CLI cannot drift apart. **Bundled Sample** returns to the
  built-in synthetic dataset.
- **Ranking** exposes the candidate cap and the novelty / confidence /
  compute-value biases, and lets you point a reference FASTA at an imported file.
- **Optional Evidence** toggles Pfam domains and the local summary, and tells you
  *before* you run whether each one can actually work ("hmmscan and Pfam-A.hmm
  are ready", "Model llama3.2 is not installed. Run: ollama pull llama3.2").
- **Export** writes JSON and Markdown to `~/Documents/BioLabExplorer/Runs`;
  **Reveal** opens it in Finder.

Long work — reference search, hmmscan, a local model — runs off the main thread,
so the window stays responsive.

Tool detection does not rely on your shell: an app launched from Finder inherits
launchd's `PATH`, so the Homebrew and MacPorts prefixes are searched explicitly
after `SIM_BIN_DIR` and `PATH`. Tools you have installed show up as installed.

## Optional evidence

### Pfam domains

```sh
brew install hmmer
ALLOW_NETWORK=1 scripts/setup_pfam.sh          # ~400 MB download, ~3 GB on disk
scripts/setup_pfam.sh --plan                   # review it first, offline

swift run BioLabExplorerPipeline --input query.fasta --output runs/demo --pfam
```

`setup_pfam.sh` refuses without `ALLOW_NETWORK=1`, pins the host, verifies the
archive against the checksum file EBI publishes beside it (or a `PFAM_SHA256`
you supply), runs `hmmpress`, and writes `data/pfam/pfam_manifest.json` recording
the release and digests it actually obtained. Pin a release for a reproducible
install: `PFAM_RELEASE=Pfam37.0`.

Domain hits land in the `domains` field, in a Markdown table marked *advisory,
not scored*, and as zero-weighted evidence entries. Default thresholds are
Pfam's curated per-family gathering cutoffs (`--cut_ga`), which is what the Pfam
website itself uses.

If HMMER is missing, the database is absent, or it has not been `hmmpress`-ed,
the run completes and the report says which one and how to fix it.

### Advisory local summaries

```sh
ollama pull llama3.2
swift run BioLabExplorerPipeline --input query.fasta --output runs/demo --summarize
```

The prompt is built only from values already in the deterministic report and
instructs the model to restate them without adding biology. The result is stored
as `advisorySummary` with a disclaimer attached, rendered under a heading that
says *not evidence*, and excluded from every score and from `DiscoveryValidator`.

## Configuration and host detection

`config/worker.json` is portable. Hardware-dependent keys may be the string
`"auto"`, resolved from the running host at use time:

| Key | Auto rule |
| --- | --- |
| `simReserveBytes` | one third of physical RAM, at least 4 GiB |
| `simRamBudgetBytes` | physical RAM minus the reserve |
| `maxWorkspaceBytes` | one quarter of free disk, clamped to 5–20 GiB |
| `simMaxCpuJobs` | `0`, meaning every logical CPU may take a job |
| `esmfoldDevice` | `mps` on Apple Silicon, `cpu` elsewhere |
| `openmmPlatform` | `CUDA` with an NVIDIA GPU, `CPU` on macOS, `OpenCL` otherwise |

See what your machine resolves to:

```sh
python3 scripts/host_profile.py --config config/worker.json --explain
```

```text
host: Darwin arm64, 15 logical CPUs, RAM 24.00 GiB
  simReserveBytes = 8.00 GiB  (one third of physical RAM, at least 4 GiB, ...)
  simRamBudgetBytes = 16.00 GiB  (physical RAM minus the reserve)
  ...
```

An explicit value is never overridden, so pinning a key for a benchmark still
works. Detection failures fall back to conservative constants rather than
raising. Each run records the host and the resolutions it used in
`runs/<cycle>/sim/summary.json`.

## Reproducibility

The ranking is bit-for-bit identical across separate processes, and
`Tests/perpetual/test_determinism.sh` enforces it by comparing six independent
runs — not six iterations inside one process, which cannot see the failure mode.

This matters because Swift seeds its hashing per process. Any floating-point
value accumulated by iterating a `Dictionary` or `Set` sums its terms in a
different order every run, and floating-point addition is not associative.
`shannonEntropy` did exactly that and drifted by one ULP, which propagated into
`confidenceScore`. Sort before you sum.

The same applies to the optional structure chain. OpenMM's CPU platform sums
forces per thread and reduces them in completion order, so it is pinned to one
thread (`openmmCpuThreads: 1`) and Vina uses a fixed seed: two runs of the same
input produce byte-identical structures. Every relaxation records
`bitReproducible`, which is false the moment you raise the thread count for
speed — the guarantee is stated per run, not assumed.

## Reports

Every run directory gets:

| File | Contents |
| --- | --- |
| `discovery-report.md` | Human-readable ranking, evidence, tool status, run notes |
| `run-<timestamp>.json` | The full `DiscoveryRun`: candidates, features, evidence, domains, advisory summary |
| `discovery-validation.json` | Whether any candidate met the actionable threshold, and the criteria |

A candidate is *actionable* when it is weakly annotated, classified as a remote
functional candidate, scores at least 0.85 novelty and 0.65 confidence, sits
between 0.15 and 0.40 known-hit identity, has a best-hit annotation, and carries
search evidence (e-value ≤ 1e-20 or native k-mer support ≥ 0.035). The full
criteria list ships inside every validation file, so a verdict is never a black
box.

`domains` and `advisorySummary` decode as absent, so reports written before
those fields existed still load.

## Autonomous discovery workflow

Runs local checks, analyses the cached 200-sequence UniProt query set, validates
the top candidate with Swift-native C-alpha distance-map comparison, writes an
achievement report, and packages the app.

```sh
scripts/run_autonomous_discovery.sh                 # local files and cache only
scripts/run_autonomous_discovery.sh --allow-network # permit UniProt/AlphaFold reads
```

By default it fails with the missing path rather than silently downloading data.

```sh
scripts/run_public_probe.sh          # public probe against the curated reference
scripts/package_app.sh               # writes dist/BioLab Explorer.app
```

## Perpetual discovery worker

A five-milestone pipeline that keeps finding new candidates without supervision.
Each milestone is independently usable.

### M1 — offline worker

Consumes FASTA batches from `state/inbox/`, records every processed sequence in
a SQLite seen-set ledger (`discoveries/ledger.db`), flags actionable ones, and
regenerates `discoveries/DISCOVERIES.md`.

```sh
swift build -c release
cp your_batch.fasta state/inbox/
scripts/run_discovery_cycle.sh
scripts/discovery_status.sh
```

Guardrails: `state/STOP` stops gracefully; the cycle pauses under `diskFloorGB`
or `maxWorkspaceBytes` and aborts if the reference digest does not match
`config/approved_manifest.json`; a single-instance lock (`state/.lock`) prevents
overlap.

### M2 — daemon

Runs cycles back to back under launchd with a minimum spacing of
`throttleSeconds`. After `maxConsecutiveFailures` failures a circuit breaker
trips (`state/PAUSED`).

```sh
scripts/discovery_agent.sh install     # load the launchd agent
scripts/discovery_agent.sh status      # loaded? paused? plus discovery status
scripts/discovery_agent.sh resume      # clear PAUSED and the failure streak
scripts/discovery_agent.sh uninstall   # true stop (unload and remove)
```

`state/STOP` pauses cycles without unloading; a true stop is `uninstall`.

### M3 — network rotation (opt-in)

To keep finding *new* candidates, enable cursor-paged UniProt fetching, one page
per cycle:

1. Set `enableNetwork: true` in `config/worker.json`.
2. Ensure `config/approved_manifest.json` matches both the curated reference and
   `config/query_rotation.json` by digest, names a non-`unset` reviewer and
   review date, and retains the biosecurity exclusions.
3. `scripts/discovery_agent.sh install` — it prints `mode=NETWORKED` and bakes
   `ALLOW_NETWORK=1` into the generated launchd plist. With `enableNetwork:
   false` it prints `mode=offline` and never sets the variable.

One networked cycle by hand, without installing the daemon:

```sh
scripts/run_discovery_cycle.sh --allow-network
```

Envelope: never touches the network unless `ALLOW_NETWORK=1` **and** the host is
`uniprotHost`; rate limited; fail-closed when the manifest is absent or a digest
does not match. Every opaque next-page cursor is bound to that digest and query
ID, so legacy or mismatched cursors are discarded. Transport, 429 and 5xx errors
are retryable no-ops; scope or response-contract violations fail the cycle
loudly.

### M4 — dashboard

Every cycle regenerates a self-contained `discoveries/dashboard.html`: stat
tiles, a new-candidates-per-cycle chart, the discoveries table, and an
interactive 3D protein viewer coloured by pLDDT for candidates with an AlphaFold
structure.

```sh
ALLOW_NETWORK=1 scripts/vendor_assets.sh    # one-time: fetch 3Dmol.js, refresh the page
open discoveries/dashboard.html
```

The vendored 3Dmol.js 2.4.0 keeps runtime CDN-free. The vendor script enforces
HTTPS, rejects redirects, and verifies pinned SHA-256 values for both the script
and its licence; a custom URL requires an explicit hash pin.

### M5 — simulation stack (opt-in)

Each cycle can run a simulation queue over that cycle's new actionable
candidates. Backends are detected at runtime; anything missing is reported in
`runs/<cycle>/sim/summary.json`, shown on the dashboard, and skipped. A
scientific backend failing does not discard the deterministic Swift result;
queue, payload or reporting contract failures do fail the cycle loudly, before
input archival.

Structure computation is a provenance-preserving serial chain:

```text
sequence -> revision-pinned ESMFold (or labelled AlphaFold-cache fallback)
         -> PDBFixer heavy-atom repair -> OpenMM minimization
         -> Meeko receptor preparation -> manifest-gated AutoDock Vina
         -> local 3Dmol protein/pose viewer + PNG export
```

OpenMM output is the only receptor source Vina accepts. SHA-256 is recorded at
every handoff, alongside model revision, energy change, and docking
box/motif/seed/affinities. Admission is bounded by unified-memory and live
memory-pressure gates; MMseqs2 and HMMER split available CPU threads by
configurable weights and run concurrently; GPU work is serialised; folding skips
sequences longer than `simMaxSeqLength`.

```sh
scripts/setup_simulation_stack.sh --plan          # review what it installs, offline
ALLOW_NETWORK=1 scripts/setup_simulation_stack.sh # multi-GB install, your call
scripts/setup_esmfold_hf.sh --plan
ALLOW_NETWORK=1 scripts/setup_esmfold_hf.sh       # isolated PyTorch/Transformers env
```

Set `ESMFOLD_PYTHON` to that environment's Python and `SIM_BIN_DIR` to the
simulation environment when the tools live in a separate conda env.

The queue can also consume a FASTA directly, using the same accession parser and
sequence checksum contract as the ledger:

```sh
python3 scripts/sim_queue.py run \
  --candidates-fasta data/public_probe/unreviewed_uncharacterized_bacteria_200.fasta \
  --reference data/public_probe/uniprot_sprot.fasta \
  --run-dir runs/swissprot-audit --config config/worker.json --budget-seconds 600
```

ColabFold is **not** part of the stack: local MSA needs roughly 940 GB of
database and 128 GB of RAM. The External MSA Store (`externalMsaStorePath`,
`enableColabFold`) is a reserved post-M5 design and is intentionally inert until
a fully local model/MSA cache path receives its own safety review.

## Measured on the reference host

Recorded on a 15-logical-core / 24 GiB Apple Silicon machine, 2026-07-15. These
are the author's numbers, not a claim about your hardware.

**CPU splitting** — 200 approved query sequences against the cached 275 MB
Swiss-Prot FASTA:

| Split | Wall clock | Notes |
| --- | --- | --- |
| Equal 7/7 | 508.235 s | |
| Weighted MMseqs2/HMMER 5/10 | 432.322 s | 75.913 s saved, 1.176× |

Both runs: 40,323 MMseqs2 rows, 98,631 non-comment HMMER result rows, zero
failed jobs, about 14.3 of 15 cores busy during the concurrent phase. The sorted
scientific-result SHA-256 values match between runs; only command headers and
output ordering differ.

**Structure chain** — the 668-residue candidate `A0A062TNK1` through
ESMFold → OpenMM → Vina: 655.97 s, zero failures, 5.16 GB peak RSS, zero swap.
ESMFold took 596.72 s on MPS (mean pLDDT 94.59); OpenMM reduced potential energy
by 55,690.39 kJ/mol; Vina used 15 threads and reported a fixed-seed best pose of
−8.317 kcal/mol. Folding, relaxation and docking input digests all matched.

**Where the evidence lives** — every figure above comes from a run directory
that stays local: `runs/` is git-ignored, so nothing here is a number you have
to take on trust from a README alone, and nothing here bloats the repository.
The CPU-split comparison is `runs/swissprot_full200_20260715` and
`runs/swissprot_full200_weighted_20260715` (about 345 MB each, almost entirely
raw MMseqs2 and HMMER result rows); the structure chain is
`runs/a0a062tnk1_full_chain_20260715` and `runs/structure_chain_*_20260715`;
the release audit is `runs/perfect_release_20260715` and
`runs/release_audit_20260715`. Regenerating them is a matter of re-running the
commands above with the same inputs, so they are safe to delete if you need the
disk back.

**Reproducibility** — a 40-residue fixture produced byte-identical ESMFold PDBs
across two MPS runs. For `G6AGY4` (842 residues), two OpenMM → Vina runs produced
byte-identical relaxed PDB, receptor PDBQT and pose PDBQT, with a fixed-seed best
affinity of −7.941 kcal/mol. OpenCL context creation failed on this host, so the
recorded release path is the CPU fallback — which is why `openmmPlatform: "auto"`
resolves to `CPU` on macOS.

## Troubleshooting

Run `scripts/doctor.sh` first — it names most of these and gives you the exact
command. The rest are the ones that confuse people.

**`swift: command not found`**
Install Apple's command line tools: `xcode-select --install`. Nothing else is
needed; a full Xcode install works too but is not required.

**"BioLab Explorer" cannot be opened because the developer cannot be verified**
The app you built is signed ad-hoc, not notarized, because this project has no
Apple Developer certificate. macOS blocks it on first open. Either right-click
the app and choose Open (which offers an "Open anyway" button), or clear the
quarantine flag on the copy you just built yourself:

```sh
xattr -dr com.apple.quarantine "dist/BioLab Explorer.app"
```

Only do that for an app you built from this source yourself. `swift run
BioLabExplorer` sidesteps the whole thing.

**A tool I have installed is reported as missing**
An app launched from Finder inherits launchd's `PATH`, not your shell's, so
Homebrew tools used to disappear inside the app. The probe now searches
`/opt/homebrew/bin`, `/usr/local/bin` and `/opt/local/bin` explicitly. If your
tool lives somewhere else, point at it:

```sh
export BIOLAB_TOOL_SEARCH_PATHS="/my/prefix/bin:/another/bin"
```

Press the refresh button beside **Tool Readiness** in the app to probe again.

**`--pfam` says the database is not indexed**
HMMER needs `hmmpress` to build the index next to `Pfam-A.hmm`:

```sh
hmmpress /path/to/Pfam-A.hmm
```

`scripts/setup_pfam.sh` does this for you. Run it with `--plan` first to see
what it would download.

**`--summarize` says the ollama server is not answering**
The Homebrew build does not start a server for you:

```sh
ollama serve                    # this shell only
brew services start ollama      # keep it running
```

**`--summarize` says my model is not installed, but I have it**
`ollama` resolves a bare name to the `:latest` tag, so having `llama3.2:1b`
does not satisfy `llama3.2`. The message lists what you do have — pass one of
those: `--summarize llama3.2:1b`.

**Tests print SKIPPED**
That is the suite telling you a tool it needs is absent, rather than pretending
to pass. The Pfam suite needs HMMER, the integration suites need
`swift build -c release`, and the OpenMM suite needs a Python with OpenMM. The
message always names what is missing.

**The results changed between two runs**
They should not. The ranking is bit-for-bit reproducible, and
`Tests/perpetual/test_determinism.sh` enforces it. If you see a difference,
that is a bug worth reporting — include both `run-*.json` files.

**Nothing is actionable**
`discovery-validation.json` lists every threshold and which candidates cleared
them. A run with no actionable candidate is a real answer about that input, not
a failure. `--require-discovery` turns it into exit code 2 when you want a
pipeline to stop there.

## Development

```sh
scripts/doctor.sh                    # what this machine has and what it is missing
swift build                          # debug
swift run BioLabExplorerChecks       # Swift checks (fast, no external tools)
swift build -c release               # needed by the integration tests
bash Tests/perpetual/run_all.sh      # full offline suite, M1..M5 and the adapters
```

The whole suite is offline. Tests that need something you may not have — the
release binary, HMMER — skip themselves with a printed reason rather than
failing. CI installs HMMER and builds release so nothing skips there.

`AGENTS.md` records the project's non-negotiable rules and is worth reading
before changing anything. `CONTRIBUTING.md` covers what gets a change rejected.

Note: with only the Command Line Tools installed, `swift build` emits
`ld: warning: search path ... not found` for Xcode-only framework paths, and
XCTest plugins do not resolve — which is why validation runs through the
`BioLabExplorerChecks` executable target rather than XCTest.

## Responsible use

Networked candidate fetching is gated by `config/approved_manifest.json`, which
pins the reference and query-set digests, names a human reviewer, and carries a
non-empty exclusion list (virulence factors, toxin biosynthesis gene clusters,
select-agent homologs). Changing the reference or the query scope changes a
digest and fails the cycle until a human re-approves it.

If you fork this and change that scope, you are the reviewer. Read
`SECURITY.md` before you do.

## Roadmap

- Streaming FASTA import for inputs larger than memory.
- A native reference database builder with incremental updates, replacing the
  one-shot subset build.
- Pfam clan-aware domain grouping, so overlapping hits from one clan collapse to
  a single line of evidence.
- Evaluate Boltz as a manifest-pinned predictor alongside ESMFold.
- Foldseek structure-database search as an optional comparison adapter.

Not planned: making any external tool mandatory, putting a cloud LLM on a
default path, or letting advisory evidence influence a score.

## License

MIT — see [LICENSE](LICENSE). Copyright (c) 2026 RTCK.

Third-party components and data sources are listed in
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). No bulk biological database is
redistributed here; a few small UniProt, AlphaFold and PubChem records are
checked in so the quickstart and the tests work offline, under their upstream
CC BY 4.0 / public-domain terms.
