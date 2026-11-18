# Resolved keyof alias display (#994)

A `keyof typeof value` alias retains the operand's resolved array or named
interface type in diagnostics. An anonymous object or union operand still
expands to its keys. The fixture also checks a direct `keyof typeof` annotation,
a primitive operand, and a union containing `keyof` so ordinary alias names
remain intact.

TypeScript 5.7.3 and native TypeScript 7.0.2 produce identical diagnostic text
for every row. The oracle audit compares the full output and exit status against
5.7.3. See [issue #994](https://github.com/home-lang/home/issues/994).
