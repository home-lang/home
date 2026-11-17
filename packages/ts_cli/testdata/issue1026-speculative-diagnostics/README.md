#1026: speculative argument diagnostics

The nested conditional handler signature makes Home retry the inner argument
check. Before the fix, that retry removed an earlier diagnostic and then
panicked when it tried to shrink the list back to its former length. The retry
now uses a private diagnostic list and preserves the earlier TS7006 row.
`scripts/tests/compare-issue846-oracles.mjs` checks the exact stream against
TypeScript 5.7.3.
