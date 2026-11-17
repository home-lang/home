#1029: evolving flow stays in its function

The fallback flow search must not use a same-named evolving declaration or
write from another function. This case has no diagnostics in TypeScript 5.7.3.
An instance field can also capture a later `let` in its enclosing function;
the scope filter must retain that binding without borrowing one from a
previous function.
`scripts/tests/compare-issue846-oracles.mjs` compares the exact stream.
