# Tuple spread union oracle (#992)

Spreading a tuple into an array literal with a tuple target reported one
diagnostic per tuple position. TypeScript explains the failure with the
spread's own element type — the union over its positions — against the target
element where the spread begins, and reports it once. `[...pair]` with
`pair: [number, string]` against `[string, number]` is therefore one
`Type 'string | number' is not assignable to type 'string'.`, not a
`number`-to-`string` and a `string`-to-`number`.

Run TypeScript 5.7.3 and Home from this directory with
`-p tsconfig.json --pretty false --noEmit`; the `test-tsc-streams` step
compares stdout, stderr and exit status exactly.

`spread.ts` pins the single diagnostic for a readonly and a mutable tuple
source, a three-position tuple whose union has three members, a spread that
begins after a fixed element — which is what fixes the reported position — and
an argument rather than a declaration. A single-type tuple has no union to
print, so its element type stands alone.

The rest are the controls the fix must not disturb. Assignability stays
positional, so a spread whose positions line up with the target is accepted in
either order and so is a matching prefix with a fixed tail; arity is still
owned by the whole assignment, with its `Source has 2 element(s)` wording; and
an array target, which already compared the element union, still does.

[Issue #992](https://github.com/home-lang/home/issues/992) tracks this work.
