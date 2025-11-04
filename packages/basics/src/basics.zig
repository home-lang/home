// Home Programming Language - Basics Module
// A friendly, Home-style wrapper around Zig's standard library
//
// Instead of importing `std`, Home developers import `Basics`:
//   const Basics = @import("basics");
//
// This provides a more welcoming API with Home naming conventions

const std = @import("std");

// Re-export core functionality with Home naming
pub const Allocator = std.mem.Allocator;
pub const ArrayList = std.ArrayList;
pub const HashMap = std.HashMap;
pub const StringHashMap = std.StringHashMap;
pub const AutoHashMap = std.AutoHashMap;

// Memory management
pub const mem = struct {
    pub const Allocator = std.mem.Allocator;
    pub const page_allocator = std.heap.page_allocator;
    pub const GeneralPurposeAllocator = std.heap.GeneralPurposeAllocator;
    pub const ArenaAllocator = std.heap.ArenaAllocator;
    pub const eql = std.mem.eql;
    pub const copy = std.mem.copy;
    pub const copyForwards = std.mem.copyForwards;
    pub const copyBackwards = std.mem.copyBackwards;
    pub const set = std.mem.set;
    pub const zeroes = std.mem.zeroes;
    pub const indexOf = std.mem.indexOf;
    pub const lastIndexOf = std.mem.lastIndexOf;
    pub const startsWith = std.mem.startsWith;
    pub const endsWith = std.mem.endsWith;
    pub const split = std.mem.split;
    pub const tokenize = std.mem.tokenize;
};

// Heap allocators
pub const heap = struct {
    pub const page_allocator = std.heap.page_allocator;
    pub const GeneralPurposeAllocator = std.heap.GeneralPurposeAllocator;
    pub const ArenaAllocator = std.heap.ArenaAllocator;
    pub const c_allocator = std.heap.c_allocator;
};

// Debug utilities
pub const debug = struct {
    pub const print = std.debug.print;
    pub const assert = std.debug.assert;
    pub const panic = std.debug.panic;
};

// Formatting
pub const fmt = struct {
    pub const format = std.fmt.format;
    pub const parseInt = std.fmt.parseInt;
    pub const parseFloat = std.fmt.parseFloat;
    pub const allocPrint = std.fmt.allocPrint;
    pub const bufPrint = std.fmt.bufPrint;
    pub const FormatOptions = std.fmt.FormatOptions;
};

// Math operations
pub const math = struct {
    pub const min = std.math.min;
    pub const max = std.math.max;
    pub const abs = std.math.abs;
    pub const sqrt = std.math.sqrt;
    pub const pow = std.math.pow;
    pub const sin = std.math.sin;
    pub const cos = std.math.cos;
    pub const tan = std.math.tan;
    pub const log = std.math.log;
    pub const ln = std.math.ln;
    pub const ceil = std.math.ceil;
    pub const floor = std.math.floor;
    pub const round = std.math.round;
    pub const pi = std.math.pi;
    pub const e = std.math.e;
    pub const inf = std.math.inf;
    pub const nan = std.math.nan;
};

// File system operations
pub const fs = struct {
    pub const File = std.fs.File;
    pub const Dir = std.fs.Dir;
    pub const cwd = std.fs.cwd;
    pub const openFileAbsolute = std.fs.openFileAbsolute;
    pub const createFileAbsolute = std.fs.createFileAbsolute;
    pub const deleteFileAbsolute = std.fs.deleteFileAbsolute;
    pub const makeDirAbsolute = std.fs.makeDirAbsolute;
    pub const deleteDirAbsolute = std.fs.deleteDirAbsolute;
    pub const path = std.fs.path;
};

// Networking
pub const net = struct {
    pub const Address = std.net.Address;
    pub const Stream = std.net.Stream;
    pub const StreamServer = std.net.StreamServer;
    pub const TcpServer = std.net.StreamServer;
};

// Time utilities
pub const time = struct {
    pub const timestamp = std.time.timestamp;
    pub const milliTimestamp = std.time.milliTimestamp;
    pub const nanoTimestamp = std.time.nanoTimestamp;
    pub const sleep = std.time.sleep;
    pub const Timer = std.time.Timer;

    /// High-precision time structure
    pub const TimeSpec = struct {
        seconds: i64,
        nanoseconds: i64,

        pub fn now() TimeSpec {
            const ns = std.time.nanoTimestamp();
            return .{
                .seconds = @divFloor(ns, std.time.ns_per_s),
                .nanoseconds = @mod(ns, std.time.ns_per_s),
            };
        }

        pub fn toNanoseconds(self: TimeSpec) i128 {
            return @as(i128, self.seconds) * std.time.ns_per_s + self.nanoseconds;
        }

        pub fn toMilliseconds(self: TimeSpec) i64 {
            return @divFloor(self.toNanoseconds(), std.time.ns_per_ms);
        }

        pub fn toSeconds(self: TimeSpec) i64 {
            return self.seconds;
        }
    };
};

// Threading
pub const Thread = struct {
    pub const spawn = std.Thread.spawn;
    pub const join = std.Thread.join;
    pub const Mutex = std.Thread.Mutex;
    pub const RwLock = std.Thread.RwLock;
    pub const Condition = std.Thread.Condition;
    pub const Pool = std.Thread.Pool;
};

// Process management
pub const process = struct {
    pub const exit = std.process.exit;
    pub const abort = std.process.abort;
    pub const args = std.process.args;
    pub const ArgIterator = std.process.ArgIterator;
    pub const getEnvVarOwned = std.process.getEnvVarOwned;
    pub const hasEnvVar = std.process.hasEnvVar;
};

// JSON parsing
pub const json = struct {
    pub const parse = std.json.parse;
    pub const parseFromSlice = std.json.parseFromSlice;
    pub const stringify = std.json.stringify;
    pub const stringifyAlloc = std.json.stringifyAlloc;
    pub const Parsed = std.json.Parsed;
    pub const Value = std.json.Value;
    pub const ArrayHashMap = std.json.ArrayHashMap;
    pub const TokenStream = std.json.TokenStream;
};

// HTTP (when available)
pub const http = struct {
    pub const Client = std.http.Client;
    pub const Server = std.http.Server;
    pub const Method = std.http.Method;
    pub const Status = std.http.Status;
    pub const Headers = std.http.Headers;
};

// Cryptography
pub const crypto = struct {
    pub const hash = struct {
        pub const sha256 = std.crypto.hash.sha256;
        pub const sha512 = std.crypto.hash.sha512;
        pub const blake3 = std.crypto.hash.blake3;
    };
    pub const random = std.crypto.random;
    pub const hmac = std.crypto.auth.hmac;
};

// Compression
pub const compress = struct {
    pub const gzip = std.compress.gzip;
    pub const zlib = std.compress.zlib;
    pub const deflate = std.compress.deflate;
};

// Sorting and searching
pub const sort = struct {
    pub const sort = std.sort.sort;
    pub const isSorted = std.sort.isSorted;
    pub const asc = std.sort.asc;
    pub const desc = std.sort.desc;
};

// Testing utilities
pub const testing = struct {
    pub const expect = std.testing.expect;
    pub const expectEqual = std.testing.expectEqual;
    pub const expectEqualStrings = std.testing.expectEqualStrings;
    pub const expectError = std.testing.expectError;
    pub const allocator = std.testing.allocator;
};

// Build info
pub const builtin = @import("builtin");

// OS-specific
pub const os = struct {
    pub const linux = std.os.linux;
    pub const windows = std.os.windows;
    pub const darwin = std.os.darwin;
    pub const system = std.os.system;
};

// ============================================================================
// Home-Specific Extensions
// ============================================================================

/// Print with friendly Home syntax
pub fn print(comptime format: []const u8, args: anytype) void {
    std.debug.print(format, args);
}

/// Print line (automatically adds newline)
pub fn println(comptime format: []const u8, args: anytype) void {
    std.debug.print(format ++ "\n", args);
}

/// Easy string equality check
pub fn strEql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Get current timestamp in seconds
pub fn now() i64 {
    return std.time.timestamp();
}

/// Get current timestamp in milliseconds
pub fn nowMillis() i64 {
    return std.time.milliTimestamp();
}

/// Sleep for milliseconds
pub fn sleepMs(milliseconds: u64) void {
    std.time.sleep(milliseconds * 1_000_000);
}

/// Sleep for seconds
pub fn sleepSec(seconds: u64) void {
    std.time.sleep(seconds * 1_000_000_000);
}

/// Create a general-purpose allocator
pub fn createAllocator() std.heap.GeneralPurposeAllocator(.{}) {
    return std.heap.GeneralPurposeAllocator(.{}){};
}

/// Create an arena allocator
pub fn createArena(backing: std.mem.Allocator) std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(backing);
}

// ============================================================================
// Common Type Aliases with Home Naming
// ============================================================================

pub const String = []const u8;
pub const MutableString = []u8;
pub const Integer = i64;
pub const Float = f64;
pub const Boolean = bool;
pub const Byte = u8;

// ============================================================================
// Error Handling Helpers
// ============================================================================

/// Common error set
pub const Error = error{
    OutOfMemory,
    FileNotFound,
    AccessDenied,
    InvalidInput,
    Timeout,
    NetworkError,
    ParseError,
    NotFound,
    AlreadyExists,
    Cancelled,
};

/// Result type for operations that can fail
pub fn Result(comptime T: type) type {
    return union(enum) {
        ok: T,
        err: Error,

        pub fn isOk(self: @This()) bool {
            return self == .ok;
        }

        pub fn isErr(self: @This()) bool {
            return self == .err;
        }

        pub fn unwrap(self: @This()) T {
            return switch (self) {
                .ok => |value| value,
                .err => |e| @panic(@errorName(e)),
            };
        }

        pub fn unwrapOr(self: @This(), default: T) T {
            return switch (self) {
                .ok => |value| value,
                .err => default,
            };
        }
    };
}

/// Option type for values that might not exist
pub fn Option(comptime T: type) type {
    return union(enum) {
        some: T,
        none,

        pub fn isSome(self: @This()) bool {
            return self == .some;
        }

        pub fn isNone(self: @This()) bool {
            return self == .none;
        }

        pub fn unwrap(self: @This()) T {
            return switch (self) {
                .some => |value| value,
                .none => @panic("Called unwrap on None"),
            };
        }

        pub fn unwrapOr(self: @This(), default: T) T {
            return switch (self) {
                .some => |value| value,
                .none => default,
            };
        }
    };
}

// ============================================================================
// Home Web Framework Modules
// ============================================================================

/// HTTP routing and middleware
pub const http_router = @import("http_router.zig");

/// Session management
pub const session = @import("session.zig");

/// Middleware (CORS, rate limiting, etc.)
pub const middleware = @import("middleware.zig");

/// Validation library
pub const validation = @import("validation.zig");

/// JSON utilities
pub const json_util = @import("json.zig");

/// HTTP utilities
pub const http_util = @import("http");

/// CLI utilities
pub const cli = @import("cli.zig");

/// Datetime utilities
pub const datetime = @import("datetime.zig");

/// Regex utilities
pub const regex = @import("regex.zig");

/// Process utilities
pub const process_util = @import("process.zig");

/// File system utilities
pub const fs_util = @import("fs.zig");

/// Network utilities
pub const net_util = @import("net.zig");

/// Cryptography utilities
pub const crypto_util = @import("crypto.zig");

/// Memory utilities (mmap, mprotect, mlock)
pub const memory_util = @import("memory.zig");

/// Collections - Fluent, Laravel-inspired API for data manipulation
pub const collections = @import("collections.zig");
pub const Collection = collections.Collection;
pub const LazyCollection = collections.LazyCollection;

// Collection builder helpers (can use directly from Basics)
pub const range = collections.range;
pub const times = collections.times;
pub const wrap = collections.wrap;
pub const empty = collections.empty;
pub const lazy = collections.lazy;

// Tests
test "Basics module imports" {
    const allocator = testing.allocator;

    // Test ArrayList
    var list = ArrayList(i32).init(allocator);
    defer list.deinit();

    try list.append(1);
    try list.append(2);
    try list.append(3);

    try testing.expectEqual(@as(usize, 3), list.items.len);
}

test "Home-friendly helpers" {
    try testing.expect(strEql("hello", "hello"));
    try testing.expect(!strEql("hello", "world"));

    const timestamp = now();
    try testing.expect(timestamp > 0);

    const millis = nowMillis();
    try testing.expect(millis > 0);
}

test "Option type" {
    const some_value = Option(i32){ .some = 42 };
    const no_value = Option(i32){ .none = {} };

    try testing.expect(some_value.isSome());
    try testing.expect(no_value.isNone());

    try testing.expectEqual(@as(i32, 42), some_value.unwrap());
    try testing.expectEqual(@as(i32, 0), no_value.unwrapOr(0));
}

test "Result type" {
    const success = Result(i32){ .ok = 42 };
    const failure = Result(i32){ .err = Error.NotFound };

    try testing.expect(success.isOk());
    try testing.expect(failure.isErr());

    try testing.expectEqual(@as(i32, 42), success.unwrap());
    try testing.expectEqual(@as(i32, 0), failure.unwrapOr(0));
}

test "Collections integration" {
    const allocator = testing.allocator;

    // Test Collection
    var col = Collection(i32).init(allocator);
    defer col.deinit();

    try col.push(1);
    try col.push(2);
    try col.push(3);

    try testing.expectEqual(@as(usize, 3), col.count());
    try testing.expectEqual(@as(i32, 6), col.sum());

    // Test filtering and mapping
    var evens = try col.filter(struct {
        fn call(n: i32) bool {
            return @mod(n, 2) == 0;
        }
    }.call);
    defer evens.deinit();

    try testing.expectEqual(@as(usize, 1), evens.count());
    try testing.expectEqual(@as(i32, 2), evens.first().?);

    // Test LazyCollection
    const items = [_]i32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    const filter_fn = struct {
        fn call(n: i32) bool {
            return @mod(n, 2) == 0;
        }
    }.call;

    const lzy = LazyCollection(i32).fromSlice(allocator, &items);
    var result = try lzy.filter(&filter_fn).take(3);
    defer result.deinit();

    try testing.expectEqual(@as(usize, 3), result.count());
    try testing.expectEqual(@as(i32, 2), result.get(0).?);
    try testing.expectEqual(@as(i32, 4), result.get(1).?);
    try testing.expectEqual(@as(i32, 6), result.get(2).?);
}

test "Collection builder functions" {
    const allocator = testing.allocator;

    // Test range
    var nums = try range(allocator, 1, 5);
    defer nums.deinit();
    try testing.expectEqual(@as(usize, 5), nums.count());
    try testing.expectEqual(@as(i32, 1), nums.first().?);
    try testing.expectEqual(@as(i32, 5), nums.last().?);

    // Test wrap
    var wrapped = try wrap(i32, allocator, 42);
    defer wrapped.deinit();
    try testing.expectEqual(@as(usize, 1), wrapped.count());
    try testing.expectEqual(@as(i32, 42), wrapped.first().?);

    // Test empty
    var empty_col = empty(i32, allocator);
    defer empty_col.deinit();
    try testing.expect(empty_col.isEmpty());
}
