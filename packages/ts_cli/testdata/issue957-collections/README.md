# Checked JavaScript collection imports (#957)

These fixtures compare `home-tsc` with TypeScript 5.7.3 for six collection
exports: `Map`, `ReadonlyMap`, `Set`, `ReadonlySet`, `WeakMap`, and `WeakSet`.
Both CommonJS and ESM owners are imported from TypeScript, with `checkJs`
enabled and disabled. `allowJs`, `strict`, `noEmit`, and ES2022 are common
to all four configs.

Run `tsc -p tsconfig-commonjs.json --pretty false` (or any other config here)
and the same command with `home-tsc`. Each run must exit 2 with exactly six
consumer diagnostics, in source order: TS2345, TS2339, TS2345, TS2339,
TS2345, TS2345. The `test-tsc-streams` build step checks the exact output.
The two readonly errors verify that JSDoc declaration types survive the JS
owner boundary even when `checkJs` is disabled; the WeakMap/WeakSet errors
verify object-valued generic arguments rather than permissive `any` recovery.
