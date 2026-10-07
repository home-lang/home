# TypeScript iteration recovery and corpus-gate evidence

The unchanged pinned conformance prefix improved from 2,985/3,020 to
3,016/3,020 exact matches. The 31 removed mismatches were iterator cascades
after unresolved-name recovery. The four residual fixtures are listed in
`manifest.json`; both full-prefix runs exited 1. Full Bun parity remains open.

The checker now treats its `unmodeled` recovery as any-like throughout sync and
async iteration, nested loop destructuring, and element derivation, while
retaining that marker for provenance. An internal spread regression was
corrected against the pinned TypeScript 7 reference: `any | undefined` is
accepted, while the unguarded `number[] | undefined` spread still emits TS2488
at its exact source position. No upstream TypeScript or Bun fixture changed.

Explicit corpus surveys now reject missing roots and zero selected fixtures;
the compiler-family exact survey also fails on diagnostic mismatches. The
exact shell runner checks both input directories and emits build summaries.
The CI workflow initializes recursive submodules and runs ten controls against
the actual opt-in test executable.

Verified gates:

- checker: 4,473/4,473, 2,057 MB peak;
- normal conformance: 1,432/1,432, including 16/16 smoke, 86/86 category, and
  586/586 baseline-aware cases, 2,248 MB peak;
- unchanged affected upstream fixtures: 47/47, no skips;
- shell-runner controls: 4/4, under the original five-second test deadline;
- exact prefix: 3,016/3,020, four failures, no skips, 1,902 MB peak.
- stripped ReleaseFast `home-tsc`: 3/3 build steps, 2,993 MB peak;
- byte-pinned Zod twice: 106 production files, 196 TS diagnostics and 3/3 HM9002
  each, normalized-identical output, 970 MB and 914 MB peaks;
- real survey controls: 10/10, covering both missing roots, empty corpora,
  empty ranges, valid inputs, and exact mismatches.

Every heavy command used `scripts/run-bounded.pl` with its machine lock and
3,840 MB memory ceiling. The final prefix had a 900-second deadline. Earlier
attempts interrupted by disk admission/exhaustion or signals are not passes.
Rebuildable caches and inactive archive/install staging data were deleted to
restore disk headroom; pinned Bun objects and WebKit libraries were retained.

To reproduce the complete prefix, initialize the pinned recursive submodules,
source `scripts/home-bin.sh`, and run:

```sh
HOME_TS_CONFORMANCE_FULL=1 HOME_TS_CONFORMANCE_EXACT=1 \
HOME_TS_CONFORMANCE_START=0 HOME_TS_CONFORMANCE_LIMIT=3020 \
HOME_RUN_MAX_MB=3840 run_bounded 900 zig build test \
  -Dfilter=ts_conformance -Dts-conformance-test-filter=opt-in --summary all
```

For the ten controls, build that filtered artifact with neither `*_FULL`
variable enabled, then pass its `.zig-cache/o/.../test` path to:

```sh
python3 scripts/tests/test-ts-corpus-survey-controls.py --test-binary <path>
```

The compressed logs retain raw diagnostics and traces. `manifest.json` records
the source pins, source-file hashes, and hashes of each uncompressed log.
