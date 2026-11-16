# Captured narrowing oracle (#1042)

Since TypeScript 5.4, a closure keeps a captured variable's narrowing when
nothing assigns the variable after the closure is created. Home started every
closure from the declared type. So `if (c) { xs.map(() => c.length) }`
therefore reported TS18048.

tsc's `checkIdentifier` moves the flow container outward through function
expressions, arrows, and object-literal or class-expression methods and
accessors. It does this for a `const`, or for a parameter, catch variable or
local `let` read past its last assignment (`isPastLastAssignment`). The last
assignment counts at the end of the statement holding it. A write in a nested
function or an `export { name }` means "never past". A function declaration, a
class-declaration method and a class field stop the walk, and so does a `var`.

Home checks a closure where it is created, so the narrow scopes below the
closure's floor hold the flow at that point. `capturedFlowNarrow` in
`check.zig` resolves the read's binding, applies tsc's rules, and searches
those scopes down to the floor of the container the walk stops at.

Run TypeScript 5.7.3 and Home from this directory with
`-p tsconfig.json --pretty false --noEmit`. The `test-tsc-streams` step
compares stdout, stderr and exit status exactly. Native TypeScript 7.0.2
prints the same 39 lines.

[Issue #1042](https://github.com/home-lang/home/issues/1042) tracks this work.
