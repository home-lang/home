//! Real filesystem operations for the repository-tool Node adapter.
const std = @import("std");
const bun = @import("bun");
const callback = @import("callback.zig");
const api = @import("extern_fns.zig");
const types = @import("opaques.zig");
const io = std.Io.Threaded.global_single_threaded.io();
const tool_file_max = 8 * 1024 * 1024;

fn readToolFile(dir: std.Io.Dir, path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    // Dir.readFileAlloc uses an exclusive limit, unlike Reader.allocRemaining.
    // Reserve the EOF probe so an exactly 8 MiB file remains valid.
    return dir.readFileAlloc(io, path, allocator, .limited(tool_file_max + 1));
}

fn decodeToolText(allocator: std.mem.Allocator, bytes: []const u8) ![]u16 {
    const valid = std.unicode.utf8ValidateSlice(bytes);
    // The stdlib formatter implements WHATWG maximal-subpart replacement.
    // Keep BOM handling in the file facade, alongside its Blob text contract.
    const normalized = if (valid) bytes else try std.fmt.allocPrint(allocator, "{f}", .{std.unicode.fmtUtf8(bytes)});
    defer if (!valid) allocator.free(normalized);
    const chars = try std.unicode.utf8ToUtf16LeAlloc(allocator, normalized);
    for (chars) |*char| char.* = std.mem.littleToNative(u16, char.*);
    return chars;
}

pub fn string(ctx: *types.JSContextRef, value: ?*types.JSValue, allocator: std.mem.Allocator) ?[]u8 {
    const js_string = api.JSValueToStringCopy(ctx, value, null) orelse return null;
    defer api.JSStringRelease(js_string);
    const length = api.JSStringGetLength(js_string);
    if (length == 0) return allocator.dupe(u8, "") catch null;
    const chars = allocator.dupe(u16, api.JSStringGetCharactersPtr(js_string)[0..length]) catch return null;
    defer allocator.free(chars);
    for (chars) |*char| char.* = std.mem.nativeToLittle(u16, char.*);
    // Preserve NUL and replace lone UTF-16 surrogates without truncating suffixes.
    return std.fmt.allocPrint(allocator, "{f}", .{std.unicode.fmtUtf16Le(chars)}) catch null;
}

pub fn text(ctx: *types.JSContextRef, value: []const u8) ?*types.JSValue {
    const allocator = std.heap.smp_allocator;
    const terminated = bun.dupeZ(allocator, u8, value) catch return null;
    defer allocator.free(terminated);
    const result = api.JSStringCreateWithUTF8CString(terminated.ptr) orelse return null;
    defer api.JSStringRelease(result);
    return api.JSValueMakeString(ctx, result);
}

pub fn set(ctx: *types.JSContextRef, object: *types.JSObject, name: [:0]const u8, value: ?*types.JSValue) void {
    const key = api.JSStringCreateWithUTF8CString(name.ptr) orelse return;
    defer api.JSStringRelease(key);
    api.JSObjectSetProperty(ctx, object, key, value, 0, null);
}

pub fn failure(ctx: *types.JSContextRef, object: *types.JSObject, err: anyerror) ?*types.JSValue {
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
        error.InputOutput => "EIO",
        error.SystemResources => "ENOMEM",
        error.StreamTooLong => "ERR_BUFFER_TOO_LARGE",
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
fn mkdir(path: []const u8, recursive: bool, depth: usize, permissions: std.Io.File.Permissions) anyerror!?[]const u8 {
    if (depth > 256) return error.Unsupported;
    std.Io.Dir.cwd().createDir(io, path, permissions) catch |err| switch (err) {
        error.FileNotFound => {
            if (!recursive) return err;
            const parent = std.fs.path.dirname(path) orelse return err;
            if (std.mem.eql(u8, parent, path)) return err;
            const first = try mkdir(parent, true, depth + 1, permissions);
            _ = try mkdir(path, true, depth + 1, permissions);
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

const DirectoryEntry = struct { name: []const u8, kind: std.Io.File.Kind };

fn accessPath(path: [:0]const u8, mode: u3) !void {
    const native_mode: c_uint =
        @as(c_uint, if (mode & 4 != 0) std.c.R_OK else 0) |
        @as(c_uint, if (mode & 2 != 0) std.c.W_OK else 0) |
        @as(c_uint, if (mode & 1 != 0) std.c.X_OK else 0);
    // Use access rather than stat/open: real-UID permissions, executable bits,
    // symlink resolution and read-only mounts belong to the kernel. Dir.access
    // currently folds ENOTDIR into ENOENT, losing Node's observable errno.
    while (true) switch (std.posix.errno(std.c.access(path.ptr, native_mode))) {
        .SUCCESS => return,
        .INTR => continue,
        .ACCES => return error.AccessDenied,
        .PERM => return error.PermissionDenied,
        .NOENT => return error.FileNotFound,
        .NOTDIR => return error.NotDir,
        .LOOP => return error.SymLinkLoop,
        .NAMETOOLONG => return error.NameTooLong,
        .ROFS => return error.ReadOnlyFileSystem,
        .TXTBSY => return error.FileBusy,
        .IO => return error.InputOutput,
        .NOMEM => return error.SystemResources,
        else => return error.Unexpected,
    };
}

fn readDirectory(allocator: std.mem.Allocator, root: std.Io.Dir, path: []const u8, with_types: bool) ![]DirectoryEntry {
    var directory = try root.openDir(io, path, .{ .iterate = true });
    defer directory.close(io);
    var entries: std.ArrayList(DirectoryEntry) = .empty;
    errdefer {
        for (entries.items) |entry| allocator.free(entry.name);
        entries.deinit(allocator);
    }
    var bytes: usize = 0;
    var iterator = directory.iterate();
    while (try iterator.next(io)) |entry| {
        // This bounded UTF-8 profile never returns an invented replacement
        // filename or a silently truncated listing.
        if (!std.unicode.utf8ValidateSlice(entry.name)) return error.Unsupported;
        bytes += entry.name.len;
        if (entries.items.len >= 100_000 or bytes > tool_file_max) return error.StreamTooLong;
        var kind = entry.kind;
        // Some filesystems return DT_UNKNOWN. Resolve that entry relative to
        // the open directory, without following even broken symbolic links.
        if (with_types and kind == .unknown) kind = (try directory.statFile(io, entry.name, .{ .follow_symlinks = false })).kind;
        const name = try allocator.dupe(u8, entry.name);
        errdefer allocator.free(name);
        try entries.append(allocator, .{ .name = name, .kind = kind });
    }
    return entries.toOwnedSlice(allocator);
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
    const c = ctx orelse return null;
    const object = api.JSObjectMake(c, null, null) orelse return api.JSValueMakeNull(c);
    api.JSValueProtect(c, @ptrCast(object));
    defer api.JSValueUnprotect(c, @ptrCast(object));
    if (count < 2 or args[0] == null or args[1] == null) return failure(c, object, error.Unsupported);
    const allocator = std.heap.smp_allocator;
    const op = string(c, args[0], allocator) orelse return failure(c, object, error.OutOfMemory);
    defer allocator.free(op);
    const path = string(c, args[1], allocator) orelse return failure(c, object, error.OutOfMemory);
    defer allocator.free(path);
    if (std.mem.indexOfScalar(u8, path, 0) != null) return failure(c, object, error.Unsupported);
    const recursive = count > 2 and api.JSValueToBoolean(c, args[2]);
    const force = count > 3 and api.JSValueToBoolean(c, args[3]);
    const creates_file = std.mem.eql(u8, op, "writeFile");
    const creates_directory = std.mem.eql(u8, op, "mkdir");
    var permissions: std.Io.File.Permissions = if (creates_directory) .default_dir else .default_file;
    if ((creates_file or creates_directory) and count > 4 and !api.JSValueIsUndefined(c, args[4])) {
        if (!api.JSValueIsNumber(c, args[4])) return failure(c, object, error.Unsupported);
        const mode = api.JSValueToNumber(c, args[4], exception);
        if (!std.math.isFinite(mode) or mode < 0 or mode > 0o7777 or @trunc(mode) != mode) return failure(c, object, error.Unsupported);
        permissions = .fromMode(@intFromFloat(mode));
    }
    if (std.mem.eql(u8, op, "access")) {
        if (count < 3 or !api.JSValueIsNumber(c, args[2])) return failure(c, object, error.Unsupported);
        const mode = api.JSValueToNumber(c, args[2], exception);
        if (!std.math.isFinite(mode) or mode < 0 or mode > 7 or @trunc(mode) != mode) return failure(c, object, error.Unsupported);
        const terminated = bun.dupeZ(allocator, u8, path) catch return failure(c, object, error.OutOfMemory);
        defer allocator.free(terminated);
        accessPath(terminated, @intFromFloat(mode)) catch |err| return failure(c, object, err);
    } else if (std.mem.eql(u8, op, "writeFile")) {
        if (count < 3 or args[2] == null) return failure(c, object, error.Unsupported);
        const contents = if (api.JSValueIsString(c, args[2]))
            string(c, args[2], allocator) orelse return failure(c, object, error.OutOfMemory)
        else contents: {
            const kind = api.JSValueGetTypedArrayType(c, args[2], exception);
            if (kind == .kJSTypedArrayTypeNone or kind == .kJSTypedArrayTypeArrayBuffer) return failure(c, object, error.Unsupported);
            const view = api.JSValueToObject(c, args[2], exception) orelse return null;
            const length = api.JSObjectGetTypedArrayByteLength(c, view, exception);
            if (exception) |out| if (out.* != null) return null;
            if (length == 0) break :contents allocator.dupe(u8, "") catch return failure(c, object, error.OutOfMemory);
            const offset = api.JSObjectGetTypedArrayByteOffset(c, view, exception);
            const raw = api.JSObjectGetTypedArrayBytesPtr(c, view, exception) orelse return null;
            const bytes: [*]const u8 = @ptrCast(raw);
            break :contents allocator.dupe(u8, bytes[offset..][0..length]) catch return failure(c, object, error.OutOfMemory);
        };
        defer allocator.free(contents);
        // Creation permissions are subject to the native umask. Never chmod an
        // existing file: Node's mode option only applies when open creates it.
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = contents, .flags = .{ .permissions = permissions } }) catch |err| return failure(c, object, err);
    } else if (std.mem.eql(u8, op, "readFile") or std.mem.eql(u8, op, "readToolFile") or std.mem.eql(u8, op, "readToolTextFile")) {
        const bounded = !std.mem.eql(u8, op, "readFile");
        const contents = (if (bounded) readToolFile(.cwd(), path, allocator) else std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited)) catch |err| return failure(c, object, err);
        defer allocator.free(contents);
        set(c, object, "byteLength", api.JSValueMakeNumber(c, @floatFromInt(contents.len)));
        if (std.mem.eql(u8, op, "readToolTextFile")) {
            const chars = decodeToolText(allocator, contents) catch |err| return failure(c, object, err);
            defer allocator.free(chars);
            const js_string = api.JSStringCreateWithCharacters(chars.ptr, chars.len) orelse return failure(c, object, error.OutOfMemory);
            defer api.JSStringRelease(js_string);
            const value = api.JSValueMakeString(c, js_string) orelse return failure(c, object, error.OutOfMemory);
            set(c, object, "text", value);
            return @ptrCast(object);
        }
        const encoded = allocator.alloc(u8, contents.len * 2) catch return failure(c, object, error.OutOfMemory);
        defer allocator.free(encoded);
        const digits = "0123456789abcdef";
        for (contents, 0..) |byte, index| {
            encoded[index * 2] = digits[byte >> 4];
            encoded[index * 2 + 1] = digits[byte & 0xf];
        }
        set(c, object, "hex", text(c, encoded));
    } else if (std.mem.eql(u8, op, "readdir")) {
        const entries = readDirectory(allocator, .cwd(), path, recursive) catch |err| return failure(c, object, err);
        defer {
            for (entries) |entry| allocator.free(entry.name);
            allocator.free(entries);
        }
        const encoded = std.json.Stringify.valueAlloc(allocator, entries, .{}) catch |err| return failure(c, object, err);
        defer allocator.free(encoded);
        const result = text(c, encoded) orelse return failure(c, object, error.OutOfMemory);
        set(c, object, "entriesJSON", result);
    } else if (std.mem.eql(u8, op, "mkdir")) {
        const first = mkdir(path, recursive, 0, permissions) catch |err| return failure(c, object, err);
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

test "native directory names and kinds release partial allocations" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(io, .{ .sub_path = "actual.txt", .data = "bytes" });
    try temporary.dir.createDir(io, "nested", .default_dir);
    const Probe = struct {
        fn run(allocator: std.mem.Allocator, directory: std.Io.Dir) !void {
            const entries = try readDirectory(allocator, directory, ".", true);
            defer {
                for (entries) |entry| allocator.free(entry.name);
                allocator.free(entries);
            }
            try std.testing.expectEqual(@as(usize, 2), entries.len);
            for (entries) |entry| {
                if (std.mem.eql(u8, entry.name, "actual.txt")) try std.testing.expectEqual(.file, entry.kind) else {
                    try std.testing.expectEqualStrings("nested", entry.name);
                    try std.testing.expectEqual(.directory, entry.kind);
                }
            }
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Probe.run, .{temporary.dir});
}

test "tool file UTF-8 decoder matches the Node byte-pair oracle" {
    const reference = @import("tool_file_text_reference");
    const parsed = try std.json.parseFromSlice(struct { node: []const u8, pairs: usize, text: []const u8 }, std.testing.allocator, reference.expected, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 65536), parsed.value.pairs);
    const expected = try std.unicode.utf8ToUtf16LeAlloc(std.testing.allocator, parsed.value.text);
    defer std.testing.allocator.free(expected);
    for (expected) |*char| char.* = std.mem.littleToNative(u16, char.*);
    const actual = try decodeToolText(std.testing.allocator, reference.bytes);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualSlices(u16, expected, actual);
}

test "tool file UTF-8 decoder releases partial allocations on failure" {
    const Probe = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const actual = try decodeToolText(allocator, "\xef\xbb\xbf\x00\xf0\x9f\x9f\xa2\xed\xa0\x80suffix\xf0\x9f\x92");
            defer allocator.free(actual);
            try std.testing.expect(actual.len > 4);
            try std.testing.expectEqual(@as(u16, 0xfeff), actual[0]);
            try std.testing.expectEqual(@as(u16, 0), actual[1]);
            try std.testing.expectEqual(@as(u16, 0xfffd), actual[actual.len - 1]);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Probe.run, .{});
}

test "tool file reads preserve exact bytes at the inclusive limit and refuse larger files" {
    const allocator = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const contents = try allocator.alloc(u8, tool_file_max + 1);
    defer allocator.free(contents);
    @memset(contents, 0xff);
    contents[0] = 0;
    try temporary.dir.writeFile(io, .{ .sub_path = "at-limit", .data = contents[0..tool_file_max] });
    const actual = try readToolFile(temporary.dir, "at-limit", allocator);
    defer allocator.free(actual);
    try std.testing.expectEqualSlices(u8, contents[0..tool_file_max], actual);
    try temporary.dir.writeFile(io, .{ .sub_path = "over-limit", .data = contents });
    try std.testing.expectError(error.StreamTooLong, readToolFile(temporary.dir, "over-limit", allocator));
    try std.testing.expectError(error.FileNotFound, readToolFile(temporary.dir, "missing", allocator));
    try temporary.dir.createDir(io, "directory", .default_dir);
    try std.testing.expectError(error.IsDir, readToolFile(temporary.dir, "directory", allocator));
}
