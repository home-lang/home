# Array stringification methods (#960)

TypeScript 5.7.3 declares `toString` and `toLocaleString` directly on both `Array<T>` and `ReadonlyArray<T>`. The control checks that they are in each `keyof` set, that both calls return `string`, and that readonly arrays still reject `push`.

`tsconfig-structural.json` checks the complete structural `ReadonlyArray<T>`
relation. An interface extending `ReadonlyArray<number>` inherits its methods
and is assignable to that type; an object with only a readonly length and
numeric index is not. The same distinction determines whether `.flat()`
unwraps an element. TypeScript 5.7.3 reports only the missing-method assignment
and the intentionally wrong flattened element assignment.

`tsconfig-display.json` pins how an array type is rendered in a diagnostic.
TypeScript parenthesizes an element whose own syntax binds looser than the
postfix `[]` — a readonly array or tuple, an intersection, a function or
constructor type, a union — and leaves everything else bare, including an
operator that belongs to a nested type (`{ run: () => number; }[]`,
`Map<string, number>[]`). Home previously rendered `(readonly number[])[]` as
`readonly number[][]`, which names a different type, and wrapped
`{ a: ... }[]` and `Map<...>[]` that need no parentheses. All twelve rows now
match TypeScript 5.7.3 exactly, including the nested
`(readonly (readonly number[])[])[]` form.

`tsconfig-arguments.json` covers the argument position. A `readonly number[]`
or `readonly [number, string]` argument cannot satisfy a mutable array or
tuple parameter, including a generic `T[]` parameter, and TypeScript puts its
`readonly` explanation underneath TS2345. Home previously accepted all three
calls silently while already rejecting the equivalent assignment with TS4104.
A spread copy, a mutable source, and a `readonly` parameter in either
direction stay legal, as do the copying methods. All three diagnostics and
both engines' exit status now match exactly.
