//! SQLite's JS bridge stays on the owning context thread. Native handles are
//! context-owned and finalized before engine teardown; no JS SQL emulation.
const std = @import("std");
const api = @import("extern_fns.zig");
const types = @import("opaques.zig");
const callback = @import("callback.zig");
const fs = @import("tool_fs.zig");
const native = @import("tool_sqlite_pool.zig");
threadlocal var active: ?*Host = null;

pub const Host = struct {
    allocator: std.mem.Allocator,
    ctx: *types.JSContextRef,
    pool: native.Pool,
    previous: ?*Host = null,
    pub fn init(allocator: std.mem.Allocator, ctx: *types.JSContextRef) Host {
        return .{ .allocator = allocator, .ctx = ctx, .pool = native.Pool.init(allocator) };
    }
    pub fn install(self: *Host, global: *types.JSGlobalObject) void {
        self.previous = active;
        active = self;
        callback.registerCallback(self.ctx, global, "__home_tool_sqlite", operation);
    }
    pub fn deinit(self: *Host) void {
        if (active == self) active = self.previous;
        self.pool.deinit();
    }
};
fn sqliteCode(number: c_int) []const u8 {
    return switch (number) {
        1555 => "SQLITE_CONSTRAINT_PRIMARYKEY",
        2067 => "SQLITE_CONSTRAINT_UNIQUE",
        1299 => "SQLITE_CONSTRAINT_NOTNULL",
        787 => "SQLITE_CONSTRAINT_FOREIGNKEY",
        275 => "SQLITE_CONSTRAINT_CHECK",
        1811 => "SQLITE_CONSTRAINT_TRIGGER",
        else => switch (number & 255) {
            1 => "SQLITE_ERROR",
            2 => "SQLITE_INTERNAL",
            3 => "SQLITE_PERM",
            4 => "SQLITE_ABORT",
            5 => "SQLITE_BUSY",
            6 => "SQLITE_LOCKED",
            7 => "SQLITE_NOMEM",
            8 => "SQLITE_READONLY",
            9 => "SQLITE_INTERRUPT",
            10 => "SQLITE_IOERR",
            11 => "SQLITE_CORRUPT",
            12 => "SQLITE_NOTFOUND",
            13 => "SQLITE_FULL",
            14 => "SQLITE_CANTOPEN",
            15 => "SQLITE_PROTOCOL",
            17 => "SQLITE_SCHEMA",
            18 => "SQLITE_TOOBIG",
            19 => "SQLITE_CONSTRAINT",
            20 => "SQLITE_MISMATCH",
            21 => "SQLITE_MISUSE",
            23 => "SQLITE_AUTH",
            25 => "SQLITE_RANGE",
            26 => "SQLITE_NOTADB",
            else => "SQLITE_ERROR",
        },
    };
}
fn operation(ctx: ?*types.JSContextRef, function: ?*types.JSObject, this: ?*types.JSObject, count: usize, args: [*c]const ?*types.JSValue, exception: api.ExceptionRef) callconv(.c) ?*types.JSValue {
    _ = function;
    _ = this;
    _ = exception;
    const c = ctx orelse return null;
    const host = active orelse return api.JSValueMakeNull(c);
    if (c != host.ctx or count != 1) return api.JSValueMakeNull(c);
    var arena = std.heap.ArenaAllocator.init(host.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = fs.string(c, args[0], allocator) orelse return api.JSValueMakeNull(c);
    const request = std.json.parseFromSlice(native.Request, allocator, source, .{}) catch return api.JSValueMakeNull(c);
    const result = host.pool.perform(allocator, request.value) catch |err| {
        const failure = host.pool.failure;
        const kind: []const u8 = switch (err) {
            error.SQLite => "sqlite",
            error.Argument => "argument",
            error.ClosedDatabase => "closed",
            error.FinalizedStatement => "finalized",
            else => "host",
        };
        const body = std.json.Stringify.valueAlloc(allocator, .{ .failure = .{
            .kind = kind,
            .message = if (failure) |f| f.message else @errorName(err),
            .code = if (failure) |f| sqliteCode(f.number) else "ERR_HOME_SQLITE",
            .errno = if (failure) |f| f.number else 0,
            .byteOffset = if (failure) |f| f.offset else -1,
        } }, .{}) catch return api.JSValueMakeNull(c);
        return fs.text(c, body);
    };
    const body = std.json.Stringify.valueAlloc(allocator, result, .{ .emit_null_optional_fields = false }) catch return api.JSValueMakeNull(c);
    return fs.text(c, body);
}
