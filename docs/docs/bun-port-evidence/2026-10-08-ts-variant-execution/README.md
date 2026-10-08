# TypeScript conformance variant execution

This checkpoint ports the pinned TypeScript runner's file-based variation
algorithm instead of selecting one available expected baseline. Multi-valued
boolean and enum directives now form a Cartesian product, configured names use
sorted lower-case `key=value` suffixes, aliases are deduplicated by their
compiler-option value, `*` and `!`/`-` exclusions are honored, and more than 25
configurations is rejected exactly as upstream does.

Each selected configuration gets independently materialized scalar directive
values before Home derives strictness, target, module, module resolution, JSX,
and other supported compiler behavior. Expected `.errors.txt` contents are read
only after the executable input has been selected. Mutating expected diagnostic
text therefore cannot change the variant count, case names, source bytes,
compiler options, or diagnostic path. A missing error baseline means that
specific configured case expects no errors; it no longer makes the case
disappear.

The reference is the nested TypeScript pin
`5848bc5157b22ff7f4e3369f4645a514a433b15f`:

- `src/harness/harnessIO.ts`: `splitVaryBySettingValue`,
  `computeFileBasedTestConfigurationVariations`, and
  `getFileBasedTestConfigurations`;
- `src/testRunner/compilerRunner.ts`: `CompilerTest.varyBy` and configured-name
  construction.

## Guarded verification

All substantial commands ran serially through `scripts/run-bounded.pl` with
`HOME_RUN_MAX_MB=3840`.

- Standalone variation algorithm: **5/5 tests passed**, 168 MB peak.
- Loader controls: a two-axis fixture produces **4/4 distinct configured
  inputs**; a second two-axis fixture remains input-identical after replacing
  all expected diagnostic text. Both controls pass.
- Pinned real target matrix:
  `emitRestParametersFunction(target=es5)` and
  `emitRestParametersFunction(target=es2015)` both execute. Together with the
  separate `emitRestParametersFunctionES6` fixture, exact comparison passes
  **3/3**, 2,149 MB peak.
- Named local category gate: **87/87 passed**, 2,036 MB peak. The previous
  86-case assertion had collapsed
  `equalityWithtNullishCoalescingAssignment`'s `strict=true,false` matrix into
  one case; the two variants both pass.
- Variant, matrix, no-content-diff, and exact configured-baseline unit filters
  all pass, each below 300 MB.

Two broader attempts are retained as non-results: the complete conformance
package reached its unchanged 900-second wall limit (exit 124) without a final
summary, and the baseline-aware survey reached the unchanged 3,840 MB ceiling
(exit 125) without a final summary. Neither earns passing-case credit and no
partial aggregate is published.

This closes the one-variant selection defect but does not close
[#841](https://github.com/home-lang/home/issues/841): root-file admission and
real default-library/compiler-API input fidelity remain open. Complete corpus
evidence remains open in [#832](https://github.com/home-lang/home/issues/832),
and full Bun acceptance remains open in
[#66](https://github.com/home-lang/home/issues/66).
