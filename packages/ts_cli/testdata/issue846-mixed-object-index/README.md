# Mixed named and indexed checked-JavaScript objects (#846)

`owner.js` declares both a concrete `known` member and a string index on
the same JSDoc object, then repeats the shape inside `nested.inner`.
TypeScript 5.7.3 reports TS2322 for the two bad indexed writes in the owner
only when `checkJs` is enabled. The TypeScript consumer gets four TS2322
errors in either mode, proving that admission and type transfer do not depend
on owner-side diagnostics.

`readonlyCounts` has a mutable concrete `known` member alongside a readonly
string index. Both `readonlyCounts.known` and `readonlyCounts['known']` are
writable; `readonlyCounts['other']` reports TS2542. `test-tsc-streams` pins
the exact sorted diagnostics and exit status for both `checkJs` modes. The
checker unit separately verifies mixed JSDoc lowering and named-property
precedence over a readonly index.
