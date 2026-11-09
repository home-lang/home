# Home repository-tool runtime

`home-tool` runs standalone JavaScript and TypeScript repository utilities on
Home's own TypeScript frontend and a native JavaScript engine. It does not
delegate parsing or execution to Node, Bun, or Python.

Execution parses, binds and emits through Home's TypeScript frontend without running semantic typechecking over application code or bundled JavaScript. Syntax errors remain failures. Static validation remains the separate `home-tsc`/compiler path; the runtime's emission path does not replace an explicit typecheck command.

JSDoc syntax diagnostics inspect comment trivia rather than marker text inside
strings or template literals. Line comments, ordinary block comments and empty
`/**/` comments do not introduce nested JSDoc tags. Genuine JSDoc diagnostics,
including duplicate return tags, remain active. The runtime smoke executes a
nested regexp-based comment emitter to check both parsing and emitted behavior.

Noncomputed object and method names use string-literal quoting even when a
template would need fewer escapes. Newlines, CRLF, mixed quotes and lone
surrogates retain their exact property keys. Ordinary string expressions can
still use template-literal quoting.

Single-statement clauses and labeled bodies preserve the same expression
grouping as top-level statements. Object destructuring assignments retain the
parentheses that distinguish them from blocks, including if/else, while,
for and do/while bodies.

Object-literal async methods accept keyword, string, numeric, BigInt and
computed property names while enforcing the no-line-terminator restriction
after async. BigInt names preserve their exact decimal property key; emitted
numeric-looking string keys remain quoted when a Number literal would change
their spelling or precision. TypeScript's TS1539 diagnostic for ordinary
BigInt property assignments is retained; TypeScript 6.0.3 permits those names
on methods. Node 26 executes the complete method witness, while Bun 1.4.4
rejects its BigInt method syntax; that reference failure remains explicit.

At statement starts, `type = value` executes as a contextual identifier
assignment, including blocks and exported function bodies. Named type aliases
keep their declaration parsing and runtime erasure. Explicit declare/export
modifiers retain malformed-declaration recovery without applying it to nested
value assignments. Required JS and TypeScript witnesses check both behaviors.

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
zig-out/bin/home-tool --conditions development run path/to/tool.ts
zig-out/bin/home-tool eval 'const answer: number = 40 + 2; answer' --print
```

Exported TypeScript enums retain their initialized runtime objects through
Home's CommonJS lowering, including enums exported as namespace members.
Static imports, dynamic imports and require share those objects; numeric
reverse mappings and merged declarations retain their values. A local enum
named module does not replace the loader's lexical module binding.

Tools receive `console`, `process`, and a deliberately small `Home` host API:

- `Home.engine` reports `zig-js` or `jsc`.
- `Home.readTextFile`, `Home.writeTextFile`, and `Home.fileExists` provide
  synchronous repository-file access.
- `Home.readFileHex` and `Home.writeFileHex` preserve arbitrary binary bytes
  through an engine-neutral lowercase hexadecimal transport.
- `Home.spawnSync(argv)` resolves the executable through `PATH` and returns
  `{ exitCode, stdout, stderr }`.

`Bun.markdown.html` and the `markdown` export from `bun` render through Home's
owned native CommonMark/GFM parser on either engine backend. Strings, boxed
strings, Buffer/typed-array byte ranges, ArrayBuffer and DataView inputs use
actual bytes; malformed UTF-8 is replaced on HTML string conversion. The HTML
bridge preserves NUL and supplementary characters with a length-bearing public
C string constructor. Tables, task lists, strikethrough, autolinks, heading IDs
and heading links, plus the parser's boolean extension flags, follow the same
native option handling (including camelCase/snake_case aliases). Invalid inputs
and throwing option getters remain failures. Parser stack/allocation failures
are surfaced, and shared heading-tracker allocations are released after render.
An option getter that detaches or changes the binary view's byte length is
refused with ERR_HOME_MARKDOWN_BUFFER_CHANGED. Full Bun native buffer-pinning
parity is not provided; an already-detached raw ArrayBuffer is refused too.
This exposes the HTML method; ANSI, custom callback and React methods are not
part of this tool adapter. It does not add a test scheduler.

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

`fs.readdirSync` and `fs/promises.readdir` enumerate the actual native directory.
The default returns UTF-8 names; withFileTypes:true returns entry objects with
name, parentPath and all seven file-kind predicates. Symlinks retain their own
kind, including broken links; unknown directory-entry types use a no-follow
stat relative to the open directory. Each call observes current filesystem
contents and preserves actual OS failures. Native enumeration is synchronous
even for the Promise facade. This bounded profile accepts string paths, UTF-8
encoding and boolean withFileTypes; recursive:true, alternate encodings and
unknown options are refused. Names must be valid UTF-8, with at most 100,000
entries and 8 MiB of name bytes; a limit/error fails the entire listing. This
does not expose the full Dirent constructor, opendir or callback API. A required
common witness creates real files, directories, symlinks, a FIFO and a Unix
socket using Python only for native fixture preparation, then executes all JS
operations on the selected Home artifact. Native allocation-failure probes
also verify partial-list ownership.

The `util`/`node:util` adapter supplies stripVTControlCharacters for primitive
strings using Node's CSI/terminated-OSC recognizer. It removes actual terminal
control sequences, including colon-delimited SGR and Unicode/newline OSC data;
non-string arguments fail with ERR_INVALID_ARG_TYPE. inspect, format, promisify
and the remaining Node utility surface are absent.

`util.types`, `util/types` and `node:util/types` share the same native-brand
adapter. The zig-js backend supports `isPromise` and `isProxy` through its
explicit C extensions. It inspects actual slots, including Promise subclasses
and revoked/callable proxies, without consulting prototypes, thenables or
toStringTag getters. Inspection neither attaches Promise reactions nor changes
rejection handling. A Proxy wrapping a Promise is a Proxy, not a Promise.
Other types predicates remain absent. The JSC reference backend has no matching
brand provider and throws ERR_HOME_UNSUPPORTED for these methods; it does not
substitute heuristics or false results.

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
dispatch) are not implemented. Refusals and reference differences
remain capability failures; this is not the complete Node async_hooks surface.

`setTimeout`/`clearTimeout` and `setInterval`/`clearInterval` globals and
`timers`/`node:timers` aliases share a native host queue. `timers/promises` and `node:timers/promises` expose
setTimeout resolving the supplied value after the actual deadline. Registration
returns immediately; after current script/jobs finish, the owner thread waits
on macOS kqueue timer events or Linux monotonic timerfd/poll events. Earliest
deadlines dispatch first, with a job/rejection checkpoint after each callback.
Intervals rearm from callback start and can cancel themselves by handle or id.
This is a timer task loop, not a general I/O or test scheduler.

Handles support ref/unref/hasRef and numeric cancellation. Unreferenced timers
do not keep the process alive but can fire while referenced tasks remain.
Canceled handles retain their reference state as in Node 26; Bun 1.4.4 differs.
Callbacks retain their receiver/arguments and original thrown values reach the
existing monitor/uncaught handler; fatal callbacks and throwing handlers exit
with statuses 1 and 7 respectively. With zig-js, protected callback closures
retain actual engine async-context snapshots and restore them inside active JS
execution, including exception dispatch. There is no ambient JS context store.
Native queue state is scoped per CLI invocation and owner thread, checked
against its context and never shared with another JS thread. Pending callbacks
remain C-API protected until cancellation, dispatch or queue destruction.

Immediates, refresh, AbortSignal and other lifecycle APIs remain
absent or explicitly refused. The bounded host removes inherited engine-owned
immediate globals rather than mixing independent queues and exception
policies. Promise options accept ref; unknown options and signals fail with
ERR_HOME_UNSUPPORTED. Delay coercion/clamping and warning categories follow
the measured Node profile, with Home's existing synchronous warning delivery.
The home-tool-timers-smoke gate is included in home-tool-smoke; timer context
and rejection witnesses also run in their respective explicit capability gates.

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
Text and JSON reads use native WHATWG UTF-8 decoding and a length-bearing UTF-16
result. They retain embedded NULs and supplementary characters without the
hexadecimal transport used for raw byte reads. The common gate checks every
two-byte input combination against a pinned Node-generated decoder oracle.
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

`Bun.env` and the `bun` module's env export share that OS-sourced environment
bag. The env property is enumerable, read-only and nonconfigurable, matching
Bun 1.4.4. Values follow Home's existing process.env semantics: the startup
environment is captured from the native process, and string mutations/deletions
remain visible through every alias. Explicit execFileSync env options forward
the current bag to real native children.
Home's ESM lowering currently lacks implicit strict assignment errors. The
readonly-property witness uses explicit strict code; that separate semantic
gap remains outside the supported profile.

`fs.statSync` and `fs.lstatSync` query native metadata synchronously, following
or retaining the final symlink respectively. The bounded numeric metadata
profile exposes size, inode, link count, timestamps/Date values and seven file
kind predicates, sharing conversion with promised stat. String paths and
`bigint: false` are supported; BigInt metadata and additional options are
explicitly refused. With `throwIfNoEntry: false`, stat suppresses ENOENT and
ENOTDIR; lstat suppresses ENOENT while retaining ENOTDIR, matching Node 26.
Permission and symlink-loop errors remain failures. Bun's ENOTDIR suppression
and empty-path error-property differences are retained as reference differences.

The `os`/`node:os` adapter supplies platform from the original native process
object. Reads follow that object's current platform property, matching Node 26
under property redefinition; replacing globalThis.process keeps the original
binding. Bun 1.4.4 retains its native platform constant in that experiment, and
the reference difference remains explicit.

`os.EOL` is initialized from the native platform (`\n` on supported POSIX
hosts) and remains fixed when callers later redefine process.platform. Module
aliases and named imports share that value. It is an enumerable, configurable,
nonwritable data property, matching Node; Bun exposes an accessor instead.

The adapter also implements POSIX `homedir`: it honors string HOME
values (including empty strings), then queries the real current-user account
via reentrant `getpwuid_r` when HOME is absent, on macOS/Linux. Native lookup
failure throws. Other os APIs remain absent. Node is the oracle for mutable HOME
behavior; Bun 1.4.4 caches its home directory and differs on these witnesses.

The tool module loader exposes the same real filesystem adapter as `fs` and
`node:fs`: `existsSync` and string-path `readFileSync`. Reads without encoding
(or with null encoding) return independent managed Buffers containing native
bytes. Explicit `utf8`/`utf-8` encoding returns a string. Promised `readFile`
shares this read profile. Reads preserve embedded NULs and BOMs,
and replace malformed UTF-8 sequences. The checked-in byte fixture and its
Node-produced expected JSON cover Unicode boundaries and malformed input.
Other encodings/flags and URL/Buffer paths remain explicitly unsupported;
the native file-read limit is 8 MiB. Native read errors
propagate; complete Node filesystem error metadata is not provided yet.

`fs.accessSync` and `fs.promises.access` check actual native access permissions
for string paths on macOS/Linux. The shared `constants` object exposes the four
access flags `F_OK`, `R_OK`, `W_OK` and `X_OK`, including combined modes. Checks
follow symbolic links and retain actual existence, permission, symlink-loop and
non-directory errors. Success returns undefined; the Promise facade rejects on
failure. This is an access-flag subset, not the full Node constants table.
Access checks do not reserve a path or prevent subsequent filesystem races.

`openSync`, `writeFileSync`, `fsyncSync` and `closeSync` use actual OS file
handles on macOS/Linux. Supported open/write flags are `r`, `r+`, `w`, `w+`,
`wx`, `wx+`, `a`, `a+`, `ax` and `ax+`. Numeric flag masks and other flag
variants remain unsupported. Synchronous writes accept a string path or a real
numeric descriptor, UTF-8 strings and exact Buffer/typed-array/DataView byte
ranges. Descriptor writes keep the existing kernel offset and append state;
write options never reopen a descriptor. Exclusive creation and append are
kernel operations, not existence checks followed by ordinary writes.

`fsyncSync` calls the native fsync syscall and propagates its errors, including
invalid descriptor/pipe failures. Short writes and interrupted writes are
continued; interrupted close is reported without retrying a possibly reused
descriptor. File descriptors opened by this host are tracked per owner thread
and context, set close-on-exec, and closed when runSource ends. Explicit close
removes ownership before reuse. Inherited descriptors perform real operations
but are not automatically closed by host teardown. This remains a blocking
profile; callback APIs, FileHandle/read/writeSync/positional I/O, general async
I/O scheduling and complete Node metadata require separate implementations.

The `fs/promises` and `node:fs/promises` aliases share `fs.promises`. Supported
operations perform real native I/O: UTF-8 `readFile`, `mkdir`
(including the first-created-ancestor return for recursive creation), `rm`
(including recursive/force behavior and unlinking symlinks), and `stat`. Stat
returns actual kind predicates, size, inode, link count and available access,
modification and change times; this is a subset of Node's Stats fields.
`writeFile` writes actual UTF-8 string bytes or the exact byte ranges of
Buffer/typed-array/DataView inputs, creates or truncates files, and propagates
native errors through its returned promise. It supports UTF-8 encoding, the
same string flags as openSync and POSIX creation permissions from `0` through
`0o7777`, as numbers or octal strings. The default file mode is `0o666`;
mkdir defaults to `0o777` and applies its mode to each newly created recursive ancestor. The native umask
restricts these modes. Existing file and directory permissions remain unchanged.
String conversion preserves NUL and replaces lone surrogates without losing
the remaining text. Iterable input and other write options are explicitly
unsupported; raw ArrayBuffer data is rejected as in Node.
The methods return real promises, but native filesystem work currently blocks
the tool thread. Buffer/URL paths, binary reads, non-permission mode bits, retry,
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

Additional package export conditions can be enabled before `run` or `eval`
with repeated `--conditions <name>` or `--conditions=<name>` flags. They apply
to static imports, dynamic imports, require and require.resolve in that tool
realm. JSON key order decides priority, not flag order; commas stay part of a
single condition name. Flags after the entry filename remain tool arguments.
The default Node condition profile does not activate `bun`, `types`,
`development`, node-addons or module-sync unless explicitly requested. Custom
conditions do not extend the bounded package-private imports profile below.
Export targets containing
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

Dynamic import in modules run by home-tool uses a separate, collision-free host
accessor. Specifier conversion runs synchronously with the string hint; conversion,
resolution and evaluation failures reject real promises. Module loading runs after
the current turn and uses import conditions, the lexical referrer, the same module
records and acyclic async graph evaluation. Concurrent/repeated imports share
execution and namespace identity, and failed ESM evaluations retain their error.
POSIX file URL strings without query/fragment identity are supported. Explicit
source require stays synchronous and still refuses async graphs.

The adapter returns cached, nonextensible null-prototype namespace views. CommonJS
gets its actual exports as default, with runtime enumerable names; this does not
claim Node's static CommonJS named-export analysis or native namespace exotic
property descriptors. ESM live binding/TDZ remains subject to the existing lowering
limits. A genuine then export is visible to actual promise resolution, including
its assimilation behavior. Import attributes, JSON dynamic imports, URL queries/
fragments and full async cycles remain explicit errors or unsettled failures.
Plain CommonJS emitter output without a host accessor retains its older lowering;
the module profile does not certify dynamic import in bare eval mode.

The native runner protects a private completion closure across the engine's
microtask checkpoint and checks it before natural exit. Rejections (including
`throw undefined`) fail; an unsettled entry fails with
`ERR_HOME_UNSETTLED_MODULE`. This is not a complete ESM implementation: async
cycles are explicitly refused with `ERR_HOME_ASYNC_MODULE_CYCLE`, the existing
CommonJS lowering does not provide full ESM live-binding/TDZ/namespace semantics,
and event-loop-backed I/O requires a separate implementation.
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

`zig build home-tool-file-io-test-bin` compiles and installs the standalone
filesystem test executable, including its explicit libc dependency. It accepts
the same target/optimization options for checking another platform's linkage;
cross-compilation does not execute the tests. The normal smoke gate still
runs every filesystem test on its actual host.

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


### Asynchronous inherited-stream children

`Bun.spawn(argv, options)` now creates a real POSIX child when all three streams
are explicitly `inherit` or `ignore`. It supports cwd, replacement env (including
PATH lookup), real pid, `exited`, exitCode/signalCode, onExit, and named signals
through `kill`. Children retain owner-loop liveness even without awaiting exited.
The owner-thread pool uses unique tokens rather than recycled PIDs; teardown
kills/reaps remaining owned children, including uncaught callback/evaluation
failures. No JavaScript executes on a worker thread.

Completion is checked with nonblocking waitpid from a protected 5 ms interval
in the existing kernel timer queue. A JS call never waits for normal child
completion; this is not an I/O readiness loop. The common mandatory gate tests
actual inherited input/output, concurrent children, timer progress, cwd/env,
exit/signals, synchronous spawn errors, callback failure and teardown cleanup.
Native tests also cover allocation failures and stale ownership tokens.

Pipe streams (including Bun's default stdout pipe), detached processes,
unref lifetime semantics, numeric signals and other spawn options remain
explicitly unsupported. Unsupported options are refused before process creation.
`Home.spawnSync` remains a distinct blocking operation. This surface does not
implement Bun.build, a test scheduler or general Bun subprocess compatibility.


### Canonical paths

`fs.realpathSync` resolves lexical dots to an absolute path before calling the
native canonicalizer. Its `.native` method and `fs.promises.realpath` pass the
original path to the OS, preserving physical symlink/parent traversal and actual
filesystem errors. Results reflect symlink mutations instead of a path cache.
This bounded surface supports string paths and UTF-8 results; Buffer/URL paths,
Buffer/other encoded results and non-UTF-8 native names are explicitly refused.
The filesystem call blocks the tool thread even through the Promise facade.


### Appending files

`fs.appendFileSync` and `fs.promises.appendFile` use the native writer with
kernel append flags by default. They preserve existing bytes and permissions,
UTF-8 text including NUL, and exact typed-array/DataView/Buffer slices. The sync
form also accepts a descriptor, preserving its current offset and O_APPEND
state without reopening or closing it. Explicit supported flag overrides keep
their actual kernel behavior, including truncation when `w` is requested.

These methods share the writer's bounded encoding, creation-mode and flag
options. Callback appendFile, FileHandle objects, iterable data, flush and other
options remain unsupported. The Promise facade performs blocking native I/O and
rejects actual filesystem errors; it is not a nonblocking I/O scheduler.


### Subprocess stdio tuples

`Bun.spawn` also accepts an explicit three-entry `stdio` array of `inherit` or
`ignore` values. The tuple takes precedence over individual stream options, as
Bun does; it uses the same real descriptor inheritance and native child lifecycle.
Pipe values, short/defaulted tuples and other stream kinds remain explicitly
unsupported. This lets Stacks dispatch its real test subprocess without claiming
that Home supplies Bun's test scheduler.
