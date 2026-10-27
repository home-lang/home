# Checked JavaScript object writes (#846)

The project imports a JSDoc-typed object from `owner.js`. TypeScript 5.7.3
reports TS2540 for the readonly write, TS2322 for invalid required and
optional writes and a required read of an optional field, and TS2339 for
the missing property. The exact five diagnostics and exit 2 are asserted by
`test-tsc-streams`.

`local-matrix.ts` removes module resolution from the experiment. Its nine
TypeScript 5.7.3 TS2322 diagnostics show that `boolean | undefined` retains
the union and literal source in a failed write, while `number | undefined`
and `string | undefined` normally report the defined primitive target for
non-nullish sources. Home models boolean as one primitive; TypeScript treats
it as `false | true`, so the complete optional target has three diagnostic
constituents. The matrix and imported-owner case must agree without an
import-specific exception.
