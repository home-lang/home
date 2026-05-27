# Bun Parity Plan - Home

> **Status:** Planning baseline refreshed 2026-05-26. This is the
> agent-facing execution plan for Bun runtime parity. Detailed API status
> remains in [`PARITY-BUN.md`](./PARITY-BUN.md), Node status in
> [`PARITY-NODE.md`](./PARITY-NODE.md), and shim status in
> [`PARITY-BUN-COMPAT.md`](./PARITY-BUN-COMPAT.md).
>
> **Scope guard:** This document coordinates documentation, measurement,
> and runtime-parity workstreams. It does not authorize source changes by
> itself. Agents still follow [`packages/runtime/README.md`](../packages/runtime/README.md)
> before touching runtime code.

---

## Current Baseline

The upstream pin is consistent today:

- `/Users/chrisbreuer/Code/bun` HEAD:
  `fd0b6f1a271fca0b8124b69f230b100f4d636af6`
- `packages/runtime/UPSTREAM_SHA.txt`:
  `fd0b6f1a271fca0b8124b69f230b100f4d636af6`

Cheap live recount from `scripts/measure-parity.sh --values` on
2026-05-26 in `/private/tmp/home-bun-parser-latest` after commit
`bbaf1d10`:

| Measurement | Value | What it means |
|---|---:|---|
| `RUNTIME_ZIG_PRESENT_FILES` | 1392 | Zig files present in `packages/runtime/src/`; **not** integrated parity credit |
| `RUNTIME_SUBSYSTEMS` | 98 | Top-level runtime source directories present |
| `RUNTIME_ZIG_DORMANT_FILES` | 797 | Source-first copied Zig files in `packages/runtime/DORMANT_BUN_ZIG_IMPORT_2026-05-21.txt`; still awaiting rewrite/wiring/tests |
| `BUN_UPSTREAM_FILES` | 1193 | Audited Bun baseline from the 2026-05-18/20 audit, excluding tests/codegen/macros |
| `NODE_FILES` | 28 | Zig files currently under `packages/runtime/src/node/` |
| `JSC_FILES` | 128 | Zig files currently under `packages/runtime/src/jsc/` |
| `COMPAT_SYMBOLS` | 16 / ~103 | Top-level `bun.*` shim symbols in `packages/compat/src/compat.zig` |

Honest interpretation:

- Raw runtime files present now exceed the old audited Bun denominator.
  That is expected because `packages/runtime/src/` contains dormant Bun
  source backlog plus Home adapters. It must not be reported as
  `>100%` runtime parity.
- Upstream Zig source presence is now complete in this main-based
  worktree. The 72-path JSC-adjacent source gap was copied from
  `/Users/chrisbreuer/Code/bun/src/` into `packages/runtime/src/`,
  preserving relative paths and leaving zero missing upstream Zig paths.
  See
  [`BUN_ZIG_SOURCE_AUDIT_2026-05-26.md`](./BUN_ZIG_SOURCE_AUDIT_2026-05-26.md).
- Copied Bun corpus presence is complete for the pinned checkout:
  `/Users/chrisbreuer/Code/bun/test/**/*.test.{ts,js}` and
  `packages/runtime/test/bun-corpus/**/*.test.{ts,js}` both contain
  **1720** files, with zero missing and zero extra copied test paths.
- The last audited integrated baseline is still **552 / 1193 (~46.3%)**:
  Home-import-rewritten, Zig 0.17-clean, build-wired, and tested. Do not
  raise that number without a fresh integration audit.
- The runtime is not JS-callable end-to-end yet. Phase 12.2 JSC bring-up
  has real milestones, including native eval smoke coverage, but the
  full `home run app.ts` path still waits on the JS-callable bridge and
  loader/test-runner wiring.
- Pantry is intentionally the package manager. `bun install` source
  parity is not a goal; Bun package-management behavior maps to Pantry
  gates instead.

## Definition Of Parity

Bun parity has four separate ledgers. Keep them separate in docs and PR
descriptions:

| Ledger | Credit only when | Primary evidence |
|---|---|---|
| Source presence | The upstream file is copied or mirrored into the repo | copy manifest or audit note |
| Integrated source | The file is Home-import-rewritten, Zig 0.17-clean, build-wired, and tested | focused build/test result plus porting status |
| JS-visible API | The API is callable from JavaScript through Home's runtime, not only Zig substrate | fixture or Bun-corpus smoke run by Home |
| Corpus parity | Upstream Bun tests pass through Home with no local rewrite or skip | `home test packages/runtime/test/bun-corpus/` |

The release goal is corpus parity, not source-file volume.

Source-first Zig inventories stay in the source-presence ledger until they
cross the integration gates. Bun is refactoring parts of its runtime from
Zig to Rust upstream; Home intentionally copies and maintains Bun's Zig
source rather than treating the Rust rewrite as parity source.

### Faithful Zig Source Policy

The source of truth for copied runtime behavior is the pinned Zig tree in
`/Users/chrisbreuer/Code/bun`, not Bun's newer Rust refactors. When Bun
replaces a Zig subsystem with Rust upstream, Home keeps the last pinned
Zig implementation as maintained Home source until a deliberate Home
design decision replaces it.

Porting rules for source agents:

- Copy whole upstream Zig subsystems in large chunks before local
  massage, keeping the original file layout, attribution, and upstream
  comments unless they are mechanically invalid in Home.
- Rewrite imports, allocator names, Zig 0.17 stdlib drift, and Home
  subsystem boundaries as integration work; do not change semantics to
  make a narrow fixture pass.
- Record dormant copied files separately from integrated files. A copied
  file gets no integrated-parity credit until it is Home-import-rewritten,
  build-wired, and covered by a focused test or corpus gate.
- Prefer upstream Bun behavior over Home convenience. Pantry is the
  intentional package-manager divergence; everything else needs an
  explicit documented compatibility decision before diverging.
- For tests, port Bun's tests to run logically against Home. Rewriting a
  test is allowed only to adapt harness plumbing, never to weaken the
  behavioral assertion.

## Phase Goals

### Process State

**Last updated:** 2026-05-26. Bun source presence is complete for the
pinned `/Users/chrisbreuer/Code/bun` Zig checkout, but integrated runtime
parity remains at the last audited **552 / 1193 (~46.3%)** until a fresh
integration audit moves it. The executable corpus ratchet is focused on
the remaining 2-file bundler frontier after `minimal-js`,
`bundler-core-itbundled`, `bundler-transpiler-bootstrap`, and the native
plugin corpus file established green Home-run bootstrap slices. The next
work is intentionally split across big independent agent chunks:
decorator semantics, `Bun.Transpiler` and macro surface, then
Bake/server-heavy corpus.

### Phase 0 - Measurement And Audit Hygiene

Goal: make every claimed number reproducible.

Done when:

- `scripts/measure-parity.sh --values` is documented as a raw-count
  helper, not an integrated-parity authority.
- The integrated-file denominator and numerator are refreshed by an
  audit script or explicit status ledger before docs claim movement.
- Dormant Bun backlog, Home adapters, and integrated ports are counted
  as separate buckets.
- `docs/PARITY-BUN.md`, this plan, and `packages/runtime/README.md`
  agree on the latest baseline.

### Phase 1 - JSC JS-Callable Bridge

Goal: make Home execute JavaScript through the native runtime path.

Done when:

- `home eval "1 + 2"` runs through JavaScriptCore without delegating to
  system Bun.
- JSC exception values map into Home runtime errors with stable
  diagnostics.
- The bridge has focused tests for primitive values, strings, promises,
  thrown exceptions, and retained callbacks.
- JSC bridge tests pass with `-Denable_jsc=true` on macOS.

### Phase 2 - Loader And CLI Runtime Path

Goal: replace delegation scaffolding for basic `home run`.

Done when:

- `home run file.js` and `home run file.ts` execute through Home's JSC
  runtime and in-process TS transform path.
- ESM, CommonJS, JSON, and TypeScript module loads have focused fixtures.
- Bare package resolution enters Pantry, not Bun's installer.
- CLI delegation sites are either removed or still marked with a
  specific open phase.

### Phase 3 - Web, Bun, And Node Surface Ladders

Goal: turn substrate into JS-visible APIs in priority order.

Done when:

- Web primitives needed by real apps are callable: `URL`, `Blob`,
  `Request`, `Response`, `Headers`, streams, timers, `fetch`, and
  `WebSocket`.
- Bun-compatible APIs have Home-native implementations plus the
  compatibility alias where required by corpus tests.
- Tier-A `node:*` modules pass focused fixtures before broad corpus
  expansion: `fs`, `path`, `process`, `buffer`, `stream`, `events`,
  `util`, `crypto`, `http`, `net`, `url`, `child_process`, and `assert`.

### Phase 4 - Test Runner And Corpus Ratchet

Goal: make Bun's test suite the merge gate.

Done when:

- `home test packages/runtime/test/bun-corpus/` discovers and runs the
  copied corpus natively.
- The runner supports Bun's test shapes used by the corpus:
  `test`, `describe`, `expect`, hooks, snapshots, mocks, retries,
  concurrent/each variants, and async lifecycle behavior.
- Each newly passing corpus slice is recorded with command, count, and
  blockers.
- No corpus skip is introduced unless upstream Bun itself skips the same
  test under the same platform condition.
- The copied Bun corpus reaches **100% no-skip parity** for the supported
  platform matrix: every discovered Bun-style test file either runs and
  passes natively through Home or is excluded only because upstream Bun
  excludes it under the same platform condition.

#### Corpus Ratchet Ledger

Current corpus scale for the next ratchet:

| Bucket | Count | Notes |
|---|---:|---|
| Copied Bun-style test files in read-only corpus audit | 1735 | `*.test.{ts,js,mjs,cjs}` / `*.spec.{ts,js}` under `packages/runtime/test/bun-corpus` |
| `js/` test files | 998 | Largest remaining general-runtime corpus bucket |
| `regression/` test files | 384 | Broad bug/regression frontier after API ladders mature |
| `cli/` test files | 150 | CLI/run/install/test subprocess behavior; Pantry divergence must be documented |
| `bundler/` test files | 89 | Current active corpus ratchet; 87 unique green and 2 files left |
| `napi/` test files | 59 | Native addon / libuv / N-API gate after native plugin bridge |
| `bake/` test files | 24 | Next server-heavy tranche after bundler |
| `integration/` test files | 20 | Cross-surface integration frontier |
| Small corpus buckets | 11 | `internal` 7, plus one each for `config`, `package-json-lint`, `snippets`, and `v8` |
| Discovered Bun-style test files | 4013 | Full copied-corpus scale for Home's Bun-style test discovery |
| Minimal-JS subset entries | ~418 | Bootstrap subset currently used for the smallest JS-capable corpus gate |
| Minimal-JS unique files | 417 | One duplicate entry remains in the subset ledger |
| Outside minimal-JS subset | 3621 | Remaining copied-corpus frontier after the bootstrap subset |

Next large slice: **bundler corpus completion**. A local audit on
2026-05-26 finds **89** copied `bundler/**/*.test.{ts,js}` files. The
current green evidence covers **87 unique files**: 66 unique bundler
files inside `minimal-js`, 5 more in `bundler-core-itbundled`, and 15
more from the executable 20-file `bundler-transpiler-bootstrap`
subset, plus `bundler/native-plugin.test.ts`. Promote the remaining
exact **2** files into native Home corpus gates before expanding into
more Bake or server-heavy tests.

First agent-sized chunk: **ordinary `itBundled` execution tranche**.
Start with these broad, high-value files because they mostly exercise
`itBundled` through `expectBundled`, while `cli.test.ts`,
`native-plugin.test.ts`, resolver-cache tests, and feature-flag tests
pull in process spawning, native-plugin ABI, cache runtime state, or
`bun test/run` behavior:

- `bundler/bundler_html.test.ts`
- `bundler/bundler_jsx.test.ts`
- `bundler/bundler_loader.test.ts`
- `bundler/esbuild/extra.test.ts`
- `bundler/esbuild/metafile.test.ts`

Harness status: `bundler_core_itbundled` now exists in
`packages/home_test/src/corpus_runner.zig` and is accepted by
`home test --bun-corpus-native-subset=bundler-core-itbundled`. The
current subset runs all five files and passes under the bootstrap
runner: **295 passed, 0 failed, 16 upstream todo** on 2026-05-26. This
closed the TypeScript/non-null lowering blocker for the first ordinary
`itBundled` tranche.

Second agent-sized chunk: **bundler transpiler bootstrap tranche**.
`bundler_transpiler_bootstrap` now exists and is accepted by
`home test --bun-corpus-native-subset=bundler-transpiler-bootstrap`.
It runs sixteen additional bundler/transpiler files plus the CLI build
surface and resolver cache tranche, passing:
**320 passed, 0 failed, 2 upstream/platform todo**
on 2026-05-26.

Files in the tranche:

- `bundler/bundler_feature_flag.test.ts`
- `bundler/plugin-error-nested-throw.test.ts`
- `bundler/transpiler/decorator-metadata.test.ts`
- `bundler/transpiler/es-decorators.test.ts`
- `bundler/transpiler/es-decorators-esbuild.test.ts`
- `bundler/transpiler/preserve-use-strict-cjs.test.ts`
- `bundler/transpiler/template-literal.test.ts`
- `bundler/transpiler/function-tostring-require.test.ts`
- `bundler/transpiler/export-default.test.js`
- `bundler/transpiler/scope-mismatch-panic.test.ts`
- `bundler/transpiler/bun-pragma.test.ts`
- `bundler/transpiler/property.test.ts`
- `bundler/transpiler/transpiler-stack-overflow.test.ts`
- `bundler/transpiler/jsx-production.test.ts`
- `bundler/transpiler/runtime-transpiler.test.ts`
- `bundler/transpiler/macro-test.test.ts`
- `bundler/cli.test.ts`
- `bundler/resolver/cache-invalidation.test.ts`
- `bundler/resolver/cache-node-compat.test.ts`
- `bundler/resolver/cache-runtime.test.ts`

Remaining bundler file frontier after the 20-file transpiler/CLI/resolver tranche
and native-plugin promotion, classified by next faithful work batch:

| Tranche | Files | Primary blocker from local corpus |
|---|---|---|
| A. Legacy decorator transpiler semantics | `bundler/transpiler/decorators.test.ts` | Top-level legacy decorator lowering; latest probe reaches the real parser blocker, `SyntaxError: Invalid character: '@'` |
| B. Transpiler API surface | `bundler/transpiler/transpiler.test.js` | `Bun.Transpiler`, loader validation, transform APIs, and callback behavior |

Agent handoff order for the remaining bundler work:

1. **Decorator semantics agent:** copy/integrate the parser and
   transpiler decorator lowering substrate needed by
   `bundler/transpiler/decorators.test.ts`.
2. **Transpiler/macro agent:** wire `Bun.Transpiler`, macro import
   resolution, macro execution, and the wider transpiler API enough to
   promote `bundler/transpiler/transpiler.test.js`.

Fresh single-file probes on 2026-05-26 in
`/private/tmp/home-bun-parser-latest`:

| Command | Result | Current blocker |
|---|---|---|
| `./zig-out/bin/home-debug test packages/runtime/test/bun-corpus/bundler/transpiler/transpiler.test.js` | Fails before promotion: 0 passed, 1 failed | Enters `Bun.Transpiler.transformSync`; CRLF and empty-type-parameter probes now advance, and the current bootstrap-body blocker is the malformed-enum parse-error section |
| `./zig-out/bin/home-debug test packages/runtime/test/bun-corpus/bundler/transpiler/decorators.test.ts` | Fails before promotion: 0 passed, 1 failed | `SyntaxError: Invalid character: '@'` |
| `./zig-out/bin/home-debug test packages/runtime/test/bun-corpus/bundler/native-plugin.test.ts` | **Passes: 6 passed, 0 failed, 0 unsupported** | Home now dlopens the built `.node` addon, runs Node-API registration callbacks, exposes N-API externals/functions, calls the Bun native `onBeforeParse` ABI, and routes the generated `bun run dist/index.js` output through the build artifact |

Native plugin promotion update on 2026-05-26: the JSC corpus adapter now
keeps real addon handles alive, exports the small Node-API surface needed
by Bun's copied native-plugin fixture, and calls `plugin_impl*` through
Home's Bun-compatible `NativePluginABI`. The harness no longer counts a
corpus-only module mock here; the copied `bundler/native-plugin.test.ts`
file passes through `home-debug` with the real node-gyp build products.

Decorator helper follow-through on 2026-05-26: the native corpus harness
now exposes Bun's `bun:wrap` runtime helper surface for transformed output:
legacy TypeScript decorator helpers, standard decorator helpers,
private-field helpers, and `__publicField`. This does not promote
`decorators.test.ts` yet; it
removes the runtime-helper blocker so the remaining work is the faithful
native parser/lowerer/printer handoff described above.

Native transpiler substrate follow-through on 2026-05-26: `home_rt` now
exposes the copied Bun parser/printer/transpiler surface through the flat
`bun.*` namespace: `logger`, `js_lexer`, `js_parser`, `js_printer`,
`ast`, `options`, `transpiler`, `Transpiler`, `bundle_v2`, and
`SourceMap`. The copied parser aggregators now resolve Home's existing
`src/ast`, `js_parser/parse`, `js_parser/scan`, `js_parser/lower`, and
`js_parser/visit` files instead of stale `js_parser/ast/*` CamelCase
paths from older Bun copies. This is a compile substrate, not corpus
credit.

Native transpiler bridge follow-through on 2026-05-26: the corpus JSC
adapter now creates native `Bun.Transpiler` handles through registered
host callbacks, validates loader/platform/define option shapes on the
native side, stores per-instance option state, resets handles with the
runtime, and routes `transformSync`/`transform` through the native
callback boundary. The current transform body intentionally stays at the
bootstrap-normalization level so `main` remains green while the copied
Bun parser/printer dependency cone is finished. The next faithful chunk
is to replace that body with the real parser-to-printer path
(`Parser.init`, `parse`, `js_printer.printAst`), including `define`,
scan/scanImports, and decorator lowering.

Parallel-agent probe finding on 2026-05-26 (two independent agents, TS-enum
and decorator): **the parser/lexer/decorator code itself is already a
faithful, byte-identical port of pinned Bun and needs no fixes.** The
decorator agent verified the `@` lexer token (`js_parser/lexer.zig:1225`),
`parseTypeScriptDecorators`/`parseStandardDecorator`, `visitTSDecorators`,
`lowerClass` (legacy TS `__legacyDecorate*` + metadata), and
`lowerStandardDecoratorsStmt/Expr` are all diff-clean against Bun.

The real gate for switching on `use_bun_parser_probe` is therefore **not**
the parser — it is that enabling the real path statically pulls the
resolver + JSON-parser + package-manager + tsconfig/package_json cone into
compilation, via `parse() -> e_template visit -> MacroContext.call ->
Resolver.resolve -> getPackageManager` (the macro reference is gated by
`comptime allow_macros = FeatureFlags.is_macro_enabled`, true on macOS, so
the cone is mandatory at compile time even though `no_macros = true`
disables it at runtime). With the flag `false` that cone is dead-code
eliminated, which is why `main` stays green.

Foundational leaves for that cone landed in
`feat(runtime): advance real-parser transpile resolver-cone leaves`:
`sys.File.from/read/readAll/getEndPos/stat`, `sys.read/readAll/fstat/getFileSize`,
`getThreadCount`, an un-parked `threading.ThreadPool`, `strings.BOM`, the
`mimalloc`/`Global` thread-pool no-ops, and `install.PackageInstall`. The
remaining cone-compile checklist (the actual next milestone, consistent with
the Pantry divergence — compile with parked install stubs, not real
installer behavior):

- Port `parsers/json.zig` to the Zig-0.17 reflection API (`@Type` field
  names) and add `bun.deprecated.SinglyLinkedList`; then wire `bun.json`.
- Add `strings.NewGlobLengthSorter`, `home_rt.StringBuilder`, and fix
  `resolver/package_json.zig` `asArray()` shape (`items`).
- Migrate the `install/*` cone off pre-0.17 `std.fs.Dir`/`std.fs.File`
  (→ `std.Io.Dir`), add `Output.err`, `Progress`, and the ~30 missing
  `install.*` aggregator exports; fix `HashMap.values` (0.17 API) in the
  resolver.

**Cone-compile progress — iteration 2 landed on `main` (2026-05-26).** All
three checklist bullets above are now done (3 parallel agents, all green,
no corpus regression):
- `parsers/json.zig` ported to Zig-0.17 reflection; faithful
  `bun.deprecated.SinglyLinkedList` (new `bun_core/singly_linked_list.zig`);
  `bun.json` wired to the real parser.
- `strings.NewGlobLengthSorter`/`NewLengthSorter` re-exported from the
  faithful `string/immutable.zig`; top-level `bun.StringBuilder` =
  `core/string/StringBuilder.zig` (the pure-Zig builder, not the WTF wrapper).
- 13 `install/*` files migrated to `std.Io.Dir`/`File`; `Output.err`+helpers;
  `bun_core/Progress.zig` migrated; ~30 `install.*` exports; resolver
  `valueIterator`; `**` array-repeat → `@splat`.

**Two cone gates remain before the real parser can switch on:**
1. **`home_rt.ast` is a stub.** It exposes only a placeholder `Expr` (no
   `E`, `asArray`, `ArrayIterator`), so `resolver/package_json.zig`,
   `tsconfig_json.zig`, and `bundler/cache.zig` (all `js_ast = bun.ast`)
   cannot compile. The faithful AST copies exist (`ast/e.zig`, `ast/expr.zig`)
   but reference `bun.ast.E`, a circular dep that must be wired together as
   one unit. This is the next foundational unlock.
2. **`install/NetworkTask.zig` needs the HTTP client cone**
   (`bun.http.{AsyncHTTP, HeaderBuilder, HTTPClientResult}`), parked at
   Phase 12.5. Per the Pantry divergence it only needs to *compile* (parked
   stubs), not perform real network installs.

Note: `use_bun_parser_probe` / `transpileSourceWithBunParser` are NOT on
canonical `main` — a ts-parity merge (`6e67f7dd`) appears to have landed an
older `jsc_bootstrap.zig` that predates that scaffold. Re-add the real-parser
transform body (or re-derive it) once the two cone gates above compile.

Once the cone compiles, the real-parser body flips on and decorators + TS
enums transpile through the already-faithful parser with no parser changes.

**MILESTONE — iterations 3-4 landed on `main` (2026-05-26): the full
real-parser cone compiles end-to-end.** The HTTP cone closed (`dcd351b9`:
`NetworkTask` compiles via Home's already-present 3300-line http client
port — just needed `home_rt.http` re-exports of `AsyncHTTP`/`HeaderBuilder`/
`HTTPClientResult`/`FetchRedirect`). The AST keystone was already wired
(`home_rt.ast = js_parser/js_parser.zig`, the real aggregator with
`E`/`Expr`/`asArray`/`ArrayIterator`; `package_json`/`tsconfig`/`cache`
compile — verified by error-injection). The `transpileSourceWithBunParser`
scaffold + `use_bun_parser_probe` flag are present on `main`. With the flag
ON, `zig build debug` (the `home-debug` exe pulling the whole real-parser →
resolver/macro/AST/printer/http cone) compiles **green end-to-end**, and the
bootstrap corpus subset is **identical ON vs OFF — zero regressions**. The
flag stays `false` (dead-code-eliminated, `main` green) until the real path
clears the last behavioral gaps.

**Remaining behavioral gaps (the real parser runs; these are exact-output
parity, not compile blockers), probed via `home-debug test`:**
1. **Legacy decorator lowering not engaging** —
   `bundler/transpiler/decorators.test.ts`: transpiled output still contains
   `@` (JSC throws `SyntaxError: Invalid character: '@'`). The decorator
   lower/visit/print code is byte-identical-faithful to Bun, so the fix is
   wiring: ensure `transpileSourceWithBunParser`'s `parser_options.features`
   engage legacy/standard decorator lowering and the printer emits the
   `__legacyDecorateClassTS`/`__decorateClass` runtime-helper form.
2. **TS enum member-key validation** —
   `bundler/transpiler/transpiler.test.js`: `enum Foo { [2]: 'hi' }` is not
   rejected; Bun emits `Expected identifier but found "["`.

(Pre-existing, flag-agnostic `bundler/resolver/cache-runtime.test.ts` was
fixed in `04049051` — the corpus `require()` now falls through to a disk read
so delete+recreate invalidation works; 3/3 pass.)

**CRITICAL REFRAME (2026-05-26) — there are TWO transpile paths, and the
probe only governs one of them.** The corpus harness loads `*.test.ts`/`.js`
FILES through `corpus_runner.zig`'s hand-written string-rewrite transpiler
(`prepareCorpusModule` → `rewriteBunTestImport` → `rewriteBootstrapTypeScript`),
which does NOT lower decorators or run the real parser. `use_bun_parser_probe`
only gates `transpileSource`, which is reached EXCLUSIVELY by the
`Bun.Transpiler.transformSync` *API*. Consequences:
- `decorators.test.ts` fails at module-LOAD with `Invalid character '@'`
  regardless of the probe — its own source uses decorators and the
  string-rewrite loader can't lower them. The decorator lower/visit/print code
  in `js_parser` is byte-faithful to Bun; it simply isn't on the loader path.
- `transpiler.test.js` exercises the `Bun.Transpiler` API, so it IS governed
  by the probe — once the cone compiles and the probe flips, the
  already-faithful enum/parse behavior applies there.

So the real corpus-wide unlock is bigger than "flip the flag": **route the
corpus module LOADER through the real parser** (replace/augment
`rewriteBootstrapTypeScript` with the real `Parser.init`→`parse`→`printAst`
path, same as `transpileSourceWithBunParser`). That is the next major
integration after the cone compiles. Sequencing:
1. Finish the cone compile (small Zig-0.17 leaf cascade; `semver String.Builder`,
   `http.Method`, `ast` cast, `strings.startsWithWindowsDriveLetter` landed in
   `58ff0993`; remaining leaves being ground out).
2. Flip `use_bun_parser_probe` on for the `Bun.Transpiler` API path (land
   `transpiler.test.js` etc.) once the bootstrap subset stays green.
3. Route the corpus module loader through the real parser → decorators and the
   broad transpiler/bundler corpus transpile through the faithful parser.

**MILESTONE — THE REAL BUN PARSER LINKS AND RUNS OVER THE CORPUS
(2026-05-26, `474a9b0f`).** With macros comptime-disabled
(`-Denable_macros=false`), scalar Highway (`a3869510`), the JSC-bridge
gate (`c5688ed4`), and parked JSC module-record panic-stubs (`474a9b0f`,
dead on the transpile/corpus path), `zig build debug -Denable_macros=false`
with `use_bun_parser_probe = true` **links into a runnable `home-debug`**
that transpiles through the real `Parser.init → parse → js_printer.printAst`
path. First real-parser corpus results:
- `bundler/transpiler/property.test.ts`: **PASS (1/0)** — a real transpiler
  corpus file transpiled correctly by the faithful parser.
- `bundler/transpiler/transpiler.test.js`: FAIL (0/1) — first real divergence
  is the `malformed enums` case: `enum Foo { [2]: 'hi' }` must throw
  `Expected identifier but found "["`, but the real parser silently accepts a
  bracketed/computed enum member name. (NB: an earlier *static* read called
  the enum path faithful; the *runtime* shows it is not — the bracketed-key
  rejection is missing.)

To reproduce/iterate: set `use_bun_parser_probe = true`, `zig build debug
-Denable_macros=false`, then `./zig-out/bin/home-debug test <corpus-file>`.
The probe flag stays `false` on `main` (DCE keeps it green) until enough of
the transpiler corpus passes to flip it.

**REAL-PARSER TRANSPILER-CORPUS FRONTIER MAP (recon 2026-05-26, probe on,
`-Denable_macros=false`, base `67169cce`):** of 16 `bundler/transpiler/*`
files, **14 PASS** through the real parser — `property` (1), `template-literal`
(1), `preserve-use-strict-cjs` (2), `function-tostring-require` (1),
`export-default` (1), `bun-pragma` (7), `jsx-production` (32),
`runtime-transpiler` (13), `scope-mismatch-panic` (3),
`transpiler-stack-overflow` (1), `es-decorators` (27), `es-decorators-esbuild`
(147), `decorator-metadata` (5), `macro-test` (10). Only **2 genuine failures
remain**, and the enum one is NOT a parser bug:
1. `transpiler.test.js` — the parser DOES reject `enum Foo { [2]: 'hi' }`
   (the standalone `home-debug run` path surfaces `Expected identifier but
   found "["`), but the corpus shim `transpileSourceWithBunParser`
   (`jsc_bootstrap.zig:816-817`) collapses every parse failure to a generic
   `return error.ParseError`, discarding `log.errors[0]`, so
   `transpilerTransformSyncNative` throws `"...failed: ParseError"` instead of
   the real message and `expectParseError` mismatches. FIX = propagate
   `log.errors[0]`'s message through the JS exception (shim, not parser).
2. `decorators.test.ts` — fails at module LOAD (`SyntaxError: Invalid
   character: '@'`): the corpus loader's transpile path doesn't lower legacy
   decorators (the reframe). NB `decorator-metadata.test.ts` PASSES despite
   inline decorators (locally-defined vs the imported decorated default-export
   fixture) — worth diffing.

Infra note: spawn-based corpus tests (`template-literal`, `es-decorators*`)
call `bunExe()` = hardcoded `zig-out/bin/home` (`jsc_bootstrap.zig:2884`), but
the debug build only produces `home-debug`. They PASS once `home ->
home-debug` is symlinked (or a release `home` is built). Not a parser gap.

Net: the real parser is essentially faithful across the transpiler corpus.
Next: (a) shim parse-error message propagation → `transpiler.test.js` passes
(DONE, `18b21489`); (b) the spawn `home`-binary path; then flip
`use_bun_parser_probe` on for the Bun.Transpiler API path; then route the
module loader through the real parser (decorators + broad sweep).

**STEP-3 BLOCKER REFINED (2026-05-26, measured prototype — net-negative,
NOT committed):** routing the corpus module loader through
`transpileSourceWithBunParser` as-is regresses the `minimal-js` subset
**399→310 files** (89 regressions, 0 new passes). Root cause: the real parser
in `transform_only` mode emits **ESM** — it injects its own `bun:wrap` helper
imports (`import { __using, __callDispose } from "bun:wrap"`) AND preserves the
source's top-level `import`/`export` statements — but the corpus bootstrap
evaluates each module as a plain SCRIPT via `JSEvaluateScript`, and
`hasUnsupportedModuleSyntax()` flags any top-level `import `/`export `, so 86
files flip to "unsupported." The existing `rewriteBootstrapModuleImports`
string-rewrite specifically lowers `bun:test`/harness/relative imports to
harness calls — which the real-parser path bypasses. (3 other files fail on
genuine dynamic-import/referrer-url behavior.)

So step 3 is NOT a blind loader swap. It requires the real parser to emit
**CommonJS** (no top-level import/export) for the corpus loader — i.e. set the
CJS-lowering options... **— CORRECTION (2026-05-26, second measured prototype):
this CJS-flag approach is NOT achievable, proven empirically.** Bun has NO
transform-mode mechanism that lowers top-level `import` into `require`:
`src/js_parser/parse/parse_entry.zig:1144` classifies any file with top-level
`import` statements as `exports_kind = .esm`, the `commonjs_at_runtime` /
`bun_commonjs` wrap mode only engages for `.cjs`-classified modules, and the
printer's `.s_import` case (`js_printer.zig:4590`) prints `import` verbatim even
under `rewrite_esm_to_cjs` (which only rewrites `export`/CJS constructs). Bun
loads ESM natively through JSC's module loader; it never needs import→require
lowering for script eval. A `transpileSourceWithBunParserCJS` prove-out
confirmed `printCommonJS` preserves the top-level `import`, reproducing the
399→310 regression. So **routing the corpus loader through the real parser
cannot eliminate top-level imports via any Bun flag.**

Re-scoped reality:
- The **transpiler corpus** (bundler/transpiler/*, which assert `Bun.Transpiler`
  output) is already conquered by the real parser via the **API path** (14/16
  files, hundreds of assertions). To make that the default, FLIP
  `use_bun_parser_probe = true` — but note this is entangled with the macro
  cone: probe-on pulls the macro→network→event-loop→bake cone, so the corpus
  runner must build with `enable_macros=false`. The flip therefore needs the
  corpus/`home-debug` build to default macros off (build-config decision).
- The **broad corpus** (js/, regression/, node/ — runtime *behavior* tests) does
  NOT need the real parser for loading; the existing string-rewrite loader
  already loads them (399/418). What those tests need is the faithful **runtime**
  (JSC bridge, webcore, node APIs, event loop) — the large parked Phase-12.2+
  subsystems. Making the loader "faithful" is a non-goal for those; making the
  runtime faithful is the real work.
- Two genuine corpus loader gaps remain where the real parser WOULD help and the
  string-rewrite can't: (1) `decorators.test.ts` (source has `@` the rewrite
  can't lower) — fix by extending the string-rewrite to lower decorators, or a
  targeted real-parser pass for decorator-bearing files; (2) the
  `transpiler.test.js` minify case (`a as any ? … : c` → `a || c`), an API-path
  real-parser minify-fidelity detail.

If a true module-faithful loader is ever wanted, it requires either (a) a real
JSC ESM module loader in the bootstrap (needs the parked `JSC_JSModuleRecord__*`
C++ glue — currently panic-stubbed), or (b) a Home-specific AST `import →
__home_import` lowering pass (a divergence, not a Bun flag). Neither is a quick
flag.

(Also: `home_rt`'s `js_printer.printCommonJS` is currently dead code that does
not compile under Zig 0.17 — `js_printer.zig:6380` stale `std.heap.stackFallback`
and `:5225` `runtime_imports.__export.?.ref` (should be `.?`); fix only if
`printCommonJS` is ever wired up.)

**CURRENT STATE & NEXT FRONTIER (2026-05-27).** Real-parser corpus build
(`zig build debug -Denable_macros=false`, probe auto-on via
`!build_options.enable_macros`): `minimal-js` subset = **3340 pass / 2 fail**.
The 2 remaining failures (`bundler/bun-build-api.test.ts`,
`bundler/bundler_edgecase.test.ts`) both require the **parked real bundler**
(`Bun.build()` executing bundle_v2/LinkerContext/OutputFile) — the harness
`itBundled`/`Bun.build` stub can't emit real artifacts. The transpiler corpus
is conquered by the real parser (14/16 files; the 2 non-passing are the
`transpiler.test.js` minify-fidelity case and `decorators.test.ts` which fails
at module-load because the string-rewrite loader can't lower `@`).

Remaining frontiers, in dependency order (all genuine multi-session subsystem
ports, mapped above):
1. **Real bundler** (`packages/bundler/`: `bundle_v2`, `LinkerContext`,
   `OutputFile`, the `itBundled`/`Bun.build` execution path) — unblocks the 2
   minimal-js bundler files and the whole `bundler/` corpus (89 files).
2. **Broad runtime corpus** (`js/` 998, `regression/` 384, `node/`, etc.) —
   these are runtime *behavior* tests; they load fine via the string-rewrite,
   but need the faithful **runtime**: the JSC JS-callable bridge, webcore
   (fetch/Request/Response/streams/Blob), `node:*` modules, the event loop, and
   timers. This is the Phase 12.2/12.3/12.5 substrate, much of it source-present
   but parked (HTTP transport uws/H2/H3/TLS, event loop, bake, JSC C++ glue).
3. **Decorator loader** + transpiler minify-fidelity — narrow real-parser
   follow-ups (extend the string-rewrite to lower `@`, or a targeted real-parser
   pass for decorator-bearing test files; chase `transpiler.test.js` minify
   cases).

Session arc landed on `main` (2026-05-26→27): stale-branch frontier 38→9 →
pivot to canonical `main` → resolver/AST/http/install cone compiles →
macro-gate (`enable_macros`) + scalar Highway + JSC module-record panic-stubs →
**real Bun parser links, runs, and is the default `Bun.Transpiler` path in the
macros-off corpus build** → minimal-js 3340/2. ~22 green, faithful, pushed
increments.

**BROAD-CORPUS REFRAME (2026-05-27 recon — pivotal, positive).** There are
TWO test execution paths and the bun-corpus gate uses the *weaker* one:
- The bun-corpus gate (`home test packages/runtime/test/bun-corpus`) routes
  every file through the curated `jsc_bootstrap` adapter
  (`packages/home_test/src/adapters/jsc_bootstrap.zig`), which feeds raw `.ts`
  to JSC via **hand-written per-exact-string TS rewrites + import shims** in
  `corpus_runner.zig` (e.g. the needle/replacement table ~12143-12250). This
  stripper has no general handling for generic functions, return-type
  annotations, or generic type-args, and curates imports per-string — so it
  fails on TS-syntax it hasn't been hand-taught and on uncurated imports.
- The **real `runtime/test_runner`** (`packages/runtime/src/runtime/test_runner/`,
  full transpiler + JSC) is MORE capable. PROVEN: `peek.test.ts`,
  `explicit-resource-management.test.ts` (4/4), `atomics.test.ts` (28/28) PASS
  via the real runner but FAIL in the bootstrap. So most broad-corpus
  "failures" are bootstrap-harness gaps, NOT runtime/API gaps.

Sampled 35 files (js/util, js/web, js/node, regression): 17 pass / 18 fail.
Failure histogram: bootstrap TS-stripping divergence (generic fns / return
types) ~3; import-curation "unsupported module syntax" ~5; parked
subprocess (`bunExe()`/`spawn`/`.toRun()` — 39% of the 811 `js/*` files) ~3;
module nationalization 1; bootstrap API-shim behavior gaps ~4. No easy
standalone wins (each is a parked subsystem or a fragile per-string rewrite).

**HIGHEST-LEVERAGE NEXT MOVE: route the bun-corpus gate through the real
`runtime/test_runner` instead of the `jsc_bootstrap` textual-rewrite adapter.**
The real runner already passes the TS-syntax/dynamic-import files unmodified, so
this eliminates the two largest failure classes (TS-stripping + import-curation,
the bulk of the ~20%+ TS-syntax `js/*` files) in one move, leaving the
genuinely-parked **subprocess/spawn subsystem** (~39% of `js/`) as the next
frontier after that. (Corpus-wide `js/*` shape: 51% import `harness`, 39%
spawn the binary, 21% use `as`-casts, 18% have return-type annotations.)

**CONCLUSION AFTER 3 LOADER-ROUTING ATTEMPTS (2026-05-27) — STOP re-chasing the
loader; the bottleneck is the parked RUNTIME, not the transpiler.** Three
measured prototypes all reverted, each revealing the next layer:
- iter 9: real parser emits ESM → top-level `import`/`export` trip
  `hasUnsupportedModuleSyntax` (399→310).
- iter 12: routing crashed on `@memcpy arguments alias` in `home_rt.copy`
  (now FIXED, `b86e3548` → `@memmove`; routing is crash-safe).
- iter 13: TS-stripping works (`peek` advances past `Unexpected token '<'`), but
  the real transpiler preserves `import.meta` which the IIFE harness rejects
  (3340→2671). To route, the real-transpiler output must ALSO get the harness's
  FULL ESM/`import.meta` neutralization (not just `rewriteBunTestImport`).
- Decisive insight: even with perfect TS-stripping, the affected files then fail
  on **parked runtime APIs** (e.g. `peek is not a function` — needs JSC promise
  internals). So loader routing changes the failure REASON (syntax → runtime
  API) without making files pass. The broad-corpus pass-rate is gated on the
  RUNTIME, not the corpus transpiler. Do NOT spend more iterations on loader
  routing for pass-rate; if ever revisited, it's only to compose the real
  transpiler with the full harness neutralization, and the gain is small.

**REAL BROAD-CORPUS FRONTIER = the parked runtime subsystems** (Phase 12.2/12.3/
12.5), to port subsystem-by-subsystem against the corpus that exercises each:
1. **Subprocess/`spawn`** — gates ~39% of `js/` (`bunExe()`/`.toRun()`); the
   biggest single bucket. Needs real `Bun.spawn`/`spawnSync` + a runnable `home`
   binary the tests can exec.
2. **JSC JS-visible API internals** — `Bun.peek` (promise status), and the rest
   of the `Bun.*`/`bun:jsc` surface backed by real JSC promise/value internals.
3. **WebCore** — `fetch`/`Request`/`Response`/streams/`Blob` for `js/web/*`.
4. **`node:*` modules** — the Tier-A set (`fs`/`stream`/`crypto`/`net`/...).
5. **Real bundler** (`bundle_v2`/`LinkerContext`) — for `bundler/` + the 2
   remaining minimal-js files.
Each is source-present-but-parked and is a multi-session port; pick one, port it
against its corpus slice, ratchet the pass count, repeat.

**CORPUS-GAP BACKLOG (2026-05-27, recon-mapped to exact files).** Banked
tractable win this pass: `ERR_INVALID_THIS` for `Request` body methods (faithful
`createInvalidThisError`/`determineSpecificType` port) + harness `gcTick`
(`6a3667b9`). The remaining sampled gaps, tagged by tractability:
- **Borderline-tractable (pure-JS-portable, good next tractable-wins targets):**
  - `node:fs` `Stats`/`BigIntStats` classes (DEP0180 14-arg ctor, shared
    prototype; `statSync` returns real instances) → `node/fs/fs-stats-constructor.test.ts`
  - `Bun.inspect.table` snapshot-exact formatter → `bun/console/bun-inspect-table.test.ts`
  - `TextEncoderStream`/`TextDecoderStream` transform-stream globals →
    `web/encoding/encode-bad-chunks.test.ts`
  - `process.setgroups` → `node/process/process-array-accessor-crash.test.ts`
- **Needs native bindings / parked subsystems:**
  - native `SharedArrayBuffer` on the corpus JSContextRef global →
    `web/atomics.test.ts`
  - `bun:jsc` `heapStats().objectTypeCounts.string` → `web/request/request-method-getter.test.ts`
  - native `Bun.hash` family (wyhash/adler32/crc32/cityHash) → `bun/util/hash.test.js`
  - `bun:ffi` `Bun.FFI.viewSource` → `bun/ffi/ffi-viewSource-non-object.test.ts`
  - webcore body/stream store-detachment (`Response.body` stream,
    `ERR_BODY_ALREADY_USED`) → `web/streams/readable-stream-blob-consumed.test.ts`
  - `CloseEvent` global + `Bun.spawnSync` (parked subprocess) → `js/...globals`

Operational note: the "canonical main sync" automation occasionally leaves
foreign uncommitted edits in the shared working tree (e.g. reverted
parser-probe experiments with `CORPUS_PREP_SENTINEL`/`ZZSENTINELZZ` markers,
or in-flight `ts_checker/lib.zig` work like the `internTuple`/`Object.entries`
helper seen on 2026-05-27); agents should `git reset --hard origin/main`,
scope commits with `--only`, and back up + preserve (don't destroy or
silently commit) any foreign edit they didn't author.

**ITER-16 OUTCOME + HARNESS-SHIM EXHAUSTION FINDING (2026-05-27, `ac03588d`).**
Landed the faithful conditional test-modifier family in the corpus bootstrap
harness, mirroring Bun's `src/runtime/test_runner/ScopeFunctions.zig`:
`it.{if,skipIf,todoIf,failingIf}`, `test.{todoIf,failingIf}`,
`describe.todoIf` (describe has no failing mode upstream, so no `failingIf`).
~72 copied corpus files reference these. **Measured pass delta: ZERO** —
minimal-js stays 3340/2; the files that use these modifiers
(`zlib`, `bun-jsc`, `atomics-waitasync-*`, …) are all gated *deeper* (parked
`Atomics.waitAsync`, TS-stripping `Unexpected token ':'`, unsupported module
syntax), so adding the modifier only changes *which* line fails, not whether
the file passes. This is the empirical confirmation of the earlier thesis:
**the corpus-harness-shim ratchet is now exhausted.** Adding more pure-JS
harness shims yields ~0 corpus pass delta because every remaining failing
file bottoms out in a parked RUNTIME subsystem, not a missing harness global.
The increment is still worth keeping (faithful API surface, removes a latent
load-time `ReferenceError` for when the subsystems land, unit-tested) but it
is NOT progress toward corpus parity.

**CONSEQUENCE FOR THE LOOP:** stop spending iterations on harness-shim
pure-JS wins. The only remaining lever for the corpus pass-rate is a
real parked-subsystem port (Phase 12.2/12.3/12.5), in the dependency order
already mapped above: (1) subprocess/`spawn` (~39% of `js/`, biggest single
bucket; needs real `Bun.spawn`/`spawnSync` + a runnable `home` binary tests
can exec), (2) JSC JS-visible API internals, (3) WebCore, (4) `node:*`,
(5) real bundler. Each is a multi-session port; there is no bounded
single-session corpus-parity win left. The honest distinction stands: the
bootstrap harness ratchets a *test pass-count* against JS shims; true
JS-visible parity requires the Phase-1 JS-callable bridge so the corpus runs
against the real `home_rt` runtime, not the harness.

**CONE BOUNDARY FINDING (2026-05-26, after ~40 leaf fixes landed in `79d82ecc`):**
the resolver/install/http leaf cascade is done, but the probe-ON `zig build
debug` now bottoms out at a *large parked subsystem set*, NOT more leaf fixes.
The real parser pulls: `parse() → e_template visit → MacroContext.call →
Resolver.resolve → getPackageManager → NetworkTask → bun.http.AsyncHTTP →` the
**full HTTP transport** (uws sockets + H2/H3-QUIC `lsquic` + TLS), the **JSC/Mini
event loop** (`AnyEventLoop` embeds an `opaque MiniEventLoop`), and **bake**
(`OutputFile` → `bake.Side`, parked `opaque`). ~13 remaining probe-ON errors all
live in those parked subsystems.

Decision fork:
- **(A) Comptime-eliminate the macro cone (CHOSEN).** The macro reference is
  `comptime allow_macros = FeatureFlags.is_macro_enabled` (true on macOS), and
  the transpiler runs `no_macros=true` — macros are never executed in transpile.
  Making `allow_macros` comptime-false for the transpile/`home-debug` build (a
  build option gating `is_macro_enabled`) dead-code-eliminates the entire
  `MacroContext.call → resolver → PM → network → event-loop → bake` cone, so the
  real parser compiles WITHOUT porting QUIC/bake/event-loop. Macro support in
  `Bun.Transpiler` becomes a separate, later milestone that re-enables the cone.
- (B) Port the parked HTTP-transport/event-loop/bake stack. Rejected for now:
  huge, and includes non-parity-goals (QUIC/H3, bake DevServer) just to compile
  code that's runtime-dead under `no_macros`.

So the immediate path is (A): add an `enable_macros` build flag (default the
faithful `true`), gate `FeatureFlags.is_macro_enabled`, build the corpus
`home-debug` with it off, confirm the real-parser cone compiles, then proceed to
steps 2-3 above (flip the probe / route the module loader). When macro support
is later wanted, that milestone ports the macro→resolver→network cone properly.

Parser hot-path probe on 2026-05-26 after the FD/sys shim batch: the
temporarily enabled `transpileSourceWithBunParser` no longer stops at
`bun.FD`, `RuntimeTranspilerCache`, `MacroContext`, or missing
uninitialized BunString symbols. The next compile frontier is now the
printer/analyze cone: `ArrayHashMap` context return widths, remaining
`std.AutoArrayHashMap` usage, stale printer `.{} -> .empty` sites,
missing `bun.strings` WTF-8 helpers, `commonjs_named_exports` iteration,
`std.Io.GenericWriter`, and `bun.ArenaAllocator`.

Follow-up parser probes in clean integration worktrees addressed the
former four blockers: `VirtualMachine.runWithAPILock`,
`RuntimeTranspilerCache` filesystem open/mkdir compatibility, resolver
`openDirAbsoluteZ` compatibility, and the `bun.path.joinAbsStringBuf*`
exports. The current temporary enablement now reaches the macro/JSC
facade frontier: VM `uncaughtException`/console state, Response blob
conversion, JSArrayIterator/JSValue enum bridging, `ConsoleObject`
`std.time.Timer` drift, the JSC JSValue isCallable C++ shim,
`jsc.AnyPromise`/`JSObject`, allocator `BSSList`/`appendLowerCase`, and
`jsc.Node.Encoding`. Keep the adapter gated until those are copied
faithfully from Bun's Zig source.

Latest clean-worktree probe on 2026-05-26: the parser namespace shims,
snapshot loading, resolver string helpers, FD/open-dir compatibility, and
ZigString ownership/data-URL helpers now compile through the temporary
native parser switch. The next compile frontier is three items:
`bun.install.PackageInstall` / install task aliases, the copied
`ThreadPool.Task` surface, and the `bun.sys.File` adapter shape
(`from`, `getEndPos`, `readAll`). The probe switch remains committed off.

Next-work ledger for the two-file frontier:

| Work item | Faithful implementation target | Promotion evidence required |
|---|---|---|
| Native `transformSync` body | Port Bun's in-process parser/printer flow: `Parser.init`, `parse`, `Symbol.Map.initList`, `js_printer.printAst`, sourcemap/output options, loader-specific parser flags, minify flags, `define`, and diagnostics mapped to JSC exceptions | `bundler/transpiler/transpiler.test.js` single-file run passes, then joins a green subset without changing expectations |
| `scan` / `scanImports` | Replace the current native bootstrap scanner with callbacks over Bun import records; `scan("")` returns `{ imports: [], exports: [] }`, `scanImports("")` returns `[]`, `scan` omits `require`, `scanImports` includes it, and records expose Bun's `{ kind, path }` shape | Focused `Bun.Transpiler` tests plus the promoted `transpiler.test.js` cases that exercise scan APIs |
| Decorator lowering | Feed `.ts` / `.tsx` through the copied Bun parser/lowerer/printer with legacy TypeScript decorator flags, metadata options, class-field/private-field helper emission, and existing `bun:wrap` helper imports | `bundler/transpiler/decorators.test.ts` single-file run passes without a corpus-local rewrite |

Completed native-plugin fixture evidence on 2026-05-26:
`bundler/native-plugin.test.ts` is no longer part of the bundler
frontier. Home builds the copied node-gyp fixture, `dlopen`s the `.node`
addon, runs the fixture's Node-API registration callbacks, preserves
external cells and loaded addon handles, calls `plugin_impl*` through
Home's Bun-compatible `NativePluginABI`, and routes the generated
`bun run dist/index.js` execution through the recorded build artifact.
The single-file corpus run passes with **6 passed, 0 failed,
0 unsupported**. This promotes that exact fixture only; broader `napi/`
and production `.node` runtime parity still need their own corpus gates.

Source module work after those corpus gates should stay faithful to the
copied Bun graph rather than expanding the bootstrap stub. Replace
`__home_expect_bundled` with a real `itBundled` adapter and wire the
needed Bun bundler substrates in `packages/bundler/src/`:
`options.zig`, `transpiler.zig`, `bundle_v2.zig`,
`LinkerContext.zig`, `OutputFile.zig`, `HTMLImportManifest.zig`,
`HTMLScanner.zig`, `ParseTask.zig`, `LinkerGraph.zig`, and the
`linker_context/*` output/metafile/HTML/CSS chunk helpers currently
present under `packages/runtime/src/bundler/linker_context/`.
Verification target:

```sh
./pantry/.bin/zig build test -Dfilter=home_test --summary all
./pantry/.bin/zig build test -Dfilter=home_rt --summary all
./pantry/.bin/zig build debug --summary all
./zig-out/bin/home-debug test packages/runtime/test/bun-corpus/bundler/transpiler/transpiler.test.js
./zig-out/bin/home-debug test packages/runtime/test/bun-corpus/bundler/transpiler/decorators.test.ts
./zig-out/bin/home-debug test packages/runtime/test/bun-corpus/bundler/native-plugin.test.ts
./zig-out/bin/home test packages/runtime/test/bun-corpus --bun-corpus-native-subset=bundler-core-itbundled
./zig-out/bin/home test packages/runtime/test/bun-corpus --bun-corpus-native-subset=bundler-transpiler-bootstrap
bunx --bun pickier docs/BUN_PARITY_PLAN.md docs/PARITY-BUN.md packages/home_test/src/PORTING_STATUS.md
git diff --check -- docs/BUN_PARITY_PLAN.md docs/PARITY-BUN.md packages/home_test/src/PORTING_STATUS.md
```

Runtime compile frontier: the current non-JSC runtime gate is green.
`./pantry/.bin/zig build test -Dfilter=home_rt --summary all` now passes
on 2026-05-26 with **1392 / 1392 tests passed**. The bridge layer that made this green is
still compile-frontier substrate, not JS-callable parity credit: it adds
missing Bun/JSC aliases, Zig 0.17 compatibility shims, parked subprocess
owners, CowSlice/CowString exposure, and test-only C++ extern stubs for
the non-JSC build gate. The latest runtime slice also compiles the copied
`runtime/cli/test/parallel` subtree through `home_rt` and adds focused
frame-ingest plus aggregate JUnit parsing tests.

Promotion rule for the last two bundler files: a file only leaves the
frontier when its exact copied corpus file passes through `home-debug`
without a corpus-only semantic mock, and the relevant upstream Bun source
path is named in the commit notes. Metadata probes and bootstrap
normalization can stay as scaffolding, but they are not parity credit.

Bundler tranche exit criteria:

- The bundler ledger names every remaining unallowlisted `bundler/` file
  and records its latest Home result.
- Ordinary bundler tests pass natively with no local rewrites and no Home
  skip entries.
- Any platform-specific exclusion exactly matches an upstream Bun skip or
  platform guard.
- Native-plugin fixture evidence stays recorded as the completed
  predecessor gate; do not re-open it unless the exact copied fixture
  regresses.
- The no-skip corpus denominator is updated after the tranche so the next
  frontier starts from the full discovered count, not the minimal-JS
  bootstrap subset.

### Phase 5 - Performance And Compatibility Closure

Goal: prove Home is a practical Bun-compatible runtime, not only a
passing fixture runner.

Done when:

- Startup, HTTP, file I/O, spawn, and package-resolution benchmarks are
  compared against the pinned Bun checkout.
- Known intentional divergences are documented with user-facing behavior
  and migration guidance.
- Cross-platform gates cover macOS and Linux at minimum.
- The release gate is zero failures in the copied Bun corpus for the
  supported platform matrix.

## Source Gates

Every parity patch that touches runtime source should state which gate it
advances:

1. **Pin gate:** `git -C /Users/chrisbreuer/Code/bun rev-parse HEAD`
   matches `packages/runtime/UPSTREAM_SHA.txt`, or the mismatch is
   resolved in a separate audit/doc patch.
2. **Copy gate:** copied files retain Bun MIT attribution and are listed
   in the relevant porting/audit status.
3. **Rewrite gate:** copied runtime files import `home_rt`, not `bun`,
   unless they are parked as dormant backlog.
4. **Build gate:** the touched package compiles under Pantry Zig
   0.17-dev.
5. **Test gate:** at least one focused test proves the newly integrated
   behavior.
6. **Doc gate:** API status moves only when JS-visible behavior exists;
   substrate-only progress stays marked as substrate.

## Test Gates

Use the cheapest gate that proves the claim, then ratchet upward:

| Claim | Minimum gate |
|---|---|
| Raw Zig source count changed | `scripts/measure-parity.sh --values` |
| Runtime source integrated | focused `./pantry/.bin/zig build test -Dfilter=<area>` |
| JSC bridge behavior changed | focused JSC/runtime test with `-Denable_jsc=true` |
| API became JS-visible | a Home-run JS fixture or Bun-corpus smoke |
| Corpus slice improved | `home test packages/runtime/test/bun-corpus/ <slice>` |
| Baseline docs changed | `rg` sanity for duplicate/stale headline claims |

Full `./pantry/.bin/zig build test --summary all` is the preferred
pre-merge gate for source changes, but documentation-only patches can use
the raw-count and `rg` sanity checks.

## Agent-Sized Workstreams

Pick work that can be completed and verified independently. Avoid broad
"runtime parity" claims in commit messages.

| Workstream | Ownership boundary | First useful output |
|---|---|---|
| Measurement ledger | `scripts/measure-parity.sh`, audit docs, parity docs | split raw-present vs integrated counts |
| JSC primitive bridge | `packages/runtime/src/jsc/` focused files | eval/value/exception fixtures |
| Module loader | runtime loader files plus Pantry resolver API docs | relative ESM/CJS/JSON fixtures |
| Pantry resolver integration | Pantry shim and runtime resolver boundary | bare package import fixture |
| Web URL/body slice | URL, URLSearchParams, Blob/File, Body readers | Web fixture smoke through Home |
| Fetch/server slice | fetch, Request/Response, server lifecycle | local loopback fixture |
| Node fs/path/process slice | `packages/runtime/src/node/` only | `node:*` fixture smoke |
| Test-runner core | runtime test runner plus corpus harness docs | `test`/`expect`/async lifecycle smokes |
| Parallel test-runner process pool | `packages/runtime/src/runtime/cli/test/parallel/` | 7-file integration ledger plus focused parallel-runner smoke |
| Corpus triage | copied Bun corpus status docs | named slice pass/fail ledger |
| Compatibility divergence | docs only unless behavior is already proven | documented intentional Pantry/Home divergence |

Suggested chunk size: one API family, one corpus slice, or one measurement
improvement per patch. If a task needs more than one subsystem, write the
dependency chain in the PR description before editing.

## Coordination Rules

- Do not count dormant source as integrated parity.
- Do not move API rows from "not implemented" to "partial" unless the
  API is callable from JavaScript through Home.
- Do not use system Bun delegation as parity evidence.
- Do not mix mechanical upstream copy, Zig compatibility rewrites, and
  semantic behavior changes in one patch.
- Do not modify `build.zig` as part of documentation/tooling-plan work.
- When concurrent edits exist, preserve them and re-read nearby status
  text before updating numbers.

## Next Documentation Tasks

1. Refresh the integrated-file audit that last reported **552 / 1193**.
2. Keep the Bun-corpus ratchet ledger current with native Home pass
   counts by slice, separate from bootstrap allowlists.
3. Update headline docs only after the measurement helper can reproduce
   the numbers without manual interpretation.

## Next Bulk Tranches

1. **Bundler corpus completion.** Promote the remaining exact 2
   unallowlisted upstream Bun `bundler/` corpus files as the next large
   test slice before moving into Bake/server-heavy tests. The files are
   `bundler/transpiler/decorators.test.ts`,
   `bundler/transpiler/transpiler.test.js`. The native-plugin fixture is
   already promoted with explicit node-gyp / `.node` / Node-API evidence.
2. **JSC-adjacent source integration.** The 72 previously missing upstream Zig
   paths listed in
   [`BUN_ZIG_SOURCE_AUDIT_2026-05-26.md`](./BUN_ZIG_SOURCE_AUDIT_2026-05-26.md)
   are now source-present. Next work is integration, not copying: apply
   Home import rewrites, Zig 0.17 cleanup, build wiring, and tests by
   dependency weight across SQL JSC, Valkey JSC, HTTP/WebSocket JSC, DNS
   JSC, then the smaller CSS/sys/parser/semver/URL/AST/patch leaves.
3. **Parallel test-runner process pool.** The full
   `runtime/cli/test/parallel` subtree is now compile-wired through
   `home_rt.runtime.cli.test_.parallel` as one chunk. Treat this as
   compile-frontier integration, not complete behavioral parity:
   `FileRange.zig`, `Frame.zig`, `Channel.zig`, `Coordinator.zig`,
   `Worker.zig`, `aggregate.zig`, and `runner.zig` all enter the runtime
   build graph, with narrow Home `uws` compatibility aliases and focused
   tests for channel frame ingestion plus aggregate JUnit parsing.

   | File | Current status | Next integration work |
   |---|---|---|
   | `FileRange.zig` | Compile-wired leaf | Keep counted as integrated only with its unit tests/build edge |
   | `Frame.zig` | Compile-wired leaf | Keep counted as integrated only with its unit tests/build edge |
   | `Channel.zig` | Compile-wired with frame tests | Replace shimmed socket/vtable pieces with real Home IPC backend |
   | `Coordinator.zig` | Compile-wired | Wire worker lifecycle, scheduler, reporting, and abort handling through Home test command |
   | `Worker.zig` | Compile-wired | Wire process spawn, stdio capture, IPC adoption, and exit accounting |
   | `aggregate.zig` | Compile-wired with JUnit attr tests | Wire full JUnit/LCOV merge to Home fs/path/source-map surfaces |
   | `runner.zig` | Compile-wired | Unpark `ParallelRunner` entrypoints through Home's test command path |

   Known remaining blockers: replacing compatibility aliases with real
   Home surfaces for `PathString`, `MimallocArena`, `Async`,
   `io.BufferedReader`, `uws`, `windows.libuv`, `c`, `fs.FileSystem`,
   `O`, `SourceMap`, `selfExePath`, `start_time`, `timespec`,
   `spawn`/process surfaces, `sys` error and file APIs, `fs` and `path`
   helpers, socket-pair or pipe adoption, and the JSC
   `VirtualMachine`/test-runner surfaces used by the worker loop. Count
   the chunk as behaviorally complete only when `ParallelRunner` exposes
   `runAsCoordinator`, `runAsWorker`, `workerEmitTestDone`, and `Worker`,
   the Home `ParallelRunner` path avoids system Bun delegation, and tests
   cover frame IPC, worker spawn/reap, result aggregation, coverage or
   JUnit fragment handling, and at least one multi-file `home test
   --parallel` corpus smoke.
4. **Bake after bundler.** The sorted full-gate frontier moves naturally
   into `bake/`, and existing runtime source already has Bake lifetime
   carrier work to build on.
