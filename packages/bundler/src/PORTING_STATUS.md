# Bun Bundler Port — Phase 4.5

This directory contains a verbatim copy of Bun's bundler Zig source
(`bun/src/bundler/*.zig`, MIT-licensed — see `LICENSE.bun.md`). The
copy is the starting point for §4.5.A of the TS-parity plan: porting
Bun's industrial-strength bundler to drive Home's `home-tsc bundle`
output.

The code as copied does **not** compile in this repo — every file
imports `bun` (Bun's stdlib aggregator), which doesn't exist here.
Each file is annotated with a header pointing back to its upstream
source. The plan below tracks adaptation status file-by-file.

> **Why a verbatim copy and not a submodule?** Per direction
> 2026-05-14: the Bun bundler is exceptionally fast, and we want to
> own the source so we can adapt it to Home's HIR/diagnostics surface
> without dragging in the entire Bun runtime (JavaScriptCore, the
> resolver, the HTTP stack, …). MIT attribution is preserved per file
> and via `LICENSE.bun.md`.

---

## Inventory (26 files, ~20 365 LOC)

LOC sorted ascending. `bun=N` is the count of `bun.X` references in
the file (a rough proxy for porting effort). `rel=N` and `ext=N` count
relative-path `@import("./...")` and `@import("../...")` calls
respectively.

| File | LOC | bun | rel | ext | Compile | Top 3 Externs Needed |
|---|---:|---:|---:|---:|---|---|
| IndexStringMap.zig | 25 | 2 | 0 | 0 | **clean** (Tier 0) | `bun.ast.Index` |
| PathToSourceIndexMap.zig | 46 | 8 | 0 | 0 | **clean** (Tier 0) | `bun.StringHashMapUnmanaged`, `bun.fs.Path`, `bun.ast.Index` |
| DeferredBatchTask.zig | 52 | 8 | 0 | 0 | blocked | `bun.BundleV2`, `bun.jsc.ConcurrentTask`, `bun.Environment` |
| Graph.zig | 140 | 13 | 2 | 2 | blocked | `bun.MultiArrayList`, `bun.collections.BabyList`, `bun.ast.BundledAst` |
| BundleThread.zig | 195 | 32 | 2 | 2 | blocked | `bun.JSC.*`, `bun.Async`, `bun.Mutex` |
| bundled_ast.zig | 235 | 12 | 0 | 0 | blocked | `bun.ast.*`, `bun.MultiArrayList`, `bun.BabyList` |
| ServerComponentParseTask.zig | 247 | 20 | 1 | 1 | blocked | `bun.bake`, `bun.js_parser`, `bun.logger` |
| HTMLImportManifest.zig | 276 | 29 | 1 | 0 | blocked | `bun.MutableString`, `bun.strings`, `bun.PathString` |
| HTMLScanner.zig | 308 | 9 | 0 | 3 | blocked | `bun.LOLHTML`, `bun.strings`, `bun.logger` |
| cache.zig | 334 | 25 | 1 | 1 | blocked | `bun.MutableString`, `bun.FD`, `bun.sys` |
| OutputFile.zig | 336 | 27 | 1 | 5 | blocked | `bun.SourceMap`, `bun.fs`, `bun.sys` |
| ThreadPool.zig | 364 | 33 | 2 | 1 | blocked | `bun.ThreadPool` (yes, distinct), `bun.Mutex`, `bun.Async` |
| entry_points.zig | 374 | 23 | 0 | 1 | blocked | `bun.fs`, `bun.resolver`, `bun.options` |
| AstBuilder.zig | 375 | 20 | 1 | 1 | blocked | `bun.ast.*`, `bun.js_parser`, `bun.logger` |
| analyze_transpiled_module.zig | 397 | 10 | 0 | 1 | blocked | `bun.ast.*`, `bun.js_parser`, `bun.strings` |
| linker.zig | 421 | 16 | 1 | 4 | blocked | `bun.resolver`, `bun.fs`, `bun.options` |
| defines.zig | 429 | 15 | 1 | 1 | blocked | `bun.ast.*`, `bun.json`, `bun.ComptimeStringMap` |
| barrel_imports.zig | 562 | 11 | 2 | 0 | blocked | `bun.ast.*`, `bun.collections.BabyList` |
| LinkerGraph.zig | 563 | 45 | 0 | 0 | blocked | `bun.ast.*`, `bun.MultiArrayList`, `bun.bit_set` |
| Chunk.zig | 853 | 44 | 3 | 0 | blocked | `bun.SourceMap`, `bun.ast.*`, `bun.css` |
| defines-table.zig | 931 | 3 | 1 | 0 | blocked | `bun.ComptimeStringMap`, `bun.ast` |
| transpiler.zig | 1461 | 57 | 4 | 15 | blocked | `bun.Transpiler`, `bun.options`, `bun.resolver` |
| ParseTask.zig | 1496 | 102 | 4 | 6 | blocked | `bun.js_parser`, `bun.ast.*`, `bun.logger` |
| options.zig | 2654 | 65 | 2 | 14 | blocked | `bun.options`, `bun.resolver`, `bun.fs` |
| LinkerContext.zig | 2782 | 100 | 29 | 7 | blocked | `bun.ast.*`, `bun.css`, `bun.SourceMap` |
| bundle_v2.zig | 4509 | 251 | 19 | 15 | blocked | the entire dependency surface |

Legend:
- **blocked**: doesn't compile yet because `@import("bun")` cannot be
  resolved.
- **partial**: compiles with stubs, missing functionality is
  TODO-marked.
- **clean**: compiles standalone in `packages/bundler/src/bun/`.

---

## External `bun.X` surface (top 30, by occurrence)

These are the symbols we need to either stub, adapt, or formally
re-export from a Home-side `bun_compat.zig` shim. The full list is
103 unique identifiers — these are the highest-leverage 30.

| Count | Symbol | Suggested mapping |
|---:|---|---|
| 124 | `bun.handleOom` | Wrap `error.OutOfMemory` → panic helper in `bun_compat.zig` |
| 84 | `bun.default_allocator` | Re-export `std.heap.smp_allocator` (or `c_allocator`) |
| 50 | `bun.assert` | Alias for `std.debug.assert` |
| 44 | `bun.bundle_v2` | Self-reference; resolve via `@import("./bundle_v2.zig")` |
| 43 | `bun.ast` | **Adapt** to Home's HIR (`packages/ts_program/src/hir`) |
| 38 | `bun.strings` | **Adapt** — most call-sites want `std.mem.eql/indexOf`; add a thin shim for the specialised SIMD scanners |
| 30 | `bun.jsc` | **Defer** — JavaScriptCore is off-scope; gate every reference behind a `comptime` flag (`enable_runtime_plugins=false`) |
| 29 | `bun.css` | **Adapt** — Home doesn't have a CSS parser yet; stub with `pub const StyleSheet = struct {};` and TODO marker |
| 28 | `bun.Output` | **Adapt** to `ts_diagnostics.Output` (scoped logger) |
| 27 | `bun.Environment` | Stub — provides `isDebug`, `isWindows`, `isMac` constants. Implement via `builtin.os.tag`/`builtin.mode` |
| 24 | `bun.fmt` | Stub — formatters; most call-sites are `fmt.fmtSliceHexLower` style helpers; port on demand |
| 21 | `bun.OOM` | Alias for `error{OutOfMemory}` |
| 19 | `bun.perf` | Stub — perf counters; safe to no-op initially |
| 19 | `bun.invalid_fd` | Stub — `pub const invalid_fd: FD = .{ .raw = -1 };` |
| 18 | `bun.path` | **Adapt** to Home's `ts_resolver.path` helpers |
| 16 | `bun.FD` | Stub — file-descriptor wrapper; map to `std.posix.fd_t` initially |
| 16 | `bun.bit_set` | **Reuse** — `std.bit_set` covers most of this |
| 15 | `bun.logger` | **Adapt** to `ts_diagnostics.Logger` |
| 15 | `bun.BabyList` | **Reuse** — port the small-vector `BabyList` verbatim; it's a perf-critical fixed-capacity array list |
| 13 | `bun.bake` | **Defer** — Bake is Bun's framework runtime; gate behind `enable_bake=false` |
| 12 | `bun.StringHashMap` | Alias for `std.StringHashMap` |
| 11 | `bun.SourceMap` | **Adapt** — Home has its own source-map emitter in `ts_emit/src/source_map.zig` |
| 11 | `bun.ImportRecord` | **Adapt** to Home's `hir.ImportRecord` |
| 11 | `bun.fs` | **Adapt** to Home's `ts_resolver.fs` |
| 11 | `bun.copy` | Likely `std.mem.copyForwards` or similar — confirm per-callsite |
| 11 | `bun.ComptimeStringMap` | **Reuse** — port verbatim; std has `std.StaticStringMap` which is close |
| 10 | `bun.http` | **Defer** — only used by HTML scanner for embedded server-side rendering |
| 9 | `bun.collections` | **Reuse** — port `BabyList`, `OrderedSet`, etc. into a small Home-side `bun_compat/collections.zig` |
| 9 | `bun.allocators` | **Reuse** — port `MimallocArena` (perf-critical) verbatim |
| 8 | `bun.PathString` | Stub — short-string interner for paths; replace with `[]const u8` initially |

---

## Build order (lowest dep depth first)

### Tier 0 — pure data structures (port now)
These need only Zig stdlib + a tiny `bun_compat` shim for
`OOM`/`handleOom`/`default_allocator`/`StringHashMapUnmanaged`/`ast.Index`:

1. `IndexStringMap.zig` (25 LOC) — `bun.ast.Index` only
2. `PathToSourceIndexMap.zig` (46 LOC) — `bun.fs.Path`, `bun.ast.Index`
3. `DeferredBatchTask.zig` (52 LOC) — needs `bun.BundleV2` forward decl + jsc shim

### Tier 1 — bundler primitives (port after `bun_compat` exists)
4. `Graph.zig` (140 LOC) — multi-array, server components, `Logger.Source`
5. `bundled_ast.zig` (235 LOC) — wraps `bun.ast.BundledAst` for the cache
6. `BundleThread.zig` (195 LOC) — gate jsc behind `enable_runtime_plugins`
7. `OutputFile.zig` (336 LOC) — straightforward IO; depends on `bun.fs`/`bun.SourceMap`
8. `cache.zig` (334 LOC) — depends on `bun.MutableString`, `bun.FD`

### Tier 2 — pipeline scaffolding
9. `entry_points.zig` (374 LOC)
10. `ThreadPool.zig` (364 LOC) — Bun has its own, port carefully (perf-critical)
11. `linker.zig` (421 LOC) — small front-door module
12. `defines.zig` (429 LOC) + `defines-table.zig` (931 LOC) — `--define` machinery
13. `barrel_imports.zig` (562 LOC) — barrel-export inlining

### Tier 3 — HTML pipeline (gate behind `enable_html`)
14. `HTMLScanner.zig` (308 LOC) — needs `bun.LOLHTML` (Cloudflare's HTML parser; **defer**)
15. `HTMLImportManifest.zig` (276 LOC)

### Tier 4 — server components / RSC (defer to Phase 5)
16. `ServerComponentParseTask.zig` (247 LOC) — needs `bun.bake`
17. `analyze_transpiled_module.zig` (397 LOC)

### Tier 5 — the heavy core (port last)
18. `AstBuilder.zig` (375 LOC)
19. `LinkerGraph.zig` (563 LOC)
20. `Chunk.zig` (853 LOC)
21. `ParseTask.zig` (1 496 LOC)
22. `transpiler.zig` (1 461 LOC)
23. `options.zig` (2 654 LOC)
24. `LinkerContext.zig` (2 782 LOC)
25. `bundle_v2.zig` (4 509 LOC) — top-level orchestrator

---

## Perf-critical decisions to preserve

These are patterns the upstream maintainers chose specifically for
throughput. Any port must keep them.

1. **Threadlocal mimalloc arenas** (`bundle_v2.zig:10-49`,
   `bun.allocators.MimallocArena`). Each bundling thread gets its
   own arena; the arena is dropped wholesale at the end of the job.
   Massively reduces individual `free` calls and avoids the global
   allocator's contention. Must be ported verbatim — the existing
   `BabyList`/`MultiArrayList` allocations assume threadlocal arena
   semantics.
2. **`MultiArrayList`** for `Graph.input_files`, `Graph.ast`. Stores
   each struct field in its own contiguous slice — cache-friendly
   linear scans, identical to ECS pattern. Already in `std.MultiArrayList`.
3. **`BabyList`** — Bun's own `ArrayListUnmanaged(T)` variant with
   `cap` stored as `u32` (not `usize`) and the slice header inlined.
   Saves 8 bytes per list × tens of thousands of lists. **Port verbatim.**
4. **`bit_set` for live-code marks** (`LinkerGraph.zig`). Bun uses
   compact bitsets to track per-source per-symbol liveness during
   tree-shaking. Port via `std.bit_set` — same memory layout.
5. **Atomic decrement gate** (`Graph.pending_items` /
   `Graph.deferred_pending`) — bundler exits the scan phase the
   instant the counter hits zero, instead of polling the event loop.
6. **Path interning via `PathString`** — short paths fit inline (no
   allocation); long paths share a backing store. Significant win
   for `node_modules` traversal where most segments are short.
7. **`PathToSourceIndexMap` per build target** (`Graph.build_graphs:
   std.EnumArray(options.Target, PathToSourceIndexMap)`) — each
   target (browser/node/bun) gets its own resolution map; the
   `EnumArray` makes the lookup branchless.
8. **`UnboundedQueue`** for the parse work pool — lock-free MPMC; Bun's
   build artefact. Port carefully.
9. **`ComptimeStringMap`** for tag/keyword lookups — perfect-hash
   tables generated at compile time. `std.StaticStringMap` is the
   stdlib equivalent.
10. **Inline scoped logging** (`Output.scoped(.fs, .visible)`) —
    compile-time-gated debug streams; the visible/hidden flag
    decides whether the logger is no-op'd at compile time.

---

## Next steps (suggested order)

1. ~~**Land this copy** with build wiring that does **not** add the new
   files to any test step (so `zig build test` stays green).~~ ✅
2. ~~Create `packages/bundler/src/bun_compat/` with a single
   `bun.zig` aggregator that re-exports the Tier 0 surface
   (`OOM`, `handleOom`, `default_allocator`, `assert`, `ast.Index`,
   `StringHashMapUnmanaged`, `fs.Path`).~~ ✅ 2026-05-15
   (`packages/bundler/src/bun_compat/bun.zig`).
3. ~~Make `IndexStringMap.zig` + `PathToSourceIndexMap.zig` compile
   against the shim. Add a tiny test artifact.~~ ✅ 2026-05-15
   (`packages/bundler/src/bun_compat_tests.zig`, 9 tests, wired
   into `zig build test` under filter `ts_bundler_bun_compat`).
4. Iterate Tier 1 → Tier 5, expanding the shim as needed.
5. Once `bundle_v2.zig` compiles, swap the existing
   `ts_bundler.zig` v0 scaffold to delegate to it.
