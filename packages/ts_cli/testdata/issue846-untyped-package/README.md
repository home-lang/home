# JavaScript package admission and CommonJS whole exports (#846)

Run `tsc -p CONFIG --pretty false` and `home-tsc -p CONFIG --pretty false`
from this directory. The package is a real `node_modules/untyped-package`
directory with a CommonJS `module.exports = 42` entry point.

At the default `maxNodeModuleJsDepth: 0`, both compilers leave the package
unadmitted and report only TS7016 on `main.ts:1:19`, including the absolute
resolved path and remediation hint. At depth 1, the package is admitted:
the import has type `number`, so both report only TS2322 on `main.ts:2:7`.
The relative `./local.js` control has the same whole-module export and
reports TS2322 on `consumer.ts:2:7` without a package-depth setting.

These three exact CLI streams and exit codes are asserted by
`zig build test-tsc-streams`. The test distinguishes source admission from
type transfer: a default import must not fall back to `any` after an admitted
whole CommonJS export has a checked type.
