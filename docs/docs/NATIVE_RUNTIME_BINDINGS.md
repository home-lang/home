# Native runtime binding ownership

Home's JSC-enabled build still links most C++ bindings and vendor libraries from a configured local Bun build. A successful build is not evidence that every runtime component has been ported into Home.

`BunProcess.cpp` is now compiled from Home's source at `packages/runtime/upstream/src/jsc/bindings/BunProcess.cpp`. The corresponding external object is excluded from linking. This makes changes such as the corrected `process.config.variables.v8_enable_i18n_support` field effective in the main runtime, workers, and the native test runner.

## Build and dependencies

Run `zig build debug -Denable_jsc=true`. The existing `HOME_BUN_OBJ_ROOT` and `HOME_BUN_WEBKIT_LIB` overrides still select the external native artifacts.

For the Home-owned bindings, the build requires `compile_commands.json` next to the external `obj` directory and entries for `BunProcess.cpp`, `napi.cpp`, the registry's unified translation unit, `UnifiedSource-src_jsc_bindings_webcore-3.cpp` (MessagePort), and `UnifiedSource-src_jsc_bindings_webcore-4.cpp` (MessagePortPipe). It uses each entry's compiler, ABI flags, generated headers, and dependency include paths. Missing metadata is an error, not a fallback to stale external objects.

The source is copied into the build cache so quoted includes use the ABI-matched external headers. Saved precompiled headers are not reused: they may belong to another compiler version. The original `root-pch.h` is parsed instead. Clang's dependency file tracks all included headers, and Home's build cache tracks the implementation and compiler arguments. Source/header changes therefore rebuild the owned binding; unchanged builds reuse it.

This is incremental binding ownership, not an independent C++ runtime build. Moving the remaining bindings, generated headers, and vendor build inputs into Home remains part of [the full Bun port](https://github.com/home-lang/home/issues/66).

## Builtin module ownership

The native build also compiles Home's `InternalModuleRegistry.cpp`, `webcore/MessagePort.cpp`, and `webcore/MessagePortPipe.cpp`, and regenerates the `node:url` and `node:worker_threads` builtins from Home's source. The corresponding external unified objects are excluded. Their other C++ implementations are rebuilt from their ABI-matched external sources; they are not yet Home-owned.

MessagePort class headers must be byte-identical to the external headers selected by each unified source. Generation rejects drift, missing implementations, or duplicate owned includes before creating output. Class layouts and vtables remain unchanged; the private `HomeMessagePortLifecycle.h` contains only constants for reserved pipe-state bits. Both implementations and the worker builtin are generated together, and all selected headers are cache dependencies.

`build-support/bundle-native-modules.ts` has an explicit ownership manifest. Only the listed module literals are replaced; all other builtin literal bytes remain those of the configured native build. Bun is currently a build-time TypeScript bundling dependency. The resulting private JSC builtin source is embedded in Home, not loaded from Bun or delegated to a Bun process at runtime.

Home's incomplete source mirror can have different numeric module IDs from the external native build. Generation resolves each referenced module by identity, maps it to the linked registry's enum, and validates each native factory against the linked dispatch table. Wrapped C++ functions additionally require an exact generated wrapper body: target, argument count, display name, visibility, and a unique dispatch entry. It also checks the complete Home error-code numbering against the native error enum. Missing mappings, unsupported Zig/bind calls, mismatched wrappers, unvalidated class IDs, and missing or duplicate replacement literals fail the build instead of silently using stale code. All owned modules are preprocessed and ABI-validated before any output is written. This incremental path does not yet support every builtin; expanding that ownership remains part of #66.

Generated files stay in Home's build cache. The generator does not write into either source tree or modify the external build's generated headers. Compiler depfiles track the external sources and headers used by the rebuilt translation unit.

The generator uses explicit ESM input files so Home's CommonJS package setting cannot wrap a builtin as a module. Leftover import/export syntax is a build error. Native builds using `BUN_DYNAMIC_JS_LOAD_PATH` are rejected because loading external JavaScript from disk would bypass the embedded Home implementation. Bun and C++ compiler executables are cache inputs, so replacing either tool invalidates the associated generated output.

## Checks

- `zig build test -Dfilter=native-bindings` tests compile-command selection and argument normalization.
- `bun test build-support/native_module_abi.test.ts` tests module/native ABI mapping and rejection of missing, ambiguous, or unsupported entries.
- `bun test build-support/bundle-native-modules.test.ts` verifies actual generation inside Home's CommonJS package, complete function grammar, unchanged non-owned literals, paired MessagePort/pipe/worker generation, preservation of external companion sources, and rejection of deliberate error/wrapper/class-header ABI drift. These integration checks skip explicitly when native build artifacts are unavailable.
- `HOME_NATIVE_VM=1 zig-out/bin/home-debug run tests/runtime/native-url-contracts.test.mjs` exercises the embedded URL implementation, including option combinations, serialization delimiters, IDNA, and legacy IPv6 behavior. The exact upstream fixtures are tracked in [#458](https://github.com/home-lang/home/issues/458).
- `HOME_NATIVE_VM=1 zig-out/bin/home-debug run tests/runtime/native-intl-capabilities.test.mjs` verifies capability metadata and real Intl/IDNA behavior in main, worker, and test-runner contexts.
- Native corpus skips and commented-out test bodies remain unsupported coverage, never passing feature checks. Related follow-up: [#456](https://github.com/home-lang/home/issues/456).

### URL port checkpoint

The exact upstream `test-url-format-whatwg.js`, `test-url-format.js`, and `test-url-parse-format.js` fixtures pass through Home's native corpus runner. A concurrent audit of the 169 routed Node-core fixtures reports **157 passing files, 12 unsupported files, 0 failures** (231 passing checks, 12 unsupported checks). The unsupported set still includes explicit upstream skips and the fully commented experimental-warning fixture; this is not 100% suite parity.

The six `tests/runtime/native-*.test.mjs` regressions pass, including the new URL test. The URL test was also run against the old binary and failed as expected, proving it detects a stale builtin. Five build-time generator/ABI tests and three Zig binding-helper tests pass; an unchanged native rebuild reuses all owned artifacts.

For the outer corpus audit, leave `HOME_NATIVE_VM` and `HOME_CORPUS_FULL_VM` unset. The CLI currently treats any nonempty value, including `"0"`, as enabling those overrides; the corpus runner sets the required native child environment itself.

## Node-API and FFI ownership

Home now compiles `packages/runtime/upstream/src/jsc/bindings/napi.cpp`. The old weak placeholders for environment lookup, reference counting, pending exceptions, handle scopes, and cleanup are removed. Real Node-API environments use the complete native binding. The reduced plain-JSC adapter cannot represent that ABI and rejects `.node` loading before opening a library or executing its constructors. Its harness also rejects cached/fabricated addon exports. NAPI and `js/bun/ffi` test files are routed to Home's full native test runner; missing addon build prerequisites are not simulated as success.

`cc()` embeds the four public Node-API headers from `packages/runtime/src/runtime/napi/`, supporting both `<node_api.h>` and `<node/node_api.h>`. It does not require a separate Node installation's header cache. Compiler headers are stored under a content-addressed `home-cc-*` temporary cache and published atomically. First-use initialization is locked across workers; concurrent processes can share the same complete header set. Header setup failures produce an error instead of continuing with missing declarations.

FFI libraries using Node-API retain executable code after `close()` through environment cleanup and the heap's final GC pass. Native values may still hold C finalizers or callbacks after the library object is closed; external-value finalizers can run even after environment cleanup. Releasing TinyCC state or a dynamic library too early caused a reproducible use-after-unmap during shutdown. A post-heap cleanup releases these resources when workers or an explicitly destructed main VM finish; ordinary process exit lets the OS reclaim them. Non-Node-API libraries still release resources immediately; repeated `close()` calls are idempotent.

Relevant regressions (run with `HOME_NATIVE_VM=1 zig-out/bin/home-debug run`):

- `tests/runtime/native-napi-ffi.test.mjs`: independent environments, values, object construction, error state, UTF-16 size handling, and GC liveness.
- `tests/runtime/native-napi-addon.test.mjs`: real modern/legacy addon initialization, callbacks, errors, and GC.
- `tests/runtime/native-ffi-header-cache.test.mjs`: concurrent cold-cache compilation and exact embedded header contents.
- `tests/runtime/native-napi-lifetime.test.mjs`: cleanup hooks and external/instance finalizers after `close()`, using both `cc()` and `dlopen()` in main and worker contexts.
- `tests/runtime/native-napi-bootstrap-safety.test.mjs`: reduced-mode unsupported reporting without running constructors or returning fake exports, paired with real native addon execution.

The exact upstream `js/bun/ffi/cc.test.ts` currently reports **8 passing tests, 10 upstream skips, 0 failures** natively. Skips are not passing feature coverage. Full Node-API and dependency-backed addon coverage remains tracked in [#459](https://github.com/home-lang/home/issues/459) and [#66](https://github.com/home-lang/home/issues/66).

## Native print/eval

Native `-p`/`--print` now use JSC's actual evaluation completion value, including statements, TypeScript, imports, top-level await, and promises. Promise completion uses the callbacks registered in the native JSC dispatch table; an arbitrary Zig callback pointer is not valid there. Pending unreferenced work does not keep the process alive. Eval preserves `process._eval`, handles the argument separator, and cleans its exact owned preload on normal completion, errors, and explicit exit.

`tests/runtime/native-print-eval.test.mjs` checks these contracts and checks child stdout for unreferenced timer callbacks, which some upstream stderr-only assertions missed. The native 56-file timer audit currently has **52 assertion files exiting successfully, 2 explicit upstream skips, 2 sandbox listen-EPERM failures, and 0 timeouts**. It is not a 100% pass result. Follow-up: [#460](https://github.com/home-lang/home/issues/460).

At the Node-API/print-eval checkpoint, the native build and unchanged cached rebuild both passed all 11 build steps. All twelve then-existing native runtime regression files passed, including main/worker FFI shutdown with exactly-once environment, instance-data, and external-value finalizers. Main heap destruction now marks termination, matching worker behavior, so finalizers execute immediately instead of being queued on an exiting loop. The unchanged upstream `cli/run/run-eval.test.ts` passed **33 tests / 70 assertions** with existing React 18.3.1 supplied read-only through `NODE_PATH=/Users/chris/Code/bun/node_modules`; no dependency installation or fixture edits were needed. Five generator/ABI tests and three Zig binding-helper tests also passed.

## Worker message ownership and exit guards

Home now generates the worker builtin together with its owned native MessagePort implementation. `receiveMessageOnPort()` distinguishes an empty queue from every payload, including `undefined`, `null`, `false`, `0`, `-0`, `NaN`, empty strings, and BigInts. Native deserialization returns an ordinary object with an own `message` data property; it does not invoke an inherited setter. Deserialization failures propagate instead of storing an empty internal JS value. The worker builtin consumes that envelope directly. This private contract must be rebuilt on both sides together.

`tests/runtime/native-worker-message-presence.test.mjs` covers main and worker contexts, FIFO order, empty queues, descriptors, cyclic/shared clones, transferred buffers and ports, and interleaved synchronous/asynchronous consumption. Close-event lifecycle coverage is now in `tests/runtime/native-worker-close-events.test.mjs`, tracked in [#462](https://github.com/home-lang/home/issues/462). The original pending regression passed and was replaced by that broader suite.

The worker builtin now includes the current upstream transfer packing, rollback, and orphan-file-descriptor cleanup. Its `fs`/FileHandle, events, streams, and shared internal dependencies still use the configured external builtin literals. Owning `worker_threads.ts` does not mean those dependencies or all worker features have been ported. Full worker ownership and message coverage are tracked in [#461](https://github.com/home-lang/home/issues/461).

Exit dispatch uses a one-shot flag in each Home VM, replacing the process-wide C++ static that let the first worker suppress later workers' and the main process's `exit` listeners. The guard is set before user callbacks and is independent of writable `process._exiting`. Worker shutdown marks the VM as shutting down after user exit listeners, before Node-API cleanup, so thrown exit assertions still report errors and failure status. Fatal worker callbacks report through the existing parent-error/termination path instead of entering a main-thread-only exit/panic shortcut. A termination request also stops the worker's `beforeExit` drain even if the failing callback scheduled referenced work. Ordinary `beforeExit` rescheduling is preserved. `tests/runtime/native-process-exit-dispatch.test.mjs` checks natural and explicit exits, sequential workers, reentrancy, exit-code changes, rescheduled work, a real failing Node `common.mustCall` check after a worker exits, and throwing worker exit/beforeExit/nested-exception guards. Follow-up: [#463](https://github.com/home-lang/home/issues/463).

Standalone worker fixture exit-zero results from before this exit-dispatch fix are provisional: their final assertion guards and cleanup could have been suppressed. They must be rerun with the per-VM guard active before being counted as logical passes. Native test-runner assertions are reported separately.

### Worker/exit verification checkpoint

At the worker/exit checkpoint, the native build and unchanged cached rebuild both passed **12/12 steps**. All **14 then-existing native regression files** passed, including the eight subprocess scenarios in the exit-dispatch regression. Six generator/ABI tests (43 assertions) and three Zig binding-helper tests passed.

That bounded upstream worker rerun reported **30 passing native tests, 3 upstream skips, 0 failures** (552 assertions across five files), plus **11 passing standalone fixtures** with exit guards active. A deliberately missed `common.mustCall` failed with status 1 and its positive control succeeded. The FileHandle fixture's temporary file was genuinely removed by its exit hook. Skips are not passing feature coverage; close events were still a known failure at that checkpoint.

Adjacent unchanged fixtures still pass: print/eval **33 tests / 70 assertions**, and the four-file FFI shard **14 passing tests, 11 upstream/platform skips, 0 failures / 23 assertions**. The full port is not complete. Test runs use bounded subprocess concurrency and per-run temporary directories; superseded owned build outputs are removed only after replacement binaries are verified.

## Native MessagePort close lifecycle

Close is now a native pipe control notification. Local closure discards only the local inbox; the peer receives accepted messages in FIFO order before its close event. Unstarted endpoints register for notifications without consuming data. A close notification that encounters unread data stalls until message delivery starts or a synchronous read reaches the empty queue. An immediate synchronous pop before the initial notification arrives preserves that already-queued wakeup.

Transfers close the old wrapper asynchronously, not the transferred endpoint. Drains validate both context and wrapper identity, including same-context transfer inside a handler. Pending close events keep wrappers alive through GC; dispatch releases listeners and context ownership. Shutdown never executes close listeners in a stopped VM. Iterative disposal closes unread transferred endpoints without recursive teardown. Strong port snapshots are released outside pipe locks to avoid destructor reentrancy deadlocks.

Teardown GC can destroy ports before their stopped context leaves the global registry. Scheduling new local drains then would strand pipe references in an event loop that cannot run. Scheduling first enters the owning context, checks its VM state outside the registry lock, and only then queues asynchronous delivery. This avoids reading another thread's VM state or releasing native captures under the registry lock. Live remote peers still receive notifications. General cancellation of already-queued remote C++ tasks is separate work in [#465](https://github.com/home-lang/home/issues/465).

The worker builtin only adapts Node's optional `close(callback)` and zero-argument `.on('close')` convention; native code owns local, peer, transfer, and teardown delivery. Repeated close is idempotent, duplicate callback identity is preserved, and late callbacks do not replay an event.

One timing difference remains explicit: Node can synchronously receive already-queued local data after `close()` returns but before its close event; Home currently discards that inbox immediately. The shared close regression checks disposal after notification. Pending-local-close receive parity is tracked separately in [#466](https://github.com/home-lang/home/issues/466), not counted as resolved by close-event delivery.

### Close-lifecycle verification checkpoint

The native build and unchanged rebuild pass **13/13 steps**. All **15 native regression files** pass. The close suite has **13 bounded cases**, also passing under Node 24.18.0 with only its executable guard removed. It checks pending-listener survival separately from collection: WeakRefs to 36 ordinary and 72 orphan/transfer wrappers clear, a strongly retained positive control survives, and the child exits naturally. This does not prove freedom from every native allocation leak.

The pipe suite reports **10 passing tests, 3 upstream skips, 0 failures / 516 assertions**. This includes one explicit Home fixture correction: `js/web/workers/message-port-pipe.test.ts` retains its `FinalizationRegistry` through the report and then releases it. The pristine fixture reported zero callbacks because the registry itself became unreachable before deferred close made its targets collectable. Retaining only the registry produced all 200 finalizations; no target was retained and no assertion was weakened. The external Bun source tree remains unchanged. FileHandle and transfer/terminate standalone fixtures also pass, with real exit cleanup.

The unchanged closed-port leak suite passes **4 tests / 10 assertions**, including 20,000 nested transferred endpoints. The unchanged worker context-destruction leak test passes **1 test / 3 assertions** on three isolated runs. Before the scheduling gate it failed consistently at +34.14, +34.58, and +34.16 MB RSS; the original 30 MB limit is unchanged. These three corpus files together report **15 passing tests, 3 upstream skips, 0 failures / 529 assertions**.

Eight generator/ABI tests (69 assertions) and four Zig binding-helper tests pass. Five additional consecutive generator runs passed after one host Bun startup SIGTRAP; the macOS crash report identifies `pthread_jit_write_protect_np`, not a generator assertion. That host/tooling incident is not counted as a passing run or hidden by retries. Full worker ownership, skipped coverage, and the complete Bun port remain open in #461 and #66.
