#1019: readonly empty tuple identity

An empty `as const` array has the type `readonly []`. A mutable empty tuple
can flow into it, but the readonly value cannot flow back into `[]`.
The exact diagnostic stream is checked against TypeScript 5.7.3.
