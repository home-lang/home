# ConcatArray structural parity (#1059)

This fixture checks `concat` overload resolution for mutable and readonly
arrays against TypeScript 5.7.3. An index-only object lacks the required
`join` and `slice` methods of `ConcatArray<T>`; an object with the full shape
is accepted. Mixed element arrays check the nested TS2769 diagnostic span.

Run `node scripts/tests/compare-issue846-oracles.mjs` to compare the complete
diagnostic stream with the pinned TypeScript and tsgo oracles.
