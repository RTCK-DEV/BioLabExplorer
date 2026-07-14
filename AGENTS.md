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
- Heavy/integration test command: `scripts/run_autonomous_discovery.sh`
- Known external dependencies:
  - Optional runtime tools: `mmseqs`, `hmmsearch`, `foldseek`, `ollama`
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
- [x] LLM-generated summaries, if added later, are advisory text only.
- [x] Missing external tools must be visible as unavailable, not silently ignored.

## 2. Non-Negotiable Rules

- Keep `BioLabExplorerCore` independent from SwiftUI.
- Do not put scoring constants in view code.
- Keep sample datasets synthetic or clearly marked as bundled examples.
- Any future network download, external API call, publication, or database write must be opt-in.
- Any future integration with biosecurity-sensitive workflows must require an explicit safety review.
