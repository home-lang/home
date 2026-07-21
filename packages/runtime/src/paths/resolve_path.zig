// Copied from bun/src/paths/resolve_path.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT - see ../cli/LICENSE.bun.md.

threadlocal var parser_join_input_buffer: [MAX_PATH_BYTES * 2]u8 = undefined;
threadlocal var parser_buffer: PathBuffer = undefined;

pub fn z(input: []const u8, output: *PathBuffer) [:0]const u8 {
    if (input.len > MAX_PATH_BYTES) @panic("path too long");
    @memcpy(output[0..input.len], input);
    output[input.len] = 0;
    return output[0..input.len :0];
}

pub fn hasPlatformPathSeparators(input_path: []const u8) bool {
    if (Environment.isWindows) return std.mem.indexOfAny(u8, input_path, "\\/") != null;
    return std.mem.indexOfScalar(u8, input_path, '/') != null;
}

const ParentEqual = enum {
    parent,
    equal,
    unrelated,
};

pub fn isParentOrEqual(parent_: []const u8, child: []const u8) ParentEqual {
    var parent = parent_;
    while (parent.len > 0 and isSepAny(parent[parent.len - 1])) parent = parent[0 .. parent.len - 1];

    const contains = if (Environment.isLinux)
        std.mem.indexOf(u8, child, parent) != null
    else
        containsCaseInsensitiveASCII(child, parent);
    if (!contains) return .unrelated;

    if (child.len == parent.len) return .equal;
    if (child.len > parent.len and isSepAny(child[parent.len])) return .parent;
    return .unrelated;
}

pub fn getIfExistsLongestCommonPathGeneric(input: []const []const u8, comptime platform: Platform) ?[]const u8 {
    const value = longestCommonPathGeneric(input, platform);
    if (value.len == 0) return null;
    return value;
}

pub fn longestCommonPathGeneric(input: []const []const u8, comptime platform: Platform) []const u8 {
    if (input.len == 0) return "";
    if (input.len == 1) return input[0];

    if (platform == .windows) {
        const first_root = windowsFilesystemRoot(input[0]);
        for (input[1..]) |path| {
            if (!eqlCaseInsensitiveASCII(first_root, windowsFilesystemRoot(path))) return "";
        }
    }

    var min_length: usize = input[0].len;
    for (input[1..]) |path| min_length = @min(min_length, path.len);
    if (min_length == 0) return "";

    var index: usize = 0;
    var last_sep: ?usize = null;
    while (index < min_length) : (index += 1) {
        const c = input[0][index];
        for (input[1..]) |path| {
            const matches = if (platform == .windows)
                std.ascii.toLower(c) == std.ascii.toLower(path[index])
            else
                c == path[index];
            if (!matches) {
                if (last_sep) |sep| return input[0][0 .. sep + 1];
                return "";
            }
        }
        if (platform.isSeparator(c)) last_sep = index;
    }

    for (input) |path| {
        if (path.len > index and platform.isSeparator(path[index])) return path[0 .. index + 1];
    }

    if (index == 0) return "";
    if (last_sep) |sep| return input[0][0 .. sep + 1];
    return input[0][0..index];
}

pub fn longestCommonPath(input: []const []const u8) []const u8 {
    return longestCommonPathGeneric(input, .loose);
}

pub fn getIfExistsLongestCommonPath(input: []const []const u8) ?[]const u8 {
    return getIfExistsLongestCommonPathGeneric(input, .loose);
}

pub fn longestCommonPathWindows(input: []const []const u8) []const u8 {
    return longestCommonPathGeneric(input, .windows);
}

pub fn longestCommonPathPosix(input: []const []const u8) []const u8 {
    return longestCommonPathGeneric(input, .posix);
}

threadlocal var relative_buffers: struct {
    relative_to_common_path_buf: PathBuffer = undefined,
    relative_from_buf: PathBuffer = undefined,
    relative_to_buf: PathBuffer = undefined,
} = .{};

pub inline fn relative_to_common_path_buf() *PathBuffer {
    return &relative_buffers.relative_to_common_path_buf;
}

pub fn relativeToCommonPath(
    common_path_: []const u8,
    normalized_from_: []const u8,
    normalized_to_: []const u8,
    buf: []u8,
    comptime always_copy: bool,
    comptime platform: Platform,
) []const u8 {
    _ = common_path_;
    return relativeNormalizedBuf(buf, normalized_from_, normalized_to_, platform, always_copy);
}

pub fn relativeNormalizedBuf(buf: []u8, from: []const u8, to: []const u8, comptime platform: Platform, comptime always_copy: bool) []const u8 {
    _ = always_copy;
    if (if (platform == .windows) eqlCaseInsensitiveASCII(from, to) else std.mem.eql(u8, from, to)) return "";

    const sep = platform.separator();
    var from_parts = PathParts.init(from, platform);
    var to_parts = PathParts.init(to, platform);

    var common: usize = 0;
    while (common < from_parts.count and common < to_parts.count) : (common += 1) {
        const a = from_parts.part(common);
        const b = to_parts.part(common);
        const same = if (platform == .windows) eqlCaseInsensitiveASCII(a, b) else std.mem.eql(u8, a, b);
        if (!same) break;
    }

    var out: usize = 0;
    var i = common;
    while (i < from_parts.count) : (i += 1) {
        if (out != 0) {
            buf[out] = sep;
            out += 1;
        }
        buf[out..][0..2].* = "..".*;
        out += 2;
    }

    i = common;
    while (i < to_parts.count) : (i += 1) {
        const part = to_parts.part(i);
        if (out != 0) {
            buf[out] = sep;
            out += 1;
        }
        @memcpy(buf[out..][0..part.len], part);
        out += part.len;
    }

    if (out == 0) return "";
    return buf[0..out];
}

pub fn relativeNormalized(from: []const u8, to: []const u8, comptime platform: Platform, comptime always_copy: bool) []const u8 {
    return relativeNormalizedBuf(relative_to_common_path_buf(), from, to, platform, always_copy);
}

pub fn dirname(str: []const u8, comptime platform: Platform) []const u8 {
    if (str.len == 0) return "";
    const last_sep = platform.lastIndexOfSeparator(str) orelse {
        if (platform == .windows) return std.fs.path.diskDesignatorWindows(str);
        return "";
    };
    if (platform == .posix and last_sep == 0) return "/";
    if (last_sep == str.len - 1) return dirname(str[0 .. str.len - 1], platform);
    return str[0..last_sep];
}

pub fn dirnameW(str: []const u16) []const u16 {
    const separator = lastIndexOfSeparatorWindowsT(u16, str) orelse {
        if (str.len < 2 or str[1] != ':' or !isDriveLetterT(u16, str[0])) return &.{};
        return str[0..2];
    };
    return str[0..separator];
}

pub fn relative(from: []const u8, to: []const u8) []const u8 {
    return relativePlatform(from, to, .auto, false);
}

pub fn relativeZ(from: []const u8, to: []const u8) [:0]const u8 {
    return relativeBufZ(relative_to_common_path_buf(), from, to);
}

pub fn relativeBufZ(buf: []u8, from: []const u8, to: []const u8) [:0]const u8 {
    const rel = relativePlatformBuf(buf, from, to, .auto, true);
    buf[rel.len] = 0;
    return buf[0..rel.len :0];
}

pub fn relativePlatformBuf(buf: []u8, from: []const u8, to: []const u8, comptime platform: Platform, comptime always_copy: bool) []const u8 {
    const normalized_from = normalizeForRelative(&relative_buffers.relative_from_buf, from, platform);
    const normalized_to = normalizeForRelative(&relative_buffers.relative_to_buf, to, platform);
    return relativeNormalizedBuf(buf, normalized_from, normalized_to, platform, always_copy);
}

pub fn relativePlatform(from: []const u8, to: []const u8, comptime platform: Platform, comptime always_copy: bool) []const u8 {
    return relativePlatformBuf(relative_to_common_path_buf(), from, to, platform, always_copy);
}

pub fn relativeAlloc(allocator: std.mem.Allocator, from: []const u8, to: []const u8) ![]const u8 {
    const result = relativePlatform(from, to, .auto, false);
    return try allocator.dupe(u8, result);
}

fn normalizeForRelative(buf: []u8, input: []const u8, comptime platform: Platform) []const u8 {
    if (platform.isAbsolute(input)) return normalizeBuf(input, buf, platform);
    return normalizeBuf(input, buf, platform);
}

pub fn windowsVolumeNameLen(path: []const u8) struct { usize, usize } {
    return windowsVolumeNameLenT(u8, path);
}

pub fn windowsVolumeNameLenT(comptime T: type, path: []const T) struct { usize, usize } {
    if (path.len < 2) return .{ 0, 0 };
    if (path[1] == ':' and isDriveLetterT(T, path[0])) return .{ 2, 0 };

    if (path.len >= 5 and
        Platform.windows.isSeparatorT(T, path[0]) and
        Platform.windows.isSeparatorT(T, path[1]) and
        !Platform.windows.isSeparatorT(T, path[2]) and
        path[2] != '.')
    {
        var i: usize = 3;
        while (i < path.len and !Platform.windows.isSeparatorT(T, path[i])) : (i += 1) {}
        if (i >= path.len) return .{ 0, 0 };
        const server_end = i;
        i += 1;
        const share_start = i;
        while (i < path.len and !Platform.windows.isSeparatorT(T, path[i])) : (i += 1) {}
        if (share_start != i) return .{ i, server_end };
    }
    return .{ 0, 0 };
}

pub fn windowsVolumeName(path: []const u8) []const u8 {
    return path[0..windowsVolumeNameLen(path)[0]];
}

pub fn windowsFilesystemRoot(path: []const u8) []const u8 {
    return windowsFilesystemRootT(u8, path);
}

pub fn isDriveLetter(c: u8) bool {
    return isDriveLetterT(u8, c);
}

pub fn isDriveLetterT(comptime T: type, c: T) bool {
    return ('a' <= c and c <= 'z') or ('A' <= c and c <= 'Z');
}

pub fn hasAnyIllegalChars(maybe_path: []const u8) bool {
    if (!Environment.isWindows) return false;
    const path = if (startsWithDiskDiscriminator(maybe_path)) maybe_path[2..] else maybe_path;
    return std.mem.indexOfAny(u8, path, "<>:\"|?*") != null;
}

pub fn startsWithDiskDiscriminator(maybe_path: []const u8) bool {
    if (!Environment.isWindows) return false;
    return maybe_path.len >= 3 and
        isDriveLetter(maybe_path[0]) and
        maybe_path[1] == ':' and
        maybe_path[2] == '\\';
}

pub fn windowsFilesystemRootT(comptime T: type, path: []const T) []const T {
    if (path.len == 0) return path[0..0];
    if (path.len >= 3 and path[1] == ':' and isDriveLetterT(T, path[0]) and Platform.windows.isSeparatorT(T, path[2])) {
        return path[0..3];
    }
    const volume = windowsVolumeNameLenT(T, path)[0];
    if (volume > 0) {
        if (path.len > volume and Platform.windows.isSeparatorT(T, path[volume])) return path[0 .. volume + 1];
        return path[0..volume];
    }
    if (Platform.windows.isSeparatorT(T, path[0])) return path[0..1];
    return path[0..0];
}

pub fn isInvalidPathString(maybe_path_: []const u8) bool {
    if (!Environment.isWindows) return false;
    return std.mem.indexOfAny(u8, maybe_path_, "<>:\"|?*") != null;
}

pub fn isInvalidPathString16(maybe_path_: []const u16) bool {
    if (!Environment.isWindows) return false;
    for (maybe_path_) |char| switch (char) {
        '<', '>', ':', '"', '|', '?', '*' => return true,
        else => {},
    };
    return false;
}

pub fn normalizeStringGeneric(str: []const u8, comptime allow_above_root: bool, comptime platform: Platform) []u8 {
    return normalizeString(str, allow_above_root, platform);
}

pub fn normalizeStringGenericT(comptime T: type, str: []const T, comptime allow_above_root: bool, comptime platform: Platform) []T {
    var buf: [MAX_PATH_BYTES]T = undefined;
    return normalizeStringBufT(T, str, &buf, allow_above_root, platform, false);
}

pub fn NormalizeOptions(comptime T: type) type {
    return struct {
        allow_above_root: bool = false,
        separator: T = std.fs.path.sep,
        isSeparator: fn (T) bool = struct {
            fn call(char: T) bool {
                return if (comptime std.fs.path.sep == std.fs.path.sep_windows)
                    char == '\\' or char == '/'
                else
                    char == '/';
            }
        }.call,
        preserve_trailing_slash: bool = false,
        zero_terminate: bool = false,
        add_nt_prefix: bool = false,
    };
}

pub fn normalizeStringGenericTZ(comptime T: type, str: []const T, comptime allow_above_root: bool, comptime platform: Platform) [:0]T {
    var out = normalizeStringGenericT(T, str, allow_above_root, platform);
    out[out.len] = 0;
    return out[0..out.len :0];
}

pub const Platform = enum {
    auto,
    loose,
    posix,
    windows,
    nt,

    pub const current: Platform = switch (Environment.os) {
        .windows => .windows,
        else => .posix,
    };

    pub fn separator(comptime platform: Platform) u8 {
        return switch (platform) {
            .auto => Platform.current.separator(),
            .loose, .posix => '/',
            .windows, .nt => '\\',
        };
    }

    pub fn isAbsolute(comptime platform: Platform, path: []const u8) bool {
        return switch (platform) {
            .auto => Platform.current.isAbsolute(path),
            .loose => std.fs.path.isAbsolutePosix(path) or std.fs.path.isAbsoluteWindows(path),
            .posix => std.fs.path.isAbsolutePosix(path),
            .windows, .nt => std.fs.path.isAbsoluteWindows(path),
        };
    }

    pub fn isAbsoluteT(comptime platform: Platform, comptime T: type, path: []const T) bool {
        if (T == u8) return platform.isAbsolute(path);
        return switch (platform) {
            .auto => Platform.current.isAbsoluteT(T, path),
            .loose => (path.len > 0 and path[0] == '/') or Platform.windows.isAbsoluteT(T, path),
            .posix => path.len > 0 and path[0] == '/',
            .windows, .nt => std.fs.path.isAbsoluteWindowsWtf16(path),
        };
    }

    pub fn isSeparator(comptime platform: Platform, char: u8) bool {
        return switch (platform) {
            .auto => Platform.current.isSeparator(char),
            .loose => isSepAny(char),
            .posix => isSepPosix(char),
            .windows, .nt => isSepWin32(char),
        };
    }

    pub fn isSeparatorT(comptime platform: Platform, comptime T: type, char: T) bool {
        return switch (platform) {
            .auto => Platform.current.isSeparatorT(T, char),
            .loose => isSepAnyT(T, char),
            .posix => isSepPosixT(T, char),
            .windows, .nt => isSepWin32T(T, char),
        };
    }

    pub fn lastIndexOfSeparator(comptime platform: Platform, str: []const u8) ?usize {
        return switch (platform) {
            .auto => Platform.current.lastIndexOfSeparator(str),
            .loose => lastIndexOfSeparatorLoose(str),
            .posix => lastIndexOfSeparatorPosix(str),
            .windows, .nt => lastIndexOfSeparatorWindows(str),
        };
    }
};

pub fn normalizeString(str: []const u8, comptime allow_above_root: bool, comptime platform: Platform) []u8 {
    return normalizeStringBuf(str, &parser_buffer, allow_above_root, platform, false);
}

pub fn normalizeStringZ(str: []const u8, comptime allow_above_root: bool, comptime platform: Platform) [:0]u8 {
    const out = normalizeString(str, allow_above_root, platform);
    out[out.len] = 0;
    return out[0..out.len :0];
}

pub fn normalizeBuf(str: []const u8, buf: []u8, comptime platform: Platform) []u8 {
    return normalizeStringBuf(str, buf, true, platform, false);
}

pub fn normalizeBufZ(str: []const u8, buf: []u8, comptime platform: Platform) [:0]u8 {
    const out = normalizeBuf(str, buf, platform);
    buf[out.len] = 0;
    return buf[0..out.len :0];
}

pub fn normalizeBufT(comptime T: type, str: []const T, buf: []T, comptime platform: Platform) []T {
    return normalizeStringBufT(T, str, buf, true, platform, false);
}

pub fn normalizeStringBuf(
    str: []const u8,
    buf: []u8,
    comptime allow_above_root: bool,
    comptime platform: Platform,
    comptime preserve_trailing_slash: bool,
) []u8 {
    return normalizeStringBufT(u8, str, buf, allow_above_root, platform, preserve_trailing_slash);
}

pub fn normalizeStringBufT(
    comptime T: type,
    str: []const T,
    buf: []T,
    comptime allow_above_root: bool,
    comptime platform_: Platform,
    comptime preserve_trailing_slash_: bool,
) []T {
    const platform = comptime if (platform_ == .auto) Platform.current else platform_;
    const preserve_trailing_slash = preserve_trailing_slash_ or str.len > 0 and platform.isSeparatorT(T, str[str.len - 1]);
    const sep: T = @intCast(platform.separator());

    if (str.len == 0) {
        buf[0] = '.';
        return buf[0..1];
    }

    const root_len = rootLenT(T, str, platform);
    const had_trailing_slash = str.len > root_len and platform.isSeparatorT(T, str[str.len - 1]);
    var out: usize = 0;
    if (root_len > 0) {
        // `str` may alias `buf` (in-place normalize from joinStringBufT); a
        // self-`@memcpy` would overlap, so skip it when they share storage.
        if (@intFromPtr(str.ptr) != @intFromPtr(buf.ptr)) @memcpy(buf[0..root_len], str[0..root_len]);
        if (platform == .windows) {
            for (buf[0..root_len]) |*char| {
                if (char.* == '/') char.* = '\\';
            }
        }
        out = root_len;
    }

    // Trim a trailing separator the root may have left before appending
    // segments (the pre-write trim from the original parts-array version).
    if (root_len > 0 and out > 1 and platform.isSeparatorT(T, buf[out - 1])) {
        out -= 1;
    }

    // Write normalized segments straight into `buf`, popping on `..` by
    // scanning back to the previous separator. The previous version collected
    // segment slices into a fixed `[256]` array and @panic'd past it, which
    // crashed on pathologically deep relative paths (e.g. resolving thousands
    // of `..` for `pathToFileURL` of a >PATH_MAX path).
    const seg_base = out;
    var i = root_len;
    while (i <= str.len) {
        while (i < str.len and platform.isSeparatorT(T, str[i])) i += 1;
        const start = i;
        while (i < str.len and !platform.isSeparatorT(T, str[i])) i += 1;
        if (i == start) break;
        const part = str[start..i];
        if (part.len == 1 and part[0] == '.') continue;
        if (part.len == 2 and part[0] == '.' and part[1] == '.') {
            if (out > seg_base) {
                // Find the start of the last written segment.
                var s = out;
                while (s > seg_base and !platform.isSeparatorT(T, buf[s - 1])) s -= 1;
                if (isDotDot(T, buf[s..out])) {
                    // Can't pop a `..`; keep it and append another (above-root
                    // relative paths only — a rooted path never leads with `..`).
                    if (allow_above_root and root_len == 0) {
                        if (out != 0 and !platform.isSeparatorT(T, buf[out - 1])) {
                            buf[out] = sep;
                            out += 1;
                        }
                        buf[out] = '.';
                        buf[out + 1] = '.';
                        out += 2;
                    }
                } else {
                    // Pop the segment, plus the joining separator before it
                    // unless that separator belongs to the root.
                    out = if (s > seg_base) s - 1 else seg_base;
                }
            } else if (allow_above_root and root_len == 0) {
                if (out != 0 and !platform.isSeparatorT(T, buf[out - 1])) {
                    buf[out] = sep;
                    out += 1;
                }
                buf[out] = '.';
                buf[out + 1] = '.';
                out += 2;
            }
            continue;
        }
        if (out != 0 and !platform.isSeparatorT(T, buf[out - 1])) {
            buf[out] = sep;
            out += 1;
        }
        for (part) |char| {
            buf[out] = if (platform == .windows and char == '/') '\\' else char;
            out += 1;
        }
    }

    if (out == 0) {
        if (root_len > 0) {
            buf[0] = sep;
            out = 1;
        } else {
            buf[0] = '.';
            out = 1;
        }
    } else if (root_len > 0 and out == root_len - 1) {
        buf[out] = sep;
        out += 1;
    }

    if (preserve_trailing_slash and had_trailing_slash and out > 0 and !platform.isSeparatorT(T, buf[out - 1])) {
        buf[out] = sep;
        out += 1;
    }

    return buf[0..out];
}

pub fn normalizeStringAlloc(allocator: std.mem.Allocator, str: []const u8, comptime allow_above_root: bool, comptime platform: Platform) ![]const u8 {
    const buf = try allocator.alloc(u8, str.len + 4);
    const normalized = normalizeStringBuf(str, buf, allow_above_root, platform, false);
    return allocator.resize(buf, normalized.len) orelse normalized;
}

pub fn joinAbs2(_cwd: []const u8, comptime platform: Platform, part: anytype, part2: anytype) []const u8 {
    return joinAbsString(_cwd, &[_][]const u8{ part, part2 }, platform);
}

pub fn joinAbs(cwd: []const u8, comptime platform: Platform, part: []const u8) []const u8 {
    return joinAbsString(cwd, &[_][]const u8{part}, platform);
}

pub fn joinAbsString(_cwd: []const u8, parts: anytype, comptime platform: Platform) []const u8 {
    return joinAbsStringBuf(_cwd, &parser_buffer, parts, platform);
}

pub fn joinAbsStringZ(_cwd: []const u8, parts: anytype, comptime platform: Platform) [:0]const u8 {
    return joinAbsStringBufZ(_cwd, &parser_buffer, parts, platform);
}

pub fn join(_parts: anytype, comptime platform: Platform) []const u8 {
    return joinStringBuf(&parser_buffer, _parts, platform);
}

pub fn joinZ(_parts: anytype, comptime platform: Platform) [:0]const u8 {
    return joinZBuf(&parser_buffer, _parts, platform);
}

pub fn joinZBuf(buf: []u8, _parts: anytype, comptime platform: Platform) [:0]const u8 {
    const joined = joinStringBuf(buf, _parts, platform);
    buf[joined.len] = 0;
    return buf[0..joined.len :0];
}

pub fn joinStringBuf(buf: []u8, parts: anytype, comptime platform: Platform) []const u8 {
    return joinStringBufT(u8, buf, parts, platform);
}

pub fn joinStringBufW(buf: []u16, parts: anytype, comptime platform: Platform) []const u16 {
    return joinStringBufT(u16, buf, parts, platform);
}

pub fn joinStringBufWZ(buf: []u16, parts: anytype, comptime platform: Platform) [:0]const u16 {
    const joined = joinStringBufW(buf, parts, platform);
    buf[joined.len] = 0;
    return buf[0..joined.len :0];
}

pub fn joinStringBufZ(buf: []u8, parts: anytype, comptime platform: Platform) [:0]const u8 {
    const joined = joinStringBuf(buf, parts, platform);
    buf[joined.len] = 0;
    return buf[0..joined.len :0];
}

pub fn joinStringBufT(comptime T: type, buf: []T, parts: anytype, comptime platform: Platform) []const T {
    // Concatenate the parts directly into the caller's `buf`, then normalize
    // in place. The previous version concatenated into a fixed
    // `[MAX_PATH_BYTES * 2]` stack buffer, which OVERFLOWED for inputs longer
    // than ~2*PATH_MAX (e.g. resolving a >PATH_MAX path for `pathToFileURL`).
    // `normalizeStringBufT` only ever shrinks (its write index never passes the
    // read index), so normalizing `buf` into `buf` is safe.
    var written: usize = 0;
    const sep: T = @intCast(platform.separator());
    for (parts) |part| {
        if (part.len == 0) continue;
        if (written != 0 and !platform.isSeparatorT(T, buf[written - 1])) {
            buf[written] = sep;
            written += 1;
        }
        @memcpy(buf[written..][0..part.len], part);
        written += part.len;
    }
    if (written == 0) {
        buf[0] = '.';
        return buf[0..1];
    }
    return normalizeStringBufT(T, buf[0..written], buf, true, platform, true);
}

pub fn joinAbsStringBuf(cwd: []const u8, buf: []u8, _parts: anytype, comptime platform: Platform) []const u8 {
    const parts_len = partsLen(_parts);
    if (parts_len == 0) return normalizeBuf(cwd, buf, platform);

    var absolute_index: ?usize = null;
    var index: usize = 0;
    while (index < parts_len) : (index += 1) {
        const part = partAt(_parts, index);
        if (part.len > 0 and platform.isAbsolute(part)) absolute_index = index;
    }
    if (absolute_index) |abs_index| {
        var temp_abs_parts_buf: [64][]const u8 = undefined;
        var count: usize = 0;
        var part_index = abs_index;
        while (part_index < parts_len) : (part_index += 1) {
            temp_abs_parts_buf[count] = partAt(_parts, part_index);
            count += 1;
        }
        return joinStringBuf(buf, temp_abs_parts_buf[0..count], platform);
    }

    var temp_parts_buf: [64][]const u8 = undefined;
    var count: usize = 0;
    temp_parts_buf[count] = cwd;
    count += 1;
    index = 0;
    while (index < parts_len) : (index += 1) {
        temp_parts_buf[count] = partAt(_parts, index);
        count += 1;
    }
    return joinStringBuf(buf, temp_parts_buf[0..count], platform);
}

fn partsLen(parts: anytype) usize {
    const Parts = @TypeOf(parts);
    return switch (@typeInfo(Parts)) {
        .pointer => |ptr| switch (ptr.size) {
            .one => switch (@typeInfo(ptr.child)) {
                .array => parts.*.len,
                .@"struct" => |info| info.field_names.len,
                else => @compileError("unsupported path parts pointer"),
            },
            .slice => parts.len,
            else => @compileError("unsupported path parts pointer"),
        },
        .array => parts.len,
        else => @compileError("unsupported path parts type"),
    };
}

fn partAt(parts: anytype, index: usize) []const u8 {
    const Parts = @TypeOf(parts);
    return switch (@typeInfo(Parts)) {
        .pointer => |ptr| switch (ptr.size) {
            .one => switch (@typeInfo(ptr.child)) {
                .array => parts.*[index],
                .@"struct" => |info| inline for (info.field_names, 0..) |fname, field_index| {
                    if (index == field_index) return @field(parts.*, fname);
                } else unreachable,
                else => @compileError("unsupported path parts pointer"),
            },
            .slice => parts[index],
            else => @compileError("unsupported path parts pointer"),
        },
        .array => parts[index],
        else => @compileError("unsupported path parts type"),
    };
}

pub fn joinAbsStringBufChecked(cwd: []const u8, buf: []u8, parts: []const []const u8, comptime platform: Platform) ?[]const u8 {
    const total = joinedLength(cwd, parts);
    if (total >= buf.len) return null;
    return joinAbsStringBuf(cwd, buf, parts, platform);
}

pub fn joinAbsStringBufZ(cwd: []const u8, buf: []u8, _parts: anytype, comptime platform: Platform) [:0]const u8 {
    const joined = joinAbsStringBuf(cwd, buf, _parts, platform);
    buf[joined.len] = 0;
    return buf[0..joined.len :0];
}

pub fn joinAbsStringBufZNT(cwd: []const u8, buf: []u8, _parts: anytype, comptime platform: Platform) [:0]const u8 {
    return joinAbsStringBufZ(cwd, buf, _parts, platform);
}

pub fn joinAbsStringBufZTrailingSlash(cwd: []const u8, buf: []u8, _parts: anytype, comptime platform: Platform) [:0]const u8 {
    const joined = joinAbsStringBuf(cwd, buf, _parts, platform);
    var len = joined.len;
    const sep = platform.separator();
    if (len == 0 or !platform.isSeparator(buf[len - 1])) {
        buf[len] = sep;
        len += 1;
    }
    buf[len] = 0;
    return buf[0..len :0];
}

fn joinedLength(cwd: []const u8, parts: []const []const u8) usize {
    var total = cwd.len;
    for (parts) |part| total += part.len + 1;
    return total;
}

pub fn isSepPosix(char: u8) bool {
    return char == '/';
}

pub fn isSepPosixT(comptime T: type, char: T) bool {
    return char == '/';
}

pub fn isSepWin32(char: u8) bool {
    return char == '/' or char == '\\';
}

pub fn isSepWin32T(comptime T: type, char: T) bool {
    return char == '/' or char == '\\';
}

pub fn isSepAny(char: u8) bool {
    return isSepPosix(char) or isSepWin32(char);
}

pub fn isSepAnyT(comptime T: type, char: T) bool {
    return isSepPosixT(T, char) or isSepWin32T(T, char);
}

pub fn lastIndexOfSeparatorPosix(str: []const u8) ?usize {
    return lastIndexOfSeparatorPosixT(u8, str);
}

pub fn lastIndexOfSeparatorPosixT(comptime T: type, str: []const T) ?usize {
    return std.mem.lastIndexOfScalar(T, str, '/');
}

pub fn lastIndexOfSeparatorWindows(str: []const u8) ?usize {
    var i = str.len;
    while (i > 0) {
        i -= 1;
        if (isSepWin32(str[i])) return i;
    }
    return null;
}

pub fn lastIndexOfSeparatorWindowsT(comptime T: type, str: []const T) ?usize {
    var i = str.len;
    while (i > 0) {
        i -= 1;
        if (isSepWin32T(T, str[i])) return i;
    }
    return null;
}

pub fn lastIndexOfSeparatorLoose(str: []const u8) ?usize {
    return lastIndexOfSeparatorLooseT(u8, str);
}

pub fn lastIndexOfNonSeparatorPosix(slice: []const u8) ?u32 {
    var i: usize = slice.len;
    while (i != 0) {
        i -= 1;
        if (slice[i] != std.fs.path.sep_posix) return @intCast(i);
    }
    return null;
}

pub fn lastIndexOfSeparatorLooseT(comptime T: type, str: []const T) ?usize {
    var i = str.len;
    while (i > 0) {
        i -= 1;
        if (isSepAnyT(T, str[i])) return i;
    }
    return null;
}

pub fn normalizeStringLooseBuf(str: []const u8, buf: []u8) []u8 {
    return normalizeStringBuf(str, buf, true, .loose, false);
}

pub fn normalizeStringLooseBufT(comptime T: type, str: []const T, buf: []T) []T {
    return normalizeStringBufT(T, str, buf, true, .loose, false);
}

pub fn normalizeStringWindows(str: []const u8) []u8 {
    return normalizeString(str, true, .windows);
}

pub fn normalizeStringWindowsT(comptime T: type, str: []const T) []T {
    return normalizeStringGenericT(T, str, true, .windows);
}

pub fn normalizeStringNode(str: []const u8, comptime platform: Platform) []u8 {
    return normalizeString(str, false, platform);
}

pub fn normalizeStringNodeT(comptime T: type, str: []const T, comptime platform: Platform) []T {
    return normalizeStringGenericT(T, str, false, platform);
}

pub fn basename(path: []const u8) []const u8 {
    if (path.len == 0) return &[_]u8{};

    var end_index: usize = path.len - 1;
    while (isSepAny(path[end_index])) {
        if (end_index == 0) return "/";
        end_index -= 1;
    }

    var start_index: usize = end_index;
    end_index += 1;
    while (!isSepAny(path[start_index])) {
        if (start_index == 0) return path[0..end_index];
        start_index -= 1;
    }

    return path[start_index + 1 .. end_index];
}

pub fn lastIndexOfSep(path: []const u8) ?usize {
    return lastIndexOfSepT(u8, path);
}

pub fn lastIndexOfSepT(comptime T: type, path: []const T) ?usize {
    if (comptime !Environment.isWindows) return std.mem.lastIndexOfScalar(T, path, '/');
    return std.mem.lastIndexOfAny(T, path, "/\\");
}

pub fn nextDirname(path_: []const u8) ?[]const u8 {
    const path = path_;
    var root_prefix: []const u8 = "";
    if (path.len > 3 and path[1] == ':' and isSepAny(path[2])) {
        root_prefix = path[0..3];
    }

    if (path.len == 0) return if (root_prefix.len > 0) root_prefix else null;

    var end_index: usize = path.len - 1;
    while (isSepAny(path[end_index])) {
        if (end_index == 0) return if (root_prefix.len > 0) root_prefix else null;
        end_index -= 1;
    }

    while (!isSepAny(path[end_index])) {
        if (end_index == 0) return if (root_prefix.len > 0) root_prefix else null;
        end_index -= 1;
    }

    if (end_index == 0 and isSepAny(path[0])) return path[0..1];
    if (end_index == 0) return if (root_prefix.len > 0) root_prefix else null;
    return path[0 .. end_index + 1];
}

pub const PosixToWinNormalizer = struct {
    buf: PathBuffer = undefined,

    pub fn resolve(this: *@This(), maybe_posix_path: []const u8) []const u8 {
        return this.resolveCWD(maybe_posix_path);
    }

    pub fn resolveZ(this: *@This(), source_dir: []const u8, maybe_posix_path: [:0]const u8) [:0]const u8 {
        if (comptime !Environment.isWindows) return maybe_posix_path;
        const joined = joinAbsStringBufZ(source_dir, &this.buf, &.{maybe_posix_path}, .auto);
        return this.resolveCWDWithExternalBufZ(joined, &this.buf);
    }

    // On POSIX an absolute posix path is already the platform path — return it
    // unchanged (faithful to upstream, whose normalizer body is gated entirely
    // behind `if (isWindows)` and otherwise returns `maybe_posix_path`). The
    // previous unconditional posix→`\` conversion corrupted every resolve
    // source dir on macOS, tripping `assert(isAbsolute(source_dir))`.
    pub fn resolveCWD(this: *@This(), maybe_posix_path: []const u8) []const u8 {
        if (comptime !Environment.isWindows) return maybe_posix_path;
        return posixToWinBuf(u8, maybe_posix_path, &this.buf);
    }

    pub fn resolveCWDWithExternalBuf(_: *@This(), maybe_posix_path: []const u8, buf: *PathBuffer) []const u8 {
        if (comptime !Environment.isWindows) return maybe_posix_path;
        return posixToWinBuf(u8, maybe_posix_path, buf);
    }

    pub fn resolveCWDWithExternalBufZ(this: *@This(), maybe_posix_path: []const u8, buf: *PathBuffer) [:0]const u8 {
        const out = this.resolveCWDWithExternalBuf(maybe_posix_path, buf);
        // `out` may alias `maybe_posix_path` (POSIX no-op); copy into `buf` so the
        // null terminator lands on the returned buffer rather than past the input.
        if (@intFromPtr(out.ptr) != @intFromPtr(buf)) @memcpy(buf[0..out.len], out);
        buf[out.len] = 0;
        return buf[0..out.len :0];
    }
};

pub fn pathToPosixBuf(comptime T: type, path: []const T, buf: []T) []T {
    var idx: usize = 0;
    while (idx < path.len) : (idx += 1) {
        buf[idx] = if (path[idx] == '\\') '/' else path[idx];
    }
    return buf[0..path.len];
}

pub fn platformToPosixInPlace(comptime T: type, path_buffer: []T) void {
    if (std.fs.path.sep == '/') return;
    for (path_buffer) |*char| {
        if (char.* == std.fs.path.sep) char.* = '/';
    }
}

pub fn dangerouslyConvertPathToPosixInPlace(comptime T: type, path: []T) void {
    if (comptime Environment.isWindows) {
        if (path.len > "C:".len and isDriveLetterT(T, path[0]) and path[1] == ':' and isSepAnyT(T, path[2])) {
            if (path[0] >= 'a' and path[0] <= 'z') {
                path[0] = @intCast('A' + (path[0] - 'a'));
            }
        }
    }

    for (path) |*char| {
        if (char.* == std.fs.path.sep_windows) char.* = '/';
    }
}

pub fn dangerouslyConvertPathToWindowsInPlace(comptime T: type, path: []T) void {
    for (path) |*char| {
        if (char.* == std.fs.path.sep_posix) char.* = '\\';
    }
}

pub fn platformToPosixBuf(comptime T: type, path: []const T, buf: []T) []const T {
    if (std.fs.path.sep == '/') return path;
    return pathToPosixBuf(T, path, buf);
}

pub fn posixToPlatformInPlace(comptime T: type, path_buffer: []T) void {
    if (std.fs.path.sep == '/') return;
    for (path_buffer) |*char| {
        if (char.* == '/') char.* = std.fs.path.sep;
    }
}

fn posixToWinBuf(comptime T: type, path: []const T, buf: []T) []T {
    for (path, 0..) |char, i| buf[i] = if (char == '/') '\\' else char;
    return buf[0..path.len];
}

fn rootLenT(comptime T: type, path: []const T, comptime platform: Platform) usize {
    if (path.len == 0) return 0;
    return switch (platform) {
        .auto => rootLenT(T, path, Platform.current),
        .loose => if (path[0] == '/') 1 else windowsFilesystemRootT(T, path).len,
        .posix => if (path[0] == '/') 1 else 0,
        .windows, .nt => windowsFilesystemRootT(T, path).len,
    };
}

fn isDotDot(comptime T: type, part: []const T) bool {
    return part.len == 2 and part[0] == '.' and part[1] == '.';
}

fn containsCaseInsensitiveASCII(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (eqlCaseInsensitiveASCII(haystack[i..][0..needle.len], needle)) return true;
    }
    return false;
}

fn eqlCaseInsensitiveASCII(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ac, bc| {
        if (std.ascii.toLower(ac) != std.ascii.toLower(bc)) return false;
    }
    return true;
}

const PathParts = struct {
    path: []const u8,
    starts: [256]usize = undefined,
    lens: [256]usize = undefined,
    count: usize = 0,

    fn init(path: []const u8, comptime platform: Platform) PathParts {
        var self = PathParts{ .path = path };
        const root_len = rootLenT(u8, path, platform);
        var i = root_len;
        while (i <= path.len) {
            while (i < path.len and platform.isSeparator(path[i])) i += 1;
            const start = i;
            while (i < path.len and !platform.isSeparator(path[i])) i += 1;
            if (i == start) break;
            self.starts[self.count] = start;
            self.lens[self.count] = i - start;
            self.count += 1;
        }
        return self;
    }

    fn part(self: *const PathParts, index: usize) []const u8 {
        return self.path[self.starts[index]..][0..self.lens[index]];
    }
};

const MAX_PATH_BYTES = @import("./paths.zig").MAX_PATH_BYTES;
const PathBuffer = @import("./paths.zig").PathBuffer;

const std = @import("std");
const builtin = @import("builtin");

const Environment = struct {
    const isWindows = builtin.os.tag == .windows;
    const isLinux = builtin.os.tag == .linux;
    const os: enum { windows, mac, linux, other } = switch (builtin.os.tag) {
        .windows => .windows,
        .macos => .mac,
        .linux => .linux,
        else => .other,
    };
};

test "normalizeStringBuf normalizes posix dot segments" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("/a/c/", normalizeStringBuf("/a//b/../c/", &buf, true, .posix, false));
    try std.testing.expectEqualStrings("a/b", normalizeStringBuf("./a//b", &buf, true, .posix, false));
    try std.testing.expectEqualStrings("../../a", normalizeStringBuf("../../a", &buf, true, .posix, false));
}

test "joinStringBuf joins and normalizes" {
    var buf: [128]u8 = undefined;
    const parts = [_][]const u8{ "/tmp", "a", "..", "b/" };
    try std.testing.expectEqualStrings("/tmp/b/", joinStringBuf(&buf, &parts, .posix));
}

test "absolute detection covers posix and windows" {
    try std.testing.expect(Platform.posix.isAbsolute("/tmp"));
    try std.testing.expect(!Platform.posix.isAbsolute("tmp"));
    try std.testing.expect(Platform.windows.isAbsolute("C:\\tmp"));
    try std.testing.expect(Platform.windows.isAbsolute("\\\\server\\share\\tmp"));
    try std.testing.expect(!Platform.windows.isAbsolute("C:tmp"));
}

test "PosixToWinNormalizer leaves absolute posix paths untouched" {
    if (Environment.isWindows) return error.SkipZigTest;
    var norm: PosixToWinNormalizer = .{};
    // resolveCWD must NOT convert '/' to '\\' on POSIX — the result has to stay
    // an absolute posix path so the resolver's isAbsolute(source_dir) assert holds.
    const out = norm.resolveCWD("/private/tmp/vmtest");
    try std.testing.expectEqualStrings("/private/tmp/vmtest", out);
    try std.testing.expect(std.fs.path.isAbsolute(out));

    var buf: PathBuffer = undefined;
    const outz = norm.resolveCWDWithExternalBufZ("/a/b/c", &buf);
    try std.testing.expectEqualStrings("/a/b/c", outz);
    try std.testing.expect(outz[outz.len] == 0);
}

test "joinAbsStringBuf respects absolute child" {
    var buf: [128]u8 = undefined;
    const rel = [_][]const u8{ "src", "main.zig" };
    try std.testing.expectEqualStrings("/repo/src/main.zig", joinAbsStringBuf("/repo", &buf, &rel, .posix));

    const abs = [_][]const u8{ "/override", "file.zig" };
    try std.testing.expectEqualStrings("/override/file.zig", joinAbsStringBuf("/repo", &buf, &abs, .posix));
}

test "public path helpers mirror Bun pure behavior" {
    try std.testing.expect(isDriveLetter('C'));
    try std.testing.expect(isDriveLetter('z'));
    try std.testing.expect(!isDriveLetter('7'));

    try std.testing.expectEqual(@as(?usize, 4), lastIndexOfSeparatorPosix("/tmp/file"));
    try std.testing.expectEqual(@as(?usize, 3), lastIndexOfSeparatorLoose("a\\b/c"));
    try std.testing.expectEqual(@as(?u32, 2), lastIndexOfNonSeparatorPosix("foo///"));
    try std.testing.expectEqual(@as(?u32, null), lastIndexOfNonSeparatorPosix("///"));

    try std.testing.expectEqualStrings("file.txt", basename("/tmp/file.txt"));
    try std.testing.expectEqualStrings("/", basename("/"));
    try std.testing.expectEqualStrings("/a/b/", nextDirname("/a/b/c").?);
    try std.testing.expectEqual(@as(?[]const u8, null), nextDirname("/"));

    var path_buf = [_]u8{ 'a', '/', 'b', '\\', 'c' };
    dangerouslyConvertPathToWindowsInPlace(u8, &path_buf);
    try std.testing.expectEqualSlices(u8, "a\\b\\c", &path_buf);
    dangerouslyConvertPathToPosixInPlace(u8, &path_buf);
    try std.testing.expectEqualSlices(u8, "a/b/c", &path_buf);
}
