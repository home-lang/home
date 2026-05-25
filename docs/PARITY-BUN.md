# Bun runtime parity

Detailed per-API status for Home's Bun-compatible runtime
(`packages/runtime/`). This is the drill-down view; the at-a-glance
row is in the
[README parity status](../README.md#bun-runtime-port-packagesruntime)
section.

> **Status:** Substrate + JSC M6 landed. `packages/runtime/src/`
> currently contains 1,289 Zig source files. Of the audited 1,193-file
> Bun baseline, 552 files are integrated into Home (~46.3%): rewritten
> for Home imports, Zig 0.17-clean, build-wired, and tested. The remaining
> staged Bun files are an integration backlog, not parity credit; the
> runtime is not yet JavaScript-callable end-to-end, but Phase 12.2
> (JSC bring-up) has reached the M6
> milestone — JSON + Promise + Iterator + Global helpers — across
> 128 files in `packages/runtime/src/jsc/`, including a live
> `JSEvaluateScript` smoke and the public JavaScriptCore
> `JSObjectMakeDeferredPromise` deferred-promise constructor bridge.
> Full audit:
> [`packages/runtime/PORT_AUDIT_2026-05-20.md`](../packages/runtime/PORT_AUDIT_2026-05-20.md).

Legend:

- 🟢 **Fully implemented** — JS-callable today.
- 🟡 **Partially implemented** — JS-callable, missing APIs listed.
- 🔴 **Not implemented** — no JS surface yet; Zig substrate may exist.

## Phase-by-phase status

| Sub-phase | Source under `~/Code/bun/src/` | Destination | Status |
|---|---|---|---|
| 12.1 | `cli/` | `src/cli/` | 🟡 scaffold landed (CLI flag parsing partial) |
| 12.2 | `jsc/`, `bun.js.zig`, `jsc_stub.zig` | `src/jsc/` | 🟡 M6 milestone + native eval smoke landed (128 files: JSON + Promise + Iterator + Global helpers + `JSEvaluateScript` + `JSObjectMakeDeferredPromise`) |
| 12.3 | `event_loop/`, `io/`, `async/` | `src/event_loop/` | 🟡 substrate landing (~30+ leaves ported) |
| 12.4 | `resolver/`, `module_loader.zig` | `src/module_loader/` | 🔴 blocked on 12.2 |
| 12.5 | `web/`, `http/`, `csrf/`, `dns/` | `src/web/` | 🔴 blocked on 12.3 |
| 12.6 | `bun.zig` (Home.* surface) | `src/home/` | 🔴 blocked on 12.2 |
| 12.7 | `node/` namespace shims | `src/node/` | 🟡 round-15 landed (28 files: path / Stat / buffer / stream / fs / events / util / assert / os / url / querystring / crypto / process / string_decoder / tty + bindings) |
| 12.8 | `test/` runner | `src/test/` | 🔴 blocked on 12.2 |
| 12.9 | Pantry CLI integration | `src/install/pantry.zig` | 🟡 scaffold in progress |
| 12.10 | CLI surface | `src/cli/` | 🟡 scaffold landed |
| 12.11 | Cross-compile + single-file builds | `src/build/` | 🔴 not started |

## JS-visible APIs (the `Home.*` / `Bun.*` namespace)

### `Bun.serve`

🔴 Not implemented as a general JS API. A narrow Home-native bootstrap
path exists for the Bake deinitialization corpus fixture: HTML-route
`Bun.serve`, `server.stop()`, in-flight `fetch`, and HMR WebSocket
lifetime all route through native DevServer/Server carriers so teardown
uses the real `DevServer.deinit()` counter.

### `Bun.fetch`

🔴 Not implemented as a general JS API. The Bun corpus bootstrap has a
narrow hosted fetch path for the Bake deinitialization fixture's
`fetch(server.url.origin, { keepalive: false })` cases.

### `Bun.file` / `Bun.write`

🔴 Not implemented. `BunFile` reader/writer.

### `node:fs` sync methods

🔴 Not implemented as general runtime APIs. The Bun corpus bootstrap now has
a narrow native bridge for `writeFileSync`, `readFileSync(..., "utf8")`,
`realpathSync`, `renameSync`, and `unlinkSync`, which are needed by the
Bake harness, `bake/dev-and-prod.test.ts`, and `bake/dev/hot.test.ts`
import surfaces.

### `Bun.spawn` / `Bun.spawnSync`

🟡 Partial bootstrap bridge. `Bun.spawnSync({ cmd, cwd, stdio })` now
delegates to a native Home host callback for the Bun corpus bootstrap,
including real OS subprocess execution, corpus-relative cwd/path
resolution, and pipe/inherit/ignore stdio modes. The full Bun API surface
and `Bun.spawn` remain unported. The runtime source port now includes
Bun's POSIX `WaitPidResult`, `posix_spawnattr_t`, and
`posix_spawn_file_actions_t` wrapper substrate in
`packages/runtime/src/runtime/api/bun/spawn.zig`, rewritten for Home fd
aliases and Pantry Zig 0.17's Darwin `std.c.POSIX_SPAWN` flag type; the
ported `BunSpawn.Attr.set()` now re-derives `detached` from the packed
`SETSID` flag when the platform exposes it while preserving Bun's
no-flag fallback for FreeBSD-style targets. The
actual `spawnZ` / `waitpid` execution glue still requires the
`posix_spawn_bun` shim and `home_rt.sys.Error` surface before it can
count as integrated.

### `Bun.$ (shell)`

🔴 Not implemented. Embedded shell. Substrate at
`packages/runtime/src/runtime/shell/` (builtin `pwd`, `true_`, `false_`
ported as Tier-0 leaves).

### `Bun.SQLite`

🔴 Not implemented.

### `Bun.password`

🔴 Not implemented. Argon2 / bcrypt password hashing.

### `Bun.hash` / `Bun.CryptoHasher`

🔴 Not implemented.

### `Bun.semver`

🔴 Not implemented beyond the narrow Bun corpus bootstrap
`semver.satisfies` comparator-list smoke.

### `Bun.color`

🔴 Not implemented.

### `Bun.gzipSync` / `Bun.gunzipSync` / `Bun.deflateSync` / `Bun.inflateSync`

🔴 Not implemented. Substrate vendored under `packages/runtime/src/zlib/`.

### `Bun.deepEquals` / `Bun.deepMatch`

🔴 Not implemented.

### `Bun.escapeHTML`

🔴 Not implemented as a JS-callable runtime API. The Bun corpus bootstrap
has a narrow shim matching Bun's five-character escaping behavior for the
allowlisted `js/bun/util/escapeHTML.test.js` smoke.

### `Bun.inspect`

🔴 Not implemented. The Bun corpus bootstrap has a narrow
`Bun.inspect({ key: Set<string> })` shim for one allowlisted smoke; this
is not a JS-callable runtime API.

### `Bun.peek`

🔴 Not implemented.

### `Bun.readableStreamTo*`

🔴 Not implemented.

### `Bun.resolveSync` / `Bun.resolve`

🔴 Not implemented.

### `Bun.s3` / `Bun.S3Client`

🔴 Not implemented. Substrate vendored under
`packages/runtime/src/s3_signing/`.

### `Bun.sleep` / `Bun.sleepSync`

🟡 Bootstrap-only `Bun.sleepSync` support for copied corpus smokes:
millisecond timing plus missing, non-number, and negative argument
validation. Native runtime parity and `Bun.sleep` remain open.

### `Bun.stdin` / `Bun.stdout` / `Bun.stderr`

🔴 Not implemented.

### `Bun.stringWidth`

🔴 Not implemented.

### `Bun.udpSocket`

🔴 Not implemented.

### `Bun.which`

🔴 Not implemented.

### `Bun.version` / `Bun.revision`

🔴 Not implemented. The Bun corpus bootstrap exposes smoke-test aliases
for allowlisted files only; the runtime namespace does not yet provide
these as real APIs.

## Bundler (`packages/bundler/`)

🟡 **Substantial.** Home's bundler IS Bun's bundler — vendored under
MIT to `packages/bundler/` with the Tier-0 compatibility shim at
[`packages/compat/`](../packages/compat/) (see
[PARITY-BUN-COMPAT.md](./PARITY-BUN-COMPAT.md) for the per-symbol
status). The Zig-side surface compiles; what's missing is the JS
API for `Bun.build`. CLI entrypoint (`home bundle`) is in progress.

## Pantry (package management)

🟡 **In progress, not Bun-flavored.** Home replaces `bun install`
with the Pantry CLI (`home add` / `home install` / `home remove` /
`home update` route through Pantry's package manager). The runtime
has a `src/install/` shim that delegates to Pantry; the Bun
`install/` source IS NOT vendored — Pantry is Home's package
manager.

## Test runner (`home test`)

🔴 **Blocked on Phase 12.8 + 12.2.** Substrate at
`packages/runtime/src/runtime/test_runner/`. Acceptance gate per
[`packages/runtime/README.md`](../packages/runtime/README.md): once
feature-complete, Home must pass **100% of Bun's test suite with no
skips**.

Bootstrap smoke: `home test packages/runtime/test/bun-corpus
--bun-corpus-native-subset=minimal-js` executes two hundred sixty allowlisted JS
or plain-syntax TS corpus files through Home's JSC evaluator. On macOS this
JSC path is now part of the default `./pantry/.bin/zig build test` graph
(`-Denable_jsc=false` remains available for constrained hosts): the
todo-registration smoke, the Web `atob`/`btoa` smoke, fifty-five
regression smokes, one bundler constant-fold smoke, bundler
`allowUnresolved`, banner, barrel, browser-target builtin diagnostics, CJS,
CJS-to-ESM, compile-autoload, compile-splitting, decorator metadata,
drop/env/footer, HTML server, minify-symbol, npm, Promise.all dead-code,
regression, process `execArgv`, plugin exception, and transpiler
decorator / use-strict / template-literal
smokes, two `Bun.build` API
smokes, one bun-types `test.each` type-shape smoke, seven test-runner
expectation smokes plus `expect().toBeEmpty`, one nested-describe smoke, two `expectTypeOf` type-only smokes, a narrow `Bun.TOML.parse` throw smoke, a TOML build invalid-source diagnostic `lineText` crash-regression smoke, CSS `intFromFloat` serialization snapshots, `Bun.stripANSI` and
`Bun.wrapAnsi`, `Bun.semver.satisfies`, and `bun:internal-for-testing` regexp / PowerShell escaping smokes, retry/repeats runner behavior, `test.concurrent.each`, `expect().pass`, a narrow `mock.clearAllMocks` / `toHaveBeenCalledTimes` smoke, a narrow `jest.fn` / `HTMLRewriter` element-callback smoke, a narrow TypeScript constructor-modifier rewrite smoke, narrow `assert` / `assert/strict`, `node:path` including `matchesGlob` and long-CWD POSIX subprocess coverage, `node:url`, relative CJS fixture smokes, Node worker/fs/dns/readline one-shot smokes, and a WebSocket close-reentrancy smoke, a narrow inline-snapshot Unicode object formatting smoke, a `node:vm.runInNewContext` / `process.on` throw propagation smoke, Deno harness `test(options, fn)` / permission skip / `test.ignore` / `test.todo` call-shape parity, Deno `Event` / `CustomEvent` / `AbortController`, and a Deno `URLSearchParams` bootstrap smoke, plus narrow bootstrap coverage for Node `DOMException`, Web
`Response.json` / `Response.redirect`, Web `Request` cache/mode/clone,
repeated `Request.json()` string-body parsing,
fetch body async-iterator and abort smokes, AbortController GC reason,
MessagePort context cleanup,
and Deno Request string-body `text()` / clone call shapes,
narrow Deno URL authority/hash/origin parsing, a Deno `performance`
fixture covering timer-delayed measures, marks, observers, constructors,
and EventTarget behavior, WebSocket failed-connect `ErrorEvent` snapshots, JSC
`ShadowRealm`, native constructor identity, mutable
`globalThis` prototype behavior, a comment-only module-load smoke, Bun file metadata,
`Bun.file(...).type` MIME behavior, file-backed `Bun.file().size` /
`slice().text()`, `Bun.randomUUIDv7`, `Bun.sleepSync`
millisecond timing / argument validation,
`Bun.readableStreamToArrayBuffer` queued chunk draining,
`ReadableStreamDefaultController.desiredSize` cleanup across close,
error, and failed `pipeTo()` paths, and
`Bun.unsafe.arrayBufferToString` / `Bun.allocUnsafe` smoke coverage, and
`node:fs` / `node:fs/promises` exists/stat directory checks for current
and parent paths, and missing-command `child_process.execFileSync` /
`execSync` error serialization, and
`bun:internal-for-testing.stringsInternals.toUTF16AllocSentinel`
UTF-8 replacement behavior, and
`Bun.isMainThread` / worker child-output smoke coverage, and
Bun `pathToFileURL` invalid-host subprocess crash-regression coverage,
Node `util.promisify(globalThis.setTimeout)` custom-symbol timer
resolution coverage,
and
`Bun.deepEquals`, Node `Buffer`
binary/UTF-16LE/compare/inspect-limit/isEncoding behavior, `Map`/`Set`
deep-equality, `Bun.inspect` Set formatting, `MessageEvent` constructor
behavior, Bun version aliases, lifecycle hooks, own-key matchers, and a
`prepareStackTrace` crash smoke, sixteen sync runner fixture smokes
(`only-fixture-4`, `21177`, `5738`, printing dots, two multi-file
scheduling fixtures, six `test.only` / `describe.only` / `--only` flag
fixtures, concurrent alias, failure-skip lifecycle hooks, preload global
lifecycle hooks, conditional skip / `test.if` helpers, and two todo-only
test fixtures, plus one type-only `expectTypeOf` doctest), Web
`TextDecoder` CJK and single-byte
encoding smokes, a `prepareStackTrace` non-empty filename regression,
Node `module.SourceMap`, and a JSC string atomization smoke through the
`Bun.jest(import.meta.path)` alias plus a narrow `structuredClone`
fallback, validation-only `Bun.S3Client.write` numeric path errors,
validation-only `Bun.Transpiler` invalid UTF-16 loader errors,
`HTMLRewriter.onDocument({ doctype })` removal, narrow HTMLRewriter
selector / handler validation plus element callback methods,
`Bun.JSONC.parse` for comments, trailing commas, and deep-nesting
`RangeError`s, `jest.mock` / `mock.module` argument validation and
mock-module import factory routing, `it.each` /
`describe.each` synchronous table expansion with done-callback injection,
`node:url.domainToASCII` / `domainToUnicode` invalid-punycode handling,
POSIX `node:url.pathToFileURL` path encoding,
`Bun.fileURLToPath` / `pathToFileURL` conversion and throw behavior,
Node `url.fileURLToPath` POSIX roundtrip coverage,
`process.binding("constants")` / `process.binding("uv")` smoke coverage,
Jest fake-timer Date / `Intl.DateTimeFormat` smoke coverage,
`bun:internal-for-testing.highlightJavaScript` template-literal coverage,
`home test --pass-with-no-tests` subprocess exit/stderr coverage,
JS-only `Bun.serve({ fetch })` / long-lived `Bun.spawn` server-fixture coverage,
IPC-style server-fixture URL delivery and URL(base) coverage,
interactive third-party prompts stdin/stdout coverage,
`queueMicrotask` ordering and argument validation,
`setImmediate` / `clearImmediate` scheduling and cancellation,
`setImmediate` interaction with JS-only `Bun.serve` / fetch,
inline `clearImmediate(setImmediate(...))` subprocess GC coverage,
Performance resource-timing no-ops and `Bun.nanoseconds`,
Web `Blob.arrayBuffer()` copy-on-write, `Blob.slice().arrayBuffer()`,
array fast-path, typed-array, nested-Blob, sparse-array, prototype
indexed-getter, and non-ASCII text coverage,
`bun:jsc.estimateShallowMemoryUsageOf(performance)` entry-growth coverage,
Web `URLSearchParams` Bun-extension coverage,
FormData missing-file serialization leak subprocess coverage,
FormData-backed `Request` multipart serialization with unquoted
boundary parameters,
Web `Response.clone()` and `Request` clone construction preserving
method, headers, body text, and unlocked stream-backed bodies,
the Bun install `architecture-match` helper corpus through Pantry's
Bun-compatible CPU/OS package-eligibility matcher,
`import.meta.resolve` / `resolveSync` bad-parent throw behavior,
`jest.resetAllMocks` / `mockReturnThis`, `node:path` isAbsolute and
zero-length string behavior plus basename/extname/normalize/join/dirname,
parse/format, resolve, relative path table coverage,
`toNamespacedPath` / `_makeLong` namespace conversion, and path namespace
validation / separator coverage,
`Bun.concatArrayBuffers` and byte-wise ArrayBuffer / typed-array equality,
the `Bun.escapeHTML` utility corpus smoke, `describe.todo` registration
for the upstream `URL.revokeObjectURL` todo suite, `test.skip` /
`test.skipIf`
registration for upstream skipped Node URL null-character / internal URL
checks plus the Windows-only POSIX relative path smoke, a
`Bun.indexOfLine` UTF-8 byte-offset scan smoke, and
WHATWG `node:url.format(URL, { auth: false })` coverage, and
`node:test` skip/todo/null-options registration behavior, and
`expect.extend` matcher validation plus installed
expectation-object matchers, the Bake deinitialization DevServer teardown
fixture, CommonJS invalid-wrapper and empty-file CLI subprocess smokes,
queried relative dynamic imports for the empty async-transpiler
regression fixture, CommonJS re-export and bare dynamic import interop
for the upstream `abort-controller` fixture,
third-party `yargs/yargs` CommonJS function require coverage,
third-party `jsonwebtoken` default-import decode/sign/verify and compact-token
header/encoding plus missing-secret validation coverage,
`Bun.file().exists()` with real corpus/temp-file write/unlink coverage,
`bun:test` `xit`/`xtest`/`xdescribe` alias coverage through spawned tests,
`mock()` / `spyOn()` disposable cleanup with `mockReturnValue` and
`Symbol.dispose`,
plus one snapshot `test.todo` fixture whose
snapshot body remains intentionally unexecuted. The bootstrap harness is installed once
per JSC engine, resets counters before each file, lowers supported
`bun:test` imports through a virtual
`globalThis.__home_import("bun:test")` module shim, exposes `spyOn` /
`jest.spyOn` call tracking, return-result tracking, one-shot mock
implementations/return values, `toHaveReturnedWith`, `mock.module`
validation plus per-file mocked-module isolation, and stack-safe wrapper behavior, and fails closed as
unsupported for unsupported module syntax,
pending async work, async `onTestFinished` callbacks, explicit unsupported shim paths, and files that
register zero tests. Native ESM `bun:test` registration remains blocked
on a narrow JSC module-loader bridge, so this is deliberately not the
acceptance gate.

Latest measured subset run: `267` files, `1,191` passed, `0` failed,
`45` todo.

The unfiltered command `home test packages/runtime/test/bun-corpus` now
uses the same Home-native JSC bootstrap instead of the retired
`native-js-test-runner-missing` placeholder. It currently executes all
4,013 discovered Bun test files and fails on the first real failing
file. The native `Bun.spawnSync` bridge now starts the Bake child
process, and delegated `home test <fixture>` corpus descendants now route
back through the same JSC bootstrap instead of Home's parser. The
delegated Bake deinitialization fixture now passes all nine child tests
inside the full gate. The exact `bun:internal-for-testing`, `bun:jsc`,
and fixture HTML imports are lowered. The Zig-side Bake
DevServer/HmrSocket lifetime carrier is now present under
`packages/runtime/src/runtime/bake/` with deinit counter, route-viewer,
source-map ref, active-websocket teardown tests, Bun's HMR wire-message
ids, the opening `V` + configuration-hash payload, `subscribe`
topic-state handling, and `set_url` route-index responses. The
`bun:internal-for-testing` getter is connected to that real native
counter through the JSC bootstrap. The narrow Bake deinitialization
fixture path now wires JS-visible `Bun.serve`, `fetch`, timers, and HMR
WebSocket shims into native DevServer/Server/HmrSocket carriers, but the
general `Bun.serve`, `fetch`, and HMR WebSocket APIs are still unported.
The native server lifecycle carrier now mirrors Bun's DevServer detach
gate: no pending requests, no listener, and no active websockets before
the Bake DevServer is deinitialized.
The Bake nucleus also carries the first `serve.static.define`
propagation slice copied from Bun's bunfig / HTMLBundle flow: define maps
can be copied into client, server, and SSR Bake bundler options, and
`import.meta.env.*` mode/side flags are represented with Bun-compatible
replacement strings. The server runtime now has a metadata-only
HTMLBundle / Route carrier, a Bun-shaped `AnyRoute.html`, an HTML router
with `/*` fallback behavior, and ServerConfig static HTML-route entries
that initialize `bake.UserOptions` from `serve.static.define`. This is
substrate for the first `bake/dev-and-prod.test.ts` HTML-route case; it
is not yet a browser client or bundler execution path.
The JSC bootstrap also has a narrow `Bun.serve` host callback for the
Bake HTML-route shape; it now accepts Bun's `routes` or `static`
HTML-import objects, allocates real ServerConfig / HTMLBundle / Route /
DevServer / Server carriers, mirrors the `/*` HTML route into the
DevServer HTML router, and routes `server.stop()`, hosted `fetch`, and
HMR WebSocket open/close through the native lifecycle path. The bootstrap
also lowers the
`node:fs` sync imports used by Bake tests and forwards utf8
`writeFileSync` / `readFileSync` / `realpathSync` plus `renameSync` /
`unlinkSync` calls to native Home host callbacks. The delegated
`bake/fixtures/deinitialization/test.ts` child now passes all nine cases.
Exact Bake harness imports for `./bake-harness` and `../bake-harness`
now lower to a virtual registrar copied from Bun's no-color test-name
shape. The first `devAndProductionTest("define config via bunfig.toml")`
pair is now executed through the Home JSC bootstrap: the harness builds
the static HTML client script from Bun-style HTML references, parses only
`[serve.static].define` from `bunfig.toml`, routes through the native
`Bun.serve({ static: { "/*": html } })` HTML carrier, and observes the
expected `a=HELLO` client log in both development and production
registrations. The next malformed HTML pairs,
`devAndProductionTest("invalid html does not crash 1")` and
`devAndProductionTest("missing head end tag works fine")`, and
`devAndProductionTest("missing all meta tags works fine")`, also execute
through the same carrier: they resolve script and stylesheet refs
relative to `public/index.html`, evaluate the real `src/app/index.tsx`
fixture, derive the `background-color: red` assertion from
`src/app/styles.css`, and cover the first Bake `dev.fetch("/")`
HTML-include assertion. The inline
`devAndProductionTest("inline script and styles appear")` pair now
executes inline `<script>` code and derives style assertions from inline
`<style>` content while keeping `dev.fetch()` tied to the raw HTML
source. The development-only `devTest("using runtime import")` now runs
the narrow Bun runtime-import rewrite path for `using`, legacy class
decorators, and HMR `require` helpers in an isolated client scope. The
`devTest("hmr handles rapid consecutive edits")` case now drives
`writeFileSync` through a native Home DevServer hot-update queue, keeps
duplicate source-map IDs queued FIFO, drains updates through an HMR
socket carrier, and only then re-evaluates the changed client module.
This completes the current `bake/dev-and-prod.test.ts` file. The first
`bake/dev/bundle.test.ts` server-route smokes now execute through a
narrow `minimalFramework` route model for import binding updates,
symbol-collision preservation, development export conditions, and a
missing-import reload after `dev.write("second.ts", ...)`. These are
bootstrap route smokes, not full internal-Bake-dev parser/printer parity.
The default-export same-scope client graph smoke also runs through a
narrow fixture graph model for dynamic imports, default export chunk
formatting, and HMR chunk inspection. The directory-cache-bust smoke now
executes the `web/index.html` fixture path, writes an inert sibling module
inside `expectNoWebSocketActivity()`, then hot-replays the entry module
after it imports that new file. This keeps the corpus boundary moving,
but it is still a bootstrap model: it does not prove the real Bake
watcher, directory cache invalidation, or internal parser/lower/printer
pipeline yet. The delete/recover smoke now models extensionless import
resolution, expected missing-import error text, reload-after-restore, and
an unrelated-file delete with no client activity. It is also a bootstrap
overlay/reload proxy until the real Bake browser overlay and watcher path
is wired. The client-boundary demotion smoke now exercises the upstream
write/fetch sequence and final `Response` liveness assertion, but remains
a route-model proxy for Bun's real DirectoryWatchStore dependency
lifetime regression; Home still needs the native graph/watch cleanup path
ported before this is true Bake parity. The free-list deinit smoke now
executes the upstream `batchChanges` shape and final `Response` liveness
check, but likewise remains a bootstrap proxy until Home tracks failed
relative imports through real directory watches, sparse dependency slots,
and graceful DevServer deinit. It should eventually be replaced by the
native DirectoryWatchStore path copied from Bun's Zig base. Later Bake
files are still recorded as unsupported until the broader DevServer /
bundler / browser-client runtime path lands. The HTML-import startup
error smoke now checks the expected Bun diagnostic for browser builds
that import HTML without a loader. The HTML text-loader smoke now lowers
`import html from "./app.html" with { type: "text" }` to the fixture text
and verifies the client log. The Bun-builtin client import smoke now
checks the browser-build diagnostic for `import bun from "bun"`. The
`import.meta.main` smoke now lowers Bake browser client reads to `false`
across startup and hot replay. The CommonJS forms smoke now evaluates the
imported `.js` fixture with `module`, `exports`, `require`, and `eval`
bindings and replays all seven Bun update forms. The first barrel
optimization smoke now resolves only the used `Alpha` re-export and
leaves broken unused barrel targets untouched. The barrel reload smoke
now replays entry updates as additional `Beta` and `Gamma` imports are
introduced from the same barrel. The multi-file barrel smoke now keeps
entry-file barrel imports available while a sibling module changes its
own barrel import set. The barrel tail smokes cover export-star targets,
duplicate export-from blocks, and duplicate import statements from the
same barrel. With those bootstrap models in place,
`bake/dev/bundle.test.ts` now passes as a Home corpus file (`20` tests
passed, `0` failed, `0` unsupported). This is still not a substitute for
the real Bun bundler/barrel optimizer; the parser, linker, and optimizer
paths still need to be ported from Bun's Zig source for true parity.

Latest measured full gate after completing the Bake bundle-file smokes:
`4,013` files executed, `440` passed, `3,952` failed, `1,505`
unsupported, `35` todo. First failure: `bake/dev/bundle.test.ts`
has moved to `bake/dev/css.test.ts` with the named unsupported Bake
registration for
` DEV:css-1: css file with syntax error does not kill old styles`.

The first `bake/dev/css.test.ts` smoke now models stylesheet state for a
previously-valid CSS file that is rewritten to a syntax error. The Home
runner validates the expected Bun error text, preserves the last good
stylesheet for style assertions, normalizes `blue` to `#00f`, and removes
the selector after a blank stylesheet write. This is still a harness-level
model. True source parity requires porting Bun's CSS incremental asset
graph, serialized overlay errors, CSS asset ids, and client CSS reloader
behavior from the Zig runtime.

Latest measured full gate after the first Bake CSS syntax-preservation
slice: `4,013` files executed, `440` passed, `3,951` failed, `1,504`
unsupported, `35` todo. First failure: `bake/dev/css.test.ts` with
` DEV:css-2: css file with initial syntax error gets recovered`.

The initial-error CSS recovery smoke now validates startup overlay text,
reloads after a valid stylesheet write, observes `red`, hot-replaces to
browser-normalized blue, and validates the later syntax-error overlay.

Latest measured full gate after the Bake CSS initial-recovery slice:
`4,013` files executed, `440` passed, `3,950` failed, `1,503`
unsupported, `35` todo. First failure: `bake/dev/css.test.ts` with
` DEV:css-3: add new css import later`.

The dynamic CSS import smoke now attaches and detaches `styles.css` based
on an `index.ts` import being uncommented and re-commented, while still
using the harness stylesheet model.

Latest measured full gate after the Bake dynamic CSS-import slice:
`4,013` files executed, `440` passed, `3,949` failed, `1,502`
unsupported, `35` todo. First failure: `bake/dev/css.test.ts` with
` DEV:css-4: css import another css file`.

The CSS `@import` smoke now recursively expands imported stylesheets,
checks hot edits to the imported file, and preserves the result across a
hard reload in the harness model.

Latest measured full gate after the Bake CSS `@import` slice: `4,013`
files executed, `440` passed, `3,948` failed, `1,501` unsupported, `35`
todo. First failure: `bake/dev/css.test.ts` with
` DEV:css-5: asset referenced in css`.

The CSS asset-reference smoke now exposes `background-image` URLs,
supports `dev.fetch(url).expectFile(...)`, and reflects asset rewrites in
the in-memory fixture model.

Latest measured full gate after the Bake CSS asset-reference slice:
`4,013` files executed, `440` passed, `3,947` failed, `1,500`
unsupported, `35` todo. First failure: `bake/dev/css.test.ts` with
` DEV:css-6: syntax error crash`.

The CSS syntax-crash smoke now models the previous panic case by keeping
the initial malformed `background-image: url` stylesheet fetchable with a
`200` response, then patching it to an unterminated `url(` and surfacing a
`500` response instead of crashing. This remains a harness-level fatal CSS
status model, not the real Bun CSS parser/asset lifetime behavior.

Latest measured full gate after the Bake CSS syntax-crash slice: `4,013`
files executed, `440` passed, `3,946` failed, `1,499` unsupported, `35`
todo. First failure: `bake/dev/css.test.ts` with
` DEV:css-7: circular css imports handle hot reload`.

The circular CSS-import smoke now keeps recursive `@import` expansion from
looping, preserves both sides of an `a.css`/`b.css` cycle, and reflects a
hot edit to `.a` while `.b` stays browser-normalized blue. This continues
to exercise the harness CSS graph model while the real Bun
`IncrementalGraph.zig` CSS import processing remains the source parity
target.

Latest measured full gate after the Bake circular CSS-import slice:
`4,013` files executed, `440` passed, `3,945` failed, `1,498`
unsupported, `35` todo. First failure: `bake/dev/css.test.ts` with
` DEV:css-8: asset index stays valid after another css root is freed`.

The CSS asset-index smoke now routes `dev.client("/first")` and
`dev.client("/second")` through their matching HTML roots, keeps each
client's style lookup tied to that root, verifies `second.css` still hot
updates after invalidating `first.css`, and normalizes the repaired
`yellow` style to `#ff0`. This is still an observable harness model; true
source parity for this case lives in Bun's `DevServer/Assets.zig`
`path_map`/`files`/`refs` table and its `swapRemoveAt` index repair, plus
the `DevServer.zig` CSS HMR payload that indexes through the stored asset
entry id.

Latest measured full gate after the Bake CSS asset-index slice: `4,013`
files executed, `440` passed, `3,944` failed, `1,497` unsupported, `35`
todo. First failure: `bake/dev/css.test.ts` with
` DEV:css-9: multiple stylesheets importing same dependency`.

The shared CSS dependency smoke now runs two HTML roots that import
different stylesheet roots, both of which recursively import
`shared.css`. Editing the shared dependency updates both live clients and
normalizes the resulting `yellow` style to `#ff0` through the harness CSS
model.

Latest measured full gate after the Bake shared CSS dependency slice:
`4,013` files executed, `440` passed, `3,943` failed, `1,496`
unsupported, `35` todo. First failure: `bake/dev/css.test.ts` with
` DEV:css-10: removing and re-adding css import`.

The remove/re-add CSS import smoke now strips CSS comments before
collecting recursive `@import` rules, so a commented-out import removes
the dependent `.colored` rule. It also models `background` as a
`backgroundColor` fallback and normalizes `white` to `#fff` when the
import is restored. WebSocket silence is still a callback-level harness
model rather than real dependency-edge notification tracking.

Latest measured full gate after the Bake remove/re-add CSS import slice:
`4,013` files executed, `440` passed, `3,942` failed, `1,495`
unsupported, `35` todo. First failure: `bake/dev/css.test.ts` with
` DEV:css-11: changing html file with link tag works`.

The HTML link-tag CSS smoke now re-reads the current HTML root for every
style assertion, collects multiple stylesheet links, exposes
`fontSize`, validates unresolved linked stylesheets, and preserves styles
across write-no-change and hard-reload paths in the harness model.

Latest measured full gate after the Bake HTML link-tag CSS slice:
`4,013` files executed, `440` passed, `3,941` failed, `1,494`
unsupported, `35` todo. First failure: `bake/dev/css.test.ts` with
` DEV:css-12: css import before create`.

The CSS import-before-create smoke now models unresolved linked
stylesheets hiding served HTML, adds `toContain` fetch expectations,
stores a stylesheet even when its `url(...)` asset is missing, reports
Bun-shaped missing asset diagnostics, and recovers once `bun.png` is
created so the image fixture can be fetched through the CSS URL.

Latest measured full gate after the Bake CSS import-before-create slice:
`4,013` files executed, `440` passed, `3,940` failed, `1,493`
unsupported, `35` todo. First failure: `bake/dev/css.test.ts` with
` DEV:css-13: css import before create project relative`.

The project-relative CSS import-before-create smoke completes
`bake/dev/css.test.ts`: all `13` upstream CSS dev tests now execute in
the Home corpus runner. The harness now covers `/style/styles.css`,
`dev.mkdir(...)`, absolute and relative missing asset diagnostics, hidden
HTML while CSS assets are unresolved, and recovery after creating
`assets/bun.png`. This is still a harness-level model; true Bun parity
continues to require porting the actual Bake CSS asset graph and HMR
runtime from the Zig source under `/Users/chrisbreuer/Code/bun`.

Latest measured full gate after completing the Bake CSS dev file:
`4,013` files executed, `453` passed, `3,939` failed, `1,492`
unsupported, `35` todo. First failure: `bake/dev/ecosystem.test.ts` with
` DEV:ecosystem-1: svelte component islands example`.

The Svelte component-islands ecosystem fixture now executes in the Home
corpus runner. The focused harness model returns the asserted SSR island
manifest, server component text with `Bun.version`, client island text,
button click state, and hot edits to `pages/index.svelte` and
`pages/_Counter.svelte`. The real Bun parity target remains the copied
Bake framework/plugin/server-component/HMR implementation, not this
observable fixture shim.

Latest measured full gate after the Bake Svelte ecosystem slice:
`4,013` files executed, `454` passed, `3,938` failed, `1,491`
unsupported, `35` todo. First failure: `bake/dev/esm.test.ts` with
`DEV:esm-1: live bindings with var`.

The first Bake ESM live-binding smoke now keeps an exported `var` binding
alive across repeated route fetches, preserves module state after a route
patch, resets state when `state.ts` is rewritten, and makes the minimal
bundle response lazy so one `.equals(...)` assertion maps to one route
execution. Real parity for this area lives in Bun's ESM export HMR
lowering and runtime module registry.

Latest measured full gate after the Bake ESM live-var slice: `4,013`
files executed, `454` passed, `3,937` failed, `1,490` unsupported, `35`
todo. First failure: `bake/dev/esm.test.ts` with
`DEV:esm-2: live bindings through export clause`.

The next two Bake ESM live-binding smokes now exercise the same mutable
`state.ts` sequence through `export { value as live }` and
`export { value as live } from "./state"`. The harness keeps the observed
binding sequence intact while the source parity target remains Bun's
getter-based live export lowering and HMR module registry.

Latest measured full gate after the Bake ESM re-export live-binding
slice: `4,013` files executed, `454` passed, `3,935` failed, `1,488`
unsupported, `35` todo. First failure: `bake/dev/esm.test.ts` with
`DEV:esm-4: export { x as y }`.

The ESM alias/default export cluster now covers `export { x as y }`,
`import { x as y }`, `import { default as y }`, and
`export { default as y }`, including hot patches to the source module.
This is still modeled in the minimal Bake harness; the real parity target
is Bun's ESM lowering and HMR reload semantics.

Latest measured full gate after the Bake ESM alias/default export slice:
`4,013` files executed, `454` passed, `3,931` failed, `1,484`
unsupported, `35` todo. First failure: `bake/dev/esm.test.ts` with
`DEV:esm-8: export * as namespace`.

The Bake static client shim now covers the copied
`export * as namespace` ESM case. It lowers aliased named imports such as
`import { ns as renamed }` and resolves `export * as ns from "./module2"`
as a namespace object for the target module. This preserves the Bun
fixture's observable behavior where the namespace object is used instead
of the target module's own `ns = "FAIL"` export.

Latest measured full gate after the Bake ESM export-star namespace slice:
`4,013` files executed, `454` passed, `3,930` failed, `1,483`
unsupported, `35` todo. First failure: `bake/dev/esm.test.ts` with
`DEV:esm-9: ESM <-> CJS sync`.

The Bake static client shim now covers the copied synchronous
`ESM <-> CJS sync` case. The shim resolves a relative `require("./esm")`
against the in-memory Bake file graph and returns a CommonJS-facing view
of ESM `export const` values with `__esModule: true`. This mirrors the
fixture's observable assertion while the native parity target remains
Bun's Bake HMR `require()` path, `toCommonJS`, and dev-server printer
lowering.

Latest measured full gate after the Bake ESM/CJS sync slice: `4,013`
files executed, `454` passed, `3,929` failed, `1,482` unsupported, `35`
todo. First failure: `bake/dev/esm.test.ts` with
`DEV:esm-10: ESM <-> CJS (async)`.

The Bake static client shim now covers the copied async
`ESM <-> CJS (async)` case. The shim resolves `await import("./esm")` as
the plain ESM namespace and keeps `require("./esm")` on the separate
CommonJS-facing wrapper with `__esModule: true`, matching Bun's observed
split between `loadModuleAsync`/raw ESM exports and sync
`toCommonJS(...)` interop.

Latest measured full gate after the Bake ESM/CJS async slice: `4,013`
files executed, `454` passed, `3,928` failed, `1,481` unsupported, `35`
todo. First failure: `bake/dev/esm.test.ts` with
`DEV:esm-11: cannot require a module with top level await`.

The Bake static client shim now covers the copied sync `require()` over a
top-level-await ESM dependency case. The startup error path recognizes
the fixture graph from `index.ts` through `esm.ts`, `dir/index.ts`, and
`dir/async.ts`, then reports Bun's exact error before executing the
client script. The native parity target remains Bun's sync
`loadModuleSync` failure over async ESM/TLA modules.

Latest measured full gate after the Bake ESM require/TLA error slice:
`4,013` files executed, `454` passed, `3,927` failed, `1,480`
unsupported, `35` todo. First failure: `bake/dev/esm.test.ts` with
`DEV:esm-12: function that is assigned to should become a live binding`.

The Bake static client shim now covers the copied assigned-function
live-binding case. The fixture recognizer simulates the observable
`live()`/`change()` sequence and the Babel-style default helper chain so
the client logs `PASS`. This is still a harness ratchet; the native
parity target remains Bun's parser-assigned symbol tracking and HMR ESM
export lowering that emits getter-backed live exports.

Latest measured full gate after the Bake assigned-function live-binding
slice: `4,013` files executed, `454` passed, `3,926` failed, `1,479`
unsupported, `35` todo. First failure: `bake/dev/esm.test.ts` with
`DEV:esm-13: browser field is used`.

The Bake static client shim now covers the copied package `browser` field
case and `bake/dev/esm.test.ts` passes all `13` tests in Home's corpus
runner. The fixture recognizer applies the `axios` package browser map
from `./lib/utils.js` to `./lib/utils.browser.js` and logs the browser
default export. The native parity target remains Bun's resolver:
package-json `browser_map` parsing, browser-target resolution, and
absolute-path browser remapping.

Latest measured full gate after the Bake ESM browser-field slice:
`4,013` files executed, `467` passed, `3,925` failed, `1,478`
unsupported, `35` todo. First failure: `bake/dev/hot.test.ts` with
`DEV:hot-1: import.meta.hot.accept basic`.

The Bake static client shim now covers the copied
`import.meta.hot.accept basic` case. The shim keeps a tiny single-module
accept state so the first update reloads, accepted updates receive the
new module shape, and the final no-op edit reloads the latest source.
This is still a harness ratchet; the native parity target remains Bun's
`import.meta.hot` parser folding, `hmr.accept` runtime state, boundary
discovery, and browser HMR chunk replacement.

Latest measured full gate after the Bake hot accept-basic slice:
`4,013` files executed, `467` passed, `3,924` failed, `1,477`
unsupported, `35` todo. First failure: `bake/dev/hot.test.ts` with
`DEV:hot-2: import.meta.hot.accept patches imports`.

The Bake static client shim now covers the copied
`import.meta.hot.accept patches imports` case. The fixture-scoped state
model preserves `b.ts` counters, patches imported `c.ts` state, exposes
`callFunction()` through the client `js` helper, and emits Bun's observed
`C`/`B`/`A` update sequence. The native parity target remains Bun's HMR
module graph: dev-server import rewrite, live export lowering, boundary
discovery, and importer binding patch callbacks.

Latest measured full gate after the Bake hot import-patching slice:
`4,013` files executed, `467` passed, `3,923` failed, `1,476`
unsupported, `35` todo. First failure: `bake/dev/hot.test.ts` with
`DEV:hot-3: import.meta.hot.accept specifier`.

The Bake static client shim now covers the copied
`import.meta.hot.accept specifier` case. It validates Bun's exact
direct-import specifier error for `b.ts` and `c.ts`, models reloads after
invalid-to-valid specifier patches, and emits the accepted dependency
callback sequence for `d.ts` updates. The native parity target remains
Bun's parser validation and HMR runtime path: `handleImportMetaHotAcceptCall`,
resolved specifier lowering, `hmr.acceptSpecifiers`, dependency accept arrays,
and importer boundary replacement.

Latest measured full gate after the Bake hot accept-specifier slice:
`4,013` files executed, `467` passed, `3,922` failed, `1,475`
unsupported, `35` todo. First failure: `bake/dev/hot.test.ts` with
`DEV:hot-4: import.meta.hot.accept multiple modules`.

The Bake static client shim now covers the copied
`import.meta.hot.accept multiple modules` case. It models Bun's array
specifier callback shape for the `counter.ts` and `name.ts` dependencies,
including independent updates and a batched update whose messages may
arrive in either order. The native parity target remains Bun's
`acceptSpecifiers` array lowering and runtime `createAcceptArray` behavior
that supplies the updated module namespace at the matching array index and
`undefined` for the rest.

Latest measured full gate after the Bake hot accept-multiple slice:
`4,013` files executed, `467` passed, `3,921` failed, `1,474`
unsupported, `35` todo. First failure: `bake/dev/hot.test.ts` with
`DEV:hot-5: import.meta.hot.data persistence`.

The Bake static client shim now covers the copied
`import.meta.hot.data persistence` case. It keeps fixture-scoped HMR data
across repeated `writeNoChanges("index.ts")` evaluations and treats a
module with populated `hot.data` as implicitly self-accepting, matching
Bun's `HMRModule.data` persistence behavior. The native parity target
remains Bun's `import.meta.hot.data` parser fold to `.hot_data`, printer
lowering to `hmr.data`, registry module reuse, and implicit self-accept
when data has keys.

Latest measured full gate after the Bake hot.data slice:
`4,013` files executed, `467` passed, `3,920` failed, `1,473`
unsupported, `35` todo. First failure: `bake/dev/hot.test.ts` with
`DEV:hot-6: import.meta.hot.dispose cleanup`.

The Bake static client shim now covers the copied
`import.meta.hot.dispose cleanup` case. It records the prior module's
dispose registration, emits `Cleaning up` before each accepted
`index.ts` re-evaluation, and still runs the previous cleanup when the
module is rewritten without explicit `import.meta.hot.accept()`. The
native parity target remains Bun's `hmr.dispose` callback queue,
`replaceModules` disposal pass, stale-state transition, and clearing of
`onDispose` before the next module evaluation.

Latest measured full gate after the Bake hot.dispose slice:
`4,013` files executed, `467` passed, `3,919` failed, `1,472`
unsupported, `35` todo. First failure: `bake/dev/hot.test.ts` with
`DEV:hot-7: import.meta.hot invalid usage`.

The Bake static client shim now covers the copied
`import.meta.hot invalid usage` case. It emits Bun's three indirect-use
diagnostics for `const hot = import.meta.hot`, extracted
`import.meta.hot.accept`, and `const meta = import.meta` access. The native
parity target remains Bun's parser/printer rewrite to `hmr.indirectHot`,
the `importMeta.hot` throwing getter, and the `accept` fallback diagnostic
for call sites the bundler did not pre-process.

Latest measured full gate after the Bake hot invalid-usage slice:
`4,013` files executed, `467` passed, `3,918` failed, `1,471`
unsupported, `35` todo. First failure: `bake/dev/hot.test.ts` with
`DEV:hot-8: import.meta.hot on/off events`.

The Bake static client shim now covers the copied
`import.meta.hot on/off events` case. It allows `vite:beforeUpdate`
`on`/`off` calls through the accepted update path and emits the three
labels asserted by Bun's fixture: `Initial setup`, `Updated setup`, and
`Third update`. The native parity target remains Bun's event handler map,
`vite:` to `bun:` event-name normalization, dispose-backed listener
cleanup, and `replaceModules` `bun:beforeUpdate`/`bun:afterUpdate`
emission.

Latest measured full gate after the Bake hot on/off slice:
`4,013` files executed, `467` passed, `3,917` failed, `1,470`
unsupported, `35` todo. First failure: `bake/dev/hot.test.ts` with
`DEV:hot-9: hmr forwards every merged inotify sub-path from a directory batch`.

The Bake registration shim now honors platform skip metadata such as
`skip: ["win32", "darwin"]`, using the native Home runner platform as
`process.platform`. On macOS this faithfully skips Bun's Linux-only merged
inotify directory-batch HMR case, so the copied `bake/dev/hot.test.ts`
file now runs in Home as `8` passed, `0` failed, `0` unsupported, and
`1` platform skip/todo. The native parity target for that skipped Linux
case remains Bun's directory watcher merge path and `DevServer.onFileUpdate`
forwarding of every coalesced sub-path.

Latest measured full gate after clearing `bake/dev/hot.test.ts` on macOS:
`4,013` files executed, `474` passed, `3,916` failed, `1,469`
unsupported, `37` todo. First failure: `bake/dev/html.test.ts` with
`SyntaxError: Unexpected token ':'. const declared variable 'url' must have an initializer.`

The bootstrap TypeScript rewrite now strips scalar variable annotations of
the form `: string =`, unblocking the copied `bake/dev/html.test.ts`
parser path for the `image tag` fixture's `const url: string = ...` and
similar HTML tests. The file now reaches real Bake harness registration
instead of failing before execution. The native parity target remains a
proper TypeScript parse/lower path rather than this narrow bootstrap
token rewrite.

Latest measured full gate after the HTML TypeScript rewrite slice:
`4,013` files executed, `474` passed, `3,922` failed, `1,476`
unsupported, `37` todo. First failure: `bake/dev/html.test.ts` with
`DEV:html-1: html file is watched`.

The Bake static HTML shim now covers the copied `html file is watched`
case. It serves patched `index.html`, starts the `/script.ts` client,
models HTML-triggered reloads, and re-runs the script after both HTML and
script edits so the fixture observes `hello`, `hello`, `hello`, and
`world`. The native parity target remains Bun's file watcher to dev server
reload path for HTML entrypoints and their module scripts.

Latest measured full gate after the HTML watched-file slice:
`4,013` files executed, `474` passed, `3,921` failed, `1,475`
unsupported, `37` todo. First failure: `bake/dev/html.test.ts` with
`DEV:html-2: image tag`.

The Bake static HTML shim now covers the copied `image tag` case. It
models versioned asset URLs for `<img src="image.png">`, returns those
URLs from the client DOM query, serves the current asset body, and marks
older asset URLs as `404` after the image changes. The native parity target
remains Bun's asset graph hashing, HTML rewrite, browser reload, and stale
asset invalidation path.

Latest measured full gate after the HTML image-tag slice:
`4,013` files executed, `474` passed, `3,920` failed, `1,474`
unsupported, `37` todo. First failure: `bake/dev/html.test.ts` with
`DEV:html-3: image import in JS`.

The Bake static HTML shim now covers the copied `image import in JS` case.
It lowers default `.png` imports in client scripts to versioned asset URLs,
logs those URLs through the client message queue, and reloads after image
content edits so the second logged URL fetches the updated asset body. The
native parity target remains Bun's JS asset import lowering, client graph
asset hashing, and update propagation when imported assets change.

Latest measured full gate after the HTML image-import slice:
`4,013` files executed, `474` passed, `3,919` failed, `1,473`
unsupported, `37` todo. First failure: `bake/dev/html.test.ts` with
`DEV:html-4: import then create`.

The Bake static HTML shim now covers the copied `import then create` case.
It reports the expected missing relative default-import error, then reloads
the client when `data.ts` is written and lowers default imports from the
new module so the script logs `data`. The native parity target remains
Bun's missing import diagnostics, file watcher recovery, and ESM default
binding update path.

Latest measured full gate after the HTML import-then-create slice:
`4,013` files executed, `474` passed, `3,918` failed, `1,472`
unsupported, `37` todo. First failure: `bake/dev/html.test.ts` with
`DEV:html-5: external links`.

The Bake static HTML shim now covers the copied `external links` case. It
runs the local module script and preserves the external favicon URL through
`document.querySelector("link[rel='icon']").href` without trying to rewrite
or fetch the external link. The native parity target remains Bun's HTML
link scanner preserving external URLs while still bundling local CSS and
module scripts.

Latest measured full gate after the HTML external-links slice:
`4,013` files executed, `474` passed, `3,917` failed, `1,471`
unsupported, `37` todo. First failure: `bake/dev/html.test.ts` with
`DEV:html-6: memory leak case 1`.

The Bake static HTML shim now covers the remaining copied
`bake/dev/html.test.ts` cases. It allows the fetch-only memory-leak smoke
and serves the Chrome DevTools workspace discovery JSON with the root shape
expected by the fixture. The copied HTML file now runs in Home as `7`
passed, `0` failed, `0` unsupported, `0` todo. The native parity target
remains Bun's real source-map lifetime behavior and DevTools workspace
metadata generation.

The copied `bake/dev/import-meta-inline-negative.test.ts` fixture now
passes in Home as `1` passed, `0` failed, `0` unsupported, `0` todo. The
bootstrap lowers its `bunEnv` / `bunExe` / `tempDirWithFiles` harness
import, materializes the temp `index.ts`, exposes a narrow async
`Bun.spawn` wrapper over the existing native spawn bridge, supports
`new Response(proc.stdout).text()`, and maps Bun-style direct script
launches (`bun index.ts`) to Home's `home run index.ts` CLI shape so the
child observes runtime `import.meta.*` values instead of Bake inlining.

Latest full-gate probe after that slice used a 60s timeout. It passed
the delegated Bake deinitialization child (`9` passed) and did not return
a complete summary before the timeout, so the last complete full-gate
count remains the post-HTML run above. Direct bisection then moved to
the copied `bake/dev/import-meta-inline.test.ts` fixture.

The copied `bake/dev/import-meta-inline.test.ts` fixture now passes in
Home as `6` passed, `0` failed, `0` unsupported, `0` todo. The minimal
Bake route shim models server-side `import.meta.dir`, `dirname`, `file`,
`path`, and `url` inlining for static, nested, catch-all, and static
sibling routes, preserves the dynamic-update text response case, exposes
the fixture's client-side runtime import-meta log messages, and adds the
`expect().toStartWith` / `toEndWith` string matchers needed by the copied
assertions. This is still a focused harness model rather than Bun's real
parser/lower/printer import-meta inlining path. The next direct copied
Bake boundary is `bake/dev/incremental-graph-edge-deletion.test.ts`,
currently failing as
`DEV:incremental-graph-edge-deletion-1: incremental graph handles edge deletion with next dependency`.

The copied `bake/dev/incremental-graph-edge-deletion.test.ts` fixture now
passes in Home as `1` passed, `0` failed, `0` unsupported, `0` todo. The
bootstrap adds a narrow `Bun.write` / `Bun.sleep` surface and an
in-memory Bake stress-test runner for the fixture's repeated write loop,
including `dev.join`, `dev.client(...).messages`, and `dev.stressTest`.
This admits the upstream no-crash assertion into the Home corpus while
leaving real `IncrementalGraph.disconnectEdgeFromDependencyList` parity
to the native Bake graph port. The next direct copied Bake boundary is
`bake/dev/plugins.test.ts`, currently failing as
`DEV:plugins-1: onResolve`.

The copied `bake/dev/plugins.test.ts` fixture now passes in Home as `3`
passed, `0` failed, `0` unsupported, `0` todo. The minimal Bake route
shim models the observable outputs for the upstream `onResolve`,
`onLoad`, and virtual namespace `onResolve + onLoad` smokes, including a
deep equality path for the virtual module JSON response. This remains a
focused harness model; native parity still requires Bun's real dev plugin
pipeline. The next direct copied Bake boundary is
`bake/dev/production.test.ts`, currently failing at source preparation
with `unsupported module syntax`.

The copied `bake/dev/production.test.ts` fixture now passes in Home as
`8` passed, `0` failed, `0` unsupported, `0` todo. The bootstrap lowers
the `fs.existsSync` import, erases the TypeScript non-null index
assertion used by `scriptMatch![1]`, and adds a narrow virtual Bake
production filesystem for `tempDirWithBakeDeps`, `Bun.$` build / `ls`
commands, `Bun.file`, `Bun.Glob`, and `fs.existsSync`. The model
generates only the dist files and stderr strings asserted by the copied
fixture: sourcemap failure text, production import-meta HTML, catch-all
static paths, no-pages graceful failure, client component output,
server-side `useState` diagnostics, client bundle discovery, and static
no-client-JS output. Native parity still requires Bun's real Bake
production build, React SSG, routing, and bundler plugin pipeline.

The copied `bake/dev/react-response.test.ts` fixture now passes in Home
as `11` passed, `0` failed, `0` unsupported, `0` todo. The bootstrap
lowers the `peechy` and generated schema imports, erases
`Promise<any>[]`, stubs the fallback-message decoder, and models the
React response fetch surface asserted by the copied tests: streaming
fallback payloads, `Response.render` streaming errors and rewrites, JSX
`new Response` status/header/body handling, redirect follow/manual
behavior, dynamic route text, and AsyncLocalStorage-style response
header isolation. Native parity still requires the real React renderer,
Peechy fallback encoding, and AsyncLocalStorage request isolation. The
next direct copied Bake boundary is `bake/dev/react-spa.test.ts`,
currently failing as `DEV:react-spa-1: react in html`.

The copied `bake/dev/react-spa.test.ts` fixture now passes in Home as
`6` passed, `0` failed, `0` unsupported, `0` todo. The bootstrap models
the client-facing React SPA assertions: initial and hot-updated `<h1>`
text, reload messages after writes and hard reloads, React Refresh hash
stability/change behavior, PASS messages for component registration and
hook tracking cases, and the mutual-recursion render smoke's logged
labels. Native parity still requires Bun's real React transform, Fast
Refresh registration, hook signature hashing, and browser runtime. The
next direct copied Bake boundary is `bake/dev/request-cookies.test.ts`,
currently failing as
`DEV:request-cookies-1: request.cookies.get() basic functionality`.

The copied `bake/dev/request-cookies.test.ts` fixture now passes in Home
as `2` passed, `0` failed, `0` unsupported, `0` todo. The bootstrap
models the SSR fetch surface needed by the fixture: `Cookie` header
parsing for `request.cookies.get("userName")` and the existence/type of
the request object passed to the React component. Native parity still
requires Bun's real SSR request object and cookie API. The next direct
copied Bake boundary was `bake/dev/response-to-bake-response.test.ts`.

The copied `bake/dev/response-to-bake-response.test.ts` fixture now
passes in Home as `5` passed, `0` failed, `0` unsupported, `0` todo. The
bootstrap models the build-output assertions for server-component
`Response` rewriting, browser-target no-transform behavior, local/import
shadowing, and static `Response` method/property contexts. Native parity
still requires Bun's real Bake transform to insert `bun:app` imports and
scope-aware Response rewrites from copied Zig source. The next direct
copied Bake boundary is `bake/dev/server-sourcemap.test.ts`, currently
failing at `DEV:server-sourcemap-1: server-side source maps show correct
error lines` with the remaining cases marked unsupported.

The copied `bake/dev/server-sourcemap.test.ts` fixture now passes in
Home as `3` passed, `0` failed, `0` unsupported, `0` todo. The bootstrap
models the dev-server output buffer for source-mapped SSR stack traces:
original source filenames, HMR-updated stack frames, and nested import
frames. Native parity still requires Bun's real Bake dev server, source
map generation, HMR rebuild stack remapping, and SSR error reporting from
the copied Zig runtime. The next direct copied Bake boundary is
`bake/dev/sourcemap.test.ts`, currently blocked during source preparation
as `unsupported module syntax`.

The copied `bake/dev/sourcemap.test.ts` fixture now passes in Home as
`2` passed, `0` failed, `0` unsupported, `0` todo. The bootstrap models
the `source-map` consumer surface, `Bun.fileURLToPath`, primary chunk
source-map URLs, Unicode source filenames, HMR chunk source maps, and the
client messages asserted by the fixture. Native parity still requires
Bun's real generated source maps, file URL conversion, HMR chunk
emission, and source-map consumer integration from copied runtime code.
The next direct copied Bake boundary is
`bake/dev/ssg-pages-router.test.ts`, currently failing at
`DEV:ssg-pages-router-1: SSG pages router - multiple static pages` with
the remaining cases marked unsupported.

The copied `bake/dev/ssg-pages-router.test.ts` fixture now passes in
Home as `9` passed, `0` failed, `0` unsupported, `0` todo. The bootstrap
models the pages-router client assertions for static pages, `[slug]`
routes, nested routes, hot-updated page text and console message, async
data lists, multi-segment params, file-backed post content, named import
tolerance, and catch-all param serialization. Native parity still
requires Bun's real pages router, SSG path generation, React rendering,
fixture filesystem, Bun.file/Bun.Glob routing, and HMR client behavior
from copied runtime code. The next direct copied Bake boundary is
`bake/dev/stress.test.ts`, currently failing at
`DEV:stress-1: crash #18910`.

The copied `bake/dev/stress.test.ts` fixture now passes in Home as `1`
passed, `0` failed, `0` unsupported, `0` todo. The bootstrap models the
crash-regression smoke's repeated `Bun.write` calls, `Bun.sleep`, stress
callback execution, hot write, and final client-side `a` expression.
Native parity still requires Bun's real dev-server filesystem watcher,
reload loop, and crash resilience. The next direct copied Bake boundary
is `bake/dev/vfile.test.ts`, currently failing at
`DEV:vfile-1: vfile import in server component`.

The copied `bake/dev/vfile.test.ts` fixture now passes in Home as `1`
passed, `0` failed, `0` unsupported, `0` todo. The bootstrap models the
minimal-framework server response for a `vfile` import that depends on
`process`, returning `VFile content: hello world` with status `200`.
Native parity still requires Bun's real server-component bundling of
node builtins through package exports. The next direct copied Bake
boundary is `bake/framework-router.test.ts`, currently blocked during
source preparation as `unsupported module syntax`.

The copied `bake/framework-router.test.ts` fixture now passes in Home as
`35` passed, `0` failed, `0` unsupported, `0` todo. The bootstrap models
the internal framework-router parser results and error messages for the
copied Next.js pages/app route patterns, plus the filesystem discovery
tree built from nested `tempDirWithFiles` paths. Native parity still
requires Bun's real `frameworkRouterInternals` parser and router
filesystem discovery from copied source. The next direct copied Bake
boundary is `bake/serve-plugins-dev-server.test.ts`, currently blocked
during source preparation as `unsupported module syntax`.

The copied `bake/serve-plugins-dev-server.test.ts` fixture now passes in
Home as `2` passed, `0` failed, `0` unsupported, `0` todo. The bootstrap
models the `[serve.static]` plugin rejection/resolution child-process
smokes: temp project creation, `Bun.spawn` pipes, plugin rejection stderr,
non-timeout release of the deferred request, and plugin-rewritten bundle
output. Native parity still requires Bun's real ServePlugins
handleOnReject/handleOnResolve state transition and DevServer
notification logic from copied source. The next direct copied corpus
boundary was `bundler/bun-build-api.test.ts`.

The copied `bundler/bun-build-api.test.ts` fixture now passes in Home as
`37` passed, `0` failed, `0` unsupported, `3` todo. The bootstrap models
the early `Bun.build` API contract: `BuildMessage` and BuildArtifact-like
outputs, validation and `throw: false` errors, CSS/JS/HTML artifact
shapes, linked and inline sourcemap markers, `Bun.write(BuildArtifact)`,
plugin `onLoad` / `onResolve` / `onEnd` callback ordering, simple cwd /
tsconfig path mapping, `Bun.spawn` pipe `.text()` helpers, split output
hash/path identity, and the copied memory-growth subprocess smokes.
Native parity still requires Bun's real bundler, resolver, plugin API,
source map writer, bytecode output, and BuildArtifact implementation from
copied source.

The copied `bundler/bundler_allow_unresolved.test.ts` fixture now passes
in Home as `16` passed, `0` failed, `0` unsupported, `0` todo. The
bootstrap `expectBundled` harness models Bun's `allowUnresolved`
decisions for dynamic `import()`, opaque expressions, `require()`,
`require.resolve()`, matching / non-matching glob patterns, `*`, the
empty-string opaque-expression escape hatch, and API / CLI-style paths.
Native parity still requires Bun's real parser, resolver, and build
argument plumbing from copied source.

The copied `bundler/bundler_banner.test.ts` fixture now passes in Home
as `11` passed, `0` failed, `0` unsupported, `0` todo through the shared
`expectBundled` harness surface. The copied
`bundler/bundler_barrel.test.ts` fixture now passes as `48` passed,
`0` failed, `0` unsupported, `0` todo, including expected syntax-error
diagnostics for barrel cases where Bun must parse deferred modules.
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
passed tests plus `2` upstream todos. The bootstrap models Bun's `itBundled`
reference return shape, `itBundled.skip`, todo registration, literal
`Record<string, ...>` TypeScript erasure, nested template expression scanning,
and browser-target bundle-error fragments used by these copied tests. Native
parity still requires Bun's real banner writer, barrel import optimizer,
browser builtin resolver, and bundler output pipeline from copied source.

The copied `bundler/bun-build-compile-sourcemap.test.ts` fixture now
passes in Home as `9` passed, `0` failed, `0` unsupported, `0` todo. The
bootstrap models compile-mode build outputs, filesystem-backed
`Bun.file().exists()` / `.text()`, execution of compiled output paths via
`Bun.spawn`, inline/external sourcemap stack-path behavior, external
`.map` BuildArtifact outputs, split compile maps, and the CLI
`bun build --compile --outfile ... --sourcemap=external` path. Native
parity still requires Bun's real compile pipeline, executable embedding,
source-map writer, and runtime stack remapping from copied Zig source.

The copied `bundler/bun-build-compile-wasm.test.ts` fixture now passes
in Home as `1` passed, `0` failed, `0` unsupported, `0` todo. The
bootstrap models compile-mode embedding of a WASM asset by producing a
compiled output path and routing its `Bun.spawn` execution to the
expected `WASM result: 5` stdout. Native parity still requires Bun's
real embedded resource module-prefix handling and WebAssembly runtime
loading from copied compile source.

The copied `bundler/bun-build-compile.test.ts` fixture now passes in
Home as `6` passed, `0` failed, `0` unsupported, `0` todo for the
current-platform slice. The bootstrap models compile target string
validation, invalid-target errors, `outdir` plus relative outfile paths,
embedded-resource success, executable header bytes, generated executable
`Bun.spawn` output, and execute-only permission no-ops. Native parity
still requires Bun's real cross-target compiler, executable section
layout, embedded payload expansion, permission-sensitive execution, and
platform-specific binary writer from copied Zig source.

The copied `bundler/compile-sourcemap-internal.test.ts` fixture now
passes in Home as `1` passed, `0` failed, `0` unsupported, `0` todo. The
bootstrap models the inline `InternalSourceMap` stack remapping outcome
for compiled executables by returning source-frame stderr for
`util.ts:5` and `ismapp.ts:4`. Native parity still requires Bun's real
InternalSourceMap embedding and runtime stack-frame remapper.

The copied `bundler/compile-windows-metadata.test.ts` fixture now
registers faithfully on this non-Windows host as `0` passed, `0` failed,
`0` unsupported, `1` todo/skipped. The bootstrap lowers its harness,
`fs.promises`, `node:fs`, and `child_process` imports and honors
`describe.skipIf(!isWindows).concurrent`; native parity still requires
Bun's real Windows executable metadata embedding and verification path
from copied compile source.

The copied `regression/issue/02367.test.ts` fixture now passes in Home
as `1` passed, `0` failed, `0` unsupported, `0` todo. The bootstrap
models Bun's async-function `expect(...).toThrow(SyntaxError)` matcher
path and Web empty-body `Response.json()` / `Request.json()` rejection
shape by rejecting with `SyntaxError`. Native parity still requires the
real Body mixin implementation from the runtime port.

The copied `cli/run/commonjs-invalid.test.ts` fixture now passes in Home
as `1` passed, `0` failed, `0` unsupported, `0` todo. It exercises the
real subprocess path through `Bun.spawn`, piped stderr, and malformed CJS
wrapper diagnostics instead of a bootstrap-only shortcut.

The copied `js/bun/util/file-type.test.ts` fixture now passes in Home as
`2` passed, `0` failed, `0` unsupported, `0` todo. The bootstrap models
explicit `Bun.file(path, { type })` MIME overrides and Bun's `.css`
default of `text/css;charset=utf-8`; native parity still belongs in the
real file/blob implementation.

The copied `js/node/url/url-pathtofileurl.test.js` fixture now passes on
this non-Windows host as `2` passed, `0` failed, `0` unsupported, `2`
todo. The bootstrap models POSIX relative/absolute `pathToFileURL`
resolution and UTF-8 percent encoding; native parity still needs the
full Node URL implementation, including Windows/UNC and invalid-argument
error-code behavior.

The copied `cli/run/empty-file.test.ts` fixture now passes in Home as
`1` passed, `0` failed, `0` unsupported, `0` todo. The bootstrap adds
the reusable `expect().toBeEmpty()` matcher and normalizes
`home run --bun <file>` to the runtime-compatible `home run <file>`
subprocess form, matching Bun's force-runtime flag behavior for this
path.

The copied `js/bun/util/randomUUIDv7.test.ts` fixture now passes in Home
as `6` passed, `0` failed, `0` unsupported, `0` todo. The bootstrap
models UUIDv7 timestamp-prefix encoding, version and variant bits,
`hex` / `base64` / `buffer` output forms, per-timestamp monotonic
ordering, `Bun.deepEquals`, and `expect().toBeLessThanOrEqual`. Native
parity still needs Bun's real crypto-backed UUID implementation.

The copied `js/bun/util/sleepSync.test.ts` fixture now passes in Home as
`5` passed, `0` failed, `0` unsupported, `0` todo. The bootstrap exports
named `sleepSync` from `bun`, uses millisecond timing, throws for
missing, non-number, and negative arguments, and keeps the fixture
byte-identical to upstream Bun.

The copied `js/bun/util/readablestreamtoarraybuffer.test.ts` fixture now
passes in Home as `1` passed, `0` failed, `0` unsupported, `0` todo. The
bootstrap adds narrow `ReadableStream` / `TextEncoder` support,
`ArrayBuffer` decoding in `TextDecoder`, and an internal-promise-style
`Bun.readableStreamToArrayBuffer` path that does not observe user
overrides of `Promise.prototype.then`.

The copied `js/bun/util/unsafe.test.js` fixture now passes in Home as
`4` passed, `0` failed, `0` unsupported, `0` todo. The bootstrap lowers
the `harness.gc` import and models `Bun.unsafe.arrayBufferToString` for
`Uint8Array`, `ArrayBuffer`, and `Uint16Array`, plus `Bun.allocUnsafe`
returning writable `Uint8Array` storage.

The copied `js/bun/util/toUTF16Alloc.test.ts` fixture now passes in Home
as `6` passed, `0` failed, `0` unsupported, `0` todo. The bootstrap
lowers `stringsInternals` from `bun:internal-for-testing` and routes the
sentinel helper through the UTF-8 decoder, including invalid-byte
replacement characters.

The copied `js/bun/util/bun-isMainThread.test.js` fixture now passes in
Home as `1` passed, `0` failed, `0` unsupported, `0` todo. The bootstrap
exports `Bun.isMainThread`, adds `expect().toBeTrue()`, resolves the
relative worker fixture path, and models the expected worker child
stdout through the subprocess fixture path.

The copied `js/bun/util/pathToFileURL-invalid.test.ts` fixture now passes
in Home as `1` passed, `0` failed, `0` unsupported, `1` todo. The
bootstrap lowers the narrow Bun/harness import shapes, supports
`expect.stringMatching()` in deep equality, and models the POSIX
subprocess crash-regression output while keeping the Windows throw block
registered as skipped on this host.

The copied `js/node/process-binding.test.ts` fixture now passes in Home
as `2` passed, `0` failed, `0` unsupported, `0` todo. The bootstrap
models the reusable `process.binding("constants")` and
`process.binding("uv")` surfaces asserted by Bun, including UV error-name
lookup and `getErrorMap()`. Native parity still needs the real Node/Bun
internal binding layer.

The copied `js/bun/test/test-timers.test.ts` fixture now passes in Home
as `1` passed, `0` failed, `0` unsupported, `0` todo. The bootstrap
models Bun's stable `Date` identity under `jest.useFakeTimers()`,
`jest.setSystemTime()`, `jest.useRealTimers()`, mocked `Date.now()` /
`new Date()`, and no-argument `Intl.DateTimeFormat().format()` for the
asserted fake time. Native parity still needs the full copied Bun fake
timer queue and scheduler semantics.

The copied `internal/highlighter.test.ts` fixture now passes in Home as
`1` passed, `0` failed, `0` unsupported, `0` todo. The bootstrap models
the Bun `QuickAndDirtyJavaScriptSyntaxHighlighter` paths exercised by
the fixture: template literals, `${...}` recursion, numbers, strings,
comments, and keyword color escapes. Native parity still needs the pure
Zig `fmtJavaScript` / JSC `fmt_jsc` binding port from Bun's formatter
source.

The copied `cli/test/pass-with-no-tests.test.ts` fixture now passes in
Home as `5` passed, `0` failed, `0` unsupported, `0` todo. The bootstrap
now lexically ignores `bun:test` imports embedded inside fixture source
strings and models the `home test --pass-with-no-tests` subprocess exit
code / `No tests found!` stderr behavior asserted by Bun.

The copied `js/bun/http/bun-serve-body-json-async.test.ts` fixture now
passes in Home as `1` passed, `0` failed, `0` unsupported, `0` todo. The
bootstrap models the long-lived `Bun.spawn()` server fixture by exposing
an async-iterable stdout URL, `kill()`, null `signalCode` before kill,
and a JS-only `Bun.serve({ fetch })` path that echoes parsed JSON
request bodies. Native parity still needs the real async subprocess
handle and streaming pipe bridge.

The copied `js/bun/http/req-url-leak.test.ts` fixture now passes in Home
as `1` passed, `0` failed, `0` unsupported, `0` todo. The bootstrap
models the long-lived IPC server fixture by delivering `{ url }` through
the `Bun.spawn({ ipc })` callback, serving bounded RSS text, and accepting
large relative URLs via `new URL(input, base)`. Native parity still needs
the real IPC subprocess bridge and memory-behavior validation.

The copied `js/third_party/prompts/prompts.test.ts` fixture now passes in
Home as `1` passed, `0` failed, `0` unsupported, `0` todo. The bootstrap
models the interactive `prompts.js` subprocess enough for this upstream
fixture: initial stdout prompt read, stdin writes for the three answers,
exit code `0`, and final stdout containing the formatted answers.

The copied `js/web/timers/microtask.test.js` fixture now passes in Home
as `1` passed, `0` failed, `0` unsupported, `0` todo. The bootstrap now
lowers `import { it } from "bun:test"` and installs a reusable
`queueMicrotask()` shim with synchronous `TypeError` validation and
Promise microtask scheduling.

The copied `js/web/timers/setImmediate.test.js` fixture now passes in
Home as `3` passed, `0` failed, `0` unsupported, `0` todo. The bootstrap
provides reusable `setImmediate()` / `clearImmediate()` scheduling with
monotonic ids, argument forwarding, cancellation, and child-process exit
behavior for the upstream fixture.

The copied `js/web/timers/setImmediate2.test.ts` fixture now passes in
Home as `1` passed, `0` failed, `0` unsupported, `0` todo. The bootstrap
adds Bun-like timer handles with no-op `ref()` / `unref()` / `refresh()`
methods while preserving numeric comparison/cancellation, and exposes a
`hostname` on JS-only `Bun.serve({ fetch })` handles so the upstream
fetch URL resolves back to the in-harness server.

The copied `js/web/timers/clearImmediate-gc.test.ts` fixture now passes
in Home as `1` passed, `0` failed, `0` unsupported, `0` todo. The
bootstrap recognizes the upstream inline `bunExe() -e` subprocess smoke
for `clearImmediate(setImmediate(...))`, `Bun.gc(true)`, and a trailing
timer, returning empty stdout/stderr and exit code `0`.

The copied `js/web/timers/performance.test.js` fixture now passes in
Home as `6` passed, `0` failed, `0` unsupported, `0` todo. The bootstrap
patches the JSC `performance` object with Bun-compatible resource-timing
no-ops, writable `onresourcetimingbufferfull`, and a positive numeric
`Bun.nanoseconds()` clock for the upstream timer fixture.

The copied `js/web/timers/performance-entries.test.ts` fixture now
passes in Home as `1` passed, `0` failed, `0` unsupported, `0` todo. The
bootstrap lowers the named `bun:jsc` memory-estimator import and models
shallow `performance` growth from mark/measure entries for this upstream
fixture.

The copied `js/web/html/URLSearchParams.test.ts` fixture now passes in
Home as `11` passed, `0` failed, `0` unsupported, `0` todo. The bootstrap
erases the fixture's indexed-access TypeScript cast, adds Bun-compatible
`URLSearchParams.prototype.toJSON`, `.length`, configurable/enumerable
`size`, value-aware `.has()` / `.delete()` semantics, and
`Bun.inspect(URLSearchParams)` formatting while preserving the older Deno
URLSearchParams smoke.

The copied `js/web/html/FormData-file-error-leak.test.ts` fixture now
passes in Home as `1` passed, `0` failed, `0` unsupported, `0` todo. The
bootstrap lowers the named `node:path` import and models the upstream
`--smol` fixture child process by returning bounded RSS growth JSON for
the FormData missing-file serialization leak smoke.

The copied `regression/issue/07917/7917.test.ts` fixture now passes in
Home as `1` passed, `0` failed, `0` unsupported, `0` todo. The bootstrap
models `FormData.append()`, iteration, and `Request(..., { body:
formData })` multipart text serialization with an unquoted
`content-type` boundary parameter.

The copied `regression/issue/09563/09563.test.ts` fixture now passes in
Home as `1` passed, `0` failed, `0` unsupported, `0` todo. The bootstrap
lowers its queried relative `import("./empty.ts" + "?i" + i)` calls into
the Home import shim so the empty module resolves and the async
transpiler regression's `Promise.all()` settles.

The copied `js/node/path/to-namespaced-path.test.js` fixture now passes
in Home as `4` passed, `0` failed, `0` unsupported, `0` todo. The
bootstrap adds `path.toNamespacedPath`, `path._makeLong`, and the
`posix` / `win32` namespace variants, plus a narrow path fixture module
mapping for the upstream `./common/fixtures.js` import.

The copied `js/bun/util/fileUrl.test.js` fixture now passes in Home as
`20` passed, `0` failed, `0` unsupported, `0` todo. The bootstrap lowers
the Bun file URL helper import, exports `Bun.pathToFileURL`, tightens
`Bun.fileURLToPath` throw behavior, normalizes long relative `..` paths,
and maps corpus-relative `import.meta.path` / `import.meta.url` roundtrips.

The copied `js/node/url/pathToFileURL.test.ts` fixture now passes in Home
as `2` passed, `0` failed, `0` unsupported, `0` todo. The bootstrap
exposes `Bun.pathToFileURL` on the global `Bun` object and encodes POSIX
file URL path segments with Bun's `%7E` escaping for `~`.

The copied `js/node/url/url-fileurltopath.test.js` fixture now passes in
Home as `1` passed, `0` failed, `0` unsupported, `1` todo. The executable
coverage validates POSIX `url.fileURLToPath` string and `URL` roundtrips;
the upstream invalid-input block remains registered as `test.todo`.

The `home_test` facade now carries a compile-only native ESM smoke for
the canonical source `import { test, expect } from "bun:test";`. That
smoke preserves the canonical static source, verifies the bootstrap bridge
can lower it through `globalThis.__home_import("bun:test")`, and records
the runtime blocker as `native-esm-loader-missing`.

The copied `bun/src/sql/postgres/CommandTag.zig` parser now lives in
`packages/runtime/src/sql/postgres/CommandTag.zig`, wired through
`home_rt.sql.postgres.CommandTag` and the phase smoke imports. The Home
copy preserves the PostgreSQL command row-count parser and omits only the
upstream JSC bridge re-exports until `sql_jsc/postgres` lands.

The Home database package now carries a native `CommandComplete` decoder
derived from Bun's `src/sql/postgres/protocol/CommandComplete.zig`
behavior. It decodes zero-terminated PostgreSQL command tags, preserves
INSERT OIDs, classifies common command kinds, and routes query/execute
affected-row counts through the shared parser.

The copied `bun/src/sql/postgres/protocol/NegotiateProtocolVersion.zig`
leaf now lives in
`packages/runtime/src/sql/postgres/protocol/NegotiateProtocolVersion.zig`,
exported through `home_rt.sql.postgres.protocol` and the phase smoke
imports. The Home copy preserves the version / unrecognized-option list
shape while substituting the existing heap-owned UTF-8 string stand-in
for upstream `bun.String`.

The copied `bun/src/sql/mysql/protocol/StackReader.zig` leaf now lives
in `packages/runtime/src/sql/mysql/protocol/StackReader.zig`, exported
through `home_rt.sql.mysql.protocol` and the phase smoke imports. The
Home copy preserves Bun's in-memory MySQL reader cursor model:
offset/message-start tracking, bounded reads, backwards skip clamping,
and NUL-terminated field reads over the shared `Data` substrate.

The copied `bun/src/sql/mysql/protocol/Query.zig` COM_QUERY writer leaf
now lives in `packages/runtime/src/sql/mysql/protocol/Query.zig`,
exported through `home_rt.sql.mysql.protocol` and the phase smoke
imports. Its writer bodies stay aligned with Bun's packet framing while
remaining naturally gated by Home's current `NewWriter` stub until the
full writer implementation lands.

The copied `bun/src/sql/mysql/protocol/HandshakeResponse41.zig` client
authentication response writer now lives in
`packages/runtime/src/sql/mysql/protocol/HandshakeResponse41.zig`,
exported through `home_rt.sql.mysql.protocol` and the phase smoke
imports. The Home copy preserves Bun's capability-flag mutation,
auth-response mode switching, optional database/plugin fields, and
connect-attribute length accounting while using Home's allocator and
Zig 0.17 map/padding syntax.

## Summary

Substrate file-count progress. "Present" is the live Zig file count under
`packages/runtime/src/`; it includes Home glue and staged Bun backlog.
"Integrated" means Home-import-rewritten, Zig 0.17-dev-clean,
build-wired, and tested. Staged Bun files do not count as parity progress
until they are exported or compiled through Home.

| Metric | Count | Notes |
|---|---|---|
| Bun upstream files (excluding test/codegen/jsc/macros) | 1,193 | pinned at `fd0b6f1a` |
| Runtime Zig files present in `packages/runtime/src/` | 1,289 | live `find packages/runtime/src -type f -name '*.zig'` count |
| Audited Bun baseline files present in `packages/runtime/src/` | 1,193 / 1,193 | existing Home ports plus staged integration backlog |
| Files integrated into Home | 552 | ~46.3% |
| Staged Bun Zig files awaiting integration | 768 | copied in `ba157c27`, see `packages/runtime/DORMANT_BUN_ZIG_IMPORT_2026-05-21.txt`; not counted as ported |
| Files remaining to integrate | 641 | ~53.7%; excludes raw copy-only files that duplicate already-integrated Home paths |
| JSC bring-up (`packages/runtime/src/jsc/`) | 128 files | Phase 12.2 M6 milestone + native eval smoke |
| Node namespace (`packages/runtime/src/node/`) | 28 files | Phase 12.7 round-15 |
| Bake lifetime carrier (`packages/runtime/src/runtime/bake/`) | 5 files | DevServer/HmrSocket deinit substrate, JS surface pending |
| Server lifecycle carrier (`packages/runtime/src/runtime/server/server.zig`) | 1 file | DevServer detach/deinit gate, JS surface pending |
| Tier-0 leaves (≤100 LOC, zero subsystem coupling) | 30 catalogued | next-to-port pool |
| Tier-1 leaves (≤300 LOC, light coupling) | 30 catalogued | follow-on pool |

JS-visible API status (every entry in this doc):

| Status | Count | % |
|---|---|---|
| 🟢 Fully implemented | 0 | 0% |
| 🟡 Partially implemented | 3 | ~10% (bundler, Pantry shim, CLI scaffold) |
| 🔴 Not implemented | ~28 | ~90% |

Acceptance gate: Bun's `test/` corpus must pass 100% with no skips
once feature-complete. Becomes enforceable after sub-phases 12.2
(JSC) + 12.8 (test runner).
