# Compound assignment flow oracle (#1028)

`let n: number | undefined = 0; n += 1;` reported
`Operator '+=' cannot be applied to types 'number | undefined' and 'number'`.
Home checked a compound assignment's target against its declared type and
did not narrow by compound writes at all.

TypeScript treats `x op= v` in three ways that Home now follows in
`check.zig`:

- **The left operand.** `checkIdentifier` reads a compound target as
  `getBaseTypeOfLiteralType` of its flow type, so `n` above is `number`. That
  type is also what the result must fit, so
  `let s: string | number = 1; s += "x";` reports
  `Type 'string' is not assignable to type 'number'`.
- **`checkNonNullType`.** An arithmetic operand, or a `+=` operand with no
  string side, may not be `null` or `undefined`. It is reported by name
  (`'n' is possibly 'undefined'`) and then checked without them. Home
  reported TS2365, TS2362 or TS18050 instead. `k++` on a variable narrowed
  to `undefined` also reported
  `Cannot assign to 'undefined' because it is not a variable`.
- **The flow after it.** `getTypeAtFlowAssignment` does not reduce by a
  compound assignment's value. The target reads as the base type of its
  type before the write: `number` stays `number` after `s += "x"`, and a
  `string | number` parameter stays `string | number`.

A compound expression now has the operation's type, so
`const r: number = (s += "b")` reports `Type 'string'`. Variables with
compound and update writes take part in #1022's assignment narrowing, and
the #1023 joins and #1027 loop heads read compound writes the same way.

`unresolved.ts` pins a side effect. A `let` with an initializer Home cannot
resolve no longer records a narrow under its name. A `for` loop binding's
narrow used to outlive the loop, so a later read of that name lost its
`Cannot find name` error.

Run TypeScript 5.7.3 and Home from this directory with
`-p tsconfig.json --pretty false --noEmit`. The `test-tsc-streams` step
compares stdout, stderr and exit status exactly. Native TypeScript 7.0.2
prints the same 18 lines.

Not covered, and why:

- **A literal union declaration.** After `let x: 0 | 1 = 0; x += 1;`
  TypeScript reads `x` as `number`. Home reads `0 | 1`, because a narrow
  that does not fit an annotated declaration falls back to it.
- **Binary arithmetic.** `n - 1` on a `number | null` still reports TS2362
  instead of `'n' is possibly 'null'`. That is the binary operator, not the
  assignment.

[Issue #1028](https://github.com/home-lang/home/issues/1028) tracks this work.
