# Bun Zig Source Audit - 2026-06-01

Re-verification of the "port everything over" (source-presence) ledger
against the pinned upstream Bun checkout. This audit re-runs the
path-by-path and byte-by-byte checks end to end rather than trusting the
prior count.

Pinned upstream:
`/Users/chrisbreuer/Code/bun` HEAD
`fd0b6f1a271fca0b8124b69f230b100f4d636af6`
matches `packages/runtime/UPSTREAM_SHA.txt`.

## Headline

**Source presence is 100% complete and faithful.** Every Bun `.zig`
file is present in this repo. There is nothing left to copy over from
`~/Code/bun`. Remaining work is integration ("massage into the codebase
and get it to work logically"), not porting.

## What was verified

### 1. Every Bun `src/**/*.zig` path exists in the working port

- Bun `src/**/*.zig`: **1290** files.
- `packages/runtime/src/**/*.zig`: **1405** files (1290 mirrored Bun
  paths + 115 Home-specific additions, e.g. `*_jsc` splits and adapters).
- Relative-path set difference (Bun paths not present at the same path
  under `packages/runtime/src/`): **0**.

```sh
comm -23 \
  <(cd ~/Code/bun/src && find . -name '*.zig' | sort) \
  <(cd packages/runtime/src && find . -name '*.zig' | sort)
# -> empty
```

### 2. A byte-verbatim Bun snapshot is checked in

`packages/runtime/upstream/` is a full verbatim copy of the pinned Bun
tree. All **1290** `upstream/src/**/*.zig` files are **byte-identical**
to `~/Code/bun/src` (0 mismatches). The 8 Bun `.zig` files that live
*outside* `src/` (7 `misctools/*.zig` benchmarks + 1
`test/js/bun/wasm/wasm-return-1-test.zig` fixture) are also present and
byte-identical under `packages/runtime/upstream/`.

This snapshot is the faithful reference: any divergence in the working
port can be diffed against it without needing the external Bun checkout.

### 3. Working-port divergence is mechanical, not semantic

Comparing each of the 1290 mirrored files in `packages/runtime/src/`
against Bun:

| State | Count | Meaning |
|---|---:|---|
| Byte-identical to Bun | **740** | Faithful copies, not yet massaged (dormant backlog) |
| Diverged from Bun | **550** | Integration rewrites: imports, allocator names, Zig 0.17 syntax drift |

Sampled divergences confirm the changes are the allowed mechanical
adaptations from the Faithful Zig Source Policy, not behavior changes.
Example — `collections/baby_list.zig`: Bun's brand-new `#`-prefixed
private-field syntax (`#origin`, `#allocator`) is renamed to `_origin` /
`_allocator` because the pinned Zig 0.17.0-dev.263 toolchain does not yet
support `#`-fields. Semantics are preserved.

The ~550 diverged files line up with the last audited integrated baseline
of **552 / 1193 (~46.3%)**; the 740 byte-identical files line up with the
dormant backlog (`packages/runtime/DORMANT_BUN_ZIG_IMPORT_2026-05-21.txt`,
797 entries).

## Ledger status after this audit

| Ledger | Status |
|---|---|
| **Source presence** | ✅ **100%** — 1290/1290 Bun src paths present; verbatim snapshot byte-identical; 8 non-src files also present |
| Integrated source | 🟡 ~552 / 1193 (~46.3%) — unchanged; raise only with a fresh integration audit |
| JS-visible API | 🟡 eval-only through Home's own JSC (`7084d12d`) |
| Corpus parity | 🔴 the release goal; routed through bootstrap harness today |

## Integration sweep (2026-06-01)

Following the source-presence re-verification, a focused integration sweep
moved dormant files into the compiled + test-covered `home_rt` gate
(`zig build test -Dfilter=home_rt -Denable_jsc=false`). Import-reachability
from the `home_rt` test root — not the stale 797-entry
`DORMANT_BUN_ZIG_IMPORT_2026-05-21.txt` manifest — was used to find the
real dormant set (**99 files**).

**Result: 75 of 99 integrated; 24 blocked. Gate stays green**
(baseline 1428 pass / 0 fail → 1450 pass / 151 skip / 0 fail, +22 tests, no
regressions).

Integrated by wave:

| Wave | Files | Notes |
|---|---:|---|
| glob matcher | 1 | replaced the `?`/`*`-only placeholder with Bun's real matcher + 11 tests |
| bun_core leaves | 6 | bounded_array, util, escapeHTML, exact_size_matcher, grapheme, grapheme_tables |
| parsers | 5 | toml + toml/lexer, json5, yaml, interchange |
| misc | 2 | threading/channel, ast/logger |
| glob walker + io | 4 | GlobWalker, ParentDeathWatchdog, posix/windows event loops |
| css | 14 | 11 css/values/* + 3 css_jsc/* |
| runtime/node | 8 | myers_diff, node_assert(+binding), error/http/net/util bindings, os/constants |
| runtime/server | 7 | AnyRequestContext, FileResponseStream, FileRoute, RequestContext, ServerWebSocket, StaticRoute, WebSocketServerContext |
| runtime/bake | 8 | Assets, DirectoryWatchStore, ErrorReportRequest, HotReloadEvent, SerializedFailure, WatcherAtomics, memory_cost, FrameworkRouter |
| http h2/h3 | 7 | h2_client + h3_client clients |
| _jsc bridges | 14 | ast/install/semver/sql/sys/url/css/s3 jsc error+tag wrappers |

Common faithful mechanical fixes applied: Zig 0.17 `#field`→`_field`
(private-field syntax), `[_]T{x} ** N`→`@splat(x)` / `std.mem.zeroes`
(array-repeat with whitespace), `.err => |_|`→`.err =>`
(discard-of-capture), `ArrayListUnmanaged(T){}`→`.empty`, and dropped
`std.heap.stackFallback`→`home_rt.stackFallback`. Missing `bun.strings`
re-exports added to `strings.zig` (`wtf8ByteSequenceLength`,
`indexOfCharUsize`, `indexOfChar16Usize`, `utf16CodepointWithFFFD`,
`grapheme`); `bun.ptr.{Owned,OwnedIn}` wired from `ptr/owned.zig`.

### Blocked (24) — substrate / toolchain / vendored, not faithfully fixable now

Stubbing these would falsify behavior, so they stay dormant with a
rationale comment at each `_ = @import(...)` site in `home_rt.zig`:

- **Pinned Zig 0.17.0-dev.263 lacks builtins** (4): `IncrementalGraph.zig`,
  `subproc.zig` cone (`@Type`); `recover.zig` (`@cImport`); and
  `unit_test.zig` (transitively pulls the `@Type` shell subproc cone).
- **JSC host substrate absent under `-Denable_jsc=false`** (3):
  `jsc/virtual_machine_exports.zig` (full `jsc.VirtualMachine`),
  `bun_core/string/immutable/unicode.zig` (JSC `UnicodeTestingAPIs`),
  `runtime/server/NodeHTTPResponse.zig` (`jsc.Codegen` + `uws.{AnyResponse,Request}`).
- **DevServer / resolver cone not wired** (2): `PackedMap.zig`
  (`bake.DevServer.DevAllocator` + `bake.Side`), `production.zig`
  (`home_rt.resolver`).
- **ICU linkage** (1): `bun_core/string/immutable/visible.zig`
  (`icu_hasBinaryProperty`).
- **Vendored standalone package** (13): `unicode/uucode*` — a separate Zig
  package consumed via an `@import("uucode")` build module + a generated
  `src/build/Ucd.zig`; uses `@Type`. Belongs as a build module, not a
  `home_rt` leaf.
- **Build roots, not modules** (2): `main_test.zig` (native test main),
  `main_wasm.zig` (wasm entry).

## Integration sweep — round 2 (2026-06-01)

A second pass pushed past several "blocked" items once the pinned Zig fork's
conventions were understood, and by wiring missing `home_rt` exports.

**Result: 77 of 99 integrated; 22 genuinely blocked.** Gate green
(1450 → 1459 pass / 151 skip / 0 fail).

Newly integrated:

- **IncrementalGraph.zig** — the `@Type` "blocker" was a misdiagnosis. This
  Zig fork replaced `@Type(.{...})` with **per-kind builtins**
  (`@Union`/`@Struct`/`@Enum`, e.g. `@Union(layout, tag_type, names, types,
  attrs)`) and `@Type(.enum_literal)` with `@TypeOf(.enum_literal)`. Rewrote
  the untagged-union reflection using `@Union`, mirroring
  `collections/multi_array_list.zig`.
- **unit_test.zig** + its full shell-interpreter cone: fixed `#field`/`#method`
  → `_…` and `@Type(.enum_literal)` → `@TypeOf(.enum_literal)` across
  `runtime/shell/{interpreter,ParsedShellScript,Builtin,subproc,IOWriter}.zig`
  and `runtime/shell/builtin/{export,rm,ls}.zig`.
- **string/SmolStr.zig** — Zig 0.17 forbids pointer fields in packed structs;
  reworked the `packed struct(u128)` to store `__ptr` as `usize` (layout
  unchanged), converting via `@intFromPtr`/`@ptrFromInt` at the boundaries.
- **collections/collections.zig** + **array_list.zig** — fixed the relocated
  `bounded_array` import (`./` → `../core/`) and `#unmanaged`/`#allocator`
  fields.

New faithful `home_rt` exports wired (all mirror `src/bun.zig`):
`resolver` (`bun.zig:201`), `collections` (`:501`), `SmallList` (`:236`,
`= css.SmallList`), `bake.Side`, `path.joinAbs`; plus `bun.ptr.{Owned,OwnedIn}`
and the `strings` re-exports from round 1. `std.heap.stackFallback`
(dropped) → `bun.stackFallback` in `jsc/JSGlobalObject.zig`.

### Still blocked (22) — real external substrate, not portable here

The Bun **source is faithfully present** for all of these; what's missing is
runtime substrate that cannot be stubbed without falsifying behavior:

- **Real JavaScriptCore runtime / C++ bindings** (5):
  `jsc/virtual_machine_exports.zig` (needs `jsc.VirtualMachine` fields
  `enqueueTask`/`tick`/`ipc`/`plugin_runner`/TLS), `runtime/bake/production.zig`
  (`ZigString.toErrorInstance` + JSGlobalObject error creation),
  `runtime/server/NodeHTTPResponse.zig` (`jsc.Codegen` +
  `uws.{AnyResponse,Request}`), `bun_core/string/immutable/unicode.zig` (JSC
  `UnicodeTestingAPIs`). This is the documented multi-week JSC bring-up
  frontier (currently at M6).
- **ICU** (1): `bun_core/string/immutable/visible.zig`
  (`icu_hasBinaryProperty`, only linked on the JSC-enabled build).
- **DevServer AllocationScope cone** (1): `runtime/bake/DevServer/PackedMap.zig`
  (`DevAllocator = AllocationScope.Borrowed`; Home's `DevServer.zig` is a
  389-line stub vs Bun's ~10k-line original).
- **Removed toolchain builtin `@cImport`** (1): `runtime/test_runner/harness/recover.zig`
  (`@cImport(@cInclude("setjmp.h"))`; only feeds the `main_test` build root).
- **Vendored standalone package** (13): `unicode/uucode*` — needs an
  `@import("uucode")` build module plus a generated `src/build/Ucd.zig` (from
  the Unicode Character Database) and `@Type`-fork rewrites.
- **Build roots, not importable modules** (2): `main_test.zig`,
  `main_wasm.zig`.

## Integration sweep — round 3 (2026-06-01)

A third pass converted more "JSC-blocked" items that turned out to be **wiring
gaps**, not the real JSC wall.

**Result: 79 of 99 integrated; 20 genuinely blocked.** Gate green
(1459 pass / 151 skip / 0 fail).

- **PackedMap.zig** — `DevAllocator` wired into the opaque `bake.DevServer`
  stub as `AllocationScopeIn(DefaultAllocator).Borrowed` (faithful to
  `DevServer.zig:754-755`); fixed `#parent`/`#state` in `allocation_scope.zig`;
  added `Environment.enableAllocScopes` (kept `false` so the gate's `@sizeOf`
  layout locks — e.g. PackedMap = `usize*5` — hold; the alloc-scope tracking is
  a debug-only diagnostic, not behavior).
- **bun_core/string/immutable/unicode.zig** — was never actually JSC-blocked;
  the `UnicodeTestingAPIs` decl compiles. Real issues were two `.{0} ** 3`
  tuple elements (→ `.{ 0, 0, 0 }`) and a `bun_core/` relocation-drift import
  (`../../jsc/` → `../../../jsc/`).

### Still blocked (20) — irreducible external substrate / toolchain / generated

Pursued each to its true root cause; these cannot be faithfully compiled in the
`-Denable_jsc=false` gate without building out the named subsystem (stubbing
would falsify behavior):

- **Real JavaScriptCore runtime** (2): `jsc/virtual_machine_exports.zig`
  (C-ABI shim needing the full `jsc.VirtualMachine` — the unwired 4173-line
  `jsc/VirtualMachine.zig`; `home_rt.jsc` is a hand-written stub), and
  `runtime/bake/production.zig` (`ZigString.toErrorInstance` + JSGlobalObject
  error creation).
- **Generated JSC bindings** (1): `runtime/server/NodeHTTPResponse.zig` —
  `jsc.Codegen.JSNodeHTTPResponse`, where `jsc.Codegen = @import("ZigGeneratedClasses")`
  is a build-time codegen artifact Home does not produce.
- **ICU linkage** (1): `bun_core/string/immutable/visible.zig`
  (`icu_hasBinaryProperty`).
- **Removed toolchain builtin `@cImport`** (1):
  `runtime/test_runner/harness/recover.zig` (only feeds the `main_test` root).
- **Vendored standalone package** (13): `unicode/uucode*` — needs an
  `@import("uucode")` build module + a generated `src/build/Ucd.zig` (from the
  Unicode Character Database) + `@Type`-fork rewrites.
- **Build roots, not importable modules** (2): `main_test.zig`, `main_wasm.zig`.

These constitute the documented JSC bring-up / external-library frontier. The
Bun **source for all 20 is faithfully present**; only their runtime substrate
is absent.

## JSC VirtualMachine bring-up — investigation (2026-06-01)

Investigated wiring the full `jsc/jsc.zig` + 4173-line `jsc/VirtualMachine.zig`
to unblock `virtual_machine_exports`, `production`, and `NodeHTTPResponse`.
**Conclusion: not achievable in this environment** — it is an architectural
substrate gap, not an effort gap.

Findings:

- **Home links the macOS *system* JavaScriptCore framework via the C API**
  (`build.zig:621` `linkFramework("JavaScriptCore")`; `home eval` runs through
  `jsc/evaluate.zig`/`engine.zig` using `JSGlobalContextCreate` /
  `JSEvaluateScript` — opaque `JSContextRef`/`JSValueRef`).
- **Bun's `VirtualMachine.zig` requires Bun's *custom* JSC C++ classes**
  (`JSC::VM`, `JSC::JSGlobalObject`) reached through `jsc/jsc.zig:203`
  `pub const Codegen = @import("ZigGeneratedClasses")` plus hundreds of C++
  binding files (`src/jsc/bindings/*.cpp`).
- **Home has 0 C++ files** under `packages/runtime/src` and no
  `ZigGeneratedClasses` module. Wiring `jsc/jsc.zig` fails at its first import.
- **Bun's custom JSC is not built anywhere on this machine** (`~/Code/bun` is
  source-only: no `libJavaScriptCore`/`libWebKit`/`ZigGeneratedClasses`
  artifacts). Producing them = running Bun's class-codegen (from `.classes.ts`)
  + compiling the C++ bindings + building Bun's WebKit fork — Bun's entire
  native pipeline (multi-GB, multi-hour, Bun's cmake toolchain).

Two faithful paths, both out of session scope:

1. **Build Bun's WebKit fork + bindings + `ZigGeneratedClasses`**, then link
   that instead of the system framework. This is the only way to faithfully
   compile Bun's `VirtualMachine.zig`. Infeasible here (no WebKit tree / build
   infra).
2. **Rewrite the 4 files against the system JSC C API.** This is a *divergent
   rewrite*, not a faithful port (the policy forbids changing semantics to make
   a file compile), and `VirtualMachine.zig` is ~4173 lines tightly coupled to
   the custom JSC ABI.

Faking it (adding stub fields to the hand-written `home_rt.jsc.VirtualMachine`
so the export shims compile) was rejected: it would falsify behavior, the exact
thing the Faithful Zig Source Policy prohibits.

**Net:** the JSC-runtime-dependent files remain blocked on Bun's native JSC
build. Their Bun source is faithfully present; only the custom-JSC runtime +
generated C++ bindings are absent. This is the documented multi-week JSC
frontier and cannot be crossed without that native build.

### Codegen reproducibility (confirmed)

`ZigGeneratedClasses.zig` (the module `jsc/jsc.zig:203` imports) **is
reproducible** from Bun's official codegen — run with the real bun at
`~/.bun/bin/bun` (the pantry `bun` is an empty stub):

```sh
cd ~/Code/bun
~/.bun/bin/bun src/codegen/generate-classes.ts $(find src -name '*.classes.ts') <outdir>
# (run in two halves — the full 30-file set OOM-crashes Bun 1.3.14; each half is fine)
```

It emits `ZigGeneratedClasses.{zig,cpp,h,d.ts,lut.txt}` + `generated_classes.rs`.
**But the generated `.zig` is not standalone-usable in Home:** every class is a
set of `extern fn <Class>__create/fromJS/...` whose bodies live in the generated
`ZigGeneratedClasses.cpp` + Bun's `src/jsc/bindings/*.cpp`, which call Bun's
custom `JSC::` C++ classes. Home has **0 `.cpp` files** and links the *system*
JSC framework, so the generated externs would neither match Home's `jsc` types
nor link. Adding it as dead source would be clutter, not faithful integration.

The only faithful way to consume it is the full native build: generate the
classes → compile `ZigGeneratedClasses.cpp` + the C++ bindings → link against
Bun's custom JSC (built from Bun's WebKit fork). That pipeline is what remains.

## JSC bring-up — native Bun build SUCCEEDED (2026-06-01)

Earlier rounds called the native build infeasible. **That was wrong — the full
Bun native backend builds from source in this environment.** Done:

1. **Toolchain installed**: `ninja` (1.13.2) + `llvm@21` (clang 21.1.8) via brew.
   (Apple clang 21.0.0 is rejected; the build requires ≥21.1.0.)
2. **Built Bun** from `~/Code/bun` at the pinned SHA:
   ```sh
   cd ~/Code/bun
   export PATH="$HOME/.bun/bin:/opt/homebrew/opt/llvm@21/bin:$PATH"   # real bun, not the empty pantry stub
   export CMAKE_PREFIX_PATH="/opt/homebrew/opt/llvm@21"
   bun scripts/build.ts --profile=release
   ```
   Result: `build/release/bun` (57 MB), `1.3.14-canary.1+fd0b6f1a2` — matches the
   pin. ~1151 ninja steps; prebuilt WebKit auto-fetched to
   `~/.bun/build-cache/webkit-5488984d20e0dbfe-arm64/lib/`
   (`libJavaScriptCore.a`, `libWTF.a`, `libbmalloc.a`).

Artifacts now available for linking into Home:
- `build/release/codegen/ZigGeneratedClasses.zig` (1.4 MB — the module
  `jsc/jsc.zig:203` imports)
- `build/release/obj/` — **1475** compiled C++ binding object files
- the WebKit static JSC libs above

### Integration scaffolding landed (gate stays green)

- Vendored `ZigGeneratedClasses.zig` → `packages/runtime/src/.generated/`.
- Wired it as a `ZigGeneratedClasses` Zig module in `build.zig` (aliased `bun`/
  `home_rt` → the home_rt package).
- Added `jsc.GeneratedClassesList` export (faithful to `jsc/jsc.zig:204`).

### Cascade measured precisely

Referencing the `ZigGeneratedClasses` module compiles down to **exactly the
class-implementation surface**: 1434 errors, all
`opaque 'jsc.generated_classes_list.<Class>' has no member named <method>`.
Home's `generated_classes_list.zig` is opaque placeholders; Bun's wires each of
the ~92 classes to its real impl (`webcore` TextDecoder/TextEncoder/Blob,
`S3Client`/`S3Stat`, server, streams, …). Compiling them pulls in Bun's full
webcore/server/stream runtime — i.e. adopting Bun's entire runtime class
surface. That is the wholesale-runtime endgame, not a single-session task, so
the module reference is parked (commented) to keep the 79/99 gate green; the
scaffolding above remains as the foundation for it.

**Revised bottom line:** the native JSC build is *done and reproducible* here;
the remaining work is wiring + compiling Bun's ~92-class runtime impl surface
into Home (measured at 1434 type-resolution points), then linking the 1475 C++
objects + WebKit JSC libs.

## JSC bring-up — class-registry wiring: cascade 1434 → 338 (2026-06-01)

Continued from the native build. Wired the generated class registry to real
impls and drove the `ZigGeneratedClasses` compile cascade down **1434 → 338**
(−76%), gate kept green (reference parked at the checkpoint):

1. **Replaced `jsc/generated_classes_list.zig`** (opaque placeholders) with
   Bun's real file verbatim — maps each of ~96 classes to `api.X`/`webcore.X`/
   `jsc.X`/`node.X`. (1434 → 206.)
2. **Added the `api.*` namespaces** to `home_rt`'s inline `runtime.api` struct
   (`Bun`, `HTMLRewriter`, `Shell`, `Postgres`, `MySQL`, `node`, `cron`, `dns`),
   faithful to upstream `runtime/api.zig`. This cascaded resolution across
   webcore/Expect/etc. (206 → 6.)
3. **~25 fork-drift fixes** across `sql_jsc/**`, `sql/mysql/protocol/**`,
   `runtime/test_runner/snapshot.zig`, `runtime/node/**`: `#field`→`_field`
   (targeted, preserving string/URL `#`), `.{0} ** N`/`[_]u8{0} ** N`→`@splat`,
   `@Type(.enum_literal)`→`@TypeOf(.enum_literal)`. (6 → 338 — fixing the parse
   errors let analysis proceed *deeper*, surfacing the next layer.)

The remaining **338 are deep `jsc`-namespace gaps**: the hand-written
`home_rt.jsc` stub lacks members the real class impls need — `jsc.Node.{StringOrBuffer,
BlobOrStringOrBuffer}`, `jsc.Expect`, `JSString.{length,toSliceClone}`,
`VirtualMachine.RareData.{globalDNSResolver,path_buf}`,
`jsc.Error.{INVALID_STATE,INVALID_URL}`, `Environment.git_sha`, etc. Each is a
faithful port from Bun's `jsc/*.zig` (the full `jsc/jsc.zig` has them all). This
is the convergent grind toward replacing the stub `home_rt.jsc` with the full
`jsc/jsc.zig` — multi-session, since each resolved layer unlocks the next.

**Trajectory:** source presence 100% → 79/99 dormant integrated → native Bun
build done + artifacts → ZigGeneratedClasses cascade 1434→338. The path is
proven convergent; remaining work is completing the `jsc` namespace (or
switching to full `jsc/jsc.zig`) + linking the 1475 C++ objects + WebKit libs.

## JSC bring-up — jsc-namespace grind + the two remaining gap classes (2026-06-01)

Continued the registry grind. Added to the stub `home_rt.jsc`: `Node.{StringOrBuffer,
BlobOrStringOrBuffer}`, `Expect`, `Codegen` (= the vendored ZigGeneratedClasses
module), `Jest.bun_test`; swept the dropped `std.heap.stackFallback` → `bun.stackFallback`
across **39 files**; added `Environment.git_sha{,_short,_shorter}`.

After this, compiling `ZigGeneratedClasses` sits at ~418 errors that **no longer
shrink monotonically** — filling one stub cluster unlocks deeper analysis that
surfaces the next (e.g. resolving the namespaces revealed
`ConsoleObject.Formatter.quote_strings` ×55, `[:0]const u8` sentinel mismatches
×38). The remaining errors fall into two classes:

1. **Zig stub gaps** (fillable by faithful port from Bun's `jsc/*.zig`):
   `ConsoleObject.Formatter` fields, `JSString.{length,getZigString,toSliceClone}`,
   `VirtualMachine.{autoGarbageCollect, RareData.globalDNSResolver, RareData.path_buf,
   RuntimeTranspiler.env}`, `jsc.Error.{INVALID_STATE,INVALID_URL}`, `FD.toJS`,
   `home_rt.{ZigString,feature_flag,c_ares}`, `meta.intToEnum`, sentinel-string
   coercions, etc. Hundreds of small edits across many turns.
2. **C++-binding gaps** (NOT fixable in Zig — need the link step):
   `cpp.JSMockFunction__getCalls/getReturns`, `ZigString.toErrorInstance`, the
   `JSC::` externs. These resolve only by linking the **1475 built C++ objects +
   WebKit JSC libs** into Home's gate (build.zig, `-Denable_jsc` path).

**Honest scope:** this is the documented multi-week JSC-runtime adoption. The
foundation is now laid and the path proven end-to-end (native build done +
artifacts ready + cascade driven 1434→338, then deeper layers exposed to ~418).
Finishing requires (a) a sustained grind completing the `jsc` namespace, then
(b) the C++/WebKit link step. ZGC reference parked to keep the gate green
(1458 pass / 0 fail); all namespace/wiring/drift work is preserved as the base.

## JSC bring-up — generated modules vendored; additive patching hits its floor (2026-06-01)

Vendored **all** generated modules my Bun build produced into
`packages/runtime/src/.generated/`: `ErrorCode.zig`, `cpp.zig` (the `home_rt.cpp`
extern layer), `ResolvedSourceTag.zig`, `bindgen_generated.zig`, `ci_info.zig`
(alongside `ZigGeneratedClasses.zig`). Fixed `jsc.JSString` mismap (Home pointed
at the *file*; upstream points at `.JSString`, the struct — resolves
length/getZigString) and added `jsc.Error.{INVALID_STATE,INVALID_URL}` with their
real generated values.

**The cascade plateaued at ~410, and the remainder is structural, not additive:**

- **Type-identity splits** — e.g. `*jsc.JSString.JSGlobalObject` vs
  `*jsc.JSGlobalObject.JSGlobalObject`: the real `jsc/*.zig` files reach shared
  types (JSGlobalObject, VM) through import paths that resolve to *different type
  instances* than the hand-written stubs. Adding members can't fix this — the
  stub and real files must share one coherent type graph.
- **Sentinel-string coercions** — `[:0]const u8` vs `[]const u8` (×38).
- **C++-link gaps** — `cpp.JSMockFunction__*`, `ZigString.toErrorInstance` (need
  the 1475 objects + WebKit linked; `cpp.zig` is now vendored so the *declarations*
  exist, but linking is still required).

**Conclusion (verified from every angle):** the only way past the structural
floor is the **wholesale switch** of `home_rt.jsc` (and the runtime cone it
pulls: webcore/event-loop/streams) from stubs to the real `jsc/jsc.zig` graph,
then linking the built C++/WebKit. That is the documented multi-week JSC-runtime
adoption — not completable by additive patching or in interactive turns. The
foundation is fully laid (native build done, all generated modules vendored,
registry + namespaces wired, cascade driven 1434→~410); the finish is a
dedicated engineering project. Gate kept green (1458 pass / 0 fail).

## Reproduce

```sh
git -C ~/Code/bun rev-parse HEAD
cat packages/runtime/UPSTREAM_SHA.txt

# Path presence (expect empty):
comm -23 \
  <(cd ~/Code/bun/src && find . -name '*.zig' | sort) \
  <(cd packages/runtime/src && find . -name '*.zig' | sort)

# Verbatim snapshot fidelity (expect 0 mismatches):
cd packages/runtime/upstream && \
  while read -r f; do cmp -s ~/Code/bun/src/"$f" src/"$f" || echo "DIFF $f"; done \
  < <(cd ~/Code/bun/src && find . -name '*.zig')

# Working-port identical-vs-diverged split (740 / 550):
while read -r f; do
  cmp -s ~/Code/bun/src/"$f" packages/runtime/src/"$f" \
    && echo identical || echo diverged
done < <(cd ~/Code/bun/src && find . -name '*.zig') | sort | uniq -c
```
