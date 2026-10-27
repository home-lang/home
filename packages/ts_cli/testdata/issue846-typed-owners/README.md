# Imported checked-JavaScript typedef and class owners (#846)

`union-owner.js` declares a JSDoc `Payload` typedef with required and optional
union-valued members. `union-consumer.ts` imports the object and performs two
invalid writes and two invalid reads. TypeScript 5.7.3 reports four TS2322
diagnostics, including their nested explanation lines, at the same positions
with `checkJs` on and off. `zig build test-tsc-streams` asserts both exact
streams and exit 2; the Program test covers serial/parallel compilation,
source insertion order, and both `checkJs` modes. The Program must publish the
checked owner's resolved type when the pre-check JSDoc name was opaque, not
infer a shape from the importer's assignments.
