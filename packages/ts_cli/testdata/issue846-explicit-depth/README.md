# Explicit JavaScript root and dependency-depth oracle (#846)

This fixture pins TypeScript 5.7.3's treatment of an explicitly listed
`node_modules/m1/index.js` root. That file requires both a relative sibling
(`./local`) and another package (`m2`). Both dependencies have no declaration
file or package identity; they enter the Program only when
`maxNodeModuleJsDepth` is one.

| Config | TypeScript exit | Diagnostics |
| --- | ---: | --- |
| `tsconfig.json` | 0 | none; the explicit JS root is admitted, its dependencies are not |
| `tsconfig-depth-one.json` | 2 | TS2322 in `main.ts` at 4:7 and 6:7 |
| `tsconfig-implicit-checkjs.json` | 2 | TS7016 in `m1/index.js` at 1:23 for `./local`, and 2:22 for `m2`; neither has an install-types hint |
| `tsconfig-implicit-checkjs-depth-one.json` | 2 | TS2322 in `main.ts` at 4:7 and 6:7 |

The implicit-checkJs configs deliberately omit `allowJs`: TypeScript enables
JavaScript admission when `checkJs` is true. At depth zero, it checks the
explicit root but does not infer types from either excluded dependency.
