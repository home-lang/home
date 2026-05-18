# Home Runtime (`packages/runtime/`)

> **Status:** Phase 12 substrate landed 2026-05-17. Source copy from Bun in progress.

This package is Home's JavaScript / TypeScript runtime, equivalent to Bun in surface area. Once complete, `home run app.ts`, `home test`, `home x <pkg>`, `home build src/index.ts --target=native`, `home add <pkg>`, etc. all work natively, with package management deferring to Pantry (`~/Code/Tools/pantry`).

## Hard rules for every copy

1. **Zig 0.17 dev compatibility is non-negotiable.** Every copied file must compile under Pantry-managed `0.17.0-dev.263+0add2dfc4`. Bun upstream targets a more recent Zig; some files use APIs that moved between 0.16 → 0.17 (e.g. `std.array_list.Managed(T)` is 0.17+, `std.heap.stackFallback` was relocated, `std.io.fixedBufferStream` was removed in favor of `std.Io.Writer.fixed`, `Child.init` was replaced by `process.spawn`). Files that don't compile under 0.17 stay parked with a `// Zig 0.17 compat: ...` note in `home_rt.zig` until an adapter lands.
2. Verify `git -C ~/Code/bun rev-parse HEAD` matches `UPSTREAM_SHA.txt` before copying. If they diverge, rewind Bun or update the SHA in a **separate** commit.
3. Rewrite `@import("bun")` → `@import("home_rt")` and every `bun.X` → `home_rt.X` at copy time. **No semantic edits in the same commit.**
4. Drop JSC-bridge re-exports (`.toJS`, `.fromJS`, `Bun__X` externs) with a `// JSC-bridge X omitted — re-lands in Phase 12.2` note.
5. Every copied file must add **at least one** inline `test "..."` that exercises a method or invariant.
6. After integrating: run `zig build test --summary all` AND `home test` in `~/Code/Apps/settlers-iii`. Both must stay green; commit only if so.

## Upstream pin

`UPSTREAM_SHA.txt` holds the exact Bun commit our copy is anchored against. Today: `fd0b6f1a271fca0b8124b69f230b100f4d636af6` (`http: port fetch TCP keepalive to on_open in lib.rs`).

## Why local copy and not vendoring

Per user direction: "build it natively as if it was ours, bc bun is MIT code." Bun is MIT-licensed, so we can copy. The flattening convention:

- Copied subsystem directories live directly under `src/` (e.g. `src/cli/`, `src/install/`, `src/jsc/`, `src/event_loop/`, `src/web/`, `src/home/`, `src/node/`).
- The aggregator `src/home_rt.zig` re-exports everything so subsystems can `@import("home_rt")` without coupling to Bun's namespace.
- JS-visible APIs go under `Home.*` (Bun's `Bun.*` namespace becomes `Home.*` for runtime callers); the Zig aggregator stays `home_rt` to avoid colliding with `home.runtime` which is reserved for native Home callers.

## Pantry replaces `bun install`

`bun install` is not copied. `home add <pkg>` / `home install` / `home remove` / `home update` route through the Pantry CLI at `~/Code/Tools/pantry`, which is Home's package manager and registry. The Pantry CLI is independently maintained; Home talks to it via a thin Zig shim.

## Acceptance gate — Bun test suite must pass 100 %

Per user direction (2026-05-17): once the runtime copy is feature-complete, Home must pass **the entire Bun test suite, no exceptions**. Concretely:

1. Copy `~/Code/bun/test/` into `packages/runtime/test/bun-corpus/` at the pinned SHA.
2. `home test packages/runtime/test/bun-corpus/` must produce zero failures on macOS, Linux, and the WASM target.
3. Every test that uses Bun-specific APIs (`Bun.serve`, `Bun.write`, `Bun.spawn`, …) is renamed at copy time to `Home.*` but otherwise unchanged.
4. Any test that the corpus marks as `bun-only` (e.g. macOS Bonjour specifics) is preserved verbatim and must pass — no skipping.
5. CI gate is `home test packages/runtime/test/bun-corpus/ --bail=0 --reporter=junit`. A regression on any case blocks merge.

This is the hard release gate for Phase 12. Substrate is in place today; the gate becomes enforceable after Phase 12.2 (JSC bring-up) and Phase 12.8 (test runner copy).

## What's here today

- `src/home_rt.zig` — aggregator skeleton (empty until copies land).
- `src/cli/` — destination for Bun's `src/cli/` command dispatch (Phase 12.10 target).
- `src/install/` — placeholder; Pantry handles package management so this directory only holds the `home <-> pantry` shim.

## What's deferred to follow-up sub-phases

| Sub-phase | Source under `~/Code/bun/src/` | Destination | Status |
|---|---|---|---|
| 12.1 | `cli/` | `src/cli/` | not-started |
| 12.2 | `jsc/`, `bun.js.zig`, `jsc_stub.zig` | `src/jsc/` | blocked on JSC C++ engine availability |
| 12.3 | `event_loop/`, `io/`, `async/` | `src/event_loop/` | not-started |
| 12.4 | `resolver/`, `module_loader.zig` | `src/module_loader/` | blocked on 12.2 |
| 12.5 | `web/`, `http/`, `csrf/`, `dns/` | `src/web/` | blocked on 12.3 |
| 12.6 | `bun.zig` (Home.* surface) | `src/home/` | blocked on 12.2 |
| 12.7 | `node/` namespace shims | `src/node/` | blocked on 12.2 |
| 12.8 | `test/` runner | `src/test/` | blocked on 12.2 |
| 12.9 | Pantry CLI integration | `src/install/pantry.zig` | scaffold in progress |
| 12.10 | CLI surface | `src/cli/` | scaffold landed |
| 12.11 | Cross-compile + single-file builds | `src/build/` | not-started |

While substantive sub-phases are blocked on JSC engine bring-up, the Home CLI surface (`home run`, `home test`, `home add`, `home x`) is exposed today via a delegation shim that calls into pantry / the system Bun runtime. This is intentional scaffolding — every delegation site has a `TODO(phase-12-N)` marker in `src/main.zig` so progressive replacement is mechanical.

## Building

The runtime package is wired into the Home build but has no test surface yet (substrate only). It compiles to nothing useful until Phase 12.2 (JSC bring-up). Verification today is:

```sh
zig build --summary all   # under pantry-managed Zig 0.17.0-dev.263+0add2dfc4
```

Substrate adds zero new test failures.
