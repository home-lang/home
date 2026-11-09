# Generic `Array` static oracle (#987)

TypeScript 5.7.3 declares `Array.of` and `Array.from` as generic members of
`ArrayConstructor`: `of<T>(...items: T[]): T[]`, `from<T>(src): T[]` and
`from<T, U>(src, mapfn, thisArg?): U[]`. Home modeled both as fixed-arity
`any` signatures returning `any[]`, which rejected valid arities and silenced
every assignment through them. Run TypeScript 5.7.3 and Home from this
directory with `-p <config> --pretty false --noEmit`; the `test-tsc-streams`
step compares stdout, stderr and exit status exactly.

`tsconfig-statics.json` (`statics.ts`) pins the result type of each form
through a deliberate mismatch: the sixteen diagnostics cover `of`'s widened
first-argument element, its `unknown[]` with no arguments, a spread argument,
a nested array argument, and the TS2345 a later argument gets against the
inferred element; `from`'s element through the array numeric index, the
iteration protocol (`Set<number>`, `"abc"`) and an array-like object's
numeric-named members; and the mapped form's result together with the
contextual types its callback receives — the TS2339 at `value.bogus` is the
element type reaching the callback parameter.

`tsconfig-targets.json` (`targets.ts`) is the clean control. Every
synthesized result has to be a real array, not only `{ length, [n: number] }`:
it assigns to `readonly number[]`, `ReadonlyArray<number>` and `readonly
any[]`, and carries the array method surface (`concat`, `join`). It also pins
the inference precedence — a literal contextual element type keeps the
argument's literal type, a widened one is left alone, and a
`(string | number)[]` target does not stop the TS2345 — plus the `any[]`
fallback for a source whose element type is not statically known. Both
engines report only that one TS2345 and exit 2.

[Issue #987](https://github.com/home-lang/home/issues/987) tracks the
remaining work: explicit type arguments (`Array.of<number>(1, 2)`,
`Array.from<string, number>(iterable, (v) => v.length)`) are still rejected
with a false TS2558, because the synthetic signatures carry no type
parameters.
