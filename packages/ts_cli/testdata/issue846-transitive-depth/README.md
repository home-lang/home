# Transitive node_modules JavaScript admission (#846)

This fixture pins TypeScript 5.7.3's `maxNodeModuleJsDepth` behavior across
two package hops from an explicitly listed JavaScript root. `m1/index.js`
requires `m2`, which requires `m3`; only `m3` supplies the numeric value.
`checkJs` implicitly enables `allowJs`.

| Config | Exact diagnostic | Exit |
| --- | --- | ---: |
| `tsconfig.json` | TS7016 at `m1/index.js:1:22` for excluded `m2` | 2 |
| `tsconfig-depth-one.json` | TS7016 at `m2/index.js:1:22` for excluded `m3` | 2 |
| `tsconfig-depth-two.json` | TS2322 at `main.ts:4:7` for number-to-string assignment | 2 |

Both TS7016 messages include the absolute resolved JS path, without a
package-install hint because these packages have no package identity. The
exact CLI output and exit code for all three configs are asserted by
`zig build test-tsc-streams`. A passing result establishes this graph only,
not every JavaScript dependency shape.
