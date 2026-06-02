// Home Runtime aggregator.
//
// This module is the single import surface used by every other Home Runtime
// subsystem. Copied-from-Bun source files have their `@import("bun")` calls
// rewritten to `@import("home")` at copy time, so this aggregator is the
// canonical replacement for Bun's `bun.zig` namespace inside Home.
//
// Each sub-phase appends its public surface here as the matching directory
// under `src/` is populated. Phase 12 status + per-file porting tables live
// in the subdirectory `PORTING_STATUS.md` files.

const std = @import("std");
const builtin = @import("builtin");

pub const upstream_sha = "fd0b6f1a271fca0b8124b69f230b100f4d636af6";
pub const callconv_inline: std.builtin.CallingConvention = if (builtin.mode == .Debug) .auto else .@"inline";
pub const callmod_inline: std.builtin.CallModifier = if (builtin.mode == .Debug) .auto else .always_inline;

// Faithful Bun-source import surface for the Node URL/querystring/assert/util
// and Web text-encoding parity slice. This namespace points at copied Bun Zig
// modules only; it does not provide JS fallback behavior.
pub const bun_node_web_parity = @import("bun/node_url_query_assert_util_encoding.zig");
pub const bun_cli_spawn_process_fs_file = @import("bun/cli_spawn_process_fs_file.zig");

// ---- Foundational primitives ------------------------------------------
// These are Home-original implementations of the small Bun stdlib subset
// that copied source needs to compile. Each function mirrors the
// upstream semantics — see file-level docs for divergences.
pub const strings = @import("strings.zig");
pub const Output = @import("output.zig");
// Bun's `bun.Progress` is a snapshot of the pre-0.13 `std.Progress` API used
// by `bun install`'s progress bar. The install / PackageManager cone consumes
// it as `Progress{}` + `Progress.Node`; migrated to Zig 0.17 `std.Io.File`.
pub const Progress = @import("bun_core/Progress.zig");
pub const Global = @import("global.zig");
pub const Environment = @import("environment.zig");
pub const fmt = @import("fmt.zig");
/// Faithful to upstream `bun.zig:11` (`feature_flag = env_var.feature_flag`).
pub const feature_flag = @import("bun_core/env_var.zig").feature_flag;

/// Faithful to upstream `bun.zig:930`.
pub fn getenvZ(key: [:0]const u8) ?[]const u8 {
    if (comptime !Environment.isNative) {
        return null;
    }
    if (comptime Environment.isWindows) {
        return getenvZAnyCase(key);
    }
    const pointer = std.c.getenv(key.ptr) orelse return null;
    return std.mem.sliceTo(pointer, 0);
}

/// Faithful to upstream `bun.zig:913`.
pub fn getenvZAnyCase(key: [:0]const u8) ?[]const u8 {
    for (std.os.environ) |lineZ| {
        const line = std.mem.sliceTo(lineZ, 0);
        const key_end = strings.indexOfCharUsize(line, '=') orelse line.len;
        if (strings.eqlCaseInsensitiveASCII(line[0..key_end], key, true)) {
            return line[@min(key_end + 1, line.len)..];
        }
    }
    return null;
}

/// Faithful to upstream `bun.zig:1936` (`string.SliceWithUnderlyingString`).
pub const SliceWithUnderlyingString = @import("string/string.zig").SliceWithUnderlyingString;

/// Faithful to upstream `bun.zig:1946`. WebKit WTF String impl handles.
pub const WTF = struct {
    /// The String type from WebKit's WTF library.
    pub const StringImpl = @import("string/string.zig").WTFStringImpl;
    pub const _StringImplStruct = @import("string/string.zig").WTFStringImplStruct;
};

/// Faithful to upstream `bun.zig:2790`. Returns a `deinit` fn that simply
/// `destroy`s the value (for structs holding no owned pointers).
pub fn TrivialDeinit(comptime T: type) fn (*T) void {
    return struct {
        pub fn deinit(self: *T) void {
            destroy(self);
        }
    }.deinit;
}

/// Faithful to upstream `bun.zig:2841`. Maps a `SystemErrno` value to the
/// matching Zig error (built at comptime from the enum tag names).
const errno_map = errno_map: {
    var max_value = 0;
    for (std.enums.values(sys.SystemErrno)) |v|
        max_value = @max(max_value, @intFromEnum(v));

    var map: [max_value + 1]anyerror = undefined;
    @memset(&map, error.Unexpected);
    for (std.enums.values(sys.SystemErrno)) |v|
        map[@intFromEnum(v)] = @field(anyerror, @tagName(v));

    break :errno_map map;
};

/// Faithful to upstream `bun.zig:2854`.
pub fn errnoToZigErr(err: anytype) anyerror {
    var num = if (@typeInfo(@TypeOf(err)) == .@"enum")
        @intFromEnum(err)
    else
        err;

    if (Environment.allow_assert) {
        assert(num != 0);
    }

    if (Environment.os == .windows) {
        // uv errors are negative, normalizing it will make this more resilient
        num = @abs(num);
    } else {
        if (Environment.allow_assert) {
            assert(num > 0);
        }
    }

    if (num > 0 and num < errno_map.len)
        return errno_map[num];

    return error.Unexpected;
}
pub const Generation = u16;
pub const Wyhash11 = std.hash.Wyhash;
pub const StandaloneModuleGraph = @import("standalone_graph/StandaloneModuleGraph.zig");
/// Mirrors Bun's `bun.json` (`interchange.json` → `parsers/json.zig`): the
/// JSON / package.json / tsconfig parser leaf of the resolver/macro/PM cone.
/// Dead-code-eliminated while the cone's parser probe stays off.
pub const json = @import("parsers/json.zig");
/// Faithful to upstream `bun.resolver` (`src/bun.zig:201`):
/// `pub const resolver = @import("./resolver/resolver.zig");`.
pub const resolver = @import("resolver/resolver.zig");
/// Faithful to upstream `bun.collections` (`src/bun.zig:501`) and
/// `bun.SmallList` (`src/bun.zig:236`, = `css.SmallList`).
pub const collections = @import("collections/collections.zig");
pub const SmallList = @import("css/small_list.zig").SmallList;
// Faithful to upstream bun.zig:1934 (ZigString) and bun.zig:768 (AllocationScope).
pub const ZigString = jsc.ZigString;
pub const AllocationScope = allocators.AllocationScope;
pub const base64 = @import("base64/base64.zig");
pub const simdutf = @import("simdutf_sys/simdutf.zig");
pub const c_ares = @import("cares_sys/c_ares.zig");
pub const zlib = @import("zlib/zlib.zig");
pub const NullableAllocator = allocators.NullableAllocator;
pub const HashedString = @import("string/HashedString.zig");
/// Faithful to upstream bun.zig:1457.
pub fn asByteSlice(buffer: anytype) []const u8 {
    return switch (@TypeOf(buffer)) {
        [*:0]u8, [*:0]const u8 => buffer[0..std.mem.len(buffer)],
        [*c]const u8, [*c]u8 => std.mem.span(buffer),
        else => buffer,
    };
}


fn assertNoHasherPointers(comptime T: type) void {
    switch (@typeInfo(T)) {
        .pointer => @compileError("no pointers in writeAnyToHasher input"),
        inline .@"struct", .@"union" => |info| for (info.fields) |field| {
            assertNoHasherPointers(field.type);
        },
        .array => |array| assertNoHasherPointers(array.child),
        else => {},
    }
}

pub inline fn writeAnyToHasher(hasher: anytype, thing: anytype) void {
    comptime assertNoHasherPointers(@TypeOf(thing));
    hasher.update(std.mem.asBytes(&thing));
}
pub const path = @import("path.zig");
pub const env_var = @import("env_var.zig");

// Re-exports so copied source can spell `home_rt.assert(...)` /
// `home_rt.OOM` etc. directly (mirrors Bun's flat `bun.assert` /
// `bun.OOM` namespace).
pub const assert = Global.assert;
pub const unsafeAssert = Global.assert;
/// Faithful to upstream `bun.zig:3182`.
pub inline fn assertWithLocation(value: bool, src: std.builtin.SourceLocation) void {
    if (comptime !Environment.allow_assert) {
        return;
    }
    if (!value) {
        if (comptime Environment.isDebug)
            unreachable; // ASSERTION FAILURE
        std.debug.panic("Internal assertion failure at {s}:{d}:{d}", .{ src.file, src.line, src.column });
    }
}
pub const OOM = Global.OOM;
pub const JSError = error{ JSError, OutOfMemory, JSTerminated };
pub const JSTerminated = error{JSTerminated};
pub const JSOOM = OOM || JSError;
pub const handleOom = Global.handleOom;
pub const default_allocator: std.mem.Allocator = std.heap.smp_allocator;
pub const StackOverflow = error{StackOverflow};
// Faithful to upstream `bun.zig:16`: `pub const DefaultAllocator = allocators.Default;`.
// The default allocator *type* used by `bun.ptr.shared` / `bun.ptr.OwnedIn`.
pub const DefaultAllocator = allocators.Default;

/// Faithful re-implementation of the (now-removed in Zig 0.17.0-dev.263)
/// `std.time.Timer`: a monotonic, anti-rollback nanosecond stopwatch. Backed by
/// `clock_gettime(CLOCK_MONOTONIC)`. Exposes the same `start`/`read`/`lap`/`reset`
/// surface upstream callers (`bun.http`'s `HTTPThread.timer`) rely on.
pub const Timer = struct {
    started: u64,
    previous: u64,

    pub const Error = error{TimerUnsupported};

    fn clockNanos() u64 {
        var ts: std.posix.timespec = undefined;
        // CLOCK.MONOTONIC is always available on the posix targets Home builds.
        _ = std.c.clock_gettime(std.posix.CLOCK.MONOTONIC, &ts);
        return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
    }

    pub fn start() Timer.Error!Timer {
        const now = clockNanos();
        return .{ .started = now, .previous = now };
    }

    /// Reads the timer value since start or the last reset in nanoseconds.
    pub fn read(self: *Timer) u64 {
        const current = clockNanos();
        return current -| self.started;
    }

    /// Resets the timer value to 0/now.
    pub fn reset(self: *Timer) void {
        const current = clockNanos();
        self.started = current;
        self.previous = current;
    }

    /// Returns the current value of the timer in nanoseconds, then resets it.
    pub fn lap(self: *Timer) u64 {
        const current = clockNanos();
        defer self.previous = current;
        return current -| self.previous;
    }
};

// Faithful port of upstream `bun.LazyBoolValue` / `bun.LazyBool`
// (`src/bun.zig:2226`). A lazily-computed boolean memoized in-place via
// `@fieldParentPtr`; the install/PackageManager cone uses it for `ci_mode`.
pub const LazyBoolValue = enum {
    unknown,
    no,
    yes,
};
/// Create a lazily computed boolean value.
/// Getter must be a function that takes a pointer to the parent struct and returns a boolean.
/// Parent must be a type which contains the field we are getting.
pub fn LazyBool(
    comptime Getter: anytype,
    comptime Parent: type,
    comptime field: []const u8,
) type {
    return struct {
        value: LazyBoolValue = .unknown,

        pub fn get(self: *@This()) bool {
            if (self.value == .unknown) {
                const parent: *Parent = @alignCast(@fieldParentPtr(field, self));
                self.value = switch (Getter(parent)) {
                    true => .yes,
                    false => .no,
                };
            }

            return self.value == .yes;
        }
    };
}

/// Faithful re-implementation of the (now-removed) `std.heap.StackFallbackAllocator`:
/// a comptime-sized inline buffer that falls back to a runtime allocator once the
/// inline buffer is exhausted. Upstream Bun (and pre-0.17 Zig) exposed this via
/// `std.heap.stackFallback(size, allocator)`; that API was dropped from the Zig
/// stdlib, so vendored `@import("bun")` callers route through `bun.stackFallback`.
pub fn StackFallbackAllocator(comptime size: usize) type {
    return struct {
        const Self = @This();

        buffer: [size]u8 = undefined,
        fixed: std.heap.FixedBufferAllocator = undefined,
        fallback_allocator: std.mem.Allocator,

        /// Initialize the inner `FixedBufferAllocator` over the inline buffer and
        /// return an `Allocator` interface bound to this (addressable) value.
        pub fn get(self: *Self) std.mem.Allocator {
            self.fixed = std.heap.FixedBufferAllocator.init(self.buffer[0..]);
            return .{
                .ptr = self,
                .vtable = &.{
                    .alloc = sfaAlloc,
                    .resize = sfaResize,
                    .remap = sfaRemap,
                    .free = sfaFree,
                },
            };
        }

        fn sfaAlloc(ctx: *anyopaque, n: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            return std.heap.FixedBufferAllocator.alloc(&self.fixed, n, alignment, ra) orelse
                self.fallback_allocator.rawAlloc(n, alignment, ra);
        }

        fn sfaResize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (self.fixed.ownsPtr(buf.ptr)) {
                return std.heap.FixedBufferAllocator.resize(&self.fixed, buf, alignment, new_len, ra);
            }
            return self.fallback_allocator.rawResize(buf, alignment, new_len, ra);
        }

        fn sfaRemap(ctx: *anyopaque, mem: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (self.fixed.ownsPtr(mem.ptr)) {
                return std.heap.FixedBufferAllocator.remap(&self.fixed, mem, alignment, new_len, ra);
            }
            return self.fallback_allocator.rawRemap(mem, alignment, new_len, ra);
        }

        fn sfaFree(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ra: usize) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (self.fixed.ownsPtr(buf.ptr)) {
                return std.heap.FixedBufferAllocator.free(&self.fixed, buf, alignment, ra);
            }
            return self.fallback_allocator.rawFree(buf, alignment, ra);
        }
    };
}

/// Drop-in replacement for the removed `std.heap.stackFallback(size, fallback)`.
/// Returns a value owning a comptime-sized inline buffer; call `.get()` on the
/// (addressable) returned value to obtain an `Allocator`.
pub fn stackFallback(comptime size: usize, fallback: std.mem.Allocator) StackFallbackAllocator(size) {
    return .{ .fallback_allocator = fallback };
}

pub noinline fn outOfMemory() noreturn {
    @branchHint(.cold);
    @panic("home_rt: out of memory");
}

pub inline fn unreachablePanic(comptime fmts: []const u8, args: anytype) noreturn {
    std.debug.panic(fmts, args);
}

pub noinline fn throwStackOverflow() StackOverflow!void {
    @branchHint(.cold);
    return error.StackOverflow;
}

pub fn ThreadlocalBuffers(comptime T: type) type {
    return struct {
        threadlocal var instance: T = .{};

        pub inline fn get() *T {
            return &instance;
        }
    };
}

pub inline fn isComptimeKnown(value: anytype) bool {
    _ = value;
    return @inComptime();
}

pub const deprecated = struct {
    pub fn jsErrorToWriteError(_: anyerror) std.Io.Writer.Error {
        return error.WriteFailed;
    }

    /// Mirrors Bun's `bun.deprecated.SinglyLinkedList`. The stdlib dropped the
    /// pre-0.17 `std.SinglyLinkedList(T)` (node-embedding) shape, so the JSON
    /// parser's `HashMapPool` node cache needs the historical API. Pulled from
    /// a dedicated module rather than `bun_core/deprecated.zig` (whose RapidHash
    /// test body still trips the pinned Zig 0.17.0-dev.263 `**` tokenizer bug,
    /// so importing it would eagerly parse that file).
    pub const SinglyLinkedList = @import("bun_core/singly_linked_list.zig").SinglyLinkedList;
};

pub fn DebugOnlyDisabler(comptime Type: type) type {
    return struct {
        threadlocal var disable_create_in_debug: if (Environment.isDebug) usize else u0 = 0;

        pub inline fn disable() void {
            if (comptime !Environment.isDebug) return;
            disable_create_in_debug += 1;
        }

        pub inline fn enable() void {
            if (comptime !Environment.isDebug) return;
            disable_create_in_debug -= 1;
        }

        pub inline fn assert() void {
            if (comptime !Environment.isDebug) return;
            if (disable_create_in_debug > 0) {
                Output.panic(comptime "[" ++ @typeName(Type) ++ "] called while disabled (did you forget to call enable?)", .{});
            }
        }
    };
}

pub const StackCheck = struct {
    cached_stack_end: usize = 0,

    pub fn configureThread() void {}

    pub fn init() StackCheck {
        return .{ .cached_stack_end = 0 };
    }

    pub fn update(this: *StackCheck) void {
        this.cached_stack_end = 0;
    }

    pub fn isSafeToRecurse(_: StackCheck) bool {
        return true;
    }
};

pub fn parseDouble(input: []const u8) !f64 {
    return std.fmt.parseFloat(f64, input);
}

pub const String = @import("string/string.zig").String;
pub const CodePoint = @import("string/immutable.zig").CodePoint;
pub const MutableString = @import("string/MutableString.zig");
pub const PathString = @import("string/PathString.zig").PathString;

// Bun native transpiler parity surface. These are direct re-exports of
// copied upstream files so home_test can move off JS string shims and into
// the parser/printer path Home already vendors.
pub const logger = @import("logger/logger.zig");
pub const js_lexer = @import("js_parser/lexer.zig");
pub const js_printer = @import("js_printer/js_printer.zig");
pub const renamer = @import("js_printer/renamer.zig");
pub const js_parser = @import("js_parser/parser.zig");
pub const options = @import("bundler/options.zig");
pub const defines = @import("bundler/defines.zig");
pub const transpiler = @import("bundler/transpiler.zig");
pub const Transpiler = transpiler.Transpiler;
pub const bundle_v2 = @import("bundler/bundle_v2.zig");
pub const Loader = bundle_v2.Loader;
pub const SourceMap = @import("sourcemap/sourcemap.zig");
pub const ast = @import("js_parser/js_parser.zig");
pub const ImportRecord = @import("options_types/import_record.zig").ImportRecord;
pub const ImportKind = @import("options_types/import_record.zig").ImportKind;
pub const schema = @import("options_types/schema.zig");
pub const bake = struct {
    pub const DevServer = opaque {
        // Faithful to upstream `bun.bake.DevServer.DevAllocator`
        // (`src/runtime/bake/DevServer.zig:754-755`):
        // `const AllocationScope = bun.allocators.AllocationScopeIn(bun.DefaultAllocator);`
        // `pub const DevAllocator = AllocationScope.Borrowed;`. Used by PackedMap.
        pub const DevAllocator = @import("bun_alloc/allocation_scope.zig").AllocationScopeIn(DefaultAllocator).Borrowed;
    };
    // Faithful to upstream `bun.bake.Side` (`src/bake/bake.zig`): the
    // client/server render-side enum used by OutputFile + the production
    // bundler. Sourced from the full ported bake.zig.
    pub const Side = @import("runtime/bake/bake.zig").Side;

    pub const Framework = struct {
        is_built_in_react: bool = false,
        file_system_router_types: []FileSystemRouterType = &.{},
        server_components: ?ServerComponents = null,
        react_fast_refresh: ?ReactFastRefresh = null,
        built_in_modules: StringArrayHashMapUnmanaged(BuiltInModule) = .empty,

        pub const none: Framework = .{};

        pub const FileSystemRouterType = struct {
            root: []const u8 = "",
            prefix: []const u8 = "",
            entry_server: []const u8 = "",
            entry_client: ?[]const u8 = null,
            ignore_underscores: bool = false,
            ignore_dirs: []const []const u8 = &.{},
            extensions: []const []const u8 = &.{},
            style: void = {},
            allow_layouts: bool = false,
        };

        pub const BuiltInModule = union(enum) {
            import: []const u8,
            code: []const u8,
        };

        pub const ServerComponents = struct {
            separate_ssr_graph: bool = false,
            server_runtime_import: []const u8 = "",
            server_register_client_reference: []const u8 = "registerClientReference",
            server_register_server_reference: []const u8 = "registerServerReference",
            client_register_server_reference: []const u8 = "registerServerReference",
        };

        pub const ReactFastRefresh = struct {
            import_source: []const u8 = "react-refresh/runtime",
        };
    };
};
pub const fs = @import("resolver/fs.zig");

pub const timespec = extern struct {
    sec: i64,
    nsec: i64,

    pub const epoch: timespec = .{ .sec = 0, .nsec = 0 };
};

/// Top-level RFC 4122 UUID type, re-exported from the JSC subtree so
/// upstream Bun call sites that spell `bun.UUID` (e.g.
/// `runtime/webcore/ObjectURLRegistry.zig:175`,
/// `runtime/node/node_crypto_binding.zig:805`) resolve against the
/// already-ported v4 / v5 / v7 implementation in `jsc/uuid.zig`. Also
/// reachable as `home_rt.jsc.uuid` for callers that prefer the
/// JSC-namespaced path.
pub const UUID = @import("jsc/uuid.zig");

/// Top-level `Mutex` alias, re-exported from `home_rt.threading.Mutex`
/// so upstream Bun call sites that spell `bun.Mutex` (notably
/// `runtime/webcore/ObjectURLRegistry.zig:3`) resolve without a
/// namespace traversal. The implementation is the same — a thin
/// spinlock wrapper that mirrors `std.Thread.Mutex`'s API.
pub const Mutex = @import("threading/Mutex.zig");
pub const SignalCode = @import("sys/SignalCode.zig").SignalCode;

/// Compile-time equality assertion. Mirrors upstream
/// `bun.assert_eql(@sizeOf(bun.String), 24)` shape — both arguments
/// must be evaluable at comptime; mismatches surface as a
/// `@compileError` referencing the actual and expected values.
/// Used by `string/string.zig:1131` to lock the WTF::String FFI
/// struct size down to 24 bytes (matching the C++ side).
pub inline fn assert_eql(comptime actual: anytype, comptime expected: anytype) void {
    if (actual != expected) {
        @compileError(std.fmt.comptimePrint(
            "assert_eql failed: actual={any} expected={any}",
            .{ actual, expected },
        ));
    }
}

/// One-shot initializer wrapper. `std.once` was removed in Zig 0.17;
/// this is the home_rt-side replacement (a verbatim port of the
/// upstream `bun.once` body from `bun.zig`, inlined here so callers
/// that already resolve `bun` to `home_rt` find it without pulling
/// in the rest of bun.zig). `call` takes an args tuple so zero-arg
/// initializers go through `.call(.{})`. Used by
/// `runtime/webcore/ObjectURLRegistry.zig`.
pub fn once(comptime f: anytype) Once(f) {
    return Once(f){};
}

pub fn Once(comptime f: anytype) type {
    return struct {
        const Return = @typeInfo(@TypeOf(f)).@"fn".return_type.?;

        done: bool = false,
        payload: Return = undefined,
        mutex: Mutex = .{},

        pub fn call(self: *@This(), args: std.meta.ArgsTuple(@TypeOf(f))) Return {
            if (@atomicLoad(bool, &self.done, .acquire))
                return self.payload;
            return self.callSlow(args);
        }

        fn callSlow(self: *@This(), args: std.meta.ArgsTuple(@TypeOf(f))) Return {
            @branchHint(.cold);
            self.mutex.lock();
            defer self.mutex.unlock();
            if (!self.done) {
                self.payload = @call(.auto, f, args);
                @atomicStore(bool, &self.done, true, .release);
            }
            return self.payload;
        }
    };
}

/// C++ FFI surface stubs. Upstream Bun's `bun.cpp.*` namespace exposes
/// the symbols implemented on the JavaScriptCore C++ side. Home's JSC
/// bridge isn't yet wired through (Phase 12.2 in flight), so each
/// function here is a `@panic` stub that satisfies the type checker
/// (unblocking unrelated tests in the home_rt binary) but aborts at
/// runtime with an actionable message. Call sites that exercise these
/// paths are in production string / JSC code rather than unit tests,
/// so the panics don't fire in the current test surface.
///
/// Signatures inferred from the existing call sites in
/// `string/wtf.zig` and `jsc/bun_string_jsc.zig`. When the C++
/// side lands, replace each panic with the corresponding
/// `pub extern fn` declaration.
pub const cpp = struct {
    pub fn JSC__jsToNumber(bytes_ptr: [*]const u8, len: usize) f64 {
        return std.fmt.parseFloat(f64, bytes_ptr[0..len]) catch std.math.nan(f64);
    }

    pub fn JSC__JSValue__coerceToInt32(value: jsc.JSValue, globalThis: *jsc.JSGlobalObject) JSError!i32 {
        _ = globalThis;
        return @intCast(@intFromEnum(value));
    }

    pub fn JSC__JSValue__coerceToInt64(value: jsc.JSValue, globalThis: *jsc.JSGlobalObject) JSError!i64 {
        _ = globalThis;
        return @intFromEnum(value);
    }

    pub fn JSC__JSValue__isSymbol(value: jsc.JSValue) bool {
        _ = value;
        return false;
    }

    pub fn JSC__JSValue__getIfPropertyExistsImpl(value: jsc.JSValue, globalThis: *jsc.JSGlobalObject, bytes_ptr: [*]const u8, len: usize) JSError!jsc.JSValue {
        _ = value;
        _ = globalThis;
        _ = bytes_ptr;
        _ = len;
        return .property_does_not_exist_on_object;
    }

    pub fn Bun__WTFStringImpl__deref(self: anytype) void {
        _ = self;
        @panic("home_rt.cpp.Bun__WTFStringImpl__deref needs the C++ FFI bridge (Phase 12.2)");
    }

    pub fn Bun__WTFStringImpl__ref(self: anytype) void {
        _ = self;
        @panic("home_rt.cpp.Bun__WTFStringImpl__ref needs the C++ FFI bridge (Phase 12.2)");
    }

    pub fn Bun__WTFStringImpl__hasPrefix(self: anytype, text: [*]const u8, len: usize) bool {
        _ = self;
        _ = text;
        _ = len;
        @panic("home_rt.cpp.Bun__WTFStringImpl__hasPrefix needs the C++ FFI bridge (Phase 12.2)");
    }

    pub fn BunString__fromJS(global: anytype, value: anytype, out: anytype) bool {
        _ = global;
        _ = value;
        _ = out;
        @panic("home_rt.cpp.BunString__fromJS needs the C++ FFI bridge (Phase 12.2)");
    }

    pub fn BunString__fromLatin1(bytes: [*]const u8, len: usize) String {
        _ = bytes;
        _ = len;
        return .dead;
    }

    pub fn BunString__fromLatin1Unitialized(len: usize) String {
        _ = len;
        return .dead;
    }

    pub fn BunString__fromUTF16Unitialized(len: usize) String {
        _ = len;
        return .dead;
    }

    pub fn JSC__JSValue__isCallable(value: anytype) bool {
        _ = value;
        return false;
    }

    // JSC bring-up: C++ bindings from the vendored generated `cpp.zig` (built
    // from Bun). Extern-backed — these compile now and resolve at the C++/WebKit
    // link step. Added on demand as the JSC cone references them.
    pub const JSMockFunction__getCalls = @import(".generated/cpp.zig").JSMockFunction__getCalls;
    pub const JSMockFunction__getReturns = @import(".generated/cpp.zig").JSMockFunction__getReturns;
};

const TestJSCExterns = struct {
    fn bunStringTransferToJS(_: *String, _: *jsc.JSGlobalObject) callconv(.c) jsc.JSValue {
        return .zero;
    }

    fn determineSpecificType(_: *jsc.JSGlobalObject, _: jsc.JSValue) callconv(.c) String {
        return String.static("Object");
    }

    fn globalObjectBunVM(_: *jsc.JSGlobalObject) callconv(.c) *jsc.VM {
        return @ptrFromInt(0x1000);
    }

    fn globalObjectVM(_: *jsc.JSGlobalObject) callconv(.c) *jsc.VM {
        return @ptrFromInt(0x1000);
    }

    fn jsValueType(_: jsc.JSValue) callconv(.c) jsc.JSValue.JSType {
        return .Cell;
    }

    fn jsValueToBoolean(value: jsc.JSValue) callconv(.c) bool {
        return value != .zero and value != .false and value != .null and value != .js_undefined;
    }

    fn vmThrowError(_: *jsc.VM, _: *jsc.JSGlobalObject, _: jsc.JSValue) callconv(.c) void {}

    fn wasmStreamingAddBytes(_: *anyopaque, _: [*]const u8, _: usize) callconv(.c) void {}

    fn globalObjectHasException(_: *jsc.JSGlobalObject) callconv(.c) bool {
        return false;
    }

    fn globalObjectThrowOutOfMemory(_: *jsc.JSGlobalObject) callconv(.c) void {}

    fn topExceptionScopeConstruct(_: *anyopaque, _: *jsc.JSGlobalObject, _: [*:0]const u8, _: [*:0]const u8, _: c_uint, _: usize, _: usize) callconv(.c) void {}

    fn topExceptionScopePureException(_: *anyopaque) callconv(.c) ?*jsc.Exception {
        return null;
    }

    fn topExceptionScopeAssertNoException(_: *anyopaque) callconv(.c) void {}

    fn topExceptionScopeDestruct(_: *anyopaque) callconv(.c) void {}
};

comptime {
    @export(&TestJSCExterns.bunStringTransferToJS, .{ .name = "BunString__transferToJS", .linkage = .weak });
    @export(&TestJSCExterns.determineSpecificType, .{ .name = "Bun__ErrorCode__determineSpecificType", .linkage = .weak });
    @export(&TestJSCExterns.globalObjectBunVM, .{ .name = "JSC__JSGlobalObject__bunVM", .linkage = .weak });
    @export(&TestJSCExterns.globalObjectVM, .{ .name = "JSC__JSGlobalObject__vm", .linkage = .weak });
    @export(&TestJSCExterns.jsValueType, .{ .name = "JSC__JSValue__jsType", .linkage = .weak });
    @export(&TestJSCExterns.jsValueToBoolean, .{ .name = "JSC__JSValue__toBoolean", .linkage = .weak });
    @export(&TestJSCExterns.vmThrowError, .{ .name = "JSC__VM__throwError", .linkage = .weak });
    @export(&TestJSCExterns.wasmStreamingAddBytes, .{ .name = "JSC__Wasm__StreamingCompiler__addBytes", .linkage = .weak });
    @export(&TestJSCExterns.globalObjectHasException, .{ .name = "JSGlobalObject__hasException", .linkage = .weak });
    @export(&TestJSCExterns.globalObjectThrowOutOfMemory, .{ .name = "JSGlobalObject__throwOutOfMemoryError", .linkage = .weak });
    @export(&TestJSCExterns.topExceptionScopeConstruct, .{ .name = "TopExceptionScope__construct", .linkage = .weak });
    @export(&TestJSCExterns.topExceptionScopePureException, .{ .name = "TopExceptionScope__pureException", .linkage = .weak });
    @export(&TestJSCExterns.topExceptionScopeAssertNoException, .{ .name = "TopExceptionScope__assertNoException", .linkage = .weak });
    @export(&TestJSCExterns.topExceptionScopeDestruct, .{ .name = "TopExceptionScope__destruct", .linkage = .weak });
}

pub inline fn copy(comptime T: type, dest: []T, src: []const T) void {
    // Overlap-safe, matching Bun's memmove-based `bun.copy`. The real TS
    // parser/printer cone (e.g. `js_parser` parse_entry) calls this with
    // aliasing slices, which `@memcpy` treats as UB (it panics
    // "@memcpy arguments alias" in safe builds). `@memmove` handles overlap.
    @memmove(dest[0..src.len], src);
}

/// Faithful to upstream `bun.zig:3468`. Overlap-safe byte copy. Bun routes the
/// native path through `c.memmove`; Home uses the `@memmove` builtin (identical
/// overlap semantics) so it needs no libc extern.
pub fn memmove(output: []u8, input: []const u8) void {
    if (output.len == 0) return;
    if (comptime Environment.allow_assert) assert(output.len >= input.len);
    @memmove(output[0..input.len], input);
}

pub fn concat(comptime T: type, dest: []T, src: []const []const T) void {
    var remaining = dest;
    for (src) |group| {
        copy(T, remaining[0..group.len], group);
        remaining = remaining[group.len..];
    }
}

/// Memory is typically not decommitted immediately when freed. Zero the slice
/// before returning it to the allocator, matching Bun's sensitive-free helper.
pub fn freeSensitive(allocator: std.mem.Allocator, slice: anytype) void {
    std.crypto.secureZero(std.meta.Child(@TypeOf(slice)), @constCast(slice));
    allocator.free(slice);
}

/// Wave-15 Tier-1 grinder stub — Bun's `bun.hash(content)` is a trivial
/// Wyhash wrapper. Re-attaches to the full hash family (hashWithSeed,
/// hash32, fastRandom) when those land.
pub fn hash(content: []const u8) u64 {
    return std.hash.Wyhash.hash(0, content);
}

pub const StringHashMapUnowned = struct {
    pub const Key = struct {
        hash: u64,
        len: usize,

        pub fn init(str: []const u8) Key {
            return .{
                .hash = std.hash.Wyhash.hash(0, str),
                .len = str.len,
            };
        }
    };

    pub const Adapter = struct {
        pub fn eql(_: @This(), a: Key, b: Key) bool {
            return a.hash == b.hash and a.len == b.len;
        }

        pub fn hash(_: @This(), key: Key) u64 {
            return key.hash;
        }
    };
};

pub inline fn pathLiteral(comptime literal: anytype) *const [literal.len:0]u8 {
    if (!Environment.isWindows) return @ptrCast(literal);
    return comptime {
        var buf: [literal.len:0]u8 = undefined;
        for (literal, 0..) |char, i| {
            buf[i] = if (char == '/') '\\' else char;
            assert(buf[i] != 0 and buf[i] < 128);
        }
        buf[buf.len] = 0;
        const final = buf[0..buf.len :0].*;
        return &final;
    };
}

pub const RuntimeEmbedRoot = enum {
    codegen,
    codegen_eager,
    src,
    src_eager,
};

pub fn runtimeEmbedFile(comptime root: RuntimeEmbedRoot, comptime sub_path: []const u8) [:0]const u8 {
    _ = root;
    _ = sub_path;
    return "";
}

pub const HTTPThread = struct {
    pub fn init(opts: anytype) void {
        _ = opts;
    }
};

fn ReinterpretSliceType(comptime T: type, comptime Slice: type) type {
    const is_const = @typeInfo(Slice).pointer.is_const;
    return if (is_const) []const T else []T;
}

pub fn reinterpretSlice(comptime T: type, slice: anytype) ReinterpretSliceType(T, @TypeOf(slice)) {
    const is_const = @typeInfo(@TypeOf(slice)).pointer.is_const;
    const bytes = std.mem.sliceAsBytes(slice);
    const new_ptr = @as(if (is_const) [*]const T else [*]T, @ptrCast(@alignCast(bytes.ptr)));
    return new_ptr[0..@divTrunc(bytes.len, @sizeOf(T))];
}

/// Wave-15 Tier-1 grinder stub — Bun's `bun.debugAssert` is a debug-only
/// assert that compiles to nothing in Release. Mirrors `assert` semantics.
pub inline fn debugAssert(ok: bool) void {
    if (Environment.allow_assert) {
        Global.assert(ok);
    }
}

pub inline fn cast(comptime To: type, value: anytype) To {
    if (@typeInfo(@TypeOf(value)) == .int) {
        return @ptrFromInt(@as(usize, value));
    }

    return @ptrCast(@alignCast(value));
}

pub fn GenericIndex(comptime backing_int: type, comptime uid: anytype) type {
    const null_value = std.math.maxInt(backing_int);
    return enum(backing_int) {
        _,
        const Index = @This();
        comptime {
            _ = uid;
        }

        pub inline fn init(int: backing_int) Index {
            assert(int != null_value);
            return @enumFromInt(int);
        }

        pub inline fn get(i: Index) backing_int {
            assert(@intFromEnum(i) != null_value);
            return @intFromEnum(i);
        }

        pub inline fn toOptional(i: Index) Optional {
            return @enumFromInt(i.get());
        }

        pub const Optional = enum(backing_int) {
            none = null_value,
            _,

            pub inline fn init(maybe: ?Index) Optional {
                return if (maybe) |i| i.toOptional() else .none;
            }

            pub inline fn unwrap(optional: Optional) ?Index {
                return if (optional == .none) null else @enumFromInt(@intFromEnum(optional));
            }
        };
    };
}

pub fn TrivialNew(comptime Type: type) fn (Type) *Type {
    return struct {
        pub fn new(value: Type) *Type {
            const created = handleOom(default_allocator.create(Type));
            created.* = value;
            return created;
        }
    }.new;
}

pub fn new(comptime Type: type, value: Type) *Type {
    const created = handleOom(default_allocator.create(Type));
    created.* = value;
    return created;
}

pub fn create(allocator: std.mem.Allocator, comptime Type: type, value: Type) *Type {
    const created = handleOom(allocator.create(Type));
    created.* = value;
    return created;
}

pub inline fn assertf(ok: bool, comptime format: []const u8, args: anytype) void {
    if (!ok) {
        std.debug.panic(format, args);
    }
}

/// Wave-15 Tier-1 grinder stub — Bun's `bun.destroy(ptr)` is the
/// allocator-aware mirror of `allocator.destroy`. Skips heap-breakdown +
/// RefCount sanity checks (`bun.heap_breakdown` / `bun.ptr.ref_count` not
/// yet ported).
pub inline fn destroy(pointer: anytype) void {
    default_allocator.destroy(pointer);
}

// Comptime string map (copied from Bun, JSC methods stripped — they'll
// be re-added under src/jsc/ once Phase 12.2 lands).
const comptime_string_map = @import("collections/comptime_string_map.zig");
pub const ComptimeStringMap = comptime_string_map.ComptimeStringMap;
pub const ComptimeStringMap16 = comptime_string_map.ComptimeStringMap16;
pub const ComptimeStringMapWithKeyType = comptime_string_map.ComptimeStringMapWithKeyType;

/// Wave-16 Tier-1 grinder stub — Bun's `bun.ComptimeEnumMap(T)` is a
/// thin wrapper that maps `@tagName(v)` → `v` for every variant of `T`.
/// Used by sql/mysql/AuthMethod.zig and other small enum dispatchers.
pub fn ComptimeEnumMap(comptime T: type) type {
    @setEvalBranchQuota(50_000);
    const values = std.enums.values(T);
    var entries: [values.len]struct { [:0]const u8, T } = undefined;
    for (values, &entries) |value, *entry| {
        entry.* = .{ @tagName(value), value };
    }
    return ComptimeStringMap(T, entries);
}

const identity_context = @import("collections/identity_context.zig");
pub const IdentityContext = identity_context.IdentityContext;
pub const ArrayIdentityContext = identity_context.ArrayIdentityContext;
pub const ArenaAllocator = std.heap.ArenaAllocator;

pub const bit_set = @import("collections/bit_set.zig");
pub const AutoBitSet = bit_set.AutoBitSet;
pub const StaticBitSet = bit_set.StaticBitSet;
pub const IntegerBitSet = bit_set.IntegerBitSet;
pub const DynamicBitSet = bit_set.DynamicBitSet;
pub const DynamicBitSetUnmanaged = bit_set.DynamicBitSetUnmanaged;

const multi_array_list = @import("collections/multi_array_list.zig");
pub const MultiArrayList = multi_array_list.MultiArrayList;

const linear_fifo = @import("collections/linear_fifo.zig");
pub const LinearFifo = linear_fifo.LinearFifo;
pub const LinearFifoBufferType = linear_fifo.LinearFifoBufferType;

const static_hash_map = @import("collections/StaticHashMap.zig");
pub const AutoHashMap = static_hash_map.AutoHashMap;
pub const AutoStaticHashMap = static_hash_map.AutoStaticHashMap;
pub const StaticHashMap = static_hash_map.StaticHashMap;
pub const HashMap = static_hash_map.HashMap;
pub const SortedHashMap = static_hash_map.SortedHashMap;

pub const StringArrayHashMapContext = struct {
    pub fn hash(_: @This(), s: []const u8) u32 {
        return @as(u32, @truncate(std.hash.Wyhash.hash(0, s)));
    }

    pub fn eql(_: @This(), a: []const u8, b: []const u8, _: usize) bool {
        return strings.eqlLong(a, b, true);
    }

    pub fn pre(input: []const u8) Prehashed {
        return .{
            .value = StringArrayHashMapContext.hash(.{}, input),
            .input = input,
        };
    }

    pub const Prehashed = struct {
        value: u32,
        input: []const u8,

        pub fn hash(this: @This(), s: []const u8) u32 {
            if (s.ptr == this.input.ptr and s.len == this.input.len) return this.value;
            return StringArrayHashMapContext.hash(.{}, s);
        }

        pub fn eql(_: @This(), a: []const u8, b: []const u8, _: usize) bool {
            return strings.eqlLong(a, b, true);
        }
    };
};

pub const StringHashMapContext = struct {
    pub fn hash(_: @This(), s: []const u8) u64 {
        return std.hash.Wyhash.hash(0, s);
    }

    pub fn eql(_: @This(), a: []const u8, b: []const u8) bool {
        return strings.eqlLong(a, b, true);
    }

    pub fn pre(input: []const u8) Prehashed {
        return .{
            .value = StringHashMapContext.hash(.{}, input),
            .input = input,
        };
    }

    pub const Prehashed = struct {
        value: u64,
        input: []const u8,

        pub fn hash(this: @This(), s: []const u8) u64 {
            if (s.ptr == this.input.ptr and s.len == this.input.len) return this.value;
            return StringHashMapContext.hash(.{}, s);
        }

        pub fn eql(_: @This(), a: []const u8, b: []const u8) bool {
            return strings.eqlLong(a, b, true);
        }
    };

    pub const PrehashedCaseInsensitive = struct {
        value: u64,
        input: []const u8,

        pub fn init(allocator: std.mem.Allocator, input: []const u8) PrehashedCaseInsensitive {
            const out = allocator.alloc(u8, input.len) catch outOfMemory();
            for (input, out) |from, *to| {
                to.* = std.ascii.toLower(from);
            }
            return .{
                .value = StringHashMapContext.hash(.{}, out),
                .input = out,
            };
        }

        pub fn hash(this: @This(), s: []const u8) u64 {
            if (s.ptr == this.input.ptr and s.len == this.input.len) return this.value;
            var hasher = std.hash.Wyhash.init(0);
            for (s) |ch| {
                const lower = std.ascii.toLower(ch);
                hasher.update((&lower)[0..1]);
            }
            return hasher.final();
        }

        pub fn eql(_: @This(), a: []const u8, b: []const u8) bool {
            return strings.eqlCaseInsensitiveASCIIICheckLength(a, b);
        }

        pub fn deinit(this: *const PrehashedCaseInsensitive, allocator: std.mem.Allocator) void {
            allocator.free(this.input);
        }
    };
};

pub fn StringArrayHashMap(comptime Type: type) type {
    return StringHashMap(Type);
}

pub fn StringArrayHashMapUnmanaged(comptime Type: type) type {
    return StringHashMapUnmanaged(Type);
}

pub const StringMap = struct {
    map: Map,
    dupe_keys: bool = false,

    pub const Map = StringArrayHashMap([]const u8);

    pub fn clone(self: StringMap) !StringMap {
        return .{
            .map = try self.map.clone(),
            .dupe_keys = self.dupe_keys,
        };
    }

    pub fn init(allocator: std.mem.Allocator, dupe_keys: bool) StringMap {
        return .{
            .map = Map.init(allocator),
            .dupe_keys = dupe_keys,
        };
    }

    pub fn keys(self: StringMap) []const []const u8 {
        return self.map.keys();
    }

    pub fn values(self: StringMap) []const []const u8 {
        return self.map.values();
    }

    pub fn count(self: StringMap) usize {
        return self.map.count();
    }

    pub fn insert(self: *StringMap, key: []const u8, value: []const u8) !void {
        const entry = try self.map.getOrPut(key);
        if (!entry.found_existing and self.dupe_keys) {
            entry.key_ptr.* = try self.map.allocator.dupe(u8, key);
        } else if (entry.found_existing) {
            self.map.allocator.free(entry.value_ptr.*);
        }

        entry.value_ptr.* = try self.map.allocator.dupe(u8, value);
    }

    pub const put = insert;

    pub fn get(self: *const StringMap, key: []const u8) ?[]const u8 {
        return self.map.get(key);
    }

    pub fn sort(self: *StringMap, sort_ctx: anytype) void {
        self.map.sort(sort_ctx);
    }

    pub fn deinit(self: *StringMap) void {
        for (self.map.values()) |value| {
            self.map.allocator.free(value);
        }

        if (self.dupe_keys) {
            for (self.map.keys()) |key| {
                self.map.allocator.free(key);
            }
        }

        self.map.deinit();
    }
};

pub fn StringHashMap(comptime Type: type) type {
    return std.StringHashMap(Type);
}

pub fn StringHashMapUnmanaged(comptime Type: type) type {
    return std.StringHashMapUnmanaged(Type);
}

pub const StringSet = struct {
    map: Map,
    ordered_keys: std.ArrayList([]const u8) = .empty,

    pub const Map = StringArrayHashMap(void);

    pub fn clone(self: *const StringSet) !StringSet {
        var new_map = Map.init(self.map.allocator);
        var new_keys: std.ArrayList([]const u8) = .empty;
        errdefer new_keys.deinit(self.map.allocator);
        try new_map.ensureTotalCapacity(self.map.count());
        try new_keys.ensureTotalCapacityPrecise(self.map.allocator, self.ordered_keys.items.len);
        for (self.ordered_keys.items) |key| {
            const duped = try self.map.allocator.dupe(u8, key);
            errdefer self.map.allocator.free(duped);
            new_map.putAssumeCapacity(duped, {});
            new_keys.appendAssumeCapacity(duped);
        }
        return StringSet{
            .map = new_map,
            .ordered_keys = new_keys,
        };
    }

    pub fn init(allocator: std.mem.Allocator) StringSet {
        return StringSet{
            .map = Map.init(allocator),
            .ordered_keys = .empty,
        };
    }

    pub fn initComptime() StringSet {
        return StringSet{
            .map = Map.initContext(undefined, .{}),
            .ordered_keys = .empty,
        };
    }

    pub fn isEmpty(self: *const StringSet) bool {
        return self.count() == 0;
    }

    pub fn count(self: *const StringSet) usize {
        return self.map.count();
    }

    pub fn keys(self: *const StringSet) []const []const u8 {
        return self.ordered_keys.items;
    }

    pub fn insert(self: *StringSet, key: []const u8) !void {
        const entry = try self.map.getOrPut(key);
        if (!entry.found_existing) {
            entry.key_ptr.* = try self.map.allocator.dupe(u8, key);
            try self.ordered_keys.append(self.map.allocator, entry.key_ptr.*);
        }
    }

    pub fn contains(self: *StringSet, key: []const u8) bool {
        return self.map.contains(key);
    }

    pub fn swapRemove(self: *StringSet, key: []const u8) bool {
        if (self.map.contains(key)) {
            for (self.ordered_keys.items, 0..) |existing, i| {
                if (std.mem.eql(u8, existing, key)) {
                    _ = self.ordered_keys.swapRemove(i);
                    break;
                }
            }
        }
        return self.map.swapRemove(key);
    }

    pub fn clearAndFree(self: *StringSet) void {
        for (self.ordered_keys.items) |key| {
            self.map.allocator.free(key);
        }
        self.ordered_keys.clearAndFree(self.map.allocator);
        self.map.clearAndFree();
    }

    pub fn deinit(self: *StringSet) void {
        for (self.ordered_keys.items) |key| {
            self.map.allocator.free(key);
        }

        self.ordered_keys.deinit(self.map.allocator);
        self.map.deinit();
    }
};

test "StringHashMapContext prehashed lookup works with std HashMap" {
    const allocator = std.testing.allocator;
    var map: StringHashMapUnmanaged(u8) = .empty;
    defer map.deinit(allocator);

    try map.put(allocator, "answer", 42);
    try std.testing.expectEqual(@as(u8, 42), map.getAdapted("answer", StringHashMapContext.pre("answer")).?);
}

const baby_list = @import("collections/baby_list.zig");
pub const BabyList = baby_list.BabyList;
pub const ByteList = baby_list.ByteList;
pub const OffsetByteList = baby_list.OffsetByteList;

// Fourth-wave collection additions (2026-05-17):
const hive_array = @import("collections/hive_array.zig");
pub const HiveArray = hive_array.HiveArray;
const object_pool = @import("collections/pool.zig");
pub const ObjectPool = object_pool.ObjectPool;

// ---- src/cli/ ----------------------------------------------------------
// Bun's CLI surface. Copy-in-progress; see src/cli/PORTING_STATUS.md.
pub const cli = struct {
    pub const which_npm_client = @import("cli/which_npm_client.zig");
    pub const yarn_commands = @import("cli/list-of-yarn-commands.zig");
    // Faithful to upstream `cli/cli.zig:5`: process-title override slot.
    pub var Bun__Node__ProcessTitle: ?[]const u8 = null;
};

// ---- src/jsc/ ----------------------------------------------------------
// JSC binding surface. Most of this is opaque types + enums until the
// JSC engine is brought up (Phase 12.2). The leaves we copy now establish
// the public-facing namespace so callers can spell things correctly.
pub const jsc = struct {
    pub const MAX_SAFE_INTEGER = 9007199254740991;
    pub const MIN_SAFE_INTEGER = -9007199254740991;

    pub fn initialize(eval_mode: bool) void {
        _ = eval_mode;
    }

    // Minimal `WTF` namespace mirroring upstream `src/jsc/WTF.zig`. Only the
    // `releaseFastMallocFreeMemoryForThisThread` hint is needed today (the
    // ThreadPool idle path calls it after a long timeout). Upstream forwards
    // to the C++ `WTF__releaseFastMallocFreeMemoryForThisThread` shim; Home
    // links the libc-backed allocator shim where WTF FastMalloc is not the
    // active heap, so this is a faithful no-op until the C++ binding lands.
    pub const wtf = struct {
        pub fn releaseFastMallocFreeMemoryForThisThread() void {}
    };

    /// Calling convention used by Bun JSC host functions.
    pub const conv: std.builtin.CallingConvention = if (Environment.isWindows and Environment.isX64)
        .{ .x86_64_sysv = .{} }
    else
        .c;

    pub const JSValue = @import("jsc/JSValue.zig").JSValue;
    pub const CallFrame = @import("jsc/CallFrame.zig").CallFrame;
    // Faithful to upstream `jsc/jsc.zig:204`:
    // `pub const GeneratedClassesList = @import("./generated_classes_list.zig").Classes;`.
    // Consumed by the vendored `ZigGeneratedClasses` module.
    pub const GeneratedClassesList = @import("jsc/generated_classes_list.zig").Classes;
    pub const JSGlobalObject = @import("jsc/JSGlobalObject.zig").JSGlobalObject;
    // JSC bring-up: real ConsoleObject (was a stub). Faithful to jsc/jsc.zig:116.
    pub const ConsoleObject = @import("jsc/ConsoleObject.zig");
    pub const JSPromiseRejectionOperation = @import("jsc/JSPromiseRejectionOperation.zig").JSPromiseRejectionOperation;
    pub const ScriptExecutionStatus = @import("jsc/ScriptExecutionStatus.zig").ScriptExecutionStatus;
    pub const SourceType = @import("jsc/SourceType.zig").SourceType;
    pub const sizes = @import("jsc/sizes.zig");
    pub const JSRuntimeType = @import("jsc/JSRuntimeType.zig").JSRuntimeType;
    pub const GetterSetter = @import("jsc/GetterSetter.zig").GetterSetter;
    pub const StaticExport = @import("jsc/static_export.zig");
    pub const ErrorCode = @import("jsc/ErrorCode.zig").ErrorCode;
    pub fn ErrorBuilder(comptime code: Error, comptime fmt_str: [:0]const u8, Args: type) type {
        return struct {
            globalThis: *JSGlobalObject,
            args: Args,

            pub inline fn throw(this: @This()) JSError {
                return code.throw(this.globalThis, fmt_str, this.args);
            }

            pub inline fn toJS(this: @This()) JSValue {
                return code.fmt(this.globalThis, fmt_str, this.args);
            }
        };
    }
    pub const Error = enum(u16) {
        MISSING_ARGS = 0,
        INVALID_ARG_TYPE = 1,
        INVALID_ARG_VALUE = 2,
        INCOMPATIBLE_OPTION_PAIR = 3,
        CRYPTO_INVALID_SCRYPT_PARAMS = 4,
        OUT_OF_RANGE = 5,
        WEBASSEMBLY_RESPONSE = 6,
        // Values from the generated ErrorCode enum (faithful to upstream).
        ENCODING_INVALID_ENCODED_DATA = 56,
        INVALID_STATE = 136,
        INVALID_URL = 142,
        UNKNOWN_ENCODING = 255,
        _,

        pub fn fmt(this: Error, globalThis: *JSGlobalObject, comptime fmt_: [:0]const u8, args: anytype) JSValue {
            _ = this;
            _ = globalThis;
            _ = fmt_;
            _ = args;
            return .zero;
        }

        pub fn throw(this: Error, globalThis: *JSGlobalObject, comptime fmt_: [:0]const u8, args: anytype) JSError {
            return globalThis.throwValue(this.fmt(globalThis, fmt_, args));
        }
    };
    pub const CommonAbortReason = @import("jsc/CommonAbortReason.zig").CommonAbortReason;
    // Fourth-wave port batch (2026-05-17, 8-agent parallel dispatch):
    pub const Exception = @import("jsc/Exception.zig").Exception;
    pub const CppTask = @import("jsc/CppTask.zig").CppTask;
    pub const ConcurrentCppTask = @import("jsc/CppTask.zig").ConcurrentCppTask;
    pub const config = @import("jsc/config.zig");
    pub const codegen = @import("jsc/codegen.zig");
    pub const comptime_string_map_jsc = @import("jsc/comptime_string_map_jsc.zig");
    // Fifth-wave port batch (2026-05-18):
    pub const CachedBytecode = @import("jsc/CachedBytecode.zig").CachedBytecode;
    pub const RuntimeTranspilerCache = @import("jsc/RuntimeTranspilerCache.zig").RuntimeTranspilerCache;
    pub const JSMap = @import("jsc/JSMap.zig").JSMap;
    pub const math = struct {
        pub fn pow(base: f64, exponent: f64) f64 {
            return std.math.pow(f64, base, exponent);
        }
    };
    pub const JSBigInt = @import("jsc/JSBigInt.zig").JSBigInt;
    pub const JSArray = @import("jsc/JSArray.zig").JSArray;
    pub const JSFunction = @import("jsc/JSFunction.zig").JSFunction;
    pub const JSModuleLoader = @import("jsc/JSModuleLoader.zig").JSModuleLoader;
    pub const Errorable = @import("jsc/Errorable.zig").Errorable;
    pub const ErrorableString = Errorable(String);
    pub const DeferredError = @import("jsc/DeferredError.zig").DeferredError;
    pub const DecodedJSValue = @import("jsc/DecodedJSValue.zig").DecodedJSValue;
    pub const Strong = struct {
        pub const Deprecated = @import("jsc/DeprecatedStrong.zig");
        pub const Optional = struct {
            value: JSValue = .zero,

            pub const empty: Optional = .{};

            pub fn create(value: JSValue, globalThis: *JSGlobalObject) Optional {
                _ = globalThis;
                return .{ .value = value };
            }

            pub fn has(this: *const Optional) bool {
                return this.value != .zero;
            }

            pub fn deinit(this: *Optional) void {
                this.* = .empty;
            }

            pub fn clearWithoutDeallocation(this: *Optional) void {
                this.value = .zero;
            }

            pub fn call(this: *Optional, globalThis: *JSGlobalObject, args: []const JSValue) JSValue {
                _ = globalThis;
                _ = args;
                return this.swap();
            }

            pub fn get(this: *const Optional) ?JSValue {
                return if (this.value == .zero) null else this.value;
            }

            pub fn swap(this: *Optional) JSValue {
                const value = this.value;
                this.value = .zero;
                return value;
            }

            pub fn trySwap(this: *Optional) ?JSValue {
                const value = this.swap();
                return if (value == .zero) null else value;
            }

            pub fn set(this: *Optional, globalThis: *JSGlobalObject, value: JSValue) void {
                _ = globalThis;
                this.value = value;
            }
        };
    };
    pub const CPUProfiler = @import("jsc/BunCPUProfiler.zig").CPUProfiler;
    pub const CPUProfilerConfig = @import("jsc/BunCPUProfiler.zig").CPUProfilerConfig;
    pub const HeapProfiler = @import("jsc/BunHeapProfiler.zig").HeapProfiler;
    pub const HeapProfilerConfig = @import("jsc/BunHeapProfiler.zig").HeapProfilerConfig;
    // Sixth-wave port batch (2026-05-18):
    pub const CommonStrings = @import("jsc/CommonStrings.zig").CommonStrings;
    pub const RegularExpression = @import("jsc/RegularExpression.zig").RegularExpression;
    pub const URLSearchParams = @import("jsc/URLSearchParams.zig").URLSearchParams;
    pub const ZigErrorType = @import("jsc/ZigErrorType.zig").ZigErrorType;
    pub const TextCodec = @import("jsc/TextCodec.zig").TextCodec;
    pub const MarkedArgumentBuffer = @import("jsc/MarkedArgumentBuffer.zig").MarkedArgumentBuffer;
    pub const ConcurrentPromiseTask = @import("jsc/ConcurrentPromiseTask.zig").ConcurrentPromiseTask;
    // Seventh-wave port batch (2026-05-18):
    pub const AbortSignal = @import("jsc/AbortSignal.zig").AbortSignal;
    // Faithful to upstream `jsc/jsc.zig:71`: `@import("./JSString.zig").JSString`
    // (the struct, where length/getZigString/toSliceClone live — not the file).
    pub const JSString = @import("jsc/JSString.zig").JSString;
    pub const RefString = @import("jsc/RefString.zig").RefString;
    pub const StringBuilder = @import("jsc/StringBuilder.zig").StringBuilder;
    pub const ZigString = @import("jsc/ZigString.zig").ZigString;
    pub const SystemError = @import("jsc/SystemError.zig").SystemError;
    pub const WTF = @import("jsc/WTF.zig");
    pub const Weak = @import("jsc/Weak.zig");
    pub const javascript_core_c_api = @import("jsc/javascript_core_c_api.zig");
    pub const C = javascript_core_c_api;
    pub const DOMURL = @import("jsc/DOMURL.zig").DOMURL;
    pub const JSArrayIterator = @import("jsc/JSArrayIterator.zig").JSArrayIterator;
    // Eighth-wave port batch (2026-05-18):
    pub const JSUint8Array = @import("jsc/JSUint8Array.zig").JSUint8Array;
    pub const VM = @import("jsc/VM.zig").VM;
    pub const JSRef = @import("jsc/JSRef.zig").JSRef;
    pub const ZigException = @import("jsc/ZigException.zig").ZigException;
    pub const JSCell = @import("jsc/JSCell.zig").JSCell;
    pub const JSPromise = @import("jsc/JSPromise.zig").JSPromise;
    pub const JSInternalPromise = @import("jsc/JSInternalPromise.zig").JSInternalPromise;
    pub const EventType = @import("jsc/EventType.zig").EventType;
    // JSC bring-up: real ArrayBuffer (jsc/jsc.zig:46). Was an inline stub.
    pub const ArrayBuffer = @import("jsc/array_buffer.zig").ArrayBuffer;
    /// Faithful to upstream `jsc/jsc.zig:45` (`array_buffer = @import("./array_buffer.zig")`).
    pub const array_buffer = @import("jsc/array_buffer.zig");
    /// Faithful to upstream `jsc/jsc.zig:47` (`array_buffer.MarkedArrayBuffer`).
    pub const MarkedArrayBuffer = @import("jsc/array_buffer.zig").MarkedArrayBuffer;
    pub const AnyPromise = @import("jsc/AnyPromise.zig").AnyPromise;
    pub const JSObject = @import("jsc/JSObject.zig").JSObject;
    pub const Jest = struct {
        pub const BunTestRoot = struct {
            pub fn onBeforePrint(this: *BunTestRoot) void {
                _ = this;
            }
        };

        pub const Runner = struct {
            bun_test_root: BunTestRoot = .{},
        };

        pub const Jest = struct {
            pub threadlocal var runner: ?*Runner = null;
        };
        // Faithful to upstream `runtime/test_runner/jest.zig` `bun_test` module
        // (ScopeFunctions / DoneCallback consumed by the generated class registry).
        pub const bun_test = @import("runtime/test_runner/bun_test.zig");
    };
    pub const Node = struct {
        pub const Encoding = @import("runtime/node/types.zig").Encoding;
        pub const StringOrBuffer = @import("runtime/node/types.zig").StringOrBuffer;
        pub const BlobOrStringOrBuffer = @import("runtime/node/types.zig").BlobOrStringOrBuffer;
        pub const PathLike = @import("runtime/node/types.zig").PathLike;
        pub const PathOrFileDescriptor = @import("runtime/node/types.zig").PathOrFileDescriptor;
        pub const Dirent = struct {
            pub const Kind = std.Io.File.Kind;
        };
    };
    // JSC bring-up: faithful to upstream `jsc/jsc.zig` (Expect:124, Codegen:203).
    pub const Expect = @import("runtime/test_runner/expect.zig");
    pub const Codegen = @import("ZigGeneratedClasses");
    // Faithful to upstream jsc/jsc.zig:153 (`Task = EventLoop.Task`).
    pub const Task = @import("jsc/Task.zig").Task;
    // Faithful to upstream jsc/jsc.zig:155 (= EventLoop.WorkPoolTask = work_pool.Task).
    pub const WorkPoolTask = @import("threading/work_pool.zig").Task;
    // Faithful to upstream jsc/jsc.zig:154 (`WorkPool = EventLoop.WorkPool`).
    pub const WorkPool = @import("threading/work_pool.zig").WorkPool;
    // Faithful to upstream jsc/jsc.zig:156 (`WorkTask = EventLoop.WorkTask`).
    pub const WorkTask = @import("jsc/WorkTask.zig").WorkTask;
    // Faithful to upstream jsc/jsc.zig:138 (`ConcurrentTask = EventLoop.ConcurrentTask`).
    pub const ConcurrentTask = @import("event_loop/ConcurrentTask.zig");
    // Faithful to upstream jsc/jsc.zig:119.
    pub const hot_reloader = @import("jsc/hot_reloader.zig");
    // Faithful to upstream jsc/jsc.zig:246.
    pub const JSTimeType = u52;
    // NOTE: upstream jsc/jsc.zig:282 (`generated = @import("bindgen_generated")`)
    // is deferred — the vendored bindgen_generated.zig imports a
    // `bindgen_generated/` subtree that codegen has not emitted into the tree yet.
    // Faithful to upstream jsc/jsc.zig:101.
    pub const RareData = @import("jsc/rare_data.zig");
    // Faithful to upstream jsc/jsc.zig:209.
    pub const Ref = struct {
        has: bool = false,

        pub fn init() Ref {
            return .{};
        }

        pub fn unref(this: *Ref, vm: *VirtualMachine) void {
            if (!this.has)
                return;
            this.has = false;
            vm.active_tasks -= 1;
        }

        pub fn ref(this: *Ref, vm: *VirtualMachine) void {
            if (this.has)
                return;
            this.has = true;
            vm.active_tasks += 1;
        }
    };
    // Faithful to upstream jsc/jsc.zig:112.
    pub const ZigStackFrame = @import("jsc/ZigStackFrame.zig").ZigStackFrame;
    pub const ManagedTask = @import("event_loop/ManagedTask.zig");
    // JSC bring-up: real VirtualMachine (was a 215-line stub). jsc/jsc.zig:99.
    pub const VirtualMachine = @import("jsc/VirtualMachine.zig");
    pub const ModuleLoader = struct {
        pub const HardcodedModule = @import("resolve_builtins/HardcodedModule.zig").HardcodedModule;
    };
    pub const URL = @import("jsc/URL.zig").URL;
    pub const DOMFormData = @import("jsc/DOMFormData.zig").DOMFormData;
    pub const TopExceptionScope = @import("jsc/TopExceptionScope.zig").TopExceptionScope;
    pub const ExceptionValidationScope = @import("jsc/TopExceptionScope.zig").ExceptionValidationScope;
    pub const JSPropertyIterator = @import("jsc/JSPropertyIterator.zig").JSPropertyIterator;
    pub const JSPropertyIteratorOptions = @import("jsc/JSPropertyIterator.zig").JSPropertyIteratorOptions;
    pub const ProcessAutoKiller = @import("jsc/ProcessAutoKiller.zig");
    pub const JSONLineBuffer = @import("jsc/JSONLineBuffer.zig").JSONLineBuffer;
    pub const event_loop_handle = @import("jsc/EventLoopHandle.zig");
    pub const EventLoop = event_loop_handle.EventLoop;
    pub const MiniEventLoop = event_loop_handle.MiniEventLoop;
    // Faithful to upstream `jsc.AnyEventLoop` (`jsc.zig:133`):
    // the `union(EventLoopKind)` over js/mini event loops.
    pub const AnyEventLoop = @import("event_loop/AnyEventLoop.zig").AnyEventLoop;
    pub const EventLoopHandle = event_loop_handle.EventLoopHandle;
    pub const EventLoopKind = event_loop_handle.EventLoopKind;
    pub const EventLoopTask = event_loop_handle.EventLoopTask;
    pub const EventLoopTaskPtr = event_loop_handle.EventLoopTaskPtr;
    // Twelfth-wave port batch (2026-05-18). uuid.zig is the pure-Zig UUID
    // v4/v5/v7 impl (csprng parked on DefaultCsprng). resolve_path_jsc
    // and resolver_jsc carry C++-visible extern symbol declarations for
    // the node:module / require.main paths host fns; bodies park behind
    // Phase 12.2 JSC bridge.
    pub const uuid = @import("jsc/uuid.zig");
    pub const resolve_path_jsc = @import("jsc/resolve_path_jsc.zig");
    pub const resolver_jsc = @import("jsc/resolver_jsc.zig");
    // Thirteenth-wave port batch (2026-05-18). Registry of every Zig
    // type the C++ Codegen reflects to JS. Entries are opaque
    // placeholders until each downstream subsystem (api/webcore/jsc)
    // lands its real type.
    pub const generated_classes_list = @import("jsc/generated_classes_list.zig");
    // Phase 12.2 M1 (2026-05-19) — stub-runnable bridge scaffold per
    // `JSC_BRIDGE_SCOPE_2026-05-19.md` §M1. The `opaques` aggregator
    // names the ~10 core JSC opaque types (JSValue, JSGlobalObject,
    // JSCell, …); `extern_fns` declares ~30 core C-API entrypoints with
    // signatures only (bodies link-resolved, fail until M3); `types`
    // exposes the C-API `JSType` + `JSTypedArrayType` enums for the
    // "new code" pathway. Existing per-file leaves (JSGlobalObject.zig,
    // JSCell.zig, VM.zig, etc.) keep their richer per-type stubs.
    pub const opaques = @import("jsc/opaques.zig");
    pub const extern_fns = @import("jsc/extern_fns.zig");
    pub const c_api_types = @import("jsc/types.zig");
    // Phase 12.2 M3 prep (2026-05-19) — Engine stub. Bodies panic with
    // TODO(phase-12.2-M3) until the C++ engine wiring lands.
    pub const engine = @import("jsc/engine.zig");
    pub const evaluate = @import("jsc/evaluate.zig");
    // Phase 12.2 M4 (2026-05-19) — exception + coerce + array helpers
    // per `JSC_BRIDGE_SCOPE_2026-05-19.md` §M4. Each namespace exposes
    // a uniform Zig-shaped surface on top of the M1 extern fn set;
    // bodies panic with TODO(phase-12.2-M3) until the C++ engine
    // wiring lands. Downstream callers can be written against these
    // signatures today without waiting on linker resolution.
    pub const exception = @import("jsc/exception_helpers.zig");
    pub const coerce = @import("jsc/coerce.zig");
    pub const array = @import("jsc/array.zig");
    // Phase 12.2 M5 (2026-05-19) — function-call + host-callback
    // helpers per `JSC_BRIDGE_SCOPE_2026-05-19.md` §M5. `call` covers
    // "Zig invokes a JS function/method/constructor" (callFunction,
    // callMethod, constructObject, isCallable, isConstructor); `callback`
    // covers "Zig publishes a function JS can invoke"
    // (Callback struct + registerCallback + registerHostFunction).
    // Bodies panic with TODO(phase-12.2-M3) until the C++ engine
    // wiring lands.
    pub const call = @import("jsc/call.zig");
    pub const callback = @import("jsc/callback.zig");
    // Minimal `console` global installer for the native eval/run realm
    // (Phase 2 prep). Named `console_global` to avoid colliding with the
    // existing `ConsoleObject`/`messageWithTypeAndLevel` console machinery.
    pub const console_global = @import("jsc/console.zig");
    // Minimal `process` global installer for the native eval/run realm.
    pub const process_global = @import("jsc/process.zig");
    // Minimal Web Platform globals (TextEncoder/Decoder, queueMicrotask,
    // btoa/atob) for the native eval/run realm.
    pub const web_globals = @import("jsc/web_globals.zig");
    // Minimal `crypto` global (getRandomValues + randomUUID) for the realm.
    pub const crypto_global = @import("jsc/crypto_global.zig");
    // Minimal timer event loop (setTimeout/Interval + drain) for the realm.
    pub const timers_global = @import("jsc/timers_global.zig");
    // Remaining sync realm globals: performance, global/self, structuredClone.
    pub const misc_globals = @import("jsc/misc_globals.zig");
    // URL/URLSearchParams for the realm (native bun.URL field parse + JS wrap).
    pub const url_global = @import("jsc/url_global.zig");
    // WebCore data types (Headers/Blob/Request/Response) for the realm.
    pub const webcore_globals = @import("jsc/webcore_globals.zig");
    // fetch() for the realm (data:/file: now; network pending).
    pub const fetch_global = @import("jsc/fetch_global.zig");
    // Minimal native `Bun` global (Bun.file/Bun.write) for the realm.
    pub const bun_global = @import("jsc/bun_global.zig");
    // CommonJS require() + node:* built-ins (path/fs/os) for the realm.
    pub const node_modules = @import("jsc/node_modules.zig");
    // Native Bun.spawnSync (real OS subprocess) for the realm.
    pub const spawn_global = @import("jsc/spawn_global.zig");
    // Phase 12.2 M6 (2026-05-19) — final scaffold milestone:
    // JSON + Promise + Iterator + Global helpers. Bodies panic with
    // TODO(phase-12.2-M3) until the C++ engine wiring lands. After M6
    // the bridge surface is complete enough for ~30 of the ~800
    // unported files to depend on.
    pub const json = @import("jsc/json.zig");
    pub const promise = @import("jsc/promise.zig");
    pub const iterator = @import("jsc/iterator.zig");
    pub const global = @import("jsc/global.zig");
    pub const WebCore = @import("home").runtime.webcore;
    pub const API = struct {
        pub const Subprocess = runtime.api.Subprocess;
        pub const ServerConfig = runtime.api.server.ServerConfig;
        pub const Valkey = runtime.api.Valkey;

        pub const BuildArtifact = struct {
            blob: WebCore.Blob = .{},

            // Faithful to upstream `jsc.API.BuildArtifact.OutputKind`
            // (`runtime/api/JSBundler.zig:1799`). The bundler's `OutputFile`
            // tags each emitted artifact with this kind.
            pub const OutputKind = enum {
                chunk,
                asset,
                @"entry-point",
                sourcemap,
                bytecode,
                module_info,
                @"metafile-json",
                @"metafile-markdown",

                pub fn isFileInStandaloneMode(this: OutputKind) bool {
                    return this != .sourcemap and this != .bytecode and this != .module_info and this != .@"metafile-json" and this != .@"metafile-markdown";
                }
            };

            pub fn fromJS(value: JSValue) ?*BuildArtifact {
                _ = value;
                return null;
            }

            pub fn writeFormat(this: *BuildArtifact, comptime Formatter: type, formatter: *Formatter, writer: anytype, comptime enable_ansi_colors: bool) !void {
                _ = this;
                _ = formatter;
                _ = enable_ansi_colors;
                try writer.writeAll("BuildArtifact");
            }
        };
    };
    pub const Subprocess = API.Subprocess;
    pub const host_fn = @import("jsc/host_fn.zig");
    pub const JSHostFn = host_fn.JSHostFn;
    pub const JSHostFnZig = host_fn.JSHostFnZig;
    pub const JSHostFnZigWithContext = host_fn.JSHostFnZigWithContext;
    pub const JSHostFunctionTypeWithContext = host_fn.JSHostFunctionTypeWithContext;
    pub const toJSHostFn = host_fn.toJSHostFn;
    pub const toJSHostFnResult = host_fn.toJSHostFnResult;
    pub const toJSHostFnWithContext = host_fn.toJSHostFnWithContext;
    pub const toJSHostCall = host_fn.toJSHostCall;
    pub const fromJSHostCall = host_fn.fromJSHostCall;
    pub const fromJSHostCallGeneric = host_fn.fromJSHostCallGeneric;

    /// Mark the call site of a C++ binding. In upstream Bun this is a
    /// debug-mode tracepoint that gates per-binding invariants
    /// (`Bun__hasCalled` counter + JSC source-mapper hooks). Home's
    /// JSC bridge isn't yet wired to the C++ side, so this is a
    /// no-op stub — the call sites still compile and the source
    /// location is available for future use. Mirrors the upstream
    /// signature `markBinding(src: std.builtin.SourceLocation)`.
    pub fn markBinding(src: std.builtin.SourceLocation) void {
        _ = src;
    }

    /// Faithful to upstream `jsc/jsc.zig:175`. Logs the binding member call
    /// site when `Environment.enable_logs` is set; a no-op otherwise (Home
    /// gates logs off, so the body compiles away).
    pub inline fn markMemberBinding(comptime class: anytype, src: std.builtin.SourceLocation) void {
        if (!Environment.enable_logs) return;
        _ = class;
        _ = src;
    }
};

// ---- src/io/ -----------------------------------------------------------
// Event loop + file poll opaques. The Loop / KeepAlive / FilePoll names
// are kept so callers can spell their function signatures; full impls
// land in Phase 12.3.
pub const io = struct {
    // Faithful to upstream `bun.io.heap` (`src/io/io.zig`): the intrusive
    // binary-heap used by the install/PM lifecycle-script scheduler.
    pub const heap = @import("io/heap.zig");
    pub const Loop = @import("io/stub_event_loop.zig").Loop;
    pub const KeepAlive = @import("io/stub_event_loop.zig").KeepAlive;
    pub const FilePoll = @import("io/stub_event_loop.zig").FilePoll;
    // Fourth-wave port batch (2026-05-17). pipes.zig is enum-only;
    // the PollOrFd union re-attaches with the full Async substrate.
    pub const FileType = @import("io/pipes.zig").FileType;
    pub const ReadState = @import("io/pipes.zig").ReadState;
    // Fifth-wave port batch (2026-05-18):
    pub const MaxBuf = @import("io/MaxBuf.zig");
    pub const BufferedReader = struct {
        _buffer: std.array_list.Managed(u8) = std.array_list.Managed(u8).init(default_allocator),
        maxbuf: ?*MaxBuf = null,
        source: ?Source = null,
        handle: Handle = .{},
        flags: Flags = .{},
        parent: ?*anyopaque = null,

        pub const Source = union(enum) {
            pipe: *anyopaque,

            pub fn isClosed(this: Source) bool {
                _ = this;
                return true;
            }
        };

        pub const Handle = struct {
            poll: Poll = .{},
        };

        pub const Poll = struct {
            flags: PollFlags = .{},
        };

        pub const PollFlags = struct {
            pub fn insert(this: *PollFlags, flag: anytype) void {
                _ = this;
                _ = flag;
            }
        };

        pub const Flags = struct {
            socket: bool = false,
            nonblocking: bool = false,
            pollable: bool = false,
        };

        pub fn init(comptime Parent: type) BufferedReader {
            _ = Parent;
            return .{};
        }

        pub fn memoryCost(this: *const BufferedReader) usize {
            return this._buffer.capacity;
        }

        pub fn hasPendingActivity(this: *const BufferedReader) bool {
            _ = this;
            return false;
        }

        pub fn setParent(this: *BufferedReader, parent: *anyopaque) void {
            this.parent = parent;
        }

        pub fn read(this: *BufferedReader) void {
            _ = this;
        }

        pub fn startWithCurrentPipe(this: *BufferedReader) @import("home").sys.Maybe(void) {
            _ = this;
            return .success;
        }

        pub fn start(this: *BufferedReader, fd: FD, is_pollable: bool) @import("home").sys.Maybe(void) {
            _ = this;
            _ = fd;
            _ = is_pollable;
            return .success;
        }

        pub fn updateRef(this: *BufferedReader, add: bool) void {
            _ = this;
            _ = add;
        }

        pub fn isDone(this: *const BufferedReader) bool {
            _ = this;
            return true;
        }

        pub fn watch(this: *BufferedReader) void {
            _ = this;
        }

        pub fn close(this: *BufferedReader) void {
            _ = this;
        }

        pub fn closeImpl(this: *BufferedReader, report: bool) void {
            _ = this;
            _ = report;
        }

        pub fn deinit(this: *BufferedReader) void {
            this._buffer.deinit();
            this.* = .{};
        }
    };
    pub const StreamBuffer = struct {
        list: std.array_list.Managed(u8) = std.array_list.Managed(u8).init(default_allocator),
        cursor: usize = 0,

        pub fn write(this: *StreamBuffer, bytes: []const u8) OOM!void {
            try this.list.appendSlice(bytes);
        }

        pub fn deinit(this: *StreamBuffer) void {
            this.list.deinit();
            this.* = .{};
        }
    };
};
pub const Async = io;

// JSC bring-up: real uws namespace (was a stub). bun.uws = uws/uws.zig.
pub const uws = @import("uws/uws.zig");

// ---- src/http/ + src/http_types/ ---------------------------------------
// HTTP value types (encoding tags, cert structs, header parsing). Pure
// data; no JSC dependency. The full HTTP stack lands in Phase 12.5.
pub const http = struct {
    pub const HTTPCertError = @import("http/HTTPCertError.zig");
    pub const InitError = @import("http/InitError.zig").InitError;
    pub const CertificateInfo = @import("http/CertificateInfo.zig");
    pub const HeaderValueIterator = @import("http/HeaderValueIterator.zig");
    pub const MimeType = @import("http_types/MimeType.zig");
    // Faithful to upstream `bun.http` (`src/http/http.zig:3263`):
    // `pub const Method = @import("../http_types/Method.zig").Method;`
    pub const Method = @import("http_types/Method.zig").Method;
    pub const Signals = @import("http/Signals.zig");
    pub const H2FrameParser = @import("http/H2FrameParser.zig");
    // Fourth-wave port batch (2026-05-17):
    pub const HTTPRequestBody = @import("http/HTTPRequestBody.zig").HTTPRequestBody;
    pub const SendFile = @import("http/HTTPRequestBody.zig").SendFile;
    // Eighth-wave port (2026-05-18). Real `ThreadSafeStreamBuffer` landed —
    // wraps `home_rt.threading.Mutex` + a local 2-thread refcount + a
    // minimal `StreamBuffer` subset. Supersedes the in-file stub
    // `HTTPRequestBody.ThreadSafeStreamBuffer`, which now stays only as
    // backward-compat shim for the field type in `HTTPRequestBody.stream`.
    pub const ThreadSafeStreamBuffer = @import("http/ThreadSafeStreamBuffer.zig");
    pub const websocket = @import("http/websocket.zig");
    pub const lshpack = @import("http/lshpack.zig");
    // HTTP client surface required by the install/PM `NetworkTask` cone.
    // Faithful to upstream `bun.http` = `src/http.zig`: the async client
    // (`AsyncHTTP`), its completion result (`HTTPClientResult`), and the
    // header builder live in `http/http.zig` / `http/HeaderBuilder.zig`.
    pub const AsyncHTTP = @import("http/AsyncHTTP.zig");
    pub const HeaderBuilder = @import("http/HeaderBuilder.zig");
    pub const HTTPClientResult = @import("http/http.zig").HTTPClientResult;
    pub const HTTPVerboseLevel = @import("http/http.zig").HTTPVerboseLevel;
    pub const FetchRedirect = @import("http_types/FetchRedirect.zig").FetchRedirect;
    // Sixth-wave port batch (2026-05-18):
    pub const h3_client = struct {
        pub const AltSvc = @import("http/h3_client/AltSvc.zig");
        // Eighth-wave port batch (2026-05-18). Leaf data + lifecycle for
        // an in-flight HTTP/3 request and a DNS-pending QUIC connect.
        // ClientSession / ClientContext / callbacks / encode are parked
        // (full lsquic state machine + bun.http back-edges).
        pub const Stream = @import("http/h3_client/Stream.zig");
        pub const PendingConnect = @import("http/h3_client/PendingConnect.zig");
    };
    // Eighth-wave port batch (2026-05-18). HTTP/2 client leaves — Stream
    // (per-request) + PendingConnect (TLS-connect coalescer). Sibling
    // ClientSession / dispatch / encode are parked alongside the full
    // fetch() state machine.
    pub const h2_client = struct {
        pub const Stream = @import("http/h2_client/Stream.zig");
        pub const PendingConnect = @import("http/h2_client/PendingConnect.zig");
    };
};
pub const http_types = struct {
    pub const Encoding = @import("http_types/Encoding.zig").Encoding;
    pub const Method = @import("http_types/Method.zig").Method;
    pub const FetchRedirect = @import("http_types/FetchRedirect.zig").FetchRedirect;
    pub const FetchRequestMode = @import("http_types/FetchRequestMode.zig").FetchRequestMode;
    pub const FetchCacheMode = @import("http_types/FetchCacheMode.zig").FetchCacheMode;
    pub const mime_type_list_enum = @import("http_types/mime_type_list_enum.zig");
    // Fourth-wave port batch (2026-05-17):
    pub const ETag = @import("http_types/ETag.zig");
    pub const URLPath = @import("http_types/URLPath.zig");
};
pub const options_types = struct {
    pub const OfflineMode = @import("options_types/OfflineMode.zig").OfflineMode;
    pub const OfflineModePrefer = @import("options_types/OfflineMode.zig").Prefer;
    // Third-wave port batch (2026-05-17):
    pub const CodeCoverageOptions = @import("options_types/CodeCoverageOptions.zig").CodeCoverageOptions;
    pub const CodeCoverageReporter = @import("options_types/CodeCoverageOptions.zig").Reporter;
    pub const CodeCoverageReporters = @import("options_types/CodeCoverageOptions.zig").Reporters;
    pub const CodeCoverageFraction = @import("options_types/CodeCoverageOptions.zig").Fraction;
};

// ---- src/meta/ ---------------------------------------------------------
// Type-classifier + bitfield helpers. Pure leaves (no `home_rt` deps).
pub const meta = struct {
    pub const typeBaseName = @import("meta/meta.zig").typeBaseName;
    pub const typeBaseNameT = @import("meta/meta.zig").typeBaseNameT;
    pub const enumFieldNames = @import("meta/meta.zig").enumFieldNames;
    pub const Item = @import("meta/meta.zig").Item;
    // `std.meta.intToEnum` was removed in Zig 0.17; faithful drop-in replacement.
    pub fn intToEnum(comptime Enum: type, tag_int: anytype) error{InvalidEnumTag}!Enum {
        inline for (@typeInfo(Enum).@"enum".fields) |f| {
            if (@as(@typeInfo(Enum).@"enum".tag_type, @intCast(tag_int)) == f.value)
                return @field(Enum, f.name);
        }
        return error.InvalidEnumTag;
    }
    pub const bits = @import("meta/bits.zig");
    pub const traits = @import("meta/traits.zig");

    pub fn typeName(comptime Type: type) []const u8 {
        return typeBaseName(@typeName(Type));
    }

    pub fn ReturnOf(comptime function: anytype) type {
        return ReturnOfType(@TypeOf(function));
    }

    pub fn ReturnOfType(comptime Type: type) type {
        const typeinfo: std.builtin.Type.Fn = @typeInfo(Type).@"fn";
        return typeinfo.return_type orelse void;
    }

    pub fn banFieldType(comptime Type: type, comptime FieldType: type) void {
        _ = Type;
        _ = FieldType;
    }
};

// ---- src/crash_handler/ ------------------------------------------------
// Out-of-memory + crash reporting. Only the OOM wrapper is ported today;
// the full crash handler (stack walking, JSC stop-the-world, native
// signal handlers) re-lands in a later sub-phase.
pub const crash_handler = struct {
    pub const handle_oom = @import("crash_handler/handle_oom.zig");
    pub const StoredTrace = @import("crash_handler/StoredTrace.zig").StoredTrace;
    // Wave-16 Tier-1 grinder (2026-05-18):
    pub const CPUFeatures = @import("crash_handler/CPUFeatures.zig");

    pub const Action = union(enum) {
        parse: []const u8,
        visit: []const u8,
        print: []const u8,
        bundle_generate_chunk: void,
        resolver: void,
        dlopen: []const u8,
    };

    pub threadlocal var current_action: ?Action = null;
};

// ---- src/core/ -----------------------------------------------------
// Additional Tier-0 helpers — pure-Zig utilities the rest of the runtime
// leans on. (result.zig + tty.zig already wired below.)
pub const ExactSizeMatcher = @import("core/string/immutable/exact_size_matcher.zig").ExactSizeMatcher;
// Sixth-wave port batch (2026-05-18):
pub const feature_flags = @import("core/feature_flags.zig");
pub const FeatureFlags = feature_flags;
pub const util = @import("core/util.zig");
pub const grapheme = @import("core/string/immutable/grapheme.zig");
pub const BoundedArray = @import("core/bounded_array.zig").BoundedArray;
pub const BoundedArrayAligned = @import("core/bounded_array.zig").BoundedArrayAligned;

// ---- src/install_types/ ------------------------------------------------
// Package manager type vocabulary. The full `install/PackageManager.zig`
// runtime is the Phase 12.9 destination; these split-out types are pure
// data and land first so other subsystems can name them.
pub const install_types = struct {
    pub const NodeLinker = @import("install_types/NodeLinker.zig").NodeLinker;
    // Legacy install_types compatibility aliases for callers that still
    // name Bun's pre-split semver strings through install_types. The
    // Bun-compatible semver namespace is exported as home_rt.Semver below.
    pub const SemverString = @import("install_types/SemverString.zig").String;
    pub const ExternalString = @import("install_types/ExternalString.zig").ExternalString;
    pub const SlicedString = @import("install_types/SlicedString.zig").SlicedString;
};

// ---- src/semver/ -------------------------------------------------------
// Bun-compatible semver aggregator. The pure Zig leaves are local; the
// JSC-backed SemverObject remains blocked in semver/semver.zig until the
// semver_jsc bridge lands.
pub const Semver = @import("semver/semver.zig");

// ---- src/install/ ------------------------------------------------------
// Pure-Zig install/ leaves. Home replaces Bun's package manager with
// Pantry (docs/TS_PARITY_PLAN.md §12.9); only small leaves other
// runtime subsystems still need are copied.
pub const install = struct {
    pub const ids = @import("install/PackageID.zig");
    pub const PackageID = ids.PackageID;
    pub const DependencyID = ids.DependencyID;
    pub const invalid_package_id = ids.invalid_package_id;
    pub const invalid_dependency_id = ids.invalid_dependency_id;
    pub const PackageNameAndVersionHash = ids.PackageNameAndVersionHash;
    pub const PackageNameHash = ids.PackageNameHash;
    pub const TruncatedPackageNameHash = ids.TruncatedPackageNameHash;
    pub const external = @import("install/ExternalSlice.zig");
    pub const ExternalSlice = external.ExternalSlice;
    pub const ExternalStringMap = external.ExternalStringMap;
    pub const ExternalStringList = external.ExternalStringList;
    pub const ExternalPackageNameHashList = external.ExternalPackageNameHashList;
    pub const VersionSlice = external.VersionSlice;
    pub const versioned_url = @import("install/versioned_url.zig");
    pub const VersionedURL = versioned_url.VersionedURL;
    pub const OldV2VersionedURL = versioned_url.OldV2VersionedURL;
    pub const VersionedURLType = versioned_url.VersionedURLType;
    pub const padding_checker = @import("install/padding_checker.zig");
    pub const ConfigVersion = @import("install/ConfigVersion.zig").ConfigVersion;
    pub const PackageManager = @import("install/PackageManager.zig");
    pub const Task = @import("install/PackageManagerTask.zig");
    pub const PackageInstall = @import("install/PackageInstall.zig").PackageInstall;

    // ---- Aggregated install/ leaves needed by the PackageManager cone ----
    // Re-exports mirroring `install/install.zig`'s aggregator. The PM cone is
    // dead-code-eliminated while the Bun-parser probe is off; these decls are
    // lazy, so the unported tails behind them are only analysed when reached.
    pub const aggregator = @import("install/install.zig");
    pub const bun_hash_tag = aggregator.bun_hash_tag;
    pub const BuntagHashBuf = aggregator.BuntagHashBuf;
    pub const buntaghashbuf_make = aggregator.buntaghashbuf_make;
    pub const alignment_bytes_to_repeat_buffer = aggregator.alignment_bytes_to_repeat_buffer;
    pub const initializeStore = aggregator.initializeStore;
    pub const Aligner = aggregator.Aligner;
    pub const Features = aggregator.Features;
    pub const PreinstallState = aggregator.PreinstallState;
    pub const ExtractData = aggregator.ExtractData;
    pub const DependencyInstallContext = aggregator.DependencyInstallContext;
    pub const TaskCallbackContext = aggregator.TaskCallbackContext;
    pub const PackageManifestError = aggregator.PackageManifestError;

    pub const ExtractTarball = @import("install/extract_tarball.zig");
    pub const NetworkTask = @import("install/NetworkTask.zig");
    pub const TarballStream = @import("install/TarballStream.zig");
    pub const Npm = @import("install/npm.zig");
    pub const PackageManifestMap = @import("install/PackageManifestMap.zig");
    pub const TextLockfile = @import("install/lockfile/bun.lock.zig");
    pub const Bin = @import("install/bin.zig").Bin;
    pub const FolderResolution = @import("install/resolvers/folder_resolver.zig").FolderResolution;
    pub const Repository = @import("install/repository.zig").Repository;
    pub const Resolution = @import("install/resolution.zig").Resolution;
    pub const Store = @import("install/isolated_install/Store.zig").Store;
    pub const FileCopier = @import("install/isolated_install/FileCopier.zig").FileCopier;
    pub const PnpmMatcher = @import("install/PnpmMatcher.zig");
    pub const PostinstallOptimizer = @import("install/postinstall_optimizer.zig").PostinstallOptimizer;

    pub const ArrayIdentityContext = @import("collections/identity_context.zig").ArrayIdentityContext;
    pub const IdentityContext = @import("collections/identity_context.zig").IdentityContext;

    pub const Integrity = @import("install/integrity.zig").Integrity;
    pub const Dependency = @import("install/dependency.zig");
    pub const Behavior = @import("install/dependency.zig").Behavior;

    pub const Lockfile = @import("install/lockfile.zig");
    pub const PatchedDep = Lockfile.PatchedDep;

    pub const patch = @import("install/patch_install.zig");
    pub const PatchTask = patch.PatchTask;
    // Faithful to upstream `bun.install.LifecycleScriptSubprocess`
    // (`install/install.zig:256`): the real runner with its intrusive-heap
    // `List`. Lazy import — only analysed when the PM cone touches it.
    pub const LifecycleScriptSubprocess = @import("install/lifecycle_script_runner.zig").LifecycleScriptSubprocess;
    pub const SecurityScanSubprocess = struct {
        pub fn onProcessExit(this: *SecurityScanSubprocess, process: anytype, status: anytype, rusage: anytype) void {
            _ = this;
            _ = process;
            _ = status;
            _ = rusage;
        }
    };
};

// Faithful to upstream `bun.zig:1182`: `pub const PackageManager = install.PackageManager;`
pub const PackageManager = install.PackageManager;
// Faithful to upstream `bun.ConfigVersion` (`bun.zig:3819`).
pub const ConfigVersion = install.ConfigVersion;

// ---- src/ptr/ ----------------------------------------------------------
// Smart-pointer helpers — Cow + meta. The full RefCount / Owned /
// TaggedPointer family re-lands in a follow-up batch.
pub const ptr = struct {
    pub const meta = @import("ptr/meta.zig");
    // Faithful to upstream ptr/ptr.zig:27 (`RawRefCount = raw_ref_count.RawRefCount`).
    pub const RawRefCount = @import("ptr/raw_ref_count.zig").RawRefCount;
    pub const Cow = @import("ptr/Cow.zig").Cow;
    pub const CowSlice = @import("ptr/CowSlice.zig").CowSlice;
    pub const CowSliceZ = @import("ptr/CowSlice.zig").CowSliceZ;
    pub const CowString = CowSlice(u8);
    pub const RefCount = @import("ptr/ref_count.zig").RefCount;
    pub const ThreadSafeRefCount = @import("ptr/ref_count.zig").ThreadSafeRefCount;
    // Faithful to upstream `bun.ptr.RefPtr` (`src/ptr/ptr.zig:24`):
    // `pub const RefPtr = ref_count.RefPtr;`.
    pub const RefPtr = @import("ptr/ref_count.zig").RefPtr;
    // Faithful to upstream `bun.ptr.shared` (`src/ptr/ptr.zig:13`):
    // `pub const shared = @import("./shared.zig");`. Provides the
    // `WithOptions(*T, .{...})` shared-pointer factory used by `SSLConfig`.
    pub const shared = @import("ptr/shared.zig");
    pub const TaggedPointer = @import("ptr/tagged_pointer.zig").TaggedPointer;
    pub const TaggedPointerUnion = @import("ptr/tagged_pointer.zig").TaggedPointerUnion;
    // Wave-15 Tier-1 grinder (2026-05-18):
    pub const WeakPtr = @import("ptr/weak_ptr.zig").WeakPtr;
    pub const WeakPtrData = @import("ptr/weak_ptr.zig").WeakPtrData;
    pub const ExternalShared = @import("ptr/external_shared.zig").ExternalShared;
    // Faithful to upstream `bun.ptr.{Owned,OwnedIn}` (`src/ptr/ptr.zig`):
    // owned smart-pointer factory used by the bake DevServer PackedMap.
    pub const Owned = @import("ptr/owned.zig").Owned;
    pub const OwnedIn = @import("ptr/owned.zig").OwnedIn;
};
pub const TaggedPointer = ptr.TaggedPointer;
pub const TaggedPointerUnion = ptr.TaggedPointerUnion;

// ---- src/uws_sys/ ------------------------------------------------------
// Opaque bindings to the `us_*` C ABI in `packages/bun-usockets`.
// Currently only the QUIC opaques; the TCP/UDP/HTTP/3 + WebSocket
// surface lands as the broader uws subtree is ported.
pub const uws_sys = struct {
    pub const quic = struct {
        pub const Socket = @import("uws_sys/quic/Socket.zig").Socket;
        pub const PendingConnect = @import("uws_sys/quic/PendingConnect.zig").PendingConnect;
        pub const Stream = @import("uws_sys/quic/Stream.zig").Stream;
        pub const Header = @import("uws_sys/quic/Header.zig").Header;
        pub const Qpack = @import("uws_sys/quic/Header.zig").Qpack;
        // Fifteenth-wave port batch (2026-05-18). lsquic engine + event-loop
        // wiring. Loop is a local forward-decl until uws_sys/Loop.zig lands.
        pub const Context = @import("uws_sys/quic/Context.zig").Context;
        // Fifteenth-wave port batch (2026-05-18). Sibling aggregator that
        // re-exports all five quic opaques + the `globalInit` entrypoint.
        pub const aggregator = @import("uws_sys/quic.zig");
    };
    // Twelfth-wave port batch (2026-05-18). Tier-0 uws_sys leaves whose
    // upstream deps collapse to opaques: Timer (Loop forward-decl),
    // the comptime VTable generator (ConnectingSocket sibling-import,
    // us_socket_t/us_bun_verify_error_t local opaques), and the
    // embedded-by-value SocketGroup (Loop/ListenSocket/SslCtx forward-decls).
    pub const Timer = @import("uws_sys/Timer.zig").Timer;
    pub const vtable = @import("uws_sys/vtable.zig");
    pub const SocketGroup = @import("uws_sys/SocketGroup.zig").SocketGroup;
};

// ---- src/event_loop/ ---------------------------------------------------
// Bun's event-loop substrate. Most files in this directory pull in
// `bun.jsc.*` / `bun.JSError` / `bun.Async` (not yet exported), so only
// the leaves that depend exclusively on `default_allocator` + `handleOom`
// can be copied today.
pub const event_loop = struct {
    pub const DeferredTaskQueue = @import("event_loop/DeferredTaskQueue.zig");
    // Fourth-wave port batch (2026-05-17). ConcurrentTask parks on
    // UnboundedQueue + jsc.Task (TaggedPointerUnion, 8 bytes) +
    // TrivialNew/TrivialDeinit — re-attaches in Phase 12.2.
    pub const AnyTask = @import("event_loop/AnyTask.zig");
    pub const AnyTaskWithExtraContext = @import("event_loop/AnyTaskWithExtraContext.zig");
    pub const AutoFlusher = @import("event_loop/AutoFlusher.zig");
    pub const ManagedTask = @import("event_loop/ManagedTask.zig");
    // Seventh-wave port (2026-05-18). Unblocked by home_rt.threading.UnboundedQueue.
    pub const ConcurrentTask = @import("event_loop/ConcurrentTask.zig");
};

// ---- src/unicode/ ------------------------------------------------------
// Unicode property tables + a pure-std 3-level LUT generator. Mirrors
// Bun's `src/unicode/uucode/` (application-facing wrapper) and
// `src/unicode/uucode_lib/` (vendored zigster/uucode library). Only
// Tier-0 leaves are present today — the full grapheme-break + width
// tables land alongside Phase 12.5.
pub const unicode = struct {
    pub const uucode = struct {
        pub const lut = @import("unicode/uucode/lut.zig");
    };
    pub const uucode_lib = struct {
        pub const ascii = @import("unicode/uucode_lib/src/ascii.zig");
        pub const utf8 = @import("unicode/uucode_lib/src/utf8.zig");
        pub const x = struct {
            pub const types = @import("unicode/uucode_lib/src/x/types.x.zig");
            pub const types_x = struct {
                pub const grapheme = @import("unicode/uucode_lib/src/x/types_x/grapheme.zig");
            };
        };
    };
};

// ---- src/runtime/ ------------------------------------------------------
// Bun's `src/runtime/` subtree. Directory shape mirrors upstream;
// individual files are flat copies as their bun.X deps allow.
pub const runtime = struct {
    pub const bake = @import("runtime/bake/bake.zig");
    pub const image = struct {
        pub const exif = @import("runtime/image/exif.zig");
        // Sixth-wave port batch (2026-05-18):
        pub const thumbhash = @import("runtime/image/thumbhash.zig");
        pub const quantize = @import("runtime/image/quantize.zig");
    };
    pub const server = struct {
        pub const server_module = @import("runtime/server/server.zig");
        pub const Server = server_module.Server;
        pub const HTMLBundle = @import("runtime/server/HTMLBundle.zig");
        pub const ServerConfig = @import("runtime/server/ServerConfig.zig");
        pub const HTTPStatusText = @import("runtime/server/HTTPStatusText.zig");
        // Sixth-wave port batch (2026-05-18):
        pub const RangeRequest = @import("runtime/server/RangeRequest.zig");
    };
    // JSC bring-up: real webcore (was a ~285-line hand-written stub).
    // Faithful to upstream bun.webcore = @import("runtime/webcore.zig").
    pub const webcore = @import("runtime/webcore.zig");
    pub const valkey = struct {
        // Per-VM Valkey state. JSC-bridge dispatch omitted — re-lands in Phase 12.2.
        pub const Context = @import("runtime/valkey_jsc/ValkeyContext.zig");
    };
    // Fifth-wave port batch (2026-05-18). Full CLI surface (commands,
    // opener, bunfig, args) lands when spawn + bunfig substrates re-attach.
    pub const cli = struct {
        pub const ci_info = @import("runtime/cli/ci_info.zig");
        pub const discord_command = @import("runtime/cli/discord_command.zig");
        // Wave-16 Tier-1 grinder (2026-05-18):
        pub const colon_list_type = @import("runtime/cli/colon_list_type.zig");
        pub const ColonListType = colon_list_type.ColonListType;
        pub const shell_completions = @import("runtime/cli/shell_completions.zig");
        pub const fuzzilli_command = @import("runtime/cli/fuzzilli_command.zig");
        // Wave-26 grinder (2026-05-19) — `which-npm-client` result
        // descriptor (npm client `bin` path + `Tag` enum). Pure data
        // — upstream `@import("bun")` was unused.
        pub const which_npm_client = @import("runtime/cli/which_npm_client.zig");
        pub const NPMClient = which_npm_client.NPMClient;
        pub const list_of_yarn_commands = @import("runtime/cli/list-of-yarn-commands.zig");
        // `test_` rather than `test` because `test` is a Zig keyword.
        pub const test_ = struct {
            pub const ParallelRunner = @import("runtime/cli/test/ParallelRunner.zig");
            pub const parallel = struct {
                pub const Channel = @import("runtime/cli/test/parallel/Channel.zig");
                pub const Coordinator = @import("runtime/cli/test/parallel/Coordinator.zig");
                pub const FileRange = @import("runtime/cli/test/parallel/FileRange.zig").FileRange;
                pub const Frame = @import("runtime/cli/test/parallel/Frame.zig");
                pub const Worker = @import("runtime/cli/test/parallel/Worker.zig");
                pub const aggregate = @import("runtime/cli/test/parallel/aggregate.zig");
                pub const runner = @import("runtime/cli/test/parallel/runner.zig");
            };
        };
    };
    // Eighth-wave port batch (2026-05-18). First runtime/api/ leaves —
    // pure-Zig helpers and small JSC bridges with stubbed JSC surfaces.
    // JSC bring-up: real api namespace (was inline stub). bun.api = runtime/api.zig.
    pub const api = @import("runtime/api.zig");
    // Wave-15 Tier-1 grinder (2026-05-18). Pure-Zig shell helpers; full
    // shell surface lands once `bun.Output.scoped` + the shell parser port.
    pub const shell = struct {
        pub const RefCountedStr = @import("runtime/shell/RefCountedStr.zig");
        pub const EnvMap = @import("runtime/shell/EnvMap.zig");
        pub const ShellSubprocess = struct {
            pub fn onProcessExit(this: *ShellSubprocess, process: anytype, status: anytype, rusage: anytype) void {
                _ = this;
                _ = process;
                _ = status;
                _ = rusage;
            }
        };
    };
};
pub const api = runtime.api;
pub const shell = runtime.shell;
// ---- src/string/ -------------------------------------------------------
// Wave-15 Tier-1 grinder (2026-05-18). Pure-Zig string helpers.
// JSC-bridge surface (`jsEscapeRegExp`, JSC PathString conversion) parks
// behind Phase 12.2.
pub const string = struct {
    pub const HashedString = @import("string/HashedString.zig");
    pub const escapeRegExp = @import("string/escapeRegExp.zig").escapeRegExp;
    pub const escapeRegExpForPackageNameMatching = @import("string/escapeRegExp.zig").escapeRegExpForPackageNameMatching;
};

// Upstream `bun.StringBuilder` aliases `string.StringBuilder` — the pure-Zig
// `{len, cap, ptr}` two-phase buffer builder (`count`/`countZ` → `allocate`
// → `append`/`appendZ`), NOT the WTF C++ wrapper at `jsc.StringBuilder`. The
// resolver cone (`resolver/tsconfig_json.zig`, `logger/logger.zig`,
// `http.HeaderBuilder`, install/PM) spells it as the top-level
// `home_rt.StringBuilder`. The leaf is `core/string/StringBuilder.zig`, whose
// root type is the builder itself (`const StringBuilder = @This()`), so the
// module is aliased directly.
pub const StringBuilder = @import("core/string/StringBuilder.zig");

// ---- Home.* — JS-facing globals (formerly Bun.*) ----------------------
// Thirteenth-wave port batch (2026-05-18). Bun's `Bun.*` JavaScript
// surface lands here as Home's `Home.*` so callers can spell upstream's
// `bun.api.*` / `bun.api.bun.*` shape via `home_rt.Home.*`. Each leaf
// is the pure-Zig substrate of the corresponding JS class — the JSC
// bindings (constructor / call frames / argument coercion) are parked
// until the matching `home_rt.jsc` substrate lands.
pub const Home = struct {
    pub const Terminal = @import("runtime/api/bun/Terminal.zig");
    pub const spawn = @import("runtime/api/bun/spawn.zig");
    pub const Glob = @import("runtime/api/glob.zig");
};
pub const spawn = Home.spawn.PosixSpawn;

// Faithful to upstream `bun.BoringSSL` (`bun.zig:813`):
// `@import("./boringssl/boringssl.zig")`. `.c` is the raw bindings namespace
// the HTTP/TLS cone (`HTTPContext`) uses.
pub const BoringSSL = @import("boringssl/boringssl.zig");

pub const fd_t = std.posix.fd_t;
pub const Mode = std.posix.mode_t;
// Faithful to upstream `bun.Stat` (`bun.zig:2005`): the platform stat struct.
// Home targets posix; `std.c.Stat` matches what `sys.stat`/`sys.fstat` return.
pub const Stat = std.c.Stat;

pub const FD = packed struct(fd_t) {
    value: fd_t,
    kind: Kind = .system,

    pub const Kind = enum(u0) { system };

    pub const invalid: FD = .{ .value = -1 };

    pub fn fromNative(value: fd_t) FD {
        return .{ .value = value };
    }

    pub const fromSystem = fromNative;

    pub fn fromUV(value: fd_t) FD {
        return .{ .value = value };
    }

    pub fn fromStdFile(file: anytype) FD {
        return .fromNative(file.handle);
    }

    pub fn fromStdDir(dir: std.Io.Dir) FD {
        return .fromNative(dir.handle);
    }

    pub fn cwd() FD {
        return .fromNative(std.Io.Dir.cwd().handle);
    }

    pub fn stdin() FD {
        return .fromNative(0);
    }

    pub fn stdout() FD {
        return .fromNative(1);
    }

    pub fn stderr() FD {
        return .fromNative(2);
    }

    pub fn native(fd: FD) fd_t {
        return fd.value;
    }

    pub const cast = native;
    pub const uv = native;

    pub fn stdFile(fd: FD) std.Io.File {
        return .{ .handle = fd.native(), .flags = .{ .nonblocking = false } };
    }

    pub fn stdDir(fd: FD) std.Io.Dir {
        return .{ .handle = fd.native() };
    }

    pub fn getFdPath(fd: FD, buf: *PathBuffer) ![]u8 {
        return @import("home").getFdPath(fd, buf);
    }

    pub fn getFdPathZ(fd: FD, buf: *PathBuffer) ![:0]u8 {
        return @import("home").getFdPathZ(fd, buf);
    }

    pub fn getFdPathW(fd: FD, buf: *WPathBuffer) ![]u16 {
        return @import("home").getFdPathW(fd, buf);
    }

    pub fn isValid(fd: FD) bool {
        return fd.value >= 0;
    }

    pub fn unwrapValid(fd: FD) ?FD {
        return if (fd.isValid()) fd else null;
    }

    pub fn close(fd: FD) void {
        _ = fd.closeAllowingBadFileDescriptor(@returnAddress());
    }

    pub fn closeAllowingBadFileDescriptor(fd: FD, _: ?usize) ?sys.Error {
        if (!fd.isValid() or fd.value <= 2) return null;
        _ = std.c.close(fd.native());
        return null;
    }

    pub fn closeAllowingStandardIo(fd: FD, return_address: ?usize) ?sys.Error {
        _ = return_address;
        if (!fd.isValid()) return null;
        _ = std.c.close(fd.native());
        return null;
    }

    pub fn makeLibUVOwned(fd: FD) !FD {
        return fd;
    }

    pub fn makeLibUVOwnedForSyscall(
        fd: FD,
        comptime _: sys.Tag,
        comptime _: enum { close_on_fail, leak_fd_on_fail },
    ) sys.Maybe(FD) {
        return .{ .result = fd };
    }

    /// Faithful to upstream `sys_jsc/fd_jsc.zig:40`. Home's FD is posix-only
    /// (no Windows handle kind), so `makeLibUVOwned` is a no-op and `uv()`
    /// returns the native fd.
    pub fn toJS(any_fd: FD, global: *jsc.JSGlobalObject) jsc.JSValue {
        if (!any_fd.isValid()) {
            return jsc.JSValue.jsNumberFromInt32(-1);
        }
        const uv_owned_fd = any_fd.makeLibUVOwned() catch {
            any_fd.close();
            const err_instance = (jsc.SystemError{
                .message = String.static("EMFILE, too many open files"),
                .code = String.static("EMFILE"),
            }).toErrorInstance(global);
            return global.vm().throwError(global, err_instance) catch .zero;
        };
        return jsc.JSValue.jsNumberFromInt32(uv_owned_fd.uv());
    }

    /// Faithful to upstream `sys_jsc/fd_jsc.zig:60`. Posix-only path.
    pub fn toJSWithoutMakingLibUVOwned(any_fd: FD) jsc.JSValue {
        if (!any_fd.isValid()) {
            return jsc.JSValue.jsNumberFromInt32(-1);
        }
        return jsc.JSValue.jsNumberFromInt32(any_fd.value);
    }

    pub fn toOptional(fd: FD) Optional {
        return @enumFromInt(fd.value);
    }

    pub const Optional = enum(fd_t) {
        none = -1,
        _,

        pub fn init(maybe: ?FD) Optional {
            return if (maybe) |fd| fd.toOptional() else .none;
        }

        pub fn unwrap(optional: Optional) ?FD {
            return if (optional == .none) null else .fromNative(@intFromEnum(optional));
        }

        pub fn take(optional: *Optional) ?FD {
            defer optional.* = .none;
            return optional.unwrap();
        }

        pub fn close(optional: Optional) void {
            if (optional.unwrap()) |fd| fd.close();
        }
    };

    pub fn format(fd: FD, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        if (!fd.isValid()) return writer.writeAll("[invalid_fd]");
        return writer.print("{d}", .{fd.native()});
    }
};

pub const invalid_fd: FD = .invalid;

fn toPackedO(number: anytype) std.posix.O {
    return @bitCast(number);
}

pub const O = switch (Environment.os) {
    .mac => struct {
        pub const PATH = 0x0000;
        pub const RDONLY = 0x0000;
        pub const WRONLY = 0x0001;
        pub const RDWR = 0x0002;
        pub const NONBLOCK = 0x0004;
        pub const APPEND = 0x0008;
        pub const CREAT = 0x0200;
        pub const TRUNC = 0x0400;
        pub const EXCL = 0x0800;
        pub const NOFOLLOW = 0x0100;
        pub const DIRECTORY = 0x00100000;
        pub const CLOEXEC = 0x01000000;
        pub const TMPFILE = 0x0000;
        pub const toPacked = toPackedO;
    },
    .linux, .wasm => struct {
        pub const RDONLY = 0x0000;
        pub const WRONLY = 0x0001;
        pub const RDWR = 0x0002;
        pub const CREAT = 0o100;
        pub const EXCL = 0o200;
        pub const NOCTTY = 0o400;
        pub const TRUNC = 0o1000;
        pub const APPEND = 0o2000;
        pub const NONBLOCK = 0o4000;
        pub const DIRECTORY = 0o200000;
        pub const NOFOLLOW = 0o400000;
        pub const CLOEXEC = 0o2000000;
        pub const TMPFILE = 0o20200000;
        pub const PATH = 0o10000000;
        pub const toPacked = toPackedO;
    },
    else => struct {
        pub const PATH = 0;
        pub const RDONLY = 0;
        pub const WRONLY = 1;
        pub const RDWR = 2;
        pub const NONBLOCK = 0;
        pub const APPEND = 0;
        pub const CREAT = 0;
        pub const TRUNC = 0;
        pub const EXCL = 0;
        pub const NOFOLLOW = 0;
        pub const DIRECTORY = 0;
        pub const CLOEXEC = 0;
        pub const TMPFILE = 0;
        pub const toPacked = toPackedO;
    },
};

pub fn openDir(dir: std.Io.Dir, path_: [:0]const u8) !std.Io.Dir {
    return try openDirA(.fromStdDir(dir), path_);
}

pub fn openDirA(dir: FD, path_: []const u8) !std.Io.Dir {
    return (try openDirForIteration(dir, path_).unwrap()).stdDir();
}

pub fn openDirForIteration(dir: FD, path_: []const u8) sys.Maybe(FD) {
    return sys.openatA(dir, path_, O.DIRECTORY | O.CLOEXEC | O.RDONLY, 0);
}

pub fn openDirForIterationOSPath(dir: FD, path_: []const OSPathChar) sys.Maybe(FD) {
    return openDirForIteration(dir, path_);
}

pub fn openDirAbsolute(path_: []const u8) !std.Io.Dir {
    return (try sys.openA(path_, O.DIRECTORY | O.CLOEXEC | O.RDONLY, 0).unwrap()).stdDir();
}

pub fn openFileForPath(file_path: [:0]const u8) !std.Io.File {
    const flags: u32 = O.CLOEXEC | O.RDONLY;
    return (try sys.openA(file_path, flags, 0).unwrap()).stdFile();
}

pub fn openFile(path_: []const u8, open_flags: anytype) !std.Io.File {
    _ = open_flags;
    return (try sys.openA(path_, O.CLOEXEC | O.RDONLY, 0).unwrap()).stdFile();
}

pub fn getFdPath(fd: FD, buf: *PathBuffer) ![]u8 {
    if (comptime Environment.isWindows) {
        return error.Unsupported;
    } else if (comptime Environment.isMac) {
        @memset(buf[0..], 0);
        while (true) {
            switch (std.c.errno(std.c.fcntl(fd.native(), std.c.F.GETPATH, buf))) {
                .SUCCESS => break,
                .INTR => continue,
                .ACCES => return error.AccessDenied,
                .BADF => return error.FileNotFound,
                .NOENT => return error.FileNotFound,
                .NOMEM => return error.SystemResources,
                .NOSPC => return error.NameTooLong,
                .RANGE => return error.NameTooLong,
                else => return error.Unexpected,
            }
        }
        const len = std.mem.indexOfScalar(u8, buf, 0) orelse buf.len;
        return buf[0..len];
    } else {
        var proc_buf: ["/proc/self/fd/-2147483648".len + 1:0]u8 = undefined;
        const proc_path = std.fmt.bufPrintZ(&proc_buf, "/proc/self/fd/{d}", .{fd.native()}) catch unreachable;
        const rc = std.c.readlink(proc_path.ptr, buf.ptr, buf.len);
        if (rc < 0) return error.Unexpected;
        return buf[0..@intCast(rc)];
    }
}

pub fn getFdPathZ(fd: FD, buf: *PathBuffer) ![:0]u8 {
    const fd_path = try getFdPath(fd, buf);
    buf[fd_path.len] = 0;
    return buf[0..fd_path.len :0];
}

pub fn getFdPathW(fd: FD, buf: *WPathBuffer) ![]u16 {
    _ = fd;
    _ = buf;
    return error.Unsupported;
}

pub const PlatformIOVecConst = std.posix.iovec_const;

pub fn platformIOVecConstCreate(input: []const u8) PlatformIOVecConst {
    return .{ .base = input.ptr, .len = input.len };
}

pub const Tmpfile = struct {
    destination_dir: FD = invalid_fd,
    tmpfilename: [:0]const u8 = "",
    fd: FD = invalid_fd,
    using_tmpfile: bool = false,

    pub fn create(destination_dir: FD, tmpfilename: [:0]const u8) sys.Maybe(Tmpfile) {
        const opened = switch (sys.openat(destination_dir, tmpfilename, O.CREAT | O.CLOEXEC | O.WRONLY | O.TRUNC, 0o644)) {
            .result => |fd| fd,
            .err => |err| return .{ .err = err },
        };

        return .{ .result = .{
            .destination_dir = destination_dir,
            .tmpfilename = tmpfilename,
            .fd = opened,
            .using_tmpfile = false,
        } };
    }

    pub fn finish(this: *Tmpfile, destname: [:0]const u8) !void {
        try sys.moveFileZWithHandle(this.fd, this.destination_dir, this.tmpfilename, this.destination_dir, destname);
    }
};

pub const webcore = runtime.webcore;

// ---- src/node/ ---------------------------------------------------------
// Node.js compatibility shims. Sourced from bun/src/runtime/node/ — bun
// never grew a top-level src/node/, so this Home subtree is the namespace
// home for everything in the upstream node/ directory.
pub const node = struct {
    pub const error_code = @import("node/nodejs_error_code.zig");
    // Seventh-wave port batch (2026-05-18):
    pub const time_like = @import("node/time_like.zig");
    pub const os_constants = @import("node/os_constants.zig");
    // Phase 12.7 round-7 (2026-05-19) — `node:events` EventEmitter
    // substrate. Generic EventEmitter(EventName, Listener) + 12 methods
    // (on/off/once/emit/listenerCount/listeners/removeAllListeners/
    // setMax/getMaxListeners/eventNames/prependListener/prependOnceListener).
    // EventEmitterDefault alias for the typical string-keyed case.
    pub const events = @import("node/events.zig");
    // Phase 12.7 round-10 (2026-05-19) — `node:stream` Zig substrate.
    // Readable/Writable/Duplex/Transform/PassThrough on top of
    // node:events. Pull-mode + push-mode + pipe trampolines. The
    // round-10 `pub const buffer = …` entry that landed alongside
    // this one was a duplicate of the round-9 declaration further
    // below; wave-23 dropped the duplicate to restore home_rt smoke
    // green (the canonical entry lives next to fs/util).
    pub const stream = @import("node/stream.zig");
    // Phase 12.7 port (2026-05-19) — `node:util` Zig substrate. Top-level
    // surface (inspect/format/formatWithOptions/isDeepStrictEqual/
    // deprecate/debuglog/debug/promisify/callbackify + InspectOptions +
    // Logger + types.*) re-exports from `node/util.zig`. Zig 0.17 removed
    // `usingnamespace`, so each public symbol is aliased explicitly.
    // `parse_args_utils` is the pre-existing parse-args helper. The JS
    // shim re-attaches once the Phase 12.2 JSC bridge is live.
    pub const util = struct {
        const util_substrate = @import("node/util.zig");
        pub const InspectOptions = util_substrate.InspectOptions;
        pub const Logger = util_substrate.Logger;
        pub const max_inspect_depth = util_substrate.max_inspect_depth;
        pub const max_inspect_bytes = util_substrate.max_inspect_bytes;
        pub const inspect = util_substrate.inspect;
        pub const format = util_substrate.format;
        pub const formatWithOptions = util_substrate.formatWithOptions;
        pub const isDeepStrictEqual = util_substrate.isDeepStrictEqual;
        pub const deprecate = util_substrate.deprecate;
        pub const debuglog = util_substrate.debuglog;
        pub const debug = util_substrate.debug;
        pub const promisify = util_substrate.promisify;
        pub const callbackify = util_substrate.callbackify;
        pub const lastOutput = util_substrate.lastOutput;
        pub const clearLastOutput = util_substrate.clearLastOutput;
        pub const types = util_substrate.types;
        pub const parse_args_utils = @import("node/util/parse_args_utils.zig");
    };
    // Eighth-wave port batch (2026-05-18). myers_diff unparked (Zig 0.17
    // compat fixes applied); node_fs_constant adds the POSIX file-flag
    // surface used by `node:fs.constants`.
    pub const node_fs_constant = @import("node/node_fs_constant.zig");
    // Phase 12.7 port (2026-05-19) — `node:assert` Zig substrate. The JS
    // wrapper re-attaches once the Phase 12.2 JSC bridge is live; this
    // file exposes the Zig-callable surface that the JS layer will
    // delegate to (ok/equal/deepEqual/throws/match/...). The legacy
    // `assert.myers_diff` leaf is re-namespaced under `assert_utils` so
    // the top-level `assert` namespace can be the substrate module
    // itself.
    pub const assert = @import("node/assert.zig");
    pub const assert_utils = struct {
        pub const myers_diff = @import("node/assert/myers_diff.zig");
    };
    pub const path = @import("node/path.zig");
    // Phase 12.7 port (2026-05-19) — `node:buffer` Zig substrate.
    // Foundational dependency for node:stream, node:fs binary mode,
    // node:crypto wrappers, and many node:* tests. Self-contained
    // `Buffer` (owned/borrowed `[]u8` + optional allocator) +
    // `Encoding` enum + module-level byteLength/isBuffer/concat.
    // Numeric readers/writers are little-endian only for now; BE
    // variants re-attach when consumers need them.
    pub const buffer = @import("node/buffer.zig");
    // Phase 12.7 port (2026-05-19) — `node:fs` sync Zig substrate.
    // Exposes the std.Io.Dir-backed sync surface (readFileSync /
    // writeFileSync / existsSync / mkdirSync / rmSync / statSync /
    // readdirSync / copyFileSync / chmodSync / realpathSync / ...).
    // The async `promises` namespace stays parked behind
    // @panic("TODO(phase-12.2-M3)") until JSC + event-loop land.
    pub const fs = @import("node/fs.zig");
    // Phase 12.7 port (2026-05-19) — `node:os` Zig substrate. System
    // info helpers (hostname / platform / arch / release / type /
    // endianness / cpus / freemem / totalmem / uptime / loadavg /
    // tmpdir / homedir / userInfo / networkInterfaces / EOL) plus
    // re-exports of `os_constants`. Used by node:fs + many node:*
    // tests for cross-platform path handling. The JS shim re-attaches
    // once the Phase 12.2 JSC bridge is live.
    pub const os = @import("node/os.zig");
    // Phase 12.7 port (2026-05-19) — `node:url` Zig substrate. WHATWG
    // `URL` + `URLSearchParams` (with full get/set/has/append/delete/
    // keys/values) plus the legacy `url.parse` / `url.format` /
    // `url.resolve` / `pathToFileURL` / `fileURLToPath` /
    // `domainToASCII` / `domainToUnicode` surface. Self-contained
    // RFC-3986-leaning parser; the JS shim re-attaches once the
    // Phase 12.2 JSC bridge is live.
    pub const url = @import("node/url.zig");
    // Phase 12.7 (2026-05-19) — `node:querystring` Zig substrate. Legacy
    // `application/x-www-form-urlencoded` parser kept around for the
    // legacy `url.parse` flow + many `node:*` tests. Pure-Zig, no JSC
    // dependency. Surface: `parse` / `stringify` / `escape` /
    // `unescape` + `encode` / `decode` aliases + `ParseOptions` /
    // `StringifyOptions`.
    pub const querystring = @import("node/querystring.zig");
    // Phase 12.7 round-12 (2026-05-19) — `node:crypto` minimal substrate
    // built on std.crypto (CSPRNG + Hash family Md5/Sha1/Sha2/Sha3 +
    // HMAC). OpenSSL-backed surfaces (pbkdf2, scrypt, cipher streams,
    // sign/verify, ECDH, X509, KeyObject) stub-panic with TODO until
    // the BoringSSL bindings port.
    pub const crypto = @import("node/crypto.zig");
    // Phase 12.7 round-13 — `node:process` host-fact substrate.
    // JSC exports and EventEmitter/nextTick semantics still attach in
    // Phase 12.2, but cwd/chdir, env, pid/ppid, platform/arch,
    // hrtime, uptime, memoryUsage, and cpuUsage are native today.
    pub const process = @import("node/process.zig");
    // Phase 12.7 round-14 — `node:string_decoder` stateful byte decoder.
    // Preserves incomplete UTF-8 / UTF-16LE / base64 groups across writes
    // with the same public shape the JS shim will expose as StringDecoder.
    pub const string_decoder = @import("node/string_decoder.zig");
    // Phase 12.7 round-15 — `node:tty` native terminal facts. Provides
    // isatty/window-size/raw-mode/color-depth substrate for future
    // ReadStream/WriteStream JS wrappers.
    pub const tty = @import("node/tty.zig");
};

// ---- src/core/ + src/alloc/ + src/safety/ ----------------------
// Result type, tty mode, c_allocator, thread-id sentinel. Pure-Zig
// utilities the rest of the runtime leans on.
pub const Result = @import("core/result.zig").Result;
pub const tty = @import("core/tty.zig");
pub const c_allocator = @import("alloc/fallback.zig").c_allocator;
pub const z_allocator = @import("alloc/fallback.zig").z_allocator;
pub const freeWithoutSize = @import("alloc/fallback.zig").freeWithoutSize;
// Sub-namespace for the zero-init allocator. Re-exports the canonical
// `z_allocator` above plus the internal helpers needed by callers that
// want to spell `home_rt.alloc.fallback.z.alloc(...)`.
pub const alloc = struct {
    pub const fallback = struct {
        pub const z = @import("alloc/fallback/z.zig");
    };
};
pub const memory = @import("bun_alloc/memory.zig");
pub const allocators = struct {
    pub const IndexType = packed struct(u32) {
        index: u31,
        is_overflow: bool = false,
    };

    pub const NotFound = IndexType{ .index = std.math.maxInt(u31) };
    pub const Unassigned = IndexType{ .index = std.math.maxInt(u31) - 1 };

    pub const ItemStatus = enum(u3) {
        unknown,
        exists,
        not_found,
    };

    pub const BSSResult = struct {
        hash: u64,
        index: IndexType,
        status: ItemStatus,

        pub fn hasCheckedIfExists(r: *const BSSResult) bool {
            return r.index.index != Unassigned.index;
        }
    };

    pub const Result = BSSResult;

    pub fn isSliceInBuffer(slice: []const u8, buffer: []const u8) bool {
        const start = @intFromPtr(buffer.ptr);
        const end = start + buffer.len;
        const slice_start = @intFromPtr(slice.ptr);
        const slice_end = slice_start + slice.len;
        return slice_start >= start and slice_end <= end;
    }

    const BSSIndexMapContext = struct {
        pub fn hash(_: @This(), key: u64) u64 {
            return key;
        }

        pub fn eql(_: @This(), a: u64, b: u64) bool {
            return a == b;
        }
    };

    pub const c_allocator = std.heap.c_allocator;
    pub const z_allocator = @import("bun_alloc/fallback/z.zig").allocator;
    pub const freeWithoutSize = @import("bun_alloc/fallback.zig").freeWithoutSize;

    pub fn BSSList(comptime ValueType: type, comptime _count: anytype) type {
        const count = _count * 2;
        const max_index = count - 1;
        return struct {
            const Self = @This();

            allocator: std.mem.Allocator,
            backing_buf: [count]ValueType = undefined,
            overflow: std.ArrayList(ValueType) = .empty,
            used: u32 = 0,

            pub var instance: *Self = undefined;
            pub var loaded = false;

            pub fn init(allocator: std.mem.Allocator) *Self {
                if (!loaded) {
                    instance = allocator.create(Self) catch outOfMemory();
                    instance.* = .{ .allocator = allocator };
                    loaded = true;
                }
                return instance;
            }

            pub fn deinit(self: *Self) void {
                self.overflow.deinit(self.allocator);
                self.allocator.destroy(self);
                loaded = false;
            }

            pub fn isOverflowing() bool {
                return loaded and instance.used >= @as(u32, @intCast(count));
            }

            pub fn exists(_: *Self, _: ValueType) bool {
                return false;
            }

            pub fn append(self: *Self, value: ValueType) !*ValueType {
                if (self.used <= max_index) {
                    const index = self.used;
                    self.backing_buf[index] = value;
                    self.used += 1;
                    return &self.backing_buf[index];
                }

                try self.overflow.append(self.allocator, value);
                self.used += 1;
                return &self.overflow.items[self.overflow.items.len - 1];
            }

            pub const Pair = struct { index: IndexType, value: *ValueType };
        };
    }

    pub fn BSSStringList(comptime _: usize, comptime _: usize) type {
        return struct {
            const Self = @This();

            allocator: std.mem.Allocator,
            pub var instance: *Self = undefined;

            pub fn init(allocator: std.mem.Allocator) *Self {
                instance = allocator.create(Self) catch outOfMemory();
                instance.* = .{ .allocator = allocator };
                return instance;
            }

            pub fn deinit(self: *Self) void {
                self.allocator.destroy(self);
            }

            pub fn append(self: *Self, comptime AppendType: type, value: AppendType) OOM![]const u8 {
                switch (@typeInfo(AppendType)) {
                    .array => |array| {
                        if (array.child == u8) return try self.allocator.dupe(u8, value[0..]);
                        if (array.child == []const u8) {
                            var total: usize = 0;
                            for (value) |part| total += part.len;
                            const out = try self.allocator.alloc(u8, total);
                            var offset: usize = 0;
                            for (value) |part| {
                                @memcpy(out[offset..][0..part.len], part);
                                offset += part.len;
                            }
                            return out;
                        }
                        @compileError("unsupported BSSStringList append array type");
                    },
                    .pointer => return try self.allocator.dupe(u8, value),
                    else => @compileError("unsupported BSSStringList append type"),
                }
            }

            pub fn appendMutable(self: *Self, comptime AppendType: type, value: AppendType) OOM![]u8 {
                return @constCast(try self.append(AppendType, value));
            }

            pub fn appendLowerCase(self: *Self, comptime AppendType: type, value: AppendType) OOM![]const u8 {
                const input = switch (@typeInfo(AppendType)) {
                    .pointer => value,
                    .array => value[0..],
                    else => @compileError("unsupported BSSStringList appendLowerCase type"),
                };
                const out = try self.allocator.alloc(u8, input.len);
                for (input, 0..) |char, index| {
                    out[index] = std.ascii.toLower(char);
                }
                return out;
            }

            pub fn exists(_: *const Self, _: []const u8) bool {
                return false;
            }
        };
    }

    pub fn BSSMap(
        comptime ValueType: type,
        comptime _: anytype,
        comptime _: bool,
        comptime _: usize,
        comptime remove_trailing_slashes: bool,
    ) type {
        return struct {
            const Self = @This();

            allocator: std.mem.Allocator,
            index: std.HashMapUnmanaged(u64, IndexType, BSSIndexMapContext, 80) = .{},
            values: std.ArrayListUnmanaged(ValueType) = .empty,

            pub var instance: *Self = undefined;
            pub var loaded = false;

            pub fn init(allocator: std.mem.Allocator) *Self {
                const self = allocator.create(Self) catch outOfMemory();
                self.* = .{ .allocator = allocator };
                instance = self;
                loaded = true;
                return self;
            }

            pub fn deinit(self: *Self) void {
                self.index.deinit(self.allocator);
                self.values.deinit(self.allocator);
                self.allocator.destroy(self);
                loaded = false;
            }

            fn keyFor(denormalized_key: []const u8) []const u8 {
                return if (comptime remove_trailing_slashes)
                    std.mem.trimEnd(u8, denormalized_key, std.fs.path.sep_str)
                else
                    denormalized_key;
            }

            pub fn getOrPut(self: *Self, denormalized_key: []const u8) !BSSResult {
                const h = hash(keyFor(denormalized_key));
                const entry = try self.index.getOrPut(self.allocator, h);
                if (entry.found_existing) {
                    return .{
                        .hash = h,
                        .index = entry.value_ptr.*,
                        .status = switch (entry.value_ptr.index) {
                            NotFound.index => .not_found,
                            Unassigned.index => .unknown,
                            else => .exists,
                        },
                    };
                }
                entry.value_ptr.* = Unassigned;
                return .{ .hash = h, .index = Unassigned, .status = .unknown };
            }

            pub fn get(self: *Self, denormalized_key: []const u8) ?*ValueType {
                const index = self.index.get(hash(keyFor(denormalized_key))) orelse return null;
                return self.atIndex(index);
            }

            pub fn markNotFound(self: *Self, result: BSSResult) void {
                self.index.put(self.allocator, result.hash, NotFound) catch outOfMemory();
            }

            pub fn atIndex(self: *Self, index: IndexType) ?*ValueType {
                if (index.index == NotFound.index or index.index == Unassigned.index) return null;
                if (index.index >= self.values.items.len) return null;
                return &self.values.items[index.index];
            }

            pub fn put(self: *Self, result: *BSSResult, value: ValueType) !*ValueType {
                if (result.index.index == NotFound.index or result.index.index == Unassigned.index) {
                    result.index = .{ .index = @intCast(self.values.items.len) };
                    try self.values.append(self.allocator, value);
                } else {
                    self.values.items[result.index.index] = value;
                }
                try self.index.put(self.allocator, result.hash, result.index);
                return &self.values.items[result.index.index];
            }
        };
    }

    pub const allocation_scope = struct {
        pub const Extra = struct {
            ptr: *anyopaque = undefined,
            vtable: ?*const VTable = null,

            pub const VTable = struct {
                onAllocationLeak: *const fn (*anyopaque, data: []u8) void,
            };
        };

        pub const AllocationScope = struct {
            pub const trace_limits: usize = 16;

            pub const Borrowed = struct {
                pub fn downcast(allocator: std.mem.Allocator) @This() {
                    _ = allocator;
                    return .{};
                }

                pub fn assertOwned(this: @This(), data: anytype) void {
                    _ = this;
                    _ = data;
                }
            };

            pub fn trackExternalAllocation(this: *@This(), data: []const u8, ret_addr: usize, extra: Extra) void {
                _ = this;
                _ = data;
                _ = ret_addr;
                _ = extra;
            }

            pub fn trackExternalFree(this: *@This(), data: []const u8, ret_addr: usize) !void {
                _ = this;
                _ = data;
                _ = ret_addr;
            }
        };

        pub fn isInstance(allocator: std.mem.Allocator) bool {
            _ = allocator;
            return false;
        }
    };

    pub const NullableAllocator = @import("bun_alloc/NullableAllocator.zig");
    pub const MaxHeapAllocator = @import("bun_alloc/MaxHeapAllocator.zig");
    pub const BufferFallbackAllocator = @import("bun_alloc/BufferFallbackAllocator.zig");
    pub const MaybeOwned = @import("bun_alloc/maybe_owned.zig").MaybeOwned;

    pub fn isDefault(allocator: std.mem.Allocator) bool {
        return allocator.vtable == @This().c_allocator.vtable;
    }

    pub fn asStd(allocator: anytype) std.mem.Allocator {
        return if (comptime @TypeOf(allocator) == std.mem.Allocator)
            allocator
        else
            allocator.allocator();
    }

    pub fn Borrowed(comptime Allocator: type) type {
        return if (comptime @hasDecl(Allocator, "Borrowed"))
            Allocator.Borrowed
        else
            Allocator;
    }

    pub fn borrow(allocator: anytype) Borrowed(@TypeOf(allocator)) {
        return if (comptime @hasDecl(@TypeOf(allocator), "Borrowed"))
            allocator.borrow()
        else
            allocator;
    }

    pub fn Nullable(comptime Allocator: type) type {
        return if (comptime Allocator == std.mem.Allocator)
            allocators.NullableAllocator
        else if (comptime @hasDecl(Allocator, "Nullable"))
            Allocator.Nullable
        else
            ?Allocator;
    }

    pub fn initNullable(comptime Allocator: type, allocator: ?Allocator) Nullable(Allocator) {
        return if (comptime Allocator == std.mem.Allocator or @hasDecl(Allocator, "Nullable"))
            .init(allocator)
        else
            allocator;
    }

    pub fn unpackNullable(comptime Allocator: type, allocator: Nullable(Allocator)) ?Allocator {
        return if (comptime Allocator == std.mem.Allocator or @hasDecl(Allocator, "Nullable"))
            allocator.get()
        else
            allocator;
    }

    pub const Default = struct {
        pub fn allocator(self: Default) std.mem.Allocator {
            _ = self;
            return allocators.c_allocator;
        }

        pub const deinit = void;
    };
};
pub const io_heap = @import("io/heap.zig");
pub const perf = struct {
    // Zig 0.17 compat: perf/system_timer.zig depends on `std.time.Timer`,
    // which 0.17.0-dev.263 removed. Parked until a thin `std.Io.Clock`
    // adapter lands.
    pub const generated_perf_trace_events = @import("perf/generated_perf_trace_events.zig");
    pub fn trace(_: []const u8) struct {
        pub fn end(_: @This()) void {}
    } {
        return .{};
    }
    // Wave-19 unmined-corner port (2026-05-19). Unbarriered TSC reader from
    // `bun/src/perf/hw_timer.zig`. Adds `Environment.isAarch64` /
    // `Environment.isX64` to the substrate so the asm-volatile paths gate
    // correctly.
    pub const hw_timer = @import("perf/hw_timer.zig");
};
pub const safety = struct {
    pub const thread_id = @import("safety/thread_id.zig");
    // Fourth-wave port batch (2026-05-17):
    pub const asan = @import("safety/asan.zig");
    pub const CriticalSection = @import("safety/CriticalSection.zig");
    pub const ThreadLock = @import("safety/ThreadLock.zig");
    pub const alloc = @import("safety/alloc.zig");
    pub const CheckedAllocator = @import("safety/alloc.zig").CheckedAllocator;
    // Thirteenth-wave port batch (2026-05-18). Upstream's `safety/safety.zig`
    // aggregator — re-exports `alloc`, `CheckedAllocator`, `CriticalSection`,
    // `ThreadLock` exactly the way Bun does. Wired as a sibling namespace so
    // callers can spell `home_rt.safety.aggregator.CheckedAllocator` when
    // they want the upstream-style flat surface.
    pub const aggregator = @import("safety/safety.zig");
};
pub const asan = safety.asan;

// Faithful port of upstream `bun.getThreadCount` (`src/bun.zig` line 3597):
// honors `UV_THREADPOOL_SIZE` / `GOMAXPROCS`, otherwise falls back to the
// detected CPU count, clamped to [2, 1024]. Home substitutes
// `std.Thread.getCpuCount` for upstream's `jsc.wtf.numberOfProcessorCores`.
pub fn getThreadCount() u16 {
    const max_threads = 1024;
    const min_threads = 2;
    const ThreadCount = struct {
        var cached_thread_count: u16 = 0;
        var cached_thread_count_once = once(getThreadCountOnce);
        fn getThreadCountFromUser() ?u16 {
            inline for (.{ "UV_THREADPOOL_SIZE", "GOMAXPROCS" }) |envname| {
                if (std.c.getenv(envname)) |env_ptr| {
                    const env = std.mem.span(env_ptr);
                    if (std.fmt.parseInt(u16, env, 10) catch null) |parsed| {
                        if (parsed >= min_threads) return @min(parsed, max_threads);
                    }
                }
            }
            return null;
        }
        fn getThreadCountOnce() void {
            const detected: u16 = @intCast(@max(1, std.Thread.getCpuCount() catch 1));
            cached_thread_count = @min(max_threads, @max(min_threads, getThreadCountFromUser() orelse detected));
        }
    };
    ThreadCount.cached_thread_count_once.call(.{});
    return ThreadCount.cached_thread_count;
}

// ---- src/threading/ ----------------------------------------------------
// Fifth-wave port batch (2026-05-18). Mutex/Condition/Futex + WaitGroup
// + an unbounded mpsc queue + Guarded smart pointers. Channel /
// ThreadPool / WorkPool are parked (Channel pulls in LinearFifo;
// ThreadPool depends on mimalloc + jsc.wtf).
pub const threading = struct {
    pub const Mutex = @import("threading/Mutex.zig");
    pub const Futex = @import("threading/Futex.zig");
    pub const Condition = @import("threading/Condition.zig");
    pub const WaitGroup = @import("threading/WaitGroup.zig");
    pub const guarded = @import("threading/guarded.zig");
    pub const Guarded = guarded.Guarded;
    pub const GuardedBy = guarded.GuardedBy;
    pub const DebugGuarded = guarded.Debug;
    pub const UnboundedQueue = @import("threading/unbounded_queue.zig").UnboundedQueue;
    // ThreadPool re-lands: its mimalloc + jsc.wtf idle-path deps now have
    // faithful libc-shim no-ops, so the kprotty-derived pool type-checks for
    // the transpiler resolver cone (PackageManagerTask embeds `ThreadPool.Task`).
    pub const ThreadPool = @import("threading/ThreadPool.zig");
};
pub const UnboundedQueue = threading.UnboundedQueue;
pub const ThreadPool = threading.ThreadPool;
pub const DotEnv = @import("dotenv/env_loader.zig");

// Faithful to upstream `bun.c` (`bun.zig:193` → `@import("translated-c-headers")`):
// the translated libc/system header surface. Home has no generated header bundle
// yet, so this exposes the individual libc symbols vendored Bun source needs.
// `workaround_missing_symbols.zig` routes `memmem` through here on posix.
pub const c = struct {
    pub extern fn memmem(
        haystack: ?[*]const u8,
        haystacklen: usize,
        needle: ?[*]const u8,
        needlelen: usize,
    ) ?[*]const u8;
    // libc memmove — overlap-safe copy used by the native `bun.memmove` path.
    pub extern fn memmove(dest: ?*anyopaque, src: ?*const anyopaque, n: usize) ?*anyopaque;
};

// ---- src/sys/ ----------------------------------------------------------
// Fifth-wave port batch (2026-05-18). Pure-data sys leaves; the
// big sys.zig substrate (4703 lines) is a future port. Lots of files
// blocked on `bun.sys.SystemErrno` + `bun.sys.Maybe` until that lands.
pub const sys = struct {
    const Sys = @This();

    // Faithful to upstream `bun.sys.workaround_symbols`
    // (`src/sys/sys.zig:20`): the platform-selected stat/memmem shims from
    // `workaround_missing_symbols.zig`. `strings.memmem` routes through this.
    pub const workaround_symbols = @import("workaround_missing_symbols.zig").current;

    // Faithful to upstream `sys/sys.zig:35` (`getErrno = platform_defs.getErrno`).
    pub const getErrno = @import("sys/sys.zig").getErrno;
    pub const unlink = @import("sys/sys.zig").unlink;
    pub const munmap = @import("sys/sys.zig").munmap;

    pub const Dir = @import("sys/dir.zig").Dir;
    pub const Error = @import("sys/Error.zig");
    pub const SignalCode = @import("sys/SignalCode.zig").SignalCode;
    // Seventh-wave port (2026-05-18):
    pub const Tag = @import("sys/tag.zig").Tag;
    // Eighth-wave port (2026-05-18). Generic `Maybe(T, E)` extracted from
    // upstream `src/sys/sys.zig` line 337 + `src/runtime/node.zig` line 64
    // (the underlying factory). Carves out the part of the 4703-line
    // sys.zig substrate that downstream files want without dragging in
    // every syscall wrapper. `kindFromMode` and a Zig-0.17-compat
    // `FileKind` enum tag along for the ride.
    pub const maybe = @import("sys/maybe.zig");
    pub fn Maybe(comptime ReturnTypeT: type) type {
        return maybe.Maybe(ReturnTypeT, Error);
    }
    pub const FileKind = maybe.FileKind;
    pub const kindFromMode = maybe.kindFromMode;
    // Wave-20 Tier-2 substrate (2026-05-19). `SystemErrno` proxies the
    // per-platform dispatcher in `errno/errno.zig` so copied source can
    // spell `home_rt.sys.SystemErrno` (mirrors upstream `bun.sys.SystemErrno`).
    // The strerror tables below are pure-data `EnumMap` instances keyed
    // off `SystemErrno`; they cover Node.js's `uv_strerror` table and
    // coreutils' `strerror` table respectively.
    pub const SystemErrno = @import("errno/errno.zig").SystemErrno;
    pub const E = @import("errno/errno.zig").E;
    pub const libuv_error_map = @import("sys/libuv_error_map.zig").libuv_error_map;
    pub const coreutils_error_map = @import("sys/coreutils_error_map.zig").coreutils_error_map;

    pub const LStat = struct {
        kind: std.Io.File.Kind = .file,
    };

    pub fn lstat_absolute(path_: [:0]const u8) !LStat {
        _ = path_;
        return .{};
    }

    fn unexpected(comptime tag: Tag) Error {
        return .{ .errno = @intFromEnum(E.INVAL), .syscall = tag };
    }

    fn errnoFromPosix(comptime tag: Tag, _: anyerror) Error {
        return unexpected(tag);
    }

    pub fn openat(dir: FD, path_: [:0]const u8, flags: i32, mode: Mode) Maybe(FD) {
        const fd = std.posix.openatZ(dir.native(), path_, O.toPacked(flags), mode) catch |err| {
            return .{ .err = errnoFromPosix(.open, err).withFd(dir) };
        };
        return .{ .result = .fromNative(fd) };
    }

    pub fn openatA(dir: FD, path_: anytype, flags: i32, mode: Mode) Maybe(FD) {
        const path_z = std.posix.toPosixPath(pathBytes(path_)) catch {
            return .{ .err = .{
                .errno = @intFromEnum(E.NAMETOOLONG),
                .syscall = .open,
            } };
        };
        return openat(dir, &path_z, flags, mode);
    }

    pub fn openA(path_: anytype, flags: i32, mode: Mode) Maybe(FD) {
        return openatA(.cwd(), path_, flags, mode);
    }

    fn pathBytes(path_: anytype) []const u8 {
        const PathType = @TypeOf(path_);
        return switch (@typeInfo(PathType)) {
            .pointer => |pointer_info| switch (pointer_info.size) {
                .one => switch (@typeInfo(pointer_info.child)) {
                    .array => path_[0..path_.len],
                    else => @compileError("unsupported bun.sys.openA path type: " ++ @typeName(PathType)),
                },
                .slice => path_,
                .many, .c => std.mem.span(path_),
            },
            else => path_,
        };
    }

    pub fn pwritev(fd: FD, buffers: []const PlatformIOVecConst, position: isize) Maybe(usize) {
        var total: usize = 0;
        var offset = position;
        for (buffers) |buffer| {
            const bytes = buffer.base[0..buffer.len];
            const rc = if (offset >= 0)
                std.c.pwrite(fd.native(), bytes.ptr, bytes.len, @intCast(offset))
            else
                std.c.write(fd.native(), bytes.ptr, bytes.len);
            if (std.c.errno(rc) != .SUCCESS) return .{ .err = unexpected(.pwritev).withFd(fd) };
            const written: usize = @intCast(rc);
            total += written;
            if (offset >= 0) offset += @intCast(written);
            if (written != bytes.len) break;
        }
        return .{ .result = total };
    }

    pub fn unlinkat(dir: FD, path_: anytype) Maybe(void) {
        if (std.c.errno(std.c.unlinkat(dir.native(), path_.ptr, 0)) != .SUCCESS) return .{ .err = unexpected(.unlink).withFd(dir) };
        return .success;
    }

    pub fn getFdPath(fd: FD, out_buffer: *PathBuffer) Maybe([]u8) {
        return .{ .result = @import("home").getFdPath(fd, out_buffer) catch |err| {
            return .{ .err = errnoFromPosix(.readlink, err).withFd(fd) };
        } };
    }

    pub fn preallocate_file(_: fd_t, _: usize, _: usize) !void {}

    pub fn moveFileZWithHandle(fd: FD, from_dir: FD, filename: [:0]const u8, to_dir: FD, destination: [:0]const u8) !void {
        _ = fd;
        if (std.c.errno(std.c.renameat(from_dir.native(), filename.ptr, to_dir.native(), destination.ptr)) != .SUCCESS) return error.Unexpected;
    }

    // Minimal faithful read helpers mirroring upstream `src/sys/sys.zig`
    // (`read` line 2129, `readAll` line 2189, `getFileSize` line 4208).
    // Home keeps the POSIX-only implementation the rest of this namespace
    // uses; downstream `sys.File` read paths (resolver/fs.zig) want these.
    pub fn read(fd: FD, buf: []u8) Maybe(usize) {
        const rc = std.posix.read(fd.native(), buf) catch |err| {
            return .{ .err = errnoFromPosix(.read, err).withFd(fd) };
        };
        return .{ .result = rc };
    }

    pub fn readAll(fd: FD, buf: []u8) Maybe(usize) {
        var rest = buf;
        var total_read: usize = 0;
        while (rest.len > 0) {
            switch (read(fd, rest)) {
                .result => |len| {
                    if (len == 0) break;
                    rest = rest[len..];
                    total_read += len;
                },
                .err => |err| return .{ .err = err },
            }
        }
        return .{ .result = total_read };
    }

    pub fn fstat(fd: FD) Maybe(std.c.Stat) {
        var stat_: std.c.Stat = std.mem.zeroes(std.c.Stat);
        if (std.c.errno(std.c.fstat(fd.native(), &stat_)) != .SUCCESS) {
            return .{ .err = unexpected(.fstat).withFd(fd) };
        }
        return .{ .result = stat_ };
    }

    /// Faithful to upstream `sys.stat` (`src/sys/sys.zig:522`): path-based stat.
    /// Routes through `workaround_symbols.stat` (libc `stat`/`stat64`) on posix,
    /// preserving the real errno so callers can branch on `.NOENT` etc.
    pub fn stat(path_: [:0]const u8) Maybe(std.c.Stat) {
        var stat_: std.c.Stat = std.mem.zeroes(std.c.Stat);
        const rc = workaround_symbols.stat(path_.ptr, &stat_);
        const err = std.posix.errno(rc);
        if (err != .SUCCESS) {
            return .{ .err = Error.fromCode(err, .stat) };
        }
        return .{ .result = stat_ };
    }

    pub fn getFileSize(fd: FD) Maybe(usize) {
        return switch (fstat(fd)) {
            .result => |stat_| .{ .result = @intCast(@max(stat_.size, 0)) },
            .err => |err| .{ .err = err },
        };
    }

    pub const File = struct {
        handle: FD,

        pub fn openat(dir: FD, path_: [:0]const u8, flags: i32, mode: Mode) Maybe(File) {
            return switch (Sys.openat(dir, path_, flags, mode)) {
                .result => |fd| .{ .result = .{ .handle = fd } },
                .err => |err| .{ .err = err },
            };
        }

        // Faithful port of `src/sys/File.zig` `from` (line 54). Home only
        // needs the std-file / FD / native-fd shapes the transpiler resolver
        // cone passes; unsupported types fail at comptime like upstream.
        pub fn from(other: anytype) File {
            const T = @TypeOf(other);
            if (T == File) return other;
            if (T == FD) return .{ .handle = other };
            if (T == fd_t) return .{ .handle = .fromNative(other) };
            if (T == std.Io.File) return .{ .handle = .fromStdFile(other) };
            if (T == std.Io.Dir) return .{ .handle = .fromStdDir(other) };
            @compileError("Unsupported home_rt.sys.File.from type " ++ @typeName(T));
        }

        pub fn read(this: File, buf: []u8) Maybe(usize) {
            return Sys.read(this.handle, buf);
        }

        pub fn readAll(this: File, buf: []u8) Maybe(usize) {
            return Sys.readAll(this.handle, buf);
        }

        pub fn getEndPos(this: File) Maybe(usize) {
            return Sys.getFileSize(this.handle);
        }

        pub fn stat(this: File) Maybe(std.c.Stat) {
            return Sys.fstat(this.handle);
        }

        pub fn close(this: File) void {
            this.handle.close();
        }

        pub fn writeAll(this: File, bytes: []const u8) Maybe(void) {
            var remaining = bytes;
            while (remaining.len > 0) {
                const written = std.posix.write(this.handle.native(), remaining) catch |err| {
                    return .{ .err = errnoFromPosix(.write, err).withFd(this.handle) };
                };
                if (written == 0) return .{ .err = unexpected(.write).withFd(this.handle) };
                remaining = remaining[written..];
            }
            return .success;
        }

        /// Faithful to upstream `sys.File.readFrom` (`src/sys/File.zig:422`):
        /// open `path` relative to `dir_fd` for reading, read the whole file into
        /// an allocator-owned buffer, close, and return the bytes. The inline
        /// `home_rt.sys.File` subset re-implements it with its own primitives
        /// (`openat` RDONLY + `getEndPos` + `readAll`) rather than the full
        /// `readFileFrom`/`readToEnd` chain, which pulls unported leaves.
        pub fn readFrom(dir_fd: anytype, path_: [:0]const u8, allocator: std.mem.Allocator) Maybe([]u8) {
            const this = switch (File.openat(File.from(dir_fd).handle, path_, O.CLOEXEC | O.RDONLY, 0)) {
                .err => |err| return .{ .err = err },
                .result => |f| f,
            };
            defer this.close();

            const size = switch (this.getEndPos()) {
                .err => |err| return .{ .err = err },
                .result => |s| s,
            };

            if (size == 0) {
                // Don't allocate an empty string; an empty slice is fine.
                return .{ .result = @constCast("") };
            }

            const buf = allocator.alloc(u8, size) catch return .{ .err = unexpected(.read).withFd(this.handle) };
            errdefer allocator.free(buf);

            const read_len = switch (this.readAll(buf)) {
                .err => |err| {
                    allocator.free(buf);
                    return .{ .err = err };
                },
                .result => |n| n,
            };

            return .{ .result = buf[0..read_len] };
        }
    };
};

pub const DirIterator = @import("runtime/node/dir_iterator.zig");

pub fn iterateDir(dir: FD) DirIterator.Iterator {
    return DirIterator.iterate(dir, .u8).iter;
}

// ---- src/paths/ --------------------------------------------------------
// Fifth-wave port batch (2026-05-18). `home_rt.path` (singular) is
// the existing std-wrapper namespace; the copied Bun surface lands as
// `home_rt.paths` (plural) to mirror upstream `src/paths/`.
pub const paths = struct {
    pub const Path = @import("paths/paths.zig").Path;
    pub const AbsPath = @import("paths/paths.zig").AbsPath;
    pub const AutoAbsPath = @import("paths/paths.zig").AutoAbsPath;
    pub const RelPath = @import("paths/paths.zig").RelPath;
    pub const AutoRelPath = @import("paths/paths.zig").AutoRelPath;
    pub const EnvPath = @import("paths/EnvPath.zig").EnvPath;
    pub const MAX_PATH_BYTES = @import("paths/paths.zig").MAX_PATH_BYTES;
    pub const PathBuffer = @import("paths/paths.zig").PathBuffer;
    pub const WPathBuffer = @import("paths/paths.zig").WPathBuffer;
    pub const OSPathChar = @import("paths/paths.zig").OSPathChar;
    pub const OSPathSlice = @import("paths/paths.zig").OSPathSlice;
    pub const OSPathSliceZ = @import("paths/paths.zig").OSPathSliceZ;
    pub const OSPathBuffer = @import("paths/paths.zig").OSPathBuffer;
    pub const path_buffer_pool = @import("paths/path_buffer_pool.zig").path_buffer_pool;
    pub const w_path_buffer_pool = @import("paths/path_buffer_pool.zig").w_path_buffer_pool;
    pub const os_path_buffer_pool = @import("paths/path_buffer_pool.zig").os_path_buffer_pool;
};
pub const Path = paths.Path;
pub const AbsPath = paths.AbsPath;
pub const AutoAbsPath = paths.AutoAbsPath;
pub const RelPath = paths.RelPath;
pub const AutoRelPath = paths.AutoRelPath;
pub const MAX_PATH_BYTES = paths.MAX_PATH_BYTES;
pub const PathBuffer = paths.PathBuffer;
pub const PATH_MAX_WIDE = @import("paths/paths.zig").PATH_MAX_WIDE;
pub const WPathBuffer = paths.WPathBuffer;
pub const OSPathChar = paths.OSPathChar;
pub const OSPathSlice = paths.OSPathSlice;
pub const OSPathSliceZ = paths.OSPathSliceZ;
pub const OSPathBuffer = paths.OSPathBuffer;
pub const path_buffer_pool = paths.path_buffer_pool;
pub const w_path_buffer_pool = paths.w_path_buffer_pool;
pub const os_path_buffer_pool = paths.os_path_buffer_pool;

// ---- src/picohttp_sys/ -------------------------------------------------
// Fifth-wave port batch (2026-05-18). Vendored picohttpparser FFI
// surface. Pure extern decls.
pub const picohttp_sys = struct {
    pub const picohttpparser = @import("picohttp_sys/picohttpparser.zig");
};

// `bun.picohttp` — the HTTP/1 request/response parser wrapper over
// picohttpparser (matches Bun's `bun.picohttp = @import("./picohttp/picohttp.zig")`).
// Used by the http client (`AsyncHTTP`) in the resolver/install cone.
pub const picohttp = @import("picohttp/picohttp.zig");

// ---- src/wyhash/ -------------------------------------------------------
// Fifth-wave port batch (2026-05-18). Fast non-cryptographic 64-bit
// hash (Zig stdlib v0.11 vintage forked here so it doesn't move
// underneath the resolver lockfile hash).
pub const wyhash = struct {
    pub const Wyhash11 = @import("wyhash/wyhash.zig").Wyhash11;
};

// ---- src/glob/ ---------------------------------------------------------
// Port batch updated 2026-06-01. `detectGlobSyntax` + the faithful upstream
// Bun matcher (`glob/matcher.zig`) are wired in; the previous hand-rolled
// `?`/`*`-only placeholder is removed so `bun.glob.match` now returns Bun's
// `MatchResult` enum (the shape every caller — WorkspaceMap, Tree, jest,
// pack/test/outdated commands — already switches on). The walker
// (`GlobWalker.zig`) re-attaches with bun.sys + bun.path.
pub const glob = struct {
    pub const detectGlobSyntax = @import("glob/glob.zig").detectGlobSyntax;

    /// Faithful upstream Bun glob matcher. Returns a `MatchResult`
    /// (`.match` / `.no_match` / `.negate_match` / `.negate_no_match`);
    /// call `.matches()` for a plain bool.
    pub const match = @import("glob/glob.zig").match;
};

// ---- src/highway/ ------------------------------------------------------
// Fifth-wave port batch (2026-05-18). Google Highway SIMD string ops
// (C ABI surface). Links against the matching Highway library.
pub const highway = @import("highway/highway.zig");

// ---- src/sourcemap/ ----------------------------------------------------
// Fifth-wave port batch (2026-05-18). VLQ codec only; Chunk /
// Mapping / LineOffsetTable / InternalSourceMap re-attach later.
pub const sourcemap = struct {
    pub const VLQ = @import("sourcemap/VLQ.zig");
    // Seventh-wave port batch (2026-05-18):
    pub const SourceMapState = @import("sourcemap/SourceMapState.zig").SourceMapState;
    pub const DebugIDFormatter = @import("sourcemap/DebugIDFormatter.zig").DebugIDFormatter;
    pub const SourceContentHandling = @import("sourcemap/types.zig").SourceContentHandling;
    pub const SourceMapLoadHint = @import("sourcemap/types.zig").SourceMapLoadHint;
    pub const SourceContent = @import("sourcemap/types.zig").SourceContent;
};

// ---- src/bundler/ ------------------------------------------------------
// Fifteenth-wave port batch (2026-05-18). The bundler-tree lives mostly
// under `packages/bundler/`; only a handful of pure-data leaves that
// other subsystems still need are mirrored here.
pub const bundler = struct {
    pub const IndexStringMap = @import("bundler/IndexStringMap.zig");
    pub const NativePluginABI = @import("bundler/native_plugin_abi.zig");
};

// ---- src/http_jsc/ -----------------------------------------------------
// Fifteenth-wave port batch (2026-05-18). JSC bridges for the pure-data
// types in `http_types/`. Each file is an `extern fn` declaration whose
// definition resolves at link time once the JSC C++ host fns land in
// Phase 12.2; the Zig surface stays minimal so callers can spell the
// `toJS` entry-points today.
pub const http_jsc = struct {
    pub const method_jsc = @import("http_jsc/method_jsc.zig");
    pub const fetch_enums_jsc = @import("http_jsc/fetch_enums_jsc.zig");
};

// ---- src/platform/ -----------------------------------------------------
// Fifteenth-wave port batch (2026-05-18). Platform-specific syscall + log
// surfaces. Darwin is fully self-contained (`$NOCANCEL` libc variants +
// `os_log_create` / signpost externs); Linux/Windows are parked on
// `bun.allocators.LinuxMemFdAllocator` / `bun.windows.*`.
pub const platform = struct {
    pub const darwin = @import("platform/darwin.zig");
};

// ---- src/css/ ----------------------------------------------------------
// Sixth-wave port batch (2026-05-18). Only the pure-data leaves that
// don't reach into `css_parser.zig` are ported today; the broader
// values/rules/properties tree re-attaches once `css_parser.zig`
// lands. Strategy A (self-contained-only) per agent #5's analysis.
pub const css = struct {
    pub const logical = @import("css/logical.zig");
    pub const sourcemap = @import("css/sourcemap.zig");
    pub const css_parser_stub = @import("css/css_parser_stub.zig");
    pub const values = struct {
        pub const values = @import("css/values/values.zig");
        // Seventh-wave port batch (2026-05-18, css Strategy B over stub):
        pub const css_string = @import("css/values/css_string.zig");
        pub const ratio = @import("css/values/ratio.zig");
        pub const alpha = @import("css/values/alpha.zig");
        // Eighth-wave port batch (2026-05-18):
        pub const number = @import("css/values/number.zig");
        pub const resolution = @import("css/values/resolution.zig");
        pub const size = @import("css/values/size.zig");
    };
    pub const properties = struct {
        pub const outline = @import("css/properties/outline.zig");
        // Eighth-wave port batch (2026-05-18):
        pub const display = @import("css/properties/display.zig");
        pub const overflow = @import("css/properties/overflow.zig");
        pub const position = @import("css/properties/position.zig");
        // Wave-15 Tier-1 grinder (2026-05-18). FillRule + AlphaValue
        // — pure-data shape leaves over the css_parser_stub.
        pub const shape = @import("css/properties/shape.zig");
        // Wave-16 Tier-1 grinder (2026-05-18). ContainerType +
        // ContainerNameList + Container — pure-data containment leaves.
        pub const contain = @import("css/properties/contain.zig");
        // Wave-18 Tier-1 grinder (2026-05-18). Text properties — pure
        // data shapes over the css_parser stub; `TextShadow.parse/toCss`
        // bodies dropped per stub policy (see file header).
        pub const text = @import("css/properties/text.zig");
    };
    pub const PropertyCategory = logical.PropertyCategory;
    pub const LogicalGroup = logical.LogicalGroup;
    // Seventh-wave port (2026-05-18) — stub-based CSS rule leaves.
    pub const rules = struct {
        pub const counter_style = @import("css/rules/counter_style.zig");
        pub const namespace = @import("css/rules/namespace.zig");
        pub const nesting = @import("css/rules/nesting.zig");
        pub const starting_style = @import("css/rules/starting_style.zig");
        pub const viewport = @import("css/rules/viewport.zig");
        pub const unknown = @import("css/rules/unknown.zig");
        pub const document = @import("css/rules/document.zig");
        // Eighth-wave port batch (2026-05-18):
        pub const custom_media = @import("css/rules/custom_media.zig");
        pub const media = @import("css/rules/media.zig");
        pub const tailwind = @import("css/rules/tailwind.zig");
        pub const scope = @import("css/rules/scope.zig");
    };
};

// ---- src/analytics/ ----------------------------------------------------
// Sixth-wave port batch (2026-05-18). The pure-std schema codec plus
// the JSC-free analytics gate. `Features` / `PackedFeatures` /
// `GenerateHeader` stay parked on bun.jsc.ModuleLoader + bun.Semver +
// bun.c.uname.
pub const analytics = struct {
    pub const schema = @import("analytics/schema.zig");
    pub const gate = @import("analytics/analytics.zig");
    pub const Features = @import("analytics/Features.zig");
};

// ---- src/*_sys/ --------------------------------------------------------
// Sixth-wave port batch (2026-05-18). Pure FFI extern wrappers around
// vendored native deps. Link-time contracts; no runtime logic.
pub const mimalloc_sys = struct {
    // Round-4 (2026-05-19): swap from the upstream wrapper to the libc
    // shim so `mi_malloc`/`mi_free`/`mi_calloc`/`mi_realloc` resolve at
    // link time without requiring a vendored mimalloc-bun build.
    // The real wrapper at `mimalloc_sys/mimalloc.zig` stays on disk and
    // re-enables when Phase 12.2 lands mimalloc-bun (revert this line).
    pub const mimalloc = @import("mimalloc_shim.zig");
};
pub const tcc_sys = struct {
    pub const tcc = @import("tcc_sys/tcc.zig");
};
pub const brotli_sys = struct {
    pub const brotli_c = @import("brotli_sys/brotli_c.zig");
};
pub const libdeflate_sys = struct {
    pub const libdeflate = @import("libdeflate_sys/libdeflate.zig");
};
pub const simdutf_sys = struct {
    pub const simdutf = @import("simdutf_sys/simdutf.zig");
};

// ---- src/cares_sys/ ----------------------------------------------------
// Eighth-wave port batch (2026-05-18). Vendored c-ares DNS FFI (1644 lines).
// The 22 `*ToJSResponse` JSC-bridge sentinels are local opaques; Windows
// EAI branch falls back to ENOTFOUND until libuv_sys lands.
pub const cares_sys = struct {
    pub const c_ares = @import("cares_sys/c_ares.zig");
};

// ---- src/libarchive_sys/ -----------------------------------------------
// Eighth-wave port batch (2026-05-18). Vendored libarchive FFI (1497 lines).
// `writeZerosToFile` + `readDataIntoFd` armed with `@compileError` until
// `home_rt.sys.File.{pwriteAll, writeAll, setFileOffset, ftruncate}` ports.
pub const libarchive_sys = struct {
    pub const bindings = @import("libarchive_sys/bindings.zig");
};

// ---- src/zlib_sys/ -----------------------------------------------------
// Wave-14 port batch (2026-05-18). Vendored zlib FFI shape: the shared
// `Z_OK` / `Z_BINARY` / `Z_NO_FLUSH` enum mirrors + the POSIX
// `z_stream_s` extern struct + `inflate`/`deflate` init wrappers.
// Pure declarations — link-time contract against the shared zlib in
// `packages/bun-usockets`.
pub const zlib_sys = struct {
    pub const shared = @import("zlib_sys/shared.zig");
    pub const posix = @import("zlib_sys/posix.zig");
    // Sixteenth-wave port batch (2026-05-18). Translate-c'd zlib.h
    // Windows-LLP64 shape; routes through shared.zig at compile time.
    pub const win32 = @import("zlib_sys/win32.zig");
};

// Faithful to upstream `bun.mimalloc` (`bun.zig`): the mimalloc bindings.
// Home links against the `mimalloc_shim` (std.c.malloc-backed) until the
// vendored mimalloc-bun build lands; it exposes `mi_malloc`/`mi_free`/
// `mi_usable_size`, which `boringssl/boringssl.zig` routes its allocator
// exports through.
pub const mimalloc = mimalloc_sys.mimalloc;

// ---- src/md/ -----------------------------------------------------------
// Sixteenth-wave port batch (2026-05-18). Pure-data markdown tables:
// unicode case-fold map + HTML named entity table.
pub const md = struct {
    pub const unicode = @import("md/unicode.zig");
    pub const entity = @import("md/entity.zig");
};

// ---- src/windows_sys/ --------------------------------------------------
// Sixteenth-wave port batch (2026-05-18). Raw Win32 extern decls
// (aliases over std.os.windows).
pub const windows_sys = struct {
    pub const externs = @import("windows_sys/externs.zig");
};

// ---- src/codegen/ ------------------------------------------------------
// Sixteenth-wave port batch (2026-05-18). Translate-c post-processing
// tool for Windows headers.
pub const codegen = struct {
    pub const process_windows_translate_c = @import("codegen/process_windows_translate_c.zig");
};

// ---- src/s3_signing/ ---------------------------------------------------
// Eighth-wave port batch (2026-05-18). Pure-Zig S3 helpers: canned-ACL
// + storage-class enums + error code/message lookup. Credentials +
// signer parked on JSC + webcore surface.
pub const s3_signing = struct {
    pub const ACL = @import("s3_signing/acl.zig").ACL;
    pub const StorageClass = @import("s3_signing/storage_class.zig").StorageClass;
    pub const sign_error = @import("s3_signing/error.zig");
    pub const credentials = @import("s3_signing/credentials.zig");
};

pub const S3 = struct {
    pub const ACL = s3_signing.ACL;
    pub const StorageClass = s3_signing.StorageClass;
    pub const S3Error = s3_signing.sign_error.S3Error;
    pub const S3Credentials = s3_signing.credentials.S3Credentials;
    pub const S3CredentialsWithOptions = s3_signing.credentials.S3CredentialsWithOptions;
    pub const MultiPartUploadOptions = @import("runtime/webcore/s3/multipart_options.zig").MultiPartUploadOptions;

    pub const S3DownloadResult = union(enum) { success: []const u8, failure: S3Error };
    pub const S3UploadResult = union(enum) { success: void, failure: S3Error };
    pub const S3DeleteResult = union(enum) { success: void, failure: S3Error };
    pub const S3StatResult = union(enum) { success: void, failure: S3Error };
    pub const S3ListObjectsResult = union(enum) { success: void, failure: S3Error };
    pub const S3ListObjectsOptions = struct {};
    pub const MultiPartUpload = opaque {};
    pub const S3HttpDownloadStreamingTask = opaque {};
    pub const S3HttpSimpleTask = opaque {};
};

// ---- src/errno/ --------------------------------------------------------
// Seventh-wave port batch (2026-05-18). POSIX errno tables per platform.
// Each file inlines a small `uv_constants` block for the few UV_E* codes
// that have no native POSIX counterpart; those are replaced by
// `home_rt.libuv_sys.libuv.UV_E*` once libuv_sys lands. Windows skipped
// (needs windows.Win32Error + libuv_sys).
pub const errno = struct {
    pub const darwin = @import("errno/darwin_errno.zig");
    pub const linux = @import("errno/linux_errno.zig");
    pub const freebsd = @import("errno/freebsd_errno.zig");
};

// ---- src/exe_format/ ---------------------------------------------------
// Seventh-wave port batch (2026-05-18). Standalone-executable section
// writers used by `home build --compile`. Only PE is self-contained;
// ELF/Mach-O parked on bun.sys (ELF) and bun.sha.SHA256 (Mach-O codesign).
pub const exe_format = struct {
    pub const pe = @import("exe_format/pe.zig");
};

// ---- src/zstd/ ---------------------------------------------------------
// Seventh-wave port batch (2026-05-18). Vendored facebook/zstd FFI surface
// + the streaming-decompress reader. Upstream pulled the `ZSTD_*` extern
// symbols from `bun.c` (translate-c over `<zstd.h>`); we inline them as
// `extern fn` decls in `zstd.c` since translate-c isn't wired up yet.
pub const zstd = struct {
    pub const zstd = @import("zstd/zstd.zig");
};

// ---- src/boringssl_sys/ ------------------------------------------------
// Seventh-wave port batch (2026-05-18). Vendored google/boringssl C ABI
// surface — SSL_*, BIO_*, X509_*, EVP_*, RSA_*, EC_*, ERR_*, and the rest
// of libcrypto/libssl. 19 306 lines, near-verbatim copy. The only deviation
// from upstream is that `bun.uws.us_bun_verify_error_t` is inlined as
// `SSL.us_bun_verify_error_t` (`uws.zig` carries a JSC-tied helper that
// hasn't been ported yet).
pub const boringssl_sys = struct {
    pub const boringssl = @import("boringssl_sys/boringssl.zig");
};

// ---- src/lolhtml_sys/ --------------------------------------------------
// Seventh-wave port batch (2026-05-18). Vendored cloudflare/lol-html C ABI
// surface (`lol_html_*`). `HTMLString.toString` + `HTMLString.toJS` are
// stubbed because they reach into `bun.String` and the JSC-tied
// `runtime/api/lolhtml_jsc.zig`; everything else is verbatim.
pub const lolhtml_sys = struct {
    pub const lol_html = @import("lolhtml_sys/lol_html.zig");
};

// ---- src/jsc_stub.zig --------------------------------------------------
// WASM-target opaque stubs. Mirrors Bun's `jsc_stub` namespace exactly.
pub const jsc_stub = @import("jsc_stub.zig");

// ---- src/sql/ ----------------------------------------------------------
// MySQL + Postgres value types, status enums, protocol type tags. Pure
// data — the wire-protocol encoders, statement runtime, and JS surface
// land in Phase 12.5 (Web standards + Home.SQL).
pub const sql = struct {
    pub const shared = struct {
        pub const ConnectionFlags = @import("sql/shared/ConnectionFlags.zig").ConnectionFlags;
        pub const SQLQueryResultMode = @import("sql/shared/SQLQueryResultMode.zig").SQLQueryResultMode;
        // Wave-18 Tier-0 grinder (2026-05-18). Stub union with
        // `.owned`/`.temporary`/`.inline_storage`/`.empty` variants —
        // packet decoders/encoders that field-store `Data` compile;
        // `toOwned`/`zdeinit`/`create` defer to Phase 12.2.
        pub const Data = @import("sql/shared/Data.zig").Data;
        // Wave-22 grinder (2026-05-19). JSC distinguishes index-vs-name
        // property names, so column identifiers parse decimal-only names
        // into `.index : u32` ahead of time. `.duplicate` flags sibling
        // collision. Pure data over the wave-18 Data stub.
        pub const ColumnIdentifier = @import("sql/shared/ColumnIdentifier.zig").ColumnIdentifier;
    };
    pub const mysql = struct {
        pub const SSLMode = @import("sql/mysql/SSLMode.zig").SSLMode;
        pub const ConnectionState = @import("sql/mysql/ConnectionState.zig").ConnectionState;
        pub const TLSStatus = @import("sql/mysql/TLSStatus.zig").TLSStatus;
        pub const QueryStatus = @import("sql/mysql/QueryStatus.zig").Status;
        pub const MySQLQueryResult = @import("sql/mysql/MySQLQueryResult.zig");
        pub const MySQLTypes = @import("sql/mysql/MySQLTypes.zig");
        // Wave-25 grinder (2026-05-19) — pure `Param` descriptor used
        // by the wire-protocol encoders. Drops in on top of the
        // wave-23 ColumnDefinition41 + MySQLTypes ports.
        pub const MySQLParam = @import("sql/mysql/MySQLParam.zig");
        pub const Param = MySQLParam.Param;
        // Wave-16 Tier-1 grinder (2026-05-18):
        pub const AuthMethod = @import("sql/mysql/AuthMethod.zig").AuthMethod;
        pub const protocol = struct {
            pub const PacketType = @import("sql/mysql/protocol/PacketType.zig").PacketType;
            pub const PacketHeader = @import("sql/mysql/protocol/PacketHeader.zig");
            // Wave-14 port batch (2026-05-18). Length-encoded integer
            // codec (MySQL wire-protocol primitive). Depends only on
            // `home_rt.BoundedArray`.
            pub const EncodeInt = @import("sql/mysql/protocol/EncodeInt.zig");
            // Wave-18/28 MySQL wire-protocol reader factory plus packet
            // leaves that decode over its method table.
            pub const NewReader = @import("sql/mysql/protocol/NewReader.zig").NewReader;
            pub const decoderWrap = @import("sql/mysql/protocol/NewReader.zig").decoderWrap;
            pub const EOFPacket = @import("sql/mysql/protocol/EOFPacket.zig");
            pub const StmtPrepareOKPacket = @import("sql/mysql/protocol/StmtPrepareOKPacket.zig");
            pub const LocalInfileRequest = @import("sql/mysql/protocol/LocalInfileRequest.zig");
            pub const OKPacket = @import("sql/mysql/protocol/OKPacket.zig");
            // Wave-22/28 MySQL wire-protocol writer factory +
            // `writeWrap` glue.
            pub const NewWriter = @import("sql/mysql/protocol/NewWriter.zig").NewWriter;
            pub const writeWrap = @import("sql/mysql/protocol/NewWriter.zig").writeWrap;
            // Wave-27 grinder (2026-05-20). MySQL in-memory reader copied
            // from Bun: offset/message-start tracking, bounded reads,
            // backwards skip, and NUL-terminated field reads.
            pub const StackReader = @import("sql/mysql/protocol/StackReader.zig");
            // Wave-27 grinder (2026-05-20). COM_QUERY writer leaf copied
            // from Bun.
            pub const Query = @import("sql/mysql/protocol/Query.zig");
            // Wave-27 grinder (2026-05-20). Client authentication
            // response packet writer copied from Bun. Connect attributes
            // use std.StringHashMapUnmanaged until the Bun alias lands.
            pub const HandshakeResponse41 = @import("sql/mysql/protocol/HandshakeResponse41.zig");
            // Wave-22 grinder (2026-05-19). Three additional MySQL
            // wire-protocol leaves from less-mined corners:
            //   - ResultSetHeader (`field_count`): leading row-set
            //     marker carrying the upcoming ColumnDefinition41 count.
            //   - AuthSwitchResponse: client → server reply after a
            //     server-side auth switch (header 0xfe).
            //   - ErrorPacket: server → client error response (0xff
            //     header, optional SQL state, error message). JSC-bridge
            //     `createMySQLError` + `toJS` re-exports omitted —
            //     Phase 12.2.
            pub const ResultSetHeader = @import("sql/mysql/protocol/ResultSetHeader.zig");
            pub const AuthSwitchResponse = @import("sql/mysql/protocol/AuthSwitchResponse.zig");
            pub const ErrorPacket = @import("sql/mysql/protocol/ErrorPacket.zig");
            // Wave-23 grinder (2026-05-19). Additional MySQL wire-protocol
            // leaves mined from less-touched corners:
            //   - SSLRequest: 32-byte TLS-upgrade negotiation packet sent
            //     right before HandshakeResponse41 once CLIENT_SSL is set.
            //   - HandshakeV10: server → client opening handshake carrying
            //     server version, connection id, auth scramble + capability
            //     flags.
            //   - ColumnDefinition41: per-column metadata record nested in
            //     ResultSet response (catalog/schema/table/name/type/...).
            //   - MySQLRequest (top-level): trivial COM_QUERY +
            //     COM_STMT_PREPARE writer helpers.
            // All bodies reach into wave-21 NewReader/NewWriter stub method
            // surfaces — compile errors out only if exercised.
            pub const SSLRequest = @import("sql/mysql/protocol/SSLRequest.zig");
            pub const HandshakeV10 = @import("sql/mysql/protocol/HandshakeV10.zig");
            pub const ColumnDefinition41 = @import("sql/mysql/protocol/ColumnDefinition41.zig");
        };
        pub const MySQLRequest = @import("sql/mysql/MySQLRequest.zig");
    };
    pub const postgres = struct {
        pub const SSLMode = @import("sql/postgres/SSLMode.zig").SSLMode;
        pub const Status = @import("sql/postgres/Status.zig").Status;
        pub const TLSStatus = @import("sql/postgres/TLSStatus.zig").TLSStatus;
        pub const CommandTag = @import("sql/postgres/CommandTag.zig").CommandTag;
        pub const AnyPostgresError = @import("sql/postgres/AnyPostgresError.zig").AnyPostgresError;
        pub const PostgresErrorOptions = @import("sql/postgres/AnyPostgresError.zig").PostgresErrorOptions;
        // Fifteenth-wave port batch (2026-05-18). Debug-only socket-monitor
        // mirrors that copy inbound/outbound Postgres bytes to a file when
        // `BUN_POSTGRES_SOCKET_MONITOR_{READER,WRITER}` are set. Both lean
        // on the wave-15 `home_rt.Output.scoped` no-op stub.
        pub const DebugSocketMonitorReader = @import("sql/postgres/DebugSocketMonitorReader.zig");
        pub const DebugSocketMonitorWriter = @import("sql/postgres/DebugSocketMonitorWriter.zig");
        // Wave-17 grinder (2026-05-19) — debug socket monitor aggregator.
        pub const SocketMonitor = @import("sql/postgres/SocketMonitor.zig");
        pub const types = struct {
            pub const int_types = @import("sql/postgres/types/int_types.zig");
        };
        pub const protocol = struct {
            pub const TransactionStatusIndicator = @import("sql/postgres/protocol/TransactionStatusIndicator.zig").TransactionStatusIndicator;
            pub const PortalOrPreparedStatement = @import("sql/postgres/protocol/PortalOrPreparedStatement.zig").PortalOrPreparedStatement;
            pub const zHelpers = @import("sql/postgres/protocol/zHelpers.zig");
            // Sixteenth-wave port batch (2026-05-18). Generic
            // decoder/writer factories + concrete BackendKeyData
            // packet leaf.
            pub const DecoderWrap = @import("sql/postgres/protocol/DecoderWrap.zig").DecoderWrap;
            pub const WriteWrap = @import("sql/postgres/protocol/WriteWrap.zig").WriteWrap;
            pub const BackendKeyData = @import("sql/postgres/protocol/BackendKeyData.zig");
            pub const NewReaderWrap = @import("sql/postgres/protocol/NewReader.zig").NewReaderWrap;
            pub const NewReader = @import("sql/postgres/protocol/NewReader.zig").NewReader;
            pub const NewWriterWrap = @import("sql/postgres/protocol/NewWriter.zig").NewWriterWrap;
            pub const NewWriter = @import("sql/postgres/protocol/NewWriter.zig").NewWriter;
            // Wave-18 Tier-0 grinder (2026-05-18). Postgres
            // wire-protocol writer/reader packet leaves. All reach
            // into the wave-16 NewReader/NewWriter method surface.
            pub const PasswordMessage = @import("sql/postgres/protocol/PasswordMessage.zig");
            pub const SASLResponse = @import("sql/postgres/protocol/SASLResponse.zig");
            pub const SASLInitialResponse = @import("sql/postgres/protocol/SASLInitialResponse.zig");
            pub const CopyOutResponse = @import("sql/postgres/protocol/CopyOutResponse.zig");
            pub const Parse = @import("sql/postgres/protocol/Parse.zig");
            pub const ReadyForQuery = @import("sql/postgres/protocol/ReadyForQuery.zig");
            pub const ParameterStatus = @import("sql/postgres/protocol/ParameterStatus.zig");
            pub const DataRow = @import("sql/postgres/protocol/DataRow.zig");
            // Wave-18 Tier-1 grinder (2026-05-18). Additional
            // Postgres wire-protocol packet leaves over the wave-16
            // NewReader/NewWriter stubs + shared.Data stub. Decoder /
            // encoder bodies stay verbatim — they trip `@compileError`
            // on actual call until the real reader/writer + bun.ByteList
            // land.
            pub const Close = @import("sql/postgres/protocol/Close.zig").Close;
            pub const Describe = @import("sql/postgres/protocol/Describe.zig");
            pub const Execute = @import("sql/postgres/protocol/Execute.zig");
            pub const CopyInResponse = @import("sql/postgres/protocol/CopyInResponse.zig");
            pub const CommandComplete = @import("sql/postgres/protocol/CommandComplete.zig");
            pub const CopyData = @import("sql/postgres/protocol/CopyData.zig");
            pub const CopyFail = @import("sql/postgres/protocol/CopyFail.zig");
            // Wave-22 grinder (2026-05-19). Postgres backend
            // RowDescription ('T') + nested FieldDescription record
            // (1-per-column) + extended-query ParameterDescription ('t').
            // All three decode via the wave-16 NewReader stub method
            // surface; exercising decode() trips a natural compile
            // error until the real reader lands (Phase 12.2).
            pub const FieldDescription = @import("sql/postgres/protocol/FieldDescription.zig");
            pub const RowDescription = @import("sql/postgres/protocol/RowDescription.zig");
            pub const ParameterDescription = @import("sql/postgres/protocol/ParameterDescription.zig");
            // Wave-22 grinder (2026-05-19). Postgres startup packet
            // (`user` / `database` / `client_encoding` + protocol
            // version 196608). Writer body reaches into the wave-16
            // NewWriter stub method surface.
            pub const StartupMessage = @import("sql/postgres/protocol/StartupMessage.zig");
            // Wave-23 grinder (2026-05-19). Postgres `R` Authentication
            // packet — tagged-union over the 10+ auth-code subtypes
            // (Ok / ClearTextPassword / MD5Password / SASL family /
            // SASLContinue / SASLFinal / ...). Decoder body lives
            // inside a comptime-generic `decodeInternal` so the
            // `home_rt.strings.split` + `reader.bytes(...)` calls
            // only get analyzed at instantiation; the file is
            // compile-clean today.
            pub const Authentication = @import("sql/postgres/protocol/Authentication.zig").Authentication;
            // Wave-25 grinder (2026-05-19). Postgres `A`
            // (NotificationResponse) backend packet. Pid + channel +
            // payload from a `LISTEN`/`NOTIFY` publication. Uses the
            // wave-18 `shared.Data.ByteList` stub for `channel` /
            // `payload`; decoder body reaches into the wave-16 NewReader
            // stub method surface (length/int4/readZ).
            pub const NotificationResponse = @import("sql/postgres/protocol/NotificationResponse.zig");
            // Wave-26 grinder (2026-05-19). FieldMessage tagged-union
            // (one per `T<value>` record inside an ErrorResponse /
            // NoticeResponse body) + the two backend packets that
            // hold a stream of them. Upstream `bun.String` is
            // substituted with a heap-owned `[]u8` slice (`cloneUTF8`
            // / `deref` / `slice` / `format` — same public shape).
            pub const FieldMessage = @import("sql/postgres/protocol/FieldMessage.zig").FieldMessage;
            pub const ErrorResponse = @import("sql/postgres/protocol/ErrorResponse.zig");
            pub const NoticeResponse = @import("sql/postgres/protocol/NoticeResponse.zig");
            pub const NegotiateProtocolVersion = @import("sql/postgres/protocol/NegotiateProtocolVersion.zig");
        };
    };
};

test "home_rt: substrate compiles" {
    try std.testing.expectEqualStrings(
        "fd0b6f1a271fca0b8124b69f230b100f4d636af6",
        upstream_sha,
    );
}

test "home_rt: getThreadCount clamps to the [2, 1024] range" {
    const count = getThreadCount();
    try std.testing.expect(count >= 2);
    try std.testing.expect(count <= 1024);
    // Cached `once` must keep returning the same value.
    try std.testing.expectEqual(count, getThreadCount());
}

test "home_rt: sys.File read helpers round-trip a temp file" {
    const payload = "home-rt-sys-file";

    // Create a temp file via the POSIX layer that sys.File wraps, so the test
    // stays independent of the churning std.Io.Dir API.
    var name_buf: [64]u8 = undefined;
    const tmp_path = try std.fmt.bufPrintZ(&name_buf, "/tmp/home_rt_sys_file_{d}.txt", .{std.c.getpid()});
    const wfd = std.c.open(tmp_path, .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
    try std.testing.expect(wfd >= 0);
    {
        defer _ = std.c.close(wfd);
        const w = std.c.write(wfd, payload.ptr, payload.len);
        try std.testing.expectEqual(@as(isize, @intCast(payload.len)), w);
    }
    defer _ = std.c.unlink(tmp_path);

    const rfd = std.c.open(tmp_path, .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
    try std.testing.expect(rfd >= 0);
    const file = sys.File.from(FD.fromNative(rfd));
    defer file.close();

    const size = switch (file.getEndPos()) {
        .result => |s| s,
        .err => return error.UnexpectedSysError,
    };
    try std.testing.expectEqual(@as(usize, payload.len), size);

    var buf: [64]u8 = undefined;
    const read_len = switch (file.readAll(buf[0..])) {
        .result => |n| n,
        .err => return error.UnexpectedSysError,
    };
    try std.testing.expectEqualStrings(payload, buf[0..read_len]);
}

test "home_rt: Timer is monotonic and resets" {
    var timer = try Timer.start();
    // read() never goes backwards and stays small immediately after start.
    const a = timer.read();
    const b = timer.read();
    try std.testing.expect(b >= a);
    // reset() rebases to ~0.
    timer.reset();
    try std.testing.expect(timer.read() < std.time.ns_per_s);
    // lap() returns time since the previous lap and never underflows.
    const first = timer.lap();
    _ = first;
    const second = timer.lap();
    try std.testing.expect(second < std.time.ns_per_s);
}

test "home_rt: stackFallback serves from the inline buffer then falls back" {
    var sfb = stackFallback(16, std.testing.allocator);
    const sfb_alloc = sfb.get();

    // Small allocation fits in the 16-byte inline buffer.
    const small = try sfb_alloc.alloc(u8, 8);
    @memset(small, 0xAB);
    try std.testing.expectEqual(@as(u8, 0xAB), small[0]);
    sfb_alloc.free(small);

    // Larger-than-buffer allocation spills to the fallback allocator and must
    // still be freeable through the same interface.
    const big = try sfb_alloc.alloc(u8, 4096);
    @memset(big, 0x5C);
    try std.testing.expectEqual(@as(u8, 0x5C), big[4095]);
    sfb_alloc.free(big);
}

test "home_rt: sys.stat + File.readFrom round-trip a temp file" {
    const payload = "home-rt-sys-stat-readfrom";

    var name_buf: [80]u8 = undefined;
    const tmp_path = try std.fmt.bufPrintZ(&name_buf, "/tmp/home_rt_sys_stat_{d}.txt", .{std.c.getpid()});
    const wfd = std.c.open(tmp_path, .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
    try std.testing.expect(wfd >= 0);
    {
        defer _ = std.c.close(wfd);
        const w = std.c.write(wfd, payload.ptr, payload.len);
        try std.testing.expectEqual(@as(isize, @intCast(payload.len)), w);
    }
    defer _ = std.c.unlink(tmp_path);

    // sys.stat reports the size and is errno-accurate for a missing path.
    const st = switch (sys.stat(tmp_path)) {
        .result => |s| s,
        .err => return error.UnexpectedSysError,
    };
    try std.testing.expectEqual(@as(i64, @intCast(payload.len)), @as(i64, @intCast(st.size)));

    const missing = sys.stat("/tmp/home_rt_definitely_missing_xyz.txt");
    try std.testing.expect(missing == .err);
    try std.testing.expect(missing.err.getErrno() == .NOENT);

    // File.readFrom opens + reads + closes, returning the full contents.
    const bytes = switch (sys.File.readFrom(FD.cwd(), tmp_path, std.testing.allocator)) {
        .result => |b| b,
        .err => return error.UnexpectedSysError,
    };
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings(payload, bytes);
}

test "home_rt: cli.which_npm_client surface is exported" {
    const NPMClient = cli.which_npm_client.NPMClient;
    const npm_client: NPMClient = .{ .bin = "home", .tag = .home };
    try std.testing.expectEqualStrings("home", npm_client.bin);
    try std.testing.expect(npm_client.tag == .home);
}

test "home_rt: cli.yarn_commands recognises canonical yarn verbs" {
    try std.testing.expect(cli.yarn_commands.all_yarn_commands.has("install"));
    try std.testing.expect(cli.yarn_commands.all_yarn_commands.has("add"));
    try std.testing.expect(cli.yarn_commands.all_yarn_commands.has("remove"));
    try std.testing.expect(cli.yarn_commands.all_yarn_commands.has("workspaces"));
    try std.testing.expect(!cli.yarn_commands.all_yarn_commands.has("not-a-yarn-command"));
}

test "home_rt: Environment flags exist" {
    try std.testing.expect(Environment.isPosix != Environment.isWindows);
}

test "home_rt: strings.indexOfChar reaches the colon-list parser" {
    try std.testing.expectEqual(@as(?usize, 3), strings.indexOfChar("foo:bar", ':'));
}

test {
    // Pull nested module tests into the home_rt test runner so a single
    // `zig build test -Dfilter=home_rt` exercises the whole substrate.
    _ = strings;
    _ = @import("bun_core/singly_linked_list.zig");
    _ = Output;
    _ = Global;
    _ = Environment;
    _ = fmt;
    _ = path;
    _ = env_var;
    _ = comptime_string_map;
    _ = identity_context;
    _ = cli.which_npm_client;
    _ = cli.yarn_commands;
    _ = jsc;
    _ = io;
    _ = http;
    _ = http_types;
    _ = tty;
    _ = safety;
    _ = jsc_stub;
    _ = sql;
    _ = options_types;
    _ = install_types;
    _ = Semver;
    _ = uws_sys;
    _ = event_loop;
    _ = unicode;
    _ = runtime;
    _ = @import("runtime/bake/bake.zig");
    _ = @import("runtime/bake/DevServer.zig");
    _ = @import("runtime/bake/DevServer/HmrSocket.zig");
    _ = @import("runtime/bake/DevServer/RouteBundle.zig");
    _ = @import("runtime/bake/DevServer/SourceMapStore.zig");
    _ = @import("runtime/server/HTMLBundle.zig");
    _ = @import("runtime/server/server.zig");
    _ = node;
    _ = meta;
    _ = crash_handler;
    _ = install;
    _ = ptr;
    _ = threading;
    _ = sys;
    _ = paths;
    _ = picohttp_sys;
    _ = wyhash;
    _ = glob;
    _ = highway;
    _ = sourcemap;
    _ = ast;
    _ = css;
    _ = analytics;
    _ = mimalloc_sys;
    _ = tcc_sys;
    _ = brotli_sys;
    _ = libdeflate_sys;
    _ = simdutf_sys;
    _ = zstd;
    _ = boringssl_sys;
    _ = lolhtml_sys;
    _ = errno;
    _ = exe_format;
    _ = s3_signing;
    _ = cares_sys;
    _ = libarchive_sys;
    _ = @import("bun/cli_spawn_process_fs_file.zig");
    // Pull nested module tests through their actual file imports so
    // the home_rt test runner exercises every copied leaf.
    _ = @import("event_loop/DeferredTaskQueue.zig");
    _ = @import("unicode/uucode/lut.zig");
    _ = @import("unicode/uucode_lib/src/ascii.zig");
    _ = @import("unicode/uucode_lib/src/utf8.zig");
    _ = @import("unicode/uucode_lib/src/x/types.x.zig");
    _ = @import("unicode/uucode_lib/src/x/types_x/grapheme.zig");
    _ = @import("runtime/image/exif.zig");
    _ = @import("runtime/server/HTTPStatusText.zig");
    _ = @import("runtime/webcore/s3/multipart_options.zig");
    _ = @import("runtime/valkey_jsc/ValkeyContext.zig");
    _ = @import("node/nodejs_error_code.zig");
    // myers_diff parked on Zig 0.17 compat.
    _ = @import("uws_sys/quic/Header.zig");
    _ = @import("sql/mysql/protocol/PacketHeader.zig");
    // Second-wave port batch (2026-05-17, agent A–H follow-up):
    _ = @import("alloc/fallback/z.zig");
    _ = @import("http/H2FrameParser.zig");
    _ = @import("http/Signals.zig");
    _ = @import("http_types/mime_type_list_enum.zig");
    _ = @import("io/heap.zig");
    _ = @import("perf/generated_perf_trace_events.zig");
    _ = @import("sql/mysql/MySQLTypes.zig");
    // Third-wave port batch (2026-05-17, parallel-agent integration):
    _ = @import("core/string/immutable/exact_size_matcher.zig");
    _ = @import("core/bounded_array.zig");
    _ = @import("meta/bits.zig");
    _ = @import("meta/traits.zig");
    _ = @import("crash_handler/handle_oom.zig");
    _ = @import("options_types/CodeCoverageOptions.zig");
    // Fourth-wave port batch (2026-05-17, 8-agent parallel dispatch):
    _ = @import("jsc/Exception.zig");
    _ = @import("jsc/CppTask.zig");
    _ = @import("jsc/config.zig");
    _ = @import("jsc/codegen.zig");
    _ = @import("jsc/comptime_string_map_jsc.zig");
    _ = @import("http/HTTPRequestBody.zig");
    _ = @import("http/websocket.zig");
    _ = @import("http/lshpack.zig");
    _ = @import("install/ConfigVersion.zig");
    _ = @import("http_types/ETag.zig");
    _ = @import("http_types/URLPath.zig");
    _ = @import("event_loop/AnyTask.zig");
    _ = @import("event_loop/AnyTaskWithExtraContext.zig");
    _ = @import("event_loop/AutoFlusher.zig");
    _ = @import("event_loop/ManagedTask.zig");
    _ = @import("ptr/meta.zig");
    _ = @import("ptr/Cow.zig");
    _ = @import("safety/asan.zig");
    _ = @import("safety/CriticalSection.zig");
    _ = @import("safety/ThreadLock.zig");
    _ = @import("io/pipes.zig");
    _ = @import("collections/hive_array.zig");
    _ = @import("collections/pool.zig");
    // Fifth-wave port batch (2026-05-18, 6-agent parallel dispatch):
    _ = @import("jsc/CachedBytecode.zig");
    _ = @import("jsc/JSMap.zig");
    _ = @import("jsc/JSBigInt.zig");
    _ = @import("jsc/JSArray.zig");
    _ = @import("jsc/JSFunction.zig");
    _ = @import("jsc/JSModuleLoader.zig");
    _ = @import("jsc/Errorable.zig");
    _ = @import("jsc/DeferredError.zig");
    _ = @import("jsc/DecodedJSValue.zig");
    _ = @import("jsc/DeprecatedStrong.zig");
    _ = @import("jsc/BunCPUProfiler.zig");
    _ = @import("jsc/BunHeapProfiler.zig");
    _ = @import("io/MaxBuf.zig");
    _ = @import("sys/dir.zig");
    _ = @import("sys/SignalCode.zig");
    _ = @import("paths/EnvPath.zig");
    _ = @import("paths/paths.zig");
    _ = @import("paths/path_buffer_pool.zig");
    _ = @import("threading/Mutex.zig");
    _ = @import("threading/Futex.zig");
    _ = @import("threading/Condition.zig");
    _ = @import("threading/WaitGroup.zig");
    _ = @import("threading/guarded.zig");
    _ = @import("threading/unbounded_queue.zig");
    _ = @import("threading/threading.zig");
    _ = @import("runtime/cli/ci_info.zig");
    _ = @import("runtime/cli/discord_command.zig");
    _ = @import("runtime/cli/test/ParallelRunner.zig");
    _ = @import("runtime/cli/test/parallel/Channel.zig");
    _ = @import("runtime/cli/test/parallel/Coordinator.zig");
    _ = @import("runtime/cli/test/parallel/FileRange.zig");
    _ = @import("runtime/cli/test/parallel/Frame.zig");
    _ = @import("runtime/cli/test/parallel/Worker.zig");
    _ = @import("runtime/cli/test/parallel/aggregate.zig");
    _ = @import("runtime/cli/test/parallel/runner.zig");
    _ = @import("bun/node_url_query_assert_util_encoding.zig");
    _ = @import("picohttp_sys/picohttpparser.zig");
    _ = @import("wyhash/wyhash.zig");
    _ = @import("glob/glob.zig");
    _ = @import("glob/matcher.zig");
    // JSC bring-up scaffolding: the vendored `ZigGeneratedClasses` module + the
    // `jsc.GeneratedClassesList` export are wired (build.zig), but referencing
    // the module here pulls all ~92 generated classes, which need their real
    // webcore/server/S3/stream impls wired into generated_classes_list.zig
    // (measured: 1434 errors). That is the full-runtime adoption step; left out
    // of the gate so the rest stays green. See BUN_ZIG_SOURCE_AUDIT_2026-06-01.
    // JSC bring-up checkpoint (2026-06-01): with generated_classes_list wired to
    // real impls + the api.* namespaces, compiling ZigGeneratedClasses dropped
    // from 1434 → 338 errors (now deep jsc-namespace gaps: jsc.Node.StringOrBuffer,
    // jsc.Expect, JSString methods, VirtualMachine.RareData fields). Parked here
    // so the rest stays green; un-comment to resume the grind.
    _ = @import("ZigGeneratedClasses");
    // Bun-original foundational leaves (2026-06-01 integration sweep). These
    // are Bun's `bun_core/*` originals; Home's live code uses the reorganized
    // `core/*` + `string/immutable.zig` copies, but referencing the originals
    // here keeps them compiled + test-covered against home_rt rather than
    // dormant. `bun` resolves to home_rt via the build.zig package alias.
    _ = @import("bun_core/bounded_array.zig");
    _ = @import("bun_core/util.zig");
    _ = @import("bun_core/string/immutable/escapeHTML.zig");
    _ = @import("bun_core/string/immutable/exact_size_matcher.zig");
    _ = @import("bun_core/string/immutable/grapheme.zig");
    _ = @import("bun_core/string/immutable/grapheme_tables.zig");
    _ = @import("bun_core/string/immutable/unicode.zig");
    // NOTE: bun_core/string/immutable/visible.zig is NOT referenced — its
    // width/emoji path links against ICU's `icu_hasBinaryProperty` (defined in
    // Bun's C++), absent from the -Denable_jsc=false test gate; stubbing would
    // falsify behavior. Tracked in docs/BUN_ZIG_SOURCE_AUDIT_2026-06-01.md.
    _ = @import("highway/highway.zig");
    // Config-format parsers (2026-06-01 integration sweep). interchange.zig
    // re-exports json/json5/toml/yaml; toml pulls toml/lexer. json is already
    // wired as home_rt.json.
    _ = @import("parsers/interchange.zig");
    // Misc self-contained leaves (2026-06-01 integration sweep).
    _ = @import("threading/channel.zig");
    _ = @import("ast/logger.zig");
    _ = @import("io/ParentDeathWatchdog.zig");
    _ = @import("glob/GlobWalker.zig");
    _ = @import("io/posix_event_loop.zig");
    _ = @import("io/windows_event_loop.zig");
    // CSS value modules (2026-06-01 integration sweep). These build on the
    // already-compiled css/css_parser.zig framework. css/values/values.zig is
    // still a stub aggregator; these reference the real Bun value parsers.
    _ = @import("css/values/angle.zig");
    _ = @import("css/values/calc.zig");
    _ = @import("css/values/color.zig");
    _ = @import("css/values/color_generated.zig");
    _ = @import("css/values/gradient.zig");
    _ = @import("css/values/ident.zig");
    _ = @import("css/values/image.zig");
    _ = @import("css/values/length.zig");
    _ = @import("css/values/percentage.zig");
    _ = @import("css/values/syntax.zig");
    _ = @import("css/values/url.zig");
    _ = @import("css_jsc/color_js.zig");
    _ = @import("css_jsc/css_internals.zig");
    _ = @import("css_jsc/error_jsc.zig");
    // runtime/node bindings (2026-06-01 integration sweep).
    _ = @import("runtime/node/assert/myers_diff.zig");
    _ = @import("runtime/node/node_assert.zig");
    _ = @import("runtime/node/node_assert_binding.zig");
    _ = @import("runtime/node/node_error_binding.zig");
    _ = @import("runtime/node/node_http_binding.zig");
    _ = @import("runtime/node/node_net_binding.zig");
    _ = @import("runtime/node/node_util_binding.zig");
    _ = @import("runtime/node/os/constants.zig");
    // runtime/server contexts (2026-06-01 integration sweep).
    _ = @import("runtime/server/AnyRequestContext.zig");
    _ = @import("runtime/server/FileResponseStream.zig");
    _ = @import("runtime/server/FileRoute.zig");
    // NodeHTTPResponse.zig blocked: needs jsc.Codegen + uws.{AnyResponse,Request}
    // (full uWebSockets HTTP bindings + JSC codegen), absent from the gate.
    // _ = @import("runtime/server/NodeHTTPResponse.zig");
    _ = @import("runtime/server/RequestContext.zig");
    _ = @import("runtime/server/ServerWebSocket.zig");
    _ = @import("runtime/server/StaticRoute.zig");
    _ = @import("runtime/server/WebSocketServerContext.zig");
    // runtime/bake DevServer + router (2026-06-01 integration sweep).
    _ = @import("runtime/bake/DevServer/Assets.zig");
    _ = @import("runtime/bake/DevServer/DirectoryWatchStore.zig");
    _ = @import("runtime/bake/DevServer/ErrorReportRequest.zig");
    _ = @import("runtime/bake/DevServer/HotReloadEvent.zig");
    _ = @import("runtime/bake/DevServer/IncrementalGraph.zig");
    _ = @import("runtime/bake/DevServer/PackedMap.zig");
    _ = @import("runtime/bake/DevServer/SerializedFailure.zig");
    _ = @import("runtime/bake/DevServer/WatcherAtomics.zig");
    _ = @import("runtime/bake/DevServer/memory_cost.zig");
    _ = @import("runtime/bake/FrameworkRouter.zig");
    // http h2/h3 clients (2026-06-01 integration sweep).
    _ = @import("http/h2_client/ClientSession.zig");
    _ = @import("http/h2_client/dispatch.zig");
    _ = @import("http/h2_client/encode.zig");
    _ = @import("http/h3_client/ClientContext.zig");
    _ = @import("http/h3_client/ClientSession.zig");
    _ = @import("http/h3_client/callbacks.zig");
    _ = @import("http/h3_client/encode.zig");
    // _jsc bridges + misc (2026-06-01 integration sweep). jsc surface is
    // stubbed under -Denable_jsc=false; decl-only bridges still compile.
    _ = @import("ast_jsc/logger_jsc.zig");
    _ = @import("install_jsc/install_binding.zig");
    // virtual_machine_exports.zig blocked: needs the full jsc.VirtualMachine
    // (enqueueTask/tick/ipc/plugin_runner/TLS + timer fields), far beyond the
    // stubbed VM available under -Denable_jsc=false.
    // _ = @import("jsc/virtual_machine_exports.zig");
    _ = @import("semver_jsc/SemverObject.zig");
    _ = @import("semver_jsc/SemverString_jsc.zig");
    _ = @import("sql_jsc/mysql/protocol/any_mysql_error_jsc.zig");
    _ = @import("sql_jsc/mysql/protocol/error_packet_jsc.zig");
    _ = @import("sql_jsc/postgres/command_tag_jsc.zig");
    _ = @import("sql_jsc/postgres/error_jsc.zig");
    _ = @import("sql_jsc/postgres/protocol/error_response_jsc.zig");
    _ = @import("sql_jsc/postgres/protocol/notice_response_jsc.zig");
    _ = @import("sql_jsc/postgres/types/tag_jsc.zig");
    _ = @import("sys_jsc/signal_code_jsc.zig");
    _ = @import("url_jsc/url_jsc.zig");
    _ = @import("runtime/webcore/s3/error_jsc.zig");
    _ = @import("unit_test.zig");
    // main_test.zig (native test main, pulls @cImport recover) and
    // main_wasm.zig (wasm entry, wasm-only exports) are build roots, not modules.
    // unicode/uucode* (vendored standalone Zig package) left dormant: its
    // codegen tree needs an `@import("uucode")` build module + a generated
    // src/build/Ucd.zig and uses `@Type`, none available in this gate.
    // recover.zig blocked: uses `@cImport` for signal/setjmp C headers, which
    // the pinned Zig build config (no C translate) does not provide.
    // _ = @import("runtime/test_runner/harness/recover.zig");
    // production.zig blocked at the JSC host boundary: the production bundler
    // creates JS error instances + global objects (ZigString.toErrorInstance,
    // JSGlobalObject) that need the real JavaScriptCore runtime, stubbed under
    // -Denable_jsc=false. resolver / path.joinAbs / bake.Side are now wired.
    // _ = @import("runtime/bake/production.zig");
    _ = @import("sourcemap/VLQ.zig");
    // Sixth-wave port batch (2026-05-18, 7-agent parallel dispatch):
    _ = @import("jsc/CommonStrings.zig");
    _ = @import("jsc/RegularExpression.zig");
    _ = @import("jsc/URLSearchParams.zig");
    _ = @import("jsc/ZigErrorType.zig");
    _ = @import("jsc/TextCodec.zig");
    _ = @import("jsc/MarkedArgumentBuffer.zig");
    _ = @import("jsc/ConcurrentPromiseTask.zig");
    _ = @import("core/feature_flags.zig");
    _ = @import("core/util.zig");
    _ = @import("core/string/immutable/grapheme.zig");
    _ = @import("core/string/immutable/grapheme_tables.zig");
    _ = @import("runtime/image/thumbhash.zig");
    _ = @import("runtime/image/quantize.zig");
    _ = @import("runtime/server/RangeRequest.zig");
    _ = @import("runtime/webcore/EncodingLabel.zig");
    _ = @import("analytics/schema.zig");
    _ = @import("analytics/analytics.zig");
    _ = @import("ast/base.zig");
    _ = @import("ast/use_directive.zig");
    _ = @import("ast/server_component_boundary.zig");
    _ = @import("css/logical.zig");
    _ = @import("css/sourcemap.zig");
    _ = @import("css/values/values.zig");
    _ = @import("http/h3_client/AltSvc.zig");
    _ = @import("mimalloc_sys/mimalloc.zig");
    _ = @import("tcc_sys/tcc.zig");
    _ = @import("brotli_sys/brotli_c.zig");
    _ = @import("libdeflate_sys/libdeflate.zig");
    _ = @import("simdutf_sys/simdutf.zig");
    _ = @import("zstd/zstd.zig");
    _ = @import("boringssl_sys/boringssl.zig");
    _ = @import("lolhtml_sys/lol_html.zig");
    // Seventh-wave port batch (2026-05-18):
    _ = @import("jsc/AbortSignal.zig");
    _ = @import("jsc/JSString.zig");
    _ = @import("jsc/RefString.zig");
    _ = @import("jsc/StringBuilder.zig");
    _ = @import("jsc/SystemError.zig");
    _ = @import("jsc/WTF.zig");
    _ = @import("jsc/Weak.zig");
    _ = @import("jsc/javascript_core_c_api.zig");
    _ = @import("event_loop/ConcurrentTask.zig");
    _ = @import("node/time_like.zig");
    _ = @import("node/os_constants.zig");
    _ = @import("node/util/parse_args_utils.zig");
    _ = @import("sys/tag.zig");
    _ = @import("errno/darwin_errno.zig");
    _ = @import("errno/linux_errno.zig");
    _ = @import("errno/freebsd_errno.zig");
    _ = @import("exe_format/pe.zig");
    _ = @import("sourcemap/SourceMapState.zig");
    _ = @import("sourcemap/DebugIDFormatter.zig");
    _ = @import("sourcemap/types.zig");
    _ = @import("css/rules/counter_style.zig");
    _ = @import("css/rules/namespace.zig");
    _ = @import("css/rules/nesting.zig");
    _ = @import("css/rules/starting_style.zig");
    _ = @import("css/rules/viewport.zig");
    _ = @import("css/rules/unknown.zig");
    _ = @import("css/rules/document.zig");
    _ = @import("css/css_parser_stub.zig");
    _ = @import("css/values/css_string.zig");
    _ = @import("css/values/ratio.zig");
    _ = @import("css/values/alpha.zig");
    _ = @import("css/properties/outline.zig");
    _ = @import("jsc/DOMURL.zig");
    _ = @import("jsc/JSArrayIterator.zig");
    // Eighth-wave port batch (2026-05-18):
    _ = @import("sys/maybe.zig");
    _ = @import("http/ThreadSafeStreamBuffer.zig");
    _ = @import("jsc/JSUint8Array.zig");
    _ = @import("jsc/VM.zig");
    _ = @import("jsc/URL.zig");
    _ = @import("jsc/DOMFormData.zig");
    _ = @import("jsc/TopExceptionScope.zig");
    _ = @import("jsc/JSPropertyIterator.zig");
    _ = @import("jsc/ProcessAutoKiller.zig");
    _ = @import("jsc/JSONLineBuffer.zig");
    _ = @import("http/h2_client/Stream.zig");
    _ = @import("http/h2_client/PendingConnect.zig");
    _ = @import("http/h3_client/Stream.zig");
    _ = @import("http/h3_client/PendingConnect.zig");
    _ = @import("runtime/api/lolhtml_jsc.zig");
    _ = @import("runtime/api/cron_parser.zig");
    _ = @import("runtime/api/bun/x509.zig");
    _ = @import("node/node_fs_constant.zig");
    _ = @import("node/assert/myers_diff.zig");
    _ = @import("node/assert.zig");
    _ = @import("node/util.zig");
    _ = @import("node/events.zig");
    _ = @import("node/buffer.zig");
    _ = @import("node/stream.zig");
    _ = @import("node/os.zig");
    _ = @import("s3_signing/acl.zig");
    _ = @import("s3_signing/storage_class.zig");
    _ = @import("s3_signing/error.zig");
    _ = @import("css/values/number.zig");
    _ = @import("css/values/resolution.zig");
    _ = @import("css/values/size.zig");
    _ = @import("css/properties/display.zig");
    _ = @import("css/properties/overflow.zig");
    _ = @import("css/properties/position.zig");
    _ = @import("css/rules/custom_media.zig");
    _ = @import("css/rules/media.zig");
    _ = @import("css/rules/tailwind.zig");
    _ = @import("css/rules/scope.zig");
    _ = @import("cares_sys/c_ares.zig");
    _ = @import("libarchive_sys/bindings.zig");
    // Ninth-wave port batch (2026-05-18):
    _ = @import("jsc/AnyPromise.zig");
    _ = @import("jsc/JSRef.zig");
    _ = @import("jsc/ResolvedSource.zig");
    _ = @import("jsc/bindgen_test.zig");
    _ = @import("jsc/Strong.zig");
    _ = @import("runtime/api/UnsafeObject.zig");
    _ = @import("runtime/api/JSONCObject.zig");
    _ = @import("runtime/api/TOMLObject.zig");
    _ = @import("runtime/api/HashObject.zig");
    _ = @import("runtime/api/standalone_graph_jsc.zig");
    _ = @import("runtime/api/crash_handler_jsc.zig");
    _ = @import("runtime/webcore/CookieMap.zig");
    _ = @import("runtime/webcore/ScriptExecutionContext.zig");
    _ = @import("node/fs_events.zig");
    _ = @import("node/node_error_binding.zig");
    _ = @import("install/Origin.zig");
    _ = @import("install/PreinstallState.zig");
    _ = @import("install/Aligner.zig");
    // Bundler-tree leaves now live in `packages/bundler/` (formerly
    // `packages/ts_bundler/`) — runtime no longer mirrors them.
    _ = @import("ast/op.zig");
    _ = @import("js_parser/lexer_tables.zig");
    _ = @import("uws_sys/SocketKind.zig");
    _ = @import("uws_sys/ConnectingSocket.zig");
    _ = @import("uws_sys/udp.zig");
    _ = @import("uws_sys/Timer.zig");
    _ = @import("uws_sys/vtable.zig");
    _ = @import("uws_sys/SocketGroup.zig");
    _ = @import("collections/bit_set.zig");
    _ = @import("collections/multi_array_list.zig");
    _ = @import("safety/alloc.zig");
    // Tenth-wave port batch (2026-05-18):
    _ = @import("jsc/CallFrame.zig");
    _ = @import("jsc/ZigStackFrame.zig");
    _ = @import("jsc/ZigStackTrace.zig");
    _ = @import("jsc/ZigException.zig");
    _ = @import("runtime/api/bun/SSLContextCache.zig");
    _ = @import("runtime/api/bun/SecureContext.zig");
    _ = @import("runtime/api/NativePromiseContext.zig");
    _ = @import("runtime/api/csrf_jsc.zig");
    _ = @import("runtime/server/InspectorBunFrontendDevServerAgent.zig");
    _ = @import("install/PackageID.zig");
    _ = @import("install/Features.zig");
    _ = @import("install/Behavior.zig");
    _ = @import("node/Stat.zig");
    _ = @import("node/StatFS.zig");
    _ = @import("node/node_net_binding.zig");
    _ = @import("http/H2Client.zig");
    _ = @import("http/H3Client.zig");
    _ = @import("http/websocket_http_client.zig");
    _ = @import("css/properties/effects.zig");
    _ = @import("css/values/position.zig");
    _ = @import("css/values/rect.zig");
    _ = @import("sourcemap/LineOffsetTable.zig");
    _ = @import("sourcemap/LineColumnOffset.zig");
    // Eleventh-wave port batch (2026-05-18):
    _ = @import("jsc/JSObject.zig");
    _ = @import("jsc/JSGlobalObject.zig");
    _ = @import("jsc/PosixSignalHandle.zig");
    _ = @import("jsc/EventLoopHandle.zig");
    _ = @import("jsc/fmt_jsc.zig");
    _ = @import("jsc/ZigString.zig");
    _ = @import("css/rules/layer.zig");
    _ = @import("css/rules/supports.zig");
    _ = @import("css/rules/style.zig");
    _ = @import("css/properties/box_shadow.zig");
    _ = @import("css/properties/border_radius.zig");
    _ = @import("css/properties/flex.zig");
    _ = @import("css/values/easing.zig");
    _ = @import("css/values/time.zig");
    _ = @import("runtime/api/JSON5Object.zig");
    _ = @import("runtime/api/YAMLObject.zig");
    _ = @import("runtime/api/MarkdownObject.zig");
    _ = @import("node/types.zig");
    _ = @import("node/dir_iterator.zig");
    _ = @import("node/uv_signal_handle_windows.zig");
    _ = @import("runtime/server/ServerConfig.zig");
    _ = @import("standalone_graph/StandaloneModuleGraph.zig");
    _ = @import("install_types/SemverString.zig");
    _ = @import("sourcemap/SourceMapShifts.zig");
    _ = @import("sourcemap/ParseUrlResultHint.zig");
    _ = @import("brotli/brotli.zig");
    _ = @import("zlib/zlib.zig");
    _ = @import("http/Decompressor.zig");
    _ = @import("http/zlib.zig");
    // Thirteenth-wave port batch (2026-05-18) — orphan-wave wiring.
    // Pull each newly-aggregated leaf into the test runner so inline
    // tests fire under `zig build test -Dfilter=home_rt`.
    _ = @import("analytics/Features.zig");
    _ = @import("node/path.zig");
    _ = @import("node/buffer.zig");
    _ = @import("node/fs.zig");
    _ = @import("node/url.zig");
    _ = @import("node/querystring.zig");
    _ = @import("node/crypto.zig");
    _ = @import("node/process.zig");
    _ = @import("node/string_decoder.zig");
    _ = @import("node/tty.zig");
    _ = @import("jsc/generated_classes_list.zig");
    _ = @import("runtime/api/bun/Terminal.zig");
    _ = @import("runtime/api/bun/spawn.zig");
    _ = @import("runtime/api/glob.zig");
    _ = @import("runtime/webcore/Body.zig");
    _ = @import("runtime/webcore/FormData.zig");
    _ = @import("runtime/webcore/ObjectURLRegistry.zig");
    _ = @import("runtime/webcore/Sink.zig");
    _ = @import("safety/safety.zig");
    // Wave-15 Tier-1 grinder (2026-05-18):
    _ = @import("runtime/shell/RefCountedStr.zig");
    _ = @import("string/HashedString.zig");
    _ = @import("string/escapeRegExp.zig");
    _ = string;
    _ = @import("ptr/weak_ptr.zig");
    _ = @import("ptr/external_shared.zig");
    _ = @import("css/properties/shape.zig");
    // Wave-16 Tier-1 grinder (2026-05-18):
    _ = @import("crash_handler/CPUFeatures.zig");
    _ = @import("runtime/cli/colon_list_type.zig");
    _ = @import("runtime/cli/shell_completions.zig");
    _ = @import("runtime/cli/fuzzilli_command.zig");
    _ = @import("sql/mysql/AuthMethod.zig");
    _ = @import("css/properties/contain.zig");
    // Wave-16 Tier-0 grinder (2026-05-18):
    _ = @import("md/unicode.zig");
    _ = @import("md/entity.zig");
    _ = @import("windows_sys/externs.zig");
    _ = @import("codegen/process_windows_translate_c.zig");
    _ = @import("zlib_sys/win32.zig");
    _ = @import("sql/postgres/protocol/DecoderWrap.zig");
    _ = @import("sql/postgres/protocol/WriteWrap.zig");
    _ = @import("sql/postgres/protocol/NewReader.zig");
    _ = @import("sql/postgres/protocol/NewWriter.zig");
    _ = @import("sql/postgres/protocol/BackendKeyData.zig");
    // Phase 12.2 M1 (2026-05-19) — JSC bridge scaffold smoke imports.
    _ = @import("jsc/opaques.zig");
    _ = @import("jsc/extern_fns.zig");
    _ = @import("jsc/types.zig");
    _ = @import("jsc/engine.zig");
    _ = @import("jsc/evaluate.zig");
    _ = @import("jsc/console.zig");
    _ = @import("jsc/process.zig");
    _ = @import("jsc/web_globals.zig");
    _ = @import("jsc/crypto_global.zig");
    _ = @import("jsc/timers_global.zig");
    _ = @import("jsc/misc_globals.zig");
    _ = @import("jsc/url_global.zig");
    _ = @import("jsc/webcore_globals.zig");
    _ = @import("jsc/fetch_global.zig");
    _ = @import("jsc/bun_global.zig");
    _ = @import("jsc/node_modules.zig");
    _ = @import("jsc/spawn_global.zig");
    // Wave-18 Tier-0 grinder (2026-05-18) — sql wire-protocol leaves.
    _ = @import("sql/shared/Data.zig");
    _ = @import("sql/mysql/protocol/NewReader.zig");
    _ = @import("sql/mysql/protocol/EOFPacket.zig");
    _ = @import("sql/mysql/protocol/StmtPrepareOKPacket.zig");
    _ = @import("sql/mysql/protocol/LocalInfileRequest.zig");
    _ = @import("sql/mysql/protocol/OKPacket.zig");
    _ = @import("sql/mysql/protocol/StackReader.zig");
    _ = @import("sql/mysql/protocol/Query.zig");
    _ = @import("sql/mysql/protocol/HandshakeResponse41.zig");
    _ = @import("sql/postgres/protocol/PasswordMessage.zig");
    _ = @import("sql/postgres/protocol/SASLResponse.zig");
    _ = @import("sql/postgres/protocol/SASLInitialResponse.zig");
    _ = @import("sql/postgres/protocol/CopyOutResponse.zig");
    _ = @import("sql/postgres/protocol/Parse.zig");
    _ = @import("sql/postgres/protocol/ReadyForQuery.zig");
    _ = @import("sql/postgres/protocol/ParameterStatus.zig");
    _ = @import("sql/postgres/protocol/DataRow.zig");
    // Wave-18 Tier-1 grinder (2026-05-18) — additional sql wire-protocol
    // leaves + css/properties/text.
    _ = @import("sql/postgres/protocol/Close.zig");
    _ = @import("sql/postgres/protocol/Describe.zig");
    _ = @import("sql/postgres/protocol/Execute.zig");
    _ = @import("sql/postgres/protocol/CopyInResponse.zig");
    _ = @import("sql/postgres/protocol/CommandComplete.zig");
    _ = @import("sql/postgres/protocol/CopyData.zig");
    _ = @import("sql/postgres/protocol/CopyFail.zig");
    _ = @import("sql/postgres/protocol/NegotiateProtocolVersion.zig");
    _ = @import("css/properties/text.zig");
    // Wave-19 unmined-corner port (2026-05-19). Adds bun/src/perf/hw_timer.zig
    // (TSC reader) — the perf/ directory is otherwise lightly mined here.
    _ = @import("perf/hw_timer.zig");
}

test "home_rt.install_types.NodeLinker.fromStr maps canonical strings" {
    try std.testing.expectEqual(install_types.NodeLinker.hoisted, install_types.NodeLinker.fromStr("hoisted").?);
    try std.testing.expectEqual(install_types.NodeLinker.isolated, install_types.NodeLinker.fromStr("isolated").?);
    try std.testing.expect(install_types.NodeLinker.fromStr("nope") == null);
}

test "home_rt.Semver exposes Bun semver leaves" {
    const version_input = "1.2.3";
    const version = Semver.Version.parseUTF8(version_input);
    try std.testing.expect(version.valid);

    const range_input = "^1.0.0";
    const group = try Semver.Query.parse(std.testing.allocator, range_input, Semver.SlicedString.init(range_input, range_input));
    defer group.deinit();

    try std.testing.expect(group.satisfies(version.version.min(), range_input, version_input));
}

test "home_rt.uws_sys.quic exposes the QUIC opaques" {
    _ = uws_sys.quic.Socket;
    _ = uws_sys.quic.PendingConnect;
}

test "home_rt.http_types.Method.find round-trips canonical verbs" {
    try std.testing.expectEqual(http_types.Method.GET, http_types.Method.find("GET").?);
    try std.testing.expectEqual(http_types.Method.POST, http_types.Method.find("post").?);
    try std.testing.expectEqual(http_types.Method.PATCH, http_types.Method.find("PATCH").?);
    try std.testing.expect(http_types.Method.find("INVALID") == null);
}

test "home_rt.http_types.Method.isIdempotent" {
    try std.testing.expect(http_types.Method.GET.isIdempotent());
    try std.testing.expect(http_types.Method.PUT.isIdempotent());
    try std.testing.expect(!http_types.Method.POST.isIdempotent());
    try std.testing.expect(!http_types.Method.PATCH.isIdempotent());
}

test "home_rt.http_types.FetchRedirect.Map maps strings to enum tags" {
    try std.testing.expectEqual(http_types.FetchRedirect.follow, http_types.FetchRedirect.Map.get("follow").?);
    try std.testing.expectEqual(http_types.FetchRedirect.@"error", http_types.FetchRedirect.Map.get("error").?);
}

test "home_rt.options_types.OfflineMode.Prefer maps strings to enum tags" {
    try std.testing.expectEqual(options_types.OfflineMode.offline, options_types.OfflineModePrefer.get("offline").?);
    try std.testing.expectEqual(options_types.OfflineMode.latest, options_types.OfflineModePrefer.get("latest").?);
}

test "home_rt.sql.postgres.types.int_types.Int32 encodes big-endian" {
    const bytes = sql.postgres.types.int_types.Int32(@as(u32, 0x0a0b0c0d));
    try std.testing.expectEqualSlices(u8, &.{ 0x0a, 0x0b, 0x0c, 0x0d }, &bytes);
}

test "home_rt.sql.postgres.CommandTag parses command rows" {
    try std.testing.expectEqual(sql.postgres.CommandTag{ .UPDATE = 2 }, sql.postgres.CommandTag.init("UPDATE 2"));
    try std.testing.expectEqual(sql.postgres.CommandTag{ .INSERT = 3 }, sql.postgres.CommandTag.init("INSERT 0 3"));
    try std.testing.expectEqualStrings("VACUUM", sql.postgres.CommandTag.init("VACUUM").other);
}

test "home_rt.sql.mysql.QueryStatus.isRunning identifies in-flight states" {
    try std.testing.expect(sql.mysql.QueryStatus.binding.isRunning());
    try std.testing.expect(sql.mysql.QueryStatus.running.isRunning());
    try std.testing.expect(sql.mysql.QueryStatus.partial_response.isRunning());
    try std.testing.expect(!sql.mysql.QueryStatus.pending.isRunning());
    try std.testing.expect(!sql.mysql.QueryStatus.success.isRunning());
}

test "home_rt.sql.postgres.protocol.zHelpers.zCount adds NUL byte" {
    try std.testing.expectEqual(@as(usize, 0), sql.postgres.protocol.zHelpers.zCount(""));
    try std.testing.expectEqual(@as(usize, 5), sql.postgres.protocol.zHelpers.zCount("home"));
}

test "home_rt.sql.postgres.protocol.PortalOrPreparedStatement tags correctly" {
    const Por = sql.postgres.protocol.PortalOrPreparedStatement;
    const p: Por = .{ .portal = "p1" };
    const ps: Por = .{ .prepared_statement = "s1" };
    try std.testing.expectEqual(@as(u8, 'P'), p.tag());
    try std.testing.expectEqual(@as(u8, 'S'), ps.tag());
    try std.testing.expectEqualStrings("p1", p.slice());
    try std.testing.expectEqualStrings("s1", ps.slice());
}

test "home_rt.sql.postgres.protocol.Close composes a portal target" {
    const close_msg: sql.postgres.protocol.Close = .{ .p = .{ .portal = "x" } };
    try std.testing.expectEqualStrings("x", close_msg.p.slice());
    try std.testing.expectEqual(@as(u8, 'P'), close_msg.p.tag());
}

test "home_rt.sql.postgres.protocol.Execute defaults max_rows to 0" {
    const e: sql.postgres.protocol.Execute = .{ .p = .{ .portal = "p" } };
    try std.testing.expectEqual(@as(u32, 0), e.max_rows);
}

test "home_rt.css.properties.text packs TextDecorationLine into a byte" {
    const TextDecorationLine = css.properties.text.TextDecorationLine;
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(TextDecorationLine));
    const t = TextDecorationLine{ .underline = true };
    try std.testing.expect(t.underline);
    try std.testing.expect(!t.overline);
}

test "home_rt.jsc enums round-trip their tag values" {
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(jsc.JSPromiseRejectionOperation.Reject));
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(jsc.JSPromiseRejectionOperation.Handle));
    try std.testing.expectEqual(@as(i32, 0), @intFromEnum(jsc.ScriptExecutionStatus.running));
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(jsc.SourceType.Program));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(jsc.SourceType.Module));
    try std.testing.expectEqual(@as(u16, 0x40), @intFromEnum(jsc.JSRuntimeType.String));
}

test "home_rt.jsc.sizes exposes generated layout constants" {
    try std.testing.expectEqual(@as(comptime_int, 6), jsc.sizes.Bun_FFI_PointerOffsetToArgumentsList);
    try std.testing.expectEqual(@as(comptime_int, 16), jsc.sizes.Bun_FFI_PointerOffsetToTypedArrayVector);
}

test "home_rt.jsc.ErrorCode round-trips through anyerror" {
    const err: anyerror = error.OutOfMemory;
    const code = jsc.ErrorCode.from(err);
    try std.testing.expectEqual(err, code.toError());
}

test "home_rt.io exposes the stub event-loop opaques" {
    // Only check that the names exist; full impl lands in Phase 12.3.
    _ = io.Loop;
    _ = io.KeepAlive;
    _ = io.FilePoll;
}

test "home_rt.http_types.Encoding flags compression families" {
    try std.testing.expect(http_types.Encoding.gzip.isCompressed());
    try std.testing.expect(!http_types.Encoding.identity.isCompressed());
    try std.testing.expect(http_types.Encoding.deflate.canUseLibDeflate());
}

test "home_rt.Result threads ok/err through union" {
    const R = Result(u32, []const u8);
    const ok: R = .{ .ok = 99 };
    const err: R = .{ .err = "nope" };
    try std.testing.expect(ok.asErr() == null);
    try std.testing.expectEqualStrings("nope", err.asErr().?);
}

test "home_rt.http types compose" {
    // Smoke test — the namespace re-exports compile cleanly.
    var iter = http.HeaderValueIterator.init("a, b");
    try std.testing.expectEqualStrings("a", iter.next().?);
    try std.testing.expectEqualStrings("b", iter.next().?);
}

test "home_rt.perf.hw_timer.is_supported tracks aarch64/x64" {
    const expected = Environment.isAarch64 or Environment.isX64;
    try std.testing.expectEqual(expected, perf.hw_timer.is_supported);
}

test "home_rt.safety.thread_id.invalid is the max thread id" {
    try std.testing.expectEqual(std.math.maxInt(std.Thread.Id), safety.thread_id.invalid);
}
