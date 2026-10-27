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

Home now matches all five lines and exit status in both modes. The
`test-tsc-streams` step compares stdout, stderr, and exit status exactly.

`tsconfig-local.json` is a TypeScript-only control for local readonly member
lookup, indexed write, and `keyof`. It expects TS2339, TS2542, and TS2322
in that order, with exact streams and exit status checked by the same step.

`tsconfig-augmentation.json` checks that adding `firstOrUndefined` to
`ReadonlyArray<T>` does not add it to mutable `Array<T>`, while readonly
arrays still exclude `push`. It expects two TS2339 diagnostics.

`tsconfig-callback.json` checks that a `map` callback receives a readonly
array rather than a mutable one. It expects TS2339 for `array.push` and
TS4104 when assigning the callback array to `number[]`.

[Issue #960](https://github.com/home-lang/home/issues/960) tracks the remaining work to model the complete TypeScript
`ReadonlyArray<T>` surface; these passing cases do not claim full parity.
