# Imported JSDoc function templates (#846)

TypeScript 5.7.3 is the oracle for both configurations. The JavaScript owner
exports an unconstrained `identity<T>` and a
`constrained<T extends string | number>` function, both with explicit JSDoc
returns. A third `inferred<T>`
function has only a parameter tag; its result comes from the checked body.
The TypeScript consumer checks return-type inference and rejection of an
argument outside the constraint.

With `checkJs: true`, the exact stream has three consumer diagnostics plus one
owner-side TS2322. With `checkJs: false`, the owner error disappears, but all
three consumer errors remain. The source is still admitted through the import; this
control verifies that disabling owner diagnostics does not erase its public
generic signature.
