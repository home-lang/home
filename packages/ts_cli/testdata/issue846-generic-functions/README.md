# Imported JSDoc function templates (#846)

TypeScript 5.7.3 is the oracle for both configurations. The JavaScript owner
exports an unconstrained `identity<T>` and a
`constrained<T extends string | number>` function, both with explicit JSDoc
returns. `inferred<T>`, `boxed<T>`, and `listed<T>` have only parameter tags;
their direct, object-member, and array-element results come from their checked
bodies. The TypeScript consumer checks return-type inference, read/write
constraints, and rejection of an argument outside the template constraint.

With `checkJs: true`, the exact stream has six consumer diagnostics plus one
owner-side TS2322. With `checkJs: false`, the owner error disappears, but all
six consumer errors remain. The source is still admitted through the import;
this control verifies that disabling owner diagnostics does not erase its
public generic signature.
