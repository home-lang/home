# Nested assignment flow oracle (#1038)

After `let v; r[0] = (v = a) & 1;`, TypeScript reads `v` as `number`. Home
read `undefined`, and `number | undefined` for an annotated
`let w: number | undefined;`. TypeScript's binder adds a flow node for every
assignment, wherever it sits. Home narrowed a variable without an
initializer only by an assignment that was a whole statement.

`check.zig` now follows nested writes on both of Home's flow paths:

- **Declared variables.** `assignmentRunsWithItsStatement` accepts a plain
  write that always runs with its statement: an operand, an argument, a
  value, an initializer, a `return` value or an `if` condition. Such a write
  narrows like a statement-level one (#1022), so a later read in the same
  statement sees it too. A write on the right of `&&`, `||` or `??`, in a
  branch of `?:`, after an optional chain, in a loop head or in a nested
  function is still joined by its statement (#1023).
- **Evolving variables** (`let v;`). Their reads are rebuilt from the
  statements before them. `nestedAssignmentFlow` now follows the writes
  inside a statement in evaluation order: after it, and before a read inside
  it. A write that may not run joins with the path that skips it.

Run TypeScript 5.7.3 and Home from this directory with
`-p tsconfig.json --pretty false --noEmit`. The `test-tsc-streams` step
compares stdout, stderr and exit status exactly. Native TypeScript 7.0.2
prints the same 19 lines.

[Issue #1038](https://github.com/home-lang/home/issues/1038) tracks this work.
