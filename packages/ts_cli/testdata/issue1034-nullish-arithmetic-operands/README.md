# Nullish arithmetic operand oracle (#1034)

`n - 1` on a `number | undefined` reported
`The left-hand side of an arithmetic operation must be of type 'any', 'number', 'bigint' or an enum type.`
TypeScript reports `'n' is possibly 'undefined'.` instead.

TypeScript's `checkBinaryLikeExpression` runs `checkNonNullType` on both
operands of `-`, `*`, `/`, `%`, `**`, the bitwise operators and the shifts,
and on `+` when neither side is string-like. The prefix `+`, `-` and `~`
operators do the same. Home now follows it in `check.zig`
(`checkNonNullOperand`):

- **The report.** An operand that may be `null` or `undefined` is reported
  as `reportObjectPossiblyNullOrUndefinedError` does. An entity name (`n`,
  `o.p`, `maybe?.p`) is named. A call, an element access, `this.count` and a
  parenthesized operand are `Object is possibly ...`. The `null` and
  `undefined` literals are `The value '...' cannot be used here.`
- **The check after it.** The operand is checked without `null` and
  `undefined`. If nothing is left (`n0: null`), it is TypeScript's error
  type and reports nothing more. So `big - 1n` and `big + 1n` on a
  `bigint | undefined` are `bigint`.
- **Compound assignments.** Both operands of `o.p -= 1`, `x -= n`, `o.p++`
  and `x += n` are checked the same way. Home used to report
  `The value 'undefined' cannot be used here.` there, and
  `Cannot assign to 'undefined'` for `o.p++`.

Run TypeScript 5.7.3 and Home from this directory with
`-p tsconfig.json --pretty false --noEmit`. The `test-tsc-streams` step
compares stdout, stderr and exit status exactly. Native TypeScript 7.0.2
prints the same 48 lines.

Not covered, and why:

- **The boolean suggestion.** `bo & true` on a `boolean | undefined` reports
  the operand and then TS2447. TypeScript 5.7.3 anchors TS2447 at the
  expression, native TypeScript 7 at the operator, and Home follows native
  TypeScript 7. The checker unit test covers it.
- **Mixing `bigint` and `number`.** `big - 1` reports
  `Operator '-' cannot be applied to types 'bigint' and 'number'.` in
  TypeScript. Home does not report that for any binary arithmetic operator,
  nullish or not.
- **`strictNullChecks` off.** Only a type that is exactly `null` or
  `undefined` is reported then. The checker unit test covers it.

[Issue #1034](https://github.com/home-lang/home/issues/1034) tracks this work.
