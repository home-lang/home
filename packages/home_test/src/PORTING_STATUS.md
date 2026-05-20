# Bun Test Runner Port — Phase 4.5+

This directory contains a verbatim copy of Bun's `bun:test` framework
Zig source (`bun/src/runtime/test_runner/*.zig` plus
`bun/src/runtime/cli/test_command.zig`, MIT-licensed — see
`LICENSE.bun.md`). The copy is the starting point for a Home-side
`home_test` runtime package that exposes the same Jest-compatible API
(`describe` / `test` / `expect` / lifecycle hooks / snapshot APIs)
that editors and existing test suites already understand.

Most copied runner files still do **not** compile in this repo — every
deep runner file imports `bun` (Bun's stdlib aggregator), and only the
first compatibility slice is mapped to Home's `packages/compat` shim.
Each file is annotated with a header pointing back to its upstream
source. The plan below tracks adaptation status file-by-file.

The Home-side `corpus.zig`, `runner.zig`, and `corpus_runner.zig`
modules are active and compiled into the `home` executable. `corpus.zig`
owns discovery and test-file classification for `home test
packages/runtime/test/bun-corpus/`; `result.zig` owns the native
file/run result model; `runner.zig` owns the adapter-neutral
prepared-file and file-run contracts; `adapters/jsc_bootstrap.zig` owns
the current JSC bootstrap execution adapter; `corpus_runner.zig` owns the
explicit `--bun-corpus-native-subset=minimal-js` allowlist, source
preparation, and summary aggregation. The full runner remains blocked on
the native `bun:test` port and JSC host-call bridge.

`zig build test -Dfilter=home_test_bun_tier0` now build-checks the first
copied Bun Zig tier under pantry-provided Zig 0.17-dev:
`bun/diff/diff_match_patch.zig`, `bun/harness/fixtures.zig`, and
`bun/harness/recover.zig`. This target is deliberately filtered to the
Home-owned smoke tests so the full upstream `diff_match_patch` test suite
does not become a false runner-parity gate.

`zig build test -Dfilter=home_test_bun_tier1` build-checks the next
copied diff formatter leaf, `bun/diff/printDiff.zig`, through a focused
Home smoke root. This tier adds only the compat pieces required by that
file: Bun-style `handleOom(error_union)` unwrapping and
`bun.strings.isValidUTF8`.

`zig build test -Dfilter=home_test_bun_tier2_order` build-checks the
first copied runner scheduling leaf, `bun/Order.zig`, through a small
Home scaffold that mirrors only the upstream `bun_test` and `Execution`
types Order touches. This keeps JSC execution out of the tier while
preserving real scheduling semantics: adjacent concurrent sequences
merge into one group, `generateAllOrder` resets entry links and creates
one group per entry, and `generateOrderTest` wraps before/after hooks
around the test while preserving retry/repeat counts.

`zig build test -Dfilter=home_test_bun_tier2_collection` build-checks
the copied collection-phase leaf, `bun/Collection.zig`, through a small
Home scaffold that mirrors only the upstream BunTest/JSC types it
touches. This keeps the real JSC callback machinery out of the tier
while preserving collection semantics: root scope creation under preload
hooks, describe callback queueing, callback dispatch with scope restore,
and failed-scope skip behavior.

The bootstrap harness is intentionally narrow but now installs once per
JSC engine, resets counters before each allowlisted file, reports a file
as unsupported if it registers zero `bun:test` tests, and preserves
explicit harness unsupported errors across the
`adapters/jsc_bootstrap.zig` boundary instead of counting them as
assertion failures. It covers the first real smoke slice: basic
`describe` / `test` / `it`, `it.todo`, `it.failing`, lifecycle hooks,
retry/repeats runner options, `onTestFinished`, returned-thenable
rejection, `test.concurrent`, `test.each`, `.not`, `toBe`, `toBeDefined`,
`toBeUndefined`, `toBeTruthy`, `toBeNumber`, `toBeTypeOf`,
`toBeInstanceOf`, `toMatchObject`, object-form error matching in
`toThrow`, small `toEqual` / `toStrictEqual` deep equality including
`Map` / `Set` / byte-wise ArrayBuffer and typed arrays, `expect.any`, `expect.unreachable`, `describe.todo`, a small
`expect.extend` asymmetric matcher path, `toIncludeRepeated`,
`toContainKey`, `toContainKeys`, `toContainAnyKeys`, `atob` / `btoa`,
`Bun` branding plus `Bun.version`, `Bun.revision`, `Bun.stripANSI`,
`Bun.wrapAnsi`, `Bun.semver.satisfies`, `Bun.concatArrayBuffers`,
`Bun.escapeHTML`, `Bun.TOML.parse` non-string input errors,
`Bun.gc`, `mock.clearAllMocks`,
`toHaveBeenCalledTimes`, `expect().pass`, `expectTypeOf` type-only no-op checks, narrow TypeScript
constructor-modifier rewrites, bun-types `test.each` type-shape smoke, synchronous `it.each` / `describe.each` table expansion,
narrow `toMatchInlineSnapshot` object formatting,
`bun:internal-for-testing` regexp and PowerShell escaping helpers,
`assert` CJS require, `assert.match` / `assert.doesNotMatch`,
`assert/strict.deepStrictEqual` boxed primitive handling,
relative CJS fixture require for `regression/issue/013880-fixture.cjs`,
`node:path` / `path` join and posix/win32 identity smokes,
isAbsolute / normalize / resolve / relative empty-string smokes,
`node:url` URL.canParse, url.format empty-input, and
domainToASCII/domainToUnicode smokes,
`import.meta.resolve` / `resolveSync` bad-parent throw smokes,
`jest.fn`, narrow `HTMLRewriter` element and doctype callbacks plus
selector / handler validation,
`process.versions.bun`, `process.revision`, `process.on` / `process.emit`,
`node:vm.runInNewContext`, DOMException, native constructor identity,
mutable `globalThis` prototype behavior, comment-only module-load smoke,
Request/Response/Headers/URL, `node-fetch`, `node:buffer`, `deno:harness`,
Deno `Event` / `CustomEvent` / `AbortController`, a Deno
`URLSearchParams` bootstrap smoke, EventTarget, AbortSignal, Node
`Buffer.alloc` / fill / `Buffer.from(..., "utf-16le")` / compare /
write / toString / inspect-limit / isEncoding subsets, `Bun.JSONC.parse`
comments / trailing commas / deep-nesting `RangeError`s, Node
`module.SourceMap`, Event / MessageChannel / MessagePort / MessageEvent
constructor shims, Web `TextDecoder` CJK and single-byte encoding smokes,
a primitive/object `structuredClone` fallback for the string atomization
smoke, `Bun.inspect({ key: Set<string> })`, `Bun.jest(import.meta.path)`
as an alias to the existing bootstrap `bun:test` facade, `jest.mock`
argument validation, `jest.resetAllMocks`, `mockReturnThis`,
`expect.extend` matcher validation plus installed expectation-object
matchers, validation-only `Bun.S3Client.write`
numeric path errors, validation-only `Bun.Transpiler` invalid UTF-16
loader errors, and a narrow `ShadowRealm.evaluate` shim. Four sync runner
fixtures
(`only-fixture-4`, `21177`, `5738`, and printing dots) are also
allowlisted, with `console.warn` falling back to `console.log` for the
printing fixture. One snapshot `test.todo` fixture is allowlisted without
executing its snapshot matcher body. The source
rewrite lowers supported `bun:test` imports to a virtual
`globalThis.__home_import("bun:test")` module and lowers
`import.meta.dir/path` to the same per-file metadata used for the
directory and filename globals. Unsupported deep-equality types such as
typed arrays, `ArrayBuffer`, and `Error` now fail closed instead of
silently comparing as empty-key objects. Native ESM `bun:test`
registration still requires a narrow JSC module-loader bridge because
system JavaScriptCore's public C API does not expose Bun's synthetic
module hooks directly. This is a stepping stone for corpus bring-up, not
a substitute for the vendored Zig runner below.

> **Why a verbatim copy?** Per direction 2026-05-14: Bun is shifting
> its core to Rust; we want to continue maintaining the Zig portion
> ourselves. Vendoring lets us adapt the test runner to Home's HIR /
> diagnostics surface and runtime module loader without taking a
> dependency on the entire Bun runtime (JavaScriptCore, the resolver,
> the HTTP stack, …). MIT attribution is preserved per file and via
> `LICENSE.bun.md`.

The matching Rust port that lives next to each `.zig` upstream
(e.g. `jest.rs` next to `jest.zig`) is **not** copied — Bun's Rust
rewrite is out of scope for Home; we are taking the Zig fork.

---

## Inventory (93 .zig files + 2 .ts + 4 fixtures, ~20 274 LOC)

LOC sorted ascending (excluding the 3-line attribution header).
`bun=N` is the count of `bun.X` references in the file (a rough
proxy for porting effort). `rel=N` and `ext=N` count relative-path
`@import("./...")` and `@import("../...")` calls respectively.

The 70 individual matchers under `expect/` are nearly identical in
shape (each ~30-100 LOC, 7-10 `bun.X` references — almost all
`bun.jsc.*` + `bun.JSError`). They're listed grouped at the bottom.

| File | LOC | bun | rel | ext | Compile | Top 3 Externs Needed |
|---|---:|---:|---:|---:|---|---|
| DoneCallback.zig | 47 | 5 | 0 | 0 | blocked | `bun.md`, `bun.handleOom`, `bun.JSError` |
| diff_format.zig | 85 | 5 | 2 | 0 | blocked | `bun.md`, `bun.AllocationScope`, `bun.Output` |
| debug.zig | 109 | 7 | 1 | 0 | blocked | `bun.JSError`, `bun.md`, `bun.env_var` |
| harness/recover.zig | 132 | 1 | 0 | 0 | tier0 | `bun.md` |
| Collection.zig | 171 | 8 | 0 | 0 | tier2-collection | `bun.JSError`, `bun.assert`, `bun.md` |
| Order.zig | 187 | 16 | 0 | 0 | tier2-order | `bun.JSError`, `bun.assert`, `bun.Environment` |
| timers/FakeTimers.zig | 376 | 32 | 0 | 0 | blocked | `bun.JSError`, `bun.timespec`, `bun.assert` |
| ScopeFunctions.zig | 498 | 64 | 0 | 0 | blocked | `bun.String`, `bun.JSError`, `bun.handleOom` |
| jest.zig | 520 | 44 | 3 | 1 | blocked | `bun.handleOom`, `bun.default_allocator`, `bun.JSError` |
| harness/fixtures.zig | 575 | 1 | 0 | 0 | tier0 | `bun.md` |
| snapshot.zig | 582 | 49 | 3 | 0 | blocked | `bun.copy`, `bun.logger`, `bun.sys` |
| diff/printDiff.zig | 586 | 12 | 1 | 0 | tier1 | `bun.handleOom`, `bun.md`, `bun.strings` |
| Execution.zig | 695 | 35 | 0 | 1 | blocked | `bun.timespec`, `bun.assert`, `bun.JSError` |
| bun_test.zig | 1 073 | 64 | 7 | 1 | blocked | `bun.JSError`, `bun.timespec`, `bun.jsc` |
| pretty_format.zig | 2 145 | 33 | 1 | 1 | blocked | `bun.JSError`, `bun.fmt`, `bun.default_allocator` |
| expect.zig | 2 272 | 144 | 76 | 0 | blocked | `bun.JSError`, `bun.String`, `bun.jsc` |
| cli/test_command.zig | 2 277 | 239 | 4 | 9 | blocked | `bun.default_allocator`, `bun.handleOom`, `bun.jsc` |
| diff/diff_match_patch.zig | 2 995 | 2 | 0 | 0 | tier0 | `bun.md`, `bun.StringHashMapUnmanaged` |
| **expect/*.zig** (70 matchers) | ~2 800 total | 7-10 each | 0 | 0-1 | blocked | `bun.jsc`, `bun.md`, `bun.JSError` |

Legend:

- **blocked**: doesn't compile yet because `@import("bun")` cannot be
  resolved.
- **partial**: compiles with stubs, missing functionality is
  TODO-marked.
- **clean**: compiles standalone in `packages/home_test/src/bun/`.

### Matchers grouped (`expect/*.zig`, all blocked)

Type-checks: `toBeArray`, `toBeBoolean`, `toBeDate`, `toBeFunction`,
`toBeInteger`, `toBeNil`, `toBeNull`, `toBeNumber`, `toBeObject`,
`toBeString`, `toBeSymbol`, `toBeUndefined`, `toBeValidDate`,
`toBeDefined`, `toBeTypeOf`, `toBeInstanceOf`.

Truthiness: `toBe`, `toBeTrue`, `toBeFalse`, `toBeTruthy`, `toBeFalsy`,
`toBeNaN`, `toBeFinite`.

Numeric: `toBeCloseTo`, `toBeEven`, `toBeOdd`, `toBeNegative`,
`toBePositive`, `toBeGreaterThan`, `toBeGreaterThanOrEqual`,
`toBeLessThan`, `toBeLessThanOrEqual`, `toBeWithin`.

Equality: `toEqual`, `toStrictEqual`, `toEqualIgnoringWhitespace`,
`toMatchObject`, `toBeOneOf`.

Strings/regex: `toContain`, `toContainEqual`, `toMatch`, `toInclude`,
`toIncludeRepeated`, `toStartWith`, `toEndWith`.

Collections: `toBeEmpty`, `toBeEmptyObject`, `toBeArrayOfSize`,
`toContainAllKeys`, `toContainAllValues`, `toContainAnyKeys`,
`toContainAnyValues`, `toContainKey`, `toContainKeys`, `toContainValue`,
`toContainValues`, `toHaveLength`, `toHaveProperty`.

Mocks: `toHaveBeenCalled`, `toHaveBeenCalledOnce`,
`toHaveBeenCalledTimes`, `toHaveBeenCalledWith`,
`toHaveBeenLastCalledWith`, `toHaveBeenNthCalledWith`,
`toHaveLastReturnedWith`, `toHaveNthReturnedWith`, `toHaveReturned`,
`toHaveReturnedTimes`, `toHaveReturnedWith`.

Errors: `toThrow`, `toSatisfy`.

Snapshots: `toMatchSnapshot`, `toMatchInlineSnapshot`,
`toThrowErrorMatchingSnapshot`, `toThrowErrorMatchingInlineSnapshot`.

---

## External `bun.X` surface (top 30, by occurrence)

These are the symbols we need to either stub, adapt, or formally
re-export from a Home-side `compat.zig` shim (the same shim the
bundler port also needs). The full list is 70 unique identifiers —
these are the highest-leverage 30.

| Count | Symbol | Suggested mapping |
|---:|---|---|
| 424 | `bun.jsc` | **Defer** — JavaScriptCore is off-scope. Gate every reference behind a `comptime` flag (`enable_jsc=false`); stub `JSValue`/`JSGlobalObject`/`CallFrame` with placeholder structs until Home's interpreter exposes a JS-runtime shim. |
| 225 | `bun.JSError` | Map onto Home's `Result(T, JsError)` from `ts_diagnostics`. Initially type-alias to `error{JsException, OutOfMemory}`. |
| 129 | `bun.default_allocator` | Re-export `std.heap.smp_allocator` (or `c_allocator`). |
| 93 | `bun.md` | Self-import marker (Bun's `bun.md` returns the current `@This()` module). Replace with `@This()` per-call-site. |
| 57 | `bun.handleOom` | Wrap `error.OutOfMemory` → panic helper in `compat.zig`. |
| 57 | `bun.String` | Bun's tagged-pointer JSC-aware string. Use `[]const u8` + `string_interner` initially; the JSC-aware variant only matters once `jsc` is in play. |
| 29 | `bun.timespec` | Wraps `std.posix.timespec`; port verbatim into `compat`. |
| 29 | `bun.assert` | Alias for `std.debug.assert`. |
| 18 | `bun.Output` | **Adapt** to `ts_diagnostics.Output` (scoped logger). |
| 18 | `bun.strings` | **Adapt** — most call-sites want `std.mem.eql`/`indexOf`; add a thin shim for the specialised SIMD scanners. |
| 16 | `bun.copy` | Likely `std.mem.copyForwards` or similar — confirm per-callsite. |
| 16 | `bun.fmt` | Stub — formatters; most call-sites are `fmt.fmtSliceHexLower` style helpers; port on demand. |
| 15 | `bun.O` | POSIX-open flags wrapper; map to `std.posix.O`. |
| 14 | `bun.cpp` | Bun's C++ binding pointer surface; mostly snapshot formatter glue. **Defer** behind `enable_cpp=false`. |
| 12 | `bun.Environment` | Stub — provides `isDebug`, `isWindows`, `isMac` constants. Implement via `builtin.os.tag`/`builtin.mode`. |
| 10 | `bun.sys` | Syscall wrappers. **Adapt** to Home's `stdlib.fs` / `stdlib.io`. |
| 10 | `bun.SourceMap` | **Adapt** — Home has its own source-map emitter in `ts_emit/src/source_map.zig`. |
| 9 | `bun.deprecated` | Marker macro; trivially port. |
| 8 | `bun.env_var` | Env-var reader; map to `std.process.getEnvVarOwned`. |
| 8 | `bun.api` | Bun runtime API hooks (vm, sourcemap registry). **Defer** behind `enable_runtime_api=false`. |
| 8 | `bun.ZigString` | JSC-aware string slice; **defer** with `jsc`. |
| 7 | `bun.debugAssert` | Compile-time-gated assert; alias `if (builtin.mode == .Debug) std.debug.assert(...)`. |
| 7 | `bun.cast` | Pointer-cast helper; replace per-callsite with `@ptrCast`/`@as`. |
| 7 | `bun.fs` | **Adapt** to Home's `ts_resolver.fs`. |
| 7 | `bun.path` | **Adapt** to Home's `ts_resolver.path` helpers. |
| 6 | `bun.PathBuffer` | Stub — short-string interner for paths; replace with `[]const u8` initially. |
| 6 | `bun.js_lexer` | The JS lexer used by snapshot formatting (to detect quoted strings). **Reuse** Home's `ts_lexer` once the API matches. |
| 5 | `bun.logger` | **Adapt** to `ts_diagnostics.Logger`. |
| 4 | `bun.hash` | XXH3 / Wyhash wrappers. Map to `std.hash.Wyhash`. |
| 4 | `bun.ci` | CI-detection helpers (Jest reporter switches output mode). Trivial port. |

The remaining tail (~40 symbols) is single-digit counts of helpers
like `bun.allocators`, `bun.bit_set`, `bun.collections`,
`bun.AllocationScope`, `bun.HiveArray`, `bun.spawnSync`,
`bun.invalid_fd`, etc. — port on demand.

---

## Build order (lowest dep depth first)

### Tier 0 — pure helpers that need only stdlib + a tiny shim

These need only `compat` for `OOM`/`handleOom`/`assert`/`md`:

1. `harness/recover.zig` (132 LOC) — single `bun.md` reference
2. `harness/fixtures.zig` (575 LOC) — single `bun.md` reference
3. `diff/diff_match_patch.zig` (2 995 LOC) — only `bun.md` and
   `bun.StringHashMapUnmanaged`. Largest pure-data file in the tree;
   will compile early once the shim is up.

### Tier 1 — diagnostics & formatters (depend on `bun.Output` shim)

4. `diff_format.zig` (85 LOC) — `bun.Output`, `bun.AllocationScope`
5. `debug.zig` (109 LOC) — env-var debug switches
6. `pretty_format.zig` (2 145 LOC) — Jest's value pretty-printer;
   touches `bun.fmt` heavily but no JSC required at the top level
7. `diff/printDiff.zig` (586 LOC) — colored Jest-style diff

### Tier 2 — test scaffolding (need `bun.timespec` + `bun.assert`)

8. `Collection.zig` (171 LOC) — test collection; compile-checked in
   the focused `home_test_bun_tier2_collection` target with a local
   BunTest/JSC scaffold for collection-phase callback scheduling
9. `Order.zig` (187 LOC) — deterministic ordering; compile-checked in
   the focused `home_test_bun_tier2_order` target with a local scaffold
   for the small `bun_test` / `Execution` surface it touches
10. `DoneCallback.zig` (47 LOC) — async test done callback
11. `Execution.zig` (695 LOC) — scheduler + timeout machinery
12. `timers/FakeTimers.zig` (376 LOC) — Jest-style fake timers
13. `snapshot.zig` (582 LOC) — snapshot persistence (touches
    `bun.sys`/`bun.logger`)

### Tier 3 — JSC-bound surface (gate behind `enable_jsc`)

These cannot meaningfully run until Home's JS runtime is wired up;
they are the entire `expect`/`describe` surface.

14. `expect.zig` (2 272 LOC) — `expect()` harness, all asymmetric matchers
15. `expect/*.zig` (70 files, ~2 800 LOC) — individual matchers
16. `ScopeFunctions.zig` (498 LOC) — `describe`/`test`/hook factories
17. `jest.zig` (520 LOC) — scope tree + lifecycle
18. `bun_test.zig` (1 073 LOC) — top-level entrypoint
19. `cli/test_command.zig` (2 277 LOC) — `bun test` CLI driver

### Out-of-scope (do not port, replace with Home's own equivalents)

- Anything under `bun.bake` / `bun.bundle_v2` references in
  `cli/test_command.zig` — Home's bundler lives in `bundler`.

- The `mod.rs` / `*.rs` files in upstream — Bun's Rust port is
  explicitly out of scope per direction 2026-05-14.

---

## Perf-critical decisions to preserve

These are patterns the upstream maintainers chose specifically for
throughput. Any port must keep them.

1. **Threadlocal arenas for matcher work** (`expect.zig`,
   `pretty_format.zig`). Each matcher invocation allocates from a
   per-test arena that is dropped wholesale on test exit. Massively
   reduces individual `free` calls on hot paths and avoids the global
   allocator's contention.

2. **Lazy snapshot file IO** (`snapshot.zig`). Snapshot file is read
   once per test file, mutated in-memory, and flushed once on suite
   exit. Avoids hammering `read()`/`write()` per matcher.

3. **`HiveArray` for free-list of `Expect` instances**
   (`expect.zig`). Bun's HiveArray is a free-list-backed pool; lets
   matchers `alloc`/`free` `Expect` instances cheaply across the
   thousands of `expect(...)` calls a typical suite makes.

4. **Diff via `diff_match_patch.zig`** (Google's algorithm). Hand-port
   verbatim — the upstream is well-tested and the Zig port is already
   tuned (~3 kLOC).

5. **JIT-emitted matcher dispatch** (`expect.zig`). Each matcher is
   exposed to JS as a `JSC::HostFunction` registered through
   `jest.classes.ts`. We will need to mirror the dispatch table once
   Home's runtime exposes a host-function surface.

6. **`std.MultiArrayList` for test scope tree** (`Collection.zig`).
   Stores each scope field in its own contiguous slice — same ECS
   pattern the bundler uses. Already in stdlib.

7. **`bun.timespec` monotonic clock** for test duration. Use
   `std.posix.clock_gettime(.MONOTONIC, ...)` — same monotonic
   guarantees, no JSC required.

8. **Single-pass tokenization in inline-snapshot writeback**
   (`snapshot.zig`). Avoids re-parsing the entire test file when
   updating an inline snapshot. Port the algorithm verbatim.

---

## Next steps (suggested order)

1. Keep the active corpus discovery in `corpus.zig` green under
   Pantry Zig 0.17 dev, and keep the full corpus command failing as a
   native Home gate until execution is real.

2. Land this copy with build wiring that does **not** add
   `src/bun/` to any test step (so `zig build test` stays green).

3. Share the `compat/` shim with the bundler port
   (`packages/bundler/src/bun/PORTING_STATUS.md` Tier 0). The
   minimal surface needed for Tier 0/1 here:

   - `OOM`, `handleOom`, `default_allocator`, `assert`, `debugAssert`,
     `md` (self-import marker), `Environment.{isDebug,isWindows,isMac}`,
     `timespec`, `O`, `copy`, `cast`, `hash.Wyhash`,
     `StringHashMapUnmanaged`.

4. Make `harness/recover.zig` + `harness/fixtures.zig` +
   `diff/diff_match_patch.zig` compile against the shim. Add a tiny
   test artifact to keep them green going forward.

5. Iterate Tier 1 → Tier 2, adapting `Output`/`logger`/`sys`/`fmt`
   as we go.

6. Defer Tier 3 (the JSC-bound surface) until Home's runtime exposes
   a `home_test_runtime` shim with a `JSValue` placeholder that maps
   onto Home's interpreter's value representation.

7. Once Tier 3 is in, expose the public API listed in
   `home_test.zig`'s doc-comment via a `home:test` runtime module.
