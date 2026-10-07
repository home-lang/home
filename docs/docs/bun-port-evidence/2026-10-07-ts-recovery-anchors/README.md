# Recovery semantics and JSDoc declaration anchors

This batch restores the four exact mismatches recorded at `02517756a`:
`decoratorOnClassMethod12`, `asyncFunctionDeclarationParameterEvaluation`,
`classCanExtendConstructorFunction`, and `parserCastVersusArrowFunction1`.
The unchanged uninterrupted leading prefix is now 3,020/3,020 exact matches,
with zero failures and zero skips. Full Bun parity and the remaining TypeScript
corpus refresh are still open.

Decorator arity checks, computed binding keys, and repeated-variable recovery
now recognize the internal any-like recovery marker. Genuine non-callable
decorators, invalid computed keys, and incompatible declarations retain their
diagnostics.

JSDoc type leaves share their enclosing declaration's HIR anchor. Recording an
invalid leaf previously replaced that declaration's complete type with
`unmodeled`, destroying function signatures and array-length inference.
JSDoc recovery now records its origin without overwriting the owner. The
regression requires the original TS2749 and one HM9002 origin, a numeric result,
and rejection of assignment to `string`.

Verified gates on the frozen source:

- focused controls: 5/5;
- unchanged four upstream targets: 4/4 exact;
- complete checker: 4,477/4,477;
- normal conformance: 1,432/1,432, including 16/16 smoke, 86/86 category, and
  586/586 baseline-aware cases;
- uninterrupted exact prefix: 3,020/3,020, zero skips, 1,404 MB peak;
- stripped ReleaseFast compiler: 3/3 build steps, 3,041 MB peak.
- two byte-pinned Zod runs: 106 production files, 196 TS diagnostics and exactly
  3/3 HM9002 each, normalized-identical output, 902/943 MB peaks;
- next unchanged window (`START=3020 LIMIT=200`): 198/200 exact, zero skips;
  `overloadTag2` and `checkJsdocTypeTag5` fail and remain the next frontier.

All heavy commands use `scripts/run-bounded.pl` with the normal machine lock
and 3,840 MB ceiling. No upstream fixture, baseline, deadline, skip, TODO, or
ratchet ceiling was changed.

Reproduce the complete prefix after initializing the pinned recursive
submodules:

```sh
source scripts/home-bin.sh
HOME_TS_CONFORMANCE_FULL=1 HOME_TS_CONFORMANCE_EXACT=1 \
HOME_TS_CONFORMANCE_START=0 HOME_TS_CONFORMANCE_LIMIT=3020 \
HOME_RUN_MAX_MB=3840 run_bounded 900 zig build test \
  -Dfilter=ts_conformance -Dts-conformance-test-filter=opt-in --summary all
```

The manifest retains source pins, source hashes, and hashes of the compressed
raw logs. The initial four-failure evidence remains in the adjacent
`2026-10-07-ts-survey-gates` bundle.
