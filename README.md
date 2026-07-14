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

## Perpetual Discovery Worker (M1, offline)

Consumes FASTA batches in `state/inbox/` and records every processed sequence into a
local SQLite seen-set ledger (`discoveries/ledger.db`), flagging actionable ones and
regenerating `discoveries/DISCOVERIES.md` from it. Offline only; local-only outputs.

```sh
swift build -c release
cp your_batch.fasta state/inbox/
scripts/run_discovery_cycle.sh
scripts/discovery_status.sh
```

Guardrails: `state/STOP` stops gracefully; the cycle pauses under `diskFloorGB`/`maxWorkspaceBytes`
(config/worker.json) and aborts if the reference digest ≠ `config/approved_manifest.json`.
A single-instance lock (`state/.lock`) prevents overlap. Tests: `bash Tests/perpetual/run_all.sh`.

## Perpetual Discovery Worker (M2, daemon)

Run the offline cycle continuously via launchd (back-to-back, min spacing
`throttleSeconds`). Falls back to the same guardrails; N consecutive failures
(`maxConsecutiveFailures`) trip a circuit breaker (`state/PAUSED`).

```sh
swift build -c release
scripts/discovery_agent.sh install     # load the launchd agent
scripts/discovery_agent.sh status      # loaded? paused? + discovery status
scripts/discovery_agent.sh resume      # clear PAUSED + failure streak
scripts/discovery_agent.sh uninstall   # true stop (unload + remove)
```

`state/STOP` pauses cycles without unloading; true stop is `uninstall`.

## Perpetual Discovery Worker (M3, network rotation — opt-in)

To keep finding NEW candidates, enable UniProt fetching (cursor-paged, one page/cycle):

1. Set `enableNetwork: true` in `config/worker.json`.
2. Ensure `config/approved_manifest.json` matches BOTH the curated reference AND
   `config/query_rotation.json` (digests).
3. Install the daemon: `scripts/discovery_agent.sh install`.

```sh
scripts/discovery_agent.sh install
```

Because `enableNetwork` is true, `install` bakes `ALLOW_NETWORK=1` into the generated launchd
plist's `EnvironmentVariables`, so the installed daemon fetches a page whenever the inbox is
empty each cycle — `install` prints `mode=NETWORKED` to confirm. Leave `enableNetwork: false`
for an offline daemon (`install` prints `mode=offline`); its plist never sets `ALLOW_NETWORK`.

Manual alternative — run a single networked cycle by hand, without installing the daemon:

```sh
ALLOW_NETWORK=1 scripts/run_discovery_cycle.sh    # one networked cycle (manual, one-shot)
```

Envelope: never hits the network unless `ALLOW_NETWORK=1` AND the host is `uniprotHost`;
rate-limited; fail-closed if the manifest is absent or the reference/query digests don't match.
The approved query set lives in `config/query_rotation.json` — editing it requires re-approving
the manifest digest (biosecurity scope control).

## Perpetual Discovery Worker (M4, dashboard)

Every cycle regenerates a self-contained `discoveries/dashboard.html` (open it in a
browser): stat tiles, new-candidates-per-cycle chart, discoveries table, and an
interactive **3D protein viewer coloured by pLDDT** for candidates with an AlphaFold
structure. The 3D viewer needs a locally-vendored 3Dmol.js (CDN is not used at runtime):

```sh
ALLOW_NETWORK=1 scripts/vendor_assets.sh    # one-time: download 3Dmol.js locally
open discoveries/dashboard.html
```

Without the vendored asset the charts/table still render; the 3D section shows a note.

## Next Integration Points

- Add FASTA import.
- Improve the native reference database builder and GUI controls.
- Keep MMseqs2/Foldseek as optional acceleration/comparison adapters only.
- Add HMMER/Pfam domain adapter.
- Add LocalColabFold/Boltz job queue.
- Add optional local LLM report summarization through Ollama or llama.cpp.
