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

`tsconfig-no-resolve.json` checks the diagnostic-format boundary. With
`noResolve`, `bridge.js` is physically found but is not admitted to the
Program, so both compilers emit TS7016 at `main.ts:1:23` and TS2322 for
the explicit `root.js`. Both compilers' TS7016 includes the absolute
resolved path to `bridge.js`; Home keeps its relative Program identity
separate from that diagnostic path. The exact result is asserted in
`test-tsc-streams` and tracked in #954.

`tsconfig-no-jsx.json` is the parallel negative JSX control: an admitted
`.jsx` module is imported without selecting a `jsx` compiler option.
Both compilers must report TS6142 at `jsx.ts:1:24`, naming the absolute
resolved path to `widget.jsx`, and exit 2. This path uses the same
diagnostic-only resolver field as the TS7016 case; `test-tsc-streams`
asserts the exact message.
