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
    op: enum { spawn, poll, kill, close, exec_file },
    argv: []const []const u8 = &.{},
    cwd: ?[]const u8 = null,
    keys: []const []const u8 = &.{},
    values: []const []const u8 = &.{},
    inherit: [3]bool = .{ true, true, true },
    id: u64 = 0,
    signal: []const u8 = "TERM",
    max_buffer: usize = 1024 * 1024,
    mirror_stderr: bool = false,
};

fn validString(value: []const u8) bool {
    return std.mem.indexOfScalar(u8, value, 0) == null;
}

fn inputBytes(ctx: *types.JSContextRef, value: ?*types.JSValue, allocator: std.mem.Allocator, exception: api.ExceptionRef) ![]u8 {
    const input = value orelse return error.UnsupportedCapture;
    if (api.JSValueGetTypedArrayType(ctx, input, exception) != .kJSTypedArrayTypeUint8Array) return error.UnsupportedCapture;
    api.JSValueProtect(ctx, input);
    defer api.JSValueUnprotect(ctx, input);
    const view = api.JSValueToObject(ctx, input, exception) orelse return error.JavaScriptException;
    const length = api.JSObjectGetTypedArrayByteLength(ctx, view, exception);
    if (length > @import("tool_exec_capture.zig").max_bytes) return error.UnsupportedCapture;
    if (length == 0) return allocator.dupe(u8, "");
    const offset = api.JSObjectGetTypedArrayByteOffset(ctx, view, exception);
    const raw = api.JSObjectGetTypedArrayBytesPtr(ctx, view, exception) orelse return error.JavaScriptException;
    // Copy the managed view before another JS call or any native IO task.
    return allocator.dupe(u8, @as([*]const u8, @ptrCast(raw))[offset..][0..length]);
}

fn outputBytes(ctx: *types.JSContextRef, object: *types.JSObject, name: [:0]const u8, bytes: []const u8, exception: api.ExceptionRef) !void {
    const view = api.JSObjectMakeTypedArray(ctx, .kJSTypedArrayTypeUint8Array, bytes.len, exception) orelse return error.OutOfMemory;
    api.JSValueProtect(ctx, @ptrCast(view));
    defer api.JSValueUnprotect(ctx, @ptrCast(view));
    if (bytes.len != 0) {
        const raw = api.JSObjectGetTypedArrayBytesPtr(ctx, view, exception) orelse return error.JavaScriptException;
        @memcpy(@as([*]u8, @ptrCast(raw))[0..bytes.len], bytes);
    }
    fs.set(ctx, object, name, @ptrCast(view));
}

fn perform(host: *Host, request: Request, result: *types.JSObject, input_value: ?*types.JSValue, exception: api.ExceptionRef) !void {
    const c = host.ctx;
    switch (request.op) {
        .exec_file => {
            const capture = @import("tool_exec_capture.zig");
            if (request.argv.len == 0 or request.argv.len > 4096 or request.keys.len != request.values.len or request.keys.len > 4096) return error.InvalidRequest;
            if (!std.fs.path.isAbsolute(request.argv[0]) or request.max_buffer > capture.max_bytes) return error.UnsupportedCapture;
            for (request.argv) |arg| if (!validString(arg)) return error.InvalidRequest;
            if (request.cwd) |cwd| if (!validString(cwd)) return error.InvalidRequest;
            var env = std.process.Environ.Map.init(host.allocator);
            defer env.deinit();
            for (request.keys, request.values) |key, value| {
                if (key.len == 0 or !validString(key) or std.mem.indexOfScalar(u8, key, '=') != null or !validString(value)) return error.InvalidRequest;
                try env.put(key, value);
            }
            const input = try inputBytes(c, input_value, host.allocator, exception);
            defer host.allocator.free(input);
            var captured = try capture.run(host.allocator, host.pool.threaded.io(), request.argv, request.cwd, &env, input, request.max_buffer);
            defer captured.deinit(host.allocator);
            // execFileSync's default captures stderr and forwards the actual
            // bytes afterwards. Explicit 'pipe' leaves forwarding to the caller.
            if (request.mirror_stderr) try std.Io.File.stderr().writeStreamingAll(host.pool.threaded.io(), captured.stderr);
            try outputBytes(c, result, "stdoutBytes", captured.stdout, exception);
            try outputBytes(c, result, "stderrBytes", captured.stderr, exception);
            fs.set(c, result, "pid", api.JSValueMakeNumber(c, @floatFromInt(captured.pid)));
            fs.set(c, result, "status", switch (captured.term) {
                .exited => |code| api.JSValueMakeNumber(c, @floatFromInt(code)),
                else => api.JSValueMakeNull(c),
            });
            fs.set(c, result, "signal", api.JSValueMakeNull(c));
            if (captured.term == .signal) {
                const name = std.enums.tagName(std.posix.SIG, captured.term.signal) orelse return error.ChildWaitFailed;
                const signal = try std.fmt.allocPrint(host.allocator, "SIG{s}", .{name});
                defer host.allocator.free(signal);
                fs.set(c, result, "signal", fs.text(c, signal));
            }
            if (captured.io_error) |err| {
                const number: std.posix.E = if (err == error.CaptureLimit) .NOBUFS else if (err == error.BrokenPipe) .PIPE else if (err == error.OutOfMemory or err == error.SystemResources) .NOMEM else .IO;
                const code = try std.fmt.allocPrint(host.allocator, "E{s}", .{@tagName(number)});
                defer host.allocator.free(code);
                fs.set(c, result, "error", fs.text(c, code));
                fs.set(c, result, "detail", fs.text(c, @errorName(err)));
                fs.set(c, result, "errno", api.JSValueMakeNumber(c, -@as(f64, @floatFromInt(@backingInt(number)))));
            }
        },
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
    const c = ctx orelse return null;
    const host = active orelse return api.JSValueMakeNull(c);
    if (host.ctx != c or count < 1 or count > 2) return api.JSValueMakeNull(c);
    const result = api.JSObjectMake(c, null, null) orelse return null;
    api.JSValueProtect(c, @ptrCast(result));
    defer api.JSValueUnprotect(c, @ptrCast(result));
    const source = fs.string(c, args[0], host.allocator) orelse return null;
    defer host.allocator.free(source);
    const parsed = std.json.parseFromSlice(Request, host.allocator, source, .{}) catch return fs.failure(c, result, error.Unsupported);
    defer parsed.deinit();
    if ((parsed.value.op == .exec_file and count != 2) or (parsed.value.op != .exec_file and count != 1)) return fs.failure(c, result, error.Unsupported);
    perform(host, parsed.value, result, if (count == 2) args[1] else null, exception) catch |err| {
        const code: []const u8 = switch (err) {
            error.FileNotFound => "ENOENT",
            error.NotDir => "ENOTDIR",
            error.AccessDenied => "EACCES",
            error.OutOfMemory, error.SystemResources => "ENOMEM",
            error.InvalidSignal => "ERR_UNKNOWN_SIGNAL",
            error.UnsupportedCapture => "ERR_HOME_UNSUPPORTED",
            else => "ERR_HOME_CHILD_PROCESS",
        };
        fs.set(c, result, "error", fs.text(c, code));
        fs.set(c, result, "detail", fs.text(c, @errorName(err)));
    };
    return @ptrCast(result);
}
