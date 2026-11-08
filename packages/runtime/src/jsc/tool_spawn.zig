//! Native child operations scoped to the JS owner thread and context.
const std = @import("std");
const api = @import("extern_fns.zig");
const types = @import("opaques.zig");
const callback = @import("callback.zig");
const fs = @import("tool_fs.zig");
const Pool = @import("tool_child_pool.zig").Pool;

threadlocal var active: ?*Host = null;

pub const Host = struct {
    allocator: std.mem.Allocator,
    ctx: *types.JSContextRef,
    pool: Pool,
    previous: ?*Host = null,

    pub fn init(allocator: std.mem.Allocator, ctx: *types.JSContextRef) !Host {
        return .{ .allocator = allocator, .ctx = ctx, .pool = try Pool.init(allocator) };
    }
    pub fn install(self: *Host, global: *types.JSGlobalObject) void {
        self.previous = active;
        active = self;
        callback.registerCallback(self.ctx, global, "__home_tool_child", operation);
    }
    pub fn deinit(self: *Host) void {
        if (active == self) active = self.previous;
        self.pool.deinit();
    }
};

const Request = struct {
    op: enum { spawn, poll, kill, close },
    argv: []const []const u8 = &.{},
    cwd: ?[]const u8 = null,
    keys: []const []const u8 = &.{},
    values: []const []const u8 = &.{},
    inherit: [3]bool = .{ true, true, true },
    id: u64 = 0,
    signal: []const u8 = "TERM",
};

fn validString(value: []const u8) bool {
    return std.mem.indexOfScalar(u8, value, 0) == null;
}

fn perform(host: *Host, request: Request, result: *types.JSObject) !void {
    const c = host.ctx;
    switch (request.op) {
        .spawn => {
            if (request.argv.len == 0 or request.argv.len > 4096 or request.keys.len != request.values.len or request.keys.len > 4096) return error.InvalidRequest;
            for (request.argv) |arg| if (!validString(arg)) return error.InvalidRequest;
            if (request.cwd) |cwd| if (!validString(cwd)) return error.InvalidRequest;
            var env = std.process.Environ.Map.init(host.allocator);
            defer env.deinit();
            for (request.keys, request.values) |key, value| {
                if (key.len == 0 or !validString(key) or std.mem.indexOfScalar(u8, key, '=') != null or !validString(value)) return error.InvalidRequest;
                try env.put(key, value);
            }
            const started = try host.pool.spawn(request.argv, request.cwd, &env, request.inherit);
            fs.set(c, result, "id", api.JSValueMakeNumber(c, @floatFromInt(started.id)));
            fs.set(c, result, "pid", api.JSValueMakeNumber(c, @floatFromInt(started.pid)));
        },
        .poll => {
            const term = (try host.pool.poll(request.id)) orelse return;
            fs.set(c, result, "done", api.JSValueMakeBoolean(c, true));
            switch (term) {
                .exited => |code| fs.set(c, result, "exitCode", api.JSValueMakeNumber(c, @floatFromInt(code))),
                .signal => |sig| {
                    const name = std.enums.tagName(std.posix.SIG, sig) orelse return error.ChildWaitFailed;
                    const text = try std.fmt.allocPrint(host.allocator, "SIG{s}", .{name});
                    defer host.allocator.free(text);
                    fs.set(c, result, "signalCode", fs.text(c, text));
                    fs.set(c, result, "signalNumber", api.JSValueMakeNumber(c, @floatFromInt(@backingInt(sig))));
                },
                else => return error.ChildWaitFailed,
            }
        },
        .close => host.pool.close(request.id),
        .kill => {
            const sig = std.meta.stringToEnum(std.posix.SIG, request.signal) orelse return error.InvalidSignal;
            fs.set(c, result, "sent", api.JSValueMakeBoolean(c, try host.pool.signal(request.id, sig)));
        },
    }
}

fn operation(ctx: ?*types.JSContextRef, function: ?*types.JSObject, this: ?*types.JSObject, count: usize, args: [*c]const ?*types.JSValue, exception: api.ExceptionRef) callconv(.c) ?*types.JSValue {
    _ = function;
    _ = this;
    _ = exception;
    const c = ctx orelse return null;
    const host = active orelse return api.JSValueMakeNull(c);
    if (host.ctx != c or count != 1) return api.JSValueMakeNull(c);
    const result = api.JSObjectMake(c, null, null) orelse return null;
    const source = fs.string(c, args[0], host.allocator) orelse return null;
    defer host.allocator.free(source);
    const parsed = std.json.parseFromSlice(Request, host.allocator, source, .{}) catch return fs.failure(c, result, error.Unsupported);
    defer parsed.deinit();
    perform(host, parsed.value, result) catch |err| {
        const code: []const u8 = switch (err) {
            error.FileNotFound => "ENOENT",
            error.NotDir => "ENOTDIR",
            error.AccessDenied => "EACCES",
            error.OutOfMemory, error.SystemResources => "ENOMEM",
            error.InvalidSignal => "ERR_UNKNOWN_SIGNAL",
            else => "ERR_HOME_CHILD_PROCESS",
        };
        fs.set(c, result, "error", fs.text(c, code));
        fs.set(c, result, "detail", fs.text(c, @errorName(err)));
    };
    return @ptrCast(result);
}
