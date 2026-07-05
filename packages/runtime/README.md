# Home Runtime (`packages/runtime/`)

> **Status (2026-05-21):** `packages/runtime/src/` currently contains
> **1,289 Zig source files**. Of the audited **1,193-file Bun baseline**,
> **552 files are integrated into Home (~46.3%)**: Home-import-rewritten,
> Zig 0.17-clean, build-wired, and tested.
> Phase 12.2 (JSC bring-up) has reached the M6 milestone — JSON + Promise
> + Iterator + Global helpers across 128 files. Phase 12.7 round-15
> has top-level `node:*` substrate modules for `buffer`, `stream`,
> `fs`, `events`, `util`, `assert`, `os`, `url`, `querystring`, and
> `crypto`, `process`, `string_decoder`, and `tty`. End-to-end
> `home run app.ts` waits
> on the JS-callable JSC bridge to wire up. Detailed per-area status:
> [`docs/PARITY-BUN.md`](../../docs/PARITY-BUN.md) and
> [`docs/PARITY-NODE.md`](../../docs/PARITY-NODE.md). Live recount:
> `scripts/measure-parity.sh --values`.

This package is Home's JavaScript / TypeScript runtime, equivalent to Bun in surface area. Once complete, `home run app.ts`, `home test`, `home x <pkg>`, `home build src/index.ts --target=native`, `home add <pkg>`, etc. all work natively, with package management deferring to Pantry (`~/Code/pantry`).

## Hard rules for every copy

1. **Zig 0.17 dev compatibility is non-negotiable.** Every copied file must compile under Pantry-managed `0.17.0-dev.263+0add2dfc4`. Bun upstream targets a more recent Zig; some files use APIs that moved between 0.16 → 0.17 (e.g. `std.array_list.Managed(T)` is 0.17+, `std.heap.stackFallback` was relocated, `std.io.fixedBufferStream` was removed in favor of `std.Io.Writer.fixed`, `Child.init` was replaced by `process.spawn`). Files that don't compile under 0.17 must be tracked as integration blockers with a `// Zig 0.17 compat: ...` note near the blocked import or adapter; they do not count as integrated until the adapter lands and the file is build-wired.
2. Verify `git -C ~/Code/bun rev-parse HEAD` matches `UPSTREAM_SHA.txt` before copying runtime source. Test-corpus syncs use `test/bun-corpus/UPSTREAM_SHA.txt` instead, so the executable Bun suite can track the local Bun checkout independently while source ports keep their own audit anchor.
3. Rewrite `@import("bun")` → `@import("home_rt")` and every `bun.X` → `home_rt.X` at copy time. **No semantic edits in the same commit.**
4. Drop JSC-bridge re-exports (`.toJS`, `.fromJS`, `Bun__X` externs) with a `// JSC-bridge X omitted — re-lands in Phase 12.2` note.
5. Every copied file must add **at least one** inline `test "..."` that exercises a method or invariant.
6. After integrating: run `./pantry/.bin/zig build test --summary all` AND `home test` in `~/Code/Apps/settlers-iii`. Both must stay green; commit only if so.

The 2026-05-21 bulk import is deliberately different: it staged the
remaining filtered Bun Zig source in `src/` without overwriting
integrated Home ports. Those files are tracked in
`DORMANT_BUN_ZIG_IMPORT_2026-05-21.txt` as an integration backlog only:
they do not count as ported until they go through the rules above and
are exported, build-wired, and tested.

## Upstream pin

`UPSTREAM_SHA.txt` holds the exact Bun commit the runtime source port is anchored against. Today: `fd0b6f1a271fca0b8124b69f230b100f4d636af6` (`http: port fetch TCP keepalive to on_open in lib.rs`). The Bun test corpus has its own pin at `test/bun-corpus/UPSTREAM_SHA.txt`.

## Why local copy and not vendoring

Per user direction: "build it natively as if it was ours, bc bun is MIT code." Bun is MIT-licensed, so we can copy. The flattening convention:

- Copied subsystem directories live directly under `src/` (e.g. `src/cli/`, `src/install/`, `src/jsc/`, `src/event_loop/`, `src/web/`, `src/home/`, `src/node/`).
- The aggregator `src/home_rt.zig` re-exports everything so subsystems can `@import("home_rt")` without coupling to Bun's namespace.
- JS-visible APIs go under `Home.*` (Bun's `Bun.*` namespace becomes `Home.*` for runtime callers); the Zig aggregator stays `home_rt` to avoid colliding with `home.runtime` which is reserved for native Home callers.

## Pantry replaces `bun install`

`bun install` is not copied. `home add <pkg>` / `home install` / `home remove` / `home update` route through the Pantry CLI at `~/Code/pantry`, which is Home's package manager and registry. The Pantry CLI is independently maintained; Home talks to it via a thin Zig shim.

## Acceptance gate — Bun test suite must pass 100 %

Per user direction (2026-05-17): once the runtime copy is feature-complete, Home must pass **the entire Bun test suite, no exceptions**. Concretely:

1. Copy `~/Code/bun/test/` into `packages/runtime/test/bun-corpus/` at the pinned SHA.
2. `home test packages/runtime/test/bun-corpus/` must produce zero failures on macOS, Linux, and the WASM target.
3. The corpus stays verbatim on disk. `Bun.*` APIs are provided by Home's Bun-compat runtime surface at test-runtime, not rewritten at copy time.
4. Any test that the corpus marks as `bun-only` (e.g. macOS Bonjour specifics) is preserved verbatim and must pass — no skipping.
5. CI gate is `home test packages/runtime/test/bun-corpus/ --bail=0 --reporter=junit --reporter-outfile zig-out/bun-corpus.junit.xml`. A regression on any case blocks merge.

This is the hard release gate for Phase 12. Substrate is in place today; the
gate becomes enforceable after Phase 12.2 (JSC bring-up) and Phase 12.8 (test
runner copy). Until then, `home test packages/runtime/test/bun-corpus/` must
fail as a native Home gate, not silently delegate to system Bun.
The gate's corpus discovery and test-file classification live in
`packages/home_test/src/corpus.zig`, which keeps this path inside Home's Zig
packages while the execution engine is still blocked.

## What's here today

- `src/home_rt.zig` — aggregator that re-exports every ported subsystem.
- `src/jsc/` — 128 files; Phase 12.2 milestones M1-M6 plus the first
  native `JSEvaluateScript` helper and the public
  `JSObjectMakeDeferredPromise` deferred-promise constructor bridge.
  Default tests compile the surface; run
  `./pantry/.bin/zig build test -Dfilter=home_rt -Denable_jsc=true` for
  a live `1 + 2` evaluation through JavaScriptCore.
- `src/node/` — 28 files; Phase 12.7 round-15 (top-level `assert.zig`, `buffer.zig`, `crypto.zig`, `events.zig`, `fs.zig`, `os.zig`, `path.zig`, `process.zig`, `querystring.zig`, `stream.zig`, `string_decoder.zig`, `tty.zig`, `url.zig`, `util.zig`, plus binding/helper files: `Stat`, `StatFS`, `dir_iterator`, `fs_events`, `os_constants`, `nodejs_error_code`, `node_fs_constant`, `node_net_binding`, `node_error_binding`, `uv_signal_handle_windows`, `types`, `time_like`, `util/parse_args_utils`, `assert/myers_diff`).
- `src/cli/` — destination for Bun's `src/cli/` command dispatch (Phase 12.10 scaffold landed).
- `src/runtime/bake/` — Bake DevServer/HmrSocket lifetime carrier copied
  from Bun and made Zig 0.17-clean. This covers the deinit counter,
  active route viewer release, source-map ref release, and active
  websocket snapshot-before-close invariants; the JS-visible
  `Bun.serve`/Bake API is still pending.
- `src/runtime/server/server.zig` — server lifecycle carrier for the
  Bun.serve/Bake teardown gate: pending requests, listener state, and
  active websockets must all clear before a DevServer is detached and
  deinitialized.
- `src/install/` — `home <-> pantry` shim. Pantry replaces `bun install` entirely.
- `src/event_loop/`, `src/io/`, `src/async/`, `src/web/`, `src/http/`, `src/runtime/`, `src/string/`, `src/threading/`, `src/css/`, `src/sql/`, `src/uws_sys/`, … — 85 subsystem directories under `src/`, most populated by wave-19+ grinder rounds (Tier-0 / Tier-1 leaves, no JSC dependency yet).

## What's deferred to follow-up sub-phases

| Sub-phase | Source under `~/Code/bun/src/` | Destination | Status |
|---|---|---|---|
| 12.1 | `cli/` | `src/cli/` | 🟡 scaffold landed |
| 12.2 | `jsc/`, `bun.js.zig`, `jsc_stub.zig` | `src/jsc/` | 🟡 M6 milestone landed (128 files; JS-callable bridge pending) |
| 12.3 | `event_loop/`, `io/`, `async/` | `src/event_loop/` | 🟡 substrate landing (~30+ leaves via wave-19+ grinders) |
| 12.4 | `resolver/`, `module_loader.zig` | `src/module_loader/` | 🔴 blocked on 12.2 |
| 12.5 | `web/`, `http/`, `csrf/`, `dns/` | `src/web/` | 🔴 blocked on 12.3 |
| 12.6 | `bun.zig` (Home.* surface) | `src/home/` | 🔴 blocked on 12.2 |
| 12.7 | `node/` namespace shims | `src/node/` | 🟡 round-15 landed (28 files) |
| 12.8 | `test/` runner | `src/test/` | 🔴 blocked on 12.2 |
| 12.9 | Pantry CLI integration | `src/install/pantry.zig` | 🟡 scaffold in progress |
| 12.10 | CLI surface | `src/cli/` | 🟡 scaffold landed |
| 12.11 | Cross-compile + single-file builds | `src/build/` | 🔴 not started |

While the JS-callable JSC bridge isn't wired up yet, the Home CLI surface (`home run`, `home test`, `home add`, `home x`) is exposed today via a delegation shim that calls into pantry / the system Bun runtime. This is intentional scaffolding — every delegation site has a `TODO(phase-12-N)` marker in `src/main.zig` so progressive replacement is mechanical.

## Building

The runtime package is wired into the Home build. Substrate + JSC milestones M1-M6 currently compile and pass their inline tests; the runtime won't actually run JS / TS until the JS-callable JSC bridge is wired up. Verification today:

```sh
./pantry/.bin/zig build --summary all        # Pantry Zig 0.17.0-dev.263+0add2dfc4
./pantry/.bin/zig build test --summary all   # substrate + JSC inline tests
```

To recount the port progress in one shot:

```sh
scripts/measure-parity.sh --values   # raw counts (RUNTIME_FILES, JSC_FILES, NODE_FILES, …)
scripts/measure-parity.sh --markdown # README headline-numbers table block
scripts/measure-parity.sh --diff     # exits non-zero if README has gone stale
```
