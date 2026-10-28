# Admitted JavaScript roots and import closure (#846)

Run TypeScript 5.7.3 and Home from this directory with `-p CONFIG
--pretty false`, using each of `tsconfig.json`, `tsconfig-no-checkjs.json`,
and `tsconfig-implicit-checkjs.json`.

The only explicit roots are `main.ts` and `root.js`. The TypeScript root
imports `bridge.js`, which re-exports from `leaf.js`; `unused.js` is an
unadmitted sibling and must not supply diagnostics. The imported value is
typed as `number`, so the TypeScript consumer's string assignment fails
even when JS diagnostics are disabled.

The editor lifecycle has a separate invariant: an import-only JavaScript
owner is admitted while reachable, retired when the importer removes its
edge, and readmitted under the same Program file identity when that import
returns. The focused Program tests exercise both `checkJs` modes and contrast
that owner with an explicitly listed JavaScript root, which must stay admitted
after an importer removes its edge. `LspProject` tests cover the actual
`didOpen`/`didChange` diagnostic publications for the import-only sequence,
and verify that a `files`-listed JavaScript root keeps its identity and
diagnostics through removal and restoration of the importer edge when
`checkJs` implicitly enables JavaScript admission.

`tsconfig-root-only.json` is the static TypeScript 5.7.3 oracle for the
explicit-root half of that lifecycle: `main-no-import.ts` has no dependency
edge, yet the listed `root.js` still reports TS2322 at `2:14`. The stream
suite asserts the exact output and error exit.

With `allowJs` and `checkJs`, or with `checkJs` alone, both compilers report
TS2322 at `leaf.js:2:14`, `main.ts:4:7`, and `root.js:2:14`, in that order,
and exit 2. With `allowJs` but no `checkJs`, only the `main.ts:4:7`
diagnostic remains. `test-tsc-streams` asserts the exact output and exit
code for all three modes.

With `--allowJs false --checkJs false`, TypeScript rejects the explicit
`root.js` with TS6504 before it enters the Program. The diagnostic names
its absolute path, even when `-p tsconfig.json` was relative; a positional
JavaScript root instead keeps the path as typed. The stream suite asserts
the config-root wording and path exactly.

`tsconfig-missing-root.json` lists `root.js` before the missing
`missing.ts` to check diagnostic ordering. TypeScript reports TS6053 for
the absent root without aborting the whole run. With JavaScript admission
disabled, it reports TS6053 and TS6504 in path order, not `files` order;
semantic errors from the existing roots do not replace either option-phase
diagnostic. The stream suite checks both exact outputs and exit status.
The positional `missing.ts` control retains its relative CLI spelling.
`tsconfig-missing-root-syntax.json` checks the earlier syntax phase: TS1109
in `bad-syntax.ts` suppresses TS6053 until the syntax error is fixed.

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

`tsconfig-jsx-no-allowjs.json` enables JSX syntax but explicitly disables
JavaScript admission, so the same import reports TS7016 instead of TS6142.
The `tsconfig-checkjs-no-allowjs*.json` controls explicitly set
`checkJs: true` and `allowJs: false` in both key orders. TypeScript emits
TS5052 at both option keys, in source order; the stream suite asserts
both diagnostics and exit 2.

## Cross-fixture oracle audit

From the repository root, build a fresh `home-tsc` and compare under the
3,840 MB guard, sequentially:

```sh
HOME_RUN_MAX_MB=3840 perl scripts/run-bounded.pl 900 zig build home-tsc -j1
HOME_RUN_MAX_MB=3840 perl scripts/run-bounded.pl 900 node scripts/tests/compare-issue846-oracles.mjs
```

The script requires TypeScript 5.7.3 and compares the exact stdout, stderr,
and exit status for every `issue846-*` `tsconfig*.json` (84 configs as of
2026-10-28). It passes `--noEmit` to both CLIs so the audit cannot modify
fixture outputs. The fresh 2026-10-28 CLI matched all 84 configs. This
enumerated fixture result does not establish arbitrary JavaScript inference
or LSP revision parity; those need their own focused and editor tests.
