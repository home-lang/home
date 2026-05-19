# Bun runtime parity

Detailed per-API status for Home's Bun-compatible runtime
(`packages/runtime/`). This is the drill-down view; the at-a-glance
row is in the
[README parity status](../README.md#bun-runtime-port-packagesruntime)
section.

> **Status:** Substrate + JSC M6 landed. **472 / 1,193 Bun source
> files ported** (~39.6%); the runtime is not yet JavaScript-callable
> end-to-end, but Phase 12.2 (JSC bring-up) has reached the M6
> milestone — JSON + Promise + Iterator + Global helpers — across
> 95 files in `packages/runtime/src/jsc/`. Full audit:
> [`packages/runtime/PORT_AUDIT_2026-05-20.md`](../packages/runtime/PORT_AUDIT_2026-05-20.md).

Legend:

- 🟢 **Fully implemented** — JS-callable today.
- 🟡 **Partially implemented** — JS-callable, missing APIs listed.
- 🔴 **Not implemented** — no JS surface yet; Zig substrate may exist.

## Phase-by-phase status

| Sub-phase | Source under `~/Code/bun/src/` | Destination | Status |
|---|---|---|---|
| 12.1 | `cli/` | `src/cli/` | 🟡 scaffold landed (CLI flag parsing partial) |
| 12.2 | `jsc/`, `bun.js.zig`, `jsc_stub.zig` | `src/jsc/` | 🟡 M6 milestone landed (95 files: JSON + Promise + Iterator + Global helpers) |
| 12.3 | `event_loop/`, `io/`, `async/` | `src/event_loop/` | 🟡 substrate landing (~30+ leaves ported) |
| 12.4 | `resolver/`, `module_loader.zig` | `src/module_loader/` | 🔴 blocked on 12.2 |
| 12.5 | `web/`, `http/`, `csrf/`, `dns/` | `src/web/` | 🔴 blocked on 12.3 |
| 12.6 | `bun.zig` (Home.* surface) | `src/home/` | 🔴 blocked on 12.2 |
| 12.7 | `node/` namespace shims | `src/node/` | 🟡 round-10 landed (22 files: path / Stat / buffer / stream / fs / events / util / assert / os + bindings) |
| 12.8 | `test/` runner | `src/test/` | 🔴 blocked on 12.2 |
| 12.9 | Pantry CLI integration | `src/install/pantry.zig` | 🟡 scaffold in progress |
| 12.10 | CLI surface | `src/cli/` | 🟡 scaffold landed |
| 12.11 | Cross-compile + single-file builds | `src/build/` | 🔴 not started |

## JS-visible APIs (the `Home.*` / `Bun.*` namespace)

### `Bun.serve`

🔴 Not implemented. HTTP/HTTPS/WebSocket server. Substrate at
`packages/runtime/src/web/` + `packages/runtime/src/uws_sys/`.

### `Bun.fetch`

🔴 Not implemented. WHATWG `fetch` with Bun extensions.

### `Bun.file` / `Bun.write`

🔴 Not implemented. `BunFile` reader/writer.

### `Bun.spawn` / `Bun.spawnSync`

🔴 Not implemented. Subprocess API.

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

🔴 Not implemented.

### `Bun.color`

🔴 Not implemented.

### `Bun.gzipSync` / `Bun.gunzipSync` / `Bun.deflateSync` / `Bun.inflateSync`

🔴 Not implemented. Substrate vendored under `packages/runtime/src/zlib/`.

### `Bun.deepEquals` / `Bun.deepMatch`

🔴 Not implemented.

### `Bun.escapeHTML`

🔴 Not implemented.

### `Bun.inspect`

🔴 Not implemented.

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

🔴 Not implemented.

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

## Summary

Substrate file-count progress (the only objective number today):

| Metric | Count | Notes |
|---|---|---|
| Bun upstream files (excluding test/codegen/jsc/macros) | 1,193 | pinned at `fd0b6f1a` |
| Files ported to `packages/runtime/src/` | 472 | ~39.6% |
| Files remaining to port | 721 | ~60.4% |
| JSC bring-up (`packages/runtime/src/jsc/`) | 95 files | Phase 12.2 M6 milestone |
| Node namespace (`packages/runtime/src/node/`) | 22 files | Phase 12.7 round-10 |
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
