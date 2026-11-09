# Entry tuple oracle (#988)

`Array.prototype.entries()` yields `[number, T]` and `Set.prototype.entries()`
yields `[T, T]` — tuples of exactly two elements. Both were built without
being recorded as tuples, so their fixed length was unknown and they rendered
and related as a tuple with a trailing rest element whose type was the union
of their own members (`[number, number, ...number[]]`,
`[number, string, ...(string | number)[]]`). `Map.prototype.entries()` and
`Object.entries` were already correct and are the pattern the fix follows.

Run TypeScript 5.7.3 and Home from this directory with
`-p tsconfig.json --pretty false --noEmit`; the `test-tsc-streams` step
compares stdout, stderr and exit status exactly.

`entries.ts` reads the yielded tuple through a `never` annotation in three
positions — the `for-of` element, the iterator value itself, and an array
spread — for a mutable array, a readonly array and a tuple receiver, whose
element union makes the second position `string | number`. The iterator's own
display name carries the yielded type, so `ArrayIterator<[number, number]>`
is what pins that the tuple is recorded *before* that name is built rather
than afterwards. `Set` and `Map` are compared side by side, the positional
destructuring rows pin that the index and element types stay distinct, and
`keys()` / `values()` pin that a non-tuple yield is untouched.

[Issue #988](https://github.com/home-lang/home/issues/988) tracks this work.
