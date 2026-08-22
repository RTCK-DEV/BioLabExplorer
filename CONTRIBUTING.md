# Contributing

Thanks for looking. This is a single-maintainer research tool, so the bar is
less about process and more about not weakening the guarantees the project sells.

## Before you start

Read `AGENTS.md`. It carries the non-negotiable rules — `BioLabExplorerCore`
stays free of SwiftUI, deterministic local scoring is the source of truth, cloud
LLMs are never on a default path, and missing external tools must be *visible*,
never silently ignored. A change that breaks one of those will be declined even
if the code is good.

## Setting up

```sh
scripts/doctor.sh                    # what this machine has, and what it is missing
swift build
swift run BioLabExplorerChecks       # fast Swift checks
bash Tests/perpetual/run_all.sh      # full offline suite (M1..M5 + adapters)
```

The suite is offline and needs no external tool. Install HMMER
(`brew install hmmer`) if you want the Pfam adapter test to actually run instead
of skipping; build the release binary (`swift build -c release`) if you want the
integration tests to run instead of skipping. CI does both.

## The rules that get changes rejected

**Determinism is a feature.** The ranking must be bit-for-bit identical across
separate processes. Swift seeds its hashing per process, so never accumulate a
floating-point value by iterating a `Dictionary` or `Set` — sort first. This is
not hypothetical: `shannonEntropy` summed over `counts.values` and drifted by one
ULP between runs, which propagated into `confidenceScore`.
`Tests/perpetual/test_determinism.sh` exists to keep that from returning.

**Optional means optional.** A new external tool must degrade to a reported note,
never a failed run and never a silent skip. Follow `PfamDomainAdapter`: an
`availability()` that explains itself in a sentence a user can act on, and a
caller that turns any failure into a run note.

**Advisory means advisory.** Domain hits and LLM summaries must not touch
`noveltyScore`, `confidenceScore`, `machineLoadScore`, `classification`, or
`DiscoveryValidator`. Both adapters ship with tests that compare an enriched run
against a plain one and fail if any score moved.

**No silent data mangling.** The parser rejects nucleotide FASTA, internal stop
codons and unsupported residues, and *reports* gap removal and stop trimming. If
you add an input path, report what it changed.

**No hidden network.** Anything that touches the network is gated by
`ALLOW_NETWORK=1` or `--allow-network`, pinned to an allowed host, and verified
against a digest or a published checksum.

## Machine-specific values

`config/worker.json` may say `"auto"` for hardware-dependent keys;
`scripts/host_profile.py` resolves them from the running host. Do not commit a
value tuned to your own machine — add an auto rule instead, and a test in
`Tests/perpetual/test_host_profile.py` that pins the rule against a synthetic
host description so it holds on any runner.

```sh
python3 scripts/host_profile.py --config config/worker.json --explain
```

## Pull requests

- One concern per PR.
- Add or update a test. A behaviour change with no test will be asked for one.
- Run `bash Tests/perpetual/run_all.sh` before pushing.
- Say what you verified and what you did not. "I could not test the Vina path,
  no GPU" is a useful sentence; silence about it is not.
- Commit messages follow the existing style: `feat(worker-m5): ...`,
  `fix(worker): ...`, `test(worker): ...`, `docs: ...`.

## Reporting bugs

Include the platform, `swift --version`, the output of
`python3 scripts/host_profile.py`, and the exact command. For a wrong result,
attach `discovery-report.md` and the run JSON — the notes section usually
explains which adapter was unavailable.
