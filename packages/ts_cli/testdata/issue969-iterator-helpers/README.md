# Iterator helper parity oracle (#969)

TypeScript 5.7.3 declares the iterator helpers on `IteratorObject<T, TReturn,
TNext>` in `lib.esnext.iterator.d.ts`, not on `Array<T>`. `values()` returns
`ArrayIterator<T>`; every helper that yields another iterator returns
`IteratorObject<T, undefined, unknown>`, and only `toArray()` produces an
array. Run TypeScript 5.7.3 and Home from this directory with
`-p <config> --pretty false --noEmit`; the `test-tsc-streams` step compares
stdout, stderr, and exit status exactly.

`tsconfig.json` (`main.ts`) is the original chain control: `filter` keeps the
yielded element type, `map` retypes it, `toArray` ends the chain, and the
direct `array.toArray()` must still be TS2339 because `Array<T>` has no such
method.

`tsconfig-helpers.json` (`helpers.ts`) exercises every helper with a correct
annotation: `map`, `filter`, `take`, `drop`, `flatMap`, both `reduce` forms
plus the separate accumulator type, `find`, `some`, `every`, `forEach` and the
readonly `[Symbol.toStringTag]`. Both engines report nothing and exit 0.

`tsconfig-wrong.json` (`wrong.ts`) pins each helper's result type through a
deliberate mismatch: twelve TS2322 diagnostics covering the `T[]` of
`toArray`, the accumulator of `reduce`, `find`'s `T | undefined`, the `boolean`
of `some`, the `void` of `forEach`, and the
`IteratorObject<number, undefined, unknown>` display of `take`, `map` and
`filter`.

`tsconfig-errors.json` (`errors.ts`) pins the arity and member diagnostics:
TS2554 for `take()`, `map()` and `reduce()` — the last with its `1-2`
argument range — TS2339 naming the `ArrayIterator<number>` receiver, and
TS2322 for assigning `[Symbol.toStringTag]` to `number`.

`tsconfig-guards.json` (`guards.ts`) covers the type-predicate overloads of
`filter` and `find`: a named guard and an inline guard both narrow the yielded
element, so all three annotations hold and both engines report nothing.

[Issue #969](https://github.com/home-lang/home/issues/969) tracks the
remaining work; these passing cases do not claim full `IteratorObject`
parity. In particular Home does not yet gate the helpers on the selected
library, so a program built with `lib: ["es2023"]` still resolves them where
TypeScript reports TS2339.
