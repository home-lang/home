#1020: inferred return literal widening

An unconstrained inferred function return widens fresh literals within a
union. Explicit `as const` and contextual literal return contracts retain
their literal types. The fixture compares the full diagnostic stream with
TypeScript 5.7.3.
