#1031: enum member flow in reads and diagnostics

A variable declared as a numeric enum retains the member assigned to it.
Both annotated and inferred declarations report `E.A` against `E.B`, matching
TypeScript 5.7.3. `scripts/tests/compare-issue846-oracles.mjs` compares the
exact diagnostic stream.
