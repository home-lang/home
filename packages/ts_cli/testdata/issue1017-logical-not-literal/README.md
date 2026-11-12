# Logical negation oracle (#1017)

Home typed every `!x` as `boolean`. TypeScript's `checkPrefixUnaryExpression`
types it from the truthiness facts of `x`:

```ts
const facts = getTypeFacts(operandType, TypeFacts.Truthy | TypeFacts.Falsy);
return facts === TypeFacts.Truthy ? falseType :
    facts === TypeFacts.Falsy ? trueType :
    booleanType;
```

`truthinessFacts` in `check.zig` ports the `Truthy | Falsy` part of
`getTypeFacts`:

- **Only falsy:** `0`, `""`, `0n`, `false`, `null`, `undefined` and `void`.
- **Only truthy:** other literals, and object, function, symbol and
  non-primitive types.
- **Both:** `string`, `number`, `bigint`, `boolean`, `any`, `unknown`, and an
  empty object type such as `{}`.
- **Composite types:** a union ORs its members' facts. An intersection ANDs
  them, ignoring object members when a primitive is present, so a branded
  string is still a string. A type parameter takes its constraint's facts.
- **Without `strictNullChecks`:** every value may be `null` or `undefined`,
  so no operand is only truthy, and only falsy operands give a literal.

The result is a fresh literal, as `trueType` and `falseType` are in
TypeScript:

- **Kept:** a `const` keeps it, and so do a literal target, a call argument,
  an `as const` tuple and a comparison.
- **Widened to `boolean`:** a non-literal target, an array element, an object
  property, a class field and a `let`.

Home's literal nodes are checked as their widened primitive, so `!` reads
its operand's literal type from the node. A `!x` node records its literal as
its type, and the mutable locations widen it explicitly.

Run TypeScript 5.7.3 and Home from this directory with
`-p tsconfig.json --pretty false --noEmit`, and again with
`-p tsconfig-loose.json`. The `test-tsc-streams` step compares stdout, stderr
and exit status exactly. Native TypeScript 7.0.2 prints the same 33 lines for
each.

`negation.ts` aims each negation at the opposite literal, so every line names
the type TypeScript computes. It covers:

- every kind of operand above, enum members, `!!0` and `!-0`;
- each context that keeps or widens the result;
- unconstrained, string-constrained and object-constrained type parameters.

`tsconfig-loose.json` checks the same file without `strict`.

Not covered, and why:

- **TS2872 on a negated literal.** TypeScript reports "This kind of
  expression is always truthy" for `!"a"`, `!0n` and `!1n`, and anchors
  `!(() => 1)` at the parenthesis. Home's check at `!` misses the first three
  and anchors inside the parenthesis. This is a separate rule from the type
  of `!x`, tracked in its own issue.
- **Narrowing a `let` to its initializer.** For `let l = !0`, TypeScript
  narrows a later read of `l` to `true`; Home gives `boolean`, as it already
  does for `let l = true`.
- **A union of literals reported as a source,** such as `cond ? !0 : 1`
  against `string`. TypeScript widens the message to `number | boolean`. That
  is #1009.

[Issue #1017](https://github.com/home-lang/home/issues/1017) tracks this work.
