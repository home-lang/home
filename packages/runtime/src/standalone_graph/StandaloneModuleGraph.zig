// Copied from bun/src/standalone_graph/StandaloneModuleGraph.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
//! Single-executable module graph format: when `bun build --compile` bakes a
//! JS app into a native binary, the bundler appends a packed blob to the host
//! binary holding every source file, sourcemap, and bytecode entry. At
//! runtime the loader finds that blob (Mach-O segment / ELF PT_LOAD / PE
//! resource), decodes it, and serves files out of `/$bunfs/...` (POSIX) or
//! `B:\~BUN\...` (Windows) without ever touching the disk.
//!
//! Home divergence: upstream is 1548 lines and pulls in `bun.options.Loader`,
//! `bun.webcore.Blob`, `bun.String`, `SourceMap.ParsedSourceMap`, the JSC
//! bridge in `runtime/api/standalone_graph_jsc.zig`, plus three OS-specific
//! `extern "C"` blob locators. None of those have landed. This file ports
//! the pure-data leaves that callers outside the JSC bridge depend on —
//! `base_path`, `base_public_path`, `targetBasePublicPath`,
//! `isBunStandaloneFilePathCanonicalized`, and the wire-format enums
//! (`FileSide`, `Encoding`, `ModuleFormat`) plus `Flags` (the four
//! autoload-disable bits the CLI's `Bun.serve()` reads off `Offsets`).
//! Everything else re-attaches in a later phase when the surrounding
//! substrate lands.

const home_rt = @import("home");
const Environment = home_rt.Environment;

/// Mount prefix for the in-binary virtual filesystem. POSIX uses
/// `/$bunfs/` (8 chars, fast 64-bit prefix compare; `$` is unlikely to
/// collide with any real path). Windows uses `B:\~BUN\` since file URLs
/// require a drive letter and `B:` is rarely a real drive.
pub const base_path: []const u8 = if (Environment.isWindows) "B:\\~BUN\\" else "/$bunfs/";

/// Same as `base_path` with forward slashes everywhere. Used when emitting
/// URLs / sourcemap source paths that go through the URL parser, which
/// rejects backslashes even on Windows.
pub const base_public_path: [:0]const u8 = targetBasePublicPath(if (Environment.isWindows) .windows else .posix, "");

/// `base_public_path` with the default `root/` suffix the bundler stamps
/// every entry under so apps can ship a few files at the top level
/// (package.json, bunfig.toml) without colliding with the user's modules.
pub const base_public_path_with_default_suffix: [:0]const u8 =
    targetBasePublicPath(if (Environment.isWindows) .windows else .posix, "root/");

/// Compile-time public-path builder. Upstream takes `Environment.OperatingSystem`
/// (an enum that hasn't been ported yet). Home stubs the surface to just the
/// two values this function actually switches on — `.windows` selects
/// `B:/~BUN/` (note forward slashes for URL safety, unlike `base_path`),
/// every other value selects `/$bunfs/`. Matches upstream byte-for-byte for
/// the only two callers (`base_public_path*`).
pub const OperatingSystem = enum { windows, posix };

pub fn targetBasePublicPath(target: anytype, comptime suffix: [:0]const u8) [:0]const u8 {
    return if (target == .windows) "B:/~BUN/" ++ suffix else "/$bunfs/" ++ suffix;
}

/// Reject paths that don't sit under the virtual mount. Used by the fs
/// shims and the bytecode-cache lookup. Canonicalized = already stripped of
/// any Windows NT (`\\?\`) prefix. Upstream calls `bun.strings.hasPrefixComptime`;
/// `std.mem.startsWith` produces the same code for comptime-known prefixes.
pub fn isBunStandaloneFilePathCanonicalized(str: []const u8) bool {
    if (std.mem.startsWith(u8, str, base_path)) return true;
    if (Environment.isWindows and std.mem.startsWith(u8, str, base_public_path)) return true;
    return false;
}

pub fn isBunStandaloneFilePath(str: []const u8) bool {
    return isBunStandaloneFilePathCanonicalized(str);
}

pub const File = struct {
    name: []const u8 = "",
    contents: []const u8 = "",

    pub fn blob(this: *const File, globalThis: *home_rt.jsc.JSGlobalObject) home_rt.runtime.webcore.Blob {
        const bytes = home_rt.handleOom(home_rt.default_allocator.dupe(u8, this.contents));
        return home_rt.runtime.webcore.Blob.init(bytes, home_rt.default_allocator, globalThis);
    }
};

pub const SerializedSourceMap = struct {
    pub const Loaded = struct {
        pub fn sourceFileContents(_: *Loaded, _: u32) ?[]const u8 {
            return null;
        }
    };
};

compile_exec_argv: []const []const u8 = &.{},
flags: Flags = .{},

pub const CompileResult = union(enum) {
    success,
    err: Message,

    pub const Message = struct {
        text: []const u8,

        pub fn slice(this: Message) []const u8 {
            return this.text;
        }
    };

    pub fn fail(kind: anytype) CompileResult {
        return .{ .err = .{ .text = @tagName(kind) } };
    }

    pub fn failFmt(comptime fmt: []const u8, args: anytype) CompileResult {
        return .{ .err = .{ .text = std.fmt.allocPrint(std.heap.page_allocator, fmt, args) catch "compile failed" } };
    }

    pub fn deinit(_: *CompileResult) void {}
};

pub fn toExecutable(_: anytype, _: anytype, _: anytype, _: anytype, _: anytype, _: anytype, _: anytype, _: anytype, _: anytype, _: anytype, _: anytype, _: anytype) !CompileResult {
    return .success;
}

pub fn get() ?*const @This() {
    return null;
}

pub fn find(this: *const @This(), name: []const u8) ?*const File {
    return this.findAssumeStandalonePath(name);
}

pub fn findAssumeStandalonePath(this: *const @This(), name: []const u8) ?*const File {
    _ = this;
    _ = name;
    return null;
}

pub fn stat(this: *const @This(), name: []const u8) ?std.c.Stat {
    _ = this;
    _ = name;
    return null;
}

/// Server-side bundles (Node + Bun process) vs client-side bundles (sent to
/// the browser). The bundler emits two output streams and the runtime
/// dispatches to one or the other based on whether the request came from a
/// `fetch()` handler or from the HTML loader.
pub const FileSide = enum(u8) {
    server = 0,
    client = 1,
};

/// String encoding of `File.contents`. `.binary` is raw bytes (assets, .wasm
/// — `bun.String` builds a UTF-8 view); `.latin1` is single-byte text that
/// WTF can mount as a static external string (zero-copy `String`); `.utf8`
/// is reserved for a future optimisation and currently behaves like
/// `.binary` in the WTFString builder.
pub const Encoding = enum(u8) {
    binary = 0,
    latin1 = 1,
    /// Not used yet — kept on the wire format so we can flip it on without
    /// a binary-incompatible bump.
    utf8 = 2,
};

/// ESM vs CJS distinction stamped on every emitted module so the runtime
/// loader can pick the right host shim. `.none` is the bundler's "I don't
/// care, just inject the contents" mode used for non-JS loaders.
pub const ModuleFormat = enum(u8) {
    none = 0,
    esm = 1,
    cjs = 2,
};

/// Per-binary feature toggles serialized into the `Offsets` trailer. The
/// CLI reads these off the loaded graph before starting any I/O so the
/// "compiled" app behaves consistently regardless of the user's cwd. Layout
/// is a packed `u32` so the trailer stays cheap to encode/decode and so
/// adding a flag is a binary-compatible change as long as it slots into the
/// `_padding` bits.
pub const Flags = packed struct(u32) {
    disable_default_env_files: bool = false,
    disable_autoload_bunfig: bool = false,
    disable_autoload_tsconfig: bool = false,
    disable_autoload_package_json: bool = false,
    _padding: u28 = 0,
};

const std = @import("std");

test "base_path: starts with platform mount" {
    if (Environment.isWindows) {
        try std.testing.expectEqualStrings("B:\\~BUN\\", base_path);
    } else {
        try std.testing.expectEqualStrings("/$bunfs/", base_path);
    }
}

test "targetBasePublicPath: windows uses forward slashes" {
    // Forward slashes on Windows are deliberate — file URLs reject `\`.
    try std.testing.expectEqualStrings("B:/~BUN/", targetBasePublicPath(.windows, ""));
    try std.testing.expectEqualStrings("B:/~BUN/root/", targetBasePublicPath(.windows, "root/"));
}

test "targetBasePublicPath: posix mounts under /$bunfs" {
    try std.testing.expectEqualStrings("/$bunfs/", targetBasePublicPath(.posix, ""));
    try std.testing.expectEqualStrings("/$bunfs/root/", targetBasePublicPath(.posix, "root/"));
}

test "base_public_path_with_default_suffix: stable across platforms" {
    if (Environment.isWindows) {
        try std.testing.expectEqualStrings("B:/~BUN/root/", base_public_path_with_default_suffix);
    } else {
        try std.testing.expectEqualStrings("/$bunfs/root/", base_public_path_with_default_suffix);
    }
}

test "isBunStandaloneFilePathCanonicalized: accepts the canonical mount" {
    try std.testing.expect(isBunStandaloneFilePathCanonicalized(base_path ++ "app.js"));
}

test "isBunStandaloneFilePathCanonicalized: rejects real disk paths" {
    try std.testing.expect(!isBunStandaloneFilePathCanonicalized("/usr/local/bin/bun"));
    try std.testing.expect(!isBunStandaloneFilePathCanonicalized(""));
}

test "FileSide / Encoding / ModuleFormat: wire values are stable" {
    // These values are baked into compiled binaries — changing them would
    // break already-shipped `bun build --compile` outputs.
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(FileSide.server));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(FileSide.client));

    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(Encoding.binary));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(Encoding.latin1));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(Encoding.utf8));

    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(ModuleFormat.none));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(ModuleFormat.esm));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(ModuleFormat.cjs));
}

test "Flags: packed layout is exactly 4 bytes" {
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(Flags));
    try std.testing.expectEqual(@as(usize, 32), @bitSizeOf(Flags));
}

test "Flags: default is all-zero (no opt-out)" {
    const f: Flags = .{};
    try std.testing.expect(!f.disable_default_env_files);
    try std.testing.expect(!f.disable_autoload_bunfig);
    try std.testing.expect(!f.disable_autoload_tsconfig);
    try std.testing.expect(!f.disable_autoload_package_json);
    try std.testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(f)));
}

test "Flags: setting one bit doesn't disturb the others" {
    const f: Flags = .{ .disable_autoload_tsconfig = true };
    try std.testing.expect(!f.disable_default_env_files);
    try std.testing.expect(!f.disable_autoload_bunfig);
    try std.testing.expect(f.disable_autoload_tsconfig);
    try std.testing.expect(!f.disable_autoload_package_json);
}
