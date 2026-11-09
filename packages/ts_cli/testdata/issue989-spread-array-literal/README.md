# All-spread array literal oracle (#989)

An array literal whose elements are all spreads of non-tuple arrays has the
spread's own array type; it is not a fresh element-wise literal. TypeScript
reports the whole value against the target, with the array types and a nested
element explanation, while Home reduced the error to the first incompatible
spread element — and in an argument position reported TS2322 at that element
where TypeScript reports TS2345 at the argument.

Run TypeScript 5.7.3 and Home from this directory with
`-p tsconfig.json --pretty false --noEmit`; the `test-tsc-streams` step
compares stdout, stderr and exit status exactly.

`spread.ts` has three groups. The whole-value group covers one spread, two
spreads, a spread union (`(string | number)[]`), an `Iterable`, a `Set`, an
asserted array, a readonly target, and the argument position that pins the
diagnostic code. The positional group covers the shapes that keep Home's
existing per-element reporting: a leading or trailing fixed element, a spread
of an array literal in either position, and a plain element. The clean group
covers a matching element type, an empty literal and a string spread.

A tuple spread (`[...pair]`) also keeps the positional reporting, because the
result is itself a tuple; it is not pinned here, since Home still reports one
diagnostic per tuple position where TypeScript reports only the first.

[Issue #989](https://github.com/home-lang/home/issues/989) tracks this work.
