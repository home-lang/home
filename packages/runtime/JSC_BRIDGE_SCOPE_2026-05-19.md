# Phase 12.2 JSC Bridge Bring-Up: Technical Roadmap

**Status:** MacOS system-JSC bridge active for core eval/call/callback smoke tests
**Target completion:** End of Q2 2026  
**Unports enabled:** ~813 Bun files (anything that touches JSC)

---

## Executive Summary

**Recommended strategy: Real-first bindings (stub-layer-as-fallback)**

Phase 12.2 should land complete Zig↔JavaScriptCore C++ FFI bindings, enabling downstream phases (12.3–12.8) to unblock in parallel. Bun's 113 JSC Zig files define a ~30 extern-fn + ~37 opaque-struct surface; 82 files already ported to Home with jsc/. The remaining ~20 critical JSC-dependent files (BunObject, Archive, test_runner, AsyncModule, bun.js) require these bindings.

As of the current Home tree, the macOS `-Denable_jsc=true` path can create a JSC context, evaluate scripts, call JS functions/methods/constructors from Zig, and register Zig host functions that JavaScript can invoke through `JSObjectMakeFunctionWithCallback`. The full Bun test runner is still blocked on adapting Bun's runner objects and module loader, but the core host-call bridge is no longer panic-only.

A stub-first approach delays unblocking by requiring two sweeps; the real-first approach is faster and safer for test-suite validation (Settlers III gate).

**Estimated effort (real-first):** 120–180 agent-hours total  
- Bindings layer: 40–60 hours  
- JSC C++ wrappers: 30–40 hours  
- Integration tests: 30–50 hours  
- 3 parallel agents: 3 weeks  

**Gating risks:**
- JavaScriptCore framework availability on Linux (requires libwebkit-bundled or similar)
- Header compatibility between macOS 14+ and Linux builds
- C++ calling conventions and exception handling across Zig

**Unblocking forecast:**
- Sub-phase 12.2.1 (bindings): 30 files unblocked (Tier 0 JSC leaves)
- Sub-phase 12.2.2 (real layer): 550+ files unblocked (Tier 1–2)
- Sub-phase 12.2.3 (integration): 813 files unblocked (full JSC surface)
- Settlers III gate: Passable after 12.2.2 (stub remaining hooks are OK for non-JS tests)

---

## Stub Surface Inventory

Bun's JSC surface consists of:

| Symbol kind | Count | Real impl loc | Zig binding target | Port effort |
|---|---|---|---|---|
| **extern fn** (C API) | 30 | `javascript_core_c_api.zig` | `jsc/c_api.zig` | 8–12h |
| **opaque struct** (JSValue, JSGlobalObject, etc.) | ~20 | `JSValue.zig`, `JSGlobalObject.zig`, `JSCell.zig` | `jsc/core.zig` | 12–16h |
| **export fn** (Zig→C++ dispatch) | ~40 | scattered in `jsc/*.zig`, prefixed `JSC__` | `jsc/exports.zig` | 20–28h |
| **inline methods** (JSValue.cast, .toJS, .fromJS) | ~25 | `JSValue.zig` | `jsc/value.zig` | 15–20h |
| **enum** (JSType, JSTypedArrayType, etc.) | ~12 | `javascript_core_c_api.zig` | `jsc/types.zig` | 3–5h |
| **strong/weak reference** tracking | ~5 | `Strong.zig`, `Weak.zig` | `jsc/refs.zig` | 8–10h |
| **Promise/Async** wrappers | ~8 | `JSPromise.zig`, `AsyncModule.zig` | `jsc/async.zig` | 10–15h |

**Total bindings entries:** ~140 symbols  
**Current stubs (jsc_stub.zig):** 6 empty structs (non-functional)  
**Gap:** ~134 symbols to port

---

## C++ Headers & Linkage

| Header / Framework | Source | Version pin | Pantry status | Notes |
|---|---|---|---|---|
| `<JavaScriptCore/JavaScriptCore.h>` | Apple SDK (macOS) or libwebkit (Linux) | macOS 14.0+, webkit 2.44+ | NOT in Pantry; requires system install or custom build | On macOS: bundled in OS; on Linux: requires `libwebkit-dev` or bun's own fork |
| `c-headers-for-zig.h` | Bun repo | pinned at SHA | Must copy to Home | Includes platform #ifdefs (DARWIN, LINUX) |
| `jsc/bindings/*.h` (193 files) | Bun repo, handwritten glue | pinned at SHA | Must copy to Home | Core helpers: `Bindgen.h`, `BunGlobalScope.h`, `ErrorCode.h` |
| `WTF/` (WebKit Template Library) | WebKit source tree | bundled with JSC | System-dependent | Stable ABI; unlikely to shift |

**Critical linkage dependency:** Bun's C++ engine is not exposed as a library. We must either:
1. Copy JSC C++ sources into Home and build from scratch (120+ LOC, 48h+ build time) — **not viable**
2. Use system JavaScriptCore (macOS) + libwebkit (Linux) + handwritten stubs for missing pieces — **viable but risky**
3. Link against Bun's compiled engine (if packaged by Pantry) — **ideal but not yet available**

**Recommendation:** Land macOS support first (system JSC); defer Linux to follow-up when Pantry provides libwebkit or a bundled JSC build.

---

## Zig Binding Surface Estimate

From audit of Bun's 113 JSC `.zig` files:

- **extern fn** declarations: 30
- **pub const X = extern struct**: 20 (JSValue, JSGlobalObject, JSCell, etc.)
- **enum** types: 12
- **strong/weak reference** types: 8
- **C API wrapper methods** (inline on JSValue, etc.): 25+

**Total extern annotations to port:** ~95  
**Lines of Zig code (excluding tests):** ~35,000 (total JSC subsystem in Bun)  
**Home target (ported + new):** ~18,000 (sans 813 unported files)

Most heavy lifting is copy-paste and rewrite (`bun.*` → `home_rt.*`); the binding layer itself is ~1,500 LOC.

---

## Phase-12.2 Milestones

### M1: Binding Layer Foundation (Days 1–5, 20h)
**Goal:** Land macOS JavaScriptCore C API bindings in `src/jsc/c_api.zig`  
**Deliverables:**
- Port `javascript_core_c_api.zig` (30 extern fn + 12 enums)
- Port `JSValue.zig` core (opaque struct, inline methods, TrueI64/FalseI64 encoding)
- Verify `zig build --summary all` compiles (no .o files needed yet)

**Acceptance:** `jsc.JSValue` is a concrete type; can construct/compare but calls panic/"stub" on dispatch.

---

### M2: Opaque Type Layer (Days 6–10, 18h)
**Goal:** Define all JSC opaque types so files can refer to them without errors  
**Deliverables:**
- Port `JSGlobalObject.zig`, `JSCell.zig`, `JSObject.zig`, `JSString.zig`, `JSArray.zig` stubs
- Port `Strong.zig`, `Weak.zig` reference-counting wrappers
- Port enums: `JSType`, `JSTypedArrayType`, `JSRuntimeType`, `ErrorCode`
- Ensure circular import loops resolve (jsc.* ↔ home_rt.* aggregation)

**Acceptance:** 82 JSC files can compile without linker errors; all types are opaque/monomorphic.

---

### M3: Real C++ Wrapper Layer (Days 11–20, 35h)
**Goal:** Land C++ ↔ Zig dispatch glue; every JSC operation routes to real engine  
**Deliverables:**
- Copy & adapt 193 C header files from Bun (`jsc/bindings/*.h`)
- Define `pub extern "c"` Zig stubs for every `JSC__*` function (40+ exports)
- Implement inline method bodies on JSValue, JSGlobalObject (toJS, fromJS, etc.)
- Port AsyncModule, JSPromise, JSException dispatch
- Add ffi.zig dispatch for FFI function calls

**Build changes:**
- Link against system JavaScriptCore.framework (macOS) or libjavascriptcore.so (Linux stub)
- C++ compilation unit for Bun-specific glue (or reuse bun's compiled .o if available)

**Acceptance:** `home test basic-jsc-ops` passes (create a value, coerce, compare, store in array).

---

### M4: Integration & High-Level APIs (Days 21–28, 25h)
**Goal:** Port remaining heavy-JSC files; enable Settlers III non-JS tests to pass  
**Deliverables:**
- Port `bun.js.zig` (top-level module entry point, ~200 LOC after rewrite)
- Port `runtime/api/BunObject.zig` (2176 LOC, 226 jsc_refs → ~1800 after drops)
- Port test runner hooks and exception formatting
- Stub out event_loop, module_loader dispatch (they call JSC but don't block on it)

**Acceptance:** `home test settlers-iii --timeout=5s` runs; non-JS tests pass (file ops, crypto, no JS eval).

---

### M5: Validation Against Bun Test Corpus (Days 29–35, 20h)
**Goal:** Run subset of Bun's test suite; gate on zero regressions  
**Deliverables:**
- Copy `~/Code/bun/test/` → `packages/runtime/test/bun-corpus/` (~5,000 tests)
- Rewrite test imports (`Bun.*` → `Home.*`)
- Filter for non-JSC-dependent tests first (file I/O, encoding, shell, etc.)
- Run `home test bun-corpus --bail=0 --reporter=junit`

**Acceptance:** ≥80% of non-JSC tests pass; known gaps documented in `KNOWN_FAILURES.md`.

---

### M6: Settlers III Full Gate (Days 36–42, 15h)
**Goal:** Validate that real Bun-derived code passes the Home acceptance gate  
**Deliverables:**
- Run `home test packages/runtime/test/bun-corpus/ --summary all` (full suite)
- Run `home test ~/Code/Apps/settlers-iii` (real app)
- Fix regressions found
- Document JSC C++ availability gaps for Linux (if any)

**Acceptance:** Zero test failures; CI job `test-settlers-iii` stays green.

---

## Unblocking Forecast

| Sub-phase | Milestone | Files unblocked | Cumulative | Depends on |
|---|---|---|---|---|
| 12.2.0 | Start | 0 | 0 | — |
| 12.2.1 | M1 + M2 | ~30 (Tier 0 JSC leaves) | 30 | Zig 0.17 compat |
| 12.2.2 | M3 + M4 | ~520 (Tier 1–2) | 550 | macOS JSC or libwebkit |
| 12.2.3 | M5 + M6 | ~260 (Tier 3, integration) | 813 | Bun test corpus passing |
| 12.3 onward | Parallel unlock | — | — | Phase 12.2 landed |

**Time to unlock 550+ files (parallel agent target):** ~2 weeks (M1–M4 in sequence)  
**Time to full unlock:** ~4 weeks (including M5–M6 validation)

---

## Risks & Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| JavaScriptCore not available on Linux | High | Build against libwebkit-dev; vendor JSC if needed; defer Linux to Phase 12.2b |
| C++ exception handling mismatch | Medium | Test FFI dispatch with synthetic C++ exceptions; use `try`/`catch` in Zig wrappers |
| Header version skew (macOS 13 vs 14+) | Low | Pin to macOS 14.0 minimum; add version #ifdefs in c-headers-for-zig.h |
| 813 unported files still have unlinked imports | Medium | Mock event_loop, resolver in stub layer; allow imports to succeed, panic only on call |
| Bun test suite incompatibility with 0.17 | High | Scope: run known-compatible tests first; skip Zig-version-specific tests |

---

## Decision: Stub vs. Real

**Real-first is recommended** because:

1. **Unblocking velocity:** Bun's 813 JSC-dependent files cannot compile without actual bindings. Stub-layer-first delays unblock by 1–2 weeks (need two sweeps).
2. **Test-suite validation:** Settlers III gate requires real C++ dispatch to prove JSC integration. Stubs that panic on first JS operation don't meet the acceptance bar.
3. **Reduced rework:** Porting is atomic; switching stubs→real introduces churn and re-testing.
4. **Parallel agent readiness:** Once M1–M2 land, agents can claim files from Tiers 1–3 immediately; real layer follows in parallel (no dependency chain).

**Stub-layer fallback:** If macOS JSC becomes unavailable mid-phase, land stub layer (panic dispatcher) as a holding pattern; upstream changes unblock later.

---

## Appendix: Files Already Ported (Tier 0)

82 JSC files already in `packages/runtime/src/jsc/`:

**Samples (ported):**
- JSValue.zig, JSGlobalObject.zig, JSCell.zig
- JSString.zig, JSArray.zig, JSMap.zig
- Strong.zig, Weak.zig (ref counting)
- ZigException.zig, ErrorCode.zig, ZigStackTrace.zig
- Counters.zig, config.zig, WTF.zig

**Samples (not yet ported, blocked on M3):**
- BunObject.zig (2,176 LOC, 226 jsc_refs) — API entry point
- AsyncModule.zig (782 LOC, 52 jsc_refs) — async/await glue
- bun.js.zig (entry point, imports most of JSC subsystem)

---

**Next step:** Allocate 3 parallel agents to M1 (20h); gate their merge on "zig build" success and zero new test failures in `home test`.
