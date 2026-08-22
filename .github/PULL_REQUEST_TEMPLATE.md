## What this changes

<!-- One paragraph. Link the issue if there is one. -->

## Verification

```
swift run BioLabExplorerChecks
bash Tests/perpetual/run_all.sh
```

<!-- Paste the tail of the suite output, or say which tests skipped and why. -->

## Guarantees checklist

- [ ] Ranking is still bit-for-bit reproducible across processes
      (`Tests/perpetual/test_determinism.sh` passes).
- [ ] No floating-point value is accumulated by iterating a `Dictionary` or `Set`.
- [ ] Any new external tool is optional and degrades to a reported run note.
- [ ] No advisory evidence (domains, LLM text) changes a score, a
      classification, or the validation verdict.
- [ ] No new network access outside an `ALLOW_NETWORK` / `--allow-network` gate
      with a pinned host and a verified digest.
- [ ] No machine-specific constant committed to `config/worker.json`
      (use `"auto"` plus a rule in `scripts/host_profile.py`).
- [ ] `BioLabExplorerCore` still imports no SwiftUI.
- [ ] Tests added or updated.

## What I did not verify

<!-- Be specific. "No NVIDIA GPU, so the CUDA path is untested" is useful. -->
