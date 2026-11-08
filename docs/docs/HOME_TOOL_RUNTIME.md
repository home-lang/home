# Home repository-tool runtime

`home-tool` runs standalone JavaScript and TypeScript repository utilities on
Home's own TypeScript frontend and a native JavaScript engine. It does not
delegate parsing or execution to Node, Bun, or Python.

Execution parses, binds and emits through Home's TypeScript frontend without running semantic typechecking over application code or bundled JavaScript. Syntax errors remain failures. Static validation remains the separate `home-tsc`/compiler path; the runtime's emission path does not replace an explicit typecheck command.

Build it with zig-js (the default when the conventional checkout and archive
exist):

```sh
zig build home-tool \
  -Dtool-js-engine=zig-js \
  -Dzig-js-root="$HOME/Code/Libraries/zig-js"
```

The checkout may instead be selected with `HOME_ZIG_JS_ROOT`. The zig-js
backend links only zig-js's public JavaScriptCore-shaped C API. Home's private
WebKit/Bun ABI remains confined to the production runtime and is not part of
the repository-tool contract.

On macOS, the system JavaScriptCore backend remains available for differential
testing:

```sh
zig build home-tool -Dtool-js-engine=jsc
```

Run TypeScript without a separate transpilation step:

```sh
zig-out/bin/home-tool run path/to/tool.ts --tool-argument
zig-out/bin/home-tool eval 'const answer: number = 40 + 2; answer' --print
```

Tools receive `console`, `process`, and a deliberately small `Home` host API:

- `Home.engine` reports `zig-js` or `jsc`.
- `Home.readTextFile`, `Home.writeTextFile`, and `Home.fileExists` provide
  synchronous repository-file access.
- `Home.readFileHex` and `Home.writeFileHex` preserve arbitrary binary bytes
  through an engine-neutral lowercase hexadecimal transport.
- `Home.spawnSync(argv)` resolves the executable through `PATH` and returns
  `{ exitCode, stdout, stderr }`.

The `events`/`node:events` adapter exports a real synchronous EventEmitter
constructor. Listener registration, prepend/once behavior, dispatch snapshots,
one-at-a-time removal, meta-events, symbols, error monitoring/propagation and
maximum-listener state/warnings execute in the selected engine. Legacy call
constructors and subclasses share that implementation. The tool realm installs
it on the process object before user listeners exist, preserving the native
process capabilities and natural exit path. Both module aliases and ESM/CJS
imports share constructor identity.

This is a bounded synchronous events surface. Promise/async-iterator helpers,
EventTarget/AbortSignal integration and async-resource APIs remain absent;
captureRejections=true is explicitly refused. Warnings use Home's existing
synchronous process.emitWarning delivery and do not claim Node's warning timing
or exact diagnostic wording/default stderr behavior. Unhandled non-Error event payloads preserve code
and context, but message formatting is not a Node inspect implementation. This
does not supply a Bun/Node test scheduler or a resource event loop.

The `tty`/`node:tty` adapter exposes native `isatty` on macOS/Linux. Valid
integer descriptors query libc in the actual process; pipes and real PTYs
produce different results. Invalid/out-of-range/non-number inputs return false
without coercion, matching Node. Bun 1.4.4 throws for some such values (including
BigInt), and that reference difference is retained. Other platforms refuse the
native query. ReadStream, WriteStream, raw mode and the full terminal/process
stream surface remain unsupported; descriptor classification does not provide
terminal I/O or an event loop.

process.nextTick validates callback arguments synchronously. A thrown callback
is sent to uncaughtExceptionMonitor and uncaughtException with its original
value and origin. Without a handler it terminates with status 1 before later
ticks; a throwing handler terminates with status 7. Fatal callbacks emit exit
and honor an exit listener's explicit status update. Scheduling still uses
Promise microtasks; this is not Node's complete tick-queue ordering.

With zig-js, the tool consumes real engine rejection notifications through
ZJSContextTakeUnhandledRejection after entry completion and each rejection-event
checkpoint. Original reason/Promise values reach unhandledRejection listeners;
otherwise monitor/uncaughtException handlers receive the rejection, and absent
handlers cause a nonzero exit. Primitive reasons are wrapped in an Error with
ERR_UNHANDLED_REJECTION. The private fatal handler stays protected outside
JS-visible state. Rejections handled during the preceding checkpoint are omitted;
this does not replace or wrap Promise. Late rejectionHandled notifications and
a general I/O event loop remain unsupported. System JSC has no corresponding
hook in this tool's public-C profile and can still return zero for an unrelated
rejected Promise. The explicit home-tool-rejections-smoke capability gate fails
on that backend; common host smokes alone do not certify rejection reporting.

The `readline`/`node:readline` adapter supplies cursorTo, moveCursor, clearLine
and clearScreenDown. These write real ANSI sequences to the supplied destination
and preserve its write result, callback and errors. Operations with no output
defer their completion callback through process.nextTick, following Node. Input
interfaces, keypress decoding, prompts, questions and readline/promises are
absent: the tool still needs actual input streams and an I/O event loop. The
existing process.stdout.write writes bytes but does not yet implement Node's
write callbacks; the helpers do not invent successful callback completion for it.

The `util`/`node:util` adapter supplies stripVTControlCharacters for primitive
strings using Node's CSI/terminated-OSC recognizer. It removes actual terminal
control sequences, including colon-delimited SGR and Unicode/newline OSC data;
non-string arguments fail with ERR_INVALID_ARG_TYPE. inspect, format, promisify,
types and the remaining Node utility surface are absent.

The `stream`/`node:stream` aliases provide owned EventEmitter-based Readable,
Writable, Duplex, Transform and PassThrough classes. These move actual managed
bytes or objects through queues, honor highWaterMark backpressure and drain,
and wait for write/final/flush callbacks. Readable.from consumes synchronous or
asynchronous iterables; read, push, pause/resume and single-destination pipe
operate on real buffered data. Pipelines destroy failed stages and await actual
iterator/resource cleanup callbacks. Missing provider callbacks leave completion
pending rather than fabricating finish or EOF.

The shared stream/promises namespace supplies pipeline and finished for owned
streams; callback pipeline is also supported. The implementation is a bounded
profile, not the full Node stream implementation. Native file/terminal streams,
outbound async iteration, string decoders/setEncoding, cork/writev, construct,
AbortSignal/Web Streams, multi-destination pipes and callback finished cleanup
are absent or explicitly refused. Unrecognized constructor/helper options are
refused. Native file-copy witnesses remain failed until fs stream adapters and
their actual I/O exist; passing in-memory flow does not certify file I/O.

The zlib/node:zlib aliases expose gzipSync, gunzipSync, Gzip and createGzip.
The native Zig RFC 1952 compressor produces actual compressed binary bytes;
gunzipSync validates header flags/header CRC, each member's data CRC/ISIZE,
concatenated members and truncation. Inputs are strings, Buffers or Uint8Arrays.
Compression input and decompressed output are limited to 2 MiB; compressed input
is limited to 2 MiB + 1/8 of that + 1024 bytes. Exceeding a limit fails with
ERR_BUFFER_TOO_LARGE rather than silently returning partial data.

Gzip is a bounded managed Transform: it acknowledges actual input copies,
retains at most 2 MiB, compresses on finalization and emits the real result.
It has no incremental output guarantee. Pipeline/finished wait for the actual
stream operations, and failures destroy stages and propagate their real errors.
Only default compression options and stream highWaterMark are accepted; flush
and other options are explicitly refused. Asynchronous compression callbacks,
Gunzip streams, deflate/raw/Brotli/Zstd and compression parameter/reset APIs are
absent. Passing bounded in-memory gzip does not certify native file/stdio I/O.

The performance global and perf_hooks/node:perf_hooks aliases share an actual
Performance instance with now, timeOrigin and toJSON. now reads the native OS
monotonic clock relative to this tool realm's initialization; timeOrigin is its
fixed wall-clock epoch sample. Clock failures throw instead of returning zero.
Node timing/event-loop telemetry, marks/measures, observers, resource entries
and timer scheduling are absent. toJSON reports only the supported timeOrigin.

With zig-js's execution-context extensions, async_hooks/node:async_hooks expose
AsyncLocalStorage run, getStore, enterWith and exit. Immutable per-instance store
snapshots live in the engine's rooted execution slot; actual Promise/await,
queueMicrotask and Home nextTick callbacks inherit the snapshot captured when
registered. Nested runs restore original identity on throws, overlapping async
tasks stay isolated, and exit shadows only its own instance. Promise.then is not
patched and there is no global ambient-store variable. Callback receivers follow
Node's null receiver; Native Bun 1.4.4 uses undefined for strict callbacks.

The module is absent on the system-JSC backend because it has no matching
execution-context primitive. The explicit home-tool-async-context-smoke gate
fails when requested there; the zig-js ecosystem bootstrap must run this gate.
Disable/lifecycle hooks, AsyncResource, static bind/snapshot, constructor options
and context inheritance for unsupported async sources (including rejection-event
dispatch and timers) are not implemented. Refusals and reference differences
remain capability failures; this is not the complete Node async_hooks surface.

The shared Bun/bun namespace also exposes file for string filesystem paths.
Its argv property initially shares the actual process.argv array, including
the native executable, canonical entry and user arguments. Array mutations
share identity; replacing either property subsequently follows ordinary data
property behavior. Bun.argv is writable/enumerable and nonconfigurable.
This is a readonly file source, not a Web Blob: exists, text, json, bytes,
arrayBuffer, size and existing-file lastModified use actual native stat/read
operations. Byte reads preserve all bytes and return independent managed data;
text consumes one UTF-8 BOM and replaces invalid UTF-8, and JSON parsing rejects
invalid data. Missing paths and directory reads retain actual filesystem errors.
The methods return real promises; their underlying OS operations are synchronous.

Reads are limited to 8 MiB in the native reader, including an exact-limit test
in the common host gate. Reads of non-regular special files are refused. If previously
observed metadata changes, the source refuses further operations: mutable-file
caching/clipped-read behavior is not implemented. Slice/stream/writer/mutation
methods, MIME/type metadata, missing-file lastModified, URL/descriptor paths and
nonempty file options are explicitly refused. File sources do not claim Blob
branding or integration with Response; native file/stdio stream adapters remain
separate work.

The `crypto`/`node:crypto` adapter exposes synchronous randomBytes with real
managed Buffer storage. It obtains fresh OS entropy through Zig Io.randomSecure;
entropy failure throws instead of returning zeros or using a weak seed. Numeric
size validation and fractional-size truncation follow Node. Callback-based
randomBytes is explicitly refused because this tool has no asynchronous crypto
host. Ciphers, hashes, keys, Web Crypto and the remaining Node crypto surface are
not supplied by this adapter.

The `buffer`/`node:buffer` aliases and global Buffer share a bounded Buffer
implementation backed by real, engine-managed Uint8Array/ArrayBuffer storage.
from accepts primitive strings, arrays, typed views, raw ArrayBuffers and
Buffer JSON data, plus shared ArrayBuffers when the engine exposes them. The
system-JSC reference realm does not expose SharedArrayBuffer. Typed sources copy; views created from raw ArrayBuffers and slice/subarray share
backing storage, and inherited typed-array map operations preserve Buffer species.
alloc, concat, byteLength, isBuffer, equals, fill, byte/string search, toJSON and UTF-8/hex toString
operate on actual bytes. UTF-8 encoding replaces isolated surrogates and decoding
reuses the owned filesystem decoder, retaining NULs/BOMs and malformed-sequence
replacement. Hex decoding uses Node's byte-wise character behavior and stops at
invalid pairs; byteLength measures hex input length independently.

This is not the complete Node Buffer surface. Other codecs (including base64),
numeric read/write helpers, pooled/unsafe allocation, deprecated constructors,
general array-like/valueOf coercion, and the full buffer module exports remain
unsupported. Missing methods stay absent and recognized unsupported codecs fail
explicitly. No native Bun runtime, external memory stand-in or Node/V8 slab
allocator supplies these bytes.

The `process` and `node:process` module aliases expose the existing live Home
`process` object, including its real environment, arguments, current directory,
next-tick queue and exit handling. They do not manufacture additional Node
process methods; unsupported fields remain absent.

The `os`/`node:os` adapter implements POSIX `homedir`: it honors string HOME
values (including empty strings), then queries the real current-user account
via reentrant `getpwuid_r` when HOME is absent, on macOS/Linux. Native lookup
failure throws. Other os APIs remain absent. Node is the oracle for mutable HOME
behavior; Bun 1.4.4 caches its home directory and differs on these witnesses.

The tool module loader exposes the same real filesystem adapter as `fs` and
`node:fs`: `existsSync` and `readFileSync` with explicit `utf8`/`utf-8` encoding
and string paths. Reads use native file bytes, preserve embedded NULs and BOMs,
and replace malformed UTF-8 sequences. The checked-in byte fixture and its
Node-produced expected JSON cover Unicode boundaries and malformed input.
Buffer-returning reads, other encodings/flags and URL/Buffer paths still require
implementations and remain errors. Native read errors
propagate; complete Node filesystem error metadata is not provided yet.

The `fs/promises` and `node:fs/promises` aliases share `fs.promises`. Supported
operations perform real native I/O: UTF-8 `readFile`, default-mode `mkdir`
(including the first-created-ancestor return for recursive creation), `rm`
(including recursive/force behavior and unlinking symlinks), and `stat`. Stat
returns actual kind predicates, size, inode, link count and available access,
modification and change times; this is a subset of Node's Stats fields.
The methods return real promises, but native filesystem work currently blocks
the tool thread. Buffer/URL paths, binary reads, custom permissions, retry,
bigint, abort and other options are unsupported rather than silently ignored.
Other fs promises methods remain absent. The disposable filesystem smoke checks
native reads/metadata, missing/existing paths, recursive deletion and that a
symlink never causes deletion of its target. Await result/member/call/exponent
precedence is preserved by the Home emitter.

`module`/`node:module` expose `createRequire` for absolute POSIX filenames and
file URL strings. The returned require resolves relative files, package imports
and offline packages from that referrer, sharing the real module cache. The
referrer need not exist; a trailing slash anchors a directory. `require.resolve`
does not parse or execute its target. URL objects, Windows referrers, and other
Module APIs still require implementations.

On POSIX hosts, `path`/`node:path` and `path/posix`/`node:path/posix` share
`normalize`, `isAbsolute`, `join`, `resolve`, `dirname`, `basename`, `sep` and
`delimiter`. basename accepts string paths and an optional string suffix, retaining
Node's measured trailing-separator and whole-component suffix behavior.
`url`/`node:url` provide `fileURLToPath` for local POSIX file URL strings, with
URL escaping, dot segments, scalar-value conversion and query/fragment handling.
The Node-produced path/URL fixture retains both successful results and errors.
Other path methods, Windows path behavior, URL objects and other URL APIs still
require implementations.

`Bun.Glob` and the `bun` module's `Glob` share a real POSIX filesystem adapter.
`scanSync` returns an iterator and `scan` an async iterator; both enumerate native
directory entries when iteration starts, using Home's existing glob matcher.
Relative component patterns support *, **, ?, character classes, escapes and
brace alternatives without slashes. Explicit dot components, dot/absolute/
onlyFiles options, string or object cwd, and leading ./ are retained. Ordinary
scans exclude symlinks with onlyFiles:true and yield link names without traversal
with onlyFiles:false, including broken links. match uses the shared string matcher
(including negation and dot characters), independently of filesystem scan policy.

Enumeration currently materializes a bounded scan on the calling tool thread;
async iteration does not claim nonblocking native filesystem work. Native errors
propagate. Symlink traversal, absolute/parent/negated scan patterns, braces that
cross path components or select leading-dot alternatives, non-UTF-8 filenames,
and unknown options fail explicitly. Option fields use strict string/boolean
validation. The scan refuses more than 100,000 entries, depth above 128, patterns
above 4096 bytes/128 components or exhausted matching budgets instead of returning
partial success. Other Bun APIs remain absent until implemented.

`Bun.YAML.parse`, `require("bun").YAML.parse` and `Home.parseYAML` use Home's
owned native YAML parser. The tool backend keeps scalar/collection storage in a
scoped thread-local arena and transfers a reference graph into the selected JS
engine, preserving shared aliases, non-finite numbers and safe own properties.
Raw illegal YAML characters fail. The Bun-produced fixture checks 43 targeted
value/error cases on both backends; property insertion order is not compared.
This is a bounded YAML parse surface. Cyclic aliases, complex collection keys,
sources beyond native recursion/graph-depth limits, lone-surrogate input and
`YAML.stringify` remain unsupported or failing and are retained as capability
gaps. Other Bun host APIs still require implementations.

`child_process`/`node:child_process` expose synchronous `execFileSync` for an
absolute POSIX executable with `stdio: "inherit"`. The OS descriptors are
inherited directly, cwd and environment replacement are applied, and real exit
status/signal failures are thrown. This is sufficient for native-tool launchers
such as TypeScript 7. Captured Buffer results, PATH lookup, timeouts, other
options and asynchronous child APIs still require implementations and fail
explicitly. `Home.spawnSync` also accepts `stdio: "inherit"`; its default
captured-output mode is unchanged, and inherited mode does not accept a timeout.

The runner resolves relative and absolute modules plus offline `node_modules`
packages. TypeScript/JavaScript modules emit to CommonJS, JSON modules load
directly, package `main`/`module` entries and `index.*` fallbacks are supported,
and the cache is populated before evaluation so CommonJS cycles terminate.

Runtime `compilerOptions.paths` aliases use the nearest tsconfig.json, Home's
owned JSONC/config-chain parser, and the config's baseUrl (or the path map's
original config directory). Relative/string extends and left-to-right extends
arrays retain their actual origins; exact keys precede the longest-prefix
wildcard match (longest suffix breaks ties), and target fallbacks run in order. Aliases can apply inside
node_modules, as Bun does; a dependency's own nearer config takes precedence.
Canonical module-cache identity and lookup-only require.resolve are preserved.
Malformed/missing/circular configs fail instead of recovering into runtime
defaults, and declaration-only targets are refused rather than executed as empty
modules. Standalone baseUrl bare-name fallback and paths with multiple stars
remain unsupported. Bun 1.4.4 fails the array-extends witness; Home uses its owned
TypeScript config-chain behavior and retains that reference difference.

Bare packages honor package.json `exports`, including scoped names and package
self references. Static imports and re-exports select `import`; source require
and require.resolve select `require`. Both activate `node`, with `default` and
nested conditions evaluated in JSON order. Exact keys precede the most specific
single-star pattern; targets may repeat the star. Null/excluded subpaths remain
blocked even when files exist. Array targets follow resolver fallback semantics,
not file-existence fallback: a missing first selected file fails. Export targets
are exact files and cannot use extension/directory-main fallback or traversal,
including escaped dot/node_modules segments. Lookup never executes a target.

This is a Node condition profile: `bun`, `types`, `development`, custom CLI
conditions, node-addons and module-sync are not active. Export targets containing
raw query, fragment or backslash syntax are explicitly refused with
ERR_HOME_PACKAGE_TARGET; full file-URL module identity remains unimplemented.
Legacy packages without exports retain Home's existing main/module/index and
TypeScript extension lookup. Relative-path resolution is unchanged.

Package-private `#name` imports support exact, unconditional `./file` targets
from the nearest `package.json`. Missing or null mappings remain errors, and
lookup stops at package and `node_modules` boundaries. Targets do not use
extension or directory fallbacks. Conditional, wildcard, external-package and
URL-encoded targets still require additional resolver support; they are refused.

The host supplies the CommonJS emitter's default and namespace import helpers. ES-module exports keep their module identity, while CommonJS objects and primitive exports receive the appropriate default binding. This allows executable entry points to use ordinary TypeScript import interoperability without relying on ambient helpers from Node or Bun.

Mixed default/named and default/namespace imports use one module load per
declaration and distinct temporaries reserved against parsed source names.
Repeated mixed imports do not redeclare a shared `_mod` helper, and namespace
bindings are initialized even when the same declaration also imports a default.

Generated ES-module export assignments use a host binding absent from every
source scope, so an import or local declaration named `module` cannot collide
with the CommonJS wrapper. Ordinary source identifiers retain their meaning,
and the wrapper still receives five arguments.

The tool's ESM-to-CommonJS host profile also evaluates acyclic top-level-await
module graphs. Static import/re-export edges come from parsed HIR; dependencies
finish before an importing body runs, while independent siblings can evaluate
when an earlier dependency is suspended. A fresh static-import accessor remains
separate from explicit source `require()`, which rejects async graphs with
`ERR_REQUIRE_ASYNC_MODULE`. Raw CommonJS exports and namespaces with a `then`
export are not assimilated as evaluation promises. Sync CommonJS cycles retain
the existing partial-exports behavior.

The native runner protects a private completion closure across the engine's
microtask checkpoint and checks it before natural exit. Rejections (including
`throw undefined`) fail; an unsettled entry fails with
`ERR_HOME_UNSETTLED_MODULE`. This is not a complete ESM implementation: async
cycles are explicitly refused with `ERR_HOME_ASYNC_MODULE_CYCLE`, the existing
CommonJS lowering does not provide full ESM live-binding/TDZ/namespace semantics,
and dynamic import and event-loop-backed I/O require separate implementations.
No await is stripped and no external JavaScript runtime evaluates these modules.

After successful evaluation, the runner emits the natural process `exit` event
and returns the effective `process.exitCode` to the caller. Exit-listener code
changes are honored, and a thrown exit listener fails the command. Smoke gates
exercise nonzero statuses, deferred assignments, listener failures and native
eight-bit status wrapping; a zero exit is not substituted for a script's status.

The tool frontend lowers `import.meta` for its CommonJS wrapper without changing strings, comments or ordinary member names. Each module receives one extensible, null-prototype metadata object with `url`, `path`, `dir`, `file`, `main`, `filename`/`dirname` aliases, `env` and the local `require`. File paths are canonical and file URLs escape reserved characters. Metadata remains lexical inside nested functions and shares module-cache identity across relative and absolute imports. `import.meta.resolve` and `glob` still require separate host implementations.

Use `zig build home-tool-smoke` with either engine selection to verify
TypeScript emission, module loading, filesystem access, process execution, and
argument setup.

## Representative consumer regression

The zig-js representative benchmark is also an end-to-end checker and runtime
probe. From a zig-js checkout whose archive was used to build `home-tool`, run:

```sh
/path/to/home/zig-out/bin/home-tool \
  run tools/representative-benchmark.ts --self-test
```

The command must exit zero and print `OK representative benchmark self-test`.
It covers the full 854-line tool and its imports, including member-call `this`
checking after contextual diagnostics have been updated. A compiler diagnostic
is a normal checked failure; a checker panic or signal exit is not. Issue #834
was verified with this command at a 55 MB supervised peak, in
addition to the complete checker and normal conformance suites.
