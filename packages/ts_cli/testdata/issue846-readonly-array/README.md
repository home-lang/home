# Readonly array member parity oracle (#846, #960)

`owner.js` exports both `ReadonlyArray<number>` and mutable `Array<number>`
from checked JavaScript. `main.ts` tests indexed writes, method availability,
reads, and argument types after importing them. Run TypeScript 5.7.3 and Home
from this directory with `-p tsconfig.json --pretty false`, then repeat with
`tsconfig-no-checkjs.json`.

In both modes, TypeScript exits 2 with this exact stdout:

```text
main.ts(4,1): error TS2542: Index signature in type 'readonly number[]' only permits reading.
main.ts(5,16): error TS2339: Property 'push' does not exist on type 'readonly number[]'.
main.ts(6,7): error TS2322: Type 'number' is not assignable to type 'string'.
main.ts(7,1): error TS2322: Type 'string' is not assignable to type 'number'.
main.ts(8,13): error TS2345: Argument of type 'string' is not assignable to parameter of type 'number'.
```

Home exits 2 but omits the TS2339 line, accepting
`readonlyValues.push(4)`.
The same TS2339 gap reproduces for a locally declared `readonly number[]`,
so the cause is the checker's shared array-member model rather than the
JavaScript import boundary. #960 tracks a proper readonly prototype surface.

This fixture is intentionally not wired into the green CLI stream suite
until the complete expected output passes; it documents a known parity gap
without weakening the expected diagnostics or concealing the failure.
