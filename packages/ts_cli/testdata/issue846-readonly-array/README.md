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

`tsconfig-jsdoc-union.json` and its no-`checkJs` control isolate JSDoc
`ReadonlyArray<number[] | string[]>` precedence across the import boundary.
Both imported element types assign to `number[] | string[]`, and their indexed
values assign to `number | string`. An invalid assignment to `boolean` yields
one TS2322 at `jsdoc-union.ts(7,7)` in both TypeScript 5.7.3 and Home, with
matching nested explanation and exit status. This is the focused CLI oracle
for [#974](https://github.com/home-lang/home/issues/974).

`tsconfig-flat.json` and `tsconfig-flat-no-checkjs.json` check default-depth
`flat()` on admitted JavaScript
readonly and mutable arrays whose elements are `number[] | string[]`.
TypeScript 5.7.3 gives the imported readonly element the type
`number[] | string[]` and returns `(number | string)[]` from `flat()` on both
surfaces. The valid result assignment succeeds; assigning the source element
or flattened result to `number[]`, and the mutable result to `boolean[]`,
reports three TS2322 diagnostics. A local readonly-array control supplies a
fourth TS2322 for its flattened result. This guards both JSDoc union precedence
([#974](https://github.com/home-lang/home/issues/974)) and the distributive
`FlatArray` element result ([#973](https://github.com/home-lang/home/issues/973)).
The `ArrayLikeOnly` control has a numeric index signature and `length` but
does not extend `ReadonlyArray`; `flat()` preserves that object. Assigning
its flattened result to `number[]` adds one TS2322 diagnostic.
Home matches the five diagnostic sites and explanations, but currently prints
the imported source union in the opposite order at line 5; that exact-stream
gap is tracked in [#975](https://github.com/home-lang/home/issues/975).

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
An explicit `<number>` callback returning the imported readonly array also
must succeed: the callback accepts `ReadonlyArray<U>` even though the method
itself returns mutable `U[]`.

An independent generic-name interaction was tracked in
[issue #962](https://github.com/home-lang/home/issues/962); the regression
below pins its resolution.

`tsconfig-flat-map-this.json` and its no-`checkJs` control exercise the
`flatMap<U, This = undefined>` signature from TypeScript 5.7.3. Both imported
readonly and mutable arrays infer callback `this` from `thisArg`; an omitted
argument defaults `this` to `undefined`, and an explicit callback `this`
annotation can supply the type instead. The fixture also checks explicit
`<U, This>` arguments and rejects a wrong `thisArg`. Both engines report only
the two intentional TS2322 diagnostics at `flat-map-this.ts(6,9)` and
`(31,6)`; the stream suite pins stdout, empty stderr, and exit 2.

`tsconfig-generic-scope.json` and its no-`checkJs` control keep an unrelated
`type Alias<U>` in scope while `flatMap` consumes both imported checked-JS and
local readonly arrays. The method must bind its own `U`, never the alias's
parameter or the `U | U[]` return union. TypeScript 5.7.3 accepts all three
valid calls and reports only the deliberately invalid `string[]` assignment
at `generic-scope.ts(9,7)`; the stream step pins that exact diagnostic in
both modes. This is the regression for #962.

`tsconfig-predicate.json` and its no-`checkJs` control test the type-predicate
overload of `filter` on admitted readonly and mutable JavaScript owners whose
elements are `number | string`. A callback asserting `value is number`
returns `number[]` on both surfaces. The ordinary truthy-value callback must
retain the original union type. TypeScript 5.7.3 and Home agree on the three
deliberate TS2322 diagnostics at `predicate.ts(5,7)`, `(8,7)`, and `(11,7)`,
with exact stdout, empty stderr, and error exit pinned by the stream suite.

`tsconfig-predicate-search.json` and its no-`checkJs` control extend the
admitted-JavaScript oracle to `find` and `findLast` on readonly and mutable
arrays. Type predicates narrow their results to `number | undefined`, while
an ordinary predicate retains `number | string | undefined`. The same control
passes a `thisArg` through `find`, `findLast`, and `filter`; both modes pin seven
deliberate TS2322 diagnostics, including the possibility that `find` returns
`undefined`, and no callback or arity errors.

`tsconfig-every-predicate.json` and its no-`checkJs` control cover the
predicate overload of `every`. A named guard narrows both imported readonly
and mutable arrays; an inline guard also narrows. A plain truthy callback
selects the ordinary overload and must leave the element union intact.
TypeScript 5.7.3 and Home report exactly four deliberate TS2322 diagnostics
at `every-predicate.ts(7,9)`, `(13,9)`, `(18,9)`, and `(23,9)` in both modes.
The stream suite pins stdout, empty stderr, and exit 2.

`tsconfig-surface.json` selects the ES2023 library and tests copying
methods on both imported readonly and mutable arrays. TypeScript 5.7.3
returns mutable `number[]` from `toReversed`, both `toSpliced` overloads,
and `with`, and accepts `toString` and `toLocaleString`. It reports two
TS2345 argument errors and one TS2322 result error; the stream step checks
their exact text, positions, order, and exit status. The second TS2345
also checks the general rule that a member-call overload set with only one
arity-compatible signature reports the argument mismatch directly.

`tsconfig-unscopables.json` and its no-`checkJs` control read the
`[Symbol.unscopables]` member declared by `lib.es2015.symbol.wellknown.d.ts`
on an imported readonly array. Its mapped flags have optional boolean
properties, including `length` and `map`, rather than array method types.
Both engines report only the deliberate TS2322 for assigning the optional
`length` flag to `number`.

`tsconfig-unscopables-mutable.json` checks the corresponding mutable array
surface. Its mapped flags include `push`, and the intentional assignment of
that optional boolean flag to `number` reports TS2322.

`tsconfig-unscopables-writes.json` checks concrete symbol-key writes on both
arrays. The outer `[Symbol.unscopables]` property is readonly in each; the
inner `length` flag is readonly only on `ReadonlyArray`.

`tsconfig-unscopables-missing.json` checks TS2339's mapped-object display for
missing flag properties on both imported array kinds. The oracle pins the
numeric index signature, declaration-order optional flags, middle elision,
and final symbol-key property in the error text.

[Issue #960](https://github.com/home-lang/home/issues/960) tracks the remaining work to model the complete TypeScript
`ReadonlyArray<T>` surface; these passing cases do not claim full parity.
