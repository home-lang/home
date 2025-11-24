// Home Programming Language - Dynamic Library Loading
// Cross-platform dynamic library (shared object) loading

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

// ============================================================================
// Platform-specific types
// ============================================================================

const DlHandle = switch (builtin.os.tag) {
    .windows => std.os.windows.HMODULE,
    else => *anyopaque, // Unix: void*
};

// ============================================================================
// Dynamic Library
// ============================================================================

pub const DynLib = struct {
    handle: DlHandle,
    path: []const u8,
    allocator: Allocator,

    /// Open a dynamic library
    pub fn open(allocator: Allocator, path: []const u8) !DynLib {
        const handle = try openPlatform(path);
        const owned_path = try allocator.dupe(u8, path);

        return DynLib{
            .handle = handle,
            .path = owned_path,
            .allocator = allocator,
        };
    }

    /// Close the dynamic library
    pub fn close(self: *DynLib) void {
        closePlatform(self.handle);
        self.allocator.free(self.path);
    }

    /// Look up a symbol by name
    pub fn lookup(self: *DynLib, comptime T: type, symbol: []const u8) !T {
        const ptr = try lookupPlatform(self.handle, symbol);
        return @as(T, @ptrCast(@alignCast(ptr)));
    }

    /// Check if a symbol exists
    pub fn hasSymbol(self: *DynLib, symbol: []const u8) bool {
        _ = lookupPlatform(self.handle, symbol) catch return false;
        return true;
    }
};

// ============================================================================
// Platform-specific implementations
// ============================================================================

// Unix/POSIX (Linux, macOS, BSD)
fn openPlatform(path: []const u8) !DlHandle {
    if (builtin.os.tag == .windows) {
        return openWindows(path);
    } else {
        return openUnix(path);
    }
}

fn closePlatform(handle: DlHandle) void {
    if (builtin.os.tag == .windows) {
        closeWindows(handle);
    } else {
        closeUnix(handle);
    }
}

fn lookupPlatform(handle: DlHandle, symbol: []const u8) !*anyopaque {
    if (builtin.os.tag == .windows) {
        return lookupWindows(handle, symbol);
    } else {
        return lookupUnix(handle, symbol);
    }
}

// ============================================================================
// Unix Implementation (dlopen/dlsym)
// ============================================================================

const RTLD_LAZY = 0x00001;
const RTLD_NOW = 0x00002;
const RTLD_GLOBAL = 0x00100;
const RTLD_LOCAL = 0x00000;

extern "c" fn dlopen(filename: [*:0]const u8, flags: c_int) ?*anyopaque;
extern "c" fn dlsym(handle: *anyopaque, symbol: [*:0]const u8) ?*anyopaque;
extern "c" fn dlclose(handle: *anyopaque) c_int;
extern "c" fn dlerror() ?[*:0]const u8;

fn openUnix(path: []const u8) !DlHandle {
    // Convert to null-terminated string
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len >= path_buf.len) return error.NameTooLong;

    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;

    const handle = dlopen(path_buf[0..path.len :0], RTLD_LAZY | RTLD_LOCAL) orelse {
        return error.LibraryNotFound;
    };

    return handle;
}

fn closeUnix(handle: DlHandle) void {
    _ = dlclose(handle);
}

fn lookupUnix(handle: DlHandle, symbol: []const u8) !*anyopaque {
    // Convert to null-terminated string
    var symbol_buf: [1024]u8 = undefined;
    if (symbol.len >= symbol_buf.len) return error.SymbolNameTooLong;

    @memcpy(symbol_buf[0..symbol.len], symbol);
    symbol_buf[symbol.len] = 0;

    // Clear previous errors
    _ = dlerror();

    const ptr = dlsym(handle, symbol_buf[0..symbol.len :0]) orelse {
        return error.SymbolNotFound;
    };

    return ptr;
}

// ============================================================================
// Windows Implementation (LoadLibrary/GetProcAddress)
// ============================================================================

fn openWindows(path: []const u8) !DlHandle {
    const windows = std.os.windows;

    // Convert to wide string
    var path_w: [windows.PATH_MAX_WIDE]u16 = undefined;
    const len = try std.unicode.utf8ToUtf16Le(&path_w, path);
    path_w[len] = 0;

    const handle = windows.kernel32.LoadLibraryW(path_w[0..len :0]) orelse {
        return error.LibraryNotFound;
    };

    return handle;
}

fn closeWindows(handle: DlHandle) void {
    const windows = std.os.windows;
    _ = windows.kernel32.FreeLibrary(handle);
}

fn lookupWindows(handle: DlHandle, symbol: []const u8) !*anyopaque {
    const windows = std.os.windows;

    // Convert to null-terminated string
    var symbol_buf: [1024]u8 = undefined;
    if (symbol.len >= symbol_buf.len) return error.SymbolNameTooLong;

    @memcpy(symbol_buf[0..symbol.len], symbol);
    symbol_buf[symbol.len] = 0;

    const ptr = windows.kernel32.GetProcAddress(
        handle,
        symbol_buf[0..symbol.len :0],
    ) orelse {
        return error.SymbolNotFound;
    };

    return @ptrCast(ptr);
}

// ============================================================================
// Convenience Functions
// ============================================================================

/// Load a function from a dynamic library
pub fn loadFunction(
    allocator: Allocator,
    lib_path: []const u8,
    comptime FnType: type,
    symbol: []const u8,
) !FnType {
    var lib = try DynLib.open(allocator, lib_path);
    defer lib.close();

    return try lib.lookup(FnType, symbol);
}

/// Check if a library exists and can be opened
pub fn libraryExists(allocator: Allocator, path: []const u8) bool {
    var lib = DynLib.open(allocator, path) catch return false;
    lib.close();
    return true;
}

/// Get standard library paths for the platform
pub fn getStandardLibraryPaths(_: Allocator) ![]const []const u8 {
    return switch (builtin.os.tag) {
        .linux => &.{
            "/lib",
            "/usr/lib",
            "/usr/local/lib",
            "/lib64",
            "/usr/lib64",
        },
        .macos => &.{
            "/usr/lib",
            "/usr/local/lib",
            "/opt/homebrew/lib",
        },
        .windows => &.{
            "C:\\Windows\\System32",
            "C:\\Windows\\SysWOW64",
        },
        else => &.{},
    };
}

/// Try to find and open a library by name (without path)
pub fn findAndOpen(allocator: Allocator, name: []const u8) !DynLib {
    // Try direct name first
    if (DynLib.open(allocator, name)) |lib| {
        return lib;
    } else |_| {}

    // Get platform-specific library name
    const lib_name = try getPlatformLibraryName(allocator, name);
    defer allocator.free(lib_name);

    // Try platform-specific name
    if (DynLib.open(allocator, lib_name)) |lib| {
        return lib;
    } else |_| {}

    // Try standard library paths
    const paths = try getStandardLibraryPaths(allocator);
    for (paths) |path| {
        const full_path = try std.fs.path.join(allocator, &.{ path, lib_name });
        defer allocator.free(full_path);

        if (DynLib.open(allocator, full_path)) |lib| {
            return lib;
        } else |_| {}
    }

    return error.LibraryNotFound;
}

fn getPlatformLibraryName(allocator: Allocator, name: []const u8) ![]const u8 {
    return switch (builtin.os.tag) {
        .windows => try std.fmt.allocPrint(allocator, "{s}.dll", .{name}),
        .macos => try std.fmt.allocPrint(allocator, "lib{s}.dylib", .{name}),
        else => try std.fmt.allocPrint(allocator, "lib{s}.so", .{name}),
    };
}

// ============================================================================
// Tests
// ============================================================================

test "DynLib - open and close system library" {
    const testing = std.testing;
    const allocator = testing.allocator;

    // Try to open libc
    const lib_name = switch (builtin.os.tag) {
        .linux => "libc.so.6",
        .macos => "libSystem.B.dylib",
        .windows => "msvcrt.dll",
        else => return error.SkipZigTest,
    };

    var lib = try DynLib.open(allocator, lib_name);
    defer lib.close();

    // If we got here, the library opened successfully
    try testing.expect(lib.path.len > 0);
}

test "DynLib - lookup function" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const lib_name = switch (builtin.os.tag) {
        .linux => "libc.so.6",
        .macos => "libSystem.B.dylib",
        .windows => "msvcrt.dll",
        else => return error.SkipZigTest,
    };

    var lib = try DynLib.open(allocator, lib_name);
    defer lib.close();

    // Look up strlen function
    const StrlenFn = *const fn ([*:0]const u8) callconv(.c) usize;
    const strlen = try lib.lookup(StrlenFn, "strlen");

    // Test it
    const result = strlen("Hello");
    try testing.expectEqual(@as(usize, 5), result);
}

test "DynLib - symbol not found" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const lib_name = switch (builtin.os.tag) {
        .linux => "libc.so.6",
        .macos => "libSystem.B.dylib",
        .windows => "msvcrt.dll",
        else => return error.SkipZigTest,
    };

    var lib = try DynLib.open(allocator, lib_name);
    defer lib.close();

    const FnType = *const fn () callconv(.c) void;
    const result = lib.lookup(FnType, "this_symbol_does_not_exist");

    try testing.expectError(error.SymbolNotFound, result);
}

test "DynLib - library not found" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const result = DynLib.open(allocator, "this_library_does_not_exist.so");
    try testing.expectError(error.LibraryNotFound, result);
}

test "DynLib - hasSymbol" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const lib_name = switch (builtin.os.tag) {
        .linux => "libc.so.6",
        .macos => "libSystem.B.dylib",
        .windows => "msvcrt.dll",
        else => return error.SkipZigTest,
    };

    var lib = try DynLib.open(allocator, lib_name);
    defer lib.close();

    try testing.expect(lib.hasSymbol("strlen"));
    try testing.expect(!lib.hasSymbol("this_symbol_does_not_exist"));
}

test "libraryExists" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const lib_name = switch (builtin.os.tag) {
        .linux => "libc.so.6",
        .macos => "libSystem.B.dylib",
        .windows => "msvcrt.dll",
        else => return error.SkipZigTest,
    };

    try testing.expect(libraryExists(allocator, lib_name));
    try testing.expect(!libraryExists(allocator, "nonexistent.so"));
}
