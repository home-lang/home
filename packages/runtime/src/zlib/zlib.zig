// Copied from bun/src/zlib/zlib.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// ArrayList-streaming zlib readers + compressors over the vendored
// zlib-ng (zlib-compat) C ABI surface. Mirrors upstream's `BunZlib`
// module modulo:
//
//   1. `@import("bun")` collapses to `@import("home")`. Upstream pulled
//      `z_stream` / `z_streamp` / `DataType` / `FlushValue` / `ReturnCode`
//      from a build-graph package named `zlib-internal`. We inline the
//      POSIX subset of those decls directly in the `internal` block below
//      so cross-directory `@import` constraints in Zig 0.17 module mode
//      don't force us to touch home_rt.zig.
//   2. The optional `bun.heap_breakdown` zone fallback is dropped (no
//      heap-breakdown substrate in home_rt yet); allocations go through
//      mimalloc directly. Re-attaches when `home_rt.heap_breakdown` lands.
//   3. The standalone single-frame `NewZlibReader(Writer, buffer_size)`
//      helper is omitted — nothing in home_rt calls it yet, and porting
//      it would pull in `std.Io.GenericWriter` plumbing we don't need
//      until the streaming-decode path lands. Re-attaches the moment
//      something in home_rt asks for it.
//   4. `@link "deps/zlib/libz.a"` directive is dropped; the link
//      contract is established by the top-level `build.zig`.

// @link "deps/zlib/libz.a"

// ---- inlined `zlib-internal` (POSIX layout) ----------------------------
// Upstream resolves `@import("zlib-internal")` through a build-graph
// package that points at `src/zlib_sys/posix.zig` on POSIX and
// `src/zlib_sys/win32.zig` on Windows. We inline the POSIX subset here —
// `c_ulong` already widens to 8 bytes on LP64 unix and 4 bytes on Windows
// LLP64, so the same field types match libz/zlib-ng on every host.
const internal = struct {
    pub const i_struct_internal_state = extern struct {
        dummy: c_int,
    };

    pub const i_z_alloc_fn = ?*const fn (*anyopaque, c_uint, c_uint) callconv(.c) ?*anyopaque;
    pub const i_z_free_fn = ?*const fn (*anyopaque, *anyopaque) callconv(.c) void;

    pub const i_DataType = enum(c_int) {
        Binary = 0,
        Text = 1,
        Unknown = 2,
    };

    pub const i_ReturnCode = enum(c_int) {
        Ok = 0,
        StreamEnd = 1,
        NeedDict = 2,
        ErrNo = -1,
        StreamError = -2,
        DataError = -3,
        MemError = -4,
        BufError = -5,
        VersionError = -6,
    };

    pub const i_FlushValue = enum(c_int) {
        NoFlush = 0,
        PartialFlush = 1,
        SyncFlush = 2,
        FullFlush = 3,
        Finish = 4,
        Block = 5,
        Trees = 6,
    };

    pub const i_zStream_struct = extern struct {
        next_in: [*c]const u8,
        avail_in: c_uint,
        total_in: c_ulong,

        next_out: [*c]u8,
        avail_out: c_uint,
        total_out: c_ulong,

        err_msg: ?[*:0]const u8,
        internal_state: ?*i_struct_internal_state,

        alloc_func: i_z_alloc_fn,
        free_func: i_z_free_fn,
        user_data: *anyopaque,

        data_type: i_DataType,

        adler: c_ulong,
        reserved: c_ulong,
    };

    pub const i_z_stream = i_zStream_struct;
    pub const i_z_streamp = *i_z_stream;
};

pub const MIN_WBITS = 8;
pub const MAX_WBITS = 15;

pub extern fn zlibVersion() [*:0]const u8;

pub extern fn compress(dest: [*]Bytef, destLen: *uLongf, source: [*]const Bytef, sourceLen: uLong) c_int;
pub extern fn compress2(dest: [*]Bytef, destLen: *uLongf, source: [*]const Bytef, sourceLen: uLong, level: c_int) c_int;
pub extern fn compressBound(sourceLen: uLong) uLong;
pub extern fn uncompress(dest: [*]Bytef, destLen: *uLongf, source: [*]const Bytef, sourceLen: uLong) c_int;
pub const struct_gzFile_s = extern struct {
    have: c_uint,
    next: [*c]u8,
    pos: c_long,
};
pub const gzFile = [*c]struct_gzFile_s;

// https://zlib.net/manual.html#Stream
const Byte = u8;
const uInt = u32;
// zlib-ng compat (and stock zlib) use `unsigned long` — 4 bytes on Windows
// LLP64, 8 on LP64 unix. cloudflare/zlib hard-coded uint64_t, which is why
// this was u64. Must match the C side or compress()/compressBound()/adler32()
// have an ABI mismatch on Windows.
pub const uLong = c_ulong;
const Bytef = Byte;
pub const uLongf = uLong;
const voidpf = ?*anyopaque;

pub const z_stream = internal.i_z_stream;
pub const z_streamp = internal.i_z_streamp;

pub const FlushValue = internal.i_FlushValue;
pub const ReturnCode = internal.i_ReturnCode;

pub extern fn inflateInit_(strm: z_streamp, version: [*c]const u8, stream_size: c_int) ReturnCode;
pub extern fn inflateInit2_(strm: z_streamp, window_size: c_int, version: [*c]const u8, stream_size: c_int) ReturnCode;

pub extern fn deflateSetDictionary(strm: z_streamp, dictionary: ?[*]const u8, length: c_uint) ReturnCode;
pub extern fn deflateParams(strm: z_streamp, level: c_int, strategy: c_int) ReturnCode;

pub extern fn inflate(stream: *zStream_struct, flush: FlushValue) ReturnCode;
pub extern fn inflateEnd(stream: *zStream_struct) ReturnCode;
pub extern fn inflateReset(stream: *zStream_struct) ReturnCode;

pub extern fn crc32(crc: uLong, buf: [*]const Bytef, len: uInt) uLong;

pub const ZlibError = error{
    OutOfMemory,
    InvalidArgument,
    ZlibError,
    ShortRead,
};

const ZlibAllocator = struct {
    pub fn alloc(_: *anyopaque, items: uInt, len: uInt) callconv(.c) *anyopaque {
        return mimalloc.mi_calloc(items, len) orelse @panic("zlib: mimalloc out of memory");
    }

    pub fn free(_: *anyopaque, data: *anyopaque) callconv(.c) void {
        mimalloc.mi_free(data);
    }
};

pub const ZlibReaderArrayList = struct {
    const ZlibReader = ZlibReaderArrayList;

    pub const State = enum {
        Uninitialized,
        Inflating,
        End,
        Error,
    };

    input: []const u8,
    list: std.ArrayListUnmanaged(u8),
    list_allocator: std.mem.Allocator,
    list_ptr: *std.ArrayListUnmanaged(u8),
    zlib: zStream_struct,
    allocator: std.mem.Allocator,
    state: State = State.Uninitialized,
    /// Decompression-bomb cap: fail once the output buffer exceeds this size.
    max_output_size: usize = std.math.maxInt(usize),

    pub fn deinit(this: *ZlibReader) void {
        var allocator = this.allocator;
        this.end();
        allocator.destroy(this);
    }

    pub fn end(this: *ZlibReader) void {
        // always free with `inflateEnd`
        if (this.state != State.End) {
            _ = inflateEnd(&this.zlib);
            this.state = State.End;
        }
    }

    pub fn init(
        input: []const u8,
        list: *std.ArrayListUnmanaged(u8),
        allocator: std.mem.Allocator,
    ) !*ZlibReader {
        const options: Options = .{
            .windowBits = 15 + 32,
        };

        return initWithOptions(input, list, allocator, options);
    }

    pub fn initWithOptions(input: []const u8, list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, options: Options) ZlibError!*ZlibReader {
        return initWithOptionsAndListAllocator(input, list, allocator, allocator, options);
    }

    pub fn initWithOptionsAndListAllocator(input: []const u8, list: *std.ArrayListUnmanaged(u8), list_allocator: std.mem.Allocator, allocator: std.mem.Allocator, options: Options) ZlibError!*ZlibReader {
        var zlib_reader = try allocator.create(ZlibReader);
        zlib_reader.* = ZlibReader{
            .input = input,
            .list = list.*,
            .list_allocator = list_allocator,
            .list_ptr = list,
            .allocator = allocator,
            .zlib = undefined,
        };

        zlib_reader.zlib = zStream_struct{
            .next_in = input.ptr,
            .avail_in = @truncate(input.len),
            .total_in = @truncate(input.len),

            .next_out = zlib_reader.list.items.ptr,
            .avail_out = @truncate(zlib_reader.list.items.len),
            .total_out = @truncate(zlib_reader.list.items.len),

            .err_msg = null,
            .alloc_func = ZlibAllocator.alloc,
            .free_func = ZlibAllocator.free,

            .internal_state = null,
            .user_data = zlib_reader,

            .data_type = DataType.Unknown,
            .adler = 0,
            .reserved = 0,
        };

        switch (inflateInit2_(&zlib_reader.zlib, options.windowBits, zlibVersion(), @sizeOf(zStream_struct))) {
            ReturnCode.Ok => return zlib_reader,
            ReturnCode.MemError => {
                zlib_reader.deinit();
                return error.OutOfMemory;
            },
            ReturnCode.StreamError => {
                zlib_reader.deinit();
                return error.InvalidArgument;
            },
            ReturnCode.VersionError => {
                zlib_reader.deinit();
                return error.InvalidArgument;
            },
            else => unreachable,
        }
    }

    pub fn errorMessage(this: *ZlibReader) ?[]const u8 {
        if (this.zlib.err_msg) |msg_ptr| {
            return std.mem.sliceTo(msg_ptr, 0);
        }

        return null;
    }

    pub fn readAll(this: *ZlibReader, is_done: bool) ZlibError!void {
        defer {
            if (this.list.items.len > this.zlib.total_out) {
                this.list.shrinkRetainingCapacity(this.zlib.total_out);
            } else if (this.zlib.total_out < this.list.capacity) {
                this.list.items.len = this.zlib.total_out;
            }
            this.list_ptr.* = this.list;
        }

        while (this.state == State.Uninitialized or this.state == State.Inflating) {
            if (this.zlib.avail_out == 0) {
                const initial = this.list.items.len;
                try this.list.ensureUnusedCapacity(this.list_allocator, 4096);
                this.list.expandToCapacity();
                if (this.list.items.len > this.max_output_size) {
                    this.state = State.Error;
                    return error.ZlibError;
                }
                this.zlib.next_out = @ptrCast(&this.list.items[initial]);
                this.zlib.avail_out = @truncate(this.list.items.len -| initial);
            }

            // Try to inflate even if avail_in is 0, as this could be a valid empty gzip stream
            const rc = inflate(&this.zlib, FlushValue.NoFlush);
            this.state = State.Inflating;

            switch (rc) {
                ReturnCode.StreamEnd => {
                    this.end();
                    return;
                },
                ReturnCode.MemError => {
                    this.state = State.Error;
                    return error.OutOfMemory;
                },
                ReturnCode.BufError => {
                    // BufError with avail_in == 0 means we need more input data
                    if (this.zlib.avail_in == 0) {
                        if (is_done) {
                            // Stream is truncated - we're at EOF but decoder needs more data
                            this.state = State.Error;
                            return error.ZlibError;
                        }
                        // Not at EOF - we can retry with more data
                        return error.ShortRead;
                    }
                    this.state = State.Error;
                    return error.ZlibError;
                },
                ReturnCode.StreamError,
                ReturnCode.DataError,
                ReturnCode.NeedDict,
                ReturnCode.VersionError,
                ReturnCode.ErrNo,
                => {
                    this.state = State.Error;
                    return error.ZlibError;
                },
                ReturnCode.Ok => {},
            }
        }
    }
};

pub const Options = struct {
    gzip: bool = false,
    level: c_int = 6,
    method: c_int = 8,
    windowBits: c_int = 15,
    memLevel: c_int = 8,
    strategy: c_int = 0,
};

pub extern fn deflateInit_(strm: z_streamp, level: c_int, version: [*:0]const u8, stream_size: c_int) ReturnCode;
pub extern fn deflate(strm: z_streamp, flush: FlushValue) ReturnCode;
pub extern fn deflateEnd(stream: z_streamp) ReturnCode;
pub extern fn deflateReset(stream: z_streamp) ReturnCode;
pub extern fn deflateBound(strm: z_streamp, sourceLen: uLong) uLong;
pub extern fn deflateInit2_(strm: z_streamp, level: c_int, method: c_int, windowBits: c_int, memLevel: c_int, strategy: c_int, version: [*c]const u8, stream_size: c_int) ReturnCode;
pub extern fn inflateSetDictionary(strm: z_streamp, dictionary: ?[*]const u8, length: c_uint) ReturnCode;

pub const NodeMode = enum(u8) {
    NONE = 0,
    DEFLATE = 1,
    INFLATE = 2,
    GZIP = 3,
    GUNZIP = 4,
    DEFLATERAW = 5,
    INFLATERAW = 6,
    UNZIP = 7,
    BROTLI_DECODE = 8,
    BROTLI_ENCODE = 9,
    ZSTD_COMPRESS = 10,
    ZSTD_DECOMPRESS = 11,
};

/// Not for streaming!
pub const ZlibCompressorArrayList = struct {
    const ZlibCompressor = ZlibCompressorArrayList;

    pub const State = enum {
        Uninitialized,
        Inflating,
        End,
        Error,
    };

    input: []const u8,
    list: std.ArrayListUnmanaged(u8),
    list_allocator: std.mem.Allocator,
    list_ptr: *std.ArrayListUnmanaged(u8),
    zlib: zStream_struct,
    allocator: std.mem.Allocator,
    state: State = State.Uninitialized,

    pub fn alloc(_: *anyopaque, items: uInt, len: uInt) callconv(.c) *anyopaque {
        return mimalloc.mi_malloc(items * len) orelse @panic("zlib: mimalloc out of memory");
    }

    pub fn free(_: *anyopaque, data: *anyopaque) callconv(.c) void {
        mimalloc.mi_free(data);
    }

    pub fn deinit(this: *ZlibCompressor) void {
        var allocator = this.allocator;
        this.end();
        allocator.destroy(this);
    }

    pub fn end(this: *ZlibCompressor) void {
        if (this.state != State.End) {
            _ = deflateEnd(&this.zlib);
            this.state = State.End;
        }
    }

    pub fn init(input: []const u8, list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, options: Options) ZlibError!*ZlibCompressor {
        return initWithListAllocator(input, list, allocator, allocator, options);
    }

    pub fn initWithListAllocator(input: []const u8, list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, list_allocator: std.mem.Allocator, options: Options) ZlibError!*ZlibCompressor {
        var zlib_reader = try allocator.create(ZlibCompressor);
        zlib_reader.* = ZlibCompressor{
            .input = input,
            .list = list.*,
            .list_ptr = list,
            .list_allocator = list_allocator,
            .allocator = allocator,
            .zlib = undefined,
        };

        zlib_reader.zlib = zStream_struct{
            .next_in = input.ptr,
            .avail_in = @truncate(input.len),
            .total_in = @truncate(input.len),

            .next_out = zlib_reader.list.items.ptr,
            .avail_out = @truncate(zlib_reader.list.items.len),
            .total_out = @truncate(zlib_reader.list.items.len),

            .err_msg = null,
            .alloc_func = ZlibCompressor.alloc,
            .free_func = ZlibCompressor.free,

            .internal_state = null,
            .user_data = zlib_reader,

            .data_type = DataType.Unknown,
            .adler = 0,
            .reserved = 0,
        };

        switch (deflateInit2_(
            &zlib_reader.zlib,
            options.level,
            options.method,
            if (!options.gzip) -options.windowBits else options.windowBits + 16,
            options.memLevel,
            options.strategy,
            zlibVersion(),
            @sizeOf(zStream_struct),
        )) {
            ReturnCode.Ok => {
                zlib_reader.list.ensureTotalCapacityPrecise(list_allocator, deflateBound(&zlib_reader.zlib, @intCast(input.len))) catch {
                    zlib_reader.deinit();
                    return error.OutOfMemory;
                };
                zlib_reader.list_ptr.* = zlib_reader.list;
                zlib_reader.zlib.avail_out = @truncate(zlib_reader.list.capacity);
                zlib_reader.zlib.next_out = zlib_reader.list.items.ptr;

                return zlib_reader;
            },
            ReturnCode.MemError => {
                zlib_reader.deinit();
                return error.OutOfMemory;
            },
            ReturnCode.StreamError => {
                zlib_reader.deinit();
                return error.InvalidArgument;
            },
            ReturnCode.VersionError => {
                zlib_reader.deinit();
                return error.InvalidArgument;
            },
            else => unreachable,
        }
    }

    pub fn errorMessage(this: *ZlibCompressor) ?[]const u8 {
        if (this.zlib.err_msg) |msg_ptr| {
            return std.mem.sliceTo(msg_ptr, 0);
        }

        return null;
    }

    pub fn readAll(this: *ZlibCompressor) ZlibError!void {
        defer {
            this.list.shrinkRetainingCapacity(this.zlib.total_out);
            this.list_ptr.* = this.list;
        }

        while (this.state == State.Uninitialized or this.state == State.Inflating) {
            if (this.zlib.avail_out == 0) {
                const initial = this.list.items.len;
                try this.list.ensureUnusedCapacity(this.list_allocator, 4096);
                this.list.expandToCapacity();
                this.zlib.next_out = @ptrCast(&this.list.items[initial]);
                this.zlib.avail_out = @truncate(this.list.items.len -| initial);
            }

            if (this.zlib.avail_out == 0) {
                return error.ShortRead;
            }

            const rc = deflate(&this.zlib, FlushValue.Finish);
            this.state = State.Inflating;

            switch (rc) {
                ReturnCode.StreamEnd => {
                    this.list.items.len = this.zlib.total_out;
                    this.end();

                    return;
                },
                ReturnCode.MemError => {
                    this.end();
                    this.state = State.Error;
                    return error.OutOfMemory;
                },
                ReturnCode.StreamError,
                ReturnCode.DataError,
                ReturnCode.BufError,
                ReturnCode.NeedDict,
                ReturnCode.VersionError,
                ReturnCode.ErrNo,
                => {
                    this.end();
                    this.state = State.Error;
                    return error.ZlibError;
                },
                ReturnCode.Ok => {},
            }
        }
    }
};

const std = @import("std");

const home_rt = @import("home");
const mimalloc = home_rt.mimalloc_sys.mimalloc;

const DataType = internal.i_DataType;
const zStream_struct = internal.i_zStream_struct;

test "zlib wrapper compiles" {
    _ = @typeName(@TypeOf(ZlibReaderArrayList.init));
    _ = @typeName(@TypeOf(ZlibReaderArrayList.readAll));
    _ = @typeName(@TypeOf(ZlibCompressorArrayList.init));
    _ = @typeName(@TypeOf(ZlibCompressorArrayList.readAll));
    _ = @typeName(@TypeOf(zlibVersion));
    _ = @typeName(@TypeOf(inflate));
    _ = @typeName(@TypeOf(deflate));
    _ = @typeName(@TypeOf(crc32));
    try std.testing.expectEqual(@as(c_int, 8), MIN_WBITS);
    try std.testing.expectEqual(@as(c_int, 15), MAX_WBITS);
    try std.testing.expectEqual(@as(u8, 11), @intFromEnum(NodeMode.ZSTD_DECOMPRESS));
    // Default options match the upstream defaults.
    const opts: Options = .{};
    try std.testing.expectEqual(@as(c_int, 6), opts.level);
    try std.testing.expectEqual(@as(c_int, 15), opts.windowBits);
}
