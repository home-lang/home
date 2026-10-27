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

`class-owner.js` declares a JSDoc-typed field and method parameter; the
method's number result is inferred from its checked body. `class-consumer.ts`
checks two invalid writes/calls and two invalid reads. TypeScript 5.7.3 emits
TS2322, TS2345, TS2322, TS2322 with `checkJs` on or off. The CLI stream cases
assert the exact output; the Program test varies compilation mode, insertion
order, and `checkJs`. The checked owner must provide the method's signature,
not the syntactic class schema's pre-check `any` result.

`class-owner-string.js` changes the field, method parameter, and inferred
result to `string`. Its separate CLI oracle emits TS2322 then TS2345 at the
same positions in TypeScript 5.7.3 and Home, with `checkJs` on or off. Program
and LSP revision tests edit the same logical owner from number to string and
back without changing the importer. They require the importer's diagnostics to
appear and then clear; the LSP test also checks a fresh publication after each
edit and no duplicate publication while the result is unchanged.
