# Assignment join oracle (#1023)

A narrow recorded before a loop, a `switch` or a logical expression survived
a write inside it, so Home read a variable as narrower than TypeScript does.
TypeScript joins the flow of every path that reaches a read. Home now does
the same for each identifier a statement assigns:

- **Loops.** The head joins the entry with every path back to it. The exit
  joins the paths where the condition fails with every `break`. A loop whose
  condition is `true` exits only by `break`. `while (!done)` ends with `done`
  read as `true`.
- **`switch`.** A clause starts from the discriminant joined with the clause
  that falls into it. A `switch` on the variable itself narrows each clause
  to its case value. The statement ends with every `break` and the last
  clause, plus the discriminant's flow when no `default` clause may match.
- **`&&`, `||`, `??` and `?:`.** The skipped operand or branch keeps the
  flow from before it.
- **`try`.** `catch` and `finally` start from the flow before the `try`
  joined with every assignment in the clauses they may interrupt. The
  statement completes through the end of the `try` block or the `catch`
  block.
- **Labeled blocks.** A block ends with each `break` to its label.

Each write reads as `getAssignmentReducedType(declared, assigned)`, so
`u = "x"` on a `string | undefined` reads as `string`, not `"x"`. With
the joins in place, #1022's restriction to straight-line writes is lifted.

The joins run after a statement is checked, from its checked assignments.
A loop head must be known before the body is checked, so Home estimates it
from assignments of literal values (`null`, `undefined`, `!x` and literals).
Other values do not widen the head.

Run TypeScript 5.7.3 and Home from this directory with
`-p tsconfig.json --pretty false --noEmit`. The `test-tsc-streams` step
compares stdout, stderr and exit status exactly. Native TypeScript 7.0.2
prints the same 47 lines.

`joins.ts` covers:

- **Loops:** `for…of`, `while` (head and exit), `do…while`, `for (;;)`, a
  labeled `break` out of nested loops, a `switch` inside a loop, and an
  assignment in a loop condition.
- **Boolean flags:** set before a `break`, cleared after the first
  iteration, and tested by the loop condition.
- **`switch`:** without and with a `default` clause, falling through, and
  on the variable it assigns.
- **Expressions:** `&&`, `||` and `?:`.
- **`try`:** the start of `catch` and of `finally`, and the end of each.
- **Labeled blocks, branch reduction and callback writes.**
- **The top level of a file.**

Not covered, and why:

- **A loop head widened by a computed value.** In
  `for (…) { s.length; s = maybe(); }`, TypeScript reads `s` as possibly
  `undefined` at the head. Home only estimates the head from literal values.
- **An enum member initializer.** `let e: E = E.A` reads as `E.A` in
  TypeScript. Home's numeric enum type is not a union, so it reads `E`.
- **An evolving `let x;` written in a loop.** It keeps its own flow
  analysis, which does not add `undefined` for zero iterations.
- **Writes Home does not join**: destructuring, `++` and arithmetic compound
  assignments keep the older narrowing.

[Issue #1023](https://github.com/home-lang/home/issues/1023) tracks this work.
