# Rest overload diagnostics (#1058)

`choose` has rest-only overloads; `withPrefix` has a fixed argument followed
by a rest parameter. The failing calls prove overload diagnostics inspect
arguments beyond the fixed prefix, including array and spread arguments. The
remaining calls are valid controls.

The same traversal is used by mutable and readonly `concat`, but the
synthetic `ConcatArray<T>` surface has a separate diagnostic-name and
array-element ownership gap tracked in #1059.

`scripts/tests/compare-issue846-oracles.mjs` compares the complete stdout,
stderr, and exit status with TypeScript 5.7.3 using this project config.
