#1044: self-references in binding defaults

An array or object binding can refer to itself in its own default expression.
TypeScript 5.7.3 reports TS7022 on the binding and TS2448 at the read for
block-scoped declarations, including `for...of` heads. The exact diagnostic
stream is compared by `scripts/tests/compare-issue846-oracles.mjs`.
