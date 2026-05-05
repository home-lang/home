//! Phase-scoped arena allocators.
//!
//! Lifetime contract: no node, type, or string allocated in arena `A` may
//! reference data allocated in arena `B` if `B` is dropped before `A`. The
//! compiler's phase order (Lex → Parse → Bind → Check → Emit) implies a
//! lifetime DAG; each phase has a named arena that is dropped en masse at the
//! end of the phase, except for `HIR` and `Check` which span the lifetime of
//! a program (Phase 5 watch mode resets these per-module on edit).
//!
//! Arenas are *not* safe for concurrent allocation from multiple threads
//! without external synchronization. The intended use is one arena per
//! worker per phase; cross-worker shared data goes through the global
//! string interner / type interner instead.
//!
//! Per the TS_PARITY_PLAN §0 Phase 0.2.

const std = @import("std");

/// A named, scoped arena. Wraps `std.heap.ArenaAllocator` with a label for
/// diagnostics and a peak-bytes counter for memory budgeting (used by the
/// `--extendedDiagnostics` output and the watch-mode regression gate).
pub const Arena = struct {
    label: []const u8,
    inner: std.heap.ArenaAllocator,
    /// Total bytes allocated across the lifetime of this arena (including
    /// bytes released by `reset`). Used for peak-RSS bookkeeping.
    cumulative_bytes: usize,
    /// Peak live bytes between resets. Updated lazily on `peakLiveBytes`
    /// queries (the underlying ArenaAllocator does not expose live-bytes
    /// directly, so this is best-effort and populated on every allocation
    /// via the wrapped allocator interface below).
    live_bytes: usize,
    peak_live_bytes: usize,

    /// Construct an arena with a static label. The label is borrowed and
    /// must outlive the arena (typical use: a string literal).
    pub fn init(label: []const u8, child: std.mem.Allocator) Arena {
        return .{
            .label = label,
            .inner = std.heap.ArenaAllocator.init(child),
            .cumulative_bytes = 0,
            .live_bytes = 0,
            .peak_live_bytes = 0,
        };
    }

    pub fn deinit(self: *Arena) void {
        self.inner.deinit();
    }

    /// Free everything allocated since the last `reset` (or `init`). Retains
    /// the underlying capacity for reuse. This is the hot path for watch
    /// mode: per-module `Parse` and `Bind` arenas reset between edits.
    pub fn reset(self: *Arena) void {
        _ = self.inner.reset(.retain_capacity);
        self.live_bytes = 0;
    }

    /// Free everything and shrink internal capacity back to zero. Useful at
    /// program shutdown or when a phase's arena will not be reused soon
    /// (e.g., `Lex` arena after Phase 1 is done).
    pub fn resetFree(self: *Arena) void {
        _ = self.inner.reset(.free_all);
        self.live_bytes = 0;
    }

    /// Returns an `std.mem.Allocator` interface bound to this arena. The
    /// returned allocator wraps the inner ArenaAllocator and updates the
    /// byte-counters on every successful allocation.
    pub fn allocator(self: *Arena) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    pub fn peakLiveBytes(self: *const Arena) usize {
        return self.peak_live_bytes;
    }

    pub fn cumulativeBytes(self: *const Arena) usize {
        return self.cumulative_bytes;
    }

    // -- Allocator vtable -----------------------------------------------------
    //
    // We delegate to the inner ArenaAllocator and bump our counters on
    // successful allocation. Resize and remap are passed through unchanged
    // (the ArenaAllocator handles them, but they don't affect the cumulative
    // counter — only the live-bytes count needs adjusting on resize).

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = vtableAlloc,
        .resize = vtableResize,
        .remap = vtableRemap,
        .free = vtableFree,
    };

    fn vtableAlloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Arena = @ptrCast(@alignCast(ctx));
        const inner_alloc = self.inner.allocator();
        const ptr = inner_alloc.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.cumulative_bytes += len;
        self.live_bytes += len;
        if (self.live_bytes > self.peak_live_bytes) self.peak_live_bytes = self.live_bytes;
        return ptr;
    }

    fn vtableResize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *Arena = @ptrCast(@alignCast(ctx));
        const inner_alloc = self.inner.allocator();
        const ok = inner_alloc.rawResize(buf, alignment, new_len, ret_addr);
        if (ok) {
            // Adjust counters: cumulative tracks growth only; live tracks delta.
            if (new_len > buf.len) {
                self.cumulative_bytes += (new_len - buf.len);
                self.live_bytes += (new_len - buf.len);
                if (self.live_bytes > self.peak_live_bytes) self.peak_live_bytes = self.live_bytes;
            } else if (new_len < buf.len) {
                self.live_bytes -= (buf.len - new_len);
            }
        }
        return ok;
    }

    fn vtableRemap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *Arena = @ptrCast(@alignCast(ctx));
        const inner_alloc = self.inner.allocator();
        const ptr = inner_alloc.rawRemap(buf, alignment, new_len, ret_addr) orelse return null;
        if (new_len > buf.len) {
            self.cumulative_bytes += (new_len - buf.len);
            self.live_bytes += (new_len - buf.len);
            if (self.live_bytes > self.peak_live_bytes) self.peak_live_bytes = self.live_bytes;
        } else if (new_len < buf.len) {
            self.live_bytes -= (buf.len - new_len);
        }
        return ptr;
    }

    fn vtableFree(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *Arena = @ptrCast(@alignCast(ctx));
        const inner_alloc = self.inner.allocator();
        inner_alloc.rawFree(buf, alignment, ret_addr);
        // ArenaAllocator's free is a no-op for individual allocations, but
        // we still decrement live_bytes so that peak tracking stays
        // semantically correct if the user calls free explicitly.
        if (self.live_bytes >= buf.len) {
            self.live_bytes -= buf.len;
        } else {
            self.live_bytes = 0;
        }
    }
};

/// Canonical phase labels. Centralizing these guarantees that the
/// `--extendedDiagnostics` output uses consistent strings across the
/// codebase, and lets tooling grep for arena names without false positives.
pub const Phase = struct {
    pub const lex = "lex";
    pub const parse = "parse";
    pub const ast = "ast";
    pub const bind = "bind";
    pub const hir = "hir";
    pub const check = "check";
    pub const emit = "emit";
    pub const codegen = "codegen";
    pub const lsp = "lsp";
};

/// A bundle of named arenas keyed by phase. Holds them in a fixed order so
/// that tear-down respects the lifetime DAG (later phases drop first).
///
/// This is the recommended top-level container for a compilation unit: one
/// `PhaseArenas` per program, threaded through the driver.
pub const PhaseArenas = struct {
    lex: Arena,
    parse: Arena,
    ast: Arena,
    bind: Arena,
    hir: Arena,
    check: Arena,
    emit: Arena,

    pub fn init(child: std.mem.Allocator) PhaseArenas {
        return .{
            .lex = Arena.init(Phase.lex, child),
            .parse = Arena.init(Phase.parse, child),
            .ast = Arena.init(Phase.ast, child),
            .bind = Arena.init(Phase.bind, child),
            .hir = Arena.init(Phase.hir, child),
            .check = Arena.init(Phase.check, child),
            .emit = Arena.init(Phase.emit, child),
        };
    }

    /// Tear down in *reverse* phase order so that downstream arenas (which
    /// may, in error paths, hold transient pointers into upstream arenas)
    /// are dropped first.
    pub fn deinit(self: *PhaseArenas) void {
        self.emit.deinit();
        self.check.deinit();
        self.hir.deinit();
        self.bind.deinit();
        self.ast.deinit();
        self.parse.deinit();
        self.lex.deinit();
    }

    /// Total live bytes across all phase arenas. Used for the memory budget
    /// gate in CI: full-build VS Code typecheck must stay ≤ 800 MB.
    pub fn totalLiveBytes(self: *const PhaseArenas) usize {
        return self.lex.live_bytes +
            self.parse.live_bytes +
            self.ast.live_bytes +
            self.bind.live_bytes +
            self.hir.live_bytes +
            self.check.live_bytes +
            self.emit.live_bytes;
    }

    /// Peak live bytes across all phase arenas, summed. Conservatively
    /// over-counts cases where two arenas peak at different moments — but
    /// that's the right direction for a budget gate.
    pub fn totalPeakBytes(self: *const PhaseArenas) usize {
        return self.lex.peak_live_bytes +
            self.parse.peak_live_bytes +
            self.ast.peak_live_bytes +
            self.bind.peak_live_bytes +
            self.hir.peak_live_bytes +
            self.check.peak_live_bytes +
            self.emit.peak_live_bytes;
    }
};

// =============================================================================
// Tests
// =============================================================================

test "Arena: basic alloc and reset" {
    const t = std.testing;
    var a = Arena.init("test", t.allocator);
    defer a.deinit();
    const al = a.allocator();

    const slice = try al.alloc(u8, 64);
    @memset(slice, 0xAA);
    try t.expectEqual(@as(usize, 64), a.live_bytes);
    try t.expectEqual(@as(usize, 64), a.cumulative_bytes);
    try t.expectEqual(@as(usize, 64), a.peak_live_bytes);

    a.reset();
    try t.expectEqual(@as(usize, 0), a.live_bytes);
    try t.expectEqual(@as(usize, 64), a.cumulative_bytes); // cumulative survives reset
    try t.expectEqual(@as(usize, 64), a.peak_live_bytes); // peak survives reset
}

test "Arena: peak tracks high-water mark" {
    const t = std.testing;
    var a = Arena.init("test", t.allocator);
    defer a.deinit();
    const al = a.allocator();

    _ = try al.alloc(u8, 100);
    try t.expectEqual(@as(usize, 100), a.peak_live_bytes);

    _ = try al.alloc(u8, 200);
    try t.expectEqual(@as(usize, 300), a.peak_live_bytes);

    a.reset();
    try t.expectEqual(@as(usize, 300), a.peak_live_bytes); // peak survives reset

    _ = try al.alloc(u8, 50);
    try t.expectEqual(@as(usize, 300), a.peak_live_bytes); // smaller, no update
}

test "Arena: many allocations stay in arena" {
    const t = std.testing;
    var a = Arena.init("test", t.allocator);
    defer a.deinit();
    const al = a.allocator();

    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        _ = try al.alloc(u8, 16);
    }
    try t.expectEqual(@as(usize, 16_000), a.cumulative_bytes);
    try t.expectEqual(@as(usize, 16_000), a.live_bytes);
}

test "Arena: resetFree releases memory back to child allocator" {
    const t = std.testing;
    var a = Arena.init("test", t.allocator);
    defer a.deinit();
    const al = a.allocator();

    _ = try al.alloc(u8, 1024 * 1024);
    try t.expectEqual(@as(usize, 1024 * 1024), a.live_bytes);

    a.resetFree();
    try t.expectEqual(@as(usize, 0), a.live_bytes);
}

test "Arena: typed alloc with create" {
    const t = std.testing;
    var a = Arena.init("test", t.allocator);
    defer a.deinit();
    const al = a.allocator();

    const Point = struct { x: i32, y: i32 };
    const p = try al.create(Point);
    p.* = .{ .x = 7, .y = 11 };
    try t.expectEqual(@as(i32, 7), p.x);
    try t.expectEqual(@as(i32, 11), p.y);
    try t.expectEqual(@sizeOf(Point), a.live_bytes);
}

test "PhaseArenas: init and deinit in correct order" {
    const t = std.testing;
    var pa = PhaseArenas.init(t.allocator);
    defer pa.deinit();

    _ = try pa.lex.allocator().alloc(u8, 64);
    _ = try pa.parse.allocator().alloc(u8, 128);
    _ = try pa.hir.allocator().alloc(u8, 256);

    try t.expectEqual(@as(usize, 64 + 128 + 256), pa.totalLiveBytes());
    try t.expectEqual(@as(usize, 64 + 128 + 256), pa.totalPeakBytes());
}

test "PhaseArenas: per-phase reset" {
    const t = std.testing;
    var pa = PhaseArenas.init(t.allocator);
    defer pa.deinit();

    _ = try pa.lex.allocator().alloc(u8, 100);
    _ = try pa.parse.allocator().alloc(u8, 200);
    pa.lex.reset();

    try t.expectEqual(@as(usize, 0), pa.lex.live_bytes);
    try t.expectEqual(@as(usize, 200), pa.parse.live_bytes);
    try t.expectEqual(@as(usize, 200), pa.totalLiveBytes());
}

test "Arena: labels are preserved" {
    const t = std.testing;
    var a = Arena.init(Phase.check, t.allocator);
    defer a.deinit();
    try t.expectEqualStrings("check", a.label);
}

test "Arena: alignment respected" {
    const t = std.testing;
    var a = Arena.init("test", t.allocator);
    defer a.deinit();
    const al = a.allocator();

    const Aligned = struct {
        bytes: [64]u8 align(64),
    };
    const p = try al.create(Aligned);
    const addr = @intFromPtr(p);
    try t.expectEqual(@as(usize, 0), addr % 64);
}

test "Arena: free updates live_bytes but cumulative is unchanged" {
    const t = std.testing;
    var a = Arena.init("test", t.allocator);
    defer a.deinit();
    const al = a.allocator();

    const slice = try al.alloc(u8, 256);
    try t.expectEqual(@as(usize, 256), a.live_bytes);
    al.free(slice);
    try t.expectEqual(@as(usize, 0), a.live_bytes);
    try t.expectEqual(@as(usize, 256), a.cumulative_bytes);
}

test "Arena: reset is idempotent" {
    const t = std.testing;
    var a = Arena.init("test", t.allocator);
    defer a.deinit();

    a.reset();
    a.reset();
    try t.expectEqual(@as(usize, 0), a.live_bytes);

    _ = try a.allocator().alloc(u8, 1);
    a.reset();
    a.reset();
    try t.expectEqual(@as(usize, 0), a.live_bytes);
}
