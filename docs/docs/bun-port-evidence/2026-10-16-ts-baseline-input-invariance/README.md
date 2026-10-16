# Conformance options independent of baseline availability

This is one input-fidelity repair for [#841](https://github.com/home-lang/home/issues/841), not a full conformance claim. The loader already enumerated fixture variants and materialized each selected directive, but then derived several compiler options from whichever expected `.errors.txt` or `.js` baseline happened to exist. A missing baseline therefore changed execution inputs instead of just expectations.

`buildVariantCorpusEntry` now takes strictness, target, module, module resolution, `allowImportingTsExtensions`, package deduplication and upstream unsupported-option classification from the selected fixture suffix and materialized source. Baselines remain inputs only to expected diagnostic text and whether an error is expected. The redundant `.js` baseline existence probe is gone. The legacy `baseline_module_*` field names remain for API compatibility; their values now come from the selected variant, not a baseline file.

The independent control loads a two-axis, four-variant fixture twice: once without baselines and once with an expected-error baseline for one variant plus a `.js` emit baseline for another. It compares configured source, module kind, extension-import option and skip classification across both loads while confirming that the expected-error status changes. Before the repair it failed because the no-baseline module kind was empty and the baseline-backed one was `commonjs`; after the repair it passes. This establishes the baseline-availability property for the controlled settings, not full fixture/library routing fidelity.

Verification on Zig `0.17.0-dev.2163+89ff10d56`, with one `run_bounded` process at a time and `HOME_RUN_MAX_MB=3840`:

- New baseline-availability control: **2/2 reported tests passed**, 328 MB peak sampled tree footprint after the final test edit. The prior red run failed at the module-kind comparison.
- The same control on Zig `0.18.0-dev.146+35accc06e`: **2/2 reported tests passed**, 425 MB peak sampled tree footprint.
- Configured-variant loader, unsupported-option classifier, target selection and TS7 strictness/config layering: **2/2 reported tests passed per focused filter**, with guarded peaks of 385, 418, 282 and 399 MB respectively.
- Wider `corpus inputs` filter: **no result**; it exceeded its unchanged 180-second wall bound (exit 124). No aggregate or passing credit is inferred from that attempt.
- `zig fmt --check` on the edited source and Pickier on the two new evidence files passed. Repository-wide Pickier did **not** pass: it reported 1,858 errors and 725 warnings across unrelated files; no lint-success claim is made for the repository.

Unresolved #841 work includes real package/library declarations, root-file and virtual-file routing, the remaining baseline/input dependencies and complete corpus evidence. Full Bun parity remains open in [#66](https://github.com/home-lang/home/issues/66).
