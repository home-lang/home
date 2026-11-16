#1045: constrained arithmetic operands

TypeScript 5.7.3 permits arithmetic on a type parameter constrained to
`number` or `bigint`, but a compound assignment must still check the widened
result against the original type parameter. The fixture also keeps an
unconstrained operand invalid and verifies that an update expression does not
receive the compound assignment error.

Run `node scripts/tests/compare-issue846-oracles.mjs` after a guarded
`zig build home-tsc -j1` to compare the exact diagnostic stream.
