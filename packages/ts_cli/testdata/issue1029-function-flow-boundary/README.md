#1029: evolving flow stays in its function

The fallback flow search must not use a same-named evolving declaration or
write from another function. This case has no diagnostics in TypeScript 5.7.3.
`scripts/tests/compare-issue846-oracles.mjs` compares the exact stream.
