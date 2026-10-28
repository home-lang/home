# Anonymous default JavaScript function admission (#846)

Run `tsc -p CONFIG --pretty false` and `home-tsc -p CONFIG --pretty false`
from this directory. The oracle is TypeScript 5.7.3. Each config deliberately
reports TS2322 for a number result assigned to a string and TS2345 for a
string argument passed to the JSDoc-constrained number parameter; stdout,
stderr, and exit status must match exactly.

`tsconfig.json` admits the owner through the re-export import closure with
`checkJs` on. `tsconfig-no-checkjs.json` turns owner diagnostics off while
preserving the imported type. `tsconfig-checkjs-only.json` omits `allowJs` to
check its implication from `checkJs`. `tsconfig-explicit.json` lists the
JavaScript owner as an explicit root. `tsconfig-direct.json` bypasses the
re-export. The associated Program test checks serial/parallel compilation and
an owner JSDoc edit/revert; the LspProject test checks watched-owner
diagnostic publication through the re-export in both `checkJs` modes.

This fixture covers the JSDoc-before-`export` ownership edge, not every
JavaScript function inference or LSP lifecycle.
