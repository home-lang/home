# Nested checked-JavaScript object constraints (#846)

`main.ts` imports an object whose JSDoc type contains a nested object and
an array. TypeScript 5.7.3 reports exactly four consumer errors: a wrong
nested write, a wrong nested read, a readonly nested write, and a wrong
array-method argument. Valid writes and reads remain accepted. The result
is the same with `checkJs` enabled and disabled because both modes use the
admitted owner's JSDoc type for the TypeScript consumer.

The owner must not acquire a spurious TS2741. Its nested `name` member
belongs to `inner`, not to the outer object; splitting the JSDoc body at
every semicolon or comma loses that boundary. `test-tsc-streams` pins both
exact TypeScript outputs, and the checker unit pins depth-aware splitting.
