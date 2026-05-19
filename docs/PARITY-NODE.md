# Node.js compatibility

Detailed per-module status for Home's `node:*` namespace. This is the
drill-down view; the at-a-glance row is in the
[README parity status](../README.md#nodejs-compatibility-packagesruntimesrcnode)
section.

> **Status:** Substrate landing module-by-module. JSC bring-up
> (Phase 12.2) is at the M6 milestone — JSON + Promise + Iterator
> + Global helpers across 96 files. Phase 12.7 round-15 has
> top-level `node:*` substrate modules (`buffer`, `stream`, `fs`,
> `events`, `util`, `assert`, `os`, `url`, `querystring`, `crypto`,
> `process`, `string_decoder`, `tty`) alongside the binding/helper
> files. Total **28 Zig substrate files** ported; no
> `node:*` module is JavaScript-callable yet, but the runway is
> shortening. Once JSC reaches the JS-callable milestone, each
> module flips from 🔴 to 🟡 or 🟢 based on Bun's existing port.

Legend:

- 🟢 **Fully implemented** — JS-callable today, passes its slice of
  the Node test suite at the rate noted.
- 🟡 **Partially implemented** — JS-callable, with missing APIs listed
  inline.
- 🔴 **Not implemented** — no JS surface yet; Zig substrate may exist.
- ❌ **Won't implement** — explicitly out of scope (no Node-only
  internals like `node:wasi` legacy quirks).

## Built-in modules

### [`node:assert`](https://nodejs.org/api/assert.html)

🔴 Not JS-callable yet (blocked on Phase 12.2). Zig substrate
landed: `packages/runtime/src/node/assert.zig` (top-level shim) +
`packages/runtime/src/node/assert/myers_diff.zig` — the diff helper
used by `assert.deepStrictEqual` error formatting.

### [`node:async_hooks`](https://nodejs.org/api/async_hooks.html)

🔴 Not implemented.

### [`node:buffer`](https://nodejs.org/api/buffer.html)

🔴 Not JS-callable yet (blocked on Phase 12.2). Zig substrate
landed: `packages/runtime/src/node/buffer.zig` (Phase 12.7 round-10
port of Bun's `node:buffer`).

### [`node:child_process`](https://nodejs.org/api/child_process.html)

🔴 Not implemented.

### [`node:cluster`](https://nodejs.org/api/cluster.html)

🔴 Not implemented.

### [`node:console`](https://nodejs.org/api/console.html)

🔴 Not implemented.

### [`node:constants`](https://nodejs.org/api/os.html#os_constants)

🔴 Not implemented. Zig substrate landed:
`packages/runtime/src/node/os_constants.zig` (POSIX error codes,
signal numbers, fs constants).

### [`node:crypto`](https://nodejs.org/api/crypto.html)

🔴 Not JS-callable yet (blocked on Phase 12.2). Zig substrate
landed: `packages/runtime/src/node/crypto.zig` — CSPRNG,
`randomBytes`, `randomFillSync`, `randomUUID`, hash/HMAC families
built on `std.crypto`; OpenSSL/BoringSSL-backed surfaces remain
stubbed until the native crypto bindings port.

### [`node:dgram`](https://nodejs.org/api/dgram.html)

🔴 Not implemented.

### [`node:diagnostics_channel`](https://nodejs.org/api/diagnostics_channel.html)

🔴 Not implemented.

### [`node:dns`](https://nodejs.org/api/dns.html)

🔴 Not implemented.

### [`node:events`](https://nodejs.org/api/events.html)

🔴 Not JS-callable yet (blocked on Phase 12.2). Zig substrate
landed: `packages/runtime/src/node/events.zig`.

### [`node:fs`](https://nodejs.org/api/fs.html)

🔴 Not JS-callable yet (blocked on Phase 12.2). Zig substrate
landed:
- `packages/runtime/src/node/fs.zig` — top-level `node:fs` shim (Phase 12.7 round-10).
- `packages/runtime/src/node/Stat.zig` — `fs.Stats` shape.
- `packages/runtime/src/node/StatFS.zig` — `fs.StatFs` shape.
- `packages/runtime/src/node/dir_iterator.zig` — `fs.Dir` iterator.
- `packages/runtime/src/node/fs_events.zig` — `fs.watch` event types.
- `packages/runtime/src/node/node_fs_constant.zig` — file mode / open flag constants.
- `packages/runtime/src/node/time_like.zig` — `utimes` / `lutimes` argument coercion.

### [`node:fs/promises`](https://nodejs.org/api/fs.html#promises-api)

🔴 Not implemented.

### [`node:http`](https://nodejs.org/api/http.html)

🔴 Not implemented.

### [`node:http2`](https://nodejs.org/api/http2.html)

🔴 Not implemented.

### [`node:https`](https://nodejs.org/api/https.html)

🔴 Not implemented.

### [`node:inspector`](https://nodejs.org/api/inspector.html)

🔴 Not implemented.

### [`node:module`](https://nodejs.org/api/module.html)

🔴 Not implemented.

### [`node:net`](https://nodejs.org/api/net.html)

🔴 Not JS-callable yet (blocked on Phase 12.2). Zig substrate
landed: `packages/runtime/src/node/node_net_binding.zig` —
`net.Socket` / `net.Server` C-callable layer.

### [`node:os`](https://nodejs.org/api/os.html)

🔴 Not JS-callable yet (blocked on Phase 12.2). Zig substrate
landed:
- `packages/runtime/src/node/os.zig` — top-level `node:os` shim (Phase 12.7).
- `packages/runtime/src/node/os_constants.zig` — constants table.

### [`node:path`](https://nodejs.org/api/path.html)

🔴 Not JS-callable yet (blocked on Phase 12.2). Zig port: **fully
ported** at `packages/runtime/src/node/path.zig` — POSIX + Win32
path resolution algorithms vendored verbatim from Bun. Will flip
🟢 the moment the JS bridge is wired.

### [`node:perf_hooks`](https://nodejs.org/api/perf_hooks.html)

🔴 Not implemented.

### [`node:process`](https://nodejs.org/api/process.html)

🔴 Not JS-callable yet (blocked on Phase 12.2). Zig substrate
landed: `packages/runtime/src/node/process.zig` — host facts and
mutators for `cwd` / `chdir`, env reads/writes/snapshots, `pid`,
`ppid`, `platform`, `arch`, `uptime`, `hrtime`, `memoryUsage`, and
`cpuUsage`. EventEmitter, `nextTick`, native bindings, and JS export
shape attach with the JS-callable bridge.

### [`node:punycode`](https://nodejs.org/api/punycode.html)

🔴 Not implemented.

### [`node:querystring`](https://nodejs.org/api/querystring.html)

🔴 Not JS-callable yet (blocked on Phase 12.2). Zig substrate
landed: `packages/runtime/src/node/querystring.zig` — legacy
`parse` / `stringify` / `escape` / `unescape` plus `encode` /
`decode` aliases, preserving duplicate keys as ordered entries until
the JS object surface attaches.

### [`node:readline`](https://nodejs.org/api/readline.html)

🔴 Not implemented.

### [`node:readline/promises`](https://nodejs.org/api/readline.html#promises-api)

🔴 Not implemented.

### [`node:repl`](https://nodejs.org/api/repl.html)

🔴 Not implemented.

### [`node:stream`](https://nodejs.org/api/stream.html)

🔴 Not JS-callable yet (blocked on Phase 12.2). Zig substrate
landed: `packages/runtime/src/node/stream.zig` (Phase 12.7 round-10
port of Bun's `node:stream`).

### [`node:stream/consumers`](https://nodejs.org/api/stream.html#streamconsumers)

🔴 Not implemented.

### [`node:stream/promises`](https://nodejs.org/api/stream.html#streampromises-api)

🔴 Not implemented.

### [`node:stream/web`](https://nodejs.org/api/webstreams.html)

🔴 Not implemented.

### [`node:string_decoder`](https://nodejs.org/api/string_decoder.html)

🔴 Not JS-callable yet (blocked on Phase 12.2). Zig substrate
landed: `packages/runtime/src/node/string_decoder.zig` — allocator
owned `StringDecoder` state machine for split UTF-8, UTF-16LE/`ucs2`,
base64/base64url grouping, hex, ascii, latin1, and binary decoding.
The public `require("string_decoder").StringDecoder` constructor
attaches once the JS module bridge is live.

### [`node:test`](https://nodejs.org/api/test.html)

🔴 Not implemented. Will land as part of `home test` (Phase 12.8) —
the runner is a port of Bun's test runner, not Node's, but the
`node:test` API surface is mapped onto it.

### [`node:timers`](https://nodejs.org/api/timers.html)

🔴 Not implemented.

### [`node:timers/promises`](https://nodejs.org/api/timers.html#timers-promises-api)

🔴 Not implemented.

### [`node:tls`](https://nodejs.org/api/tls.html)

🔴 Not implemented.

### [`node:trace_events`](https://nodejs.org/api/tracing.html)

🔴 Not implemented.

### [`node:tty`](https://nodejs.org/api/tty.html)

🔴 Not JS-callable yet (blocked on Phase 12.2). Zig substrate
landed: `packages/runtime/src/node/tty.zig`, backed by
`packages/runtime/src/core/tty.zig` — `isatty`, window-size probing,
raw/normal/io terminal modes, color-depth environment rules, and
lightweight stream state for future `ReadStream` / `WriteStream`
wrappers.

### [`node:url`](https://nodejs.org/api/url.html)

🔴 Not JS-callable yet (blocked on Phase 12.2). Zig substrate
landed: `packages/runtime/src/node/url.zig` — WHATWG `URL`,
`URLSearchParams`, legacy `parse` / `format` / `resolve`, and
file-URL helpers.

### [`node:util`](https://nodejs.org/api/util.html)

🔴 Not JS-callable yet (blocked on Phase 12.2). Zig substrate
landed:
- `packages/runtime/src/node/util.zig` — top-level `node:util` shim (Phase 12.7).
- `packages/runtime/src/node/util/parse_args_utils.zig` — `util.parseArgs` parser.
- `packages/runtime/src/node/types.zig` — `util.types.*` type-predicate exports.

### [`node:v8`](https://nodejs.org/api/v8.html)

❌ Won't implement. Home runs on JavaScriptCore, not V8 — the
serializer and heap-snapshot APIs are V8-specific and have no
equivalent in JSC.

### [`node:vm`](https://nodejs.org/api/vm.html)

🔴 Not implemented.

### [`node:wasi`](https://nodejs.org/api/wasi.html)

🔴 Not implemented.

### [`node:worker_threads`](https://nodejs.org/api/worker_threads.html)

🔴 Not implemented.

### [`node:zlib`](https://nodejs.org/api/zlib.html)

🔴 Not implemented.

## Node.js globals

🔴 Not implemented. Once JSC is up, `process`, `Buffer`,
`globalThis`, `console`, the timer functions (`setTimeout` /
`setInterval` / `setImmediate` and their `clearX` pairs),
`queueMicrotask`, `fetch`, `URL`, `URLSearchParams`, `TextEncoder`,
`TextDecoder`, `crypto`, `performance`, `structuredClone`, and the
`*Streams` family all attach via Bun's existing port.

## Summary

| Status | Count | % |
|---|---|---|
| 🟢 Fully implemented | 0 | 0% |
| 🟡 Partially implemented | 0 | 0% |
| 🔴 Not implemented (JS-callable) | 47 | ~98% |
| ❌ Won't implement | 1 | ~2% |

**Zig substrate ported:** 28 files. Phase 12.7 round-15 has top-level
module shims for `assert.zig`, `buffer.zig`, `crypto.zig`,
`events.zig`, `fs.zig`, `os.zig`, `path.zig`, `process.zig`,
`querystring.zig`, `stream.zig`, `string_decoder.zig`, `tty.zig`,
`url.zig`, and `util.zig`. On top of the 14 binding/helper files already
present: `Stat`, `StatFS`, `dir_iterator`, `fs_events`,
`os_constants`, `nodejs_error_code`, `node_fs_constant`,
`node_net_binding`, `node_error_binding`, `uv_signal_handle_windows`,
`types`, `time_like`, `util/parse_args_utils`, `assert/myers_diff`.

JSC bring-up (Phase 12.2) has reached the M6 milestone — JSON +
Promise + Iterator + Global helpers across 96 files. Once the
JS-callable bridge wires up, the substrate-backed modules
(`assert`, `buffer`, `crypto`, `events`, `fs`, `net`, `os`, `path`,
`process`, `querystring`, `stream`, `string_decoder`, `tty`, `url`, `util`)
flip from 🔴 to 🟡 / 🟢 based on Bun's existing port, and the
remaining modules grow substrate per their own Phase 12.7 rounds.
