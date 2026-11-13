# Bigint and number mixing oracle (#1037)

`bb - 1` on a `bigint` reported nothing. TypeScript reports
`Operator '-' cannot be applied to types 'bigint' and 'number'.`

After `checkNonNullType` and the operand checks, TypeScript's
`checkBinaryLikeExpression` picks the result of `-`, `*`, `/`, `%`, `**`,
the bitwise operators and the shifts. `arithmeticResultType` in
`check.zig` now follows it:

- With both operands any-like, or neither possibly a bigint, the result is
  `number`. "Possibly" is `maybeTypeOfKind`, which ignores a type
  parameter's constraint (`typeMaybeOfBigIntKind`).
- With both assignable to `bigint` (`any` and `never` included), it is
  `bigint`, and `>>>` reports TS2365.
- Otherwise TS2365 is reported and the result is `any`, TypeScript's error
  type, so `const r: string = nb - nb` reports nothing more.

`reportOperatorCannotBeApplied` follows `reportOperatorError`. A mix shows
the operands' base types (`'number | bigint'`, `'E'`, `'boolean'`), and `>>>`
shows them as they are (`'1n'`). So does a promise operand, where awaiting
both would make them relate. `+` and `+=` show the operands' own types
(`'1'`, `'T'`), since TypeScript treats number, bigint and string as close
enough there.

`typeIsBigIntLike` reads the OR'd flags of a union, so it took
`number | bigint` for a bigint. `typeAssignableToBigIntKind` checks every
member.

Run TypeScript 5.7.3 and Home from this directory with
`-p tsconfig.json --pretty false --noEmit`. The `test-tsc-streams` step
compares stdout, stderr and exit status exactly. Native TypeScript 7.0.2
prints the same 44 lines.

Not covered, and why:

- **Type-parameter operands.** `t - 1n` on a `T extends bigint` is valid in
  TypeScript, but Home reports TS2362 for any type-parameter operand.

[Issue #1037](https://github.com/home-lang/home/issues/1037) tracks this work.
