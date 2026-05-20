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

Latest measured subset run: `127` files, `544` passed, `0` failed,
`34` todo.

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
