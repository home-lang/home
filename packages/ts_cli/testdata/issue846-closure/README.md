# Admitted JavaScript roots and import closure (#846)

Run TypeScript 5.7.3 and Home from this directory with `-p CONFIG
--pretty false`, using each of `tsconfig.json`, `tsconfig-no-checkjs.json`,
and `tsconfig-implicit-checkjs.json`.

The only explicit roots are `main.ts` and `root.js`. The TypeScript root
imports `bridge.js`, which re-exports from `leaf.js`; `unused.js` is an
unadmitted sibling and must not supply diagnostics. The imported value is
typed as `number`, so the TypeScript consumer's string assignment fails
even when JS diagnostics are disabled.

With `allowJs` and `checkJs`, or with `checkJs` alone, both compilers report
TS2322 at `leaf.js:2:14`, `main.ts:4:7`, and `root.js:2:14`, in that order,
and exit 2. With `allowJs` but no `checkJs`, only the `main.ts:4:7`
diagnostic remains. `test-tsc-streams` asserts the exact output and exit
code for all three modes.
