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
2026-05-26 in `/tmp/home-bun-parity-main`:

| Measurement | Value | What it means |
|---|---:|---|
| `RUNTIME_ZIG_PRESENT_FILES` | 1391 | Zig files present in `packages/runtime/src/`; **not** integrated parity credit |
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

## Phase Goals

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
| Discovered Bun-style test files | 4013 | Full copied-corpus scale for Home's Bun-style test discovery |
| Minimal-JS subset entries | ~418 | Bootstrap subset currently used for the smallest JS-capable corpus gate |
| Minimal-JS unique files | 417 | One duplicate entry remains in the subset ledger |
| Outside minimal-JS subset | 3621 | Remaining copied-corpus frontier after the bootstrap subset |

Next large slice: **bundler corpus completion**. A local audit on
2026-05-26 finds **89** copied `bundler/**/*.test.{ts,js}` files. The
current green evidence covers **86 unique files**: 66 unique bundler
files inside `minimal-js`, 5 more in `bundler-core-itbundled`, and 15
more from the executable 20-file `bundler-transpiler-bootstrap`
subset. Promote the remaining exact **3** files into native Home corpus
gates before expanding into more Bake or server-heavy tests. Keep
`bundler/native-plugin.test.ts` last because upstream handles it as a
special native-plugin case, so it should not mask ordinary bundler
coverage.

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

Remaining bundler file frontier after the 20-file transpiler/CLI/resolver tranche,
classified by next faithful work batch:

| Tranche | Files | Primary blocker from local corpus |
|---|---|---|
| A. Legacy decorator transpiler semantics | `bundler/transpiler/decorators.test.ts` | Top-level legacy decorator lowering; latest probe reaches the real parser blocker, `SyntaxError: Invalid character: '@'` |
| B. Transpiler API surface | `bundler/transpiler/transpiler.test.js` | `Bun.Transpiler`, loader validation, transform APIs, and callback behavior |
| C. Native plugin final | `bundler/native-plugin.test.ts` | Native plugin ABI, node-gyp build, `.node` loading, `onBeforeParse`, crash-name behavior |

Fresh single-file probes on 2026-05-26 in
`/private/tmp/home-bun-parity-main`:

| Command | Result | Current blocker |
|---|---|---|
| `./zig-out/bin/home-debug test packages/runtime/test/bun-corpus/bundler/transpiler/transpiler.test.js` | Fails before promotion: 0 passed, 1 failed | Enters `Bun.Transpiler.transformSync`; CRLF and empty-type-parameter probes now advance, and the current bootstrap-body blocker is the malformed-enum parse-error section |
| `./zig-out/bin/home-debug test packages/runtime/test/bun-corpus/bundler/transpiler/decorators.test.ts` | Fails before promotion: 0 passed, 1 failed | `SyntaxError: Invalid character: '@'` |
| `./zig-out/bin/home-debug test packages/runtime/test/bun-corpus/bundler/native-plugin.test.ts` | Fails before promotion: 0 passed, 1 failed, 0 unsupported | File-attribute imports, native-plugin TS annotations, async lifecycle hooks, and node-gyp addon build now run; current blocker is the Home N-API dlopen bridge for `.node` exports |

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

Parser hot-path probe on 2026-05-26 after the FD/sys shim batch: the
temporarily enabled `transpileSourceWithBunParser` no longer stops at
`bun.FD`, `RuntimeTranspilerCache`, `MacroContext`, or missing
uninitialized BunString symbols. The next compile frontier is now the
printer/analyze cone: `ArrayHashMap` context return widths, remaining
`std.AutoArrayHashMap` usage, stale printer `.{} -> .empty` sites,
missing `bun.strings` WTF-8 helpers, `commonjs_named_exports` iteration,
`std.Io.GenericWriter`, and `bun.ArenaAllocator`.

Next-work ledger for the three-file frontier:

| Work item | Faithful implementation target | Promotion evidence required |
|---|---|---|
| Native `transformSync` body | Port Bun's in-process parser/printer flow: `Parser.init`, `parse`, `Symbol.Map.initList`, `js_printer.printAst`, sourcemap/output options, loader-specific parser flags, minify flags, `define`, and diagnostics mapped to JSC exceptions | `bundler/transpiler/transpiler.test.js` single-file run passes, then joins a green subset without changing expectations |
| `scan` / `scanImports` | Replace the current native bootstrap scanner with callbacks over Bun import records; `scan("")` returns `{ imports: [], exports: [] }`, `scanImports("")` returns `[]`, `scan` omits `require`, `scanImports` includes it, and records expose Bun's `{ kind, path }` shape | Focused `Bun.Transpiler` tests plus the promoted `transpiler.test.js` cases that exercise scan APIs |
| Decorator lowering | Feed `.ts` / `.tsx` through the copied Bun parser/lowerer/printer with legacy TypeScript decorator flags, metadata options, class-field/private-field helper emission, and existing `bun:wrap` helper imports | `bundler/transpiler/decorators.test.ts` single-file run passes without a corpus-local rewrite |
| Native plugin bridge | Port or compile Bun's JSC/C++ native plugin bridge and wire it to copied `ParseTask.zig`, N-API external validation, `.node` loading metadata, and `onBeforeParse` result handoff | `bundler/native-plugin.test.ts` single-file run passes after node-gyp builds the fixture addon |

Native plugin audit on 2026-05-26: `bundler/native-plugin.test.ts`
has a corpus-preprocessor shim for the upstream file-attribute imports
and `harness.makeTree`, so the next rebuilt runner should get past the
plain module-syntax guardrail without mocking `.node` loading. This is
not parity credit. The real parity surface is Bun's native
bundler plugin ABI:

- The copied fixture builds `native_plugin.cc` and `not_native_plugin.cc`
  with `node-gyp`, requires the resulting `.node` modules, and passes a
  N-API external into `build.onBeforeParse`.
- The fixture exercises `BUN_PLUGIN_NAME` discovery, `dlsym` /
  `GetProcAddress` symbol lookup, `OnBeforeParseArguments` /
  `OnBeforeParseResult` struct-size versioning, `fetchSourceCode`,
  source replacement, loader handoff, log/error propagation, external
  pointer validation, invalid free-context detection, first-plugin-wins
  semantics, concurrent filter matching, and crash-handler plugin-name
  reporting.
- Home already has the core copied Zig/header substrate:
  `packages/runtime/src/bundler/ParseTask.zig`,
  `packages/runtime/src/runtime/api/JSBundler.zig`,
  `packages/runtime/src/jsc/NodeModuleModule.zig`,
  `packages/runtime/src/runtime/napi/napi.zig`, and
  `packages/runtime/upstream/packages/bun-native-bundler-plugin-api/bundler_plugin.h`.
  The audited header and native-plugin fixture files compared
  byte-for-byte with `/Users/chrisbreuer/Code/bun`, and Home already has
  copied C++ bridge sources under `packages/runtime/upstream/src/jsc/bindings/`.
- The missing integration is the native/JSC bridge, especially
  `src/jsc/bindings/JSBundlerPlugin.cpp`,
  `src/jsc/bindings/napi.cpp`, and
  `src/jsc/bindings/napi_external.cpp`, plus the build wiring that
  exposes those host functions to Home's JSC-enabled runtime and lets
  node-gyp-built addons attach the private dlopen handle used by
  `onBeforeParse`.
- The ABI edge itself is now less ambiguous: Home has
  `packages/runtime/src/bundler/native_plugin_abi.zig` for Bun's public
  loader/log ids, and `ParseTask.zig` translates those ids to Home's
  richer internal loader enum instead of passing the internal enum across
  the C boundary.

Worker evidence on 2026-05-26 after commit `f6ab6eaa`: no additional
isolated Zig/header files were found missing for this frontier. The
owned harness change is intentionally limited to lowering
`import ... with { type: "file" }` for `bundler_plugin.h`,
`native_plugin.cc`, and `not_native_plugin.cc`, plus adding
`harness.makeTree`. `bunx --bun pickier` passed for the parity ledgers.
The native parser/printer bridge also gained concrete Home compatibility
shims (`bun.glob.match`, `ComptimeStringMap.getWithEql`, `jsc.math`,
`KnownGlobal.minifyGlobalConstructor`, `BSSMap`/`BSSStringList`, and Zig
0.17 std API fixes), and the bridge is kept gated until the resolver/cache
cone is complete. `zig build test -Dfilter=home_test --summary all`
rebuilds green with 296/297 tests passing and one expected skip.
The rebuilt native-plugin single-file probe no longer fails at module
syntax, async lifecycle hooks, or missing node-gyp output. The harness now
runs the fixture's node-gyp build and reaches the native addon loader,
then stops at `Native .node module loading requires the Home N-API dlopen
bridge`. The generic harness blockers are gone, but this remains no
parity credit until the real `.node` / N-API bridge is wired.

Do not close this by adding a corpus-only `.node` mock. A faithful close
should first compile or port the native bridge, then promote the fixture
with evidence from the single-file corpus run.

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
./zig-out/bin/home test packages/runtime/test/bun-corpus --bun-corpus-native-subset=bundler-core-itbundled
./zig-out/bin/home test packages/runtime/test/bun-corpus --bun-corpus-native-subset=bundler-transpiler-bootstrap
bunx --bun pickier docs/BUN_PARITY_PLAN.md docs/PARITY-BUN.md packages/home_test/src/PORTING_STATUS.md
git diff --check -- docs/BUN_PARITY_PLAN.md docs/PARITY-BUN.md packages/home_test/src/PORTING_STATUS.md
```

Runtime compile frontier: the current non-JSC runtime gate is green.
`./pantry/.bin/zig build test -Dfilter=home_rt --summary all` now passes
on 2026-05-26 with **1388 / 1388 tests passed**. The bridge layer that made this green is
still compile-frontier substrate, not JS-callable parity credit: it adds
missing Bun/JSC aliases, Zig 0.17 compatibility shims, parked subprocess
owners, CowSlice/CowString exposure, and test-only C++ extern stubs for
the non-JSC build gate. The latest runtime slice also compiles the copied
`runtime/cli/test/parallel` subtree through `home_rt` and adds focused
frame-ingest plus aggregate JUnit parsing tests.

Bundler tranche exit criteria:

- The bundler ledger names every remaining unallowlisted `bundler/` file
  and records its latest Home result.
- Ordinary bundler tests pass natively with no local rewrites and no Home
  skip entries.
- Any platform-specific exclusion exactly matches an upstream Bun skip or
  platform guard.
- `bundler/native-plugin.test.ts` is the final bundler item and is closed
  with explicit native-plugin build/runtime evidence.
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

1. **Bundler corpus completion.** Promote the remaining exact 3
   unallowlisted upstream Bun `bundler/` corpus files as the next large
   test slice before moving into Bake/server-heavy tests. The files are
   `bundler/transpiler/decorators.test.ts`,
   `bundler/transpiler/transpiler.test.js`,
   `bundler/native-plugin.test.ts`. Keep
   `bundler/native-plugin.test.ts` last because upstream treats native
   plugins specially.
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
