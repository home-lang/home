# `home_rt` Test-Target Link Failure — Scope Report

**Date:** 2026-05-19
**Status:** Recommendation pending owner sign-off

## Symptoms

The top-level `zig build test --summary all` fails on the `home_rt`
test executable with unresolved native symbols:

- `_zlibVersion`, `_inflate*` (zlib)
- `_BrotliDecoder*` (brotli)
- `_ZSTD_*` (zstandard)
- `_mi_malloc`, `_mi_free` (mimalloc)

The failure does NOT affect filtered test runs
(`-Dfilter=ts_checker`, `-Dfilter=ts_conformance`,
`-Dfilter=phase12`), so daily TS-parity / runtime-port work is
unblocked. Only the top-level summary's `home_rt` step fails.

## Root Cause

`build.zig` ~line 936-938 creates the `home_rt` test artifact:

```zig
const home_rt_tests = b.addTest(.{ .root_module = home_rt_pkg });
const run_home_rt_tests = b.addRunArtifact(home_rt_tests);
dependOnTest(test_step, &run_home_rt_tests.step, test_filter, "home_rt");
```

The artifact **lacks** `link_libc = true` and `linkSystemLibrary(...)`
calls, even though the `home_rt` module pulls in wave-11 C-library
wrappers that declare `extern fn` symbols:

- `packages/runtime/src/mimalloc_sys/mimalloc.zig` — `mi_malloc`, `mi_free`
- `packages/runtime/src/brotli_sys/brotli_c.zig` — 13 BrotliDecoder/Encoder symbols
- `packages/runtime/src/zlib/zlib.zig` — `zlibVersion`, `inflate*`, `deflate*`
- `packages/runtime/src/zstd/zstd.zig` — `ZSTD_compress`, `ZSTD_createDStream`, etc.

The `_phase12_smoke.zig` + `home_rt.zig` test blocks reference these
via `_ = @import(...)`, which forces compilation but not linking. At
link time, the symbols are unresolved.

## Resolution Options (Ranked)

### Option A — Wire system libraries in `build.zig` (preferred)

Add after `home_rt_tests` creation:

```zig
home_rt_tests.root_module.link_libc = true;
home_rt_tests.linkSystemLibrary("z");        // zlib
home_rt_tests.linkSystemLibrary("brotlidec"); // brotli (or brotli)
home_rt_tests.linkSystemLibrary("brotlienc");
home_rt_tests.linkSystemLibrary("zstd");     // zstandard
// mimalloc: vendor or system-link based on Pantry config
```

- **Pros:** Mirrors the production-exe linkage (build.zig:507), centralizes config, respects build target.
- **Cons:** Assumes system libs are present (true on macOS via Pantry / on Linux via standard packages).
- **Effort:** ~2 agent-hours (verify on macOS + Linux, handle missing-lib fallback via Pantry).
- **Sign-off required:** No — pure build-config change, no semantic shift.

### Option B — Gate imports behind comptime flag

Add `-Denable_compression=false` (default `true`). Conditionally exclude
the compression wrapper imports in `home_rt.zig:1050-1285`.

- **Pros:** Keeps `home_rt` test binary pure-Zig when compression isn't needed.
- **Cons:** Two code paths to maintain; friction for devs who need compression.
- **Effort:** ~3 agent-hours.
- **Sign-off required:** Yes — adds a build flag + conditional code path.

### Option C — Revert wave-11 wrappers

Remove `mimalloc_sys/`, `brotli_sys/`, `zlib/`, `zstd/` from the `home_rt`
aggregator surface. Keep only in downstream consumers
(`http/Decompressor.zig`, etc.) that link independently.

- **Pros:** Unblocks `home_rt` tests immediately, single commit.
- **Cons:** Loses centralized FFI surface; cascading reverts in `http/zlib.zig`, `http/Decompressor.zig` and elsewhere.
- **Effort:** ~5 agent-hours total (revert + downstream fixes).
- **Sign-off required:** Yes — architecture review (removes centralized FFI surface).

## Recommendation

**Option A.** Smallest blast radius, no architecture change, mirrors
existing production-exe linkage. Pantry already provides the system
libraries on macOS, and they're standard on Linux. The fix is ~5 lines
in `build.zig` and unblocks the top-level test summary that's been
red since wave-11 landed.

Mimalloc is the only library that may require special handling — Bun
upstream vendors a custom `mimalloc-bun` build; we can either vendor
it under `pantry/` or use the system `libmimalloc` for now and revisit
in Phase 12.2.

## Next Step

Awaiting owner sign-off. Once approved, a focused agent can apply
Option A in a 15-line `build.zig` diff and verify
`zig build test --summary all` is fully green (no more `home_rt`
unresolved-symbol failures).
