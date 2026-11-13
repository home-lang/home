# Own-initializer read oracle (#1036)

`for (let a = a; a; ) { }` and `for (let k in k) { }` reported
`Cannot find name 'a'.` and `Cannot find name 'k'.` TypeScript reports the
binding as used before its declaration, and as circular.

The cause was wider than loops. A read inside a variable's own initializer
was skipped while Home looked for its declaration, so it fell through to
TS2304, or to `any` with nothing reported for a `var` or at the top level.
An inner `let s = s + 1` resolved to an outer `s` instead.

`selfInitializerBinding` in `check.zig` now finds the binding whose own
initializer, or `for...in` / `for...of` source, holds the read. The check
stops at a function, whose body runs later. `typeOfIdentifier` checks it
before any narrow or outer scope, and `reportSelfInitializerReference`
follows TypeScript:

- A `let` or `const` reports `Block-scoped variable '...' used before its
  declaration.` at the read. A `var` does not.
- An unannotated binding is circular. Under `noImplicitAny` it reports
  TS7022 at its name, and the read is `any`.
- An annotated `let` or `const` reads as declared, and reports
  `Variable '...' is used before being assigned.` when its type has no
  `undefined`.
- A read in a class body inside the initializer reports TS2448 but not
  TS7022, since the class type does not depend on it.

Run TypeScript 5.7.3 and Home from this directory with
`-p tsconfig.json --pretty false --noEmit`. The `test-tsc-streams` step
compares stdout, stderr and exit status exactly. Native TypeScript 7.0.2
prints the same 35 lines.

Not covered, and why:

- **Return-type circularity.** `let g = () => g;` and
  `let o = { m() { return o; } };` report nothing in TypeScript. Home
  reports TS7023 and TS7024 there.
- **Destructuring defaults.** `let [x2 = x2] = [];` reports TS2448 in both,
  but Home misses TypeScript's TS7022.

[Issue #1036](https://github.com/home-lang/home/issues/1036) tracks this work.
