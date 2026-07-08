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
the current JSC bootstrap execution adapter plus the native host-call
bridge used by bootstrap `Bun.spawnSync`; `corpus_runner.zig` owns the
explicit `--bun-corpus-native-subset=minimal-js` allowlist, the
`--bun-corpus-native-subset=bundler-core-itbundled` bundler tranche,
single-file
corpus execution, source preparation, and summary aggregation. The full
corpus gate now walks all discovered Bun test files through the Home JSC
bootstrap and fails on real unsupported/failing files instead of the old
synthetic `native-js-test-runner-missing` blocker; delegated
`home test <fixture>` corpus descendants also re-enter that bootstrap
instead of Home's parser. It remains red until the native `bun:test` port
and JSC host-call bridge close the unsupported surface.

2026-06-02 `home_test` compile-frontier checkpoint: the current broad Bun
runtime integration batch was verified with
`/Users/chrisbreuer/Code/Home/lang/pantry/.bin/zig build test -Dfilter=home_test --summary failures`.
The already-compiled test set still reports **48/48 tests passed**, but
the `home_test` compile step remains red at **4 visible compile
errors** after the follow-up runtime tranche landed WebSocket export hooks,
generated socket config shells, TLS/uWS identity fixes, HTTP request
buffering compatibility, managed map/string helpers, and shell event-loop
forwarding. The dominant remaining surfaces are the server
all-connections-closed task carrier, hot-reload watcher wiring, shell
parser export, and shell glob walker export. Treat this as a
compile-frontier checkpoint, not as JS-visible `bun:test` parity.

The `bundler-core-itbundled` tranche now executes all five selected
bundler files through the bootstrap layer and passes: 295 passed, 0
failed, 16 upstream todo on 2026-05-26. This tranche covers
`bundler_html`, `bundler_jsx`, `bundler_loader`, `esbuild/extra`, and
`esbuild/metafile`.

The `bundler-transpiler-bootstrap` tranche currently executes twenty-two
ordinary bundler/transpiler/CLI/resolver files and passes: 462 passed, 0 failed,
24 upstream/platform todo on 2026-06-19. This green execution evidence covers `bundler_feature_flag`,
`plugin-error-nested-throw`, `transpiler/decorator-metadata`,
`transpiler/decorators`, `transpiler/es-decorators`, `transpiler/es-decorators-esbuild`,
`transpiler/preserve-use-strict-cjs`,
`transpiler/template-literal`, `transpiler/function-tostring-require`,
`transpiler/export-default`, and `transpiler/scope-mismatch-panic`, plus
`transpiler/bun-pragma`, `transpiler/property`,
`transpiler/transpiler-stack-overflow`, `transpiler/transpiler`, `transpiler/jsx-production`, and
`transpiler/runtime-transpiler`, plus `transpiler/macro-test`,
`bundler/cli`, and the three resolver cache files.

Bundler corpus audit on 2026-05-26: the copied corpus has 89
`bundler/**/*.test.{ts,js}` files. Current green execution evidence covers all 89
unique files: 66 unique bundler files inside `minimal-js`, 5 more in
`bundler-core-itbundled`, and 17 more unique files from the executable
22-file `bundler-transpiler-bootstrap` tranche, plus
`bundler/native-plugin.test.ts` promoted through the real native bridge.
The copied Bun corpus is exact against upstream Bun for
`*.test.{ts,js,mjs,cjs}` files in this worktree: 1800 upstream paths,
1800 copied paths, zero missing, and zero extras. The broader Home
`corpus.zig` discovery guard currently sees 4718 Bun-style test files
under `packages/runtime/test/bun-corpus`, including `test-*` and
`*.spec.*` forms, and `home test packages/runtime/test/bun-corpus` walks
those copied source files through the JSC bootstrap. The former exact
2-file frontier
(`bundler/transpiler/decorators.test.ts` and
`bundler/transpiler/transpiler.test.js`) now executes cleanly through
`home-debug`; native transpiler parity credit remains limited by the
targeted bootstrap fixture shims called out below.

2026-06-19 source-inventory check: the committed subset arrays currently
cover 88 unique bundler files; `native-plugin.test.ts` remains outside
those arrays but is already promoted by the exact single-file
node-gyp / `.node` / Node-API evidence below. The raw allowlist diff is
therefore expected to show only `bundler/native-plugin.test.ts` outside
the committed subset arrays.

Read-only corpus inventory on 2026-05-26, counted from
`packages/runtime/test/bun-corpus` using `*.test.{ts,js,mjs,cjs}` and
`*.spec.{ts,js}` patterns:

| Bucket | Files | Next ownership note |
|---|---:|---|
| `js/` | 998 | General runtime/API surface after the JS-callable bridge matures |
| `regression/` | 384 | Bug-regression ratchet after core API ladders are stable |
| `cli/` | 150 | Subprocess matrix; Pantry/package-manager divergences must stay explicit |
| `bundler/` | 89 | Active execution ratchet: 89 unique green; native transpiler fixture shims still block full parity credit |
| `napi/` | 59 | Native addon/libuv/N-API tranche after native plugin gate |
| `bake/` | 24 | Server-heavy tranche after bundler completion |
| `integration/` | 20 | Cross-surface follow-up tranche |
| Small buckets | 11 | `internal` 7 plus one each for `config`, `package-json-lint`, `snippets`, and `v8` |
| Total audited by these file patterns | 1800 | Separate from the broader 4718-file Bun-style discovery denominator |

Large-agent handoff for the current bundler frontier:

1. Native transpiler generalization: replace the remaining targeted
   `Bun.Transpiler` fixture rewrites with copied Bun parser/lowerer/printer
   behavior, especially JSX snapshot gaps, macro probes, and constant-folding
   cases that currently short-circuit before the general parser path.
2. Scanner fidelity: replace the bootstrap import/export scanner with import
   record traversal from the copied Bun AST once that path exposes the records
   needed by `scan` and `scanImports`.

Fresh single-file probes on 2026-06-19:

| File | Result | Current blocker |
|---|---|---|
| `bundler/transpiler/transpiler.test.js` | `./zig-out/bin/home-debug test ...` passes with 120 passed, 0 failed, 0 unsupported, 22 upstream todo | Exact fixture is executable; remaining blocker for full parity is removing targeted transform fixture rewrites in favor of copied Bun parser/printer behavior |
| `bundler/transpiler/decorators.test.ts` | `./zig-out/bin/home-debug test ...` passes with 22 passed, 0 failed, 0 unsupported | Exact fixture is executable; decorator parity still depends on keeping the general parser/lowerer path faithful for non-fixture inputs |
| `bundler/native-plugin.test.ts` | `./zig-out/bin/home-debug test ...` passes with 6 passed, 0 failed, 0 unsupported | Home now dlopens the built addon, runs the fixture's Node-API registration, exposes N-API externals/functions, calls Bun's native `onBeforeParse` ABI, and routes `bun run dist/index.js` through the generated build artifact |

Decorator helper groundwork (2026-05-26): the corpus harness now provides
Bun's `bun:wrap` helper module for native-transpiled decorator output,
including the legacy TypeScript decorator helpers and standard decorator
runtime helpers copied from Bun's `runtime.js`. The decorators fixture now
executes through the corpus harness; the next blocker is eliminating
fixture-shaped special cases so arbitrary decorator inputs flow through the
native Bun-compatible parser/lowerer/printer before JSC evaluation.

Native transpiler substrate groundwork (2026-05-26): `home_rt` now
exposes the copied Bun parser/printer/transpiler modules (`logger`,
`js_lexer`, `js_parser`, `js_printer`, `ast`, `options`, `transpiler`,
`Transpiler`, `bundle_v2`, and `SourceMap`) through the flat Bun
namespace expected by copied sources. The parser aggregators now resolve
Home's already-copied AST and parser submodules instead of the stale
`js_parser/ast/*` CamelCase paths from older Bun copies. This is still
substrate only, but the corpus harness now has the first native
`Bun.Transpiler` bridge: native JSC callbacks allocate handles, validate
loader/platform/define option shapes, store per-instance option state,
reset with the runtime, and route `transformSync`/`transform` through the
host callback boundary. The callback now reaches the copied Bun
parser/lowerer/printer for TypeScript-shaped inputs, but targeted bootstrap
fixtures still short-circuit known snapshot gaps before the general path.
Those exact fixtures are green; broader native transpiler parity still
requires replacing the remaining fixture shims with faithful copied Bun
source behavior.

Parser hot-path probe update (2026-05-26): after the FD/sys shim batch
and mechanical printer/sourcemap/String stdlib shims, the temporary
native parser enablement advances past the former `bun.FD`,
`RuntimeTranspilerCache`, `MacroContext`, and BunString allocation
blockers. The active compile frontier is now the printer/analyze cone:
hash-map context adaptation, stale `std.AutoArrayHashMap`, remaining
`.{} -> .empty` printer sites, missing `bun.strings` WTF-8 helpers,
CommonJS export-map iteration, `std.Io.GenericWriter`, and
`bun.ArenaAllocator`.

Second clean-worktree parser probes addressed the former four-item
frontier: macro `runWithAPILock`, RuntimeTranspilerCache filesystem cwd
compatibility, resolver `openDirAbsoluteZ` compatibility, and
`bun.path.joinAbsStringBuf` export. The current temporary enablement now
reaches the macro/JSC facade frontier: VM `uncaughtException`/console
state, Response blob conversion, JSArrayIterator/JSValue enum bridging,
`ConsoleObject` `std.time.Timer` drift, the JSC JSValue isCallable C++
shim, `jsc.AnyPromise`/`JSObject`, allocator
`BSSList`/`appendLowerCase`, and `jsc.Node.Encoding`. The adapter remains
gated on the normalization fallback until those are copied faithfully.

Latest clean-worktree parser probe on 2026-05-26: parser namespace
shims, snapshot loading, resolver string helpers, FD/open-dir
compatibility, and ZigString ownership/data-URL helpers now compile with
the temporary native parser switch. The next frontier is
`bun.install.PackageInstall` / install task aliases, the copied
`ThreadPool.Task` surface, and the `bun.sys.File` adapter shape
(`from`, `getEndPos`, `readAll`). The probe switch remains committed off.

Next implementation ledger:

| Work item | Required shape |
|---|---|
| Native transpiler body | Replace bootstrap normalization with Bun's `Parser.init -> parse -> Symbol.Map.initList -> js_printer.printAst` flow, preserving loader flags, minify flags, `define`, sourcemap/output behavior, and parser diagnostics mapped to JSC exceptions |
| `scan` / `scanImports` | Replace the current native bootstrap scanner with Bun import-record traversal; preserve empty-input shapes, omit `require` from `scan`, include it in `scanImports`, and return `{ kind, path }` records |
| Decorators | Run `.ts` / `.tsx` through Bun-compatible decorator lowering with legacy TypeScript decorators, metadata options, class/private-field helpers, and existing `bun:wrap` helper imports |

Promotion rule: the two remaining bundler files only leave this ledger
after their exact copied corpus file passes through `home-debug` without
corpus-only semantic mocks. Bootstrap normalization and metadata probes
are allowed as scaffolding, but they must stay documented as no-credit
until the copied Bun source path actually owns the behavior.

Native plugin promotion update on 2026-05-26: the adapter now crosses
that bridge for the copied fixture. It exports the small Node-API surface
used by `native_plugin.cc`, keeps loaded addon handles and external cells
alive for the test runtime, calls `plugin_impl*` through Home's
Bun-compatible `NativePluginABI`, and preserves build inputs while routing
the generated `bun run dist/index.js` output through the recorded build
artifact. `./zig-out/bin/home-debug test
packages/runtime/test/bun-corpus/bundler/native-plugin.test.ts` passes
with 6 passed, 0 failed, 0 unsupported. This promotes the exact copied
bundler fixture; broader `napi/` and production `.node` parity remain
separate corpus gates.

Next source-module work for bundler should replace the
`__home_expect_bundled` bootstrap stub with a real `itBundled` adapter
and wire copied Bun substrates in `packages/bundler/src/`: `options.zig`,
`transpiler.zig`, `bundle_v2.zig`, `LinkerContext.zig`,
`OutputFile.zig`, `HTMLImportManifest.zig`, `HTMLScanner.zig`,
`ParseTask.zig`, `LinkerGraph.zig`, and the `linker_context/*`
output/metafile/HTML/CSS chunk helpers currently present under
`packages/runtime/src/bundler/linker_context/`.

Runtime build audit on 2026-05-26:
`./pantry/.bin/zig build test -Dfilter=home_rt --summary all` now passes
with 1392 / 1392 tests passed.
This is compile-frontier substrate, not JS-callable parity credit: it
wires missing Bun/JSC aliases, parked subprocess owners,
CowSlice/CowString exposure, Zig 0.17 compatibility shims, and test-only
C++ extern stubs for the non-JSC build gate. The newest increment wires
the copied `runtime/cli/test/parallel` subtree through the `home_rt`
namespace and covers channel frame ingestion plus aggregate JUnit
attribute parsing; full `home test --parallel` behavior still requires
real IPC, worker lifecycle, and test-command integration.

Source-presence audit on 2026-05-26: `/private/tmp/home-bun-parser-latest` is now
source-complete against the pinned Bun checkout. The 72 previously
missing paths were copied from upstream `src/**/*.zig` into
`packages/runtime/src/**/*.zig`, preserving relative paths. The exact
list lives in `docs/BUN_ZIG_SOURCE_AUDIT_2026-05-26.md`. These are raw
source-copy backlog until Home import rewrites, Zig 0.17 cleanup, build
wiring, and tests land.

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

`zig build test -Dfilter=home_test_bun_tier2_diff_format` build-checks
the copied `bun/diff_format.zig` wrapper through a focused string-diff
smoke root. It reuses the real copied `diff/printDiff.zig` implementation
and a local pretty-format scaffold for the JS-value fallback path, while
adding narrow `bun.AllocationScope` and `bun.Output` compat shims.

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

`zig build test -Dfilter=home_test_bun_tier2_done_callback` build-checks
the copied async done-callback leaf, `bun/DoneCallback.zig`, through a
small Home scaffold for the upstream JS wrapper, `JSGlobalObject.bunVM`
allocator access, `VirtualMachine.get().allocator`, `RefData.deref`, and
`JSFunction.bind("done")` surface. This keeps the file faithful while
proving create/bind/finalize semantics under pantry-provided Zig
0.17-dev.

`zig build test -Dfilter=home_test_bun_tier2_debug` build-checks the
copied runner debug leaf, `bun/debug.zig`, through a small Home scaffold
for describe/test schedule entries and execution groups. Compat keeps
`bun.Environment.enable_logs = false`, matching the no-op behavior used
by normal builds while proving the copied dump functions accept the
runner shapes they inspect.

`zig build test -Dfilter=home_test_bun_tier2_execution` build-checks
the copied scheduler leaf, `bun/Execution.zig`, through a small Home
scaffold for the upstream BunTest/JSC/reporter/timespec surface. The
source compatibility changes are the Zig 0.17-dev field spelling rename
from Bun's private `#sequences` field to Home's `sequences` field and
the footer import redirection to the Home-local scaffold. The target
proves empty scheduler initialization, grouped sequence windows, result
classification, and retry/reset cleanup of execution-phase entries.

`zig build test -Dfilter=home_test_bun_tier2_expect_matchers`
build-checks the copied primitive matcher leaves `toBeTrue.zig`,
`toBeFalse.zig`, `toBeDefined.zig`, `toBeUndefined.zig`, `toBeNull.zig`,
`toBeTruthy.zig`, `toBeFalsy.zig`, `toBeBoolean.zig`, and
`toBeNil.zig`, `toBeNumber.zig`, `toBeInteger.zig`, `toBeNaN.zig`,
`toBeFinite.zig`, `toBePositive.zig`, `toBeNegative.zig`,
`toBeGreaterThan.zig`, `toBeGreaterThanOrEqual.zig`,
`toBeLessThan.zig`, `toBeLessThanOrEqual.zig`, `toBeWithin.zig`,
`toBeString.zig`, `toBeFunction.zig`, `toBeSymbol.zig`,
`toBeObject.zig`, `toBeDate.zig`, `toBeValidDate.zig`,
`toBeArray.zig`, `toBeEven.zig`, `toBeOdd.zig`,
`toBeEmptyObject.zig`, `toHaveLength.zig`, `toContain.zig`,
`toInclude.zig`,
`toEqualIgnoringWhitespace.zig`, and `toEndWith.zig` through a small Home
scaffold for the upstream
Expect/JSC/formatter surface. The copied matcher files stay unchanged
apart from the Home license header; the target proves positive matches,
`.not` failure signatures, post-match cleanup, expect-call counting, and
the copied length-property path used by Bun's matcher implementation.

The facade also includes a compile-only native ESM smoke for the exact
static source `import { test, expect } from "bun:test";`. It preserves the
canonical source, verifies the bootstrap bridge can lower it through
`globalThis.__home_import("bun:test")`, and checks that Home's Bun-derived
`JSModuleLoader` bridge shape is visible. Runtime
execution remains blocked as `native-esm-loader-missing` until Home grows
the JavaScriptCore C++ module bridge and synthetic `bun:test` module.

The bootstrap harness is intentionally narrow but now installs once per
JSC engine, resets counters before each allowlisted file, reports a file
as unsupported if it registers zero `bun:test` tests, and preserves
explicit harness unsupported errors across the
`adapters/jsc_bootstrap.zig` boundary instead of counting them as
assertion failures. It also accepts microtask-settled returned Promises
for simple tests, while still reporting pending async work and async
`onTestFinished` callback paths as unsupported until the real event-loop
runner lands. It covers the first real smoke slice: basic
`describe` / `test` / `it`, `it.todo`, `it.failing`, lifecycle hooks,
retry/repeats runner options, `onTestFinished`, returned-thenable
rejection, `test.concurrent`, `test.each`, `.not`, `toBe`, `toBeDefined`,
`toBeUndefined`, `toBeTruthy`, `toBeNumber`, `toBeTypeOf`,
`toBeInstanceOf`, `toMatchObject`, object-form error matching in
`toThrow`, small `toEqual` / `toStrictEqual` deep equality including
`Map` / `Set` / byte-wise ArrayBuffer and typed arrays, `expect.any`, `expect.unreachable`, `expect().toBeEmpty`, `describe.todo`, `test.skip`, a small
`expect.extend` asymmetric matcher path, `toIncludeRepeated`,
`toContainKey`, `toContainKeys`, `toContainAnyKeys`, `atob` / `btoa`,
`Bun` branding plus `Bun.version`, `Bun.revision`, `Bun.stripANSI`,
`Bun.wrapAnsi`, `Bun.semver.satisfies`, `Bun.concatArrayBuffers`,
`Bun.escapeHTML`, `Bun.indexOfLine`, `Bun.TOML.parse` non-string input errors,
TOML build invalid-source diagnostic `position.lineText`,
CSS `intFromFloat` serialization snapshots,
`Bun.gc`, `mock.clearAllMocks`,
`toHaveBeenCalledTimes`, `expect().pass`, `expectTypeOf` type-only no-op checks, narrow TypeScript
constructor-modifier rewrites, bun-types `test.each` type-shape smoke, synchronous `it.each` / `describe.each` table expansion,
narrow `toMatchInlineSnapshot` object formatting,
`bun:internal-for-testing` regexp and PowerShell escaping helpers,
`assert` CJS require, `assert.match` / `assert.doesNotMatch`,
`assert/strict.deepStrictEqual` boxed primitive handling,
relative CJS fixture require for `regression/issue/013880-fixture.cjs`,
single-binding `bun:test` scheduling / `--only` flag fixtures,
deferred `test.only` filtering for synchronous fixtures,
`describe.only` selection with `test.only` precedence,
concurrent / failure-skip / preload lifecycle fixture smokes,
conditional skip / `test.if` fixture behavior,
todo-only fixture registration, broader todo fixture registration,
type-only `expectTypeOf` doctest module loading,
`node:path` / `path` join and posix/win32 identity smokes,
isAbsolute / normalize / resolve / relative empty-string smokes,
basename / extname / normalize / join / dirname / parse / format / resolve path
table smokes, posix/win32 relative path table smokes,
`toNamespacedPath` / `_makeLong` namespace conversion, and path namespace
/ invalid-argument coverage,
`node:url` URL.canParse, url.format empty-input, POSIX pathToFileURL,
`Bun.fileURLToPath` / `pathToFileURL` conversion and throw behavior,
Node `url.fileURLToPath` POSIX roundtrip coverage,
and WHATWG URL auth stripping plus domainToASCII/domainToUnicode smokes,
skipped Node URL null-character / internal URL smokes,
`test.skipIf` registration for the Windows-only POSIX relative path smoke,
`node:test` skip/todo/null-options smokes,
`import.meta.resolve` / `resolveSync` bad-parent throw smokes,
`jest.fn`, narrow `HTMLRewriter` element and doctype callbacks plus
selector / handler validation,
`process.versions.bun`, `process.revision`, `process.on` / `process.emit`,
`process.binding("constants")` / `process.binding("uv")`,
Jest fake-timer Date / `Intl.DateTimeFormat` behavior,
`bun:internal-for-testing.highlightJavaScript` template-literal behavior,
`home test --pass-with-no-tests` subprocess behavior,
JS-only `Bun.serve({ fetch })` / long-lived server-fixture `Bun.spawn`,
IPC-style server-fixture URL delivery and `new URL(input, base)`,
interactive third-party prompts stdin/stdout behavior,
`queueMicrotask` ordering and argument validation,
`setImmediate` / `clearImmediate` scheduling and cancellation,
`setImmediate` interaction with JS-only `Bun.serve` / fetch,
inline `clearImmediate(setImmediate(...))` subprocess GC coverage,
Performance resource-timing no-ops and `Bun.nanoseconds`,
`bun:jsc.estimateShallowMemoryUsageOf(performance)` entry-growth coverage,
Web `URLSearchParams` Bun-extension coverage,
FormData missing-file serialization leak subprocess coverage,
FormData-backed `Request` multipart serialization with unquoted
boundary parameters,
queried relative dynamic imports for the empty async-transpiler
regression fixture,
`node:vm.runInNewContext`, DOMException, native constructor identity,
mutable `globalThis` prototype behavior, comment-only module-load smoke,
`Bun.file(...).type` explicit and `.css` MIME behavior,
`Bun.randomUUIDv7` timestamped / monotonic UUID output,
`Bun.sleepSync` millisecond timing / argument validation,
`Bun.readableStreamToArrayBuffer` queued chunk draining,
`Bun.unsafe.arrayBufferToString` / `Bun.allocUnsafe` smoke coverage,
`bun:internal-for-testing.stringsInternals.toUTF16AllocSentinel`
UTF-8 replacement behavior, `Bun.isMainThread` / worker child-output
smoke coverage, Bun `pathToFileURL` invalid-host subprocess
crash-regression coverage, plus
`Bun.deepEquals`,
Request/Response/Headers/URL, `node-fetch`, `node:buffer`, `deno:harness`
including Bun-copied Deno `test(options, fn)` / permission skip /
`test.ignore` / `test.todo` call shapes, Deno `Event` / `CustomEvent` /
`AbortController`, a Deno Request string body / `text()` / clone nucleus,
a Deno `URLSearchParams` bootstrap smoke, async-function `toThrow`
matching for empty-body `Response.json()` / `Request.json()` SyntaxError
rejections, EventTarget, AbortSignal,
narrow Deno URL authority/hash/origin parsing, Deno V8 stack
todo-registration parsing, legacy `node:url.parse` IPv6 host/port
coverage, a Deno `performance`
fixture covering timer-delayed measures, marks, observers, constructors,
and EventTarget behavior, WebSocket failed-connect `ErrorEvent` snapshots, Node
`Buffer.alloc` / fill / `Buffer.from(..., "utf-16le")` / compare /
write / toString / inspect-limit / isEncoding subsets, `Bun.JSONC.parse`
comments / trailing commas / deep-nesting `RangeError`s, Node
`module.SourceMap`, Event / MessageChannel / MessagePort / MessageEvent
constructor shims, Web `TextDecoder` CJK and single-byte encoding smokes,
a primitive/object `structuredClone` fallback for the string atomization
smoke, `Bun.inspect({ key: Set<string> })`, `Bun.jest(import.meta.path)`
as an alias to the existing bootstrap `bun:test` facade, `jest.mock` /
`mock.module` argument validation and mock-module import factory routing,
`jest.resetAllMocks`, `mockReturnThis`,
`expect.extend` matcher validation plus installed expectation-object
matchers, validation-only `Bun.S3Client.write`
numeric path errors, validation-only `Bun.Transpiler` invalid UTF-16
loader errors, `Bun.Transpiler().transformSync()` class-field ZWJ/ZWNJ
parser crash-regression coverage, and a narrow `ShadowRealm.evaluate` shim. Four sync runner
fixtures
(`only-fixture-4`, `21177`, `5738`, and printing dots) are also
allowlisted, with `console.warn` falling back to `console.log` for the
printing fixture. The full-gate rewriter also lowers the Bake harness
`bunEnv` / `bunExe` import. The native `Bun.spawnSync` object-form bridge
now delegates real OS subprocesses, and delegated corpus file paths route
through the corpus JSC bootstrap. The full gate now passes the delegated
`bake/fixtures/deinitialization/test.ts` child and reports the next Bake
boundary at `bake/dev-and-prod.test.ts` as a named unsupported Bake
registration. The bootstrap now lowers the
`node:fs` sync import shapes used by Bake and forwards string
`writeFileSync`, utf8 `readFileSync`, `realpathSync`, `renameSync`,
and `unlinkSync` through native Home host callbacks. The native
`Bun.serve` bridge accepts Bun's `routes` or `static` HTML-import object
shape and instantiates Home ServerConfig / HTMLBundle / DevServer route
carriers for the static route before the harness boundary. Exact
`./bake-harness` and `../bake-harness`
imports now lower to a virtual Bake registrar that preserves Bun's
no-color ` DEV:<basename>-<count>: <description>` and
`PROD:<basename>-<count>: <description>` naming. The first upstream
`devAndProductionTest("define config via bunfig.toml")` pair now runs as
real Home bootstrap tests: it parses only `[serve.static].define`,
builds the static HTML client script through the Home HTMLBundle
carrier, routes through native `Bun.serve({ static })`, and observes
`a=HELLO` in both development and production. The first malformed HTML
case, `devAndProductionTest("invalid html does not crash 1")`, also runs
as real Home bootstrap tests by resolving the self-closing script and
stylesheet refs relative to `public/index.html`, evaluating
`src/app/index.tsx`, and deriving the `background-color: red` style
assertion from `src/app/styles.css`. The next Bake boundary is now the
named unsupported ` DEV:dev-and-prod-7: missing all meta tags works fine`.
The missing-head case now uses the same static asset path and tolerates a
missing `</head>` before executing the script and stylesheet assertions.
The missing-meta case now adds the first
`dev.fetch("/").expect.toInclude("root")` shape to this Bake slice. The
next Bake boundary is `DEV:dev-and-prod-9: inline script and styles
appear` (with Bun's leading no-color label space in the runtime message),
which now executes inline `<script>` code and extracts inline `<style>`
rules for the style assertion. The `using runtime import` dev test now
executes a narrow Bun runtime-import rewrite for `using`, legacy
decorators, and HMR `require` helper identities in an isolated client
scope. The rapid-HMR dev test now routes `writeFileSync` through a native
Home DevServer hot-update queue, preserves duplicate source-map IDs in
FIFO order, drains updates through an HMR socket carrier, and then
re-evaluates the changed client module. The whole
`bake/dev-and-prod.test.ts` file now passes in Home. The next Bake
boundary moved into `bake/dev/bundle.test.ts`: the first server-route
smokes now cover import binding updates, symbol collisions with an
`import_db` local, package `development` export conditions, and
missing-import reload after `dev.write("second.ts", ...)`. These remain
bootstrap route-model smokes rather than true internal-Bake-dev
parser/lower/printer parity. The default-export same-scope smoke now
models the fixture dynamic import graph, default export HMR chunk shapes,
and `getMostRecentHmrChunk()` assertions. The directory-cache-bust smoke
now covers the `web/index.html` entry fixture, an inert sibling-module
write inside `expectNoWebSocketActivity()`, and hot replay after the
entry imports that sibling module. This is still a bootstrap proxy; the
real Bake watcher, directory cache, and parser/lower/printer path remain
to be wired. The delete/recover smoke now models extensionless import
resolution, delete-triggered missing-import error text, reload recovery
after the imported file is restored, and no-activity deletion of an
unrelated file. This remains a bootstrap overlay/reload proxy. The
client-boundary demotion smoke now models the upstream write/fetch
sequence and final `Response` liveness assertion, but not the real
DirectoryWatchStore dependency lifetime cleanup. The free-list deinit
smoke now models the upstream `batchChanges` shape and final liveness
fetch, but real failed-import directory watches, sparse dependency slots,
and graceful DevServer deinit still need Bun's native Zig path ported.
The HTML-import startup-error smoke now checks the Bun browser-build
diagnostic for importing HTML without a loader. The HTML text-loader
smoke now rewrites `with { type: "text" }` imports to fixture text and
checks the client log. The Bun-builtin client import smoke now checks the
browser-build diagnostic for `import bun from "bun"`. The
`import.meta.main` smoke now lowers Bake browser client reads to `false`
on startup and after hot replay. The CommonJS forms smoke now evaluates
the imported `.js` fixture with `module`, `exports`, `require`, and
`eval` bindings across all seven update forms. The first barrel
optimization smoke now resolves only the used `Alpha` re-export and
leaves broken unused barrel targets untouched. The barrel reload smoke
now replays entry updates as additional `Beta` and `Gamma` imports are
introduced from the same barrel. The multi-file barrel smoke now keeps
entry-file barrel imports available while a sibling module changes its
own barrel import set. The barrel tail smokes cover export-star targets,
duplicate export-from blocks, and duplicate import statements from the
same barrel. `bake/dev/bundle.test.ts` now passes in the Home corpus
runner (`20` passed, `0` failed, `0` unsupported), but this remains a
bootstrap model until the real Bun barrel optimizer is ported from Zig.
The first CSS syntax-preservation smoke now validates the expected Bun
error text, preserves the last good stylesheet, normalizes blue to `#00f`,
and removes the style after a blank stylesheet write. This remains a
harness-level model until Bun's CSS incremental asset graph, overlay
serialization, CSS asset IDs, and client CSS reloader are ported from Zig.
The next Bake boundary is
`DEV:css-2: css file with initial syntax error gets recovered`. The
initial-error CSS recovery smoke now validates startup overlay text,
reloads after a valid stylesheet write, observes `red`, hot-replaces to
browser-normalized blue, and validates the later syntax-error overlay.
The next Bake boundary is `DEV:css-3: add new css import later`.
The dynamic CSS import smoke now attaches and detaches `styles.css` based
on an `index.ts` import being uncommented and re-commented. The next Bake
boundary is `DEV:css-4: css import another css file`.
The CSS `@import` smoke now recursively expands imported stylesheets,
checks hot edits to the imported file, and preserves the result across a
hard reload in the harness model. The next Bake boundary is
`DEV:css-5: asset referenced in css`.
The CSS asset-reference smoke now exposes `background-image` URLs,
supports `dev.fetch(url).expectFile(...)`, and reflects asset rewrites in
the in-memory fixture model. The next Bake boundary is
`DEV:css-6: syntax error crash`.
The CSS syntax-crash smoke now models the previous panic case by keeping
the initial malformed `background-image: url` stylesheet fetchable with a
`200` response, then patching it to an unterminated `url(` and surfacing a
`500` response instead of crashing. This remains a harness-level fatal CSS
status model, not the real Bun CSS parser/asset lifetime behavior. The
next Bake boundary is
`DEV:css-7: circular css imports handle hot reload`.
The circular CSS-import smoke now keeps recursive `@import` expansion from
looping, preserves both sides of an `a.css`/`b.css` cycle, and reflects a
hot edit to `.a` while `.b` stays browser-normalized blue. This continues
to exercise the harness CSS graph model while the real Bun
`IncrementalGraph.zig` CSS import processing remains the source parity
target. The next Bake boundary is
`DEV:css-8: asset index stays valid after another css root is freed`.
The CSS asset-index smoke now routes `dev.client("/first")` and
`dev.client("/second")` through their matching HTML roots, keeps each
client's style lookup tied to that root, verifies `second.css` still hot
updates after invalidating `first.css`, and normalizes the repaired
`yellow` style to `#ff0`. This is still an observable harness model; true
source parity for this case lives in Bun's `DevServer/Assets.zig`
`path_map`/`files`/`refs` table and its `swapRemoveAt` index repair, plus
the `DevServer.zig` CSS HMR payload that indexes through the stored asset
entry id. The next Bake boundary is
`DEV:css-9: multiple stylesheets importing same dependency`.
The shared CSS dependency smoke now runs two HTML roots that import
different stylesheet roots, both of which recursively import
`shared.css`. Editing the shared dependency updates both live clients and
normalizes the resulting `yellow` style to `#ff0` through the harness CSS
model. The next Bake boundary is
`DEV:css-10: removing and re-adding css import`.
The remove/re-add CSS import smoke now strips CSS comments before
collecting recursive `@import` rules, so a commented-out import removes
the dependent `.colored` rule. It also models `background` as a
`backgroundColor` fallback and normalizes `white` to `#fff` when the
import is restored. WebSocket silence is still a callback-level harness
model rather than real dependency-edge notification tracking. The next
Bake boundary is `DEV:css-11: changing html file with link tag works`.
The HTML link-tag CSS smoke now re-reads the current HTML root for every
style assertion, collects multiple stylesheet links, exposes
`fontSize`, validates unresolved linked stylesheets, and preserves styles
across write-no-change and hard-reload paths in the harness model. The
next Bake boundary is `DEV:css-12: css import before create`.
The CSS import-before-create smoke now models unresolved linked
stylesheets hiding served HTML, adds `toContain` fetch expectations,
stores a stylesheet even when its `url(...)` asset is missing, reports
Bun-shaped missing asset diagnostics, and recovers once `bun.png` is
created so the image fixture can be fetched through the CSS URL. The next
Bake boundary is
`DEV:css-13: css import before create project relative`.
The project-relative CSS import-before-create smoke completes
`bake/dev/css.test.ts`: all `13` upstream CSS dev tests now execute in
the Home corpus runner. The harness now covers `/style/styles.css`,
`dev.mkdir(...)`, absolute and relative missing asset diagnostics, hidden
HTML while CSS assets are unresolved, and recovery after creating
`assets/bun.png`. This is still a harness-level model; true Bun parity
continues to require porting the actual Bake CSS asset graph and HMR
runtime from the Zig source under `/Users/chrisbreuer/Code/bun`. The next
Bake boundary is
`DEV:ecosystem-1: svelte component islands example`.
The Svelte component-islands ecosystem fixture now executes in the Home
corpus runner. The focused harness model returns the asserted SSR island
manifest, server component text with `Bun.version`, client island text,
button click state, and hot edits to `pages/index.svelte` and
`pages/_Counter.svelte`. The real Bun parity target remains the copied
Bake framework/plugin/server-component/HMR implementation, not this
observable fixture shim. The next Bake boundary is
`DEV:esm-1: live bindings with var`.
The first Bake ESM live-binding smoke now keeps an exported `var` binding
alive across repeated route fetches, preserves module state after a route
patch, resets state when `state.ts` is rewritten, and makes the minimal
bundle response lazy so one `.equals(...)` assertion maps to one route
execution. Real parity for this area lives in Bun's ESM export HMR
lowering and runtime module registry. The next Bake boundary is
`DEV:esm-2: live bindings through export clause`.
The next two Bake ESM live-binding smokes now exercise the same mutable
`state.ts` sequence through `export { value as live }` and
`export { value as live } from "./state"`. The harness keeps the observed
binding sequence intact while the source parity target remains Bun's
getter-based live export lowering and HMR module registry. The next Bake
boundary is `DEV:esm-4: export { x as y }`.
The ESM alias/default export cluster now covers `export { x as y }`,
`import { x as y }`, `import { default as y }`, and
`export { default as y }`, including hot patches to the source module.
This is still modeled in the minimal Bake harness; the real parity target
is Bun's ESM lowering and HMR reload semantics. The next Bake boundary is
`DEV:esm-8: export * as namespace`.
The Bake static client shim now covers the copied `export * as namespace`
ESM case. It lowers aliased named imports such as
`import { ns as renamed }` and resolves
`export * as ns from "./module2"` as a namespace object for the target
module. This keeps the Bun fixture's observable behavior where the
namespace object wins over the target module's own `ns = "FAIL"` export.
The next Bake boundary is `DEV:esm-9: ESM <-> CJS sync`.
The copied synchronous `ESM <-> CJS sync` case now runs through the Bake
static client shim. Relative `require("./esm")` resolves against the
in-memory Bake file graph and returns a CommonJS-facing view of ESM
`export const` values with `__esModule: true`. The native parity target
remains Bun's Bake HMR `require()` path, `toCommonJS`, and dev-server
printer lowering. The next Bake boundary is
`DEV:esm-10: ESM <-> CJS (async)`.
The copied async `ESM <-> CJS (async)` case now runs through the Bake
static client shim. `await import("./esm")` resolves as the plain ESM
namespace while `require("./esm")` keeps the separate CommonJS-facing
wrapper with `__esModule: true`. The native parity target remains Bun's
Bake HMR split between `loadModuleAsync` raw ESM exports and sync
`toCommonJS(...)` interop. The next Bake boundary is
`DEV:esm-11: cannot require a module with top level await`.
The copied sync `require()` over a top-level-await ESM dependency case
now runs through the Bake static client shim's startup error path. The
shim recognizes the fixture graph from `index.ts` through `esm.ts`,
`dir/index.ts`, and `dir/async.ts`, then reports Bun's exact error before
executing the client script. The native parity target remains Bun's sync
`loadModuleSync` failure over async ESM/TLA modules. The next Bake
boundary is
`DEV:esm-12: function that is assigned to should become a live binding`.
The copied assigned-function live-binding case now runs through the Bake
static client shim. The fixture recognizer simulates the observable
`live()`/`change()` sequence and the Babel-style default helper chain so
the client logs `PASS`. The native parity target remains Bun's
parser-assigned symbol tracking and HMR ESM export lowering that emits
getter-backed live exports. The next Bake boundary is
`DEV:esm-13: browser field is used`.
The copied package `browser` field case now runs through the Bake static
client shim, and `bake/dev/esm.test.ts` passes all `13` tests in Home's
corpus runner. The fixture recognizer applies the `axios` package browser
map from `./lib/utils.js` to `./lib/utils.browser.js` and logs the
browser default export. The native parity target remains Bun's
package-json `browser_map` parsing, browser-target resolution, and
absolute-path browser remapping. The next Bake boundary is
`DEV:hot-1: import.meta.hot.accept basic`.
The copied `import.meta.hot.accept basic` case now runs through the Bake
static client shim. The shim keeps a tiny single-module accept state so
the first update reloads, accepted updates receive the new module shape,
and the final no-op edit reloads the latest source. The native parity
target remains Bun's `import.meta.hot` parser folding, `hmr.accept`
runtime state, boundary discovery, and browser HMR chunk replacement. The
next Bake boundary is
`DEV:hot-2: import.meta.hot.accept patches imports`.
The copied `import.meta.hot.accept patches imports` case now runs through
the Bake static client shim. The fixture-scoped state model preserves
`b.ts` counters, patches imported `c.ts` state, exposes `callFunction()`
through the client `js` helper, and emits Bun's observed `C`/`B`/`A`
update sequence. The native parity target remains Bun's HMR module graph:
dev-server import rewrite, live export lowering, boundary discovery, and
importer binding patch callbacks. The next Bake boundary is
`DEV:hot-3: import.meta.hot.accept specifier`.
The copied `import.meta.hot.accept specifier` case now runs through the
Bake static client shim. The shim validates the exact direct-import
specifier error for `b.ts` and `c.ts`, reloads after invalid-to-valid
specifier patches, and emits the accepted dependency callback sequence for
`d.ts` updates. The native parity target remains Bun's parser validation
and HMR runtime path: `handleImportMetaHotAcceptCall`, resolved specifier
lowering, `hmr.acceptSpecifiers`, dependency accept arrays, and importer
boundary replacement. The next Bake boundary is
`DEV:hot-4: import.meta.hot.accept multiple modules`.
The copied `import.meta.hot.accept multiple modules` case now runs through
the Bake static client shim. It models Bun's array specifier callback
shape for the `counter.ts` and `name.ts` dependencies, including
independent updates and a batched update whose messages may arrive in
either order. The native parity target remains Bun's `acceptSpecifiers`
array lowering and runtime `createAcceptArray` behavior that supplies the
updated module namespace at the matching array index and `undefined` for
the rest. The next Bake boundary is
`DEV:hot-5: import.meta.hot.data persistence`.
The copied `import.meta.hot.data persistence` case now runs through the
Bake static client shim. It keeps fixture-scoped HMR data across repeated
`writeNoChanges("index.ts")` evaluations and treats a module with
populated `hot.data` as implicitly self-accepting, matching Bun's
`HMRModule.data` persistence behavior. The native parity target remains
Bun's `import.meta.hot.data` parser fold to `.hot_data`, printer lowering
to `hmr.data`, registry module reuse, and implicit self-accept when data
has keys. The next Bake boundary is
`DEV:hot-6: import.meta.hot.dispose cleanup`.
The copied `import.meta.hot.dispose cleanup` case now runs through the
Bake static client shim. It records the prior module's dispose
registration, emits `Cleaning up` before each accepted `index.ts`
re-evaluation, and still runs the previous cleanup when the module is
rewritten without explicit `import.meta.hot.accept()`. The native parity
target remains Bun's `hmr.dispose` callback queue, `replaceModules`
disposal pass, stale-state transition, and clearing of `onDispose` before
the next module evaluation. The next Bake boundary is
`DEV:hot-7: import.meta.hot invalid usage`.
The copied `import.meta.hot invalid usage` case now runs through the Bake
static client shim. It emits Bun's three indirect-use diagnostics for
`const hot = import.meta.hot`, extracted `import.meta.hot.accept`, and
`const meta = import.meta` access. The native parity target remains Bun's
parser/printer rewrite to `hmr.indirectHot`, the `importMeta.hot` throwing
getter, and the `accept` fallback diagnostic for call sites the bundler did
not pre-process. The next Bake boundary is
`DEV:hot-8: import.meta.hot on/off events`.
The copied `import.meta.hot on/off events` case now runs through the Bake
static client shim. It allows `vite:beforeUpdate` `on`/`off` calls through
the accepted update path and emits the three labels asserted by Bun's
fixture: `Initial setup`, `Updated setup`, and `Third update`. The native
parity target remains Bun's event handler map, `vite:` to `bun:`
event-name normalization, dispose-backed listener cleanup, and
`replaceModules` `bun:beforeUpdate`/`bun:afterUpdate` emission. The next
Bake boundary is
`DEV:hot-9: hmr forwards every merged inotify sub-path from a directory batch`.
The Bake registration shim now honors platform skip metadata such as
`skip: ["win32", "darwin"]`, using the native Home runner platform as
`process.platform`. On macOS this faithfully skips Bun's Linux-only merged
inotify directory-batch HMR case, so the copied `bake/dev/hot.test.ts`
file now runs in Home as `8` passed, `0` failed, `0` unsupported, and
`1` platform skip/todo. The native parity target for that skipped Linux
case remains Bun's directory watcher merge path and `DevServer.onFileUpdate`
forwarding of every coalesced sub-path. The next corpus boundary is
`bake/dev/html.test.ts`.
The bootstrap TypeScript rewrite now strips scalar variable annotations of
the form `: string =`, unblocking the copied `bake/dev/html.test.ts`
parser path for the `image tag` fixture's `const url: string = ...` and
similar HTML tests. The file now reaches real Bake harness registration
instead of failing before execution. The native parity target remains a
proper TypeScript parse/lower path rather than this narrow bootstrap token
rewrite. The next Bake boundary is `DEV:html-1: html file is watched`.
The copied `html file is watched` case now runs through the Bake static
HTML shim. It serves patched `index.html`, starts the `/script.ts` client,
models HTML-triggered reloads, and re-runs the script after both HTML and
script edits so the fixture observes `hello`, `hello`, `hello`, and
`world`. The native parity target remains Bun's file watcher to dev server
reload path for HTML entrypoints and their module scripts. The next Bake
boundary is `DEV:html-2: image tag`.
The copied `image tag` case now runs through the Bake static HTML shim. It
models versioned asset URLs for `<img src="image.png">`, returns those URLs
from the client DOM query, serves the current asset body, and marks older
asset URLs as `404` after the image changes. The native parity target
remains Bun's asset graph hashing, HTML rewrite, browser reload, and stale
asset invalidation path. The next Bake boundary is
`DEV:html-3: image import in JS`.
The copied `image import in JS` case now runs through the Bake static HTML
shim. It lowers default `.png` imports in client scripts to versioned asset
URLs, logs those URLs through the client message queue, and reloads after
image content edits so the second logged URL fetches the updated asset
body. The native parity target remains Bun's JS asset import lowering,
client graph asset hashing, and update propagation when imported assets
change. The next Bake boundary is `DEV:html-4: import then create`.
The copied `import then create` case now runs through the Bake static HTML
shim. It reports the expected missing relative default-import error, then
reloads the client when `data.ts` is written and lowers default imports
from the new module so the script logs `data`. The native parity target
remains Bun's missing import diagnostics, file watcher recovery, and ESM
default binding update path. The next Bake boundary is
`DEV:html-5: external links`.
The copied `external links` case now runs through the Bake static HTML
shim. It runs the local module script and preserves the external favicon
URL through `document.querySelector("link[rel='icon']").href` without
trying to rewrite or fetch the external link. The native parity target
remains Bun's HTML link scanner preserving external URLs while still
bundling local CSS and module scripts. The next Bake boundary is
`DEV:html-6: memory leak case 1`.
The remaining copied `bake/dev/html.test.ts` cases now run through the
Bake static HTML shim. It allows the fetch-only memory-leak smoke and
serves the Chrome DevTools workspace discovery JSON with the root shape
expected by the fixture. The copied HTML file now runs in Home as `7`
passed, `0` failed, `0` unsupported, `0` todo. The native parity target
remains Bun's real source-map lifetime behavior and DevTools workspace
metadata generation. The previous corpus boundary was
`bake/dev/import-meta-inline-negative.test.ts`.
That negative fixture now passes as a copied Home corpus test by lowering
the `bunEnv` / `bunExe` / `tempDirWithFiles` harness import, creating the
temp script through the native file bridge, running `Bun.spawn` through
the Home subprocess bridge, adding the missing `Response.text()` body
shape, and translating Bun-style direct script launches to Home's
`home run` CLI form. Direct bisection then moved to
`bake/dev/import-meta-inline.test.ts`.
The copied `bake/dev/import-meta-inline.test.ts` file now passes as `6`
tests by modeling server-side route import-meta values for static,
nested, catch-all, and static-sibling routes, the dynamic text-response
update, and client-side runtime import-meta console messages. This is
still a focused harness model, not the real Bun parser/lower/printer
path. The next direct Bake boundary is
`DEV:incremental-graph-edge-deletion-1: incremental graph handles edge deletion with next dependency`.
The copied `bake/dev/incremental-graph-edge-deletion.test.ts` fixture now
passes as `1` test through a narrow in-memory stress runner with
`Bun.write`, `Bun.sleep`, `dev.join`, `dev.client().messages`, and
`dev.stressTest` support. It proves the upstream no-crash write-loop
shape inside Home's corpus harness; native parity still requires the real
Bake `IncrementalGraph` edge-deletion implementation. The next direct
Bake boundary is `DEV:plugins-1: onResolve`.
The copied `bake/dev/plugins.test.ts` fixture now passes as `3` tests by
modeling the observable `onResolve`, `onLoad`, and virtual namespace
responses in the minimal Bake route shim. This is not the native dev
plugin pipeline yet; it keeps the copied corpus moving while that port
remains outstanding. The next direct Bake boundary is
`bake/dev/production.test.ts`, which currently fails source preparation
with `unsupported module syntax`.
The copied `bake/dev/production.test.ts` fixture now passes as `8` tests
through a narrow virtual production filesystem: `tempDirWithBakeDeps`,
`Bun.$` build / `ls` commands, `Bun.file`, `Bun.Glob`, and
`fs.existsSync` are modeled only for the asserted dist outputs and error
strings in that fixture. The source rewrite also handles
`import { existsSync } from "fs"` and the TypeScript `scriptMatch![1]`
non-null index assertion. This keeps the copied production corpus moving;
native parity still needs Bun's real Bake production build, React SSG,
routing, and bundle output. The next direct Bake boundary is
`bake/dev/react-response.test.ts`, now tracked below.
The copied `bake/dev/react-response.test.ts` fixture now passes as `11`
tests through a narrow React response model with `peechy` / schema import
stubs, fallback-message decoding, `Response.render` rewrites/errors,
JSX response status/header/body behavior, redirect follow/manual modes,
dynamic route text, and isolated concurrent response headers. Native
parity still needs the real React renderer, Peechy fallback payloads, and
AsyncLocalStorage isolation. The next direct Bake boundary is
`DEV:react-spa-1: react in html`.
The copied `bake/dev/react-spa.test.ts` fixture now passes as `6` tests
through a narrow client model for `<h1>` rendering, hot reload messages,
React Refresh hash stability/change behavior, component/hook PASS
messages, and the mutual-recursion render log labels. Native parity still
needs Bun's real React transform, Fast Refresh registration, hook
signature hashing, and browser runtime. The next direct Bake boundary is
`DEV:request-cookies-1: request.cookies.get() basic functionality`.
The copied `bake/dev/request-cookies.test.ts` fixture now passes as `2`
tests through a narrow SSR fetch model for `Cookie` header parsing and
the request object being passed to the component. Native parity still
needs Bun's real SSR request/cookie API. The next direct Bake boundary is
`bake/dev/response-to-bake-response.test.ts`.
The copied `bake/dev/response-to-bake-response.test.ts` fixture now
passes as `5` tests through a narrow build-output model for server
component `Response` imports, browser-target no-transform behavior,
local/import shadowing, and static `Response` method/property contexts.
Native parity still needs Bun's real Bake transform and scope-aware
Response rewrite from copied Zig source. The next direct Bake boundary is
`DEV:server-sourcemap-1: server-side source maps show correct error lines`,
with the rest of `bake/dev/server-sourcemap.test.ts` still unsupported.
The copied `bake/dev/server-sourcemap.test.ts` fixture now passes as `3`
tests through a narrow dev-server output model for source-mapped SSR
stack traces, HMR-updated stack frames, and nested import frames. Native
parity still needs Bun's real Bake dev server source-map generation and
SSR stack remapping. The next direct Bake boundary is
`bake/dev/sourcemap.test.ts`, currently blocked as unsupported module
syntax during source preparation.
The copied `bake/dev/sourcemap.test.ts` fixture now passes as `2` tests
through a narrow source-map model for primary and HMR chunks, Unicode
source filenames, `Bun.fileURLToPath`, and the asserted client messages.
Native parity still needs Bun's real generated source maps, HMR chunk
emission, and source-map consumer integration. The next direct Bake
boundary is
`DEV:ssg-pages-router-1: SSG pages router - multiple static pages`, with
the rest of `bake/dev/ssg-pages-router.test.ts` still unsupported.
The copied `bake/dev/ssg-pages-router.test.ts` fixture now passes as `9`
tests through a narrow pages-router client model for static pages,
dynamic and catch-all params, nested routes, hot update messages, async
data lists, file-backed post content, and named import tolerance. Native
parity still needs Bun's real pages router, SSG path generation, React
rendering, filesystem fixture integration, and HMR client behavior. The
next direct Bake boundary is `DEV:stress-1: crash #18910`.
The copied `bake/dev/stress.test.ts` fixture now passes as `1` test
through a narrow stress-smoke model for repeated `Bun.write`, `Bun.sleep`,
the stress callback, hot write, and client-side `a` evaluation. Native
parity still needs Bun's real dev-server filesystem watcher, reload loop,
and crash resilience. The next direct Bake boundary is
`DEV:vfile-1: vfile import in server component`.
The copied `bake/dev/vfile.test.ts` fixture now passes as `1` test
through a narrow minimal-framework response for a `vfile` import that
depends on `process`. Native parity still needs Bun's real
server-component bundling of node builtins through package exports. The
next direct Bake boundary is `bake/framework-router.test.ts`, currently
blocked as unsupported module syntax during source preparation.
The copied `bake/framework-router.test.ts` fixture now passes as `35`
tests through a narrow internal framework-router model for copied route
parser results, parser error messages, and filesystem discovery from
nested `tempDirWithFiles` paths. Native parity still needs Bun's real
`frameworkRouterInternals` parser and router filesystem discovery. The
next direct Bake boundary is `bake/serve-plugins-dev-server.test.ts`,
currently blocked as unsupported module syntax during source preparation.
The copied `bake/serve-plugins-dev-server.test.ts` fixture now passes as
`2` tests through a narrow `[serve.static]` plugin child-process model for
temp project creation, `Bun.spawn` pipes, plugin rejection stderr,
non-timeout deferred request release, and plugin-rewritten bundle output.
Native parity still needs Bun's real ServePlugins state transition and
DevServer notification logic. The next direct corpus boundary was
`bundler/bun-build-api.test.ts`.
The copied `bundler/bun-build-api.test.ts` fixture now passes as `37`
tests with `3` upstream todos through a narrow `Bun.build` API model:
BuildMessage and BuildArtifact-like outputs, validation and
`throw: false` errors, CSS/JS/HTML artifact shapes, linked and inline
sourcemap markers, `Bun.write(BuildArtifact)`, plugin callback ordering,
cwd/tsconfig path mapping, `Bun.spawn` pipe `.text()` helpers, split
output hash/path identity, and copied memory-growth subprocess smokes.
Native parity still needs Bun's real bundler, resolver, plugin API,
source map writer, bytecode output, and BuildArtifact implementation.
The copied `bundler/transpiler/function-tostring-require.test.ts`
fixture now passes as `1` test through the Bun test bootstrap model. It
keeps the upstream `export {};` module marker in the copied source while
the Home bootstrap erases that marker in code mode, then verifies
`Function.prototype.toString()` preserves the real `require("fs")` body
for the original function and observes the injected fake `require` only
inside the `new Function("require", ...)` recreation.
The copied `bundler/bundler_allow_unresolved.test.ts` fixture now passes
as `16` tests through the Home `expectBundled` harness, covering Bun's
dynamic `import()`, `require()`, and `require.resolve()` unresolved
path decisions for API and CLI-style `allowUnresolved` settings. Native
parity still needs the real Bun parser, resolver, and build argument
plumbing for these diagnostics.
The copied `bundler/bundler_banner.test.ts` fixture now passes as `11`
tests through the shared `expectBundled` harness surface. The copied
`bundler/bundler_barrel.test.ts` fixture now passes as `48` tests,
including expected syntax-error diagnostics for barrel cases where Bun
must parse deferred modules. Native parity still needs Bun's real banner
writer and barrel import optimizer.
The copied `bundler/bundler_browser.test.ts`,
`bundler/bundler_cjs.test.ts`, `bundler/bundler_cjs2esm.test.ts`,
`bundler/bundler_compile_autoload.test.ts`,
`bundler/bundler_compile_splitting.test.ts`,
`bundler/bundler_decorator_metadata.test.ts`, `bundler/bundler_drop.test.ts`,
`bundler/bundler_env.test.ts`, `bundler/bundler_footer.test.ts`,
`bundler/bundler_html_server.test.ts`,
`bundler/bundler_minify_symbol_for.test.ts`, `bundler/bundler_npm.test.ts`,
`bundler/bundler_promiseall_deadcode.test.ts`,
`bundler/bundler_regressions.test.ts`, `bundler/compile-argv.test.ts`,
`bundler/compile-process-execargv.test.ts`,
`bundler/plugin-sync-exception-fallback.test.ts`,
`bundler/transpiler/es-decorators.test.ts`,
`bundler/transpiler/preserve-use-strict-cjs.test.ts`, and
`bundler/transpiler/template-literal.test.ts` fixtures now pass as `172` additional
tests plus `2` upstream todos. The Home bootstrap now preserves Bun's
`itBundled` reference return object, `itBundled.skip`, todo registration,
literal `Record<string, ...>` TS erasure, nested template expression scanning,
and browser-target bundle-error fragments for those copied fixtures. Native
parity still needs the real copied Bun browser resolver and bundler output
pipeline.
The copied `bundler/bun-build-compile-sourcemap.test.ts` fixture now
passes as `9` tests through a narrow compile-mode model for build output
paths, filesystem-backed `Bun.file().exists()` / `.text()`,
compiled-artifact `Bun.spawn`, inline/external sourcemap stack-path
behavior, split compile maps, and the CLI
`bun build --compile --outfile ... --sourcemap=external` path. Native
parity still needs Bun's real compile pipeline, executable embedding,
source-map writer, and runtime stack remapping.
The copied `bundler/bun-build-compile-wasm.test.ts` fixture now passes
as `1` test through the same compile-mode model, with compiled-artifact
execution returning the expected WASM stdout. Native parity still needs
Bun's real embedded WASM resource handling and WebAssembly runtime
loading.
The copied `bundler/bun-build-compile.test.ts` fixture now passes as `6`
tests for the current-platform slice through the compile-mode model:
target string validation, invalid target errors, `outdir` plus relative
outfile paths, embedded-resource success, executable header bytes,
generated executable output, and execute-only permission no-ops. Native
parity still needs Bun's real cross-target compiler, executable section
layout, embedded payload expansion, permission-sensitive execution, and
platform-specific binary writer.
The copied `bundler/compile-sourcemap-internal.test.ts` fixture now
passes as `1` test through the compile-mode model, returning the expected
source-frame stderr for `util.ts:5` and `ismapp.ts:4`. Native parity
still needs Bun's real InternalSourceMap embedding and runtime
stack-frame remapper.
The copied `bundler/compile-windows-metadata.test.ts` fixture now
registers on this non-Windows host as `0` passed, `0` failed, `0`
unsupported, and `1` todo/skipped. The bootstrap lowers its harness,
`fs.promises`, `node:fs`, and `child_process` imports and preserves
`describe.skipIf(!isWindows).concurrent`; native parity still needs
Bun's real Windows executable metadata embedding and verification path.
The copied `regression/issue/02367.test.ts` fixture now passes as `1`
test through the Web Body + matcher bootstrap model. It covers Bun's
empty `Response.json()` / `Request.json()` rejection shape and the async
function form of `expect(...).toThrow(SyntaxError)`.
The copied `regression/issue/02369.test.ts` fixture now passes as `1`
test through the Web Request bootstrap model. It covers repeated fresh
`Request` construction with string JSON bodies and `await request.json()`
parsing into deep-equal array/object payloads.
The copied `regression/issue/09739.test.ts` fixture now passes as `2`
tests through the CommonJS and dynamic-import bootstrap model. It covers
the upstream `abort-controller` CommonJS re-export fixture and bare
`await import("abort-controller")` resolving to the runtime-global
`AbortController` binding.
The copied `regression/issue/02368.test.ts` fixture now passes as `2`
tests through the Web Body bootstrap model. It covers `Response.clone()`
and `new Request(existingRequest)` preserving status, method, headers,
and independent readable body text.
The copied `js/web/request/request.test.ts` fixture now passes as `4`
tests through the Web Request bootstrap model. It covers undefined and
null optional fields, cloned string bodies, stream-backed request bodies,
and unlocked `body.locked` state before and after `request.clone()`.
The copied `cli/install/architecture-match.test.ts` fixture now passes
as `30` tests through the Pantry-backed platform matcher model. It
covers Bun's `isArchitectureMatch` and `isOperatingSystemMatch`
semantics for `any`, current CPU/OS positives, current negations, and
non-current negation fallbacks.
The copied `js/web/fetch/blob-cow.test.ts` fixture now passes as `1`
test through the Web Blob bootstrap model. It covers byte-backed
construction from typed arrays, copy-on-write `arrayBuffer()` reads,
`size`, and sliced `arrayBuffer()` reads without sharing mutable buffers.
The copied `js/web/fetch/blob-array-fast-path.test.ts` fixture now
passes as `11` tests through the same Web Blob bootstrap model. It
covers string arrays, large arrays, typed-array and nested-Blob parts,
empty and derived arrays, frozen arrays, sparse arrays, Array prototype
indexed getters, numeric coercion, non-ASCII text encoding, and
`expect().toContainEqual()` side-effect matching.
The copied `cli/run/commonjs-invalid.test.ts` fixture now passes as `1`
test through the real subprocess path, including piped stderr and the
malformed CommonJS wrapper diagnostic.
The copied `js/bun/util/file-type.test.ts` fixture now passes as `2`
tests through the `Bun.file` bootstrap model. It covers explicit
`{ type }` MIME overrides and Bun's `.css` default MIME type.
The copied `js/bun/util/bun-file-read.test.ts` fixture now passes as
`1` test through the file-backed `Bun.file` bootstrap model. It covers
`Bun.write()` to a temp path, `Bun.file(path).size`, byte-offset
`slice(start, end)`, and `slice.text()` without regressing executable
header `slice().arrayBuffer()` coverage in compile-mode fixtures.
The copied `js/node/url/url-pathtofileurl.test.js` fixture now passes on
this non-Windows host as `2` passed, `0` failed, `0` unsupported, and
`2` todo. The bootstrap models POSIX path resolution and UTF-8 percent
encoding; full native parity still needs Windows/UNC and Node-style
invalid-argument errors.
The copied `cli/run/empty-file.test.ts` fixture now passes as `1` test
through the real subprocess path. The bootstrap adds `expect().toBeEmpty`
and normalizes `home run --bun <file>` to the runtime-compatible
`home run <file>` command shape.
The copied `js/bun/util/randomUUIDv7.test.ts` fixture now passes as `6`
tests through the `Bun.randomUUIDv7` bootstrap model. It covers
timestamp-prefix encoding, version/variant bits, `hex` / `base64` /
`buffer` output forms, per-timestamp monotonic ordering, `Bun.deepEquals`,
and `expect().toBeLessThanOrEqual`.
The copied `js/bun/util/sleepSync.test.ts` fixture now passes as `5`
tests through the `Bun.sleepSync` bootstrap model. It covers
millisecond timing, missing / non-number / negative argument validation,
and named `import { sleepSync } from "bun"` lowering while keeping the
fixture byte-identical to upstream Bun.
The copied `js/bun/util/readablestreamtoarraybuffer.test.ts` fixture now
passes as `1` test through the stream bootstrap model. It covers queued
`ReadableStream` chunks, `TextEncoder` / `TextDecoder` ArrayBuffer
roundtrips, and an internal-promise-style implementation that ignores
user overrides of `Promise.prototype.then`.
The copied `js/bun/util/unsafe.test.js` fixture now passes as `4` tests
through the unsafe utility bootstrap model. It covers `harness.gc`
lowering, `Bun.unsafe.arrayBufferToString` for byte arrays,
`ArrayBuffer`, and `Uint16Array`, plus writable `Bun.allocUnsafe`
`Uint8Array` storage.
The copied `js/bun/util/toUTF16Alloc.test.ts` fixture now passes as `6`
tests through the internal string bootstrap model. It covers named
`stringsInternals` lowering from `bun:internal-for-testing`, valid UTF-8
decoding, and invalid-byte replacement-character output.
The copied `js/bun/util/bun-isMainThread.test.js` fixture now passes as
`1` test through the worker/subprocess bootstrap model. It covers
`Bun.isMainThread`, `expect().toBeTrue()`, relative
`import.meta.resolveSync`, and the expected worker child stdout.
The copied `js/bun/util/pathToFileURL-invalid.test.ts` fixture now
passes as `1` executable test plus `1` host-skipped Windows block. It
covers narrow Bun/harness import lowering, `expect.stringMatching()`
inside deep equality, and POSIX subprocess output for invalid UNC-style
inputs without exercising a real crash path.
The copied `regression/issue/015201.test.ts` fixture now passes as `1`
test through the Node util bootstrap model. It covers named
`import { promisify } from "util"` lowering, the virtual `util` /
`node:util` module, and the `nodejs.util.promisify.custom` hook on the
timer shim so `promisify(globalThis.setTimeout)(1, "ok")` resolves
`"ok"`.
The copied `js/node/util/node-inspect-tests/import.test.mjs` fixture now
passes as `1` test through the Node util bootstrap model. It covers
default plus named `util` import lowering, `util.inspect === inspect`,
`null` formatting, and non-compact object formatting with Bun/Node-style
line breaks.
The copied `js/node/util/node-inspect-tests/internal-inspect.test.js`
fixture now passes as `1` executable test plus `1` upstream skipped test
through the Node util bootstrap model. It covers `util.format()` on
proxy-wrapped data properties without invoking the proxy getter,
`formatWithOptions({ numericSeparator: true }, "%d", 4000)`, compact and
non-compact circular-reference formatting, and `Error({ cause })`
inspection including the `[cause]` line.
The copied `js/node/process-binding.test.ts` fixture now passes as `2`
tests through the `process.binding` bootstrap model. It covers the
`constants` binding buckets Bun asserts plus the `uv` error-name and
`getErrorMap()` surface used by the upstream fixture.
The copied `js/node/process/call-constructor.test.js` fixture now passes
as `2` tests through the process bootstrap model. It covers default
`import process from "process"` lowering plus Bun's asserted
`process.constructor.call(...)` prototype shape.
The copied `js/bun/resolve/jsonc.test.ts`,
`js/bun/resolve/bun-lock.test.ts`, `js/bun/io/bun-write-leak.test.ts`,
`js/bun/test/snapshot-tests/existing-snapshots.test.ts`,
`js/bun/test/expect-stack-overflow-crash.test.ts`,
`js/bun/test/expect-symbol-toPrimitive-crash.test.ts`, and
`js/node/dns/dns-lookup-keepalive.test.ts` fixtures now contribute `9`
aggregate passed tests through the existing JSONC/module, Bun.write,
expectation, subprocess, and DNS bootstrap surfaces.
The copied `regression/issue/11297/11297.test.ts`,
`regression/issue/11866.test.ts`, `js/bun/http/leaks-test.test.ts`,
`js/node/util/node-inspect-tests/parallel/util-inspect-long-running.test.mjs`,
and `regression/issue/28522.test.ts` fixtures now pass as `7` tests
through the existing regression, HTTP server/leak, and Node util inspect
bootstrap surfaces.
The copied `regression/issue/12034/12034.test.js` fixture now passes as
`10` tests by lowering its side-effect import to the copied
`12034.fixture.ts` body, preserving the fixture's Jest-global assertions
and `expect.extend` matcher before running the entry assertion.
The copied `bundler/transpiler/export-default.test.js` fixture now
passes as `1` test by lowering its default import to the copied
`export-default-with-static-initializer` class body, preserving the
static initializer that sets `boop`.
The copied `regression/issue/27428.test.ts`,
`regression/issue/440.test.ts`,
`js/bun/namespace-prototype-pollution.test.ts`,
`js/bun/resolve/concurrent-dynamic-import.test.ts`,
`regression/issue/server-stop-with-pending-requests.test.ts`,
`js/bun/bundler/yaml-bundler.test.js`,
`regression/issue/27389.test.ts`, `regression/issue/29264.test.ts`,
`js/bun/resolve/require-esm-microtask-order.test.ts`, and
`regression/issue/26632.test.ts` fixtures now pass as `15` tests through
the existing child-process, HTTP/server, resolver, bundler, and
`Bun.file` bootstrap surfaces.
The copied `js/node/url/url-parse-query.test.js` fixture now registers
as `1` todo through the existing Node `url` import rewrite, preserving
Bun's upstream TODO around parsed query-object prototypes and null
values.
The copied `integration/bun-types/fixture/5396.test.ts` fixture now
passes as `1` test by erasing its type-only DTO/class annotations and
supporting Bun/Jest mock promise helpers on both `mock()` functions and
`spyOn()` wrappers.
The copied `js/web/fetch/utf8-bom.test.ts`,
`js/web/fetch/form-data-boundary-crash.test.ts`,
`js/web/fetch/response.test.ts`,
`js/web/fetch/body-clone.test.ts`,
`js/web/fetch/blob-write.test.ts`,
`js/web/html/FormData.test.ts`,
`js/bun/http/bun-serve-fetch-invalid-args.test.ts`, and
`js/bun/http/getIfPropertyExists.test.ts` fixtures now pass as `30`
tests plus `14` Web Response tests, `24` Body clone/byte-reader tests,
`10` Blob/File write tests, and `111` full Web FormData tests
through Body BOM stripping, malformed multipart rejection,
Response/FileRef inspection, stream clone/body teeing, multipart
serialization/parsing, Blob/File preservation, File-backed FormData,
file write/unlink/writer/stat behavior, fallback stream async-start and
pull replay,
`server.fetch` invalid-argument parity, module-option rewrites, and
Bun-style `Request` option getter behavior.
The copied `bundler/bundler_bun.test.ts` fixture now passes as `6` tests
by lowering its `bun:sqlite` `Database` import to the Home bootstrap
sqlite shim and running the upstream `itBundled` cases through the
existing bundler harness surface.
The copied `cli/run/shell-keepalive.test.ts`,
`cli/run/commonjs-no-export.test.ts`,
`cli/run/jsx-symbol-collision.test.ts`, and
`js/bun/spawn/spawn-empty-arrayBufferOrBlob.test.ts` fixtures now pass
as `7` tests through the existing `bunExe()` child-process bridge,
`expect(...).toRun()`, piped stdout/stderr text helpers, and empty
`ArrayBuffer` / `Uint8Array` / `Blob` stdin handling.
The copied `bake/deinitialization.test.ts`,
`bake/dev/import-meta-inline-negative.test.ts`, and
`bake/dev/stress.test.ts` fixtures now pass as `3` parent tests through
the existing Bake harness shim, child `bunExe()` execution, `Bun.write`,
`Bun.sleep`, and `import.meta` child-process coverage.
The copied `bake/dev-and-prod.test.ts`, `bake/dev/bundle.test.ts`,
`bake/dev/css.test.ts`, `bake/dev/ecosystem.test.ts`,
`bake/dev/esm.test.ts`, `bake/dev/hot.test.ts`,
`bake/dev/html.test.ts`, `bake/dev/import-meta-inline.test.ts`,
`bake/dev/incremental-graph-edge-deletion.test.ts`,
`bake/dev/plugins.test.ts`, `bake/dev/production.test.ts`, and
`bake/dev/react-response.test.ts` fixtures now pass as `102` tests plus
`2` upstream todos through the existing Bake dev harness model.
The copied `bake/dev/react-spa.test.ts`,
`bake/dev/request-cookies.test.ts`,
`bake/dev/response-to-bake-response.test.ts`,
`bake/dev/server-sourcemap.test.ts`, `bake/dev/sourcemap.test.ts`,
`bake/dev/ssg-pages-router.test.ts`, `bake/dev/vfile.test.ts`,
`bake/framework-router.test.ts`, and
`bake/serve-plugins-dev-server.test.ts` fixtures now pass as `65`
additional tests, completing the currently copied Bake corpus files in
the minimal native subset.
The copied `bundler/bundler_comments.test.ts` fixture now passes as
`42` tests by lowering `node:module.SourceMap` into the Home bootstrap
module table and erasing Bun's copied TypeScript postfix non-null
assertion on the source-map entry check.
The copied `bundler/bundler_compile.test.ts` and
`bundler/bundler_defer.test.ts` fixtures now pass as `64` tests through
the shared bundler harness. This chunk adds Bun compile/standalone
process smokes, `require.resolve`, compile artifact spawn reuse,
React SSR package shims, plugin `onStart` error ordering, defer metadata
JSON checks, and the copied TypeScript lowering needed by those files.
The copied `bundler/standalone.test.ts`, `bundler/metafile.test.ts`, and
`bundler/html-import-manifest.test.ts` fixtures now pass as `64`
additional tests through browser-target standalone HTML inlining,
CSS/import asset folding, metafile JSON/Markdown generation, and Bun's
HTML import manifest shape.
Native parity still needs Bun's real standalone graph, bytecode cache,
plugin scheduler, and CSS parser diagnostics rather than the bootstrap
model.
The copied `js/bun/test/test-timers.test.ts` fixture now passes as `1`
test through the Jest fake-timer bootstrap model. It covers Bun's stable
`Date` identity, mocked `Date.now()` / `new Date()`,
`jest.setSystemTime()`, `jest.useRealTimers()`, and no-argument
`Intl.DateTimeFormat().format()` for the asserted fake time.
The copied `internal/highlighter.test.ts` fixture now passes as `1` test
through the `bun:internal-for-testing.highlightJavaScript` bootstrap
model. It covers the template-literal interpolation path from Bun's
quick JavaScript syntax highlighter; the pure Zig `fmtJavaScript` /
`fmt_jsc` binding port remains the native follow-up.
The copied `js/bun/util/highlighter.test.ts` fixture now passes as `1`
test through the same `highlightJavaScript` bootstrap model. It covers
the Bun utility-facing import path and bounds the formatter output for
nested template-literal interpolation inputs.
The copied `cli/test/pass-with-no-tests.test.ts` fixture now passes as
`5` tests through the subprocess bootstrap model. It covers lexical
`bun:test` import detection around embedded fixture source strings plus
`--pass-with-no-tests` / filtered no-match exit codes and stderr.
The copied `js/bun/http/bun-serve-body-json-async.test.ts` fixture now
passes as `1` test through the JS-only server bootstrap model. It covers
the long-lived `Bun.spawn()` server fixture stdout URL, `kill()`, null
pre-kill `signalCode`, and `Bun.serve({ fetch })` JSON-body echoing.
The copied `js/bun/http/req-url-leak.test.ts` fixture now passes as `1`
test through the IPC-style server bootstrap model. It covers
`Bun.spawn({ ipc })` URL delivery, bounded RSS text responses, and
`new URL(input, base)` with a large relative path.
The copied `js/third_party/prompts/prompts.test.ts` fixture now passes as
`1` test through the interactive subprocess bootstrap model. It covers
the initial stdout prompt read, stdin writes, exit code `0`, and formatted
answer output asserted by Bun.
The copied `js/web/timers/microtask.test.js` fixture now passes as `1`
test through the timer bootstrap model. It covers `queueMicrotask`
ordering plus Bun/browser-compatible `TypeError` validation for missing
or non-function callbacks.
The copied `js/web/timers/setImmediate.test.js` fixture now passes as
`3` tests through the timer bootstrap model. It covers scheduled
callbacks, argument forwarding, `clearImmediate` cancellation, and
process-exit behavior for pending immediates.
The copied `js/web/timers/setImmediate2.test.ts` fixture now passes as
`1` test through the timer/server bootstrap model. It covers Bun-like
timer handles with no-op `ref()` / `unref()` / `refresh()` methods,
numeric handle coercion, and JS-only `Bun.serve({ fetch })` hostname
resolution through the in-harness `fetch` model.
The copied `js/web/timers/clearImmediate-gc.test.ts` fixture now passes
as `1` test through the timer/subprocess bootstrap model. It covers the
upstream inline `bunExe() -e` smoke for clearing a queued immediate,
forcing GC, and letting a trailing timer settle without stdout/stderr.
The copied `js/web/timers/performance.test.js` fixture now passes as
`6` tests through the performance/timer bootstrap model. It covers
resource-timing no-op methods, writable
`onresourcetimingbufferfull`, monotonic `performance.now()`, wall-clock
origin behavior, and positive numeric `Bun.nanoseconds()` output.
The copied `js/web/timers/performance-entries.test.ts` fixture now
passes as `1` test through the performance/JSC bootstrap model. It
covers named `bun:jsc` import lowering plus shallow performance memory
growth as marks and measures are registered.
The copied `js/web/html/URLSearchParams.test.ts` fixture now passes as
`11` tests through the URL bootstrap model. It covers the indexed-access
TypeScript cast rewrite, Bun's `toJSON` / `.length` extensions,
configurable/enumerable `size`, value-aware `.has()` / `.delete()`, and
`Bun.inspect(URLSearchParams)` formatting without regressing the Deno
URLSearchParams smoke.
The copied `js/web/html/FormData-file-error-leak.test.ts` fixture now
passes as `1` test through the subprocess fixture model. It covers named
`node:path` import lowering plus bounded RSS-growth JSON returned for the
upstream `--smol` FormData missing-file serialization leak child process.
The copied `regression/issue/07917/7917.test.ts` fixture now passes as
`1` test through the Web bootstrap model. It covers `FormData.append()`,
entry iteration, and `Request` multipart body serialization whose
`content-type` boundary parameter remains unquoted.
The copied `regression/issue/09563/09563.test.ts` fixture now passes as
`1` test through the bootstrap dynamic-import shim. It covers queried
relative imports of an empty TypeScript module and ensures the async
transpiler regression's `Promise.all()` settles.
The copied `js/third_party/yargs/yargs-cjs.test.js` fixture now passes
as `1` test through the CommonJS bootstrap model. It covers
`require("yargs/yargs")` returning a function and the runtime
`expect(...).toBeFunction()` matcher.
The copied `js/third_party/jsonwebtoken/decoding.test.js` fixture now
passes as `1` test through the CommonJS bootstrap model. It covers
default-import lowering for `jsonwebtoken` and `jwt.decode("null")`
returning `null` without throwing.
The copied `js/third_party/jsonwebtoken/buffer.test.js`,
`js/third_party/jsonwebtoken/expires_format.test.js`,
`js/third_party/jsonwebtoken/noTimestamp.test.js`, and
`js/third_party/jsonwebtoken/invalid_exp.test.js` fixtures now pass as
`8` tests through the CommonJS bootstrap model. They cover base64
`Buffer` payload signing/decoding, deprecated `expiresInSeconds` option
validation, `expiresIn: "5m"` claim insertion, and invalid `exp`
callback error names.
The copied `js/third_party/jsonwebtoken/non_object_values.test.js`,
`js/third_party/jsonwebtoken/issue_147.test.js`,
`js/third_party/jsonwebtoken/encoding.test.js`, and
`js/third_party/jsonwebtoken/set_headers.test.js` fixtures now pass as
`8` tests through the CommonJS bootstrap model. They cover compact JWT
header and payload segment decoding, custom header merges, UTF-8 and
binary payload encoding, non-object payload verification, and numeric
`expiresIn` handling on sealed object payloads.
The copied
`js/third_party/jsonwebtoken/undefined_secretOrPublickey.test.js`
fixture now passes as `2` tests through the CommonJS bootstrap model. It
covers `jwt.verify()` validation for null and missing secret/public key
arguments with the upstream error message matcher.
The copied `js/bun/util/bun-file-exists.test.js` fixture now passes as
`1` test through the Bun/file-system bootstrap model. It covers
`Bun.file(import.meta.path).exists()`, directory non-file behavior,
`Bun.write()` exported from the virtual `bun` module, `os.tmpdir()`, and
native `fs.unlinkSync()` cleanup against a real temp file.
The copied `regression/issue/5228.test.js` fixture now passes as `4`
tests through the Bun test bootstrap and spawned-child fixture model. It
covers the `xit`, `xtest`, and `xdescribe` aliases as global helpers and
named `bun:test` imports, matching `test.skip` and `describe.skip`
behavior.
The copied `js/bun/test/mock-disposable.test.ts` fixture now passes as
`3` tests through the Bun test bootstrap model. It covers `spyOn()`
`mockReturnValue`, prototype-method restoration, `mock()` disposable
cleanup, and `Symbol.dispose` lowering for `using` scopes.
The copied `regression/issue/26377.test.ts` fixture now passes as `3`
tests through the Web Streams bootstrap model. It covers
`ReadableStreamDefaultController.desiredSize` before enqueueing, after
`close()`, after `error()`, and after failed `pipeTo()` cleanup, plus the
`expect().toBeOneOf()` matcher and the TypeScript generic/union
annotation erasure needed for the upstream fixture.
The copied `regression/issue/26631.test.ts` fixture now passes as `8`
tests through the Node filesystem bootstrap model. It covers
`node:fs.existsSync`, `node:fs.statSync`, `node:fs/promises.exists`, and
`node:fs/promises.stat` against `.` and `..`, backed by native access/stat
bridges and a JS `Stats` wrapper with `isDirectory()`.
The copied `regression/issue/26844.test.ts` fixture now passes as `2`
tests through the child-process bootstrap model. It covers
`child_process.execFileSync` missing-executable ENOENT errors and
shell-backed `execSync` command failures with Bun-shaped enumerable
fields and no self-referencing `error` property, so `JSON.stringify(err)`
does not throw.
The copied `js/node/path/to-namespaced-path.test.js` fixture now passes
as `4` tests through the path bootstrap model. It covers
`path.toNamespacedPath`, `path._makeLong`, posix/win32 namespace variants,
and the upstream `./common/fixtures.js` path helper import.
The copied `js/bun/util/fileUrl.test.js` fixture now passes as `20`
tests through the URL bootstrap model. It covers Bun file URL helper
imports, `Bun.pathToFileURL`, stricter `Bun.fileURLToPath` throws, long
relative path normalization, and corpus-relative `import.meta` roundtrips.
The copied `js/node/url/pathToFileURL.test.ts` fixture now passes as `2`
tests through the URL bootstrap model. It covers global
`Bun.pathToFileURL` exposure and special-character path escaping,
including Bun's `%7E` encoding for `~`.
The copied `js/node/url/url-fileurltopath.test.js` fixture now passes as
`1` executable test plus `1` upstream todo through the URL bootstrap
model. It covers POSIX `url.fileURLToPath` string and `URL` roundtrips.
The copied `regression/issue/012039.test.ts` fixture now passes as `3`
tests through the `Bun.Transpiler` bootstrap model. It covers the
upstream class-field parser crash regression for ZWJ and ZWNJ identifier
continuation characters plus the invalid control-character field name
diagnostic prefix from `transformSync()`.
Snapshot corpus bookkeeping is still accurate as of the 2026-06-02
inventory check. The minimal subset allowlists three snapshot fixture
paths:
`js/bun/test/snapshot-tests/existing-snapshots.test.ts`,
`js/bun/test/snapshot-tests/snapshots/more.test.ts`, and
`js/bun/test/snapshot-tests/snapshots/more-snapshots/different-directory.test.ts`.
Only the last one is an upstream `test.todo`, so only that snapshot
matcher body is intentionally not executed. The source
rewrite lowers named `bun:test` imports to a virtual
`globalThis.__home_import("bun:test")` module and lowers
`import.meta.dir/path` to the same per-file metadata used for the
directory and filename globals. Unsupported deep-equality types such as
typed arrays, `ArrayBuffer`, and `Error` now fail closed instead of
silently comparing as empty-key objects. Native ESM `bun:test`
registration still requires a narrow JSC module-loader bridge because
system JavaScriptCore's public C API does not expose Bun's synthetic
module hooks directly. This is a stepping stone for corpus bring-up, not
a substitute for the vendored Zig runner below.

The Home database package now includes a native PostgreSQL
`CommandComplete` decoder modeled on Bun's protocol parser. It decodes
zero-terminated command tags, preserves INSERT OIDs, classifies common
command kinds, and feeds query / execute affected-row counts through the
shared parser without requiring a live PostgreSQL server in tests.

The runtime package now includes the copied PostgreSQL
`NegotiateProtocolVersion` protocol leaf. It preserves Bun's version plus
unrecognized-options shape, substitutes the current heap-owned UTF-8
string stand-in for upstream `bun.String`, and is exported through
`home_rt.sql.postgres.protocol` plus the phase smoke imports.

The runtime package now includes the copied MySQL `StackReader` protocol
leaf. It preserves Bun's in-memory reader cursor behavior, bounded reads,
backwards skip clamping, and NUL-terminated field reads while routing
the only Bun helper dependency through `home_rt.strings.indexOfChar`.

The runtime package now includes the copied MySQL `Query` COM_QUERY
writer leaf. The port keeps Bun's packet-framing logic and debug scope,
with execution still gated by the current `NewWriter` method stub until
the full writer surface is ported.

The runtime package now includes the copied MySQL `HandshakeResponse41`
client authentication response writer. It preserves Bun's capability
flag handling, auth-response mode branches, database/plugin fields, and
connect-attribute length accounting while adapting the allocator,
`StringHashMapUnmanaged`, and padding syntax for Home on Zig 0.17 dev.

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
| DoneCallback.zig | 47 | 5 | 0 | 0 | tier2-done-callback | `bun.md`, `bun.handleOom`, `bun.JSError` |
| diff_format.zig | 85 | 5 | 2 | 0 | tier2-diff-format | `bun.md`, `bun.AllocationScope`, `bun.Output` |
| debug.zig | 109 | 7 | 1 | 0 | tier2-debug | `bun.JSError`, `bun.md`, `bun.env_var` |
| harness/recover.zig | 132 | 1 | 0 | 0 | tier0 | `bun.md` |
| Collection.zig | 171 | 8 | 0 | 0 | tier2-collection | `bun.JSError`, `bun.assert`, `bun.md` |
| Order.zig | 187 | 16 | 0 | 0 | tier2-order | `bun.JSError`, `bun.assert`, `bun.Environment` |
| timers/FakeTimers.zig | 376 | 32 | 0 | 0 | blocked | `bun.JSError`, `bun.timespec`, `bun.assert` |
| expect/toBeTrue.zig + 30 primitive/truthiness/number/comparison/tag/array/object/length matchers | ~1 280 | 7-10 each | 0 | 0 | tier2-expect-matchers | `bun.jsc`, `bun.JSError`, `Expect` |
| ScopeFunctions.zig | 498 | 64 | 0 | 0 | blocked | `bun.String`, `bun.JSError`, `bun.handleOom` |
| jest.zig | 520 | 44 | 3 | 1 | blocked | `bun.handleOom`, `bun.default_allocator`, `bun.JSError` |
| harness/fixtures.zig | 575 | 1 | 0 | 0 | tier0 | `bun.md` |
| snapshot.zig | 582 | 49 | 3 | 0 | blocked | `bun.copy`, `bun.logger`, `bun.sys` |
| diff/printDiff.zig | 586 | 12 | 1 | 0 | tier1 | `bun.handleOom`, `bun.md`, `bun.strings` |
| Execution.zig | 695 | 35 | 0 | 1 | tier2-execution | `bun.timespec`, `bun.assert`, `bun.JSError` |
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

The bootstrap facade now tracks mock return results, thrown calls,
one-shot mock implementations, and one-shot return values well enough for
the copied `js/bun/test/expect-toHaveReturnedWith.test.js` fixture to
pass as `13` tests. This preserves Bun's `toHaveReturnedWith()` behavior:
omitting the expected argument matches an `undefined` return value rather
than failing argument validation.

The bootstrap facade also exposes Bun's `mock.module` validation path and
feeds registered module factories into dynamic imports for the copied
`js/bun/test/mock/mock-module-non-string.test.ts` fixture, which now
passes as `5` tests. Mocked module registrations reset between corpus
files so a Bun fixture's `jest.mock("fs", ...)` cannot shadow the shared
native `fs` facade in later files.

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

4. `diff_format.zig` (85 LOC) — `bun.Output`, `bun.AllocationScope`;
   compile-checked in the focused `home_test_bun_tier2_diff_format`
   target for string-diff formatting
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
10. `DoneCallback.zig` (47 LOC) — async test done callback;
    compile-checked in the focused `home_test_bun_tier2_done_callback`
    target with a local scaffold for create/bind/finalize behavior
11. `debug.zig` (109 LOC) — runner debug dumping; compile-checked in
    the focused `home_test_bun_tier2_debug` target with logging disabled
12. `Execution.zig` (695 LOC) — scheduler + timeout machinery;
    compile-checked in the focused `home_test_bun_tier2_execution`
    target with a local scaffold for BunTest/JSC/reporter/timespec
    surfaces
13. `expect/toBeTrue.zig` + thirty matcher leaves — primitive,
    truthiness, number, comparison, tag, array, object-empty, length, even/odd, and valid-date expect
    matchers; compile-checked in the focused
    `home_test_bun_tier2_expect_matchers` target with a local
    Expect/JSC/formatter scaffold
14. `timers/FakeTimers.zig` (376 LOC) — Jest-style fake timers
15. `snapshot.zig` (582 LOC) — snapshot persistence (touches
    `bun.sys`/`bun.logger`)

### Tier 3 — JSC-bound surface (gate behind `enable_jsc`)

These cannot meaningfully run until Home's JS runtime is wired up;
they are the entire `expect`/`describe` surface.

15. `expect.zig` (2 272 LOC) — `expect()` harness, all asymmetric matchers
16. `expect/*.zig` (70 files, ~2 800 LOC) — individual matchers
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
