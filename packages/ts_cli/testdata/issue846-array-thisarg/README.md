# Imported array callback `thisArg` parity (#846, #960)

`owner.js` exports a JSDoc `ReadonlyArray<number>` and a mutable `number[]`.
Only `main.ts` is an explicit root; the JavaScript owner is admitted through
its import. Both `checkJs` modes call `map`, `forEach`, `every`, `some`,
`findIndex`, and `findLastIndex` with a second `thisArg` on both arrays.

TypeScript 5.7.3 accepts those 12 calls and reports only TS2322 at
`main.ts(17,7)` for assigning a mapped number to string, then TS2554 at
`main.ts(18,50)` for a third argument. Home's exact CLI stream test pins
both lines, empty stderr, and exit 2 in each mode. The local checker test
also checks readonly and mutable receivers, positive two-argument calls,
and the assignment/arity negatives.

This patch models methods whose TypeScript 5.7.3 declaration uses
`thisArg?: any`. It does not claim `flatMap`'s separate generic
`This` parameter, `every`'s type-predicate overload, or the complete
`ReadonlyArray<T>` surface are implemented; those remain open under #960.
