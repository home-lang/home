#1046: literal writes in evolving-binding flow

A flow query can reach an assignment before its literal expression has a
cached HIR type. The known primitive type must participate in conditional
flow joins immediately, and later checks must not change the result. The
fixture pins number and string writes as exact diagnostic streams against
TypeScript 5.7.3.

Run `node scripts/tests/compare-issue846-oracles.mjs` after a guarded
`zig build home-tsc -j1` to compare the full stream.
