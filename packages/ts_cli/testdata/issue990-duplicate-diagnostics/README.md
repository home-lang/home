# Duplicate diagnostic oracle (#990)

TypeScript sorts *and* deduplicates program diagnostics
(`sortAndDeduplicateDiagnostics`); Home's driver sorted only. A tuple-typed
target behind an object-literal property or an array literal element is
reached by more than one traversal, so the same mismatch was reported once per
path — four copies for one property, eight for a nested one, two for an array
element — while TypeScript reports each once.

Run TypeScript 5.7.3 and Home from this directory with
`-p tsconfig.json --pretty false --noEmit`; the `test-tsc-streams` step
compares stdout, stderr and exit status exactly.

`duplicates.ts` pins one diagnostic per statement for a tuple property, a
nested tuple property, a tuple inside an array literal and a tuple two arrays
deep. An array-typed property is the control that was already reported once,
which is what makes the duplication specific to a tuple target, and the clean
rows pin that correct values stay silent.

The duplicate traversals themselves still happen; the deduplication is what
TypeScript does with them. The deeper
`Type at position 0 in source is not compatible with type at position 0 in
target.` elaboration level, and an extra outer diagnostic that Home reports
for an array literal **argument** whose element already reported, are separate
and are not pinned here.

[Issue #990](https://github.com/home-lang/home/issues/990) tracks this work.
