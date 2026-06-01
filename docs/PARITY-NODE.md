# Node.js compatibility

Detailed per-module status for Home's `node:*` namespace. This is the
drill-down view; the at-a-glance row is in the
[README parity status](../README.md#nodejs-compatibility-packagesruntimesrcnode)
section.

> **Status:** The JS-callable bridge is live. A `require()` (CommonJS) of
> the `node:*` modules below works through Home's **own** JavaScriptCore
> realm — exercised today by `home eval` and `HOME_NATIVE_RUN=1 home run`,
> NOT by delegating to system `bun`. 24 modules are JS-callable (🟡) as
> behavioral subsets, each unit-tested in
> `packages/runtime/src/jsc/node_modules.zig` (+ `jsc/spawn_global.zig` for
> `child_process`). Several are backed by native Zig: `node:zlib`
> (`std.compress.flate`), `node:crypto` HMAC/pbkdf2 (`std.crypto`),
> `node:fs`/`child_process` (`std.process` / native fs).
>
> **Scope caveat:** 🟡 here means "callable through Home's realm as a
> useful subset", NOT "passes the Node test suite" (we don't run it yet)
> and NOT "wired into the bun-corpus gate" (that still routes through the
> separate bootstrap harness). Socket/networking and heavy modules
> (`net`/`http`/`tls`/`dns`/`worker_threads`/`vm`/…) remain 🔴.

Legend:

- 🟢 **Fully implemented** — JS-callable today, passes its slice of
  the Node test suite at the rate noted.
- 🟡 **Partially implemented** — JS-callable (through Home's realm), with
  missing APIs / caveats noted inline.
- 🔴 **Not implemented** — no JS surface yet; Zig substrate may exist.
- ❌ **Won't implement** — explicitly out of scope (no Node-only
  internals like `node:wasi` legacy quirks).

## Built-in modules

### [`node:assert`](https://nodejs.org/api/assert.html)

🟡 JS-callable. `ok`/`equal`/`notEqual`/`strictEqual`/`notStrictEqual`,
`deepEqual`/`deepStrictEqual`/`notDeepStrictEqual`, `throws`/`doesNotThrow`,
`rejects`/`doesNotReject`, `match`/`doesNotMatch`, `ifError`, `fail`,
`AssertionError` (code `ERR_ASSERTION`), `assert.strict`. Missing: full
`AssertionError` diff formatting (the `myers_diff.zig` substrate isn't wired
to messages yet).

### [`node:async_hooks`](https://nodejs.org/api/async_hooks.html)

🔴 Not implemented.

### [`node:buffer`](https://nodejs.org/api/buffer.html)

🟡 JS-callable (`Buffer extends Uint8Array`, also a global). `from`
(utf8/hex/base64/base64url/latin1/array/ArrayBuffer/view), `alloc`/
`allocUnsafe`, `isBuffer`, `byteLength`, `concat`, `compare` (static +
instance), `equals`, `toString` (utf8/hex/base64/base64url/latin1/ascii),
`toJSON`, `subarray` (memory-sharing view), and read/write `UInt8`/`Int8`,
`UInt16`/`Int16` LE+BE, `UInt32`/`Int32` LE+BE, `BigUInt64` LE/BE,
`Float`/`Double` LE. Missing: `Blob`, `File`, the full read/write variant
matrix, `SlowBuffer`, `transcode`. Zig substrate: `node/buffer.zig`.

### [`node:child_process`](https://nodejs.org/api/child_process.html)

🟡 JS-callable, mapped onto Home's native `Bun.spawnSync`:
`spawnSync`/`execSync`/`execFileSync` (Node result shapes) + `exec`/
`execFile` (async callback) + `spawn` (EventEmitter emitting stdout/stderr
`data`/`end` and `exit`/`close`). Caveat: **eager** — children run to
completion synchronously under the hood (no live streaming / interactive
stdin yet). `fork`/IPC not implemented.

### [`node:cluster`](https://nodejs.org/api/cluster.html)

🔴 Not implemented.

### [`node:console`](https://nodejs.org/api/console.html)

🟡 JS-callable — `require("node:console")` returns the realm's `console`
global (`log`/`info`/`debug`/`error`/`warn`/`trace`/`dir`).

### [`node:constants`](https://nodejs.org/api/os.html#os_constants)

🟡 JS-callable — POSIX/Darwin subset: `O_*` open flags, `F_OK`/`R_OK`/
`W_OK`/`X_OK`, `S_IF*` mode bits, `SIG*` signal numbers. Zig substrate:
`packages/runtime/src/node/os_constants.zig`.

### [`node:crypto`](https://nodejs.org/api/crypto.html)

🟡 JS-callable. `createHash` (sha256/sha512/sha1/md5), `createHmac`
(HMAC over native hash), `pbkdf2`/`pbkdf2Sync` (native `std.crypto.pwhash`,
sha1/256/512 — RFC 6070 verified), `randomBytes`, `randomFillSync`,
`randomInt`, `randomUUID` (v4), `timingSafeEqual`, `getHashes`. Missing:
`createCipheriv`/`createDecipheriv`, `createSign`/`verify`, `hkdf`,
`scrypt`, `KeyObject`, X.509 — the OpenSSL/BoringSSL-backed surfaces.
Zig substrate: `node/crypto.zig`.

### [`node:dgram`](https://nodejs.org/api/dgram.html)

🔴 Not implemented (needs UDP sockets).

### [`node:diagnostics_channel`](https://nodejs.org/api/diagnostics_channel.html)

🔴 Not implemented.

### [`node:dns`](https://nodejs.org/api/dns.html)

🔴 Not implemented (needs resolver bindings).

### [`node:events`](https://nodejs.org/api/events.html)

🟡 JS-callable. `EventEmitter` (`on`/`once`/`off`/`emit`/`addListener`/
`prependListener`/`removeListener`/`removeAllListeners`/`listeners`/
`listenerCount`/`eventNames`/`setMaxListeners`), `events.once(emitter,name)`
→ Promise, `events.getEventListeners`. Missing: `events.on` async iterator,
`captureRejections`, `EventTarget` interop. Zig substrate: `node/events.zig`.

### [`node:fs`](https://nodejs.org/api/fs.html)

🟡 JS-callable, backed by Home's native fs. Sync:
`readFileSync`/`writeFileSync`/`existsSync`/`statSync`/`mkdirSync`/
`appendFileSync`. Callback: `readFile`/`writeFile`. Streams:
`createReadStream`/`createWriteStream` (on `node:stream`). `fs.promises`
(see below). Missing: `readdirSync`/`readdir` (throws ENOSYS),
`rm`/`unlink`/`rename`/`copyFile`/`watch`, full `Stats` instances, most
async callback variants. Zig substrate: `node/fs.zig`, `Stat.zig`,
`StatFS.zig`, `dir_iterator.zig`, `fs_events.zig`, `node_fs_constant.zig`,
`time_like.zig`.

### [`node:fs/promises`](https://nodejs.org/api/fs.html#promises-api)

🟡 JS-callable (`require("node:fs/promises")` or `fs.promises`):
`readFile`/`writeFile`/`appendFile`/`mkdir`/`stat`/`access`. Missing the
rest of the promises surface (readdir/rm/open/FileHandle/…).

### [`node:http`](https://nodejs.org/api/http.html)

🔴 Not implemented (needs the socket/server stack).

### [`node:http2`](https://nodejs.org/api/http2.html)

🔴 Not implemented.

### [`node:https`](https://nodejs.org/api/https.html)

🔴 Not implemented.

### [`node:inspector`](https://nodejs.org/api/inspector.html)

🔴 Not implemented.

### [`node:module`](https://nodejs.org/api/module.html)

🔴 Not implemented (the realm exposes a CommonJS `require` global, but the
`node:module` API — `createRequire`/`Module`/`builtinModules` — is not).

### [`node:net`](https://nodejs.org/api/net.html)

🔴 Not implemented (needs TCP/IPC sockets). Zig substrate:
`packages/runtime/src/node/node_net_binding.zig`.

### [`node:os`](https://nodejs.org/api/os.html)

🟡 JS-callable. `platform`/`arch`/`type`/`release`/`machine`/`version`,
`EOL`, `homedir`/`tmpdir`/`hostname`, `cpus`/`totalmem`/`freemem`
(placeholder values), `endianness`, `loadavg`, `uptime`,
`availableParallelism`, `networkInterfaces` (`{}`), `userInfo`,
`constants.signals`, `getPriority`/`setPriority`, `devNull`. Several derive
from `process`/`navigator` rather than syscalls. Zig substrate:
`node/os.zig`, `os_constants.zig`.

### [`node:path`](https://nodejs.org/api/path.html)

🟡 JS-callable. Full POSIX surface (`join`/`normalize`/`resolve`/
`dirname`/`basename`/`extname`/`isAbsolute`/`relative`/`parse`/`format`/
`sep`/`delimiter`), plus `path.posix`/`path.win32` namespaces,
`path.matchesGlob`, `path.toNamespacedPath`. Win32 is a backslash-aware
subset. (The verbatim Bun Zig port at `node/path.zig` is not yet the
backing impl — the current impl is the realm's JS port.)

### [`node:perf_hooks`](https://nodejs.org/api/perf_hooks.html)

🟡 JS-callable — `{ performance, PerformanceObserver (stub) }`. Missing
`PerformanceObserver` actually observing, `performance.mark`/`measure`
entries.

### [`node:process`](https://nodejs.org/api/process.html)

🟡 JS-callable — `require("node:process")` returns the realm's `process`
global: `argv`, `env`, `platform`, `arch`, `version`/`versions`, `pid`,
`cwd()`, `exit()`, `nextTick()`, `stdout`/`stderr` `.write`. Missing:
EventEmitter surface, `hrtime`, `memoryUsage`/`cpuUsage`, signal handlers,
`process.binding`. Zig substrate: `node/process.zig`.

### [`node:punycode`](https://nodejs.org/api/punycode.html)

🔴 Not implemented.

### [`node:querystring`](https://nodejs.org/api/querystring.html)

🟡 JS-callable — `parse`/`stringify`/`escape`/`unescape` (duplicate keys
preserved as arrays). Zig substrate: `node/querystring.zig`.

### [`node:readline`](https://nodejs.org/api/readline.html)

🟡 JS-callable — `createInterface({ input })` reads lines from a Readable
input, emitting `line`/`close` (CRLF-trimmed). `question` is a stub.
Missing: interactive/output mode, history, cursor control.

### [`node:readline/promises`](https://nodejs.org/api/readline.html#promises-api)

🔴 Not implemented.

### [`node:repl`](https://nodejs.org/api/repl.html)

🔴 Not implemented.

### [`node:stream`](https://nodejs.org/api/stream.html)

🟡 JS-callable, flowing-mode on `EventEmitter`: `Readable` (`push`/`read`/
`resume`/`pause`/`pipe`/`Readable.from`/`[Symbol.asyncIterator]`),
`Writable`, `Transform`, `PassThrough`, `Duplex`, and `stream.finished`/
`stream.pipeline` (callback). Missing: object-mode nuances, backpressure,
`highWaterMark`, `cork`/`uncork`, the web-streams bridge. Zig substrate:
`node/stream.zig`.

### [`node:stream/consumers`](https://nodejs.org/api/stream.html#streamconsumers)

🔴 Not implemented.

### [`node:stream/promises`](https://nodejs.org/api/stream.html#streampromises-api)

🟡 JS-callable — `stream.promises.pipeline` / `finished` (also via
`require("node:stream/promises")`).

### [`node:stream/web`](https://nodejs.org/api/webstreams.html)

🔴 Not implemented (no WHATWG `ReadableStream`/`WritableStream`/
`TransformStream` yet).

### [`node:string_decoder`](https://nodejs.org/api/string_decoder.html)

🟡 JS-callable — `StringDecoder` with UTF-8 chunk-boundary handling
(buffers an incomplete trailing multibyte sequence between `write`s);
non-utf8 encodings fall back to whole-chunk `Buffer.toString`. Zig
substrate: `node/string_decoder.zig`.

### [`node:test`](https://nodejs.org/api/test.html)

🔴 Not implemented. Will land as part of `home test` (Phase 12.8).

### [`node:timers`](https://nodejs.org/api/timers.html)

🟡 JS-callable — `setTimeout`/`clearTimeout`/`setInterval`/`clearInterval`/
`setImmediate`/`clearImmediate` (re-exporting the realm's event-loop
timers) + `timers.promises.setTimeout`.

### [`node:timers/promises`](https://nodejs.org/api/timers.html#timers-promises-api)

🟡 JS-callable — `setTimeout(ms, value)` → Promise (via
`require("node:timers/promises")`). Missing `setInterval`/`setImmediate`
async-iterator forms.

### [`node:tls`](https://nodejs.org/api/tls.html)

🔴 Not implemented (needs TLS sockets).

### [`node:trace_events`](https://nodejs.org/api/tracing.html)

🔴 Not implemented.

### [`node:tty`](https://nodejs.org/api/tty.html)

🟡 JS-callable — `isatty()` (returns `false` for now), `ReadStream`/
`WriteStream` stubs. Missing real tty detection / window-size / raw mode.
Zig substrate: `node/tty.zig`, `core/tty.zig`.

### [`node:url`](https://nodejs.org/api/url.html)

🟡 JS-callable — `URL`/`URLSearchParams` (the realm's WHATWG globals),
`fileURLToPath`/`pathToFileURL`, `format`. Missing legacy `url.parse`/
`resolve` (the old `Url` object shape). Zig substrate: `node/url.zig`.

### [`node:util`](https://nodejs.org/api/util.html)

🟡 JS-callable — `inspect`, `format`, `promisify`, `callbackify`,
`inherits`, `deprecate`, `isDeepStrictEqual`, `stripVTControlCharacters`,
`toUSVString`, `debuglog`, `TextEncoder`/`TextDecoder`, `parseArgs`
(long/short/`=value`/clustered/boolean+string/multiple/defaults/
positionals/`--`), and `types.*` (isDate/isRegExp/isPromise/isMap/isSet/
isArrayBuffer/isTypedArray/isAsyncFunction/isNativeError/isAnyArrayBuffer).
Zig substrate: `node/util.zig`, `util/parse_args_utils.zig`, `types.zig`.

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

🟡 JS-callable, **native** (Zig `std.compress.flate`): `gzipSync`/
`gunzipSync`/`deflateSync`/`inflateSync`/`deflateRawSync`/`inflateRawSync`
+ async (callback) `gzip`/`gunzip`/`deflate`/`inflate`. Missing: brotli,
streaming `Gzip`/`Gunzip` transform classes, options (level/strategy).

## Node.js globals

🟡 JS-callable in the realm: `process`, `Buffer`, `console`, the timer
functions (`setTimeout`/`setInterval`/`setImmediate` + `clearX`),
`queueMicrotask`, `fetch` (data:/file:/http(s)), `URL`, `URLSearchParams`,
`TextEncoder`/`TextDecoder`, `crypto` (`getRandomValues`/`randomUUID`),
`performance`, `structuredClone`, `atob`/`btoa`, `global`/`self`. Missing:
`WebSocket`, the WHATWG `*Stream` family, `navigator` (intentionally absent
to prove non-delegation).

## Summary

| Status | Count | % |
|---|---|---|
| 🟢 Fully implemented | 0 | 0% |
| 🟡 Partially implemented (JS-callable subset) | 24 | ~51% |
| 🔴 Not implemented | 22 | ~47% |
| ❌ Won't implement | 1 | ~2% |

🟡 modules (JS-callable via Home's realm — `home eval` /
`HOME_NATIVE_RUN`): `assert`, `buffer`, `child_process`, `console`,
`constants`, `crypto`, `events`, `fs`, `fs/promises`, `os`, `path`,
`perf_hooks`, `process`, `querystring`, `readline`, `stream`,
`stream/promises`, `string_decoder`, `timers`, `timers/promises`, `tty`,
`url`, `util`, `zlib`.

Still 🔴 (the next frontier — mostly sockets/networking + heavy runtime):
`net`, `http`, `https`, `http2`, `tls`, `dgram`, `dns`, `worker_threads`,
`vm`, `cluster`, `repl`, `wasi`, `inspector`, `module`, `async_hooks`,
`trace_events`, `diagnostics_channel`, `punycode`, `readline/promises`,
`stream/consumers`, `stream/web`, `test`.

**Honest caveats:** (1) 🟡 = a useful subset callable through Home's own
JSC realm, not a full module nor Node-test-suite-verified; (2) these are
**not** yet wired into the bun-corpus gate (which still routes through the
bootstrap text-rewrite harness), so they do not yet move the corpus
pass-count — that needs the loader/runtime convergence work tracked in
[`BUN_PARITY_PLAN.md`](./BUN_PARITY_PLAN.md).
