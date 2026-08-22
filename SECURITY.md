# Security and responsible use

## Reporting a vulnerability

Report security issues through GitHub's private vulnerability reporting
("Report a vulnerability" on the Security tab). Please do not open a public
issue for anything exploitable. Include the version or commit, the platform, and
a reproduction. Expect a first reply within about a week; this is a
single-maintainer project, not a funded one.

## What this project does and does not do

BioLabExplorer ranks protein sequences by how weakly annotated and how
structurally interesting they look, so a human can decide what is worth
studying. It is a prioritisation aid. It does not design sequences, does not
predict function, and its scores are not evidence of biological activity.

Every default workflow is local and offline. Network access requires an explicit
`--allow-network` or `ALLOW_NETWORK=1`, is restricted to a configured host, and
is fail-closed when the approval manifest is missing or its digests do not match.

## Biosecurity scope control

Networked candidate fetching is gated by `config/approved_manifest.json`, which
pins:

- the SHA-256 of the curated reference FASTA,
- the SHA-256 of the approved query set (`config/query_rotation.json`),
- a named human reviewer and review date,
- a non-empty exclusion list.

The checked-in manifest excludes virulence factors, toxin biosynthesis gene
clusters, and select-agent homologs, and scopes queries to uncharacterized
bacterial proteins. Changing the reference or the query set changes a digest,
which fails the cycle until a human re-reviews and re-approves the manifest.
That gate is the point: **if you fork this project and change the query scope,
you are the reviewer, and the exclusions are yours to justify.**

Do not use this project to search for, prioritise, or characterise select
agents, toxins, or virulence determinants. Removing the exclusions or disabling
the manifest check in order to do so is outside the intended use of this
software, and outside what the maintainer will support or accept contributions
for.

## Third-party data and tools

No bulk biological database is redistributed here; a few small UniProt,
AlphaFold and PubChem records are checked in so the quickstart and the tests
work offline. Optional adapters shell out to tools you install yourself. See
`THIRD_PARTY_NOTICES.md` for what is vendored, what is redistributed, what is
only detected, and the terms attached to each.

## Advisory LLM output

The optional `--summarize` path runs a local model through Ollama and stores its
text as `advisorySummary`, always accompanied by a disclaimer. It is wording
only: it never feeds a score, a classification, or the validation verdict, and
it can be wrong. No cloud LLM is contacted on any code path.
