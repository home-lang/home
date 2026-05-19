// Wave-18 stub (2026-05-18) — minimal forward-decl for the sql wire
// `Data` union. Upstream `bun/src/sql/shared/Data.zig` is a 94-line
// union with two helpers (`toOwned`, `zdeinit`) that require
// `bun.ByteList` + `bun.BoundedArray` + `bun.default_allocator` +
// `bun.freeSensitive`. Only `BoundedArray` is wired in home_rt today,
// so the rest of the surface is parked.
//
// This stub keeps the union shape (`.owned`, `.temporary`,
// `.inline_storage`, `.empty`) so packet decoders/encoders that store
// fields of type `Data` compile, plus the `slice()` / `sliceZ()` /
// `substring()` / `deinit()` / `Empty` declarations users reach for
// at the API boundary. `toOwned` + `zdeinit` + `create` get
// `@compileError` bodies — invoking them is the trigger to port the
// real `Data` and drop this stub.
//
// TODO(phase-12-N): replace with the verbatim upstream copy once
// `bun.ByteList` + `bun.freeSensitive` are ported.

pub const Data = union(enum) {
    owned: ByteList,
    temporary: []const u8,
    inline_storage: InlineStorage,
    empty: void,

    /// Stand-in for `bun.ByteList`. Real type is a SSO-friendly
    /// length-prefixed byte slice. The stub holds just the field shape
    /// (slice + len) needed by `.owned` / `slice()` so users that only
    /// hold or read borrowed data compile.
    pub const ByteList = extern struct {
        ptr: [*]u8 = @ptrFromInt(@alignOf(u8)),
        len: u32 = 0,
        cap: u32 = 0,

        pub fn slice(this: @This()) []const u8 {
            return this.ptr[0..this.len];
        }
    };

    pub const InlineStorage = struct {
        // Zig 0.17 dropped `.{0} ** N` tuple-init repetition; use the
        // builtin `@splat` form instead. Behavior is identical: all 15
        // bytes initialized to 0.
        buffer: [15]u8 = @splat(0),
        len: u8 = 0,

        pub fn slice(this: *const @This()) []const u8 {
            return this.buffer[0..this.len];
        }
    };

    pub const Empty: Data = .{ .empty = {} };

    pub fn create(_: []const u8, _: std.mem.Allocator) !Data {
        @compileError("sql/shared/Data: create() not wired — port bun.ByteList first");
    }

    pub fn toOwned(_: @This()) !ByteList {
        @compileError("sql/shared/Data: toOwned() not wired — port bun.ByteList first");
    }

    pub fn deinit(this: *@This()) void {
        switch (this.*) {
            .owned => {}, // freeing owned needs allocator wiring — see TODO
            .temporary, .empty, .inline_storage => {},
        }
    }

    pub fn zdeinit(_: *@This()) void {
        @compileError("sql/shared/Data: zdeinit() not wired — port bun.freeSensitive first");
    }

    pub fn slice(this: *const @This()) []const u8 {
        return switch (this.*) {
            .owned => this.owned.slice(),
            .temporary => this.temporary,
            .empty => "",
            .inline_storage => this.inline_storage.slice(),
        };
    }

    pub fn substring(this: *const @This(), start_index: usize, end_index: usize) Data {
        return switch (this.*) {
            .owned => .{ .temporary = this.owned.slice()[start_index..end_index] },
            .temporary => .{ .temporary = this.temporary[start_index..end_index] },
            .empty => .{ .empty = {} },
            .inline_storage => .{ .temporary = this.inline_storage.slice()[start_index..end_index] },
        };
    }
};

test "Data.empty slices to empty string" {
    const std_local = @import("std");
    const d: Data = .{ .empty = {} };
    try std_local.testing.expectEqualStrings("", d.slice());
}

test "Data.temporary slices through" {
    const std_local = @import("std");
    const d: Data = .{ .temporary = "abc" };
    try std_local.testing.expectEqualStrings("abc", d.slice());
}

test "Data.Empty constant is the empty variant" {
    const d = Data.Empty;
    switch (d) {
        .empty => {},
        else => @panic("Data.Empty must be the .empty variant"),
    }
}

const std = @import("std");
