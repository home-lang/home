# Inferred generic owner revisions (#846)

These are exact TypeScript 5.7.3 CLI snapshots. Both JavaScript owners declare
the same `@template T` function without an explicit return tag. One returns
`T`; the other returns `T[]`. The identical TypeScript consumer has one TS2322
in each snapshot, but on opposite assignments.

Program and LSP tests apply the two owner bodies to the **same** logical
`/owner.js` path, then revert the edit. They assert the changed diagnostic
message and LSP republication, not just the common TS2322 code. This catches
stale checked generic signatures and stale editor publication state.
