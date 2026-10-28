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

`tsconfig-entries.json` checks the `[number, T]` tuple yielded by `entries()`
on both admitted checked-JavaScript readonly and mutable arrays. TypeScript
5.7.3 reports exactly three TS2322 errors when the numeric index or element
is assigned to `string`; Home now preserves those types instead of treating
the iterator values as `any`. The stream step pins all three locations,
messages, and exit status.

`tsconfig-concat.json` checks that readonly arrays can be concatenated into
either readonly or mutable receivers while the result remains a mutable
`number[]`. Its invalid result assignment must elaborate the array *element*
mismatch directly. A local array-literal control keeps its element-site
errors; a structural numeric-index interface control retains the distinct
`'number' index signatures are incompatible` chain. The exact TypeScript
5.7.3 streams and exit code are pinned in `test-tsc-streams`.

`tsconfig-flat-map.json` checks generic inference when a callback returns
either a scalar or an admitted readonly array, as well as the `T[]` callback
array parameter declared for `flatMap` in TypeScript 5.7.3's
`lib.es2019.array.d.ts`. Both calls must succeed; only assigning the
resulting `number[]` to `string[]` reports TS2322. The stream step pins the
exact location, elaboration and exit status with both `checkJs` settings.
An independent generic-name interaction was tracked in
[issue #962](https://github.com/home-lang/home/issues/962); the regression
below pins its resolution.

`tsconfig-generic-scope.json` and its no-`checkJs` control keep an unrelated
`type Alias<U>` in scope while `flatMap` consumes both imported checked-JS and
local readonly arrays. The method must bind its own `U`, never the alias's
parameter or the `U | U[]` return union. TypeScript 5.7.3 accepts all three
valid calls and reports only the deliberately invalid `string[]` assignment
at `generic-scope.ts(9,7)`; the stream step pins that exact diagnostic in
both modes. This is the regression for #962.

`tsconfig-surface.json` selects the ES2023 library and tests copying
methods on both imported readonly and mutable arrays. TypeScript 5.7.3
returns mutable `number[]` from `toReversed`, both `toSpliced` overloads,
and `with`, and accepts `toString` and `toLocaleString`. It reports two
TS2345 argument errors and one TS2322 result error; the stream step checks
their exact text, positions, order, and exit status. The second TS2345
also checks the general rule that a member-call overload set with only one
arity-compatible signature reports the argument mismatch directly.

[Issue #960](https://github.com/home-lang/home/issues/960) tracks the remaining work to model the complete TypeScript
`ReadonlyArray<T>` surface; these passing cases do not claim full parity.
