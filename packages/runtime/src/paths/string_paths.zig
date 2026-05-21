// Copied from bun/src/paths/string_paths.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT - see ../cli/LICENSE.bun.md.

pub const windows = struct {
    pub const long_path_prefix: [4]u16 = .{ '\\', '\\', '?', '\\' };
    pub const nt_object_prefix: [4]u16 = .{ '\\', '?', '?', '\\' };
    pub const nt_unc_object_prefix: [8]u16 = .{ '\\', '?', '?', '\\', 'U', 'N', 'C', '\\' };

    pub const long_path_prefix_u8 = "\\\\?\\";
    pub const nt_object_prefix_u8 = "\\??\\";
    pub const nt_unc_object_prefix_u8 = "\\??\\UNC\\";
};

pub fn isWindowsAbsolutePathMissingDriveLetter(comptime T: type, chars: []const T) bool {
    std.debug.assert(Platform.windows.isAbsoluteT(T, chars));
    std.debug.assert(chars.len > 0);

    if (!(chars[0] == '/' or chars[0] == '\\')) {
        std.debug.assert(chars.len > 2);
        std.debug.assert(chars[1] == ':');
        return false;
    }

    if (chars.len > 4) {
        if (chars[1] == '?' and chars[2] == '?' and (chars[3] == '/' or chars[3] == '\\')) {
            return false;
        }
        if ((chars[1] == '/' or chars[1] == '\\') and
            (chars[2] == '?' or chars[2] == '.') and
            (chars[3] == '/' or chars[3] == '\\'))
        {
            return false;
        }
    }

    return windowsFilesystemRootT(T, chars).len == 1;
}

pub fn fromWPath(buf: []u8, utf16: []const u16) [:0]const u8 {
    std.debug.assert(buf.len > 0);
    const to_copy = trimPrefixComptimeType(u16, utf16, &windows.long_path_prefix);
    const written = std.unicode.utf16LeToUtf8(buf[0 .. buf.len - 1], to_copy) catch 0;
    std.debug.assert(written < buf.len);
    buf[written] = 0;
    return buf[0..written :0];
}

pub fn withoutNTPrefix(comptime T: type, path: []const T) []const T {
    if (comptime !Environment.isWindows) return path;
    if (hasPrefixComptimeType(T, path, &windows.nt_object_prefix)) return path[windows.nt_object_prefix.len..];
    if (hasPrefixComptimeType(T, path, &windows.long_path_prefix)) return path[windows.long_path_prefix.len..];
    if (hasPrefixComptimeType(T, path, &windows.nt_unc_object_prefix)) return path[windows.nt_unc_object_prefix.len..];
    return path;
}

pub fn toNTPath(wbuf: []u16, utf8: []const u8) [:0]u16 {
    if (!std.fs.path.isAbsoluteWindows(utf8)) return toWPathNormalized(wbuf, utf8);
    if (hasPrefixComptime(utf8, windows.nt_object_prefix_u8) or
        hasPrefixComptime(utf8, windows.nt_unc_object_prefix_u8))
    {
        return wbuf[0..toWPathNormalized(wbuf, utf8).len :0];
    }

    if (hasPrefixComptime(utf8, "\\\\")) {
        if (hasPrefixComptime(utf8[2..], windows.long_path_prefix_u8[2..])) {
            wbuf[0..windows.nt_object_prefix.len].* = windows.nt_object_prefix;
            return wbuf[0 .. toWPathNormalized(wbuf[windows.nt_object_prefix.len..], utf8[4..]).len + windows.nt_object_prefix.len :0];
        }
        wbuf[0..windows.nt_unc_object_prefix.len].* = windows.nt_unc_object_prefix;
        return wbuf[0 .. toWPathNormalized(wbuf[windows.nt_unc_object_prefix.len..], utf8[2..]).len + windows.nt_unc_object_prefix.len :0];
    }

    wbuf[0..windows.nt_object_prefix.len].* = windows.nt_object_prefix;
    return wbuf[0 .. toWPathNormalized(wbuf[windows.nt_object_prefix.len..], utf8).len + windows.nt_object_prefix.len :0];
}

pub fn toNTPath16(wbuf: []u16, path: []const u16) [:0]u16 {
    if (!std.fs.path.isAbsoluteWindowsWtf16(path)) return toWPathNormalized16(wbuf, path);
    if (hasPrefixComptimeType(u16, path, &windows.nt_object_prefix) or
        hasPrefixComptimeType(u16, path, &windows.nt_unc_object_prefix))
    {
        return wbuf[0..toWPathNormalized16(wbuf, path).len :0];
    }

    if (hasPrefixComptimeType(u16, path, &.{ '\\', '\\' })) {
        if (hasPrefixComptimeType(u16, path[2..], windows.long_path_prefix[2..])) {
            wbuf[0..windows.nt_object_prefix.len].* = windows.nt_object_prefix;
            return wbuf[0 .. toWPathNormalized16(wbuf[windows.nt_object_prefix.len..], path[4..]).len + windows.nt_object_prefix.len :0];
        }
        wbuf[0..windows.nt_unc_object_prefix.len].* = windows.nt_unc_object_prefix;
        return wbuf[0 .. toWPathNormalized16(wbuf[windows.nt_unc_object_prefix.len..], path[2..]).len + windows.nt_unc_object_prefix.len :0];
    }

    wbuf[0..windows.nt_object_prefix.len].* = windows.nt_object_prefix;
    return wbuf[0 .. toWPathNormalized16(wbuf[windows.nt_object_prefix.len..], path).len + windows.nt_object_prefix.len :0];
}

pub fn addNTPathPrefix(wbuf: []u16, utf16: []const u16) [:0]u16 {
    wbuf[0..windows.nt_object_prefix.len].* = windows.nt_object_prefix;
    @memcpy(wbuf[windows.nt_object_prefix.len..][0..utf16.len], utf16);
    wbuf[utf16.len + windows.nt_object_prefix.len] = 0;
    return wbuf[0 .. utf16.len + windows.nt_object_prefix.len :0];
}

pub fn addLongPathPrefix(wbuf: []u16, utf16: []const u16) [:0]u16 {
    wbuf[0..windows.long_path_prefix.len].* = windows.long_path_prefix;
    @memcpy(wbuf[windows.long_path_prefix.len..][0..utf16.len], utf16);
    wbuf[utf16.len + windows.long_path_prefix.len] = 0;
    return wbuf[0 .. utf16.len + windows.long_path_prefix.len :0];
}

pub fn addNTPathPrefixIfNeeded(wbuf: []u16, utf16: []const u16) [:0]u16 {
    if (hasPrefixComptimeType(u16, utf16, &windows.nt_object_prefix)) {
        @memcpy(wbuf[0..utf16.len], utf16);
        wbuf[utf16.len] = 0;
        return wbuf[0..utf16.len :0];
    }
    if (hasPrefixComptimeType(u16, utf16, &windows.long_path_prefix)) {
        return addNTPathPrefix(wbuf, utf16[windows.long_path_prefix.len..]);
    }
    return addNTPathPrefix(wbuf, utf16);
}

pub const toNTDir = toNTPath;

pub fn toExtendedPathNormalized(wbuf: []u16, utf8: []const u8) [:0]const u16 {
    std.debug.assert(wbuf.len > 4);
    if (hasPrefixComptime(utf8, windows.long_path_prefix_u8) or
        hasPrefixComptime(utf8, windows.nt_object_prefix_u8))
    {
        return toWPathNormalized(wbuf, utf8);
    }
    wbuf[0..4].* = windows.long_path_prefix;
    return wbuf[0 .. toWPathNormalized(wbuf[4..], utf8).len + 4 :0];
}

pub fn toWPathNormalizeAutoExtend(wbuf: []u16, utf8: []const u8) [:0]const u16 {
    if (std.fs.path.isAbsoluteWindows(utf8)) return toExtendedPathNormalized(wbuf, utf8);
    return toWPathNormalized(wbuf, utf8);
}

pub fn toWPathNormalized(wbuf: []u16, utf8: []const u8) [:0]u16 {
    var stack: [std.fs.max_path_bytes]u8 = undefined;
    var path_to_use = normalizeSlashesOnly(&stack, utf8, '\\');
    if (path_to_use.len > 3 and isSepAny(path_to_use[path_to_use.len - 1])) {
        path_to_use = path_to_use[0 .. path_to_use.len - 1];
    }
    return toWPath(wbuf, path_to_use);
}

pub fn toWPathNormalized16(wbuf: []u16, path: []const u16) [:0]u16 {
    var path_to_use = normalizeSlashesOnlyT(u16, wbuf, path, '\\', true);
    if (path_to_use.len > 3 and isSepAnyT(u16, path_to_use[path_to_use.len - 1])) {
        path_to_use = path_to_use[0 .. path_to_use.len - 1];
    }
    wbuf[path_to_use.len] = 0;
    return wbuf[0..path_to_use.len :0];
}

pub fn toPathNormalized(buf: []u8, utf8: []const u8) [:0]const u8 {
    var stack: [std.fs.max_path_bytes]u8 = undefined;
    var path_to_use = normalizeSlashesOnly(&stack, utf8, '\\');
    if (path_to_use.len > 3 and isSepAny(path_to_use[path_to_use.len - 1])) {
        path_to_use = path_to_use[0 .. path_to_use.len - 1];
    }
    return toPath(buf, path_to_use);
}

pub fn normalizeSlashesOnlyT(comptime T: type, buf: []T, path: []const T, comptime desired_slash: u8, comptime always_copy: bool) []const T {
    comptime std.debug.assert(desired_slash == '/' or desired_slash == '\\');
    const undesired_slash = if (desired_slash == '/') '\\' else '/';

    if (containsCharT(T, path, undesired_slash)) {
        @memcpy(buf[0..path.len], path);
        for (buf[0..path.len]) |*c| {
            if (c.* == undesired_slash) c.* = desired_slash;
        }
        return buf[0..path.len];
    }

    if (comptime always_copy) {
        @memcpy(buf[0..path.len], path);
        return buf[0..path.len];
    }
    return path;
}

pub fn normalizeSlashesOnly(buf: []u8, utf8: []const u8, comptime desired_slash: u8) []const u8 {
    return normalizeSlashesOnlyT(u8, buf, utf8, desired_slash, false);
}

pub fn toWPath(wbuf: []u16, utf8: []const u8) [:0]u16 {
    return toWPathMaybeDir(wbuf, utf8, false);
}

pub fn toPath(buf: []u8, utf8: []const u8) [:0]u8 {
    return toPathMaybeDir(buf, utf8, false);
}

pub fn toWDirPath(wbuf: []u16, utf8: []const u8) [:0]const u16 {
    return toWPathMaybeDir(wbuf, utf8, true);
}

pub fn toKernel32Path(wbuf: []u16, utf8: []const u8) [:0]u16 {
    const path = if (hasPrefixComptime(utf8, windows.nt_object_prefix_u8))
        utf8[windows.nt_object_prefix_u8.len..]
    else
        utf8;
    if (hasPrefixComptime(path, windows.long_path_prefix_u8)) return toWPath(wbuf, path);
    if (utf8.len > 2 and isDriveLetter(utf8[0]) and utf8[1] == ':' and isSepAny(utf8[2])) {
        wbuf[0..4].* = windows.long_path_prefix;
        const wpath = toWPath(wbuf[4..], path);
        return wbuf[0 .. wpath.len + 4 :0];
    }
    return toWPath(wbuf, path);
}

pub fn toWPathMaybeDir(wbuf: []u16, utf8: []const u8, comptime add_trailing_slash: bool) [:0]u16 {
    std.debug.assert(wbuf.len > 0);
    const written = std.unicode.utf8ToUtf16Le(wbuf[0..wbuf.len -| (1 + @as(usize, @intFromBool(add_trailing_slash)))], utf8) catch 0;
    dangerouslyConvertPathToWindowsInPlace(u16, wbuf[0..written]);

    var len = written;
    if (add_trailing_slash and len > 0 and wbuf[len - 1] != '\\') {
        wbuf[len] = '\\';
        len += 1;
    }
    wbuf[len] = 0;
    return wbuf[0..len :0];
}

pub fn toPathMaybeDir(buf: []u8, utf8: []const u8, comptime add_trailing_slash: bool) [:0]u8 {
    std.debug.assert(buf.len > 0);
    var len = utf8.len;
    @memcpy(buf[0..len], utf8);
    if (add_trailing_slash and len > 0 and buf[len - 1] != '\\') {
        buf[len] = '\\';
        len += 1;
    }
    buf[len] = 0;
    return buf[0..len :0];
}

pub fn cloneNormalizingSeparators(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const base = withoutTrailingSlash(input);
    if (base.len == 0) return allocator.dupe(u8, "");
    var tokenized = std.mem.tokenizeScalar(u8, base, std.fs.path.sep);
    var buf = try allocator.alloc(u8, base.len + 2);
    var out: usize = 0;
    if (base[0] == std.fs.path.sep) {
        buf[out] = std.fs.path.sep;
        out += 1;
    }
    while (tokenized.next()) |token| {
        if (out > 0 and buf[out - 1] != std.fs.path.sep) {
            buf[out] = std.fs.path.sep;
            out += 1;
        }
        @memcpy(buf[out..][0..token.len], token);
        out += token.len;
    }
    return buf[0..out];
}

pub fn pathContainsNodeModulesFolder(path: []const u8) bool {
    return std.mem.indexOf(u8, path, comptime std.fs.path.sep_str ++ "node_modules" ++ std.fs.path.sep_str) != null;
}

pub fn charIsAnySlash(char: u8) bool {
    return char == '/' or char == '\\';
}

pub fn startsWithWindowsDriveLetter(s: []const u8) bool {
    return startsWithWindowsDriveLetterT(u8, s);
}

pub fn startsWithWindowsDriveLetterT(comptime T: type, s: []const T) bool {
    return s.len > 2 and s[1] == ':' and isDriveLetterT(T, s[0]);
}

pub fn withoutTrailingSlash(this: string) []const u8 {
    var href = this;
    while (href.len > 1 and isSepAny(href[href.len - 1])) {
        href.len -= 1;
    }
    return href;
}

pub fn withoutTrailingSlashWindowsPath(input: string) []const u8 {
    if (Environment.isPosix or input.len < 3 or input[1] != ':') return withoutTrailingSlash(input);
    const root_len = windowsFilesystemRoot(input).len + 1;
    var path = input;
    while (path.len > root_len and isSepAny(path[path.len - 1])) {
        path.len -= 1;
    }
    return path;
}

pub fn withoutLeadingSlash(this: string) []const u8 {
    return std.mem.trimLeft(u8, this, "/");
}

pub fn withoutLeadingPathSeparator(this: string) []const u8 {
    return std.mem.trimLeft(u8, this, &.{std.fs.path.sep});
}

pub fn removeLeadingDotSlash(slice: []const u8) []const u8 {
    if (slice.len >= 2 and slice[0] == '.' and (slice[1] == '/' or (Environment.isWindows and slice[1] == '\\'))) {
        return slice[2..];
    }
    return slice;
}

pub fn basename(comptime T: type, input: []const T) []const T {
    if (comptime Environment.isWindows) return basenameWindows(T, input);
    return basenamePosix(T, input);
}

fn basenamePosix(comptime T: type, input: []const T) []const T {
    if (input.len == 0) return &.{};
    var end_index: usize = input.len - 1;
    while (input[end_index] == '/') {
        if (end_index == 0) return &.{};
        end_index -= 1;
    }
    var start_index: usize = end_index;
    end_index += 1;
    while (input[start_index] != '/') {
        if (start_index == 0) return input[0..end_index];
        start_index -= 1;
    }
    return input[start_index + 1 .. end_index];
}

fn basenameWindows(comptime T: type, input: []const T) []const T {
    if (input.len == 0) return &.{};
    var end_index: usize = input.len - 1;
    while (true) {
        const byte = input[end_index];
        if (byte == '/' or byte == '\\') {
            if (end_index == 0) return &.{};
            end_index -= 1;
            continue;
        }
        if (byte == ':' and end_index == 1) return &.{};
        break;
    }

    var start_index: usize = end_index;
    end_index += 1;
    while (input[start_index] != '/' and input[start_index] != '\\' and
        !(input[start_index] == ':' and start_index == 1))
    {
        if (start_index == 0) return input[0..end_index];
        start_index -= 1;
    }
    return input[start_index + 1 .. end_index];
}

pub fn hasPrefixComptime(input: []const u8, comptime prefix: []const u8) bool {
    return input.len >= prefix.len and std.mem.eql(u8, input[0..prefix.len], prefix);
}

fn hasPrefixComptimeType(comptime T: type, input: []const T, comptime prefix: []const u16) bool {
    if (input.len < prefix.len) return false;
    inline for (prefix, 0..) |char, i| {
        if (input[i] != @as(T, @intCast(char))) return false;
    }
    return true;
}

fn trimPrefixComptimeType(comptime T: type, input: []const T, comptime prefix: []const T) []const T {
    if (input.len >= prefix.len and std.mem.eql(T, input[0..prefix.len], prefix)) return input[prefix.len..];
    return input;
}

fn containsCharT(comptime T: type, input: []const T, needle: u8) bool {
    return std.mem.indexOfScalar(T, input, @as(T, @intCast(needle))) != null;
}

const paths = @import("./resolve_path.zig");
const Platform = paths.Platform;
const dangerouslyConvertPathToWindowsInPlace = paths.dangerouslyConvertPathToWindowsInPlace;
const isDriveLetter = paths.isDriveLetter;
const isDriveLetterT = paths.isDriveLetterT;
const isSepAny = paths.isSepAny;
const isSepAnyT = paths.isSepAnyT;
const windowsFilesystemRoot = paths.windowsFilesystemRoot;
const windowsFilesystemRootT = paths.windowsFilesystemRootT;

const string = []const u8;

const std = @import("std");
const builtin = @import("builtin");

const Environment = struct {
    const isWindows = builtin.os.tag == .windows;
    const isPosix = !isWindows;
};

test "normalizeSlashesOnly rewrites only the requested slash" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("a/b/c", normalizeSlashesOnly(&buf, "a\\b\\c", '/'));
    try std.testing.expectEqualStrings("a/b/c", normalizeSlashesOnly(&buf, "a/b/c", '/'));
}

test "basename follows platform separator semantics" {
    try std.testing.expectEqualStrings("file.txt", basename(u8, "/tmp/file.txt"));
    if (Environment.isWindows) {
        try std.testing.expectEqualStrings("file.txt", basename(u8, "C:\\tmp\\file.txt"));
    }
}
