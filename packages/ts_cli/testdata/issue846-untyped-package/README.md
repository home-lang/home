# JavaScript package admission, exports, and Node format (#846)

Run `tsc -p CONFIG --pretty false` and `home-tsc -p CONFIG --pretty false`
from this directory. The package is a real `node_modules/untyped-package`
directory with a CommonJS `module.exports = 42` entry point.

At the default `maxNodeModuleJsDepth: 0`, both compilers leave the package
unadmitted and report only TS7016 on `main.ts:1:19`, including the absolute
resolved path and remediation hint. At depth 1, the package is admitted:
the import has type `number`, so both report only TS2322 on `main.ts:2:7`.
The relative `./local.js` control has the same whole-module export and
reports TS2322 on `consumer.ts:2:7` without a package-depth setting.

The `untyped-named` CommonJS package exports a `box.count` number. At depth
zero, its named import reports only TS7016. At depth one, with `checkJs` either
on or off, a string read and a string write each report TS2322. This checks
that admitted exports carry a mutable property type into the importing file.

The `untyped-esm` (`index.mjs`) and `untyped-esm-js` (`index.js` in a package
with `"type": "module"`) packages exercise the same admission boundary.
At depth zero, each reports only TS7016. At depth one, each reports TS1479
for a static import from this Node16 CommonJS-format `.ts` file, plus both
TS2322 property diagnostics. The ESM format follows the package owner for
`.js`, not the importing file's format. All cases were compared against
TypeScript 5.7.3; `zig build test-tsc-streams` asserts the exact Home CLI
streams and exit codes.

`import-equals.ts` and `import-type.ts` pin three more Node16 import forms
against the same ESM package. With depth zero, both use TS7016 and downstream
untyped accesses recover as `any`; admitting the package instead yields
TS1471 for `import = require(...)`, or TS1541 and TS1542 (with conversion
message chains) for the type-only declaration and `typeof import(...)`.
Both `checkJs` modes preserve these importer diagnostics. The six additional
exact streams and exits are part of `zig build test-tsc-streams`.

`import-type-indexed.ts` checks the parser's distinct representation of
`typeof import('untyped-esm')['box']` and a `typeof box` query on a type-only
named import. TypeScript 5.7.3 emits the same two module-format errors as
the bare import-type fixture at depth one, and two TS7016 errors at depth
zero; neither typed read introduces an extra diagnostic. Both `checkJs`
modes and the depth-zero boundary are asserted as exact CLI streams.
