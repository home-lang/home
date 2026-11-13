# Compound assignment past a literal annotation oracle (#1035)

After `let x: 0 | 1 = 0; x += 1;`, TypeScript reads `x` as `number`. Home
read `0 | 1`.

`getTypeAtFlowAssignment` types a compound write as the base type of the
type before it (#1028), so the flow type can be wider than a literal union
annotation. Home recorded that narrow, but `typeOfIdentifier` returns the
declared type when a narrow does not fit the annotation. That fallback
guards against stale narrows, which are keyed by name. Now a narrow is kept
when the name has a compound assignment or update and the narrow fits the
annotation with its literals widened (`compoundNarrowFitsDeclaredType`).
Other narrows that do not fit still read as declared.

`annotation.ts` covers:

- the issue's row, an update, string concatenation, a mixed union, an enum
  and a single literal;
- the widened type joined out of a loop and a branch, and into the next
  iteration;
- a later plain assignment, which narrows again, and a variable of the same
  name in another function, which keeps its own type.

Run TypeScript 5.7.3 and Home from this directory with
`-p tsconfig.json --pretty false --noEmit`. The `test-tsc-streams` step
compares stdout, stderr and exit status exactly. Native TypeScript 7.0.2
prints the same 11 lines.

Not covered, and why:

- **Parameters.** `p += 1` and `p = 1` on a parameter do not narrow it in
  Home at all.
- **Closures.** Since TypeScript 5.4, a closure created after a variable's
  last assignment keeps its narrowed type. Home starts every closure from
  the declared type.

[Issue #1035](https://github.com/home-lang/home/issues/1035) tracks this work.
