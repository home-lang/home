# Bun runtime parity

Detailed per-API status for Home's Bun-compatible runtime
(`packages/runtime/`). This is the drill-down view; the at-a-glance
row is in the
[README parity status](../README.md#bun-runtime-port-packagesruntime)
section.

> **Status:** Substrate + JSC M6 landed. 492 / 1,193 Bun source
> files ported (~41.2%); the runtime is not yet JavaScript-callable
> end-to-end, but Phase 12.2 (JSC bring-up) has reached the M6
> milestone — JSON + Promise + Iterator + Global helpers — across
> 97 files in `packages/runtime/src/jsc/`, including a live
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
| 12.2 | `jsc/`, `bun.js.zig`, `jsc_stub.zig` | `src/jsc/` | 🟡 M6 milestone + native eval smoke landed (97 files: JSON + Promise + Iterator + Global helpers + `JSEvaluateScript` + `JSObjectMakeDeferredPromise`) |
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
and `Bun.spawn` remain unported.

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

🔴 Not implemented.

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
--bun-corpus-native-subset=minimal-js` executes one hundred twenty-seven allowlisted JS
or plain-syntax TS corpus files through Home's JSC evaluator when
`home` is built with `./pantry/.bin/zig build -Denable_jsc=true`: the
todo-registration smoke, the Web `atob`/`btoa` smoke, twenty-three
regression smokes, one bundler constant-fold smoke, one bun-types `test.each` type-shape smoke, six test-runner
expectation smokes, one nested-describe smoke, two `expectTypeOf` type-only smokes, a narrow `Bun.TOML.parse` throw smoke, `Bun.stripANSI` and
`Bun.wrapAnsi`, `Bun.semver.satisfies`, and `bun:internal-for-testing` regexp / PowerShell escaping smokes, retry/repeats runner behavior, `test.concurrent.each`, `expect().pass`, a narrow `mock.clearAllMocks` / `toHaveBeenCalledTimes` smoke, a narrow `jest.fn` / `HTMLRewriter` element-callback smoke, a narrow TypeScript constructor-modifier rewrite smoke, narrow `assert` / `assert/strict`, `node:path`, `node:url`, and relative CJS fixture smokes, a narrow inline-snapshot Unicode object formatting smoke, a `node:vm.runInNewContext` / `process.on` throw propagation smoke, Deno harness `test(options, fn)` / permission skip / `test.ignore` / `test.todo` call-shape parity, Deno `Event` / `CustomEvent` / `AbortController`, and a Deno `URLSearchParams` bootstrap smoke, plus narrow bootstrap coverage for Node `DOMException`, Web
`Response.json` / `Response.redirect`, Web `Request` cache/mode/clone
and Deno Request string-body `text()` / clone call shapes,
narrow Deno URL authority/hash/origin parsing, a Deno `performance`
bootstrap nucleus (`now`, `timeOrigin`, `toJSON`, marks, measures, and
entry lookup), WebSocket failed-connect `ErrorEvent` snapshots, JSC
`ShadowRealm`, native constructor identity, mutable
`globalThis` prototype behavior, a comment-only module-load smoke, Bun file metadata, Node `Buffer`
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
`RangeError`s, `jest.mock` argument validation, `it.each` /
`describe.each` synchronous table expansion with done-callback injection,
`node:url.domainToASCII` / `domainToUnicode` invalid-punycode handling,
`import.meta.resolve` / `resolveSync` bad-parent throw behavior,
`jest.resetAllMocks` / `mockReturnThis`, `node:path` isAbsolute and
zero-length string behavior plus basename/extname/normalize/join/dirname,
parse/format, resolve, relative path table coverage, and path namespace
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
expectation-object matchers, plus one snapshot `test.todo` fixture whose
snapshot body remains intentionally unexecuted. The bootstrap harness is installed once
per JSC engine, resets counters before each file, lowers supported
`bun:test` imports through a virtual
`globalThis.__home_import("bun:test")` module shim, and fails closed as
unsupported for unsupported import shapes, unsupported module syntax,
async tests or hooks, explicit unsupported shim paths, and files that
register zero tests. Native ESM `bun:test` registration remains blocked
on a narrow JSC module-loader bridge, so this is deliberately not the
acceptance gate.

Latest measured subset run: `125` files, `537` passed, `0` failed,
`32` todo.

The unfiltered command `home test packages/runtime/test/bun-corpus` now
uses the same Home-native JSC bootstrap instead of the retired
`native-js-test-runner-missing` placeholder. It currently executes all
4,013 discovered Bun test files and fails on the first real failing
file. The native `Bun.spawnSync` bridge now starts the Bake child
process, and delegated `home test <fixture>` corpus descendants now route
back through the same JSC bootstrap instead of Home's parser. The current
first blocker is that the child fixture still exits `1` while Bun expects
`0`, because the Bake fixture now reaches the bootstrap runner's async
test boundary and reports `Async tests are not supported by the Home Bun
corpus bootstrap runner yet`. The exact `bun:internal-for-testing`,
`bun:jsc`, and fixture HTML imports are lowered. The Zig-side Bake
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
Bake HTML-route shape; it allocates a real DevServer/Server carrier and
routes `server.stop()`, hosted `fetch`, and HMR WebSocket open/close
through the native lifecycle path. The bootstrap also lowers the
`node:fs` sync imports used by Bake tests and forwards utf8
`writeFileSync` / `readFileSync` / `realpathSync` plus `renameSync` /
`unlinkSync` calls to native Home host callbacks. The delegated
`bake/fixtures/deinitialization/test.ts` child now passes all nine cases.
Exact Bake harness imports for `./bake-harness` and `../bake-harness`
now lower to a virtual registrar copied from Bun's no-color test-name
shape. It records ` DEV:<basename>-<count>: <description>` and
`PROD:<basename>-<count>: <description>` entries as unsupported without
executing `options.test`, so the corpus can account for each Bake test
registration while still failing honestly at the unported DevServer /
bundler runtime boundary.

Latest measured full gate after the WebSocket ErrorEvent nucleus:
`4,013` files executed, `408` passed, `3,984` failed, `1,537`
unsupported, `35` todo. First failure: `bake/dev-and-prod.test.ts`
with the named unsupported Bake registration for
` DEV:dev-and-prod-1: define config via bunfig.toml`.

The `home_test` facade now carries a compile-only native ESM smoke for
the canonical source `import { test, expect } from "bun:test";`. That
smoke verifies the source is not lowered through the bootstrap
`globalThis.__home_import("bun:test")` rewrite path and records the
runtime blocker as `native-esm-loader-missing`.

## Summary

Substrate file-count progress (the only objective number today):

| Metric | Count | Notes |
|---|---|---|
| Bun upstream files (excluding test/codegen/jsc/macros) | 1,193 | pinned at `fd0b6f1a` |
| Files ported to `packages/runtime/src/` | 492 | ~41.2% |
| Files remaining to port | 701 | ~58.8% |
| JSC bring-up (`packages/runtime/src/jsc/`) | 97 files | Phase 12.2 M6 milestone + native eval smoke |
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
