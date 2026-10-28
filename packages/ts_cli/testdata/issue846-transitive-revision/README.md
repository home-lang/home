# Transitive admitted-JavaScript source revision (#846)

`main.ts` imports `bridge.js`, which re-exports the value from `leaf.js`.
Only `main.ts` is an explicit root. The JavaScript owners must enter the
Program through the import closure, including when `checkJs` is disabled.

TypeScript 5.7.3 and Home both report exactly
`main.ts(3,7): error TS2322: Type 'number' is not assignable to type 'string'.`
with exit 2 and empty stderr for both configs. The exact stream is checked by
`test-tsc-streams` and the #846 differential auditor.

Changing only `leaf.js` from `export const value = 1` to
`export const value = 'ready'` makes both compilers exit 0 with no output in
both modes. This revision was checked against TypeScript 5.7.3 with the same
config and `--pretty false`, then the numeric fixture was restored. The
`LspProject` regression exercises the edit-and-revert sequence through
`workspace/didChangeWatchedFiles`, retaining the same open TypeScript importer
and both admitted JavaScript file identities. This covers a transitive
watched-source revision, not every possible JavaScript inference or editor
event ordering.

`alternate.js` is an unadmitted sibling until `bridge.js` re-exports it.
Changing only that re-export edge from `leaf.js` to `alternate.js` makes
TypeScript 5.7.3 and Home exit 0 with empty streams in both configs; reversing
the edge restores the single TS2322. The editor regression watches the bridge
edit-and-revert, requiring the old leaf to leave the Program, the alternate
leaf to enter it, and the original leaf FileId to return on reversal.
