# Assignment narrowing oracle (#1022)

`let flag = true` read as `boolean`. TypeScript narrows a reference after an
assignment with `getTypeAtFlowAssignment`. When the declared type is a union,
the read is `getAssignmentReducedType(declared, assigned)`: the declared
members the assigned value may be assignable to. `boolean` is the union
`true | false`, so `let flag = true` reads as `true`. A declared type that is
not a union is read unchanged.

Home's flow narrowing for a declaration differed in three ways:

- **No narrowing in some places.** A `let` or `var` at the top level of a
  file never recorded its initializer, and an unannotated one never did
  anywhere.
- **The literal instead of the member.** Elsewhere Home recorded the
  initializer's own literal, so `let x: string = "a"` read as `"a"`.
- **No narrowing by object or `undefined` initializers** of a union.

`assignmentReducedType` in `check.zig` ports the reduction. Declarations and
plain assignments now record the reduced type.

At #1022 Home's flow scopes did not join narrows across branches, loops,
`try`, `switch` or closures, so the new narrowing applied only to a variable
whose every write was a plain `name = value;` statement in its declaring
block. #1023 added the joins and lifted that restriction; see
`../issue1023-assignment-joins/`.

An untyped declaration without an initializer keeps its evolving type,
which takes each assigned type as before.

A narrowed boolean literal is fresh, as `getAssignmentReducedType` keeps
it. A mutable copy, an array element, an object property and an inferred
return type widen it to `boolean`. This also fixes `function f() { return
!0; }`, which #1017 typed as returning `true`.

Now that a variable can read as `true`, its error message follows
`reportRelationError`. A boolean literal source prints as `boolean` unless
the target could hold a singleton type (`typeCouldHaveTopLevelSingletonTypes`):
a literal, an enum, `null`, `undefined`, a unique symbol, or a union with one.
So `let x = true` gives `Type 'true' is not assignable to type 'E'` but
`Type 'boolean' is not assignable to type 'number'`.

Run TypeScript 5.7.3 and Home from this directory with
`-p tsconfig.json --pretty false --noEmit`; the `test-tsc-streams` step
compares stdout, stderr and exit status exactly. Native TypeScript 7.0.2
prints the same 24 lines.

`narrowing.ts` covers:

- **Booleans:** initialized, annotated, reassigned, negated and hoisted, and
  one reassigned from a call.
- **Other declared types:** a type union, a literal union, an optional
  object, and a `string`, which is not narrowed.
- **Fresh reads:** a copy, an array, an object, an inferred return type and a
  comparison.
- **Message names:** the narrowed `true` against an enum, `null` and
  `number`.
- **Function bodies:** the same rules inside a function.
- **Writes in a branch or a loop**, which leave the declared type in both
  compilers.

Not covered, and why (callback writes and loop exit conditions are pinned by
#1023):

- **Narrowing preserved in a closure** created after the last assignment, as
  TypeScript 5.4 does. Home reads the declared type in every closure.
- **A narrow to `never`**, such as `false` inside `if (flag)`. Home falls
  back to the declared type, as it already does for a `const`.
- **An enum member initializer.** `let e = E.A` reads as `E.A` in TypeScript.
  Home's numeric enum type is not a union, so it is not reduced.

[Issue #1022](https://github.com/home-lang/home/issues/1022) tracks this work.
