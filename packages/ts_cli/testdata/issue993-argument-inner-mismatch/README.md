# Argument inner-mismatch oracle (#993)

A tuple target reached through an object-literal property or an array literal
element reported twice from an argument position: the element, which is the
diagnostic TypeScript reports, and an outer one comparing the *widened*
literal against the tuple — `Type 'number[]' is not assignable to type
'[string, number]'` with a `length` chain, or the same as an argument-level
TS2345. The identical literals in a declaration position already reported
once, so the extra report was specific to the argument path.

Run TypeScript 5.7.3 and Home from this directory with
`-p tsconfig.json --pretty false --noEmit`; the `test-tsc-streams` step
compares stdout, stderr and exit status exactly.

`arguments.ts` has four groups. The first is the double-reporting one: a
tuple behind a property, behind an array element, and two objects deep. The
second and third are the positions that already reported once — a direct
tuple or array argument, and the same literals as declarations — which pin
that nothing moved there. The fourth is the counter-case the fix must not
break: with no diagnostic inside the argument, the argument still owns one, so
an all-spread literal keeps the TS2345 that #989 depends on, and a wholly
wrong shape keeps its own diagnostic. That last group is also where the arity
wording belongs: an array's length is not statically known, so TypeScript
explains a fixed tuple target with `Target requires 2 element(s) but source
may have fewer.` rather than through the `length` member a structural walk
would reach.

A tuple spread against a tuple target still differs in diagnostic count and
is tracked by #992; it is not pinned here.

[Issue #993](https://github.com/home-lang/home/issues/993) tracks this work.
