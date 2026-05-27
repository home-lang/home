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
2026-05-26 after the 70-file Zig source-presence gap copy:

| Measurement | Value | What it means |
|---|---:|---|
| `RUNTIME_ZIG_PRESENT_FILES` | 1394 | Zig files present in `packages/runtime/src/`; **not** integrated parity credit |
| `RUNTIME_SUBSYSTEMS` | 99 | Top-level runtime source directories present |
| `RUNTIME_ZIG_DORMANT_FILES` | 856 | Source-first copied Zig files in dormant import manifests; still awaiting rewrite/wiring/tests |
| `BUN_UPSTREAM_FILES` | 1193 | Audited Bun baseline from the 2026-05-18/20 audit, excluding tests/codegen/macros |
| `NODE_FILES` | 28 | Zig files currently under `packages/runtime/src/node/` |
| `JSC_FILES` | 130 | Zig files currently under `packages/runtime/src/jsc/` |
| `COMPAT_SYMBOLS` | 16 / ~103 | Top-level `bun.*` shim symbols in `packages/compat/src/compat.zig` |

Honest interpretation:

- Raw runtime files present now exceed the old audited Bun denominator.
  That is expected because `packages/runtime/src/` contains dormant Bun
  source backlog plus Home adapters. It must not be reported as
  `>100%` runtime parity.
- Upstream Zig source presence is now complete for the pinned checkout:
  `comm -23` between `/Users/chrisbreuer/Code/bun/src/**/*.zig` and
  `packages/runtime/src/**/*.zig` returns zero missing paths. The newest
  70 files are documented in
  [`packages/runtime/DORMANT_BUN_ZIG_IMPORT_2026-05-26.txt`](../packages/runtime/DORMANT_BUN_ZIG_IMPORT_2026-05-26.txt).
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
integration audit moves it. The executable corpus ratchet is now focused
on bundler completion after `minimal-js`, `bundler-core-itbundled`, and
`bundler-transpiler-bootstrap` established green Home-run bootstrap
slices. The next work is intentionally split across big independent
agent chunks: parser/decorator semantics, `Bun.Transpiler` and macro
surface, resolver cache behavior, CLI build behavior, native plugin ABI,
then Bake/server-heavy corpus.

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
| `bundler/` test files | 89 | Current active corpus ratchet; includes 85 ordinary bundler files plus 4 CSS WPT files |
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
current green evidence covers **79 unique files**: 66 unique bundler
files inside `minimal-js`, 5 more in `bundler-core-itbundled`, and 8
more from the executable 13-file `bundler-transpiler-bootstrap`
subset. Promote the remaining **10** files into native Home corpus gates
before expanding into more Bake or server-heavy tests. Keep
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
It runs thirteen additional bundler/transpiler files and passes:
**132 passed, 0 failed, 0 todo** on 2026-05-26.

Parser hot-path compatibility update on 2026-05-26: the local Bun-Zig
adapter now exposes the parser-facing `bun.path.joinAbsStringBuf*` helpers,
`bun.jsc.RuntimeTranspilerCache`, and `bun.jsc.OpaqueWrap`, and the
Zig-0.17 filesystem drift in RuntimeTranspilerCache/resolver directory opens
is bridged locally. The bootstrap subset still passes at **13 files / 132
tests**. The remaining `home_rt` compile frontier is no longer these parser
blockers; it is the broader JSC/webcore/event-loop/string substrate surface.

Files in the tranche:

- `bundler/bundler_feature_flag.test.ts`
- `bundler/plugin-error-nested-throw.test.ts`
- `bundler/transpiler/es-decorators.test.ts`
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

Remaining bundler file frontier, classified by tranche:

| Tranche | Files | Primary blocker from local corpus |
|---|---|---|
| A. Decorator transpiler semantics | `bundler/transpiler/decorator-metadata.test.ts`, `bundler/transpiler/decorators.test.ts`, `bundler/transpiler/es-decorators-esbuild.test.ts` | Decorator metadata / legacy and standard decorator syntax lowering; next observed blocker is parse-time `SyntaxError: Invalid character: '@'` in `decorator-metadata.test.ts` |
| B. Transpiler API and macro surface | `bundler/transpiler/macro-test.test.ts`, `bundler/transpiler/transpiler.test.js` | `Bun.Transpiler`, macro imports, and broader transpiler API behavior |
| C. Resolver cache behavior | `bundler/resolver/cache-invalidation.test.ts`, `bundler/resolver/cache-node-compat.test.ts`, `bundler/resolver/cache-runtime.test.ts` | Repeated in-process `Bun.build()` / `require()` cache invalidation, filesystem mutation, Node-vs-Bun subprocess comparison |
| D. CLI build surface | `bundler/cli.test.ts` | `bun build` CLI subprocess matrix: compile/outfile/sourcemap/tsconfig override/package install paths |
| E. Native plugin final | `bundler/native-plugin.test.ts` | Native plugin ABI, node-gyp build, `.node` loading, `onBeforeParse`, crash-name behavior |

Agent handoff order for the remaining bundler work:

1. **Decorator semantics agent:** copy/integrate the parser and
   transpiler decorator lowering substrate needed by all three decorator
   files, then promote the three files together.
2. **Transpiler/macro agent:** wire `Bun.Transpiler`, macro import
   resolution, macro execution, and the wider transpiler API enough to
   promote both files as one slice.
3. **Resolver-cache agent:** own all three resolver cache tests together,
   including repeated `Bun.build()` state, file mutation, and Node-vs-Bun
   comparison plumbing.
4. **CLI build agent:** own `bundler/cli.test.ts` as a full subprocess
   matrix, including compile/outfile/sourcemap/tsconfig override/package
   install paths.
5. **Native plugin agent:** keep `bundler/native-plugin.test.ts` last and
   close it only with real native addon build, `.node` load, N-API/plugin
   symbol registration, `onBeforeParse`, and crash-name evidence.

Native plugin bridge update on 2026-05-26: `packages/home_test` now has
a Home-owned `.node` bridge slice for this frontier. The adapter runs
real `node-gyp` builds for `binding.gyp` temp projects, calls a Zig
`dlopen` metadata callback for `require(.node)`, retains addon handles,
inspects Bun plugin symbols, and maps the native-plugin fixture into
`Bun.build().onBeforeParse()` error/count semantics. End-to-end corpus
file execution still needs the unrelated current `js_printer` compile
drift cleared so a fresh `home-debug` binary can run
`bundler/native-plugin.test.ts`.

After the file frontier is green, replace the `__home_expect_bundled`
stub with a real `itBundled` adapter and wire the needed Bun bundler
substrates in `packages/bundler/src/` (`options.zig`,
`transpiler.zig`, `bundle_v2.zig`, `LinkerContext.zig`,
`OutputFile.zig`, plus HTML/metafile surfaces).
Verification target:

```sh
./pantry/.bin/zig build test -Dfilter=home_test --summary all
./zig-out/bin/home test packages/runtime/test/bun-corpus --bun-corpus-native-subset=bundler-core-itbundled
./zig-out/bin/home test packages/runtime/test/bun-corpus --bun-corpus-native-subset=bundler-transpiler-bootstrap
```

Runtime compile frontier: the current non-JSC runtime gate is red but
sharply narrowed. `./pantry/.bin/zig build test -Dfilter=home_rt
-Denable_jsc=false --summary failures` now fails at compile time with
**9 errors** on 2026-05-26, down from **38** earlier the same day. The
progression: the parked `EventLoopHandle.EventLoop` opaque became a sized
struct (so `VirtualMachine.zig` embeds it by value), then successive
faithful-port passes closed the granular layers it exposed.

Closed this run (all faithful, not shallow fakes):

- **strings/immutable substrate** — `copyLowercase`/`lastIndexOfChar`/
  `whitespace_chars`/`startsWithChar`/`eqlLong`/`utf16EqlString`/
  `firstNonASCII16` re-exports, `bun.clone`/`feature_flag`/
  `options.defaultLoaders`/`unsafeAssert`, `cpp.BunString__toThreadSafe`/
  `JSC__JSValue__isAnyInt`, `Async.KeepAlive` ref/unref/disable, and
  `ManagedTask`/`AnyTask.Task` unification.
- **node Buffer identity** — `bun.api.node.Buffer` re-pointed at
  `jsc.MarkedArrayBuffer` (was the pure-Zig `node/buffer.zig`); restored the
  faithful `buffer.slice()` calls in `runtime/node/types.zig`.
- **AnyPromise unification** — `AnyPromise`'s divergent local
  `Promise`/`InternalPromise`/`JSValue`/`VM`/`JSGlobalObject` stubs aliased
  to the canonical `jsc.JSPromise`/`JSInternalPromise`/etc. (the canonical
  types now carry the full promise method surface), plus the parked
  `JSC__JSPromise__status`/`result`/`isHandled`/`setHandled`/`rejectAsHandled`
  cpp stubs.
- **JSC value-type unification** — `Errorable.JSValue` and `Exception`'s
  `JSValue`/`JSGlobalObject` pointed at the canonical jsc types
  (`Exception.value()` now returns `JSValue` by value).
- **VM resolver path** — wired `jsc.ModuleLoader.HardcodedModule` to the
  self-contained `resolve_builtins/HardcodedModule.zig` builtin-alias table,
  and gave `node/process.zig`'s `exit` the Bun-faithful
  `exit(globalObject, code)` signature.

Zig 0.17 stdlib-drift fixes folded in: `std.time.milliTimestamp` →
`bun.milliTimestamp` (`std.c.clock_gettime`), the C-ABI `Bun__parseDate`
error-union signature, and a runtime-indexed `@Vector` in `firstNonASCII16`.
The default macOS JSC-enabled command still needs a fresh pass after the
non-JSC frontier closes.

The remaining **9 errors** are deep subsystem-port clusters; several have
hard prerequisites discovered this run and are no longer shallow stub
additions:

| Cluster | Representative errors | Real blocker discovered |
|---|---|---|
| `Output.Source` streaming | `output.Source` / `output.errorWriterBuffered` | **Blocked on a `sys/File.zig` writer migration**: `Source` instantiates `File.QuietWriter`, which uses `std.Io.GenericWriter` — removed in this Zig. The old→new `adaptToNewApi` bridge assumes a GenericWriter that no longer exists; File's Writer/QuietWriter must move to the new `std.Io.Writer` interface first. Also pulls `home_rt.take`, `jsc.ZigException`, more `Exception.value`. |
| `install/PackageManager` | `install/PackageManager.zig` `std.fs.Dir` (→ `std.Io.Dir`) drift, blocking the rest of the file | **Not a parity goal** — Pantry is the intentional package-manager divergence. Pulled into the graph because copied VM code references `resolver.package_manager`. The right move is a Pantry-backed/stub `package_manager` type for the resolver, not porting Bun's installer. |
| SavedSourceMap | `jsc.SavedSourceMap` missing `lock`/`unlock`/`last_path_hash`/`last_ism`/`getValueLocked`/`putMappings`/`putValue`/`resolveMapping` | Adding `lock` cascades the whole `resolveSourceMapping` body; needs the real `jsc/SavedSourceMap.zig` storage + mutex port. |
| RareData S3/IPC | `RareData.awsCache`, `RareData.spawnIPCGroup` | `AWSSignatureCache` uses the pre-0.17 managed `StringArrayHashMap.init(allocator)` (now an allocator-per-method `ArrayHashMap` taking 3 args); needs a Zig-0.17 refactor first, plus `uws.SocketGroup` for IPC. |
| Codegen Cached accessors | `DisabledTypedClass(...).ipcCallbackSetCached` | Zig can't synthesize named decls from strings, so the codegen pipeline (or explicit per-class accessors) must generate `<field>GetCached`/`SetCached`; also risks a subprocess.zig cascade. |
| BoringSSL TLS surface | `BoringSSL.c.SSL_get_error`, `BoringSSL.c.SSL.getVerifyError` | ~40-symbol OpenSSL surface for `ssl_wrapper`; extern decls also need a link provider, so this is real BoringSSL wiring, not a stub. |

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

1. **Bundler corpus completion.** Promote the remaining 10-file
   upstream Bun `bundler/` frontier as the next large test slice before
   moving into Bake/server-heavy tests. Keep
   `bundler/native-plugin.test.ts` last because upstream treats native
   plugins specially.
2. **Parallel test-runner process pool.** Integrate the dormant
   `runtime/cli/test/parallel` subtree as one chunk. Treat this as an
   integration backlog, not raw source-copy work: the seven Zig files are
   already source-present, but only the compile-wired leaves count today.

   | File | Current status | Next integration work |
   |---|---|---|
   | `FileRange.zig` | Compile-wired leaf | Keep counted as integrated only with its unit tests/build edge |
   | `Frame.zig` | Compile-wired leaf | Keep counted as integrated only with its unit tests/build edge |
   | `Channel.zig` | Dormant integration backlog | Source-visible; wire IPC backend over Home `uws`/sys surfaces |
   | `Coordinator.zig` | Dormant integration backlog | Source-visible; wire worker lifecycle, scheduler, reporting, and abort handling |
   | `Worker.zig` | Dormant integration backlog | Source-visible; wire process spawn, stdio capture, IPC adoption, and exit accounting |
   | `aggregate.zig` | Dormant integration backlog | Source-visible; wire JUnit/LCOV merge to Home fs/path/source-map surfaces |
   | `runner.zig` | Dormant integration backlog | Source-visible; unpark `ParallelRunner` entrypoints through Home's test command path |

   Known blockers for the five dormant files: Home-compatible aliases for Bun
   globals and allocators, `PathString`, `MimallocArena`, `Async`,
   `io.BufferedReader`, `uws`, `windows.libuv`, `c`, `fs.FileSystem`,
   `O`, `SourceMap`, `selfExePath`, `start_time`, `timespec`,
   `spawn`/process surfaces, `sys` error and file APIs, `fs` and `path`
   helpers, socket-pair or pipe adoption, and the JSC
   `VirtualMachine`/test-runner surfaces used by the worker loop. Count
   the chunk as integrated only when `ParallelRunner` exposes
   `runAsCoordinator`, `runAsWorker`, `workerEmitTestDone`, and `Worker`,
   all seven files compile through the runtime build graph, the Home
   `ParallelRunner` path avoids system Bun delegation, and focused tests
   cover frame IPC, worker spawn/reap, result aggregation, coverage or
   JUnit fragment handling, and at least one multi-file `home test
   --parallel` corpus smoke.
3. **Bake after bundler.** The sorted full-gate frontier moves naturally
   into `bake/`, and existing runtime source already has Bake lifetime
   carrier work to build on.
