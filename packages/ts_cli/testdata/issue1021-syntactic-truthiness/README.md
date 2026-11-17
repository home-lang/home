#1021: syntactic truthiness diagnostics

The same TypeScript syntactic truthiness rule applies to `!`, conditional and
statement conditions, and the left side of `&&` and `||`. The `??` row pins
TypeScript's separate nullish diagnostic. The full stream is compared with
TypeScript 5.7.3.
