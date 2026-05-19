//! `home_test` — Home's port of Bun's `bun:test` framework.
//!
//! Bun is shifting its runtime to Rust; we want to keep maintaining
//! the Zig portion. This package vendors Bun's `src/runtime/test_runner/`
//! tree (MIT, see `LICENSE.bun.md`) so Home can expose a Jest-compatible
//! testing API — `describe`, `test`, `it`, `expect`, lifecycle hooks,
//! snapshot testing, fake timers — under our own runtime module
//! (`home:test`) without dragging in the Bun runtime, JavaScriptCore,
//! or any of Bun's IO stack.
//!
//! ## Status
//!
//! This file is the *facade*. The vendored sources under
//! `src/bun/` do **not** compile yet: every file references
//! `@import("bun")` (Bun's stdlib aggregator), which doesn't exist
//! here. The adaptation plan lives in `src/PORTING_STATUS.md`.
//!
//! Once the `compat` shim work that the bundler also needs lands
//! (see `packages/bundler/src/bun/PORTING_STATUS.md`), individual
//! files in `src/bun/` will be re-exported from this facade and wired
//! into Home's runtime module loader.
//!
//! ## Public API (intended, post-activation)
//!
//! ```zig
//! const home_test = @import("home_test");
//! ```
//!
//! exposes the same set of functions Bun does today via `bun:test`:
//!
//!   - `describe(name, fn)` / `describe.skip` / `describe.only` / `describe.each`
//!   - `test(name, fn)` (alias `it`) / `test.skip` / `test.only` /
//!     `test.todo` / `test.failing` / `test.concurrent` / `test.serial` /
//!     `test.each` / `test.if` / `test.skipIf` / `test.todoIf`
//!   - `beforeAll(fn)` / `beforeEach(fn)` / `afterAll(fn)` / `afterEach(fn)`
//!   - `expect(value)` with the full ~70-matcher surface listed in
//!     `src/bun/expect/`
//!   - `expect.assertions(n)` / `expect.hasAssertions()` /
//!     `expect.unreachable()` / `expect.extend({ ... })` /
//!     `expect.addSnapshotSerializer(...)`
//!   - `expect.any(...)` / `expect.anything()` / `expect.arrayContaining(...)`
//!     / `expect.objectContaining(...)` / `expect.stringContaining(...)` /
//!     `expect.stringMatching(...)` / `expect.closeTo(n, digits)`
//!   - `mock(fn)` / `spyOn(obj, method)` / `mock.module(...)` /
//!     `jest.fn()` / `jest.spyOn(...)` / `jest.useFakeTimers()` /
//!     `jest.useRealTimers()` / `jest.advanceTimersByTime(...)` /
//!     `jest.runAllTimers()` / `jest.runOnlyPendingTimers()` /
//!     `jest.setSystemTime(...)` / `jest.now()` /
//!     `jest.setTimeout(...)` (per-test timeout)
//!   - `setSystemTime(...)` (Bun-specific helper) / `setDefaultTimeout(...)`
//!   - Snapshot APIs: `toMatchSnapshot()`, `toMatchInlineSnapshot()`,
//!     `toThrowErrorMatchingSnapshot()`, `toThrowErrorMatchingInlineSnapshot()`
//!
//! ## Adaptation TODO (port from `bun.X` to Home equivalents)
//!
//! - `bun.jsc.*` — JavaScriptCore bindings. Home's runtime is not yet
//!   wired up; gate every `jsc` reference behind a `comptime` flag and
//!   stub with a minimal `JSValue` placeholder until Home's interpreter
//!   exposes a `home_test_runtime` shim (target: Phase 6+).
//! - `bun.JSError` — JavaScript-side error union. Map onto Home's
//!   `Result(T, JsError)` from `ts_diagnostics`.
//! - `bun.Output` — stdout/stderr writer with Jest-style coloring.
//!   Replace with `ts_diagnostics.Output`.
//! - `bun.String` — Bun's tagged-pointer JSC-aware string. Use
//!   `[]const u8` + `string_interner` initially; the JSC-aware variant
//!   only matters once `jsc` is in play.
//! - `bun.handleOom` / `bun.OOM` — wrap `error.OutOfMemory` in a
//!   panic helper inside `compat.zig`.
//! - `bun.default_allocator` — re-export `std.heap.smp_allocator`.
//! - `bun.assert` / `bun.debugAssert` — `std.debug.assert` aliases.
//! - `bun.timespec` — wraps `std.posix.timespec`; port verbatim into
//!   `compat`.
//! - `bun.strings` — most call-sites want `std.mem.eql`/`indexOf`.
//! - `bun.fs` / `bun.sys` — file IO. Adapt to Home's stdlib + fs layer.
//! - `bun.SourceMap` — Home has its own emitter in
//!   `ts_emit/src/source_map.zig`.
//! - `bun.path` — adapt to `ts_resolver.path`.
//! - `bun.fmt` — Bun's pretty-formatter. Port on demand.
//! - `bun.PathBuffer` — short-string interner; `[]u8` for now.
//! - `bun.Environment.{isDebug,isWindows,isMac}` — derive from
//!   `builtin.os.tag` / `builtin.mode`.
//! - `bun.cpp` — Bun's C++ binding pointer surface; mostly snapshot
//!   formatter glue. Defer.
//! - `bun.api.*` — Bun runtime API hooks (vm, sourcemap registry).
//!   Defer.
//!
//! ## Layout under `src/bun/`
//!
//!   - `bun_test.zig`          — entrypoint / scope tree owner
//!   - `jest.zig`              — Jest-compatible scope/lifecycle
//!   - `expect.zig`            — `expect()` matcher harness
//!   - `expect/*.zig`          — 70 individual matchers (`toBe`, ...)
//!   - `Collection.zig`        — test collection
//!   - `Execution.zig`         — test execution scheduling
//!   - `Order.zig`             — deterministic test ordering
//!   - `ScopeFunctions.zig`    — `describe` / `test` / hook factories
//!   - `DoneCallback.zig`      — async test `done` callbacks
//!   - `snapshot.zig`          — snapshot persistence
//!   - `pretty_format.zig`     — value pretty-printer
//!   - `diff_format.zig`       — top-level diff formatter
//!   - `diff/printDiff.zig`    — Jest-style colored diff output
//!   - `diff/diff_match_patch.zig` — Myers-style line/word diff
//!   - `debug.zig`             — debugging helpers
//!   - `harness/recover.zig`   — fixture harness recovery
//!   - `harness/fixtures.zig`  — fixture harness
//!   - `timers/FakeTimers.zig` — Jest-style fake timers
//!   - `cli/test_command.zig`  — `bun test` CLI driver (file glob,
//!                               watch mode, parallel execution)
//!   - `jest.classes.ts`       — TypeScript bridge / class registry
//!
//! ## Why we own this code
//!
//! Bun has announced it is rewriting its core in Rust. We rely on
//! Zig — both because Home's compiler is Zig and because we want the
//! maintenance burden to stay with us, not with a project moving in a
//! different direction. Vendoring (rather than vendoring + binding to
//! the upstream package) lets us:
//!
//! 1. Adapt the test runner to Home's HIR diagnostics surface and
//!    runtime module loader without round-tripping through Bun's
//!    JavaScriptCore boundary.
//! 2. Keep the upstream MIT license intact (per-file headers +
//!    `LICENSE.bun.md`).
//! 3. Track a clear porting status in `PORTING_STATUS.md` so we know
//!    exactly what compiles and what's still on Bun's stdlib.

const std = @import("std");

pub const corpus = @import("corpus.zig");
pub const corpus_runner = @import("corpus_runner.zig");
pub const result = @import("result.zig");
pub const runner = @import("runner.zig");

/// Stub. Once the `compat` shim is in place, this module will
/// re-export `bun_test`, `jest`, `expect`, and the rest of the surface
/// listed above. For now it's intentionally empty so the build-system
/// wiring can compile this package without dragging in the
/// not-yet-portable `src/bun/*.zig` tree.
pub const version = "0.0.0";

test "home_test facade compiles" {
    try std.testing.expectEqualStrings("0.0.0", version);
}

test "home_test corpus discovery is linked" {
    try std.testing.expect(corpus.isTestFile("sample.test.ts"));
}

test "home_test corpus runner is linked" {
    try std.testing.expectEqual(corpus_runner.Subset.minimal_js, corpus_runner.parseSubsetFlagValue("minimal-js").?);
}

test "home_test result model is linked" {
    var summary = result.RunSummary{};
    summary.addFile(.{ .path = "sample.test.ts", .passed = 1 });
    try std.testing.expectEqual(@as(usize, 1), summary.passed);
}

test "home_test runner contract is linked" {
    try std.testing.expectEqualStrings("jsc-bootstrap", runner.Adapter.jsc_bootstrap.label());
}
