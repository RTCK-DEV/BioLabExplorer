# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.1] — 2026-08-22

Found by actually running the things 1.0.0 only claimed: the OpenMM stack, a
real local model, and the packaged app.

### Fixed

- **OpenMM relaxation was not reproducible, and its metrics said otherwise.**
  `openmmCpuThreads` was read from the config, copied into the job record and
  written into the metrics file — and never applied to the platform. The CPU
  platform sums forces per thread and reduces them in completion order, so two
  relaxations of the same structure landed ~200 kJ/mol apart while both reported
  `cpuThreads: 1`. `openmm_relax.py` now takes `--cpu-threads` (default 1),
  applies it to the CPU platform before any context is created (including
  `addHydrogens`), and reports the count the context actually holds.
  `sim_queue.py` passes the configured value through. A new
  `bitReproducible` field states plainly whether a run can be reproduced.
- **`usedCpuFallback` was wrong under `--platform auto`.** With `auto` there is
  no requested platform to fall back from, so CPU is a selection, not a
  degradation; it was reported as a fallback on every macOS run.
- **Terminal escape sequences reached the reports.** `ollama run` word-wraps by
  moving the cursor back and erasing to end of line, and emits those escapes
  even into a pipe, so `\u001b[7D\u001b[K` and duplicated words were stored in
  `advisorySummary` and rendered into Markdown. The client is now invoked with
  `--nowordwrap`, and `LocalSummaryAdapter.sanitize` renders whatever still
  arrives the way a terminal would — applying the cursor motions that change
  content and discarding the rest — so no control byte can reach a report.
- **The app reported every installed tool as missing.** A GUI app launched from
  Finder inherits launchd's `PATH` (`/usr/bin:/bin:/usr/sbin:/sbin`), not the
  login shell's, so MMseqs2, HMMER and Ollama showed as "missing" in the app
  while the same probe found all of them from a terminal. `ToolProbe` now also
  searches the Homebrew and MacPorts prefixes, after `SIM_BIN_DIR` and `PATH`.

### Added

- **Build provenance on every release artifact.** Notarizing needs a paid Apple
  certificate this project does not have, so the downloads stay ad-hoc signed
  and Gatekeeper still stops them. What the release workflow can give a reader
  for free is the part that actually matters — signed, public evidence that
  these exact bytes came out of this repository at a named commit:
  `gh attestation verify <file> --repo RTCK-reina/BioLabExplorer`. Documented in
  the README and inside the tarball.
- **`scripts/doctor.sh`** — the one command a newcomer runs. Checks macOS,
  Swift, Python, the bundled data and every optional tool, prints the exact
  command for anything missing, shows what this machine resolves the config to,
  and with `--build` builds and runs the bundled 200-sequence example. Offline,
  installs nothing, never asks for an administrator password. CI runs it, so the
  first thing anyone does with the project cannot silently break.
- A README that starts with a picture of the window, three commands, and a
  plain "is this for you?" table, followed by how to read a result. The
  reference material still follows; it is no longer the first thing you meet.
- A **Troubleshooting** section covering the failures people actually hit:
  missing Swift, the Gatekeeper block on an ad-hoc-signed app, an installed
  tool reported missing, an unindexed Pfam database, the ollama server not
  running, a model tag that does not match, tests printing SKIPPED, and what a
  run with no actionable candidate means.
- `--version` on the pipeline CLI, from a single `BioLabExplorerVersion`.
- `Tests/perpetual/test_openmm_determinism.sh`: relaxes the same structure
  twice and requires byte-identical output, requires the metrics to report the
  thread count actually used, and pins the `auto` platform ordering. Skips when
  no Python with OpenMM is available.
- Swift checks for `LocalSummaryAdapter.sanitize` (cursor-back plus erase-line,
  colour codes, carriage returns, OSC sequences, stray control bytes) and for
  the tool search order.
- CI names the suites that skipped on the runner, so a silent skip is never
  mistaken for a pass.

### Changed

- `scripts/doctor.sh` answers a non-macOS user in one screen — why this is
  macOS-only, that no install will change it, and where the portable part of
  the code lives — instead of walking them through a checklist of things that
  cannot help.

- **One source of truth for the OpenMM platform.** `host_profile.py` used to
  guess `openmmPlatform` from the host while `openmm_relax.py` probed the
  platforms for real — two different answers to one question, and the guess was
  the one that could be wrong. The key is now passed through untouched and the
  probe decides, recording every attempt.
- Ollama's unavailable messages name the next command instead of describing the
  problem: a stopped server says `ollama serve` (and `brew services start
  ollama`), and a missing model lists the models you do have plus a
  `--summarize` line that would work with one of them.

### Verified on real tools

- OpenMM 8.5.2: `--platform auto` tried CUDA (not registered) then OpenCL
  ("No compatible OpenCL platform is available") then selected CPU, with every
  attempt recorded — which is what `openmmPlatform: "auto"` resolving to `CPU`
  on macOS was inferred from in 1.0.0 and is now measured.
- Ollama 0.32.15 with `llama3.2:1b`: a real summary, clean of control bytes,
  with scores and the validation verdict unchanged.
- The packaged app: settings, tool readiness with resolved paths, and the
  live availability message for an absent Pfam database.

### Known limitations

Things this release does not do. None of them is a bug report; they are the
answers a reader would otherwise find the hard way.

- **The downloads are ad-hoc signed, not notarized.** Notarization needs a paid
  Apple Developer account this project does not have, so Gatekeeper stops both
  the app and the CLI the first time they are opened. Check the build
  provenance first — `gh attestation verify <file> --repo
  RTCK-reina/BioLabExplorer`, which prints nothing and exits 0 when it
  succeeds — then follow the Gatekeeper steps under Troubleshooting in the
  README.
- **macOS 15 or newer, Apple Silicon or Intel.** The Swift core is portable and
  its tests run anywhere Swift 6 does, but the app, the packaging scripts and
  the tool probe are macOS-only. On other systems `scripts/doctor.sh` says so
  in one screen instead of walking through a checklist that cannot help.
- **The figure in the README is a diagram, not a screen capture.** It is drawn
  to match the window layout and labelled as a diagram. A `--render-screenshot`
  flag was written and then removed: `ImageRenderer` cannot draw
  `NavigationSplitView` or `List`, so it wrote unusable images rather than a
  picture of the app.
- **The simulation stack is an opt-in multi-gigabyte install.** OpenMM, ESMFold
  and AutoDock Vina are neither bundled nor installed by anything in this
  repository. Until they are present `Tests/perpetual/test_openmm_determinism.sh`
  reports SKIPPED and the pipeline runs the sequence-only path.
- **`bitReproducible` is a single-threaded CPU guarantee.** It is true only on
  the CPU or Reference platform with one thread. Anywhere else the order in
  which forces are reduced varies between runs, and two relaxations of the same
  structure will not match.
- **The Pfam and advisory-summary adapters need tools you install yourself.**
  Domain annotation wants an `hmmpress`-indexed Pfam-A database; the advisory
  summary wants a running `ollama` server and a model you have pulled. Neither
  is bundled, both report their own unavailability with the next command to
  run, and a run completes without either.
- **ColabFold and the External MSA Store are reserved keys, not features.**
  `enableColabFold` and `externalMsaStorePath` appear in `config/worker.json`,
  but nothing in this release acts on them: a fully local MSA needs roughly
  940 GB of database and 128 GB of RAM, and sending raw FASTA to a public MSA
  server is out of scope for a tool that runs on one machine.

## [1.0.0] — 2026-08-22

First public release. Everything below M1..M5 shipped before the repository was
opened; this entry records the work that made it usable on a machine other than
the author's.

### Added

- **Host auto-detection** (`scripts/host_profile.py`). Hardware-dependent keys in
  `config/worker.json` may now be the string `"auto"` and are resolved from the
  running host: `simReserveBytes`, `simRamBudgetBytes`, `maxWorkspaceBytes`,
  `simMaxCpuJobs`, `esmfoldDevice`, `openmmPlatform`. Explicit values are never
  overridden, every substitution is reported with a reason, and detection
  failures fall back to conservative constants instead of raising.
  `python3 scripts/host_profile.py --config config/worker.json --explain` shows
  what the current host resolves to.
- **Pfam domain adapter** (`PfamDomainAdapter`, `--pfam`). Optional profile-HMM
  annotation of ranked candidates through `hmmscan`, defaulting to Pfam's curated
  gathering thresholds. Domain hits are recorded as zero-weighted evidence and in
  a new `domains` field; they never change a score. `scripts/setup_pfam.sh`
  fetches and indexes the database behind the usual network gate and writes a
  provenance manifest.
- **Local advisory summaries** (`LocalSummaryAdapter`, `--summarize [model]`).
  Optional narrative wording from a local Ollama model, stored as
  `advisorySummary` with a disclaimer attached. Prompted only from values already
  in the deterministic report. No cloud endpoint is contacted on any code path.
- **Residue-level FASTA validation** (`SequenceAlphabet`). Alignment gaps are
  removed and counted, a terminal stop codon is trimmed, IUPAC ambiguity codes
  are accepted, and every transformation is reported in the run notes. Internal
  stop codons, unsupported residues, empty headers and nucleotide FASTA now fail
  with the offending record and position instead of being silently mangled.
- **App controls**: ranking settings (candidate cap, novelty/confidence/compute
  biases), reference FASTA selection, Pfam and summary toggles with live
  availability messages, tool re-probe, reveal-in-Finder, and a bundled-sample
  button. Imported files now go through exactly the command-line pipeline, so
  the app and the CLI cannot drift apart.
- **CI** (`.github/workflows/ci.yml`): debug and release builds, Swift checks,
  the full offline suite, host-profile resolution, and app packaging on macOS,
  plus shell and Python static checks on Linux.
- **Tests**: `test_host_profile.py` (19 cases over synthetic hosts),
  `test_determinism.sh` (cross-process bit-for-bit reproducibility),
  `test_pfam_adapter.sh` (real `hmmbuild`/`hmmpress`/`hmmscan` chain against a
  throwaway profile database), `test_local_summary.sh` (full shell-out chain
  against a stub), and new Swift checks for the alphabet, parser diagnostics,
  report schema compatibility, and the external command runner.
- `LICENSE` (MIT), `SECURITY.md`, `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md`,
  `THIRD_PARTY_NOTICES.md`, issue and pull-request templates.

### Fixed

- **The ranking was not reproducible across processes.** `shannonEntropy` summed
  `-p·log2(p)` by iterating `counts.values`. Swift seeds its hashing per process,
  so the terms were added in a different order in every run, and floating-point
  addition is not associative: the result drifted by one ULP, which propagated
  into `confidenceScore`. Six separate runs of the same input produced two
  different score sets. Summation is now ordered by residue, and
  `test_determinism.sh` compares separate processes so this cannot return
  unnoticed.
- `ExternalCommandRunner` read stdout only after the child exited, so a child
  that outgrew a pipe buffer would deadlock. Both pipes are now drained
  concurrently, and the runner gained stdin and timeout support.
- The pipeline CLI silently ignored unknown flags, so a typo produced a
  confident run with the wrong settings. Unknown options now fail with usage.
- `swift build` emitted Swift 6 concurrency warnings for captured mutable state
  in the command runner. Zero warnings now.

### Changed

- `config/worker.json` ships `"auto"` for the six hardware-dependent keys. On the
  original 15-core / 24 GiB host this resolves to exactly the values that were
  previously hard-coded (8 GiB reserve, 16 GiB budget), so behaviour there is
  unchanged.
- `openmm_relax.py --platform` accepts `auto` and `CUDA`, trying accelerated
  platforms before CPU and recording every attempt in the metrics file.
- Simulation summary schema bumped to version 4: `host` and `hostResolvedConfig`
  record the machine and the auto-resolution that a run actually used.
- `CandidateReport` gained `domains` and `DiscoveryRun` gained `advisorySummary`.
  Both decode as absent, so reports written by earlier versions still load.

## [0.5.0] — 2026-07-15 — M5, simulation stack

Opt-in simulation queue over each cycle's new actionable candidates, with runtime
backend detection, unified-memory and memory-pressure admission gates, weighted
CPU splitting between MMseqs2 and HMMER, and a provenance-preserving structure
chain (revision-pinned ESMFold → PDBFixer → OpenMM → Meeko → manifest-gated
Vina) with SHA-256 recorded at every handoff.

## [0.4.0] — 2026-07-14 — M4, dashboard

Every cycle regenerates a self-contained `discoveries/dashboard.html` with stat
tiles, a new-candidates-per-cycle chart, a discoveries table, and an interactive
3D viewer coloured by pLDDT, backed by a digest-pinned local copy of 3Dmol.js.

## [0.3.0] — M3, network rotation

Opt-in, cursor-paged UniProt fetching bound to a digest-pinned approved query
set, rate limited, host restricted, and fail-closed on any scope or contract
violation.

## [0.2.0] — M2, daemon

Continuous offline cycles under launchd with throttling, a circuit breaker after
N consecutive failures, and a true-stop path separate from a graceful pause.

## [0.1.0] — M1, perpetual worker

Offline FASTA batch consumption from `state/inbox/`, a SQLite seen-set ledger,
disk and workspace guardrails, a single-instance lock, and a regenerated
`DISCOVERIES.md`.

[1.0.1]: https://github.com/RTCK-reina/BioLabExplorer/releases/tag/v1.0.1
[1.0.0]: https://github.com/RTCK-reina/BioLabExplorer/releases/tag/v1.0.0
