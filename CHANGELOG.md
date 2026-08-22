# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[1.0.0]: https://github.com/RTCK-reina/BioLabExplorer/releases/tag/v1.0.0
