# AGENTS.md

## 1. Project Facts

- Project: BioLabExplorer
- Target platform: macOS desktop app, Apple Silicon first
- Main languages: Swift 6, SwiftUI
- Primary entry points:
  - `Sources/BioLabExplorer/BioLabExplorerApp.swift`
  - `Sources/BioLabExplorerCore/DiscoveryEngine.swift`
  - `scripts/run_autonomous_discovery.sh`
- Source of truth for config/constants:
  - `Sources/BioLabExplorerCore/DiscoveryConfiguration.swift`
- Source of truth for API/file/data contracts:
  - `Sources/BioLabExplorerCore/Models.swift`
  - `Sources/BioLabExplorerCore/ReportWriter.swift`
- Build command: `swift build`
- Test command: `swift run BioLabExplorerChecks`
- Full offline suite: `bash Tests/perpetual/run_all.sh` (needs `swift build -c release` for the integration tests)
- Heavy/integration test command: `scripts/run_autonomous_discovery.sh`
- Known external dependencies:
  - Optional runtime tools: `mmseqs`, `hmmsearch`, `foldseek`, `ollama`
  - Scientific stack: revision-pinned Hugging Face ESMFold (isolated env), PDBFixer/OpenMM, Meeko/AutoDock Vina, vendored 3Dmol.js.
  - Public UniProt/AlphaFold reads require `--allow-network`; default workflows use local files/cache only.
  - The MVP must run without them and must report missing tools explicitly.
  - This local Command Line Tools install does not resolve XCTest/Testing plugins, so validation uses the `BioLabExplorerChecks` executable target.
  - Default discovery and structure validation must use Swift-native code. MMseqs2/Foldseek are optional comparison adapters only.
- Known unsafe/destructive commands:
  - Do not delete user datasets.
  - Do not run destructive file cleanup outside `dist/` or `.build/`.

### Locked facts

- [x] Cloud LLMs are not part of the default runtime path.
- [x] Local scientific tools and deterministic scores are the source of truth.
- [x] LLM-generated summaries are advisory text only (`LocalSummaryAdapter`, opt-in via `--summarize`).
- [x] Pfam domain hits are advisory evidence only (`PfamDomainAdapter`, opt-in via `--pfam`).
- [x] The ranking is bit-for-bit reproducible across separate processes.
- [x] Missing external tools must be visible as unavailable, not silently ignored.

## 2. Non-Negotiable Rules

- Keep `BioLabExplorerCore` independent from SwiftUI.
- Do not put scoring constants in view code.
- Keep sample datasets synthetic or clearly marked as bundled examples.
- Any future network download, external API call, publication, or database write must be opt-in.
- Any future integration with biosecurity-sensitive workflows must require an explicit safety review.
- Never accumulate a floating-point value by iterating a `Dictionary` or `Set`.
  Swift seeds its hashing per process, so the terms are summed in a different
  order in every run and the result drifts by an ULP. Sort first.
  `shannonEntropy` broke this and moved `confidenceScore` between runs;
  `Tests/perpetual/test_determinism.sh` compares separate processes to catch a
  regression.
- Advisory evidence must not reach `noveltyScore`, `confidenceScore`,
  `machineLoadScore`, `classification`, or `DiscoveryValidator`. Both adapter
  tests compare an enriched run to a plain one and fail if a score moved.
- A new external tool degrades to a reported run note. Never a failed run, never
  a silent skip. Model it on `PfamDomainAdapter.availability()`: the reason
  string must tell the user what to do next.
- Input transformations are reported, never silent. The parser removes alignment
  gaps and a terminal stop, and says so; internal stops, unsupported residues and
  nucleotide FASTA fail loudly.
- No machine-specific constant in `config/worker.json`. Hardware-dependent keys
  are `"auto"` and resolved by `scripts/host_profile.py`; add a rule and a
  synthetic-host test rather than a value tuned to one workstation.
- The app must reach a result through the same pipeline as the CLI. Imported
  files go through `DiscoveryPipeline.run`; in-memory ranking shares the optional
  adapters through `DiscoveryPipeline.enrich`.

## 3. Public Repository

This project is public under MIT (`LICENSE`). `README.md` is the user-facing
entry point, `CONTRIBUTING.md` states what gets a change rejected, and
`SECURITY.md` carries the biosecurity scope policy. Keep all three honest: if a
guarantee stops holding, change the document in the same commit that breaks it.
