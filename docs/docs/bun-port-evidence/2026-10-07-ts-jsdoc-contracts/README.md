# JSDoc contracts and mutable field inference

The unchanged `overloadTag2` and `checkJsdocTypeTag5` fixtures now match their
exact upstream baselines. Their 200-fixture window improves from 198/200 to
200/200. An uninterrupted leading-prefix run verifies 3,220/3,220 exact matches
with zero failures and zero skips. Full Bun parity and the remaining TypeScript
corpus refresh remain open.

Unannotated mutable class fields now apply the same fresh-literal widening rule
as mutable variables. This preserves `readonly`, explicit annotation and
`as const` contracts while allowing a mutable conditional initializer to infer
`number | string` instead of `1 | "1"`.

JSDoc contracts retain diagnostic ownership. Declarations and expression-bodied
arrows check their returned values; owner-typed block arrows and function
expressions infer their actual signatures and are checked once at the owning
variable. Explicit return tags still check the body. Object call-signature
JSDoc now preserves parameter names in diagnostic rendering.

The controls use the pinned native TypeScript 7.0.2 compiler as a reference and
require diagnostic positions, genuine readonly/const errors, and named target
signatures. No upstream fixture, baseline, deadline, skip, TODO, or ratchet
ceiling was changed.

Verified semantic gates:

- focused controls: 4/4;
- unchanged upstream targets: 2/2 exact;
- complete 200-fixture window: 200/200 exact;
- checker: 4,480/4,480, 2,058 MB peak;
- normal conformance: 1,432/1,432, including 16/16 smoke, 86/86 category and
  586/586 baseline-aware cases, 2,065 MB peak;
- uninterrupted prefix: 3,220/3,220, zero skips, 1,629 MB peak.
- stripped ReleaseFast compiler: 3/3 steps, 2,920 MB peak;
- two pinned Zod runs: 106 files, 196 TS diagnostics and 3/3 HM9002 each,
  normalized-identical output, 957/951 MB peaks;
- subsequent unchanged window `START=3220 LIMIT=200`: 200/200 exact;
- next window `START=3420 LIMIT=200`: 198/200, zero skips, correctly exits 1;
  `typeOnlyMerge2` and `computedPropertyName` remain the next frontier.

Every heavy command used the normal machine lock and 3,840 MB ceiling. The full
prefix had a 900-second deadline. After initializing recursive pinned
submodules, reproduce it with:

```sh
source scripts/home-bin.sh
HOME_TS_CONFORMANCE_FULL=1 HOME_TS_CONFORMANCE_EXACT=1 \
HOME_TS_CONFORMANCE_START=0 HOME_TS_CONFORMANCE_LIMIT=3220 \
HOME_RUN_MAX_MB=3840 run_bounded 900 zig build test \
  -Dfilter=ts_conformance -Dts-conformance-test-filter=opt-in --summary all
```

The manifest records source pins and hashes. Compressed logs retain the raw
diagnostics and complete prefix trace. The initial two-failure window remains
in the adjacent `2026-10-07-ts-recovery-anchors` evidence bundle.
