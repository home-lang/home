# Imported JSDoc function templates (#846)

TypeScript 5.7.3 is the oracle for both configurations. The JavaScript owner
exports an unconstrained `identity<T>` and a `constrained<T extends string |
number>` function. The TypeScript consumer checks return-type inference and
rejection of an argument outside the constraint.

With `checkJs: true`, the exact stream has two consumer diagnostics plus one
owner-side TS2322. With `checkJs: false`, the owner error disappears, but both
consumer errors remain. The source is still admitted through the import; this
control verifies that disabling owner diagnostics does not erase its public
generic signature.
