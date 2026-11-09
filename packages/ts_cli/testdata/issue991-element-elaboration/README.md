# Element elaboration oracle (#991)

An array element's own explanation was missing from the chain:
`arrayOriginElementMismatchEntry` built the element line and returned it as a
leaf, so Home stopped two levels short of TypeScript for a tuple element and
one level short for a nested array element. Everything needed to continue was
already reachable from `buildAssignabilityElaborationChainDepth` —
`tuplePositionElaborationChain` for a tuple pair, and the element entry itself
for a nested array pair.

Run TypeScript 5.7.3 and Home from this directory with
`-p tsconfig.json --pretty false --noEmit`; the `test-tsc-streams` step
compares stdout, stderr and exit status exactly.

`elements.ts` pins the whole chain at every depth it reaches: four lines for a
tuple element failing at position 0 and at position 1, the same four under a
readonly receiver and under an argument (TS2345), three for a nested array
element, and five for a tuple two arrays deep, which is what shows the
recursion is general rather than one extra hard-coded level. A matching
element stays silent, and a direct tuple assignment keeps the array-literal
path's own single-line diagnostic.

[Issue #991](https://github.com/home-lang/home/issues/991) tracks this work.
