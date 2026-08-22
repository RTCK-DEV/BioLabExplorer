# Third-party notices

BioLabExplorer itself is MIT licensed (see `LICENSE`). It vendors and optionally
calls the following third-party work.

## Vendored in this repository

### 3Dmol.js 2.4.0 — BSD-3-Clause

`discoveries/assets/3Dmol-min.js`, fetched and digest-verified by
`scripts/vendor_assets.sh`. The upstream licence text is kept verbatim beside it
in `discoveries/assets/3Dmol-LICENSE.txt`.

Used to render the local protein/pose viewer in `discoveries/dashboard.html`
without contacting a CDN at runtime.

## Detected at runtime, never bundled

These are optional adapters. BioLabExplorer runs without every one of them and
reports each missing tool explicitly. Installing them is the user's decision,
and each remains under its own licence and terms.

| Tool | Role | Licence |
| --- | --- | --- |
| MMseqs2 | optional sequence search | MIT |
| HMMER (`hmmscan`, `phmmer`) | optional profile-HMM / Pfam domains | BSD-3-Clause |
| Foldseek | optional structure search | GPL-3.0 |
| OpenMM, PDBFixer | optional structure relaxation | MIT / LGPL |
| AutoDock Vina, Meeko | optional docking | Apache-2.0 / LGPL |
| Ollama | optional advisory local summaries | MIT |
| PyTorch, Transformers (ESMFold) | optional structure prediction | BSD-3-Clause / Apache-2.0 |

## Small data samples redistributed here

No bulk biological database is committed — those are fetched by opt-in,
network-gated scripts (see below). A handful of small records *are* checked in
so the quickstart and the test suite work offline, and they carry their
upstream terms:

| Path | Contents | Source | Terms |
| --- | --- | --- | --- |
| `data/curated_reference/` | curated reference FASTA (24 KB) | UniProt | CC BY 4.0 |
| `data/public_probe/unreviewed_uncharacterized_bacteria_200.fasta` | 200-sequence query set (300 KB) | UniProt | CC BY 4.0 |
| `data/alphafold_cache/`, `data/structures/` | 6 predicted structures (~2 MB) | AlphaFold Protein Structure Database, EMBL-EBI / Google DeepMind | CC BY 4.0 |
| `data/docking/penicillin_g_cid5904.sdf` | one ligand, PubChem CID 5904 | PubChem, NCBI | public domain |
| `data/examples/esmfold_smoke.fasta` | 40-residue synthetic fixture | this project | MIT |

AlphaFold DB attribution, as its terms require: Jumper et al., *Highly accurate
protein structure prediction with AlphaFold*, Nature 596, 583–589 (2021); and
Varadi et al., *AlphaFold Protein Structure Database*, Nucleic Acids Research 50,
D439–D444 (2022).

## Bulk data sources, fetched not redistributed

Each of these is downloaded by an opt-in, network-gated script and stays under
its provider's terms. None of them is committed here.

| Source | Fetched by | Terms |
| --- | --- | --- |
| UniProt (full query sets, Swiss-Prot) | `scripts/fetch_uniprot.py` | CC BY 4.0 |
| AlphaFold DB (beyond the cached samples) | `scripts/run_autonomous_discovery.sh --allow-network` | CC BY 4.0 |
| Pfam (EBI) | `scripts/setup_pfam.sh` | CC0 1.0 |
| ESMFold weights (Hugging Face) | `scripts/setup_esmfold_hf.sh` | see the model card |
