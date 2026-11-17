# Tuple union relation witness (#1050)

A tuple's number index relates its element union to an array's element type.
When that union widens to one primitive, TypeScript still reports the failing
constituent as a nested explanation. For example, `[1 | 2]` to `boolean[]`
has two consecutive `Type 'number' is not assignable to type 'boolean'.`
lines: the widened element and the witness from the original union.

For mixed unions, Home follows native TypeScript 7.0.2's deterministic
constituent order, as established in #975. TypeScript 5.7.3 uses allocation
order, so its child can differ even though the diagnostic code, location, and
outer explanation agree. The stream audit verifies those common diagnostics
against 5.7.3 and the full text against native 7.0.2. Both Home and 5.7.3
exit with status 2; native 7 exits with status 1.

Run the three compilers from this directory with
`-p tsconfig.json --pretty false --noEmit`. The source covers both tuple
position orders, several targets, readonly tuples, homogeneous numeric,
string, and bigint literal unions, singleton literal targets, and passing
controls. Boolean union display is tracked separately in #1008.

[Issue #1050](https://github.com/home-lang/home/issues/1050) tracks this work.
