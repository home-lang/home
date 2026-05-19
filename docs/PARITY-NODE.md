# Node.js compatibility

Detailed per-module status for Home's `node:*` namespace. This is the
drill-down view; the at-a-glance row is in the
[README parity status](../README.md#nodejs-compatibility-packagesruntimesrcnode)
section.

> **Status:** Substrate only. The `node:*` surface attaches once Phase
> 12.2 (JSC bring-up) lands. Today we have **15 Zig binding files
> ported** plus the design scaffolding; no `node:*` module is
> JavaScript-callable yet. Once JSC ships, each module flips from 🔴
> (not implemented) to 🟡 (partial) or 🟢 (fully implemented) based on
> Bun's existing port, which we vendor under MIT.

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

🔴 Not implemented (blocked on Phase 12.2). Zig substrate landed:
`packages/runtime/src/node/assert/myers_diff.zig` — the diff helper
used by `assert.deepStrictEqual` error formatting.

### [`node:async_hooks`](https://nodejs.org/api/async_hooks.html)

🔴 Not implemented.

### [`node:buffer`](https://nodejs.org/api/buffer.html)

🔴 Not implemented.

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

🔴 Not implemented.

### [`node:dgram`](https://nodejs.org/api/dgram.html)

🔴 Not implemented.

### [`node:diagnostics_channel`](https://nodejs.org/api/diagnostics_channel.html)

🔴 Not implemented.

### [`node:dns`](https://nodejs.org/api/dns.html)

🔴 Not implemented.

### [`node:events`](https://nodejs.org/api/events.html)

🔴 Not implemented.

### [`node:fs`](https://nodejs.org/api/fs.html)

🔴 Not implemented. Zig substrate landed:
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

🔴 Not implemented. Zig substrate landed:
`packages/runtime/src/node/node_net_binding.zig` — `net.Socket` /
`net.Server` C-callable layer.

### [`node:os`](https://nodejs.org/api/os.html)

🔴 Not implemented. Zig substrate landed:
`packages/runtime/src/node/os_constants.zig` (constants table).

### [`node:path`](https://nodejs.org/api/path.html)

🔴 Not implemented (JS surface). Zig port: **fully ported** at
`packages/runtime/src/node/path.zig` — POSIX + Win32 path resolution
algorithms vendored verbatim from Bun. Will flip 🟢 the moment the JS
bridge is wired.

### [`node:perf_hooks`](https://nodejs.org/api/perf_hooks.html)

🔴 Not implemented.

### [`node:process`](https://nodejs.org/api/process.html)

🔴 Not implemented.

### [`node:punycode`](https://nodejs.org/api/punycode.html)

🔴 Not implemented.

### [`node:querystring`](https://nodejs.org/api/querystring.html)

🔴 Not implemented.

### [`node:readline`](https://nodejs.org/api/readline.html)

🔴 Not implemented.

### [`node:readline/promises`](https://nodejs.org/api/readline.html#promises-api)

🔴 Not implemented.

### [`node:repl`](https://nodejs.org/api/repl.html)

🔴 Not implemented.

### [`node:stream`](https://nodejs.org/api/stream.html)

🔴 Not implemented.

### [`node:stream/consumers`](https://nodejs.org/api/stream.html#streamconsumers)

🔴 Not implemented.

### [`node:stream/promises`](https://nodejs.org/api/stream.html#streampromises-api)

🔴 Not implemented.

### [`node:stream/web`](https://nodejs.org/api/webstreams.html)

🔴 Not implemented.

### [`node:string_decoder`](https://nodejs.org/api/string_decoder.html)

🔴 Not implemented.

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

🔴 Not implemented.

### [`node:url`](https://nodejs.org/api/url.html)

🔴 Not implemented.

### [`node:util`](https://nodejs.org/api/util.html)

🔴 Not implemented. Zig substrate landed:
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
| 🔴 Not implemented | 47 | ~98% |
| ❌ Won't implement | 1 | ~2% |

**Zig substrate ported:** 15 binding files (`path`, `Stat`, `StatFS`,
`dir_iterator`, `fs_events`, `os_constants`, `nodejs_error_code`,
`node_fs_constant`, `node_net_binding`, `node_error_binding`,
`uv_signal_handle_windows`, `types`, `time_like`,
`util/parse_args_utils`, `assert/myers_diff`) — about 3% of Bun's
`node/` source tree.

Once Phase 12.2 (JSC) lands the entire JS-callable surface flips from
🔴 to its Bun-equivalent status in one wave; the substrate then earns
percentages from Node's own test suite (the same yardstick Bun uses).
