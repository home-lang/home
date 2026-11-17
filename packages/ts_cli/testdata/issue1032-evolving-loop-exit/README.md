#1032: a loop can leave an evolving variable untouched

The `for...of` body may never execute, so a later read joins the initial
`undefined` flow with the value assigned inside the loop. TypeScript 5.7.3
reports `number | undefined` in the resulting TS2322 diagnostic.
`scripts/tests/compare-issue846-oracles.mjs` compares the exact stream.
