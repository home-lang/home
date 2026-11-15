# Parameter assignment flow oracle (#1041)

After `p = 1;` on a `p: number | string` parameter, TypeScript reads `p` as
`number`. Home read the declared type. `getTypeAtFlowAssignment` treats a
parameter like a `let`, but Home's assignment narrowing (#1022, #1038) and
compound flow (#1028) required a `let` or `var` declaration.

`parameterAssignmentSlot` in `check.zig` gives a write to a parameter the
same slot a `let` has: the parameter's type inside the body (`T | undefined`
for `p?: T`, `T` for a defaulted `p: T = ...`). It uses the nearest enclosing
function that binds the name, so a closure's write narrows the closure's
own reads, and the narrow stays in the closure's scope. A destructured
parameter's binding is typed from its pattern. A declaration nearer the
write, or a destructuring assignment to the name, keeps the older behavior.

Run TypeScript 5.7.3 and Home from this directory with
`-p tsconfig.json --pretty false --noEmit`. The `test-tsc-streams` step
compares stdout, stderr and exit status exactly. Native TypeScript 7.0.2
prints the same 22 lines.

[Issue #1041](https://github.com/home-lang/home/issues/1041) tracks this work.
