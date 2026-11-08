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
`normalize`, `isAbsolute`, `join`, `resolve`, `dirname`, `sep` and `delimiter`.
`url`/`node:url` provide `fileURLToPath` for local POSIX file URL strings, with
URL escaping, dot segments, scalar-value conversion and query/fragment handling.
The Node-produced path/URL fixture retains both successful results and errors.
Other path methods, Windows path behavior, URL objects and other URL APIs still
require implementations.

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

Package-private `#name` imports support exact, unconditional `./file` targets
from the nearest `package.json`. Missing or null mappings remain errors, and
lookup stops at package and `node_modules` boundaries. Targets do not use
extension or directory fallbacks. Conditional, wildcard, external-package and
URL-encoded targets still require additional resolver support; they are refused.

The host supplies the CommonJS emitter's default and namespace import helpers. ES-module exports keep their module identity, while CommonJS objects and primitive exports receive the appropriate default binding. This allows executable entry points to use ordinary TypeScript import interoperability without relying on ambient helpers from Node or Bun.

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
