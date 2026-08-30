# Native runtime binding ownership

Home's JSC-enabled build still links most C++ bindings and vendor libraries from a configured local Bun build. A successful build is not evidence that every runtime component has been ported into Home.

`BunProcess.cpp` is now compiled from Home's source at `packages/runtime/upstream/src/jsc/bindings/BunProcess.cpp`. The corresponding external object is excluded from linking. This makes changes such as the corrected `process.config.variables.v8_enable_i18n_support` field effective in the main runtime, workers, and the native test runner.

## Build and dependencies

Run `zig build debug -Denable_jsc=true`. The existing `HOME_BUN_OBJ_ROOT` and `HOME_BUN_WEBKIT_LIB` overrides still select the external native artifacts.

For the Home-owned bindings, the build requires `compile_commands.json` next to the external `obj` directory and entries for `BunProcess.cpp`, `napi.cpp`, the registry's unified translation unit, `UnifiedSource-src_jsc_bindings_webcore-3.cpp` (MessagePort and JSWorker), `UnifiedSource-src_jsc_bindings_webcore-4.cpp` (MessagePortPipe), `UnifiedSource-src_jsc_bindings_webcore-5.cpp` (Worker), `UnifiedSource-src_jsc_bindings-0.cpp` (BunWorkerGlobalScope), and `UnifiedSource-src_jsc_bindings_webcore-2.cpp` (JSMessagePort). It uses each entry's compiler, ABI flags, generated headers, and dependency include paths. Missing metadata is an error, not a fallback to stale external objects.

The source is copied into the build cache so quoted includes use the ABI-matched external headers. Saved precompiled headers are not reused: they may belong to another compiler version. The original `root-pch.h` is parsed instead. Clang's dependency file tracks all included headers, and Home's build cache tracks the implementation and compiler arguments. Source/header changes therefore rebuild the owned binding; unchanged builds reuse it.

This is incremental binding ownership, not an independent C++ runtime build. Moving the remaining bindings, generated headers, and vendor build inputs into Home remains part of [the full Bun port](https://github.com/home-lang/home/issues/66).

## Builtin module ownership

The native build also compiles Home's `InternalModuleRegistry.cpp`, `BunWorkerGlobalScope.cpp`, `webcore/JSMessagePort.cpp`, `webcore/JSWorker.cpp`, `webcore/MessagePort.cpp`, `webcore/MessagePortPipe.cpp`, and `webcore/Worker.cpp`, and regenerates the `node:url` and `node:worker_threads` builtins from Home's source. The corresponding external unified objects are excluded. Their other C++ implementations are rebuilt from their ABI-matched external sources; they are not yet Home-owned.

MessagePort and Worker class headers must be byte-identical to the external headers selected by each unified source. Generation rejects drift, missing implementations, or duplicate owned includes before creating output. Class layouts and vtables remain unchanged; the private `HomeMessagePortLifecycle.h` and `HomeWorkerSnapshots.h` supply state-bit constants and internal transport/lifecycle declarations without changing external class layouts. The owned implementations and worker builtin are generated together, and all selected headers are cache dependencies.

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

Close is now a native pipe control notification. Local closure retains the local inbox for synchronous receive until close completion; the peer receives accepted messages in FIFO order before its close event. Unstarted endpoints register for notifications without consuming data. A peer-close notification that encounters unread data stalls until message delivery starts or a synchronous read reaches the empty queue. An immediate synchronous pop before the initial notification arrives preserves that already-queued wakeup.

Transfers close the old wrapper asynchronously, not the transferred endpoint. Drains validate both context and wrapper identity, including same-context transfer inside a handler. Pending close events keep wrappers alive through GC; dispatch releases listeners and context ownership. Shutdown never executes close listeners in a stopped VM. Iterative disposal closes unread transferred endpoints without recursive teardown. Strong port snapshots are released outside pipe locks to avoid destructor reentrancy deadlocks.

Teardown GC can destroy ports before their stopped context leaves the global registry. Scheduling new local drains then would strand pipe references in an event loop that cannot run. Scheduling first enters the owning context, checks its VM state outside the registry lock, and only then queues asynchronous delivery. This avoids reading another thread's VM state or releasing native captures under the registry lock. Live remote peers still receive notifications. General cancellation of already-queued remote C++ tasks is separate work in [#465](https://github.com/home-lang/home/issues/465).

The worker builtin adapts Node's optional `close(callback)`; native code owns local, peer, transfer, and teardown delivery. Repeated close is idempotent, duplicate callback identity is preserved, and late callbacks do not replay an event. Both callbacks and `.on('close')` listeners receive the close event object. The earlier zero-argument `.on('close')` implementation was incorrect; native Node controls exposed it during the parent-port checkpoint below.

The pending-local-close window is tracked in [#466](https://github.com/home-lang/home/issues/466). Outgoing delivery, asynchronous local message dispatch, and transferring the closing endpoint stop immediately, but synchronous receive still consumes accepted data, including new peer sends before completion. The native detached flag remains set for serialization validation; the existing post-detachment state distinguishes local close from a transferred-away wrapper, which cannot read or close its replacement. Class layouts remain unchanged. Close completion discards remaining local data iteratively before callbacks. Orphaned endpoints and context destruction discard immediately, without a pending receive window.

Posting through an inactive sender still validates and serializes its transfer list. Transferred buffers detach, and transferred ports become orphaned and close; a former peer or replacement endpoint can be consumed this way without being delivered. This is separate from transferring the inactive sender itself, which remains invalid. `tests/runtime/native-worker-pending-close.test.mjs` checks these contracts against Node controls; the earlier presence regression now positively checks the pending queued payload instead of asserting Home's former immediate-empty behavior.

### Initial close-lifecycle verification checkpoint

At the initial close-lifecycle checkpoint, the native build and unchanged rebuild passed **13/13 steps**. All **15 then-existing native regression files** passed. The close suite had **13 bounded cases**, also passing under Node 24.18.0 with only its executable guard removed. It checked pending-listener survival separately from collection: WeakRefs to 36 ordinary and 72 orphan/transfer wrappers cleared, a strongly retained positive control survived, and the child exited naturally. This did not prove freedom from every native allocation leak.

The pipe suite reports **10 passing tests, 3 upstream skips, 0 failures / 516 assertions**. This includes one explicit Home fixture correction: `js/web/workers/message-port-pipe.test.ts` retains its `FinalizationRegistry` through the report and then releases it. The pristine fixture reported zero callbacks because the registry itself became unreachable before deferred close made its targets collectable. Retaining only the registry produced all 200 finalizations; no target was retained and no assertion was weakened. The external Bun source tree remains unchanged. FileHandle and transfer/terminate standalone fixtures also pass, with real exit cleanup.

At that checkpoint, the unchanged closed-port leak suite passed **4 tests / 10 assertions**, including 20,000 nested transferred endpoints. The unchanged worker context-destruction leak test passed **1 test / 3 assertions** on three isolated runs. Before the scheduling gate it failed consistently at +34.14, +34.58, and +34.16 MB RSS; the original 30 MB limit was unchanged. These three corpus files together reported **15 passing tests, 3 upstream skips, 0 failures / 529 assertions**. The later pending-close checkpoint records why the completed-closure memory fixture subsequently needed an explicit asynchronous wait.

Eight generator/ABI tests (69 assertions) and four Zig binding-helper tests pass. Five additional consecutive generator runs passed after one host Bun startup SIGTRAP; the macOS crash report identifies `pthread_jit_write_protect_np`, not a generator assertion. That host/tooling incident is not counted as a passing run or hidden by retries. Full worker ownership, skipped coverage, and the complete Bun port remain open in #461 and #66.

### Historical queued-transfer ownership regression

Before the incoming-inbox fix, `tests/runtime/worker-queued-transfer-close.pending.mjs` intentionally failed on [#465](https://github.com/home-lang/home/issues/465). One worker blocked a timer callback for a finite interval. The parent queued one transferred port and terminated the worker before delivery. The surviving peer never closed, while the normal-delivery positive control did. That bounded test demonstrated retained incoming-message ownership without large allocations or an RSS threshold. It now passes and is superseded by the broader seven-case native inbox suite below; it is no longer a pending failure. This does not establish cancellation or reclamation of the native task itself. General task admission, cancellation, and thread-affine cleanup remain open; deleting arbitrary queued callbacks is insufficient.

At that checkpoint, the linked Worker implementation was external (`UnifiedSource-src_jsc_bindings_webcore-5.cpp`). Its `dispatchExit` already released the create-time C++ reference through the pre-enqueue hook; the corresponding Home mirrored source was stale. That mirror discrepancy was not the runtime cause of #465. The following inbox checkpoint takes ownership of that implementation while preserving the hook.

### Pending-close verification checkpoint

At the pending-close checkpoint, the build and unchanged rebuild passed **13/13 steps**. All **16 then-existing native regression files** passed. The new pending-close suite passed **15 cases** on three fresh Home runs and three Node 24.18.0 control runs. The prior 13-case close suite, main/worker message-presence coverage, Node-API/FFI lifetime checks, eval, and exit-dispatch regressions remained passing. The FileHandle and transfer/terminate standalone fixtures passed with natural exits and actual file cleanup. Eight generator/ABI tests (69 assertions) and four Zig binding-helper tests passed.

The focused pipe, closed-port, and context-destruction corpus shard reports **15 passing tests, 3 upstream skips, 0 failures / 529 assertions**, with explicit fixture adaptations recorded. In addition to the earlier FinalizationRegistry correction, `message-port-closed-leak.test.ts` now waits for bounded close-event completion before measuring completed-closure memory. Its original synchronous measurement observed legitimate pending inboxes (+333.06, +132.28, and +132.30 MB), not proof of a post-close leak. The corrected test preserves every payload size, iteration count, memory threshold, and outer assertion. A small unstarted-peer sentinel keeps the sender live while the destination closes, preserving the closed-destination send path. The 20,000-endpoint test waits for the final orphan peer to close before reporting success, proving the cascade completed. The external Bun source tree is unchanged.

Node controls avoid reading inside a close callback or its immediate continuation, which reproducibly crashes Node 24.18.0; terminal reads happen after callbacks unwind. No crash is treated as desired behavior. At that checkpoint, the independent #465 queued-transfer regression still failed with its positive control passing. Neither those focused results nor upstream skips established full Bun parity.

## Worker incoming-inbox shutdown

Home now owns `webcore/Worker.cpp` for the bounded incoming-message fix in [#469](https://github.com/home-lang/home/issues/469). Its baseline was synchronized with the implementation actually linked from Bun commit `4982b91e3702094330f3be3883354c52b8c01323`, rather than the older Home mirror. This preserves the three-argument `postTaskTo` pre-enqueue reference-release hook, the module-loader lock during teardown, and the existing native error-dispatch ABI. `Worker.h` is byte-identical to the selected external header; there is no class-layout change.

When the worker has stopped, `dispatchExit` publishes `Closing`, extracts its incoming inbox, and resets its scheduled-drain flag under the relevant locks. Destruction happens after those locks are released because transferred endpoints can close other pipes and post tasks. Incoming messages racing shutdown either join the extracted batch or are rejected before buffering under the same inbox lock. Startup only transitions from `Pending` to `Running`, so it cannot reopen a closing worker. `terminate()` remains a termination request; parent-bound accepted messages and their delivery order are unchanged.

This releases queued transferred resources even when JavaScript retains the terminated Worker and no GC runs. It does **not** cancel generic C++ tasks, reclaim every queued native allocation, or settle separately owned heap-snapshot requests. The existing create-time reference-release hook was already present in the linked external Worker and was not the cause of the retained inbox.

### Incoming-inbox verification checkpoint

The native build and unchanged cached rebuild passed **14/14 steps**. All **16 previously existing native regression files** passed, and `tests/runtime/native-worker-inbox-shutdown.test.mjs` passed its **seven bounded cases on both Home and Node 24.18.0**. These cover normal delivery, retained-Worker cleanup without GC, repeated cancelled and late transfers, and normal/cancelled worker-local transfer callbacks. Cancelled handlers must not execute. Peer closure demonstrates message-resource cleanup, not reclamation of every underlying task allocation.

The original eight-case control suite passed under Node 24.18.0. Home's failing nested-worker case was separated into `tests/runtime/worker-nested-termination.pending.mjs`: that standalone case passes on Node but fails on Home because one cancelled child handler still executes. It remains an explicit failure in [#470](https://github.com/home-lang/home/issues/470), not a skip or an eighth Home pass.

The pipe, completed-closure leak, and isolated context-destruction corpus tests passed **15 tests, with 3 upstream skips and 0 failures / 529 assertions**. The previously documented Home fixture adaptations remain explicit; thresholds and workloads were not relaxed. Both standalone FileHandle and transfer/terminate fixtures passed with natural exit guards and actual cleanup. Build-time verification passed **8 generator/ABI tests / 84 assertions**, **4 Worker source-contract tests / 25 assertions**, and **4 Zig binding-helper tests**. Source-contract checks are separate from native execution evidence.

### Remaining shutdown work

[#465](https://github.com/home-lang/home/issues/465) remains open for safe admission and cancellation of generic C++ tasks, cleanup-tag behavior, thread-affine captures, and callback-only cleanup such as parent-poll release. [#468](https://github.com/home-lang/home/issues/468) tracks work-pool producer quiescence: an in-flight native job is not the same thing as an event-loop queue entry. [#470](https://github.com/home-lang/home/issues/470) tracks nested-worker termination and ownership.

At that checkpoint, `tests/runtime/worker-heap-snapshot-cancellation.pending.mjs` was a bounded Home failure in [#471](https://github.com/home-lang/home/issues/471): the snapshot promise remains unsettled after worker termination, producing a deadline failure and exit status 1. The probe accepts either a resolved readable stream or `ERR_WORKER_NOT_RUNNING`, since snapshot work may finish before cancellation. It checks settlement and the stream interface, not snapshot contents. Node 24.18.0 can resolve the promise, but both consuming the stream and immediately destroying it without consumption produced SIGSEGV during this race, including after printing the settlement message. Therefore no passing Node snapshot control is claimed; a printed success message before a crash is not a successful run. Reproducing that crash is not a compatibility requirement.

The passing inbox checkpoint does not close these issues or establish full Bun suite parity. Missing functionality, pending failures, and upstream skips remain outside passing feature coverage under [#66](https://github.com/home-lang/home/issues/66).

## Nested worker shutdown

Home now propagates termination through the native worker ancestry and waits for each direct child's final resource-cleanup publication before destroying its parent's VM ([#470](https://github.com/home-lang/home/issues/470)). Registration and ancestry traversal share the live-worker registry lock, so a child created during termination inherits the request. Completion is published after exit-task enqueueing and thread-local cleanup; observing zero cannot race the final wake against destruction of the parent's embedded counter.

Nested exit tasks are explicitly marked and published while their parent VM is protected by that child counter. During shutdown, the parent performs only those native cleanup callbacks, releasing the child poll reference and captured Worker reference on the owning thread without dispatching JavaScript into the stopped parent. Normal parent execution still receives child exit events. Unrelated queued tasks are not executed or treated as safely cancelled by this path. General cancellation and native producer quiescence remain [#465](https://github.com/home-lang/home/issues/465) and [#468](https://github.com/home-lang/home/issues/468).

The main-thread wait now returns whether all workers completed. If its deadline expires, process exit must not free shared resolver/VM state underneath outstanding workers. Nested parents retain their VM while waiting; this is a resource-lifetime barrier, not an OS thread join or proof that every native operation can be interrupted.

### Nested shutdown verification checkpoint

- Native build and unchanged rebuild: **14/14 steps**.
- All **17 existing native runtime regression files** pass on the rebuilt Home executable.
- `tests/runtime/native-worker-nested-shutdown.test.mjs` adds **five passing cases**: parent termination with queued transfers; normal, explicit, and unreferenced parent exit; and a three-level descendant branch with a sibling. Three consecutive native runs, an additional run with `BUN_DESTRUCT_VM_ON_EXIT=1`, and two Node controls pass. The old Home binary fails the original cancelled-child callback assertion.
- Exact native corpus execution with **both** `HOME_NATIVE_VM=1` and `HOME_CORPUS_FULL_VM=1`: pipe, completed-close leak, and context-destruction suites report **15 pass, 3 skip, 0 fail / 529 assertions**. The three skips are upstream debug/sanitizer guards, not passing coverage. The existing documented fixture adaptations are unchanged.
- Three standalone upstream worker fixtures pass through native Home: nested termination, message-port transfer/termination, and termination during transfer-list iteration. The outer corpus adapter was checked separately and its results are not substituted for the full VM.
- Generator/ABI/source guards: **12 tests / 109 assertions**; native build helpers: **4 Zig tests**. Focused Pickier lint and Zig format checks pass. The full Bun suite and other platform builds were not run for this checkpoint.

The normal-exit control initially exposed another real gap: `fakeParentPort.close()` is a no-op. The descendant test now uses a one-shot message listener to test normal child exit independently of closing that port. `tests/runtime/worker-parent-port-close.pending.mjs` preserves the separate failure: Home times out waiting for natural exit, while the exact Node control closes once and exits successfully. This remains open in [#477](https://github.com/home-lang/home/issues/477); it is not counted among the 18 passing native regression files. The snapshot cancellation probe also still fails with an unsettled promise in [#471](https://github.com/home-lang/home/issues/471).

### Publication

The 65 prior local port commits through `6de9852ea8443c3b5d4a58dcdbcf11944456fd2e` were recovered from the existing separate Git metadata and published on `codex/runtime-port` on 2026-08-27. Their original hashes and sole Chris Breuer author/committer identities were preserved, with no coauthor trailers or force push. Publication on this branch is not a merge into `main` or a claim of complete Bun ownership.

## Native worker parent port

The `fakeParentPort` JavaScript stand-in is removed. Before evaluating a worker's entry point, Home creates a real native `MessagePort` endpoint. Its virtual peer belongs to the native Worker transport. Startup inbox migration and subsequent parent sends share a registry/inbox lock order, preserving FIFO order even before the worker is online. Synchronous receive reads the same pipe queue as asynchronous delivery, including falsy and `undefined` payloads. Transferring the endpoint uses the existing native transfer machinery and retains its original Worker peer.

Outgoing port messages enter the existing parent-bound native inbox after normal structured-clone and transfer validation. The registry lifetime is bounded by the worker's create-time reference; shutdown unregisters and closes the virtual peer on the worker thread before its VM is destroyed. Resource destruction happens outside the registry lock. Close remains asynchronous and does not terminate other worker resources. The Web Worker global event surface still starts native delivery and receives the same deserialized value and transferred endpoints, without cloning transfers twice.

`BunWorkerGlobalScope.cpp` and `JSMessagePort.cpp` are now compiled from Home sources with byte-identical external class headers. Message-listener references use the same native ref state as explicit `ref()`/`unref()`, so unref can release a listening parent port. Clearing `onmessage` releases its reference, while an `onmessageerror` handler does not acquire one. These changes also correct the corresponding transferred-MessagePort behavior. The EventEmitter adapter now forwards the close event to `.on('close')` listeners, as verified against Node 24.18.0.

Verification for [#477](https://github.com/home-lang/home/issues/477):

- Build and unchanged cached rebuild: **16/16 steps**. All **19 native runtime regression files** pass.
- `tests/runtime/native-worker-parent-port.test.mjs`: **11 Home scenarios**, including synchronous/pending-close receive, reference transitions, repeated asynchronous close, continued timer work after close, self-transfer rejection, transfer to a descendant, and the Web Worker global surface. **10 shared scenarios pass two Node control runs**; the Web Worker extension is Home-only. Two further native runs with main-VM destruction pass.
- The descendant test once again uses a persistent parent-port listener and real `parentPort.close()` for normal exit. It no longer needs the temporary one-shot isolation used before this fix.
- **15 byte-identical upstream Node worker fixtures pass**, covering parent-port references, onmessage clearing, transfer/termination, SharedArrayBuffer, and WebAssembly module/thread transfer.
- Unmodified guard behavior in the three native worker suites reports **15 pass, 3 debug/sanitizer skips, 0 fail / 529 assertions**. Separately, a temporary derivative enabled all three guarded stress bodies without altering their assertions: **13 pass, 0 fail / 525 assertions**, including concurrent channel creation and cross-thread message/microtask ordering. This is additional native stress evidence, not an ASAN or UBSan run. The temporary file was removed.
- **12 generator/ABI/source-contract tests / 123 assertions** and **4 Zig build-helper tests** pass. Newly owned class headers participate in pre-generation ABI checks and cache inputs. Focused test/build-helper Pickier checks and Zig formatting pass; the builtin source retains its existing quote-style warning.

The historical parent-port pending regression is now the active native suite above. At the parent-port checkpoint, general queued-task cancellation (#465), producer quiescence (#468), and snapshot request settlement (#471) remained separate work; the snapshot implementation is described below. This checkpoint does not establish full Bun ownership, whole-suite completion, or other-platform verification.

## Snapshot request ownership and cancellation (#471)

The snapshot round trip now uses a locked native registry. Each request owns its parent VM's `Strong<JSPromise>` and optional completed JSON payload. Creation, settlement, cancellation, and handle destruction run only on the parent thread. Worker tasks and return notifications carry monotonically unique integer IDs; they do not capture a Strong handle, Worker reference, or JSON payload. Cancelling a request makes a late notification inert and releases any already-produced payload independently of whether the generic task object is reclaimed.

Worker exit cancels outstanding requests before publishing the parent-visible exit event. A live parent receives `ERR_WORKER_NOT_RUNNING`; successful requests still generate real V8-format JSON and return a readable stream. Main and worker `VirtualMachine.onExit()` clear all requests owned by that VM after user exit listeners and before native cleanup hooks or JSC destruction, without executing promise reactions in a stopped context. Worker completion racing parent shutdown can only publish into an existing request under the registry lock.

`JSWorker.cpp` is now compiled from Home inside the same owned unified translation unit as `MessagePort.cpp`. Generation replaces both sources together, rejects missing/duplicate includes for either, and validates the unchanged `JSWorker.h` ABI. The generated source uses the configured JSC promise rejection signature rather than the stale mirrored overload.

The historical failing snapshot probe above is promoted to `tests/runtime/native-worker-heap-snapshot.test.mjs`. The suite checks six concurrent cancellation settlements, four outstanding requests during worker self-exit, rejects after exit, validates nine concurrent snapshots and a live heap sentinel under parent GC, stops nested parents with blocked/running snapshot children, and destroys the main VM with outstanding requests. The running-child case allows time for return delivery but does not claim deterministic control of native task scheduling. Node's previously observed snapshot/termination crash is not a required or passing control; normal snapshot validation is tested separately.

This addresses snapshot request and payload ownership, not arbitrary native task object reclamation (#465), native producer quiescence (#468), all heap-snapshot options, or complete Bun-suite parity. Native ownership assertions and repeated subprocess tests are not a sanitizer run.

Verification for this snapshot checkpoint:

- Native build and unchanged cached rebuild: **16/16**. After shared cache files disappeared during concurrent builds, verification used isolated caches: `ZIG_GLOBAL_CACHE_DIR="$PWD/zig-out/snapshot-global-cache" zig build debug -Denable_jsc=true -j1 --cache-dir zig-out/snapshot-cache --summary all`. The missing-cache attempts were failures, not passes.
- **All 20 native regression files pass.** The six-scenario snapshot suite passes four complete runs, including two with `BUN_DESTRUCT_VM_ON_EXIT=1`. Its cancellation case fails on the prior installed binary with the original unsettled-promise deadline.
- **16 byte-identical upstream Node worker fixtures pass**, now including `test-worker-heap-snapshot.js`. That snapshot fixture also passes in Node, as does the nine-snapshot concurrent-GC scenario with only its Home executable guard removed and the normal-success block selected. No Node termination-race pass is claimed.
- The byte-identical upstream `worker_heap_snapshot_gc.test.ts` and its fixture pass the full native workload: **15 attempts × 300 completed snapshots = 4,500 snapshots**, **1 test / 15 assertions**, without shrinking the workload. The harness launches `process.execPath`, which is the native Home executable in this run.
- The three strict native MessagePort suites remain **15 pass / 3 existing debug-sanitizer guard skips / 0 fail / 529 assertions**. Both `HOME_NATIVE_VM=1` and `HOME_CORPUS_FULL_VM=1` were set for corpus runs. Skips are not passes.
- The unmodified full `worker_threads.test.ts` reports **33 pass / 1 timeout / 1 between-test error**; all three snapshot cases pass, but the file is **not green**. At this snapshot checkpoint, Home's native CLI ignored `-t getHeapSnapshot`: its manual context setup discarded that flag instead of setting the existing test-filter options ([#481](https://github.com/home-lang/home/issues/481)). Bun's control correctly reports 3 pass / 31 filtered out.
- The full-file timeout is the unchanged 100 MiB eval-source leak fixture's five-second deadline. The exact standalone fixture passes its existing memory-growth threshold in native debug in 20.22 s, versus 2.20 s in Bun. This is not evidence of a retained-source leak; optimized-build timing and the original deadline remain unresolved in [#482](https://github.com/home-lang/home/issues/482). No workload, threshold, or deadline was changed.
- Generator/ABI/source-contract checks: **12 pass / 135 assertions**; Zig binding-helper tests: **4/4**. Focused Pickier and Zig formatting checks pass.

Snapshot requests explicitly wait for `online` in the regression. A five-run startup-order control shows both Home and Bun can emit a user message before `online` while top-level code is still running; Node emits `online` first. A message handshake alone is therefore insufficient to prove a snapshot request was admitted. The blocked-work tests schedule their work after startup so they exercise cancellation of real queued requests rather than immediate pre-start rejection.

## Native test CLI option integration (#481)

`runTestsViaVM` now initializes `Command.Context` through the existing native `Arguments.parse` implementation. The manual flag-skipping loop and line-based bunfig preload extractor are removed. A normalized parser argv is kept separate from `bun.argv`, so native code still observes the original executable and invocation. Test/runtime/transpiler options and real bunfig parsing share the native parser instead of maintaining a second partial grammar.

This restores lazy command parameter/help declarations, missing CLI environment descriptors, and configuration slots. `--title` writes the value used by `process.title`. Fatal CLI diagnostics now flush and exit with status 1 through `Global.crash()`, matching Bun instead of panicking. Output now distinguishes direct writers from per-thread buffered writers, restores buffering scopes, and preserves an existing terminal newline. Coverage tables and CLI summaries consequently retain Bun's ordering. `GITHUB_ACTIONS=false`/`0` no longer enables CI groups. Crash-reporting and AI-agent detection are not completed by these configuration/output fixes.

The existing `tests/runtime/native-node-core-cli.test.mjs` checks filter aliases, inline/separate/duplicate values, nested-name regexes, file ordering, `--`, empty/no-match patterns, invalid arguments, retry/rerun/bail, timeout, only, empty directories, config selection and validation, preload aliases, defines, title, JUnit/dots, deterministic seeds, file sharding, and actual concurrent execution limits. Fixtures record `process.execPath` and test-body execution. The poison body must never execute when excluded; invalid input must stop before loading user code. Unknown runtime flags retain Bun's permissive behavior. Optional `--config` uses its explicit `--config=path` form, as confirmed by Bun controls.

The expanded regression fails on the previous native binary because the excluded poison test executes. Its shared CLI block passes under Bun 1.3.14; the native checks also retain their Home-executable guard. These controls do not substitute Bun execution for Home results.

Final native build and unchanged cached rebuild pass **16/16 steps**, using the isolated cache command documented above. **All 20 native regression files pass**, including the expanded CLI suite after the buffering and invalid-seed diagnostic fixes. Focused Pickier, diff whitespace, and Zig format checks pass for the changed CLI/output files. The two shared `home.zig` and full crash-handler files retain pre-existing enum-builtin formatter migrations; those unrelated rewrites were not included.

Verification includes the unchanged upstream suites for bunfig options (**5 tests / 17 assertions / 1 snapshot**), path-ignore patterns (**10 / 38**), retry/repeat hooks (**12 / 7**), immediate concurrency (**2 / 8 / 2 snapshots**), and full coverage (**12 / 27 / 10 snapshots**). The ordinary concurrency file passes **6 tests / 15 assertions / 3 snapshots** when run from the original Bun checkout, preserving its literal `test/js/...` snapshot paths. The snapshot filter now runs exactly **3 tests / 7 assertions**, with **31 filtered out** and no failures. Together these seven native commands execute **50 passing tests / 119 assertions**; the filtered cases are not passes. Tests and snapshots are unchanged from the selected Bun source. The matching Bun controls for configuration, coverage, path ignores, and ordinary concurrency pass too.

The wider option audit exposed separate native feature gaps: fresh-global/module-record isolation in [#484](https://github.com/home-lang/home/issues/484), and parallel coordinator/worker IPC in [#485](https://github.com/home-lang/home/issues/485). The unchanged isolation selection reports **1 pass / 3 fail / 15 filtered out**, reaching the parked `JSC__IdentifierArray__create` bridge; Bun reports **4 pass / 0 fail**. The unchanged parallel selection reports **0 pass / 3 fail / 24 filtered out**, returning `ParallelTestCoordinatorNotImplemented`; Bun reports **3 pass / 0 fail**. No flags, assertions, or workloads were removed to count those as passing.

Full worker-file timing remains unresolved in [#482](https://github.com/home-lang/home/issues/482). This CLI checkpoint does not establish full Bun parity, all CLI/runtime feature implementations, complete native ownership, or other-platform verification.

## Native isolated test globals and resource release (#484)

The native module-record path now calls the actual C++ identifier-array, variable-environment, and `JSModuleRecord` functions instead of local weak panic implementations. Home owns `BunAnalyzeTranspiledModule.cpp` in the WorkerGlobalScope unity object. Generation checks its header against the selected external ABI before producing output. Cached metadata validates identifier bounds, attribute tags, string lengths, and record lengths before indexing the native identifier array. The bridge reads the metadata without taking ownership: C++ either releases it immediately or retains it on the cached SourceProvider until that provider is destroyed.

The current C++ requested-module ABI includes an import-phase boolean missing from Bun's historical Zig declarations. Home passes evaluation phase explicitly for its existing metadata producer. This does **not** implement deferred-import syntax or its serialized phase representation.

Before replacing an isolated global, Home now closes watchers without emitting close listeners, stops registered servers through their native lifecycle, retires the file's watch-file scheduler, and cancels JS timers from both real and fake heaps. Heap traversal runs under the timer lock; cancellation runs after unlocking. AbortSignal timeout cancellation releases its extra native reference without dispatching an abort event. The Home-owned `JSAbortSignalCustom.cpp` checks an atomic timeout-activity flag, so a cancelled timeout box still owned by the signal does not keep the wrapper alive through GC opaque roots. The AbortSignal class header remains unchanged and is checked against the external ABI.

The watch-file registry removes entries on the JS-thread close path, before a work-pool task can free the watcher. Closed state is atomic; scheduler work cannot be enqueued twice while its intrusive node is in flight. Retirement disarms the scheduler, waits for active work, drains queued references, and prevents late timer-update tasks from rearming it. Those queued updates hold their own native references. This is watch-file scheduler cleanup, not general work-pool shutdown completion (#468).

Server configuration teardown now balances protected fetch, error, Node HTTP, and WebSocket callbacks. Reloading transfers the new references explicitly, including repeated identical functions, and releases discarded callbacks. These releases happen when their owning config is destroyed or replaced; stopping a server does not prematurely discard handlers still needed by its JS wrapper or pending requests.

The unchanged upstream isolation file passes **19 tests / 67 assertions**, including three additional consecutive full runs. The added cases in `native-node-core-cli.test.mjs` execute eight fresh files for each of two modes: explicitly closed/reloaded handles plus pending watch-file work and long AbortSignal listeners; and fake timers plus long AbortSignal listeners. They assert fresh globals, actual Home execution, all file bodies, and a maximum of four live globals. Before the final GC fix, the long AbortSignal case retained all eight globals; afterward the focused probe plateaus at two to three. No upstream workload, assertion, or deadline was changed.

All **20 native regression files** pass. The seven CLI verification commands above remain green (**50 tests / 119 assertions**). Adjacent unchanged upstream checks pass for watch-file scheduling (**9 tests / 30 assertions; 2 platform skips**, including 1,000 watchers), discarded WebSocket reload handlers (**1 / 3**), server stop with pending requests (**2 / 3**), the server reload selection (**1 / 2; 200 filtered out**), AbortSignal behavior (**5 / 12**), and abort listener lifetime (**5 / 6**). These selected passing commands total **92 upstream tests / 242 assertions**; neither filtered nor skipped cases count as passes. The AbortSignal file's existing spawn subtest only checks absence of a failure glyph, so that subtest alone does not prove its child executed every intended assertion; the native lifecycle checks and remaining direct timeout/reason assertions provide separate evidence.

The native build and unchanged cached rebuild pass **17/17 steps**. Generation/ABI tests pass **8 tests / 135 assertions**, including source ownership rejection and AbortSignal header drift. Focused Pickier and whitespace checks pass. Three untouched legacy enum-builtin expressions in otherwise changed AbortSignal, FSWatcher, and Timer files still trigger Zig 0.17 formatter migrations; unrelated rewrites were left out.

Verification also exposed separate failures: the full fake-timer semantics file ([#490](https://github.com/home-lang/home/issues/490)) reports **16 pass / 14 fail / 65 assertions**, both before and after this isolation work, while installed Bun 1.3.14 passes **30 / 83**. The deferred-import selection ([#491](https://github.com/home-lang/home/issues/491)) fails in the parser (**0 pass / 1 fail / 19 filtered out**). Installed Bun 1.3.14 itself fails four newer cases in the full isolation file (**15 pass / 4 fail**), two watch-file cases, and the discarded WebSocket-handler regression, so it is not a passing control for those newer expectations. The pinned checkout's unchanged tests remain the target. Parallel orchestration (#485), the full worker timing failure (#482), general resource teardown, deferred imports, fake-clock semantics, other platforms, and full-suite compatibility remain outside this checkpoint.

## Native parallel test coordinator and worker pool (#485)

The native test command now activates the pinned process-pool coordinator and worker entry points instead of returning `ParallelTestCoordinatorNotImplemented`. Workers are real Home subprocesses running isolated test files. The coordinator partitions files by directory, steals work from the back of busy ranges, scales lazily, forwards test filters and runtime options, and aggregates result frames, console output, snapshots, JUnit XML, LCOV coverage, bail state, crashes, and exit accounting over the fd 3 channel. `JEST_WORKER_ID` and `BUN_TEST_WORKER_ID` remain unique per worker.

Backpressured IPC now advances an unsent offset instead of shifting the complete remaining buffer after every socket write. This keeps the pinned 68,000,000-character result-line case within its unchanged deadline while preserving the 64 MiB frame boundary and truncation marker. SIGINT and SIGTERM wake the coordinator's existing event loop before it tears down workers. The POSIX spawn adapter now maps `new_process_group` to `POSIX_SPAWN_SETPGROUP`, so terminating a worker group reaches its spawned descendants on Darwin. Current Zig signal types, allocating writers, sentinel paths, and coverage-fraction types are adapted without changing the protocol or upstream expectations.

The complete unchanged `cli/test/parallel.test.ts` passes **27 tests / 185 assertions / 1 snapshot**, including real worker identifiers, forwarding, bail, failure/crash accounting, live output, non-interleaving, JUnit and coverage merging, lazy scaling, work stealing, snapshots, the oversized result line, hostile fd 3 input, randomized replay, and coordinator signal cleanup. The original three-case reproduction is **3 pass / 24 filtered out / 24 assertions / 1 snapshot**, compared with the parked path's 0/3 result. Filtered cases are not counted as passes. Focused `home_rt` passes **1,815 tests / 19 skips / 0 failures** with **20/20 build steps**; JSC-enabled and JSC-disabled native builds pass **18/18** and **5/5** steps respectively. The execution evidence is Darwin-only; Windows/Linux runtime behavior and the complete Bun suite remain tracked by [#66](https://github.com/home-lang/home/issues/66).

## Native fake clocks and reset lifetimes (#490)

Home's mockable monotonic clock now reads the synchronized fake-clock offset. Timer deadlines, advancement, `Date.now()`, `new Date()` and `performance.now()` therefore use the same clock; internal timers can still request real time explicitly. Fractional advancement retains nanoseconds instead of truncating milliseconds. `useFakeTimers` reads and validates the actual options object, including inherited `now` getters and number/Date values, before changing clock state. The existing native Date override bridge remains authoritative.

Both `clearAllTimers()` and `useRealTimers()` now unlink fake timers under the heap lock and release their references after unlocking. Timeout/interval cancellation releases the removed heap pin, disables event-loop liveness and downgrades the JS wrapper; AbortSignal timeout cancellation releases its native reference without emitting an abort. Retained cancelled handles stay safe to inspect and cannot revive callbacks through `refresh()`.

The unchanged core fake-timer file now passes **30 tests / 83 assertions**, up from **16 pass / 14 fail / 65 assertions**. Installed Bun 1.3.14 passes the same **30 / 83** control. Running the entire upstream fake-timer directory reports **61 pass / 438 TODO / 0 fail / 115 assertions** in both runtimes. However, **14 of those reported passes are `it.failing` cases**; they and all 438 TODOs are not evidence of implemented features. That leaves 47 ordinary passing tests, including the core 30. No upstream tests or helper adapters were changed; 24 selected corpus files were verified byte-for-byte against source pin `4982b91e3702094330f3be3883354c52b8c01323`.

The new `native-fake-timers.test.mjs` checks actual Home execution, getter errors without clock mutation, nested callbacks and intervals, fractional advancement, cancelled handles, and natural exit. Repeated resets allocate 3,072 timeout/interval wrappers and 1,536 AbortSignal timeouts, with GC checks that retained wrapper counts remain bounded. It passes alongside all **21 native regression files**, plus three additional consecutive focused runs. The cached pre-change binary fails the new test because it never reads the options getter. The unchanged isolation suite remains green at **19 tests / 67 assertions**, and timers/promises passes **4 / 7**. Native build and cached rebuild pass **17/17 steps**; focused Pickier, timer-file Zig formatting and whitespace checks pass.

At this checkpoint the wider Node timer file executed 19 tests, then hung on the caught-immediate-exception fixture. The same fixture hung in the pre-change Home binary and succeeded in Bun; the original-checkout Bun control passed the full **20 tests / 31 assertions**. This was tracked in [#493](https://github.com/home-lang/home/issues/493), with unchanged workloads and external process-group deadlines. The following investigation identified an import-time spawn failure, not an immediate continuation/ordering defect. Full-suite parity, deferred imports (#491), parallel orchestration (#485), full worker timing (#482), other platforms and remaining native ownership work are still open.

## Native POSIX spawn errors and setup failure cleanup (#493)

A native stack sample traced the timer fixture hang to Node's common ESM helper reading `common.opensslCli` during import. That getter calls `spawnSync` on a missing absolute executable path, before any immediate callbacks are scheduled. Home's libc `posix_spawn` wrapper interpreted its direct positive errno return as a successful syscall and tried to watch PID 0. The wrapper now preserves the returned errno and executable path. `wait4` retains its separate -1/errno convention.

The native attribute and file-action wrappers also preserve direct errno results and propagate setup failures instead of discarding requested actions. This covers Darwin's `EBADF` at fd 10240. Temporary native objects are destroyed on every return path, and the extra-fd registration list is released on `Maybe.err` as well as Zig errors; successful spawns transfer that list into the owning process. No timer scheduling or exception-dispatch code was changed for this fix.

The unchanged immediate fixture now exits successfully, and the full unchanged Node timer file passes **20 tests / 31 assertions**. The selected child-process missing-command and invalid-fd cases pass **2 tests / 9 assertions**, with **32 filtered cases excluded**. The PATH-from-env file passes **1 / 2**. All **21 native regression files** pass, including an extension to `native-node-core-cli.test.mjs` that repeats missing-path, permission and invalid-cwd failures, rejects invalid extra-fd setup, checks descriptor counts, verifies no user microtask re-entry during `spawnSync`, and successfully spawns after failures. Isolation (**19 / 67**), core fake timers (**30 / 83**) and timers/promises (**4 / 7**) remain green. These checks comprise **28 successful commands**; standalone fixture/native commands are not added to upstream test counts. Native build and cached rebuild pass **17/17 steps**. Focused Pickier, spawn-wrapper Zig formatting and whitespace checks pass. Eight relevant upstream files, including both common helpers, match the pinned Bun checkout byte-for-byte.

Broader suites still expose separate gaps. The complete child-process file reports **30 pass / 2 fail / 1 skip / 1 TODO / 70 assertions**: extra stdio pipe arrays are rejected before the GC workload ([#495](https://github.com/home-lang/home/issues/495)), and package-script passthrough reaches a missing `run` entry path ([#497](https://github.com/home-lang/home/issues/497)). The spawnSync file reports **4 pass / 1 fail / 1 platform skip / 11 assertions** because the real native counter snapshot bridge is still parked ([#496](https://github.com/home-lang/home/issues/496)). Installed Bun 1.3.14 passes the latter two scenarios and the extra-pipe case, but fails the newer invalid-fd case itself; its complete child-process result is **31 pass / 1 fail / 1 skip / 1 TODO / 71 assertions**. No incomplete suite, expected failure, skip or TODO counts as full logical parity. Linux, Windows, PTY behavior and broader native ownership are not established by this Darwin checkpoint.

## Native extra-stdio ownership and real counter snapshots (#495, #496)

The selected Bun `node:child_process` builtin requests `socket-fd` for extra pipe slots, then gives each parent fd to a `net.Socket`. Home now parses and maps that native stdio mode. POSIX socketpairs remain owned by spawn during fallible setup and become caller-owned only immediately before the JS Subprocess is returned. This keeps error cleanup responsible for descriptors that JavaScript never received, while exit and Subprocess GC cannot close an fd already owned by a Node socket. The mode rejects indices below three and synchronous spawn, whose result cannot expose the fd. Windows maps the mode to the existing libuv pipe path, matching the selected source; Windows execution was not verified here.

`getCounters()` now calls the real invoking VM's native counter snapshot bridge. The weak stub that returned the global object is removed. Each call creates a distinct plain snapshot; mutating it cannot change the runtime. Existing native spawn paths supply the increments, with no fabricated success values. The extended native core test checks field types, snapshots, the real blocking fast-path increment, buffered-spawn behavior, and failure-path behavior. Linux can allocate memfds before the OS rejects a spawn, so the test does not incorrectly require its allocation counter to stay unchanged after such a failure. Repeated missing-executable and invalid-later-fd cases also exercise cleanup after creating extra socketpairs.

Verification on Darwin arm64:

- All **21 native regression files** pass. Together with nine selected unchanged upstream commands and the standalone immediate fixture, the regression batch completes **31 successful commands**. The final expanded native core test also passes separately.
- The complete unchanged spawnSync file improves to **5 pass / 1 Linux-only skip / 0 fail / 11 assertions**. Linux memfd behavior remains unverified, not counted as a pass.
- All three unchanged socket-fd cases pass **3 tests / 5 assertions**, including caller reads after child exit and an explicit caller close; **128 filtered cases are excluded**. A repeated focused run also passes.
- The unchanged 20-round extra-pipe GC workload passes **1 test / 1 assertion**, with **33 filtered cases excluded**. The complete child-process file improves to **31 pass / 1 fail / 1 skip / 1 TODO / 70 assertions**. Its remaining failure is package-script dispatch in [#497](https://github.com/home-lang/home/issues/497), not extra-pipe cleanup.
- Isolation remains **19 / 67**, Node timers **20 / 31**, timers/promises **4 / 7**, core fake timers **30 / 83**, missing-command/invalid-fd selection **2 / 9**, and spawn PATH **1 / 2**.
- The prior published binary fails the new counter assertions and the unchanged extra-pipe workload. Ten selected corpus files match source pin `4982b91e3702094330f3be3883354c52b8c01323` byte-for-byte. No upstream assertion, workload or deadline was changed.
- Native build and cached rebuild pass **17/17 steps**. Focused Pickier, six Zig-file format checks and scoped whitespace checks pass. Formatting copies of the remaining three changed Zig files shows only pre-existing enum-builtin migrations and one unrelated formatting block; those rewrites were left out.

Broader extra-stdio input coverage remains open in [#499](https://github.com/home-lang/home/issues/499): an empty Blob is wrongly rejected and a direct ReadableStream reaches an unreachable native branch. The same stream panic reproduces in the prior published binary. The 16-case selection aborts and is not green. Installed Bun 1.3.14 fails that newer selection itself and is not a passing control for it.

The full spawn file did not complete within a 120-second external probe bound; the older published binary also did not complete within a separate 60-second probe. Both last reported nine passing tests before the onExit workload. These are incomplete bounded runs, not proof of failure at that test's original 600-second deadline. A separate two-child onExit probe succeeds in both Home binaries and Bun; it does not replace the original workload. Full spawn coverage, Linux/Windows validation, remaining native ownership and complete Bun-suite compatibility remain outstanding under [#66](https://github.com/home-lang/home/issues/66).

## Native subprocess input ownership and stale-poll teardown (#499, #501, #502)

Extra-stdio validation now matches the selected current Bun implementation: empty Blob inputs become ignored slots, while nonempty Blob and direct/Response/Request-backed stream inputs receive the indexed JavaScript errors instead of reaching native unreachable branches. Rejected or ignored owned Blob values release their native store and metadata; caller-owned Blob objects remain usable. Parsed in-memory stdin payloads are also released when a later option or native spawn fails. Successful writer initialization explicitly transfers that ownership, and terminal stdio replacement discards the payloads it supersedes.

ArrayBuffer inputs now copy the selected byte slice before acquiring the native writer's Strong reference. Keeping a caller's wrapper alive cannot prevent mutation or transfer of its backing storage. The owned copy preserves offsets and lengths and remains valid while asynchronous writes are pending. The native core suite exercises ArrayBuffer, Uint8Array, DataView and Buffer inputs with immediate mutation and transfer/detachment followed by GC, using two MiB of input per scenario. Its repeated-rejection case mixes Blob/Response/Request extra inputs with already-parsed Blob/typed-array stdin, checking a 32 MiB post-warmup RSS-growth bound and descriptor counts. The old published binary fails that bound with roughly 160 MiB of growth; a separate old-binary snapshot probe delivers all 2,097,152 bytes mutated instead of their original value.

FilePoll now decodes Darwin kevent error-event data as an errno value, preserving the separate global syscall-return convention. Invalid error data falls back to EINVAL. ENOENT/EBADF during deregistration means the registration is already gone, so native flags are still cleared; other errors remain errors. This handling is ported across the selected Darwin/Linux/FreeBSD branches, but only Darwin execution is verified locally. The unchanged stale-fd fixture had previously reached a null unwrap and then its five-second outer timeout. The fix preserves its close/reuse, pending-read cancellation and child-cleanup workload.

Verification for this input/poll checkpoint:

- The final native binary passes **34 main regression commands**, including all **21 native regression files**. The expanded native core file passes three further runs, one with `BUN_DESTRUCT_VM_ON_EXIT=1`; the stale-fd corpus file passes three further runs as well.
- The complete unchanged spawn file passes **126 tests / 5,484 assertions / 5 existing skips**. Its original onExit workload executes all 2,000 assertions; no workload or deadline was reduced. The test process exits with status zero. Its deliberately unreferenced `sleep 999999` fixture descendant was cleaned up afterward in the owned test process group, without terminating the tested parent. The earlier short probes did not establish a test failure.
- The extra-input selection passes **16 / 24**, with **115 filtered tests excluded**. The stale-fd file passes **1 / 3**. The stream edge-case file passes **12 / 41**, with **1 TODO excluded**. The seven additional empty-input, sync-stream, stream-integration, readable-stream, streaming-input, stdin-destroy and stdin-fd-lifetime files pass **34 tests / 197 assertions**, with **3 TODOs excluded**.
- Existing isolation, timers, fake timers, counters, PATH and extra-pipe checks remain green. Thirteen selected upstream test files were verified byte-for-byte against source pin `4982b91e3702094330f3be3883354c52b8c01323`; no corpus tests or fixtures were edited.
- Final build and unchanged cached rebuild pass **17/17 steps**. Focused Pickier, the stdio/Writable Zig format checks and scoped whitespace checks pass. FilePoll retains three pre-existing enum-builtin formatter migrations; the spawn binding retains one unrelated formatting block.

One verification attempt encountered host ENOSPC errors and is not counted as passing. Only obsolete intermediate outputs in this task's isolated runtime cache were removed; the installed binary, selected control binaries and unrelated shared worktree changes were preserved. The full regression batch and repeat checks were then rerun successfully with disk space available.

The complete child-process file still reports **31 pass / 1 fail / 1 skip / 1 TODO / 70 assertions** because of package-script dispatch in [#497](https://github.com/home-lang/home/issues/497). The newly recorded terminal gap is [#503](https://github.com/home-lang/home/issues/503): Home's selected terminal integration cases report **0 pass / 3 fail / 13 filtered out**, with skeleton terminal creation/I/O methods. The pre-change Home binary fails identically. Installed Bun 1.3.14 passes only the inline-terminal case and times out on the other two, so it is not a passing control for the whole newer selection. Terminal payload replacement cleanup is not evidence that terminal support is implemented. General native ownership, other-platform execution and the complete Bun suite remain unfinished under [#66](https://github.com/home-lang/home/issues/66).

## Native terminal PTYs, controlling sessions and teardown (#503)

`Terminal.zig` now implements actual PTY allocation, reader/writer I/O, callbacks, resize, termios access, raw mode, references and disposal in place of the skeleton. The implementation follows the pinned Zig source and was checked against `terminal.rs` at `4982b91e3702094330f3be3883354c52b8c01323`. Terminal writers participate in native FilePoll dispatch. POSIX backpressure completion delivers the drain callback after buffered bytes have drained. Reader references are acquired before synchronous registration callbacks; EOF/error release happens once, after re-entrant JavaScript returns. Disposal suppresses callbacks and releases the strong wrapper reference.

Home's VM startup now calls the native process initializer once, recording inherited TTY descriptors and their original attributes, and registers stdio restoration at exit. This enables real `node:tty` process streams and fixes child `isTTY`, dimensions, raw mode and restoration behavior. PTY spawns use the native fork/exec helper and error pipe for `setsid`/`TIOCSCTTY`; ordinary spawns retain their existing path and errno handling. Standalone terminals remain reusable, while inline terminals close the parent's slave descriptor to deliver EOF when the child exits.

Each terminal owns its raw-mode snapshot, so toggling one cannot restore another's settings. Darwin's 64-bit termios flag conversion saturates before converting a rounded JavaScript number; Infinity and NaN no longer risk integer overflow. The `openpty` signature now uses the actual platform termios type, replacing the skeleton's incorrect fixed 44-byte ABI assumption.

Final Darwin verification:

| Unchanged upstream file | Passed | Assertions | Excluded |
| --- | ---: | ---: | --- |
| `terminal.test.ts` | 89 | 220 | 1 TODO |
| `terminal-spawn.test.ts` | 15 | 72 | 1 Windows-only skip |
| `terminal-platform-gaps.test.ts` | 19 | 31 | None |
| `stdin-pause-pty.test.ts` | 1 | 2, plus 1 snapshot | None |

All four files and the inspected readline child fixture are byte-identical to the source pin. Tests exercise real bytes, controlling-terminal access, Ctrl+C, SIGWINCH, SIGHUP, dimensions, terminal reuse and stdio restoration. No corpus assertions, workloads or deadlines were changed.

The new `tests/runtime/native-terminal.test.mjs` checks natural unref exit and positive ref/re-ref controls, independent raw modes, a 1,048,593-byte backpressured input whose caller buffer is overwritten, drain receiver identity, `/dev/tty` dimensions, constructor failures with zero through three descriptor slots available, 48 disposal/failed-inline-spawn cycles with overridden Blob/typed-array inputs, collectible retired wrappers with a retained positive control, and 24 close/GC callbacks during reading. The previous published binary fails its reference-liveness control. Darwin's transient PENDIN bit is excluded only from raw-mode snapshot comparison; actual terminal settings are still checked.

The final native binary passes **39 regression commands**, including all **22 native regression files**, the four files above and the complete unchanged spawn file (**126 passed / 5,484 assertions / 5 skips**). Its deliberately unreferenced sleep descendant was cleaned up after the tested parent exited normally. Three additional native terminal runs pass, including VM destruction at exit. Seven adjacent stdin suites pass **34 tests / 197 assertions**, with **3 TODOs excluded**. Native build and cached rebuild pass **17/17 steps**; focused Pickier, Terminal/spawn Zig formatting and scoped whitespace checks pass.

The complete child-process file still reports **31 passed / 1 failed / 1 skipped / 1 TODO / 70 assertions**: package-script dispatch remains tracked in [#497](https://github.com/home-lang/home/issues/497). Linux/Windows execution and cross-compilation have not been verified in this checkpoint; restored ConPTY source is not a verified Windows result. [#503](https://github.com/home-lang/home/issues/503) stays open for integration and platform verification. The complete Bun port and suite remain unfinished under [#66](https://github.com/home-lang/home/issues/66).

## Native package scripts, CLI binaries and inherited stdio (#497)

Native dispatch now recognizes runtime flags before `run`, parses argument-taking flags, and resolves named package scripts through the existing package/environment resolver. Scripts execute their actual pre/main/post commands in the package directory, with lifecycle metadata, local binary paths and escaped arguments. Only the main script receives passthrough arguments; empty arguments are explicitly quoted. Module resolution precedes PATH fallback, including extensionless TypeScript entries. Existing Home source and VM entrypoints remain separate.

The runner loads local bunfig settings and chooses the system shell from the original PATH before adding dependency binaries. Nested `bun` commands resolve to Home; `--bun` also resolves Node shebangs to Home. POSIX aliases use a persistent cache per executable, with directory ownership/mode/type and symlink-target validation. They remain usable after process exit, as required by background children and `which node` callers. The previous shared debug directory is no longer recursively deleted.

The internal synchronous-spawn import now delegates to the pinned full runtime implementation instead of maintaining a reduced second process backend. Inherited and ignored streams, concurrent buffered output, IPC descriptor adoption, detached spawning, stdin buffers, independent `argv0`, and macOS spawn-as-exec therefore share the same ownership, waiting, signal, and cleanup paths. A native parent/child regression passes fd 3 through `NODE_CHANNEL_FD` and a synchronous package-script exec, where the reduced helper returned `UnsupportedIpcDescriptor`. Focused native package, `bunx`, changed-test capture, JSC-enabled and JSC-disabled builds pass. This checkpoint executes on Darwin; detached/input behavior on Linux and Windows remains part of the broader platform work in [#66](https://github.com/home-lang/home/issues/66).

Final Darwin verification:

| Coverage | Result |
| --- | --- |
| Complete unchanged `child_process.test.ts` | 32 pass, 0 fail, 72 assertions; 1 skip and 1 TODO excluded |
| Eight adjacent CLI/bunfig/shell files | 48 pass, 0 fail, 106 assertions; 1 Windows-only skip excluded |
| Complete unchanged `spawn.test.ts` | 126 pass, 0 fail, 5,484 assertions; 5 skips excluded |
| Full regression command set | 49/49 commands, including all 23 native regression files |
| Complete unchanged `cli/install/bun-run.test.ts` | 258 pass, 33 fail, 380 assertions across 291 cases |

The broader `bun-run` file previously reported 160 pass / 131 fail on the published `8157bde43c9649afa9276af708463ed5fb28117d` binary. The final comparison resolves 98 failing cases with no newly failing test names. Its remaining loader/diagnostic, VM-option, workspace-filter and `bun x` gaps are tracked in [#508](https://github.com/home-lang/home/issues/508). The unchanged dotenv file still reports 1 pass / 8 fail / 28 assertions, reproduced on the previous binary and tracked separately in [#506](https://github.com/home-lang/home/issues/506). The `run_command` test runs from the copied corpus root: inheriting Home's repository root instead finds Home's real `dev` script, invalidating that test's missing-script assumption.

`tests/runtime/native-package-run.test.mjs` verifies native child identity, lifecycle metadata/order, shell-sensitive and empty arguments under both shells, cwd/precedence, extension resolution, failure propagation, stdin transfer, output visible before process exit, actual SIGKILL termination, persistent alias resolution and rejection of unsafe cache permissions/targets. It also passes with `BUN_DESTRUCT_VM_ON_EXIT=1`; the previous published binary fails its native dispatch control. All 11 measured CLI/child-process source files are byte-identical to pin `4982b91e3702094330f3be3883354c52b8c01323`. No corpus expectations, workloads or deadlines were changed. The complete spawn run retains the original 1,000-iteration onExit workload; owned unreferenced descendants are cleaned only after their tested parent exits.

Native build and cached rebuild pass 17/17 steps; scoped Pickier, Zig formatting and whitespace checks pass. Local evidence is retained in `zig-out/package-final-regressions.json`, `package-wide-{baseline,final}.json`, `package-wide-comparison.json`, `package-native-controls.json` and `package-corpus-integrity.json`. This checkpoint is Darwin-only; Linux/Windows execution and cross-compilation remain unverified. [#497](https://github.com/home-lang/home/issues/497) remains open for integration/platform verification, and the complete port remains unfinished under [#66](https://github.com/home-lang/home/issues/66).

## Native module/eval CLI context and bunfig propagation (#506)

Native VM startup now retains the actual parsed CLI context instead of replacing it with default TransformOptions. Package lookup passes its context through when the target resolves to a module, so relative `--cwd` is applied once. File and inline-eval execution receive dotenv settings, explicit env files, preloads, defines, loaders, conditions, symlink settings and the existing runtime/resolver options. The DCE flag now reaches the transpiler. The global context used by console formatting is preserved as well.

Eval parses only leading runtime options; its source and trailing script arguments remain owned by the existing eval dispatcher. A parser-only synthetic TypeScript positional ensures bunfig loads before CLI overrides without changing the VM's `[eval]` path or `process._eval`. The previously accepted Node `--input-type` flag is registered as value-taking so later flags are not lost. This does not establish full Node input-type enforcement. Redundant manual preload/condition collection was removed, while existing comma-separated and repeated conditions remain supported.

Darwin results against published parent `06a212514bfd7f8b5a17778543642f7aeb36598d`:

| Complete unchanged upstream file | Before | After | Final assertions / exclusions |
| --- | --- | --- | --- |
| `cli/run/no-envfile.test.ts` | 1 pass / 8 fail | 9 pass / 0 fail | 36 assertions |
| `cli/run/env.test.ts` | 64 pass / 15 fail | 76 pass / 3 fail | 89 assertions; 2 skips, 2 TODOs |
| `config/bunfig/preload.test.ts` | 6 pass / 12 fail | 18 pass / 0 fail | 52 assertions, 2 snapshots; 2 skips, 1 TODO |
| `cli/console-depth.test.ts` | 3 pass / 6 fail | 9 pass / 0 fail | 25 assertions, 9 snapshots |
| `cli/install/bun-run.test.ts` | 258 pass / 33 fail | 259 pass / 32 fail | 381 assertions |

The comparisons identify 39 resolved failing test names across these files and no newly failing names. The remaining three env failures reproduce on the parent binary and are tracked in [#510](https://github.com/home-lang/home/issues/510): dotenv expansion, escaped dollar signs and same-file override boundaries. The 32 broader CLI failures remain in [#508](https://github.com/home-lang/home/issues/508). Skips and TODOs are excluded from passing counts.

All 49 runtime regression commands pass, including all 23 native files, complete spawn (**126 pass / 5,484 assertions; 5 skips**) and child-process (**32 pass / 72 assertions; 1 skip, 1 TODO**) files. The expanded native package/eval checks also pass with VM destruction enabled. They cover relative cwd, explicit env files, bunfig/CLI precedence, exactly-once preloads, script argument boundaries, custom loaders and repeated/comma-separated ESM/CommonJS conditions; the parent binary fails the new configuration controls. The spawn workload retains all 1,000 onExit iterations, and owned unreferenced descendants are cleaned only after their tested parent exits naturally.

Build and cached rebuild pass 17/17 steps. Focused Pickier, Zig formatting and scoped whitespace checks pass. All five measured upstream files and 33 preload fixtures are byte-identical to pin `4982b91e3702094330f3be3883354c52b8c01323`. Evidence is retained in `zig-out/cli-context-{baseline,build1,comparison,final-regressions,destruction,corpus-integrity,final-binary}.json` and the adjacent/wide comparison files. Older owned object files were losslessly compressed with verified hashes to recover disk space; their executable controls remain intact. This checkpoint does not establish Linux/Windows execution, platform integration or full-suite compatibility. #506 remains open for integration/platform verification; #66 remains unfinished.

## Native dotenv expansion and replacement ownership (#510)

The dotenv parser now keeps the map's initial entry count fixed. Variables inherited from the process or earlier files retain precedence and are not expanded again; later definitions within the current file replace earlier definitions. Newly added entries expand in insertion order through the existing Bun expansion algorithm, including escaped dollars and default values. This restores the selected source's boundary semantics instead of expanding all environment values indiscriminately.

Replacement values are allocated before modifying the map, so allocation failure leaves valid entries. Same-file replacements release the parser's previous allocation. A small bitmap tracks inherited slots replaced by an overriding parse: original borrowed values remain with their owners, while subsequent replacements of those slots release parser-owned allocations. This preserves Home's borrowed environment-map contract; it does not convert every map/worker environment lifetime to Rust's owning representation.

The complete unchanged `cli/run/env.test.ts` now passes **79 tests / 89 assertions**, up from **76 pass / 3 fail** on published parent `bfdb5f3188e6a6b8f0bea7070131144f5813c046`. Its **2 skips and 2 TODOs are excluded**. `no-envfile.test.ts` remains green at **9 / 36**. The unchanged upstream Node `test-util-parse-env.js` also exits successfully. These files and its dotenv fixture match source pin `4982b91e3702094330f3be3883354c52b8c01323` byte-for-byte.

The expanded native package regression checks duplicate definitions, chained/default/escaped expansion, inherited literal and empty values, explicit/repeated env files, and 512 non-expanding `util.parseEnv` calls with periodic GC. It passes in module, explicit-run and eval modes, and with VM destruction enabled; the parent binary fails the new dotenv control. Two Zig tests verify inherited/earlier-file boundaries, replacement cleanup and every allocation-failure point using the testing allocator.

Running the full Zig substrate suite exposed obsolete `.unwrap()` calls in spawn tests and a missing N-API registration dispatch in the test root. The calls now use the actual error-union API without dropping assertions. The test root forwards registration to the existing complete native N-API implementation; no placeholder implementation was added. The suite now executes **1,818 passing tests / 19 skips / 1 failure**, including both passing dotenv allocator tests. At this checkpoint, the reduced-realm stream failure and an incorrect stream-unit identity expectation remained under [#512](https://github.com/home-lang/home/issues/512), so the unit suite was **not fully green**. The initially reported native unsized-read difference was subsequently confirmed to match the exact Bun pin; see the correction below.

The final native binary passes **54 runtime regression commands**, including all 23 native files, full spawn (**126 pass / 5,484 assertions; 5 skips**) and full child-process (**32 pass / 72 assertions; 1 skip, 1 TODO**). No upstream workloads, assertions or deadlines were changed; the spawn run retains its original 1,000 onExit iterations. The full 291-case CLI file remains **259 pass / 32 fail / 381 assertions**, with no newly failing names (#508). Native build/cached build pass **17/17 steps**, and focused Pickier, Zig formatting and whitespace checks pass.

Evidence: `zig-out/dotenv-{baseline,current,comparison,final-regressions,destruction-final,corpus-integrity,final-binary}.json`, `dotenv-unit-build3.log`, `dotenv-stream-unit-controls.json`, and `package-wide-dotenv-final.json`. Verification is Darwin-only. #510 remains open for integration/platform verification, and the full port remains unfinished under #66.

## Stream contracts and router fixture isolation

The initial diagnosis in [#512](https://github.com/home-lang/home/issues/512) incorrectly treated an installed Bun/Node difference as a missing port. The exact `4982b91e3702094330f3be3883354c52b8c01323` Git object for `internal/streams/readable.ts::howMuchToRead` deliberately returns the first buffered byte chunk for an unsized read, even when paused. Home already matches that pin. No concatenation override was added to the full VM.

The reduced-realm exception had a separate cause: earlier router fixtures changed the process cwd without restoring it, so the stream unit could not resolve the upstream `common` module. Router construction now restores cwd on success or error and closes fixture directory/file handles. The existing route test asserts that cwd is unchanged. JavaScript probe failures now report their actual exception instead of discarding it.

The reduced C-API stream implementation now normalizes typed-array/DataView byte chunks to Buffers sharing their original storage, matching `internal/stream.ts::_uint8ArrayToBuffer`. Object mode preserves value identity, and `Readable.from` defaults to object mode. The corrected unit retains its real upstream `common` import and checks Buffer versus Uint8Array identity, byte offsets/content, sized reads across chunks, object-mode reads and decoded reads. The native CLI regression also checks DataView offsets, iterable identity and split UTF-8 decoding. This is limited reduced-realm coverage, not a claim that its entire stream implementation has been ported.

The complete runtime unit suite passes **1,819 tests / 19 skips / 0 failures** (1,838 total; one fuzz test discovered, not a full fuzz campaign). The final native build passes **17/17** steps. All **54 native regression commands** pass, including all 23 native regression files, full spawn (**126 pass / 5 skip / 5,484 assertions**), full child-process (**32 pass / 1 skip / 1 TODO / 72 assertions**) and dotenv (**79 pass / 2 skip / 2 TODO / 89 assertions**). The corrected unit's exact JavaScript body also returns true in the full native VM.

Both the published parent and final binary pass **246 / 252** unchanged upstream Node `test-stream*` files, with identical failing filenames/statuses and no regressions; all **63** focused readable/byte/object/decoder fixtures passed. The six remaining failures are tracked in [#513](https://github.com/home-lang/home/issues/513) (the pinned Rust Brotli decoder-code mapping) and [#514](https://github.com/home-lang/home/issues/514) (two pipeline timeouts and three missing internal-wrapper modules). Both pipeline timeouts reproduced with 45-second bounds. Native stream builtins still partly use configured external builtin literals; these results do not establish complete source ownership.

Evidence: `zig-out/stream-unit-{diagnostic,fixed}.log`, `stream-source-integrity.json`, `stream-final-{binary,regressions}.json`, `stream-exact-unit-native.json`, `stream-{all,final-all}-results.json`, `stream-final-comparison.json`, and `stream-failure-controls.json`. Verification is Darwin-only; branch integration and other platforms remain unverified. The full port remains incomplete under [#66](https://github.com/home-lang/home/issues/66).

## Brotli error mapping and HTTP/2 stream/header contracts

The exact Bun pin `4982b91e3702094330f3be3883354c52b8c01323` maps every Brotli decoder enum to `ERR__<enum name>`; Home's earlier `ERR_BROTLI_DECODER_` prefix was not compatible. Home now keeps the enum suffix's leading underscore. Six corrupt-input classes plus the truncated-input control cover synchronous, promisified callback and pipeline surfaces, followed by a successful round trip. Seven unchanged pinned Brotli Node fixtures, the unchanged stream-iterator error fixture, the native regression and the three-test reentrancy suite pass. The full unchanged `zlib.test.js` is **377 pass / 2 skip / 1 fail / 429 assertions**. Its one failure is the separately tracked async buffer lifetime defect in [#516](https://github.com/home-lang/home/issues/516), so compression parity is not complete.

The HTTP/2 parser previously discarded the stream object returned by the pinned JavaScript `streamStart` callback and sent `streamHeaders` a flat array instead of its `[rawHeaders, headersObject, sensitiveNames]` tuple. It now retains the returned stream, packs transient HPACK output for the pin's owned C++ materializer, and sends the expected tuple. The outbound path handles raw `[name, value, ...]` pairs without enumerating array indices and applies the pin's header-value, sensitivity and numeric-name rules.

Sixteen byte-identical pinned HTTP/2 header and validation fixtures pass. The unchanged `test-stream-pipeline-http2.js` exits naturally, and the real-loopback regression covers both-side pipeline cancellation, natural shutdown, duplicates, cookies, sensitive names, numeric status, set-cookie arrays, continuations, trailers, multiplexing, reset, ping and GOAWAY. It also passes with JSC exception-check validation enabled. The native source generator passes **3 tests / 111 assertions**, and the final binary contains the owned materializer symbol.

The full byte-identical stream scan improves from **246 / 252** to **248 / 252**. `test-stream-pipeline.js` still times out in its HTTP/1 case starting at line 271, and the three internal `js_stream_socket` wrapper fixtures remain unavailable; all four stay open in [#514](https://github.com/home-lang/home/issues/514). Isolated diagnostics are not counted as upstream passes. Evidence: `zig-out/stream-codec-h2-{all,zlib}-results.json`, `http2-raw-corpus-results.json`, `http2-headers-results.json`, `http2-exception-check.json`, `pipeline-blocks-results.json`, `http-pipeline-chunks-results.json`, and `stream-codec-h2-source-integrity.json`. Verification is Darwin-only, the branch is not merged to main, and [#66](https://github.com/home-lang/home/issues/66) remains incomplete.

## Native compression buffer ownership (#516)

Asynchronous Zlib, Brotli and Zstd writes now follow the selected Bun lifetime contract. Input and output views are validated before ownership changes, their backing stores are pinned against transfer and then resolved again, and generated cached fields independently keep both JavaScript views alive while native work runs. Completion releases both pins and GC roots before invoking error or write callbacks, including the case where input and output share one backing store. Rejected bounds and concurrent-write paths do not acquire pins.

Compression write-state arrays are retained as cached JavaScript values rather than raw native pointers. Sync and async completions resolve the current typed-array backing store before writing the two result words, so detaching the original `_writeState` storage cannot produce a stale write. The class schema matches source pin `4982b91e3702094330f3be3883354c52b8c01323`; the generated native binary exposes all 18 cache accessors for the three classes plus the ArrayBuffer pin/unpin bridge.

The cross-codec native regression covers transfer blocking and release, shared-storage pin balancing, validation-before-pin behavior, concurrent-write rejection, GC retention during work and collection after completion. It passes 20 consecutive runs with JSC exception checks enabled; the previous published binary fails its first input-pin assertion. The unchanged pinned bounds and re-entrancy files pass **9 / 9** and **3 / 3** tests. The complete unchanged `zlib.test.js` is now **378 pass / 2 skip / 0 fail / 434 assertions**, resolving its prior lifetime failure.

The final build passes **17/17 steps**, the runtime unit suite passes **1,819 tests / 19 skips / 0 failures**, and all **55 runtime regression commands** pass, including all **24 native regression files**, complete spawn and child-process coverage. No upstream test or fixture was edited. Evidence: `zig-out/compression-lifetime-{build-final,unit,regressions,stress,upstream-final}*` and `compression-lifetime-source-integrity.json`. Verification is Darwin-only; [#516](https://github.com/home-lang/home/issues/516) remains open for integration and other-platform verification, and the complete port remains unfinished under [#66](https://github.com/home-lang/home/issues/66).

### Stream failure baseline correction (#514)

The local Bun release executable reports `1.4.0-canary.1+4982b91e3` and reproduces the HTTP/1 pipeline timeout: its complete unchanged `test-stream-pipeline.js` exceeds a 45-second bound, and the isolated diagnostic has the same empty keep-alive response and unfinished request pipeline as Home. Node instead rejects the unframed follow-up bytes with a 400 response and closes the socket. The exact pinned uWS parser waits for more bytes while the method token has no delimiter. No Home-specific difference is established for this case; it still fails the requested full-suite goal and is not counted as passing.

The exact pin also has no `internal/js_stream_socket` or `internal/test/binding` source module, and neither appears in its `exposedInternals` map. The local release control rejects `bun:internal-for-testing` even with its feature environment variable, so that run cannot establish execution parity for the three wrapper tests. Home's missing-module failures and the unimplemented wrapper/socket behavior remain explicit in #514. Evidence: `zig-out/http1-pipeline-{lifecycle,pinned}-results.json` and `http1-wrap-flag-results.json`. These baseline findings do not resolve the four failing stream files.

## Native CLI entrypoint diagnostics (#508)

Implicit file runs and explicit `run` now share the native entrypoint preflight. It resolves extensionless and directory entries, rejects non-runnable loaders, preserves the original target spelling in missing-module/file/script errors, and emits CLI diagnostics without a VM exception footer. A valid PATH binary can still win after an unrunnable data-file resolution, and `--if-present` retains its silent-success boundary. Actual exceptions from evaluated JavaScript keep their runtime traceback and footer.

Automatic dispatch prefers an existing readable runnable file over a same-named package script, while explicit `run` prefers the script. The probe opens and fstats the file, so an unreadable `.js` file can fall through to its package script; a missing `.js` file also permits script lookup before resolving a `.ts` sibling. This read-permission edge was reproduced against the local Bun release control and is covered by the native regression on unprivileged POSIX runs. Successful VM execution now flushes the resolver/transpiler log after `onBeforeExit`, matching the selected pin's nonfatal debug-diagnostic behavior.

The complete unchanged `cli/install/bun-run.test.ts` is byte-identical to source pin `4982b91e3702094330f3be3883354c52b8c01323`:

| Checkpoint | Passing | Failing | Assertions |
| --- | ---: | ---: | ---: |
| Published parent | 259 | 32 | 381 |
| Native entrypoint diagnostics | 287 | 4 | 411 |

The comparison resolves 28 failing test names and introduces none. The expanded native package regression covers missing targets, unrunnable JSON, binary fallback, file/script precedence, loader overrides, real runtime exceptions, and both debug and quiet config behavior. It passes normally and with VM destruction plus JSC exception checks. The final build passes **17/17 steps**, runtime units pass **1,819 tests / 19 skips / 0 failures**, and all **55 regression commands** pass, including all **24 native files**, complete spawn and child-process tests. The earlier published binary fails the new missing-module diagnostic assertion. No upstream test, assertion, fixture or deadline was changed.

The four remaining bun-run failures are three native `bun x` dispatch cases ([#518](https://github.com/home-lang/home/issues/518)) and workspace-filter execution ([#519](https://github.com/home-lang/home/issues/519)). Optional config-value parsing versus Home's outer target scanner is an additional gap ([#517](https://github.com/home-lang/home/issues/517)); attached `--config=PATH` is used for the verified debug/quiet regression. These counts do not establish complete CLI or source-ownership parity. Verification used the shared Darwin checkout; unrelated compiler edits are excluded from this commit. The branch is not merged to main, and [#66](https://github.com/home-lang/home/issues/66) remains incomplete.

The final unit rebuild initially failed with `NoSpaceLeft`; its successful rerun followed cleanup of five verified obsolete task artifacts. The failed run remains recorded in `entrypoint-unit-nospace.{log,json}`.

Evidence: `zig-out/entrypoint-build5.{log,json}`, `entrypoint-unit.{log,json}`, `entrypoint-regressions.json`, `entrypoint-native-{final,destruction,parent}.json`, `package-wide-entrypoint-{baseline,final}.json`, `entrypoint-comparison.json`, `entrypoint-readable-control.json`, `entrypoint-config{,2}-control.json`, and `entrypoint-source-integrity.json`.

## Native workspace-filter execution (#519)

Native implicit runs and explicit `run` now dispatch `--filter` and `--workspaces` through the owned workspace runner before ordinary entrypoint lookup. The parsed context reaches package selection, per-package cwd/PATH, dependency and lifecycle ordering, cycle handling, package-manager rewrites, script argument escaping and exit-code propagation. Native CLI dispatch does not delegate to an installed Bun; scripts retain their own executable selection.

The runner drains already-written nonblocking stdout/stderr when process exit arrives before pipe readiness, preserving fast commands and unterminated final output before completion. Display selection honors the typed color controls before VM initialization, including forced color on POSIX pipes. Malformed-workspace warnings identify the package.json path. Signal state is atomic; SIGINT also wakes the existing event loop, whose kqueue wait otherwise retries EINTR without checking the abort flag. The handler preserves errno, and the runner forwards interruption to active scripts.

Empty arguments are explicitly quoted, as in Home's ordinary package-script path. The local Bun release control drops this argument and also hangs on the new parent-only SIGINT diagnostic; these are intentional correctness improvements beyond those pinned edge cases. No upstream assertion was changed. Expected unsafe-node-shim directory and target rejections now produce concise CLI diagnostics rather than native Zig source traces; their permission/ownership/target checks remain intact. The earlier isolated directory rejection took 28.33 seconds in DWARF symbolization and exceeded the existing native regression's 15-second command deadline.

The complete unchanged workspace suites pass **58 tests / 0 failures / 192 assertions**: `cli/run/workspaces.test.ts` is 3/3 and `cli/run/filter-workspace.test.ts` is 55/55. The published parent fails all three workspace tests and times out in the full filter file. The final unchanged `cli/install/bun-run.test.ts` run is **288 pass / 3 fail / 413 assertions**, versus an immediate published-parent rerun of **287 pass / 4 fail / 411 assertions**. The comparison resolves workspace argument preservation with no new failing test names. The remaining three cases require native bunx dispatch ([#518](https://github.com/home-lang/home/issues/518)); optional config scanning remains separate in [#517](https://github.com/home-lang/home/issues/517).

The expanded native package regression passes normally and with VM destruction plus JSC exception checks. It verifies native child identity, implicit/explicit filter forms, per-package cwd, shell-sensitive and empty arguments, missing selections/scripts, `--if-present`, repeated fast unterminated output, forced/plain display behavior and parent-only SIGINT with the child's natural exit. All three measured upstream source files are byte-identical to pin `4982b91e3702094330f3be3883354c52b8c01323`. Earlier full CLI runs had four additional SIGILL timeouts on both candidate and parent; those failed attempts remain recorded, and neither final rerun has those timeouts.

Final verification: native build **17/17 steps**, runtime units **1,819 pass / 19 skip / 0 fail** with **19/19 build steps**, and **55/55 runtime regression commands**, including all **24 native files**, complete spawn (**126 pass / 5 skips / 5,484 assertions**) and complete child-process (**32 pass / 1 skip / 1 TODO / 72 assertions**). All **31 upstream source files exercised by this regression set** match the pinned Git objects byte-for-byte. Skips and TODOs are excluded from completed parity. Scoped Pickier, changed CLI-file Zig formatting and whitespace checks pass. Verification used the shared Darwin checkout; unrelated compiler changes are excluded. Linux/Windows execution and branch integration remain unverified, #519 stays open for those boundaries, and the full port under [#66](https://github.com/home-lang/home/issues/66) remains incomplete.

Evidence: `zig-out/filter-build9.{log,json}`, `filter-build9-binary.json`, `filter-unit.{log,json}`, `filter-regressions.json`, `filter-native-{final9,destruction}.json`, `filter-corpus-final9.json`, `package-wide-filter-{parent-final9,final9}.json`, `filter-comparison-final9.json`, and `filter-source-integrity-final9.json`. Earlier build failures, invalid/empty artifacts, cancellations, disk exhaustion and diagnostic failures remain in the preceding `filter-build*`, `filter-native-*`, `filter-only-diagnostic.json` and `filter-noempty-diagnostic.json` records; none are counted as passing runs.

## Native bunx and package installation (#518)

Strict native `x`/`exec`, bunx/homex aliases, and `add`/`i`/`install` now use Home-owned CLI, dependency resolution and installation code. Copied bunx executables re-enter native `add` for missing packages instead of recursively executing bunx. Leading `--bun x` dispatch preserves script argument boundaries. Package runs share CLI initialization for logging, timing and main-thread state. The non-native Pantry/Bun compatibility paths are unchanged and are not used as evidence here.

The installer now reaches real registry manifests, tarball extraction, dependency traversal, bin linking, cache execution and lifecycle scripts. The legacy Wyhash11 implementation is restored where the pin requires it; the retained lockfile hash assertion exposed the wrong hash for an unnamed root package and was not removed. Installer I/O, patch subprocesses, YAML strings and bin-name iteration use current owned APIs. `add --analyze` and `install --analyze` use the actual parser/linker/import traversal without entering unrelated application-artifact generation. Native application builds are not implied complete.

Pinned Rust security checks are retained: unsafe writable/symlinked cache roots are rejected, bin selections are validated, and saved registry tokens cannot follow an environment override to another host or an HTTPS downgrade. Synthetic-credential tests verify both denial and same-origin retention without exposing the user's saved token. Runtime auto-install also starts the real HTTP thread; its former facade was a no-op and caused Angular's local-CLI probe to busy-wait until the original 300,000 ms test deadline. The unchanged Angular case now completes with automatic installation enabled.

At source pin `4982b91e3702094330f3be3883354c52b8c01323`, the entire unchanged `bun-run.test.ts` passes **291 tests / 0 failures / 416 assertions**, resolving the three remaining `npx`, `pnpm dlx` and `pnpx` cases from the published **288/3** parent. The entire unchanged bunx file passes **33 tests / 1 Windows-only skip / 0 failures / 161 assertions** on Darwin with an isolated PATH containing hard links named `node` and `bun` to the exact Home candidate plus system utilities. No installed Node/Bun runtime handles those JavaScript children. The candidate SHA-256 is `b57fad4dfb9c8cf03a79da23f782e3bf18c3d1d7539df9036b8b1fd73b90b852`.

Execution conditions matter: the ordinary PATH run is **32 pass / 1 skip / 1 fail / 159 assertions**, because an installed `claude` command prevents the alias test from contacting its mock registry. The pinned Bun release reproduces that failure and passes the isolated alias control. An initial Home-only symlink PATH run instead fails one older cowsay/yargs help assertion because the real executable basename is `home-debug`; hard links preserve the actual `node`/`bun` invocation basename without altering runtime values or package source. These failed runs remain recorded, not relabeled as passes. The Windows skip is not completed parity.

The native local-registry fixture passes normally and with VM destruction/JSC exception checks. It covers exact child identity, argument bytes, real dependent-package installation, cached/no-install execution, copied aliases, cache-root safety, both analyzer commands, erased type-only/builtin imports, registry credential boundaries, and successful/missing runtime auto-install. The unchanged upstream analyzer test passes **1 test / 18 assertions**. The complete workspace suites retain **58/58 tests / 192 assertions**.

Final verification: native build **17/17 steps**, runtime units **1,820 pass / 19 skips / 0 failures** with **19/19 build steps**, and **56/56 runtime regression commands**, including all **25 native files**, full spawn (**126 pass / 5 skips / 5,484 assertions**) and full child-process (**32 pass / 1 skip / 1 TODO / 72 assertions**). Skips and TODOs remain outside completed parity.

All **33 measured upstream source files** match the pin byte-for-byte. The unchanged bunx suite regenerates its tracked multi-tool tarball; generated bytes were archived, normalized file contents verified equal, and the pinned fixture restored. No upstream assertion, workload or deadline was changed. Scoped Pickier, changed Zig-file formatting and whitespace checks pass. Verification uses the shared Darwin checkout; unrelated compiler edits are excluded. Linux/Windows execution, branch integration, other installer features and full source ownership remain unverified. #518, #508 and #66 remain open; optional config scanning is separate in #517. The complete Bun port is not finished.

Evidence: `zig-out/bunx-build21.{log,json}`, `bunx-build21-{binary,source-snapshot}.json`, `bunx-native-{candidate21,destruction}.json`, `bunx-corpus-{candidate21-full,candidate21-isolated-full,candidate21-native-hardlinks}.json`, `bunx-corpus-release-control-{alias20,isolated-alias21}.json`, `bunx-node-alias21.json`, `bunx-upstream-analyze21.json`, `package-wide-bunx-candidate21.json`, `bunx-bun-run-comparison21.json`, `filter-corpus-bunx21.json`, `bunx-unit21.{log,json}`, `bunx-regression21s.json`, `bunx-source-integrity21.json`, and `bunx-generated-fixture-audit21.json`. Earlier build failures, disk exhaustion, the retained hash panic and the five-minute Angular timeout are preserved in the preceding bunx records; none count as successful verification.

## Native optional-config and argument boundaries (#517)

The outer native dispatcher now shares the parser's separate-token consumption rules: required and repeated flag values consume the next token; optional values do not. Bare `--config`/`-c` preserve the following entrypoint, while only attached `--config=PATH` selects another config. The pinned short optional form `-c=PATH` continues to use the default config. Implicit dispatch respects `--`, including filenames beginning with `-`; eval scanning stops there and at a selected entrypoint. A bare config flag parses its context and displays native CLI help. This changes dispatch, not the underlying clap implementation.

All **21 controlled argument-boundary cases** match the pinned Bun release on exit status, entry/argument selection and config diagnostic behavior. Help is compared as help behavior, not byte-identical formatting. The expanded existing native package regression verifies exact Home child identity, implicit/explicit runs, attached/separate/absent values, leading config before `run`/eval, `--`, and literal arguments after the entrypoint. It passes normally and with VM destruction/JSC exception checks; the published parent fails the new entry-selection assertion. An initial regression assertion incorrectly expected a debug diagnostic for explicit `run --`; it was corrected against the pinned control, with failed attempts retained. No upstream assertion was edited.

Complete unchanged suites retain **291/291 bun-run tests / 416 assertions**, **33 bunx passes / 1 Windows-only skip / 0 failures / 161 assertions** with the previously documented native hard-link PATH, and **58/58 workspace tests / 192 assertions**. The complete unchanged eval suite passes **33 tests / 0 failures / 70 assertions** in both Home and pinned Bun. Its declared React dependency was initially absent: Home installed React 18.3.1 into a task-owned directory, then an owned symlink fulfilled the manifest's local dependency path. The pre-existing empty corpus React directory and all upstream sources were left intact. Missing-dependency failures and the unsuitable earlier NODE_PATH control remain recorded.

The broader unchanged tsconfig-override file still fails **1 of 6 tests** in both published Home and this candidate (**5 passes / 14 assertions**); pinned Bun passes **6/6 / 17 assertions**. A registry auto-install 404 replaces the expected missing-module diagnostic. This pre-existing resolver gap is tracked in [#525](https://github.com/home-lang/home/issues/525), not counted as a config success. One transient candidate pass does not establish stable parity.

All **56/56 runtime regression commands** pass, including all **25 native files**, full spawn (**126 pass / 5 skips / 5,484 assertions**) and full child-process (**32 pass / 1 skip / 1 TODO / 72 assertions**). Skips and TODOs are not completed parity. Native build: **17/17 steps**. Runtime units: **1,820 pass / 19 skips / 0 failures**, **19/19 build steps**. All **35 measured upstream source files** are byte-identical to pin `4982b91e3702094330f3be3883354c52b8c01323`; the regenerated bunx tarball was archived, normalized contents checked, and pinned bytes restored. Scoped Pickier, Zig formatting and whitespace checks pass. Shared Darwin checkout only; unrelated compiler edits are excluded. Platform verification, exact help rendering, branch integration and full CLI/runtime/source parity remain open. #66 is incomplete.

Evidence: `zig-out/config-build{1,2}.{log,json}`, `config-build1-binary.json`, `config-build2-source-snapshot.json`, `config-boundary-{parent-control,candidate1}.json`, `config-native-{parent,candidate1-corrected,destruction}.json`, `config-unit1.{log,json}`, `config-regression1s.json`, `package-wide-config-candidate1.json`, `filter-corpus-config-candidate1.json`, `bunx-corpus-config-candidate1.json`, `config-wide-{parent,candidate1,release-control}-declared-deps.json`, `config-react-{install,link}.json`, `config-source-integrity1.json`, and `config-generated-fixture-audit1.json`.

## Native resolver diagnostics and fallible installer initialization (#525)

Runtime resolution now uses typed resolver metadata or the canonical missing-module formatter; a generic installer GET/404 log no longer replaces the public error message. Scoped and unscoped package failures preserve the different CommonJS and ESM error codes. The existing local-registry fixture verifies actual 404 requests, exact native child identity, require/require.resolve/import.meta.resolveSync errors, and empty stderr after caught failures.

The unreadable-cwd boundary required the real pinned initialization contract, not a VM-side reconstruction. The native readable-file fast path now runs before package cwd scanning, while custom loader cases retain full preflight. Runtime package-manager initialization validates directory-cache errors before singleton allocation, returns errors through the existing once wrapper, and retains failure for later calls. Resolver/transpiler accessors propagate the result and attach typed resolver metadata; the VM's generic cwd/log fallback is removed. Pending-task callbacks retain their successful-initialization invariant. The test-only lockfile binding also returns a JavaScript error on initialization failure.

The complete unchanged tsconfig-override file advances from the published parent's **5 pass / 1 fail / 14 assertions** to **6 pass / 0 fail / 17 assertions**. The complete unchanged resolver file advances from **38 pass / 1 fail / 1 error** to **39 pass / 2 skips / 1 TODO / 0 failures / 59 assertions**, matching the pinned Bun control; its spawned resolver file has **9 passes / 1 TODO / 41 assertions**. The original unreadable-cwd test now passes within its unchanged 5,000 ms deadline. Four additional implicit/explicit and absolute/relative entry controls match pinned Bun's caught directory error. The expanded native fixture repeats initialization failure three times in each scenario without contacting the registry.

The resolver suite's declared reflect-metadata 0.2.2 and tsyringe 4.8.0 dependencies were installed using Home into the same task-owned dependency directory used for eval verification, then linked through the corpus ancestor node_modules. Existing empty corpus dependency directories and upstream sources were left intact. Initial missing-dependency failures, the original cwd startup timeout, the intermediate inactive-union panic and all diagnostic attempts are retained.

A separate local HTTP/1.0 registry that closes each 404 response still exposes a **pre-existing pending-task assertion**, tracked in [#526](https://github.com/home-lang/home/issues/526). Published Home and the final candidate print caught errors before aborting; pinned Bun exits successfully. The final transport matrix passes both connection-closing and keep-alive responses with Content-Length, isolating the failure to EOF-delimited bodies. The passing Bun.serve registry fixture is not evidence that this different transport case is fixed. The task-count assertion remains intact. The complete installer and full Bun suite are not passing.

The unchanged bun-run suite retains **291/291 tests / 416 assertions**, bunx retains **33 passes / 1 Windows-only skip / 0 failures / 161 assertions** with the documented Home hard-link PATH, workspaces retain **58/58 / 192 assertions**, and eval retains **33/33 / 70 assertions**. All 21 prior config-boundary controls still match pinned Bun. The expanded native registry fixture passes normally and with VM destruction/JSC exception checks. All **37 measured upstream sources** match the exact pin; regenerated bunx fixture contents were verified and pinned bytes restored. All **56/56 runtime regression commands** pass, including **25 native files**, full spawn (**126 passes / 5 skips / 5,484 assertions**) and full child-process (**32 passes / 1 skip / 1 TODO / 72 assertions**). Skips and TODOs are not completed parity. Native build **17/17 steps** and runtime units **1,820 pass / 19 skips / 0 failures**, **19/19 build steps**. Scoped Pickier and Zig formatting pass. Shared Darwin checkout only; unrelated compiler edits are excluded. Platform verification, branch integration and full source/runtime ownership remain unverified; #66 is incomplete.

Evidence: `zig-out/resolve-build3.{log,json}`, `resolve-build3-{binary,source-snapshot}.json`, `resolve-native-{parent-esm,candidate3,destruction}.json`, `resolve-wide-{parent-declared-deps,release-declared-deps,candidate3}.json`, `resolve-cwd-{release-control,candidate3}.json`, `resolve-fallible-init-pin.json`, `resolve-transport-matrix3.json`, `resolve-dependencies.json`, `package-wide-resolve-candidate3.json`, `bunx-corpus-resolve-candidate3.json`, `filter-corpus-resolve-candidate3.json`, `config-wide-resolve-candidate3.json`, `resolve-source-integrity3.json`, and `resolve-generated-fixture-audit3.json`.

## EOF completion and decompression boundaries (#526, #527, #528)

Buffered HTTP consumers now receive completion only at EOF for responses without Content-Length. Incremental decoding remains active; partial notifications require the caller's streaming signal. This prevents half-manifest parsing and duplicate installer task publication without changing pending-task assertions or counters. The expanded native registry fixture exercises actual fragmented 404s, cold package installation, exact Home child identity and a streaming handshake that withholds the tail until the first chunk has been consumed.

That successful-install probe also exposed a libarchive initialization ordering bug: setting format options clears the selected format, re-entering a format bidder that cannot resume on an incomplete first header. TarballStream now registers tar, applies options, then selects tar before opening. Streaming extraction remains enabled. This is a logical repair established from the linked external vendor source, not a claim that the pinned Rust implementation already contains this ordering fix. Temporary tracing was removed. The published parent fails the new native fixture with an incomplete JSON manifest; the first HTTP candidate then fails archive opening; the final candidate passes normally, with VM destruction/JSC exception checks, and in the full regression run. The original Python EOF-404 parent SIGABRT is separately preserved. All three final EOF/Content-Length/keep-alive transport controls exit successfully with empty stderr, six caught errors and exactly two unauthenticated registry requests.

The pinned HTTP decompression contract removes Home's arbitrary 1 GiB output cap and treats a compressed response with zero received body bytes as empty. A started but truncated stream still fails, including an empty final chunk. Buffered installer tarballs instead have the pin's explicit **2 GiB decompressed-output limit**. The zlib reader now clamps produced output to the remaining budget rather than rejecting spare allocation capacity, and the installer releases its reader on success and failure. Unit tests cover exact/small limits with both fresh and over-allocated buffers, empty compressed bodies across codecs, and truncated gzip EOF. The six consulted Rust source files match pin `4982b91e3702094330f3be3883354c52b8c01323`; external libarchive source provenance is recorded separately.

| Complete unchanged corpus file | Published parent | Final native Home | Pinned Bun control |
| --- | --- | --- | --- |
| fetch-gzip | 22 pass / 2 fail | 24 pass / 0 fail / 43 assertions | 24 pass / 0 fail / 43 assertions |
| streaming-extract | 5 pass / 1 fail | 6 pass / 0 fail / 180 assertions | 6 pass / 0 fail / 180 assertions |

The original 1,025 MiB HTTP response and 2.25 GiB installer payload were not reduced; deadlines and assertions are unchanged. Four further complete fetch files pass: streaming **110 passes / 5 TODOs**, chunked trailing **23/23**, connection headers **10/10**, and body-stream excess **4/4**. Streaming assertion counts vary with chunk boundaries; the final run has 436 and the control 446, with no failing assertions. The complete zlib file retains **378 passes / 2 skips / 434 assertions**, plus bounds **9/9** and reentrancy **3/3**.

Retained full CLI coverage: bun-run **291/291 / 416 assertions**, bunx **33 passes / 1 Windows-only skip / 161 assertions** using the documented native hard-link PATH, workspaces **58/58 / 192 assertions**, eval **33/33 / 70 assertions**, tsconfig **6/6 / 17 assertions**, and resolver **39 passes / 2 skips / 1 TODO / 59 assertions** plus its spawned **9 passes / 1 TODO / 41 assertions**. All **21 config controls** still match. Native build **17/17 steps**; runtime units **1,824 passes / 19 skips / 0 failures**, **19/19 steps**; runtime regression commands **56/56**, including **25 native files**, full spawn **126 passes / 5 skips / 5,484 assertions** and full child-process **32 passes / 1 skip / 1 TODO / 72 assertions**.

All **46 measured upstream test sources** match the exact pin. The generated bunx tarball was archived, normalized contents verified equal, and pinned bytes restored. Scoped Pickier, Zig formatting and whitespace checks pass. The final native executable SHA-256 is `bc89ff0feb858524d5456a2b17036dd6e498c30ca1e80d55a7324cf5490693a0`. Verification uses the shared Darwin checkout; unrelated compiler work is excluded. These fixes do not establish Linux/Windows behavior, branch integration, all installer paths, skipped/TODO functionality, or full source ownership. #526–#528 retain platform/integration verification; **the full port and 100% logical Bun-suite compatibility under #66 remain incomplete**.

Evidence: `zig-out/eof-build4.{log,json}`, `eof-build4-{binary,source-snapshot}.json`, `eof-unit4.{log,json}`, `eof-regression4s.json`, `eof-native-{parent,candidate1,candidate2-trace,candidate3,final4,destruction}.json`, `eof-fetch-{parent,candidate1,release-control,final4}.json`, `eof-extract-{parent,release-control,final4}.json`, `resolve-404-eof-{parent,candidate1}.json`, `resolve-404-eof-final4-{close-eof,close-length,keepalive-length}.json`, `eof-zlib-final4.json`, `package-wide-eof-final4.json`, `bunx-corpus-eof-final4.json`, `filter-corpus-eof-final4.json`, `config-wide-eof-final4.json`, `resolve-wide-eof-final4.json`, `config-boundary-eof-final4.json`, `eof-source-integrity4.json`, `eof-implementation-pin.json`, and `eof-generated-fixture-audit4.json`. Earlier failures remain recorded and are not counted as successful runs.

## Active-upload abort settlement and body-matrix audit (#529, #530)

`FetchTasklet.onBodyReceived` now treats failure as terminal for both upload and response. It materializes the shared cancellation reason, transfers the error to a buffered response body, and only then re-reads and cancels the upload sink, whose synchronous JavaScript callback may re-enter the tasklet. Error ownership and cleanup follow the exact pinned Rust implementation. The former early return after sink cancellation left `arrayBuffer()` and `text()` pending indefinitely.

The entire unchanged `fetch-abort-stream-body.test.ts` advances from **1 pass / 1 fail / 5 assertions** to **2 passes / 0 failures / 6 assertions**, matching pinned Bun. Its original 2,500 ms timeout sentinel and 50-cancellation workload are unchanged. The complete queued-abort case remains **1/1 / 3 assertions**. The new native regression checks **24 abort scenarios**: five buffered consumers plus a stream reader, default and exact custom reasons, repeated rounds, one cancellation callback, abort/GC/fetch reentry from that callback, recovery requests and natural process exit. The published parent fails its three-second settlement bound. The final candidate passes normally, with VM destruction/JSC exception checks, and in the complete native regression run.

Five complete unchanged body files pass in both Home and pinned Bun: body-clone **25/25 / 69 assertions**, async iterator **2/2 / 4**, mixin errors **2/2 / 6**, stream fast path **18/18 / 32**, and body **346 passes / 4 skips / 604 assertions**, including the original string-lifetime workloads. All five previously checked fetch files retain their passes, including gzip **24/24 / 43 assertions**. Native build **17/17 steps**, units **1,824 passes / 19 skips / 0 failures** (**19/19 steps**), and runtime regression commands **57/57**, including all **26 native files**. Full spawn remains **126 passes / 5 skips / 5,484 assertions**; full child-process **32 passes / 1 skip / 1 TODO / 72 assertions**.

The broader audit contradicts the tracker's historical HTTP/3 completion claim. The complete unchanged 9,086-case body-stream file is **4,883 pass / 4,203 fail / 2 between-test errors** in the published parent and **4,883 pass / 4,203 fail / 10 errors** in this candidate; both have **72,378 assertions** and identical emitted failing test-name counts. All failures are in the HTTP/3 matrix. Both runs contain original five-second case timeouts followed by HTTP3StreamReset errors; the additional candidate errors are retained, not dismissed or counted as passes. The pinned release passes **9,086/9,086 / 135,984 assertions**. Thus no passing full-file or whole-HTTP/3 regression claim is made.

The published parent's complete HTTP/3 client/adversarial files fail **6 pass / 46 fail / 11 assertions** and **5 pass / 22 fail / 5 assertions**; pinned Bun passes **52/52 / 241** and **27/27 / 163**. A four-way loopback control isolates the failing side before JavaScript dispatch: Home and Bun clients both fail against Home's HTTP/3-only server, whose handler is never reached; both clients receive the exact 200 response from Bun's HTTP/3-only server. Protocol selection is explicit; no TCP fallback is allowed. The Home server's native dispatch path is the next investigation in [#530](https://github.com/home-lang/home/issues/530). #66's checked HTTP/3/body-stream entries have been corrected to reflect this evidence. No speculative HTTP/3 code change is included here.

Response API snapshot testing has a separate layout boundary: the unchanged file fails only its hard-coded `test/js/...` path in the flattened Home corpus, in both runtimes. Running the original pinned file from the Bun repository root with the exact Home candidate passes **14/14 / 41 assertions**, without editing the snapshot. The native header/argument files also pass: headers **94/94**, headers-case **3/3**, undici headers **51/51**, fetch arguments **47/47**, and fetch headers **6/6**. The release control cannot load `bun:internal-for-testing` for the first header file, so no passing release comparison is claimed for it.

All **64 measured upstream test/fixture sources** match pin `4982b91e3702094330f3be3883354c52b8c01323`. No upstream assertion, workload or deadline was changed. Scoped Pickier, Zig formatting and whitespace checks pass. The candidate executable SHA-256 is `e9949c03f505cdc87fa513b956e3bae5d81c31b4fab0d8b56fdf3f3ba411dec1`. Verification uses the shared Darwin checkout; unrelated compiler changes are excluded. Platform and integration checks remain open in #529; HTTP/3 is explicitly failing in #530. Skips/TODOs, full source ownership and **100% logical Bun-suite compatibility remain incomplete**.

Evidence: `zig-out/body-build1.{log,json}`, `body-build1-{binary,source-snapshot}.json`, `body-abort-{parent1,release1,candidate1}.json`, `body-abort-pin1.json`, `body-native-{parent1,candidate1,destruction}.json`, `body-unit1.{log,json}`, `body-regression1s.json`, `body-corpus-{parent1,release1,candidate1}.json`, `body-matrix-comparison1.json`, `body-h3-{parent1,release1}.json`, `body-h3-cross1.json`, `body-api-{parent1,release1,candidate1}.json`, `body-response-original-checkout1.json`, `eof-fetch-body-candidate1.json`, and `body-source-integrity-final1.json`. Full stdout/stderr, unsuccessful controls and timed-out cases remain recorded.

## TLS ABI and multiplexed response progress (#530–#533)

The HTTP/3 server reset was a TLS options ABI mismatch. `BunSocketContextOptions` omitted the pinned C interface's `ssl_min_version` and `ssl_max_version` fields, shifting later values when passed by value. LLDB confirmed UDP reception, certificate lookup and ALPN selection, but no accepted connection or JavaScript request. At the C boundary, the old binary supplied `request_cert = 600` and `reject_unauthorized = 3`. The two fields are restored in ABI order and included in the context digest, matching the pinned Rust mirror. User-facing TLS version-option plumbing remains separate unfinished work in [#532](https://github.com/home-lang/home/issues/532).

HTTP/3 now refuses per-request TLS settings it cannot honor, including enforced `checkServerIdentity`, and excludes them from automatic Alt-Svc upgrade. This follows the pinned transport eligibility checks instead of silently dropping trust options. Multiplexed response delivery also publishes buffered progress before the reader's streaming signal reaches the HTTP thread; otherwise a duplex upload waiting for the first response chunk deadlocks. HTTP/1 buffered EOF completion still waits for EOF. The existing unit test now covers HTTP/1, HTTP/2 and HTTP/3 with and without the streaming signal, plus fixed Content-Length completion.

| Complete unchanged file | Earlier published Home control | Final native Home | Pinned Bun |
| --- | --- | --- | --- |
| body-stream | 4,883 pass / 4,203 fail / 10 errors | **9,086 pass / 0 fail / 135,984 assertions** | 9,086/9,086 / 135,984 |
| fetch-http3-client | 6 pass / 46 fail | **50 pass / 2 fail / 235 assertions** | 52/52 / 241 |
| fetch-http3-adversarial | 5 pass / 22 fail | **27/27 / 163 assertions** | 27/27 / 163 |
| fetch-http2-client | 7 pass / 53 fail | **58 pass / 2 fail / 2 errors / 185 assertions** | 60/60 / 197 |
| fetch-http2-adversarial | 2 pass / 13 fail | **13 pass / 2 fail / 29 assertions** | 15/15 / 33 |
| bun-serve-ssl | 12 pass / 4 fail | **16/16 / 32 assertions** | 16/16 / 32 |

The historical HTTP/3 client/adversarial controls use `90ced0ed6`; the body, HTTP/2 and TLS controls use `fb161314a`. The final body matrix is independently green in both the ABI-only candidate and the final rebuilt binary, without excluding HTTP/3, reducing payloads or extending original deadlines. Four-way Home/Bun loopback controls now all return the exact 200 response with explicit HTTP/3 selection and UDP-only servers. These cross-process diagnostic servers are deliberately stopped after the client check, not counted as natural-exit tests.

The new native regression checks HTTP/1 and HTTP/3 with default, optional and required client-certificate settings; server-certificate rejection; unsupported custom CA, client certificate, server-name and enforced identity callbacks; first-chunk-gated duplex upload; recovery requests; and natural exit. Its final version passes normally and with VM destruction/JSC exception checks. The published parent fails. An initial invalid protocol spelling and a later callback expectation with verification disabled were corrected in this new fixture; unsuccessful attempts remain recorded. No upstream tests were edited.

At this earlier checkpoint, remaining failures were explicit. [#531](https://github.com/home-lang/home/issues/531) tracks request compression: the full compression file remains **4 pass / 28 fail / 2 errors / 35 assertions** versus pinned Bun **32/32 / 78**, and compression is the only remaining HTTP/3 client failure. [#533](https://github.com/home-lang/home/issues/533) tracks HTTP/2 verification-host session isolation and invalid response-header names. [#532](https://github.com/home-lang/home/issues/532) tracks native TLS context/CA ownership and version options: the context file remains **3 pass / 4 fail / 25 assertions** versus Bun **7/7 / 28**; the cache file remains **4 pass / 5 fail / 9 assertions**, while the release control cannot import its debug-only internal binding. That unavailable control is not a pass. The argument-validation file remains **5/5 / 13 assertions**.

Native build **17/17 steps** and the isolated runtime-unit retry **1,824 passes / 19 skips / 0 failures**, **19/19 steps**, pass. An earlier unit run exhausted disk and could not write its result; its empty log/result failure is invalid evidence, not a successful build. Only obsolete objects in this task's cache were removed after verifying and preserving their executables. The initial regression run had a spawn timeout and the new fixture's incorrect callback expectation; the initial streaming-fetch run had four original five-second timeouts. These failed runs remain separate from subsequent verification. The complete sequential rerun passes **58/58 regression commands**, including all **27 native files**, full spawn **126 passes / 5 skips / 5,484 assertions** and full child-process **32 passes / 1 skip / 1 TODO / 72 assertions**. The complete five-file sequential fetch rerun also passes: gzip **24/24 / 43 assertions**, streaming **110 passes / 5 TODOs / 0 failures**, chunked trailing **23/23**, connection headers **10/10**, and body-stream excess **4/4**. The original 1,025 MiB gzip workload and all case deadlines are unchanged. Both abort files retain their passes.

All **72 measured upstream test/harness sources** and **six consulted implementation sources** match pin `4982b91e3702094330f3be3883354c52b8c01323`. Scoped Pickier, Zig formatting and whitespace checks pass. The final native executable SHA-256 is `039a30eee0d7ef2098b92898a1b9962cd3a1ebf5631a9fc037cd98df1e09202c`. Verification uses the shared Darwin checkout; unrelated compiler work is excluded. Other platforms, branch integration, skipped/TODO behavior and full source ownership remain unverified. #530 stays open for remaining HTTP/3 and platform work; **#66 and 100% logical Bun-suite compatibility remain incomplete**.

### Native HTTP/2 response validation and verification-host isolation

Follow-up [#533](https://github.com/home-lang/home/issues/533) ports two missing contracts from the same pinned Bun source. Idle HTTP/2 sessions now preserve their Host-override hash when transferred to the keep-alive pool; active and pending sessions already included that discriminator. Response names must be nonempty lowercase HTTP tokens, with connection-specific fields rejected. Validation still consumes the complete HPACK block before rejecting a stream, preserving the shared dynamic table for later requests.

The new native HTTP/2 fetch regression checks pending, active and idle session isolation, same-host reuse with case/port normalization, ten malformed header names, protocol resets, dynamic-table references created after a rejected field, and the decoder's separate empty-name compression error. It passes normally, with VM destruction/JSC exception checks, and in the full regression run. A control with only the executable-identity assertion and harness import adapted passes in pinned Bun; the published Home parent fails the idle-session isolation check. A runtime unit checks all 256 possible header-name bytes.

| Complete unchanged upstream file | Published parent | Native candidate | Pinned Bun |
| --- | --- | --- | --- |
| HTTP/2 adversarial | 13 pass / 2 fail / 29 assertions | 15 pass / 0 fail / 33 assertions | 15 pass / 0 fail / 33 assertions |
| HTTP/2 lifetime | Not rerun | 7 pass / 0 fail / 21 assertions | 7 pass / 0 fail / 21 assertions |
| HTTP/2 client | 58 pass / 2 fail / 2 errors (prior checkpoint) | 58 pass / 2 fail / 2 errors / 185 assertions | 60 pass / 0 fail / 197 assertions |
| HTTP/3 adversarial | 27 pass (prior checkpoint) | 27 pass / 0 fail / 163 assertions | 27 pass / 0 fail / 163 assertions |
| HTTP/3 client | 50 pass / 2 fail (prior checkpoint) | 50 pass / 2 fail / 235 assertions | 52 pass / 0 fail / 241 assertions |

Lifetime tests retain all seven scenarios and the original 200-request workloads. At this earlier checkpoint, remaining HTTP/2 and HTTP/3 client failures are request compression ([#531](https://github.com/home-lang/home/issues/531)); their original deadlines remain unchanged. Two newly exercised CONNECT-proxy files panic in both parent and candidate, while pinned Bun passes both. The shared `HTTPClient.onWritable` assertion and the still-unexercised SSLConfig race workload are tracked separately in [#535](https://github.com/home-lang/home/issues/535), linked to [#532](https://github.com/home-lang/home/issues/532).

The complete unchanged body-stream matrix also passes **9,086/9,086 / 135,984 assertions** (`h2-body-stream-final4.json`). Native build passes **17/17 steps**, runtime units **1,825 pass / 19 skip / 0 fail** (**19/19 steps**), and sequential runtime regressions **59/59**, including all **28 native files**, full spawn (**126 passes / 5 skips / 5,484 assertions**) and full child-process (**32 passes / 1 skip / 1 TODO / 72 assertions**). Skips and TODOs are not completed parity. An initial matrix runner failed during post-exit process-group cleanup; its logs are retained and the entire matrix was rerun successfully as a runner, with the actual test failures above preserved. Early native-fixture expectation errors are retained as failed attempts, not test passes.

Evidence: `zig-out/h2-build2-binary.json`, `h2-unit1.{json,log}`, `h2-regression1s.json`, `h2-matrix-{parent3,final3,release3}.json`, `h2-native-{final4,destruction4,control3}.json`, `h2-source-integrity.json` and `h2-source-snapshot.json`. **40 measured upstream test/harness/fixture sources** and **six consulted implementations** match the pin byte-for-byte. Scoped Pickier, Zig formatting and whitespace checks pass. Native executable SHA-256: `bb9767dfbc0b6a729b92b7693a288e79c28c6910c370c5c73a770ca472aacd97`. Verification remains Darwin-only, with pinned C/C++/JSC dependencies and no Rust archive. Other platforms, branch integration, full source ownership and **100% logical Bun-suite compatibility under #66 remain incomplete**.

### Native request compression and CONNECT envelope ownership

The native `fetch({ compress })` path is now ported from Bun `4982b91e3702094330f3be3883354c52b8c01323` ([#531](https://github.com/home-lang/home/issues/531)). It accepts boolean, encoding and object forms, validates encoding-specific levels, and supports gzip, zlib-wrapped deflate, Brotli and zstd. Buffered and file bodies are compressed on the HTTP thread; explicit Content-Encoding, empty/streaming bodies and signed S3 destinations opt out. This does not establish S3 subsystem parity. Small bodies use shared scratch and a cached libdeflate compressor; larger gzip/deflate bodies use streaming zlib with bounded input chunks and incremental output growth. Unsent shared bytes are copied before yielding; HTTP/2, HTTP/3 and TLS-tunnel writes retain owned compressed storage. Framing uses the compressed length, while redirects and retries retain the original input. File reads close both newly opened and duplicated descriptors after reading, while sendfile retains its transferred ownership; caller-owned descriptors remain open.

Two missing CONNECT contracts are repaired in the same send path ([#535](https://github.com/home-lang/home/issues/535)). Passing the fixed writer by reference preserves its byte count and removes the empty-request assertion. Detaching the accumulated CONNECT envelope before starting inner TLS prevents it from being reparsed as the upstream response. The detached allocation stays alive until the TLS BIO has copied its tail, and cleanup does not touch the client after a synchronous failure could free it.

| Complete unchanged file | Published parent `fd239c3ac` | Native candidate | Pinned Bun |
| --- | --- | --- | --- |
| fetch-compress | 4 pass / 28 fail / 2 errors / 35 assertions | 32 pass / 0 fail / 78 assertions | 32 pass / 0 fail / 78 assertions |
| HTTP/2 client | 58 pass / 2 fail / 2 errors / 185 assertions | 60 pass / 0 fail / 197 assertions | 60 pass / 0 fail / 197 assertions |
| HTTP/3 client | 50 pass / 2 fail / 235 assertions | 52 pass / 0 fail / 241 assertions | 52 pass / 0 fail / 241 assertions |
| split CONNECT envelope | 0 pass / 1 fail (child panic) | 1 pass / 0 fail / 2 assertions | 1 pass / 0 fail / 2 assertions |
| proxy SSLConfig race | 0 pass / 1 fail / 1 assertion (child exit 134) | 1 pass / 0 fail / 3 assertions | 1 pass / 0 fail / 3 assertions |

The complete HTTP/2 adversarial (**15/15 / 33 assertions**) and lifetime (**7/7 / 21**, original 200-request workloads) files also pass in parent, candidate and pinned Bun. The final HTTP/3 adversarial run initially failed (**21 pass / 6 fail / 3 errors / 150 assertions**), then passed three serial full-file replays (**27/27 / 163** each). A fresh published-parent replay also failed (**19 pass / 8 fail / 4 errors / 125**), and pinned Bun had both a passing replay and a failing one (**24 pass / 3 fail / 160**). Initial-upload stalls and stream resets remain unresolved in [#539](https://github.com/home-lang/home/issues/539); passing retries do not erase these failures or establish their cause. The race test now exercises its original five-second workload and probe-count checks; no assertion was removed. An intermediate candidate fixed the writer but still leaked the split CONNECT envelope; that failed result is retained in `compress-matrix-final3.json`.

The new native fixture covers every encoding across HTTP/1, HTTP/2 and HTTP/3; shared/spilled incompressible bodies, concurrent scratch reuse, valid/invalid levels, 307/308 replay, file/empty/stream/disabled cases, cancellation after headers with GC and recovery, split CONNECT uploads and certificate rejection. Repeated sliced `Bun.file(fd)` uploads check exact bytes, caller-descriptor retention and absence of duplicated-descriptor growth; the pre-fix candidate fails the leak guard. It passes normally, with VM destruction/JSC exception checks, and in the full regression run. The parent fails; a pinned Bun control with only executable-identity and harness-import adaptations passes. Runtime units verify codec round trips for shared/spilled buffers and preservation of the unsent cursor and original body.

Native build passes **17/17 steps**, runtime units **1,827 pass / 19 skip / 0 fail** (**19/19 steps**), and sequential runtime regressions **60/60**, including all **29 native files**, full spawn (**126 passes / 5 skips / 5,484 assertions**) and full child-process (**32 passes / 1 skip / 1 TODO / 72 assertions**). The full unchanged body-stream matrix passes **9,086/9,086 / 135,984 assertions**. All five EOF/fetch files pass, including gzip **24/24 / 43** with its original **1,025 MiB** payload and streaming **110 passes / 5 TODOs**; both abort files pass. Skips and TODOs are excluded from completed parity.

Evidence: `zig-out/compress-build5-binary.json`, `compress-unit3.{json,log}`, `compress-regression2s.json`, `compress-matrix-{parent4,final5,release4}.json`, `compress-native5.json`, `compress-native-parent4.json`, `compress-native-{destruction5,control5}.json`, `compress-fd-parent4.json`, `compress-body-stream-final5.json`, `eof-fetch-compress-final5.json`, `body-abort-compress-final5.json`, `compress-h3-replay.json`, `compress-integrity5.json` and `compress-source-snapshot5.json`. **48 measured upstream test/harness/fixture sources** and **11 consulted implementations** match the pin byte-for-byte. Failed builds and intermediate attempts are retained, including unit attempt 2 (`NoSpaceLeft`, **16/19 steps**, no unit execution) and the initial adversarial failure. Only obsolete task-owned objects were removed. Ten older executables were then losslessly archived with verified decompressed hashes to reclaim space; the current executable and required replay controls stayed available. Unit attempt 3 rebuilt successfully and ran all units. Native executable SHA-256: `e16d199f8d05563ff1cb24b21c9f04c6fb50e2d7009a897b4cd62ba7fff09be7`. Verification is Darwin-only, with pinned C/C++/JSC dependencies and no Rust archive. TLS context/CA/version work remains [#532](https://github.com/home-lang/home/issues/532). Platform verification, branch integration, full source ownership and **100% logical Bun-suite compatibility under #66 remain incomplete**.

Evidence: `zig-out/h3-build{1,2,3}.{log,json}`, `h3-build3-binary.json`, `h3-final-source-snapshot.json`, `h3-lldb{2,3,4}.*`, `h3-cross-final31.json`, `h3-corpus-{candidate1,final3}.json`, `body-h3-h3-candidate2.json`, `h3-related-{parent1,candidate2,release1,h3-final3}.json`, `h3-tls-{parent1,abi1,release1,h3-final3}.json`, `h3-native-{final-parent,final3,destruction4}.json`, `h3-unit3-invalid.json`, `h3-unit4.{log,json}`, `h3-regression{3,4}s.json`, `eof-fetch-{h3-final3,h3-sequential4}.json`, `body-abort-h3-final3.json`, and `h3-source-integrity-final.json`.

### Native TLS private contexts, certificate chains and version limits

The native context layer now implements the missing behavior tracked in [#532](https://github.com/home-lang/home/issues/532), using Bun pin `4982b91e3702094330f3be3883354c52b8c01323`. User-created contexts own distinct `SSL_CTX` handles and bypass both internal caches; `addCACert` mutates only that handle. Internal contexts retain their digest-based sharing. PKCS#12 parsing preserves binary DER and view offsets, coerces the passphrase before borrowing a potentially detachable buffer, copies the returned PEM values, and frees the C allocator's buffers. Three placeholder exports are replaced by checked native host functions.

Detailed peer certificates now link the peer chain and local trust-store issuers, including self-issued roots. The JS head remains rooted across allocations; server leaf references, shared stores, store contexts and issuer references are released on success and error paths, with a 16-hop issuer cap. Legacy X509 conversion uses the JSC exception boundary. Native client authorization checks the selected hostname and retains a hostname-mismatch error. Both ordinary and Duplex-server modes are excluded from client hostname verification. TLS min/max versions survive JS parsing, config cloning, equality/hashing and native context projection; a unit test verifies both version fields affect cache identity.

Complete unchanged-file comparison:

| TLS file | Published parent | Native candidate | Pinned Bun release |
| --- | --- | --- | --- |
| node-tls-context | 3 pass / 4 fail | 7 pass / 0 fail / 28 assertions | 7 pass / 0 fail / 28 assertions |
| ssl-ctx-cache | 4 pass / 5 fail | 9 pass / 0 fail / 16 assertions | Debug-only binding unavailable; not a passing control |
| node-tls-create-secure-context-args | 5 pass | 5 pass / 13 assertions | 5 pass / 13 assertions |
| node-tls-connect-hostname-verification | 4 pass / 1 fail | 5 pass / 0 fail | 5 pass / 0 fail |
| node-tls-cert | 10 pass / 18 fail / 3 TODO | 28 pass / 0 fail / 3 TODO / 70 assertions | 28 pass / 0 fail / 3 TODO / 70 assertions |

The unchanged no-cipher-match file also passes. The new native fixture exercises private-handle and actual CA isolation, trusted/untrusted and hostname checks, detailed/abbreviated/X509 representations, real TLS 1.2/1.3 negotiation and disjoint-version rejection, client certificates, PKCS#12 Buffer/offset-view parsing, malformed inputs, repeated conversion and GC. Native normal and VM-destruction/exception-check runs pass; the published parent fails at its missing context handle. A pinned Bun control changes only executable identity and fixture location and passes. An initial test incorrectly required a client error when the server rejected missing client credentials; pinned Bun demonstrated that TLS 1.3 can close without that error. The fixture now checks no server secureConnection and no application bytes; the failed attempt is retained.

Expanded coverage includes the full peer-certificate leak test with its original workloads and memory threshold, root immutability/concurrent initialization, internal helpers, context churn, upgrade and half-open handling. Eleven Node parallel programs pass their existing BoringSSL branches; the legacy-PFX program skips its OpenSSL-only body. These branches do not establish the skipped OpenSSL protocol/multi-key matrices. Two destructor-UAF cases retain their sanitizer guards and are not counted as passes. Pinned release cannot execute the debug-only internals/churn bindings.

Final source review caught an intermediate role check that excluded ordinary servers but treated Duplex servers as clients. It now uses the full server-role predicate. A new mutual-TLS regression over a generic Duplex asserts native authorization and the exact client certificate despite a deliberately different context hostname; the earlier Home candidate fails, pinned Bun and the corrected Home artifact pass. Initial probe/control attempts with incomplete error handling or a wait for remote closure are retained; the final case awaits both handshake events and explicitly closes its transports.

The larger TLS files remain incomplete: server **31 pass / 7 fail / 122 assertions** (parent **30/8/121**, Bun **38/0/147**) exposes SNI suspension/error and ALPN callback behavior in [#542](https://github.com/home-lang/home/issues/542). Connect **26 pass / 4 fail / 1 skip / 102 assertions** (parent **20/10/1 skip/100**, Bun **28/2/1 skip/106**) retains two local session/keylog failures in [#543](https://github.com/home-lang/home/issues/543). Final Home and pinned Bun each fail the two live bun.sh OCSP-field expectations; they are preserved as failures, not counted as successful compatibility. Parent additionally failed detailed certificate and TLS-version behavior repaired here.

Native build **17/17**; runtime units **1,828 pass / 19 skip / 0 fail**, **19/19 steps**; sequential regressions **61/61**, including **30 native files**. Full spawn **126 pass / 5 skip / 5,484 assertions**; full child-process **32 pass / 1 skip / 1 TODO / 72 assertions**. Complete compression **32/32**, HTTP/2 client **60/60**, HTTP/3 client **52/52**, HTTP/2 adversarial **15/15**, HTTP/2 lifetime **7/7**, and both CONNECT files pass. The initial HTTP/3 adversarial run is **24 pass / 3 fail / 160 assertions**, followed by three complete **27/27 / 163** serial replays. Full body-stream **9,086/9,086 / 135,984 assertions**, all five EOF/fetch files and both abort files pass with original workloads and deadlines. #539 remains open: the passing replays do not erase the final artifact’s initial failure or the earlier Home and pinned Bun failures.

Evidence: `zig-out/tls532-build5-binary.json`, `tls532-unit2.{json,log}`, `tls532-candidate5.json`, `tls532-expanded5.json`, `tls532-expanded-release1.json`, `tls532-broader-parent2.json`, `tls532-native-{parent1,control6,destruction5}.json`, `tls532-regression5s.json`, `tls532-final5-results.json`, `tls532-corpus-integrity1.json`, `tls532-implementation-integrity1.json` and `tls532-source-snapshot5.json`. All **249 measured TLS test/harness/fixture sources**, **48 HTTP/regression sources** and **13 consulted TLS implementations** match the pin. Earlier build failures, the incomplete disk-exhausted parent1 attempt and the incorrect initial control assertion remain recorded; parent2 is the complete replay. Only owned reproducible objects were removed; older executable controls were losslessly archived and decompressed hashes checked. Required control executables stayed available. Final executable SHA-256: `d9649de0fa31c3b0fa935b909cf09e028a088be76bc407e29d66a8927b889e9e`.

Verification used a shared Darwin checkout; unrelated compiler changes are excluded from this checkpoint. Pinned C/C++/JSC dependencies remain, with no Rust archive. #532 retains platform/integration scope; #542/#543, HTTP/3 reliability [#539](https://github.com/home-lang/home/issues/539), skipped/TODO behavior, full source ownership and **100% logical Bun-suite compatibility under #66 remain unfinished**.

## Native TLS session and keylog delivery (#543)

Native TLS sockets now retain serialized session and NSS keylog payloads until the
Zig/JavaScript dispatch boundary can safely deliver them. The uSockets layer owns
FIFO copies on the `SSL`, releases them with the connection, and flushes session
events before keylog and application data. The socket layer copies each payload
into the exact JavaScript `Buffer` visible to listeners. Callback dispatch checks
for socket destruction between events, so a `session` listener or a same-read data
listener may close the socket without a later use-after-free. The same handlers and
ordering apply to direct TCP TLS, upgraded Duplex TLS and the named-pipe wrapper
surface.

`net.ts` retains TLS 1.2 sessions until `secureConnect`, forwards client session and
keylog callbacks through both direct and upgraded socket tables, and propagates
server keylog events. The generated socket descriptor and its checked-in Zig
fallback now include both handlers. The former strong no-op exports are removed;
the real dispatch functions reject non-TLS, null and negative-length inputs before
entering JavaScript.

The unchanged `test/js/node/tls/node-tls-connect.test.ts` advances from the
published parent's **26 pass / 4 fail / 1 skip / 102 assertions** to **28 pass / 2
fail / 1 skip / 106 assertions**, exactly matching the pinned Bun release. The two
remaining failures inspect live `bun.sh` OCSP metadata and reproduce in pinned Bun;
they are not counted as repaired. The original Duplex session/keylog case and the
session-before-destructive-data-callback case both pass with their original
five-second deadlines.

The new native lifetime regression covers Buffer shapes, newline-terminated NSS
keylog format, server TLSSocket propagation, session-before-data ordering,
destruction inside a session callback, Duplex wrapper teardown and forced GC. It
passes **20/20 independent process repetitions**. The adjacent unchanged TLS files
are **47 pass / 2 skip / 7 fail / 424 assertions**; all seven failures remain the
SNI/ALPN callback work tracked in [#542](https://github.com/home-lang/home/issues/542).

Final verification: native build **17/17 steps**, runtime units **1,828 pass / 19
skips / 0 failures** with **19/19 build steps**, and **62/62 sequential runtime
regression commands**. Scoped Pickier, Zig formatting and whitespace checks pass.
The candidate executable SHA-256 is
`ad1800ecef37c99a21f912ed45e56653f994cfaddc340f2435f6b90b9451b757`.

The debug build currently links the pinned Bun release object
`build/release/obj/packages/bun-usockets/src/crypto/openssl.c.o`; that object already
contains the pending-event ABI used here. Home's checked-in `openssl.c` now carries
the corresponding logical source implementation and compiles cleanly with the
release object's exact compile-command flags and Home's headers, but this checkpoint
does not claim that Home rebuilt or owns the linked native dependency. Verification
used the shared Darwin checkout; Windows/Linux execution, branch integration,
[#542](https://github.com/home-lang/home/issues/542), skipped/TODO behavior, full
native source ownership and **100% logical Bun-suite compatibility under
[#66](https://github.com/home-lang/home/issues/66) remain unfinished**.

Evidence: `zig-out/tls543-unit-final.log`, `tls543-regressions.json`,
`tls543-repeat.json`, focused complete-file and adjacent TLS run records, and the
successful transformed release compile command for Home's `openssl.c`. The initial
unrelated `Bun.ArrayBufferSink` unit trap passed on direct replay and the complete
cached rerun; it is not counted as a successful run.

## Native TLS SNI suspension and ALPN selection (#542)

TLS listeners now carry protected `serverName` and `alpnCallback` handlers from
the JavaScript socket configuration into Home's Zig listener and accepted-socket
dispatch. A ClientHello invokes `SNICallback` for every connection, including a
name equal to the listener hostname. Synchronous callbacks may select a wrapped
or raw native `SecureContext`, return no context for static/default fallback, or
abort with the original error. Asynchronous callbacks park BoringSSL's
select-certificate state and resume it through a real generated `resumeSNI`
socket method; late and duplicate resolutions release their owned context and
become harmless no-ops.

The native selector saves and restores the loop's shared BIO routing state
around JavaScript. Socket destruction inside SNI or ALPN dispatch therefore
defers SSL teardown until the BoringSSL frame unwinds. Home's checked-in
uSockets source now contains the matching pending-certificate state, early
ClientHello server-name parser, static-tree fallback, context ownership rules,
deferred detach protocol and public resume ABI. It compiles with the pinned
release object's exact C compile flags and Home headers. The debug binary still
links the pinned Bun object; this is logical source parity, not a claim that the
dependency was rebuilt by Home.

Dynamic `ALPNCallback` receives the offered protocol list and SNI name, accepts
only a protocol the client offered, and reports throws or invalid selections as
`tlsClientError`. Because ALPN selection is an `SSL_CTX` property, Home also
reinstalls its selector whenever SNI hands the connection to a synchronous,
asynchronous, or `addContext` context. This closes a composition boundary not
covered by Bun's server file: SNI and ALPN now work together when the SNI
callback rotates certificates.

The complete unchanged `node-tls-server.test.ts` advances from **31 pass / 7
fail / 122 assertions** to **38 pass / 0 fail / 147 assertions**, exactly
matching pinned Bun. The seven-file TLS sweep is **120 pass / 1 skip / 3 TODO /
2 fail / 380 assertions**. Both failures inspect live `bun.sh` OCSP metadata and
reproduce in pinned Bun; they remain failures. The new native regression covers
sync and async selection, wrapped and raw contexts, same-host precedence,
non-Error rejection, ALPN selection/error propagation, combined SNI+ALPN,
callback destruction, late resolution, repeated connections and forced GC. It
passes **20/20 independent processes** and VM destruction/JSC exception checks.

Final verification: native build **17/17 steps**, scoped runtime units **1,828
pass / 19 skips / 0 failures** with **19/19 build steps**, and **63/63 sequential
runtime regression commands**, including every native regression, full spawn
and full child-process. Scoped Pickier still reports existing unused-variable
findings outside these callback changes in the vendored `net.ts`/`tls.ts`; no
passing lint claim is made. Whitespace checks and Zig formatting for authored
Zig sources pass. Candidate executable SHA-256:
`febb4ccec5d7b99ae893c2501f88ace9585f4e45a2743b28a9055049060e5a3d`.

Evidence: `zig-out/tls542-corpus-final.json`, `tls542-unit-final.log`,
`tls542-regressions.json`, `tls542-repeat.json`, the native destruction run,
and `tls542-c-source-compile.json` from the successful transformed release
compile command for Home's `openssl.c`. Verification is Darwin-only and still
uses pinned C/C++/JSC
dependencies without a Rust archive. Windows/Linux execution, branch
integration, skipped/TODO behavior, full source ownership and **100% logical
Bun-suite compatibility under [#66](https://github.com/home-lang/home/issues/66)
remain incomplete**.

## HTTP/3 verification isolation (#539)

The intermittent initial-upload failures tracked in #539 reproduce as a host
contention artifact, including in the pinned Bun release, rather than a Home
transport divergence. In a serialized alternating control, the complete
unchanged `fetch-http3-adversarial.test.ts` passed **12/12 Home processes** and
**12/12 pinned Bun processes**; every process reported **27 tests / 163
assertions** under the original five-second case deadlines.

Three deliberately concurrent waves launched eight copies of that same file at
once. Home passed **11/12** processes and pinned Bun passed **5/12**. Every
ordinary failure had the historical shape: the first 64 KiB cases expired at
five seconds, a pull-stream request reset immediately, then later sizes
recovered. One pinned Bun process extended the same sequence into the first 512
KiB request. An eight-process socket snapshot showed sixteen distinct UDP
ports, excluding accidental port sharing. The host simultaneously had an
unrelated release Zig compile consuming one CPU and about 4.4 GiB, plus other
active system work, on eleven logical CPUs.

This is the environment correction required by #539: heavyweight HTTP/3 corpus
files are verified serially and are not launched alongside other native corpus
processes or builds. The upstream deadlines, workloads, protocol selection and
assertions remain unchanged; no transport retry, sleep, skip or fallback was
added. A separate UDP-proxy diagnostic that dropped the first client datagram
confirmed normal retransmission in all four Home/Bun client-server directions.
Thirty further Home/Home first-datagram-loss processes passed; an earlier cold
diagnostic took 10.2 seconds and is retained rather than counted as a passing
five-second corpus result.

Evidence: `zig-out/h3-539-repro.json`, `h3-539-concurrent.json`,
`h3-539-sockets.json`, `h3-539-sockets.lsof`, `h3-539-loss.json`, and the
per-process stdout/stderr artifacts. The checked-in `quic.c`, `quic.h`,
`H3Client.zig`, and all seven `h3_client` modules match the pinned source. This
resolves the specific
intermittent original-file observation; Darwin-only platform/integration,
native dependency ownership and complete logical Bun-suite parity remain open
under #530 and #66.
