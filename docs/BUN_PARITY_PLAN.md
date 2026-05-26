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

Next large slice: **bundler corpus completion**. Promote the remaining
roughly 23 unallowlisted upstream Bun `bundler/` tests into the native
Home corpus gate before expanding into Bake or server-heavy tests. Keep
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
It runs eight additional bundler/transpiler files and passes:
**78 passed, 0 failed, 0 todo** on 2026-05-26.

Files in the tranche:

- `bundler/bundler_feature_flag.test.ts`
- `bundler/plugin-error-nested-throw.test.ts`
- `bundler/transpiler/es-decorators.test.ts`
- `bundler/transpiler/preserve-use-strict-cjs.test.ts`
- `bundler/transpiler/template-literal.test.ts`
- `bundler/transpiler/function-tostring-require.test.ts`
- `bundler/transpiler/export-default.test.js`
- `bundler/transpiler/scope-mismatch-panic.test.ts`

Next work is to promote `bundler/transpiler/bun-pragma.test.ts`, whose
first current blocker is bootstrap lowering for typed rest-parameter
syntax such as `(...segs: string[]): string =>`, then continue through
the remaining ordinary transpiler files before replacing the
`__home_expect_bundled` stub with a real `itBundled` adapter and wiring
the needed Bun bundler substrates in `packages/bundler/src/`
(`options.zig`, `transpiler.zig`, `bundle_v2.zig`,
`LinkerContext.zig`, `OutputFile.zig`, plus HTML/metafile surfaces).
Verification target:

```sh
./pantry/.bin/zig build test -Dfilter=home_test --summary all
./zig-out/bin/home test packages/runtime/test/bun-corpus --bun-corpus-native-subset=bundler-core-itbundled
./zig-out/bin/home test packages/runtime/test/bun-corpus --bun-corpus-native-subset=bundler-transpiler-bootstrap
```

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

1. **Bundler corpus completion.** Promote the remaining roughly 23
   unallowlisted upstream Bun `bundler/` corpus files as the next large
   test slice before moving into Bake/server-heavy tests. Keep
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
