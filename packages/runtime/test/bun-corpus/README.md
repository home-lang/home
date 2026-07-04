# Bun test corpus (Phase 12 acceptance gate substrate)

Verbatim mirror of `~/Code/bun/test/` at the pinned upstream SHA recorded in
`UPSTREAM_SHA.txt`. The test corpus pin intentionally tracks the executable Bun
suite independently from the runtime source audit pin in
`packages/runtime/UPSTREAM_SHA.txt`. This is the **substrate** for the runtime
acceptance gate in `packages/runtime/README.md`: once the Home runtime is
feature-complete it must pass 100 % of these tests on macOS, Linux, and the WASM
target.

## Status

- **Not wired into `zig build test`.** Staged only; wiring lands alongside the
  Phase 12.8 test-runner copy.
- `home test packages/runtime/test/bun-corpus/` is the full acceptance gate and
  must keep failing until Home can execute 100 % of this corpus natively. It
  now walks every discovered Bun test file through Home's native JSC
  bootstrap and reports the first real unsupported/failing file. The 2026-07-04
  resync to `4982b91e3702094330f3be3883354c52b8c01323` discovers `4,708`
  Bun-style test files. A separate
  bootstrap path exists for the current allowlist:
  `home test packages/runtime/test/bun-corpus --bun-corpus-native-subset=minimal-js`
  after building `home` with `./pantry/.bin/zig build -Denable_jsc=true`.
  Latest measured subset run: `405` files, `3,194` passed, `0` failed,
  `184` todo. That subset currently executes the todo-registration smoke, three Node
  `assert` CommonJS smokes, the full Node `path` corpus slice, six Node `url` smokes, Deno
  event/fetch/crypto platform smokes, the Web
  `atob`/`btoa` smoke, sixty-four regression smokes, one bundler
  constant-fold smoke, bundler function-toString `require()`
  preservation, bundler `allowUnresolved`, bun-target/sqlite coverage,
  banner, barrel, expanded Bake dev/deinitialization, bundler comments, CLI run/spawn stdin,
  browser-target builtin diagnostics, CJS, CJS-to-ESM, compile-autoload,
  compile-splitting, compile standalone smokes, decorator metadata,
  plugin defer coverage, drop/env/footer, HTML server,
  minify-symbol, npm, Promise.all dead-code, regression, process `execArgv`,
  plugin exception, and transpiler decorator / use-strict / template-literal
  smokes, one bun-types
  `test.each` type-shape smoke, ten test-runner expectation smokes, one nested-describe
  smoke, two `expectTypeOf` type-only smokes, a narrow `Bun.TOML.parse` throw smoke, `Bun.stripANSI`, `Bun.wrapAnsi`, `Bun.semver.satisfies`, and
  `bun:internal-for-testing` regexp / PowerShell escaping smokes, retry/repeats runner
  behavior, `test.concurrent.each`, `expect().pass`, `expect().toBeEmpty`, a narrow `mock.clearAllMocks` /
  `toHaveBeenCalledTimes` smoke, a narrow `jest.fn` / `HTMLRewriter`
  element-callback smoke, a narrow TypeScript constructor-modifier
  rewrite smoke, narrow `assert` / `assert/strict`, `node:path`, `node:url`
  including POSIX `pathToFileURL`, Bun file URL helper conversion, Node `fileURLToPath` POSIX roundtrips, path `toNamespacedPath` / `_makeLong` / `matchesGlob`, long-CWD POSIX resolution subprocess coverage, and relative CJS fixture smokes, a narrow inline-snapshot Unicode object
  formatting smoke, Node console/watch/worker/fs/dns/readline one-shot smokes, a WebSocket
  close-reentrancy smoke, a `node:vm.runInNewContext` / `process.on` throw
  propagation smoke, JSONC and `bun.lock` resolution smokes,
  `Bun.write` leak coverage, HTTP leak/header smokes,
  `dns.lookup` keepalive coverage,
  `process.binding("constants")` /
  `process.binding("uv")` smoke coverage, `process.constructor.call`
  prototype-shape coverage, Jest fake-timer Date /
  `Intl.DateTimeFormat` smoke coverage plus the upstream Bun
  fake-timers and focused sinon issue corpus,
  `bun:internal-for-testing.highlightJavaScript` template-literal and
  utility highlighter coverage, a long-running Node util inspect regression,
  imported Jest-global fixture registration, default class export
  static-initializer coverage,
  `home test --pass-with-no-tests` subprocess coverage,
  JS-only `Bun.serve({ fetch })` / long-lived server-fixture `Bun.spawn` coverage,
  IPC-style server-fixture URL delivery and `new URL(input, base)` coverage,
  interactive third-party prompts stdin/stdout coverage,
  `queueMicrotask` ordering and argument validation,
  `setImmediate` / `clearImmediate` scheduling and cancellation,
  `setImmediate` interaction with JS-only `Bun.serve` / fetch,
  inline `clearImmediate(setImmediate(...))` subprocess GC coverage,
  Performance resource-timing no-ops and `Bun.nanoseconds`,
  Web `Blob.arrayBuffer()` copy-on-write, `Blob.slice().arrayBuffer()`,
  array fast-path, typed-array, nested-Blob, sparse-array, prototype
  indexed-getter, and non-ASCII text coverage,
  Web `URLSearchParams` Bun-extension coverage,
  FormData missing-file serialization leak subprocess coverage,
  FormData-backed `Request` multipart serialization with unquoted
  boundary parameters,
  Web `Response.clone()` and `Request` clone construction preserving
  method, headers, body text, and unlocked stream-backed bodies,
  the Bun install `architecture-match` helper corpus through Pantry's
  Bun-compatible CPU/OS package-eligibility matcher,
  `bun:jsc.estimateShallowMemoryUsageOf(performance)` entry-growth coverage, Deno `performance`, Deno `Event` / `CustomEvent` /
  `AbortController`, a Deno `URLSearchParams` bootstrap smoke, and narrow bootstrap coverage for Node
  `DOMException`, Web `Response.json` / `Response.redirect`, Web `Request`
  cache/mode/clone, repeated `Request.json()` string-body parsing,
  fetch body async-iterator and abort smokes,
  AbortController GC reason, MessagePort context cleanup, JSC `ShadowRealm`,
  native constructor identity, mutable
  `globalThis` prototype behavior, a comment-only module-load smoke, Bun file metadata,
  `Bun.file(...).type` MIME behavior, file-backed `Bun.file().size` /
  `slice().text()`, `Bun.randomUUIDv7` /
  `Bun.sleepSync` millisecond timing and validation /
  `Bun.readableStreamToArrayBuffer` queued chunk draining /
  `ReadableStreamDefaultController.desiredSize` close/error/failed-`pipeTo()`
  cleanup / `Bun.unsafe.arrayBufferToString` and `Bun.allocUnsafe` /
  `node:fs` / `node:fs/promises` exists/stat directory checks /
  missing-command `child_process.execFileSync` / `execSync` error serialization /
  `stringsInternals.toUTF16AllocSentinel` UTF-8 replacement behavior /
  `Bun.isMainThread` worker stdout smoke /
  Bun `pathToFileURL` invalid-host subprocess smoke /
  `Bun.deepEquals`, Node `Buffer`
  binary/UTF-16LE/compare/inspect-limit/isEncoding behavior, `Map`/`Set` deep-equality,
  lifecycle hooks, conditional skip helpers, broader todo registration, type-only `expectTypeOf`
  doctests, and additional sync fixture lifecycle smokes,
  `Bun.inspect` Set formatting, `MessageEvent` constructor
  behavior, Bun version aliases, own-key matchers, a `prepareStackTrace`
  crash smoke plus a non-empty filename regression, Web empty-body
  `Response.json()` / `Request.json()` SyntaxError matching, four sync runner
  fixture smokes (`only-fixture-4`, `21177`, `5738`, and printing dots),
  broader Web `TextEncoder` / `TextDecoder` and Deno encoding smokes,
  Node `module.SourceMap`, and a JSC string atomization smoke through
  `Bun.jest(import.meta.path)` plus a narrow `structuredClone` fallback,
  CommonJS invalid-wrapper and empty-file subprocess smokes, `mock.module`
  validation and mocked dynamic-import routing, queried relative dynamic
  imports for the empty async-transpiler regression fixture,
  CommonJS re-export and bare dynamic import interop for the upstream
  `abort-controller` fixture, third-party
  `yargs/yargs` CommonJS function require coverage, third-party
  `jsonwebtoken` default-import decode/sign/verify and compact-token
  header/encoding plus missing-secret validation coverage, `Bun.file().exists()`
  with real corpus/temp-file write/unlink coverage, `bun:test`
  `xit`/`xtest`/`xdescribe` alias coverage through spawned tests,
  `mock()` / `spyOn()` disposable cleanup with `mockReturnValue` and
  `Symbol.dispose`, Node `util.inspect` / `util.format` /
  `util.formatWithOptions` object, numeric-separator, circular-reference,
  error-cause, and proxy-safe formatting coverage, `Bun.Transpiler().transformSync()`
  parser-crash regression coverage for class-field ZWJ/ZWNJ and invalid
  identifier diagnostics, current compile-mode
  Bun.build smokes, the bundler minify corpus smoke, broader bundler edgecase /
  naming / string coverage, CSS modules plus WPT background/color/relative-color coverage, and
  esbuild css / dce / default / importstar / loader / lower / packagejson /
  splitting / ts / tsconfig coverage, and FormData set/append/get/delete plus
  File-backed multipart serialization. It is only a smoke path for JSC + `home_test`; it is not the
  release gate. The bootstrap harness is installed once per JSC engine, resets
  counters before each file, lowers named `bun:test` imports through a
  virtual `globalThis.__home_import("bun:test")` module shim, and fails closed
  as unsupported for unsupported module syntax,
  async tests or hooks, explicit unsupported shim paths, and files that
  register zero tests. The bootstrap now exposes a native
  `Bun.spawnSync({ cmd, cwd, stdio })` bridge for real OS subprocesses,
  corpus-relative cwd/path resolution, and pipe/inherit/ignore stdio
  modes. The pre-refresh full gate reached the Bake child process and then
  failed because delegated `home test <fixture>` corpus descendants re-entered
  the corpus JSC bootstrap, lowered the exact child `bun:internal-for-testing`,
  `bun:jsc`, and HTML imports, and then reported the Bake fixture as
  `Async tests are not supported by the Home Bun corpus bootstrap runner yet`.
  The current corpus needs a fresh full-gate measurement after the larger
  resync; the refreshed `js/bun/jsonc/jsonc.test.ts` file passes directly as
  `14` tests through `home test`.
- No source renames. `Bun.serve`, `Bun.write`, `Bun.spawn`, etc. appear
  verbatim. The `Bun.* -> Home.*` rename happens at **test-runtime** (via the
  host runtime's surface aliasing), not at copy time, so the corpus stays a
  clean diff against upstream and re-syncs cleanly.
- Tests marked `bun-only` (e.g. macOS Bonjour) are preserved verbatim and must
  pass — no skipping at the gate.

## What was filtered out of the copy

The sync script keeps runtime fixtures verbatim, including binary assets such
as `.png`, `.wasm`, `.gif`, `.mp4`, and `.zip`. It drops generated/cache
outputs and platform binaries that are not source fixtures: `node_modules/`,
`.zig-cache/`, `.bun-cache/`, `coverage/`, `dist/`, `*.log`, `.DS_Store`,
`*.exe`, `*.dylib`, and `*.so`.

`FILTERED_FILES.txt` is regenerated by `scripts/sync-bun-tests.sh` and lists
the exact files intentionally not copied from the pinned Bun checkout. At the
current pin, the omitted source fixture is a README excluded by the corpus sync
filters.

Nested `node_modules/` under `fixtures/` are kept on disk (test inputs) but
excluded from git by the repo's global rule — re-run the sync after a fresh
clone to restore them.

## Re-sync

```sh
./scripts/sync-bun-tests.sh
```

The script verifies `~/Code/bun` HEAD matches the pinned SHA and aborts if not.
Override the Bun checkout location with `BUN_REPO=/path/to/bun`.
