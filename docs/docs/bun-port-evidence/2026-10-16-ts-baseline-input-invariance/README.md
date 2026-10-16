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

## Follow-on: comparison mode and fixture read failures

The selected ES5 target previously enabled its TS5107 option diagnostic only when exact-baseline comparison was requested. That made the comparison mode an executable compiler input. The flag now follows the selected target alone. The new control failed on the coarse-comparison variant before the fix and passes for both comparison modes afterward. Upstream typescript-go skips selected ES5 fixtures, so this control establishes option-input invariance; it does **not** count an ES5 corpus fixture as a passing compiler case.

Selected fixture reads also had four silent `catch continue` exits: open, stat, allocation and read failures. A short read could remove a fixture from the aggregate entirely. Those errors now fail corpus loading; a short read returns `UnexpectedEndOfFile`, and its partial buffer is freed. The file closes before variant enumeration. A deterministic one-byte-file/two-byte-read control covers the short-read path, while the configured-variant loader control covers the ordinary path. Loader failure is a failing run, not a per-fixture result; per-fixture failure records remain open work under #841/#832.

The ES5 comparison-mode and short-read controls each report **2/2 passing tests** on pinned Zig 0.17 and Zig 0.18. Guarded tree-footprint peaks were 438/411 MB for ES5 and 280/280 MB for short-read controls (0.17/0.18). The ordinary configured-variant loader control reports **2/2** on 0.17 at 317 MB; the earlier baseline-availability control still reports **2/2** at 328 MB. All runs kept the 3,840 MB ceiling and ran serially. These focused results do not replace the unfinished full-corpus survey or the earlier 180-second broader-filter timeout.
