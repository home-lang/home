# Bun compatibility shim (`packages/compat/`)

Detailed per-symbol status for the `bun` compatibility shim that
lets vendored Bun source compile against Home's stdlib without
modification. This is the drill-down view; the at-a-glance row is
in the
[README parity status](../README.md#bun-compatibility-shim-packagescompat)
section.

> **Why this exists:** the [Bun bundler](https://github.com/oven-sh/bun)
> is vendored verbatim into [`packages/bundler/src/`](../packages/bundler/src/)
> under MIT, and the [Bun runtime port](./PARITY-BUN.md) does the
> same for [`packages/runtime/src/`](../packages/runtime/src/).
> Both code bases pervasively write `@import("bun")` and reach for
> `bun.X` helpers. To compile that source without rewriting every
> file, Home ships a `bun` shim — `packages/compat/src/compat.zig` —
> that re-exports the minimal Bun surface against Home's stdlib.
> The build wires `@import("bun")` to this package
> (`build.zig:350`).

> **Goal:** every external `bun.X` identifier the vendored sources
> reference resolves through this shim, so the upstream files stay
> diff-clean and can be re-synced from Bun without merge conflicts.

## Surface size

| Measurement | Coverage | % |
|---|---|---|
| **Tier-0 symbols implemented** | **7 / ~103** | **~6.8%** |
| Upstream Bun surface (identifiers under `bun.*`) | ~103 | — |
| Tier breakdown (planned) | Tier 0 — minimal data types; Tier 1 — allocators + helpers; Tier 2 — logger / fs / strings; Tier 3 — JSC bridge stubs | — |

Each subsequent tier opens the door for more vendored Bun files to
compile. The 7 Tier-0 symbols below are what `IndexStringMap.zig`
and `PathToSourceIndexMap.zig` (the first two bundler vendors
brought online) require.

Legend:

- 🟢 **Implemented** — symbol exists with the right shape; vendored
  callers compile against it.
- 🟡 **Partial** — symbol exists but a subset of fields / methods
  upstream callers may eventually need is still stubbed.
- 🔴 **Not implemented** — referenced by some upstream file but not
  yet shimmed; that file currently won't compile.

## Tier 0 — the minimum 7 (landed today)

### `bun.OOM`

🟢 `error{OutOfMemory}` alias. Lets explicit error-return signatures
written as `bun.OOM!void` translate verbatim.

```zig
pub const OOM = error{OutOfMemory};
```

### `bun.handleOom`

🟢 Converts an `error.OutOfMemory` into a panic for call sites that
can't propagate it. Matches the upstream signature so vendored
files compile.

```zig
pub fn handleOom(err: anyerror) noreturn { … }
```

### `bun.default_allocator`

🟢 Process-wide allocator. Re-exports `std.heap.smp_allocator` —
the Zig stdlib's general-purpose multi-thread allocator.

```zig
pub const default_allocator: std.mem.Allocator = std.heap.smp_allocator;
```

### `bun.assert`

🟢 Alias for `std.debug.assert`. Bun uses `bun.assert(...)` instead
of `std.debug.assert(...)` so individual callers can be retargeted
to a richer in-house assert in the future.

```zig
pub const assert = std.debug.assert;
```

### `bun.ast.Index`

🟢 Strongly-typed source-file / module index. Upstream Bun stores
the raw integer separately as `Index.Int` so callers can pass the
unwrapped `u32` through hot-path collections without paying for
the struct wrapper. We mirror that split.

```zig
pub const ast = struct {
    pub const Index = struct {
        pub const Int = u32;
        value: Int,
        pub fn init(value: Int) Index { … }
    };
};
```

### `bun.StringHashMapUnmanaged`

🟢 Alias for the std-lib generic. Tier-0 collections (`IndexStringMap`,
`PathToSourceIndexMap`) use this as their underlying storage.

```zig
pub const StringHashMapUnmanaged = std.StringHashMapUnmanaged;
```

### `bun.fs.Path`

🟡 Path record. Tier-0 callers read only `.text`; subsequent tiers
will grow the struct (namespace, pretty path, interned id, …) as
they need.

```zig
pub const fs = struct {
    pub const Path = struct {
        text: []const u8,
    };
};
```

## Tier 1+ — not yet shimmed

Anything else in the upstream `bun.*` surface that vendored files
might reach for is 🔴 right now. As subsequent vendor files come
online — `Graph.zig`, `bundled_ast.zig`, `BundleThread.zig`, the
linker context, the rest of the runtime port — they'll either
discover missing symbols at compile time and we extend the shim, or
the file gets parked under `packages/runtime/PORTING_STATUS.md`
with a `blocked` marker.

Known categories the shim will likely need to grow into:

- 🔴 `bun.Output` — logger / stderr writer (used heavily in bundler diagnostics)
- 🔴 `bun.JSC.*` — JavaScriptCore bridge externs (parked until Phase 12.2 lands JSC)
- 🔴 `bun.strings` — string utility namespace (escape / unescape / convert)
- 🔴 `bun.path` — Bun's path module (distinct from `node:path`)
- 🔴 `bun.options` — bundler / runtime option records
- 🔴 `bun.resolver` — module resolution surface (separate from Home's `ts_resolver`)
- 🔴 `bun.MutableString` — Bun's interned mutable string type
- 🔴 `bun.bake` — full-stack bundling primitives
- 🔴 `bun.css` — CSS parser surface
- 🔴 `bun.transpiler` — Bun's JS/TS transpiler entrypoints
- 🔴 `bun.SourceMap` — Bun's source map writer

## Test coverage

Two test surfaces exercise the shim:

1. **In-line tests** in
   [`packages/compat/src/compat.zig`](../packages/compat/src/compat.zig)
   — 3 unit tests pinning the Tier-0 surface shape (the `OOM` /
   `assert` / `ast.Index.Int` / `fs.Path` / `default_allocator` /
   `StringHashMapUnmanaged` checks).

2. **Integration tests** in
   [`packages/bundler/src/compat_tests.zig`](../packages/bundler/src/compat_tests.zig)
   — 7 tests that build the actual vendored `IndexStringMap.zig`
   and `PathToSourceIndexMap.zig` files against the shim (round-
   trip `put` / `get`, `getOrPut`, `removePath`, `getPath` /
   `putPath` via `fs.Path`). This is the gate that proves the shim
   shape matches what real Bun code expects.

Run them with:

```sh
zig build test -Dfilter=compat
zig build test -Dfilter=bundler
```

Both are part of the regular `zig build test` umbrella; the
bundler test suite would not link without the shim.

## Build wiring

The shim is wired into the build at
[`build.zig:208`](../build.zig) (`compat_pkg`) and the
[`build.zig:349-350`](../build.zig) line installs it as the
`"bun"` import on the bundler's compat-test module:

```zig
const bundler_compat_pkg = createPackage(b, "packages/bundler/src/compat_tests.zig", ...);
bundler_compat_pkg.addImport("bun", compat_pkg);
```

When a new vendored Bun file lands in `packages/bundler/src/` or
`packages/runtime/src/`, the same `addImport("bun", compat_pkg)`
pattern wires it up so `@import("bun")` resolves to the shim.

## Summary

| Status | Count | % |
|---|---|---|
| 🟢 Implemented | 6 | ~5.8% (of ~103 total `bun.*` identifiers) |
| 🟡 Partial | 1 | ~1.0% (`fs.Path` — `.text` only) |
| 🔴 Not implemented | ~96 | ~93.2% |

**Tier-0 surface (7 symbols):** fully landed, regression-gated by
two test modules, exercises real vendored Bun code without
modification. Each subsequent tier follows the same pattern: a
vendor file lands, the shim grows just enough to make it compile,
inline + integration tests pin the surface, then the file becomes
buildable from `zig build`. See
[`packages/runtime/PORT_AUDIT_2026-05-18.md`](../packages/runtime/PORT_AUDIT_2026-05-18.md)
for the next-to-port queue.
