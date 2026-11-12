# Loop head value oracle (#1027)

A loop head joins the flow entering the loop with every path back to it.
Home needs the head before it checks the body. #1023 estimated it from
assignments of literal values only, so `s = maybe()` in a loop did not widen
`s` at the head. Home then missed `'s' is possibly 'undefined'` on the next
iteration's read.

`estimateValueType` in `check.zig` now types an unchecked value from
declared types. It never checks the value, so no diagnostic is reported
twice:

- **Calls** to a non-generic function or method with one signature read its
  declared return type.
- **Properties and elements** read from the estimated object. An optional
  property or `?.` adds `undefined`, so `item = item.next` and
  `item = item?.child` widen the head through the loop's own variable.
- **`new C()`** of a non-generic class reads its instance type.
- **Identifiers** read their type where the loop starts, narrowed by the
  conditions on the path that need no checking: truthiness, `!`, and
  comparisons with `null` or `undefined`. So `if (other) s = other` stays
  `string`. A `for…of` element, a `for…in` key and a `for (let i = 0; …)`
  counter are typed from their source. Another identifier the loop
  assigns, or one behind another kind of condition, has no estimate.
- **Operators**: `?:`, `??`, `||`, `&&`, arithmetic, `+` with a string,
  comparisons, `await` and `!`.

A value with no estimate does not widen the head, as before.

Two related loop fixes are pinned here too:

- **`while (item)`** narrows an annotated variable in the body.
  `annotatedLoopFlowTypeAt` used to override every narrow inside a loop,
  including the condition's, so `use(item)` reported
  `Argument of type 'Item | undefined'`. A narrow recorded inside the loop
  now wins; one from before the loop still gives way.
- **Duplicate members.** Object types are not interned, so a join could
  hold one interface under two ids and print an extra
  `Type 'Item' is not assignable` line. Flow joins drop a member that
  prints the same and is assignable both ways.

Run TypeScript 5.7.3 and Home from this directory with
`-p tsconfig.json --pretty false --noEmit`. The `test-tsc-streams` step
compares stdout, stderr and exit status exactly. Native TypeScript 7.0.2
prints the same 17 lines.

Not covered, and why:

- **Generic calls.** `s = pick<string | undefined>(x)` and
  `s = await Promise.resolve(maybe())` need inference or instantiation,
  which only checking provides. They do not widen the head.

[Issue #1027](https://github.com/home-lang/home/issues/1027) tracks this work.
