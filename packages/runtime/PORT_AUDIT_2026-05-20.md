# Bun Runtime Port Audit

**Date:** 2026-05-20
**Upstream pinned at:** `fd0b6f1a271fca0b8124b69f230b100f4d636af6`
**Destination:** `packages/runtime/src/`
**Supersedes:** [`PORT_AUDIT_2026-05-18.md`](./PORT_AUDIT_2026-05-18.md)
  (referenced for the Tier 0 / Tier 1 catalogue)

## Totals

- **Upstream files:** 1,193 `.zig` files under `~/Code/bun/src/`
  (excluding `test/`, `codegen/`, `*_jsc/`, `*_macros/`).
- **Ported files:** **492** files already in `packages/runtime/src/`.
- **Unported files:** **701** files remaining to port.
- **Subsystem directories:** 59 under `packages/runtime/src/`.

Recount in one command:

```sh
scripts/measure-parity.sh --values
```

## What landed since 2026-05-18

The previous audit measured **366 ported** files. Since then,
**106 additional files** have landed across:

### Phase 12.2 — JSC bring-up (95 files in `src/jsc/`)

- **M1** — `enable_jsc` build flag + `Engine` stub.
- **M2** — `JSValue`, `JSGlobalObject`, `JSCell` skeletons.
- **M3** — Engine init, root context, basic value coercion.
- **M4** — Exception propagation, type coercion (`toNumber`,
  `toString`, `toObject`), array helpers (`getLength`,
  `getIndex`, `putIndex`).
- **M5** — Call + callback helpers (`call`, `construct`,
  `getCallee`, `makeFunctionCallback`).
- **M6** — JSON + Promise + Iterator + Global helpers
  (`JSON.parse` / `JSON.stringify` bridges, public deferred-promise
  creation via `JSObjectMakeDeferredPromise`, retained resolver calls,
  iterator protocol, `globalThis` accessors).

JS-callable end-to-end wire-up (the `home run` reaches JS via JSC)
is the remaining gate.

### Phase 12.7 — `node:*` namespace shims (22 files in `src/node/`)

Round-10 dropped seven top-level module shims on top of the 15
bindings already present:

- `src/node/assert.zig` — `node:assert` top-level shim.
- `src/node/buffer.zig` — `node:buffer`.
- `src/node/events.zig` — `node:events` EventEmitter.
- `src/node/fs.zig` — `node:fs` sync surface.
- `src/node/os.zig` — `node:os` top-level shim.
- `src/node/stream.zig` — `node:stream`.
- `src/node/util.zig` — `node:util`.

Plus the existing 14 binding files: `path`, `Stat`, `StatFS`,
`dir_iterator`, `fs_events`, `os_constants`, `nodejs_error_code`,
`node_fs_constant`, `node_net_binding`, `node_error_binding`,
`uv_signal_handle_windows`, `types`, `time_like`,
`util/parse_args_utils`, `assert/myers_diff`.

### Phase 12.3 — Event loop / IO / async substrate (wave-19+ grinders)

Wave-19 through wave-23 dropped Tier-0 / Tier-1 leaves across:

- `runtime/shell/builtin/` — `pwd`, `true_`, `false_`.
- `ast/`, `bun_alloc/` (BufferFallback, MaxHeap, Nullable allocators).
- `ptr/` — `raw_ref_count`, `weak_ptr`.
- `string/` — `PathString`, `HashedString`.
- `threading/` — `work_pool`.
- `sql/mysql/` — `EncodeInt`, `AuthMethod`, `StmtPrepareOKPacket`,
  `ColumnDefinition41`.
- `css/properties/` — `svg`, `list`.
- `uws_sys/` — `BodyReaderMixin`, `ListenSocket`, `Timer`, `vtable`,
  `SocketGroup`.
- `install_types/` — `ExternalString`, `SlicedString`.
- `runtime/timer/`, `runtime/crypto/` (HMAC), `runtime/cli/`,
  `runtime/test_runner/` (DoneCallback), `jsc/` (UUID, JSSecrets,
  config).

### Phase 12 Bake — DevServer/HMR lifetime carrier (5 files)

- `runtime/bake/bake.zig` — public Bake nucleus plus the
  `serve.static.define` propagation carrier that copies define maps into
  client/server/ssr Bake bundler options and preserves Bun's
  `import.meta.env.*` define strings.
- `runtime/bake/DevServer.zig` — deinit counter, Bun HMR wire-message
  ids, route-pattern lookup, configuration hash payload storage, and
  active-socket snapshot-before-close teardown.
- `runtime/bake/DevServer/HmrSocket.zig` — borrowed parent reference,
  opening version payload, `subscribe` / `set_url` client-message
  handling, route viewer release, source-map ref release, active-map
  removal.
- `runtime/bake/DevServer/RouteBundle.zig` — stable route index and
  active-viewer/source-map lifetime fields.
- `runtime/bake/DevServer/SourceMapStore.zig` — source-map refcount and
  weak-ref upgrade/remove semantics.

This is not yet the JS-visible `Bun.serve`/Bake API; it preserves the Bun
teardown invariants needed by `bake/deinitialization.test.ts` and the
protocol bytes needed by the first `dev-and-prod.test.ts` HMR handshake
before the full DevServer graph is connected.

### Phase 12 server — Bake static HTML-route carrier (3 files)

- `runtime/server/server.zig` — mirrors Bun's `deinitIfWeCan` gate for
  detaching and deinitializing a Bake DevServer only after pending
  requests, the listener, and active websockets are gone; also carries
  the first `AnyRoute.html` union shape and mirrors HTML routes into the
  DevServer HTML router.
- `runtime/server/HTMLBundle.zig` — metadata-only HTMLBundle / Route
  carrier copied from Bun's `HTMLBundle.zig` shape, with owned imported
  path, route state, script/style reference parsing, and the
  `serve.static.define` replacement pass needed by the first
  `bake/dev-and-prod.test.ts` HTML entry.
- `runtime/server/ServerConfig.zig` — adds static HTML route entries,
  `had_routes_object`, and `bake.UserOptions` initialization for HTML
  routes while reusing the existing serve-static define propagation.

## Sub-phase status snapshot

| Sub-phase | Source under `~/Code/bun/src/` | Destination | Files | Status |
|---|---|---|---|---|
| 12.1 | `cli/` | `src/cli/` | varies | 🟡 scaffold landed |
| 12.2 | `jsc/`, `bun.js.zig`, `jsc_stub.zig` | `src/jsc/` | **97** | 🟡 M6 milestone landed; JS-callable bridge pending |
| 12.3 | `event_loop/`, `io/`, `async/` | `src/event_loop/`, `src/io/`, `src/async/` | varies | 🟡 substrate landing |
| 12.4 | `resolver/`, `module_loader.zig` | `src/module_loader/` | — | 🔴 blocked on 12.2 |
| 12.5 | `web/`, `http/`, `csrf/`, `dns/` | `src/web/`, … | varies (substrate) | 🔴 blocked on 12.3 |
| 12.6 | `bun.zig` (`Home.*` surface) | `src/home/` | — | 🔴 blocked on 12.2 |
| 12.7 | `node/` namespace shims | `src/node/` | **22** | 🟡 round-10 landed |
| 12.8 | `test/` runner | `src/test/` | — | 🔴 blocked on 12.2 |
| 12.9 | Pantry CLI integration | `src/install/pantry.zig` | — | 🟡 scaffold in progress |
| 12.10 | CLI surface | `src/cli/` | — | 🟡 scaffold landed |
| 12.11 | Cross-compile + single-file builds | `src/build/` | — | 🔴 not started |

## Tier roadmap

The 2026-05-18 audit catalogued Tier 0 (30 ≤100-LOC leaves) and
Tier 1 (30 ≤300-LOC leaves) ready-to-claim files. Most of those
Tier 0/1 entries have since landed via the wave-19+ grinder rounds
— see [`PORTING_STATUS.md`](./PORTING_STATUS.md) (or its successor)
for the up-to-date claim ledger.

The next concentrated push is **Phase 12.2 finish line**: wire the
M1-M6 JSC helpers into a JS-callable entry point that takes a
script and runs it. Everything blocked on 12.2 (12.4 module
loader, 12.5 web/http, 12.6 `Home.*` JS surface, 12.7 functional
`node:*` modules, 12.8 test runner) unblocks the moment that gate
opens.

## See also

- [`docs/PARITY-BUN.md`](../../docs/PARITY-BUN.md) — per-API
  status with JSC + node:* milestones.
- [`docs/PARITY-NODE.md`](../../docs/PARITY-NODE.md) — every
  `node:*` module with status.
- [`docs/PARITY-BUN-COMPAT.md`](../../docs/PARITY-BUN-COMPAT.md) —
  `packages/compat/` Tier-0 shim that lets vendored Bun source
  compile against Home's stdlib.
- [`PORT_AUDIT_2026-05-18.md`](./PORT_AUDIT_2026-05-18.md) —
  predecessor audit, retained for the full Tier 0 / Tier 1 file
  catalogue (still useful as a reference for next-to-port pools).
