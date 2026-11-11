# Signed numeric literal oracle (#1012)

A `const` initialized with `-5` or `+5` was typed `number`; so was the same
literal under `as const`. The checker kept a bare `5` and, since #1005, a
negative bigint `-5n`, but never a sign applied to a numeric literal.

TypeScript's `checkPrefixUnaryExpression` gives `-N` and `+N` the fresh literal
type of the signed value whenever the operand is the numeric literal itself.
Home now does the same in `numericLiteralExpressionType`, which serves a
`const` initializer, `as const`, a literal target and narrowing. Two of those
already had a copy that knew `-N` but not `+N`.

- **`-0` is the `0` literal.** TypeScript keys number literal types in a
  `Map`, so `-0` and `0` are one type. Home's interner keyed them by their
  bits; it now stores `-0` as `0`.
- **Only the literal itself.** `-(5)` and `- -5` stay `number`, because the
  operand is not a numeric literal. The HIR has no parenthesized-expression
  node, so the parentheses are read from the source.

Run TypeScript 5.7.3 and Home from this directory with
`-p tsconfig.json --pretty false --noEmit`; the `test-tsc-streams` step
compares stdout, stderr and exit status exactly. Native TypeScript 7.0.2
prints the same 22 lines.

`signed.ts` pins a `const` initialized with a negative and a positive integer,
a negative fraction, and negative and positive hexadecimal; `-0` rejected by
`1` and accepted by `0`; `as const` alone, in an object and in a tuple; a
signed literal against a literal target; narrowing by `=== +2` and `=== -1`;
and the cases that stay `number`: a parenthesized operand, a doubly signed
one, a `let` and an object property without `as const`.

Not covered, and why:

- **An exponential number** such as `-1e21` is kept as a literal, but Home
  prints a number literal type in exponent form with all of its digits
  (`-1000000000000000000000` for `-1e+21`), as it does for `1e21` without a
  sign. That display bug is tracked in its own issue.
- **The same `const` imported from another file.** An importer sees no type
  at all for most unannotated exported consts, signed or not. That is tracked
  in its own issue.

[Issue #1012](https://github.com/home-lang/home/issues/1012) tracks this work.
