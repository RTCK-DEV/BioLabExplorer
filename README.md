# BioLabExplorer

BioLabExplorer is a local-first macOS prototype for semi-automated scientific prospecting. The first MVP focuses on protein-sequence discovery: it ranks synthetic environmental protein candidates by novelty, machine-load value, structural-interest proxies, and evidence quality.

The app does not depend on cloud LLMs. External tools such as MMseqs2, HMMER, Foldseek, and Ollama are optional adapters. If they are missing, the app shows that status and still runs the bundled deterministic sample pipeline.

## Current MVP

- Native SwiftUI GUI.
- Deterministic local candidate ranking.
- Built-in synthetic protein dataset and a cached public-probe workflow.
- Explicit runtime tool readiness checks.
- JSON and Markdown report export.
- Autonomous discovery script that runs checks, candidate discovery, structure validation, achievement reporting, and app packaging.
- Executable checks for scoring, parsing, report writing, validation, and tool probing.

## Build

```sh
swift build
```

## Run

```sh
swift run BioLabExplorer
```

## Test

```sh
swift run BioLabExplorerChecks
```

## Run the Autonomous Discovery Workflow

This is the main end-to-end workflow. It runs local checks, analyzes the cached 200-sequence UniProt unreviewed/uncharacterized bacterial query set, validates the top actionable candidate with Swift-native C-alpha distance-map comparison, writes an achievement report, and packages the macOS app.

By default it uses only local files and the local AlphaFold cache. If the public probe FASTA or AlphaFold structures are missing, it fails with the missing path instead of silently downloading data.

```sh
scripts/run_autonomous_discovery.sh
```

To explicitly allow public UniProt/AlphaFold reads for missing cache files:

```sh
scripts/run_autonomous_discovery.sh --allow-network
```

## Run the Public Discovery Probe

This uses a 200-sequence UniProt unreviewed/uncharacterized bacterial query set and the local curated reference FASTA in `data/curated_reference/pbp_pks_reference.fasta`. The default path uses Swift-native k-mer search, writes JSON/Markdown reports, and fails if no actionable discovery candidate is found.

```sh
scripts/run_public_probe.sh
```

After a public probe run, validate the top actionable candidate at the structure level with Swift-native C-alpha distance-map comparison and the local AlphaFold cache:

```sh
swift run BioLabExplorerStructureCheck --run runs/public_probe_20260708_validated --cache data/alphafold_cache
```

Latest verified autonomous output in this workspace:

```text
runs/autonomous_discovery_20260708_gui_bundle/automation-achievement.md
runs/autonomous_discovery_20260708_gui_bundle/discovery-report.md
runs/autonomous_discovery_20260708_gui_bundle/discovery-validation.json
runs/autonomous_discovery_20260708_gui_bundle/native_structure_summary.md
```

## Package a Local App Bundle

```sh
scripts/package_app.sh
```

The generated app bundle is written to `dist/BioLab Explorer.app`.

## Next Integration Points

- Add FASTA import.
- Improve the native reference database builder and GUI controls.
- Keep MMseqs2/Foldseek as optional acceleration/comparison adapters only.
- Add HMMER/Pfam domain adapter.
- Add LocalColabFold/Boltz job queue.
- Add optional local LLM report summarization through Ollama or llama.cpp.
