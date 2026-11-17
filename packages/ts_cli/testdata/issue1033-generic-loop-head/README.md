#1033: generic calls in loop-head flow estimates

TypeScript 5.7.3 reports TS18048 for all three reads: explicit type
arguments, inferred type arguments, and an awaited `Promise.resolve` call.
The loop head must include the type assigned on a later iteration before
checking the loop body. The exact diagnostic stream is audited by
`scripts/tests/compare-issue846-oracles.mjs`.
