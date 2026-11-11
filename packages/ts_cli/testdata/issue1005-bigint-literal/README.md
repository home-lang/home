# bigint literal type oracle (#1005)

A `bigint` literal type in an annotation accepted any value. `1n` in type
position had no branch in `parsePrimaryType`: it fell through to the recovery
case and became a reference to `unknown`, so `const a: 1n = { q: 1 }` passed
silently. `-1n` did parse, as a literal type, but its value was only half
modelled, so `const j: -1n = -1n` was reported as `number` against `-1`.

Five changes make a bigint literal behave as a numeric one does:

- **The type parses.** `1n` is a literal type, like `1`.
- **The value is canonical.** TypeScript keeps a bigint literal as its
  base-ten value, so `0x10n`, `1_6n` and `16n` are one type and `-0n` is `0n`.
  `bigIntLiteralValueId` does the conversion for the annotation and for the
  expression, which are compared by that value.
- **A bigint literal expression is a fresh literal.** `2n` keeps the type `2n`
  where a numeric literal keeps its own: against a literal target, in a
  `const`, under `as const`, in narrowing and in an argument. Against a
  target that is not a literal it is shown widened, `'bigint'`.
- **`-` and `~` keep a bigint a bigint.** They gave `number`. An operand that
  may also be a number gives `number | bigint`, as in `getUnaryResultType`.
- **The literal prints with its `n`.** Three display paths printed `1`.

Run TypeScript 5.7.3 and Home from this directory with
`-p tsconfig.json --pretty false --noEmit`; the `test-tsc-streams` step
compares stdout, stderr and exit status exactly. Native TypeScript 7.0.2
prints the same 41 lines.

- `annotation.ts` pins rejection by a bigint literal annotation of an object,
  a string, another bigint literal, a numeric literal, `bigint` and a negative
  literal; acceptance of the literal itself, a union member, a negative
  literal and a declared value; spellings in hexadecimal, octal, binary and
  with separators, and `-0n`; and a parameter, an object property and an
  array element.
- `values.ts` pins `const` and `let`, a negative literal, `as const` in an
  object and a tuple, a comparison with no overlap, narrowing by `===`, `!==`
  and `switch`, and `-` and `~` of `bigint` and of `number | bigint`.

Not covered, and why — none is specific to bigint, and each also fails for a
numeric literal:

- **A literal returned against a literal return type** is reported widened
  (`Type 'bigint' is not assignable to type '5n'`), as `"bogus"` and `6` are
  (#1004).
- **A literal in a template literal type** (`` `${1n}` ``, `` `${1}` ``) is
  not folded into text, and a numeric one accepts any string.
- **`const n = -5`** is typed `number` where TypeScript keeps `-5`; the bigint
  form `-5n` is covered.

[Issue #1005](https://github.com/home-lang/home/issues/1005) tracks this work.
