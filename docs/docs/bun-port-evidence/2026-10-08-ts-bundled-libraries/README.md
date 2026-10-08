# TypeScript bundled compiler-host libraries

This checkpoint wires the pinned TypeScript standard-library inputs into
Home's conformance Program route for
[#841](https://github.com/home-lang/home/issues/841). It follows the compiler
host used by `typescript-go` instead of placing synthetic declarations beside
fixture files.

The authoritative pins are `typescript-go`
`89d5d5b2849a0db0957065889ca58536fa6d2e4a` and nested TypeScript
`5848bc5157b22ff7f4e3369f4645a514a433b15f`. Relevant upstream behavior lives
in:

- `internal/bundled/bundled.go`, whose compiler host supplies a separate
  bundled-library directory;
- `internal/compiler/fileloader.go`, which loads explicit or target-selected
  libraries from that directory and gates both branches behind `noLib`;
- `internal/tsoptions/enummaps.go`, which defines default filenames and the
  case-insensitive explicit-library alias map;
- `internal/compiler/program.go`, where `skipDefaultLibCheck` applies only to
  source files registered as default libraries;
- `internal/testutil/harnessutil/harnessutil.go`, which defaults
  `skipDefaultLibCheck` to true before applying fixture configuration.

## Implemented behavior

- All **108** files from `internal/bundled/libs` are mounted byte-for-byte at
  `/.typescript/lib` in the conformance VFS. This reserved compiler-host path
  cannot collide with `/lib.*.d.ts` files supplied by a fixture.
- Program receives the effective fixture/configuration `target`, `lib`,
  `noLib`, `types`, `typeRoots`, and `skipDefaultLibCheck` values. Expected
  baseline text is not an input to this selection.
- Default and triple-slash library references resolve from the same canonical
  compiler-host directory.
- Explicit names are case-insensitive and preserve the pinned compatibility
  aliases: `es6`, `es7`, and legacy `esnext.*` names select the same physical
  files as TypeScript.
- `noLib: true` suppresses both the default library and an explicit `lib`
  list, while type-reference discovery remains independent.
- `skipDefaultLibCheck` suppresses semantic diagnostics only for declaration
  files inside the compiler-host directory. Fixture and package declaration
  files continue to report semantic errors.

No declaration was synthesized, no fixture or expected baseline changed, and
no resource limit was raised.

## Guarded verification

Every substantial command ran serially through `scripts/run-bounded.pl` with
`HOME_RUN_MAX_MB=3840`.

- Complete `ts_program` package: pass, including isolated compiler-host lookup,
  the explicit alias map, `noLib` precedence, and distinct default/fixture
  declaration checking; peak 2,230 MB, host low-water 32%.
- Complete `ts_driver` package: pass, including independent propagation of
  `skipLibCheck` and `skipDefaultLibCheck`; peak 1,995 MB, host low-water 28%.
- Exact-byte mount control: all 108 files present, selected bytes equal the
  pinned physical source, and no root-level shadow path exists.
- Real-byte Program integration: pinned `lib.es2023.intl.d.ts` loads through
  the compiler-host namespace with the compiler-library include reason and
  default-library-only skip policy; peak 2,070 MB, host low-water 31%.
- Named real-fixture category gate: **87/87 passed**, zero failures and zero
  skips; peak 2,116 MB, host low-water 44%.

A separate exact run of the real `typeFromPropertyAssignment8_1` fixture
(`@lib: es6,dom`) reached the unchanged 600-second wall bound and exited 124
without a result. It is deliberately **not** counted as passing evidence. The
full DOM declaration graph remains a performance/coverage follow-up; replacing
it with a smaller declaration, increasing the bound, or reporting a partial
result would make the corpus input dishonest.

This closes the bundled-library input slice for the Program route only.
Single-source fixtures that still use the legacy compile path, compiler-API
fixtures requiring built `typescript.d.ts`, complete input-invariance evidence,
and complete-corpus regeneration remain open in #841. Full Bun acceptance
remains tracked in [#66](https://github.com/home-lang/home/issues/66).
