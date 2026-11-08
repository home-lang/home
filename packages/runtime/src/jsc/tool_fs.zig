//! Real filesystem operations for the repository-tool Node adapter.
const std = @import("std");
const bun = @import("bun");
const callback = @import("callback.zig");
const api = @import("extern_fns.zig");
const types = @import("opaques.zig");
const io = std.Io.Threaded.global_single_threaded.io();

fn string(ctx: *types.JSContextRef, value: ?*types.JSValue, allocator: std.mem.Allocator) ?[]u8 {
    const js_string = api.JSValueToStringCopy(ctx, value, null) orelse return null;
    defer api.JSStringRelease(js_string);
    const buffer = allocator.alloc(u8, api.JSStringGetLength(js_string) * 4 + 1) catch return null;
    defer allocator.free(buffer);
    const count = api.JSStringGetUTF8CString(js_string, buffer.ptr, buffer.len);
    if (count == 0) return null;
    return allocator.dupe(u8, buffer[0 .. count - 1]) catch null;
}

fn text(ctx: *types.JSContextRef, value: []const u8) ?*types.JSValue {
    const allocator = std.heap.smp_allocator;
    const terminated = bun.dupeZ(allocator, u8, value) catch return null;
    defer allocator.free(terminated);
    const result = api.JSStringCreateWithUTF8CString(terminated.ptr) orelse return null;
    defer api.JSStringRelease(result);
    return api.JSValueMakeString(ctx, result);
}

fn set(ctx: *types.JSContextRef, object: *types.JSObject, name: [:0]const u8, value: ?*types.JSValue) void {
    const key = api.JSStringCreateWithUTF8CString(name.ptr) orelse return;
    defer api.JSStringRelease(key);
    api.JSObjectSetProperty(ctx, object, key, value, 0, null);
}

fn failure(ctx: *types.JSContextRef, object: *types.JSObject, err: anyerror) ?*types.JSValue {
    const code: []const u8 = switch (err) {
        error.FileNotFound => "ENOENT",
        error.AccessDenied => "EACCES",
        error.PermissionDenied => "EPERM",
        error.NotDir => "ENOTDIR",
        error.IsDir => "EISDIR",
        error.PathAlreadyExists => "EEXIST",
        error.DirNotEmpty => "ENOTEMPTY",
        error.NameTooLong => "ENAMETOOLONG",
        error.SymLinkLoop => "ELOOP",
        error.NoSpaceLeft => "ENOSPC",
        error.ReadOnlyFileSystem => "EROFS",
        error.FileBusy => "EBUSY",
        error.Unsupported => "ERR_HOME_UNSUPPORTED",
        else => "ERR_HOME_FS",
    };
    set(ctx, object, "error", text(ctx, code));
    set(ctx, object, "detail", text(ctx, @errorName(err)));
    return @ptrCast(object);
}

// Return the first created ancestor, as Node's recursive mkdir does. The
// stdlib's createDirPath intentionally discards that path, so walk parents
// only after a genuine missing-parent error. Preserve .. and symlink behavior.
fn mkdir(path: []const u8, recursive: bool, depth: usize) anyerror!?[]const u8 {
    if (depth > 256) return error.Unsupported;
    std.Io.Dir.cwd().createDir(io, path, .default_dir) catch |err| switch (err) {
        error.FileNotFound => {
            if (!recursive) return err;
            const parent = std.fs.path.dirname(path) orelse return err;
            if (std.mem.eql(u8, parent, path)) return err;
            const first = try mkdir(parent, true, depth + 1);
            _ = try mkdir(path, true, depth + 1);
            return first orelse path;
        },
        error.PathAlreadyExists => {
            if (!recursive) return err;
            const stat = try std.Io.Dir.cwd().statFile(io, path, .{});
            if (stat.kind != .directory) return err;
            return null;
        },
        else => return err,
    };
    return path;
}

fn operation(
    ctx: ?*types.JSContextRef,
    function: ?*types.JSObject,
    this: ?*types.JSObject,
    count: usize,
    args: [*c]const ?*types.JSValue,
    exception: api.ExceptionRef,
) callconv(.c) ?*types.JSValue {
    _ = function;
    _ = this;
    _ = exception;
    const c = ctx orelse return null;
    const object = api.JSObjectMake(c, null, null) orelse return api.JSValueMakeNull(c);
    if (count < 2 or args[0] == null or args[1] == null) return failure(c, object, error.Unsupported);
    const allocator = std.heap.smp_allocator;
    const op = string(c, args[0], allocator) orelse return failure(c, object, error.OutOfMemory);
    defer allocator.free(op);
    const path = string(c, args[1], allocator) orelse return failure(c, object, error.OutOfMemory);
    defer allocator.free(path);
    if (std.mem.indexOfScalar(u8, path, 0) != null) return failure(c, object, error.Unsupported);
    const recursive = count > 2 and api.JSValueToBoolean(c, args[2]);
    const force = count > 3 and api.JSValueToBoolean(c, args[3]);
    if (std.mem.eql(u8, op, "readFile")) {
        const contents = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch |err| return failure(c, object, err);
        defer allocator.free(contents);
        const encoded = allocator.alloc(u8, contents.len * 2) catch return failure(c, object, error.OutOfMemory);
        defer allocator.free(encoded);
        const digits = "0123456789abcdef";
        for (contents, 0..) |byte, index| {
            encoded[index * 2] = digits[byte >> 4];
            encoded[index * 2 + 1] = digits[byte & 0xf];
        }
        set(c, object, "hex", text(c, encoded));
    } else if (std.mem.eql(u8, op, "mkdir")) {
        const first = mkdir(path, recursive, 0) catch |err| return failure(c, object, err);
        if (recursive) if (first) |created| set(c, object, "created", text(c, created));
    } else if (std.mem.eql(u8, op, "rm")) {
        const stat = std.Io.Dir.cwd().statFile(io, path, .{ .follow_symlinks = false }) catch |err| {
            if (force and err == error.FileNotFound) return @ptrCast(object);
            return failure(c, object, err);
        };
        if (stat.kind == .directory and !recursive) {
            set(c, object, "error", text(c, "ERR_FS_EISDIR"));
            return @ptrCast(object);
        }
        if (recursive) {
            std.Io.Dir.cwd().deleteTree(io, path) catch |err| return failure(c, object, err);
        } else {
            std.Io.Dir.cwd().deleteFile(io, path) catch |err| {
                if (force and err == error.FileNotFound) return @ptrCast(object);
                return failure(c, object, err);
            };
        }
    } else if (std.mem.eql(u8, op, "stat")) {
        const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| return failure(c, object, err);
        set(c, object, "kind", text(c, @tagName(stat.kind)));
        set(c, object, "size", api.JSValueMakeNumber(c, @floatFromInt(stat.size)));
        set(c, object, "ino", api.JSValueMakeNumber(c, @floatFromInt(stat.inode)));
        set(c, object, "nlink", api.JSValueMakeNumber(c, @floatFromInt(stat.nlink)));
        set(c, object, "mtimeMs", api.JSValueMakeNumber(c, @as(f64, @floatFromInt(stat.mtime.nanoseconds)) / 1_000_000));
        set(c, object, "ctimeMs", api.JSValueMakeNumber(c, @as(f64, @floatFromInt(stat.ctime.nanoseconds)) / 1_000_000));
        if (stat.atime) |time| set(c, object, "atimeMs", api.JSValueMakeNumber(c, @as(f64, @floatFromInt(time.nanoseconds)) / 1_000_000));
    } else return failure(c, object, error.Unsupported);
    return @ptrCast(object);
}

pub fn install(ctx: *types.JSContextRef, global: *types.JSGlobalObject) void {
    callback.registerCallback(ctx, global, "__home_tool_fs_operation", operation);
}
