// Copied verbatim from bun/src/zstd/zstd.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// Zig wrapper around the vendored facebook/zstd C library. Upstream pulled
// the ZSTD_* extern symbols from `bun.c` (translate-c over `<zstd.h>`); we
// inline them as `extern fn` decls here so we don't depend on translate-c.
// The C ABI surface is the link-time contract with libzstd and must not be
// renamed.

// ---- ZSTD C ABI extern surface ----------------------------------------
// Mirrors the FFI block in upstream/src/zstd/lib.rs; the upstream Zig file
// reached these through `bun.c.ZSTD_*` (translate-c over `<zstd.h>`).
pub const c = struct {
    pub const ZSTD_DStream = opaque {};
    /// `typedef ZSTD_DCtx ZSTD_DStream;` — same opaque object.
    pub const ZSTD_DCtx = ZSTD_DStream;
    pub const ZSTD_CCtx = opaque {};

    pub const ZSTD_ErrorCode = c_uint;
    // ZSTD_ErrorCode enum values (vendor/zstd/lib/zstd_errors.h).
    pub const ZSTD_error_no_error: ZSTD_ErrorCode = 0;
    pub const ZSTD_error_GENERIC: ZSTD_ErrorCode = 1;
    pub const ZSTD_error_prefix_unknown: ZSTD_ErrorCode = 10;
    pub const ZSTD_error_version_unsupported: ZSTD_ErrorCode = 12;
    pub const ZSTD_error_frameParameter_unsupported: ZSTD_ErrorCode = 14;
    pub const ZSTD_error_frameParameter_windowTooLarge: ZSTD_ErrorCode = 16;
    pub const ZSTD_error_corruption_detected: ZSTD_ErrorCode = 20;
    pub const ZSTD_error_checksum_wrong: ZSTD_ErrorCode = 22;
    pub const ZSTD_error_literals_headerWrong: ZSTD_ErrorCode = 24;
    pub const ZSTD_error_dictionary_corrupted: ZSTD_ErrorCode = 30;
    pub const ZSTD_error_dictionary_wrong: ZSTD_ErrorCode = 32;
    pub const ZSTD_error_dictionaryCreation_failed: ZSTD_ErrorCode = 34;
    pub const ZSTD_error_parameter_unsupported: ZSTD_ErrorCode = 40;
    pub const ZSTD_error_parameter_combination_unsupported: ZSTD_ErrorCode = 41;
    pub const ZSTD_error_parameter_outOfBound: ZSTD_ErrorCode = 42;
    pub const ZSTD_error_tableLog_tooLarge: ZSTD_ErrorCode = 44;
    pub const ZSTD_error_maxSymbolValue_tooLarge: ZSTD_ErrorCode = 46;
    pub const ZSTD_error_maxSymbolValue_tooSmall: ZSTD_ErrorCode = 48;
    pub const ZSTD_error_cannotProduce_uncompressedBlock: ZSTD_ErrorCode = 49;
    pub const ZSTD_error_stabilityCondition_notRespected: ZSTD_ErrorCode = 50;
    pub const ZSTD_error_stage_wrong: ZSTD_ErrorCode = 60;
    pub const ZSTD_error_init_missing: ZSTD_ErrorCode = 62;
    pub const ZSTD_error_memory_allocation: ZSTD_ErrorCode = 64;
    pub const ZSTD_error_workSpace_tooSmall: ZSTD_ErrorCode = 66;
    pub const ZSTD_error_dstSize_tooSmall: ZSTD_ErrorCode = 70;
    pub const ZSTD_error_srcSize_wrong: ZSTD_ErrorCode = 72;
    pub const ZSTD_error_dstBuffer_null: ZSTD_ErrorCode = 74;
    pub const ZSTD_error_noForwardProgress_destFull: ZSTD_ErrorCode = 80;
    pub const ZSTD_error_noForwardProgress_inputEmpty: ZSTD_ErrorCode = 82;
    pub const ZSTD_error_frameIndex_tooLarge: ZSTD_ErrorCode = 100;
    pub const ZSTD_error_seekableIO: ZSTD_ErrorCode = 102;
    pub const ZSTD_error_dstBuffer_wrong: ZSTD_ErrorCode = 104;
    pub const ZSTD_error_srcBuffer_wrong: ZSTD_ErrorCode = 105;
    pub const ZSTD_error_sequenceProducer_failed: ZSTD_ErrorCode = 106;
    pub const ZSTD_error_externalSequences_invalid: ZSTD_ErrorCode = 107;
    pub const ZSTD_error_maxCode: ZSTD_ErrorCode = 120;
    pub const ZSTD_EndDirective = c_uint;
    pub const ZSTD_ResetDirective = c_uint;
    pub const ZSTD_cParameter = c_uint;
    pub const ZSTD_dParameter = c_uint;

    pub const ZSTD_e_continue: ZSTD_EndDirective = 0;
    pub const ZSTD_e_flush: ZSTD_EndDirective = 1;
    pub const ZSTD_e_end: ZSTD_EndDirective = 2;

    pub const ZSTD_reset_session_only: ZSTD_ResetDirective = 1;
    pub const ZSTD_reset_parameters: ZSTD_ResetDirective = 2;
    pub const ZSTD_reset_session_and_parameters: ZSTD_ResetDirective = 3;

    pub const ZSTD_inBuffer = extern struct {
        src: ?*const anyopaque,
        size: usize,
        pos: usize,
    };

    pub const ZSTD_outBuffer = extern struct {
        dst: ?*anyopaque,
        size: usize,
        pos: usize,
    };

    pub extern fn ZSTD_compress(dst: ?*anyopaque, dstCapacity: usize, src: ?*const anyopaque, srcSize: usize, compressionLevel: c_int) callconv(.c) usize;
    pub extern fn ZSTD_compressBound(srcSize: usize) callconv(.c) usize;
    pub extern fn ZSTD_decompress(dst: ?*anyopaque, dstCapacity: usize, src: ?*const anyopaque, compressedSize: usize) callconv(.c) usize;
    pub extern fn ZSTD_isError(code: usize) callconv(.c) c_uint;
    pub extern fn ZSTD_getErrorName(code: usize) callconv(.c) [*:0]const u8;
    pub extern fn ZSTD_defaultCLevel() callconv(.c) c_int;

    pub extern fn ZSTD_createDStream() callconv(.c) ?*ZSTD_DStream;
    pub extern fn ZSTD_freeDStream(zds: *ZSTD_DStream) callconv(.c) usize;
    pub extern fn ZSTD_initDStream(zds: *ZSTD_DStream) callconv(.c) usize;
    pub extern fn ZSTD_decompressStream(zds: *ZSTD_DStream, output: *ZSTD_outBuffer, input: *ZSTD_inBuffer) callconv(.c) usize;

    pub extern fn ZSTD_createCCtx() callconv(.c) ?*ZSTD_CCtx;
    pub extern fn ZSTD_freeCCtx(cctx: *ZSTD_CCtx) callconv(.c) usize;
    pub extern fn ZSTD_createDCtx() callconv(.c) ?*ZSTD_DCtx;
    pub extern fn ZSTD_freeDCtx(dctx: *ZSTD_DCtx) callconv(.c) usize;
    pub extern fn ZSTD_CCtx_setPledgedSrcSize(cctx: *ZSTD_CCtx, pledgedSrcSize: c_ulonglong) callconv(.c) usize;
    pub extern fn ZSTD_CCtx_setParameter(cctx: *ZSTD_CCtx, param: ZSTD_cParameter, value: c_int) callconv(.c) usize;
    pub extern fn ZSTD_DCtx_setParameter(dctx: *ZSTD_DCtx, param: ZSTD_dParameter, value: c_int) callconv(.c) usize;
    pub extern fn ZSTD_CCtx_reset(cctx: *ZSTD_CCtx, reset: ZSTD_ResetDirective) callconv(.c) usize;
    pub extern fn ZSTD_DCtx_reset(dctx: *ZSTD_DCtx, reset: ZSTD_ResetDirective) callconv(.c) usize;
    pub extern fn ZSTD_compressStream2(cctx: *ZSTD_CCtx, output: *ZSTD_outBuffer, input: *ZSTD_inBuffer, endOp: ZSTD_EndDirective) callconv(.c) usize;
    pub extern fn ZSTD_getErrorCode(functionResult: usize) callconv(.c) ZSTD_ErrorCode;
    pub extern fn ZSTD_getErrorString(code: ZSTD_ErrorCode) callconv(.c) [*:0]const u8;
};

// -----------------------------------

/// ZSTD_compress() :
///  Compresses `src` content as a single zstd compressed frame into already allocated `dst`.
///  NOTE: Providing `dstCapacity >= ZSTD_compressBound(srcSize)` guarantees that zstd will have
///        enough space to successfully compress the data.
///  @return : compressed size written into `dst` (<= `dstCapacity),
///            or an error code if it fails (which can be tested using ZSTD_isError()). */
// ZSTDLIB_API size_t ZSTD_compress( void* dst, size_t dstCapacity,
//                             const void* src, size_t srcSize,
//                                   int compressionLevel);
pub fn compress(dest: []u8, src: []const u8, level: ?i32) Result {
    const result = c.ZSTD_compress(dest.ptr, dest.len, src.ptr, src.len, level orelse c.ZSTD_defaultCLevel());
    if (c.ZSTD_isError(result) != 0) return .{ .err = std.mem.sliceTo(c.ZSTD_getErrorName(result), 0) };
    return .{ .success = result };
}

pub fn compressBound(srcSize: usize) usize {
    return c.ZSTD_compressBound(srcSize);
}

/// ZSTD_decompress() :
/// `compressedSize` : must be the _exact_ size of some number of compressed and/or skippable frames.
/// `dstCapacity` is an upper bound of originalSize to regenerate.
/// If user cannot imply a maximum upper bound, it's better to use streaming mode to decompress data.
/// @return : the number of bytes decompressed into `dst` (<= `dstCapacity`),
///           or an errorCode if it fails (which can be tested using ZSTD_isError()). */
// ZSTDLIB_API size_t ZSTD_decompress( void* dst, size_t dstCapacity,
//   const void* src, size_t compressedSize);
pub fn decompress(dest: []u8, src: []const u8) Result {
    const result = c.ZSTD_decompress(dest.ptr, dest.len, src.ptr, src.len);
    if (c.ZSTD_isError(result) != 0) return .{ .err = std.mem.sliceTo(c.ZSTD_getErrorName(result), 0) };
    return .{ .success = result };
}

/// Decompress data, automatically allocating the output buffer.
/// Returns owned slice that must be freed by the caller.
/// Handles both frames with known and unknown content sizes.
/// For safety, if the reported decompressed size exceeds 16MB, streaming decompression is used instead.
pub fn decompressAlloc(allocator: std.mem.Allocator, src: []const u8) ![]u8 {
    const size = getDecompressedSize(src);

    const ZSTD_CONTENTSIZE_UNKNOWN = std.math.maxInt(c_ulonglong); // 0ULL - 1
    const ZSTD_CONTENTSIZE_ERROR = std.math.maxInt(c_ulonglong) - 1; // 0ULL - 2
    const MAX_PREALLOCATE_SIZE = 16 * 1024 * 1024; // 16MB safety limit

    if (size == ZSTD_CONTENTSIZE_ERROR) {
        return error.InvalidZstdData;
    }

    // Use streaming decompression if:
    // 1. Content size is unknown, OR
    // 2. Reported size exceeds safety limit (to prevent malicious inputs claiming huge sizes)
    if (size == ZSTD_CONTENTSIZE_UNKNOWN or size > MAX_PREALLOCATE_SIZE) {
        var list = std.ArrayListUnmanaged(u8).empty;
        // `reader.deinit()` below does not free `list`; free it ourselves on any error
        // (init failure, readAll failure, or toOwnedSlice failure).
        errdefer list.deinit(allocator);
        const reader = try ZstdReaderArrayList.init(src, &list, allocator);
        defer reader.deinit();

        try reader.readAll(true);
        return try list.toOwnedSlice(allocator);
    }

    // Fast path: size is known and within reasonable limits
    const output = try allocator.alloc(u8, size);
    errdefer allocator.free(output);

    const result = decompress(output, src);
    return switch (result) {
        .success => |actual_size| output[0..actual_size],
        // `output` is freed by the errdefer above.
        .err => error.DecompressionFailed,
    };
}

pub fn getDecompressedSize(src: []const u8) usize {
    return ZSTD_findDecompressedSize(src.ptr, src.len);
}

//ZSTD_findDecompressedSize() :
//`src` should point to the start of a series of ZSTD encoded and/or skippable frames
//`srcSize` must be the _exact_ size of this series
//     (i.e. there should be a frame boundary at `src + srcSize`)
//@return : - decompressed size of all data in all successive frames
//          - if the decompressed size cannot be determined: ZSTD_CONTENTSIZE_UNKNOWN
//          - if an error occurred: ZSTD_CONTENTSIZE_ERROR
//
// note 1 : decompressed size is an optional field, that may not be present, especially in streaming mode.
//          When `return==ZSTD_CONTENTSIZE_UNKNOWN`, data to decompress could be any size.
//          In which case, it's necessary to use streaming mode to decompress data.
// note 2 : decompressed size is always present when compression is done with ZSTD_compress()
// note 3 : decompressed size can be very large (64-bits value),
//          potentially larger than what local system can handle as a single memory segment.
//          In which case, it's necessary to use streaming mode to decompress data.
// note 4 : If source is untrusted, decompressed size could be wrong or intentionally modified.
//          Always ensure result fits within application's authorized limits.
//          Each application can set its own limits.
// note 5 : ZSTD_findDecompressedSize handles multiple frames, and so it must traverse the input to
//          read each contained frame header.  This is fast as most of the data is skipped,
//          however it does mean that all frame data must be present and valid. */
pub extern fn ZSTD_findDecompressedSize(src: ?*const anyopaque, srcSize: usize) c_ulonglong;

pub const Result = union(enum) {
    success: usize,
    err: [:0]const u8,
};

pub const ZstdReaderArrayList = struct {
    const State = enum {
        Uninitialized,
        Inflating,
        End,
        Error,
    };

    input: []const u8,
    list: std.ArrayListUnmanaged(u8),
    list_allocator: std.mem.Allocator,
    list_ptr: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    zstd: *c.ZSTD_DStream,
    state: State = State.Uninitialized,
    total_out: usize = 0,
    total_in: usize = 0,
    /// Decompression-bomb cap: fail once the output buffer exceeds this size.
    max_output_size: usize = std.math.maxInt(usize),

    // PORT NOTE: upstream `pub const new = bun.TrivialNew(ZstdReaderArrayList);`
    // — re-attaches in Phase 12.2 when home_rt.TrivialNew lands. Callers use
    // `allocator.create()` in the meantime (which is what init does already).

    pub fn init(
        input: []const u8,
        list: *std.ArrayListUnmanaged(u8),
        allocator: std.mem.Allocator,
    ) !*ZstdReaderArrayList {
        return initWithListAllocator(input, list, allocator, allocator);
    }

    pub fn initWithListAllocator(
        input: []const u8,
        list: *std.ArrayListUnmanaged(u8),
        list_allocator: std.mem.Allocator,
        allocator: std.mem.Allocator,
    ) !*ZstdReaderArrayList {
        var reader = try allocator.create(ZstdReaderArrayList);
        reader.* = .{
            .input = input,
            .list = list.*,
            .list_allocator = list_allocator,
            .list_ptr = list,
            .allocator = allocator,
            .zstd = undefined,
        };

        reader.zstd = c.ZSTD_createDStream() orelse {
            allocator.destroy(reader);
            return error.ZstdFailedToCreateInstance;
        };
        _ = c.ZSTD_initDStream(reader.zstd);
        return reader;
    }

    pub fn end(this: *ZstdReaderArrayList) void {
        if (this.state != .End) {
            _ = c.ZSTD_freeDStream(this.zstd);
            this.state = .End;
        }
    }

    pub fn deinit(this: *ZstdReaderArrayList) void {
        var alloc = this.allocator;
        this.end();
        alloc.destroy(this);
    }

    pub fn readAll(this: *ZstdReaderArrayList, is_done: bool) !void {
        defer this.list_ptr.* = this.list;

        if (this.state == .End or this.state == .Error) return;

        while (this.state == .Uninitialized or this.state == .Inflating) {
            const next_in = this.input[this.total_in..];

            // If we have no input to process
            if (next_in.len == 0) {
                if (is_done) {
                    // If we're in the middle of inflating and stream is done, it's truncated
                    if (this.state == .Inflating) {
                        this.state = .Error;
                        return error.ZstdDecompressionError;
                    }
                    // No more input and stream is done, we can end
                    this.end();
                }
                return;
            }

            var unused = this.list.unusedCapacitySlice();
            if (unused.len < 4096) {
                try this.list.ensureUnusedCapacity(this.list_allocator, 4096);
                unused = this.list.unusedCapacitySlice();
            }
            var in_buf: c.ZSTD_inBuffer = .{
                .src = if (next_in.len > 0) next_in.ptr else null,
                .size = next_in.len,
                .pos = 0,
            };
            var out_buf: c.ZSTD_outBuffer = .{
                .dst = if (unused.len > 0) unused.ptr else null,
                .size = unused.len,
                .pos = 0,
            };

            const rc = c.ZSTD_decompressStream(this.zstd, &out_buf, &in_buf);
            if (c.ZSTD_isError(rc) != 0) {
                this.state = .Error;
                return error.ZstdDecompressionError;
            }

            const bytes_written = out_buf.pos;
            const bytes_read = in_buf.pos;
            this.list.items.len += bytes_written;
            this.total_in += bytes_read;
            this.total_out += bytes_written;
            if (this.list.items.len > this.max_output_size) {
                this.state = .Error;
                return error.ZstdDecompressionError;
            }

            if (rc == 0) {
                // Frame is complete
                this.state = .Uninitialized; // Reset state since frame is complete

                // Check if there's more input (multiple frames)
                if (this.total_in >= this.input.len) {
                    // We've consumed all available input
                    if (is_done) {
                        // No more data coming, we can end the stream
                        this.end();
                        return;
                    }
                    // Frame is complete and no more input available right now.
                    // Just return normally - the caller can provide more data later if they have it.
                    return;
                }
                // More input available, reset for the next frame
                // ZSTD_initDStream() safely resets the stream state without needing cleanup
                // It's designed to be called multiple times on the same DStream object
                _ = c.ZSTD_initDStream(this.zstd);
                continue;
            }

            // If rc > 0, decompressor needs more data
            if (rc > 0) {
                this.state = .Inflating;
            }

            if (bytes_read == next_in.len) {
                // We've consumed all available input
                if (bytes_written > 0) {
                    // We wrote some output, continue to see if we need more output space
                    continue;
                }

                if (is_done) {
                    // Stream is truncated - we're at EOF but need more data
                    this.state = .Error;
                    return error.ZstdDecompressionError;
                }
                // Not at EOF - we can retry with more data
                return error.ShortRead;
            }
        }
    }
};

const std = @import("std");

test "zstd extern symbol signatures compile" {
    _ = @typeName(@TypeOf(c.ZSTD_compress));
    _ = @typeName(@TypeOf(c.ZSTD_decompress));
    _ = @typeName(@TypeOf(c.ZSTD_createDStream));
    _ = @typeName(@TypeOf(c.ZSTD_decompressStream));
    _ = @typeName(@TypeOf(c.ZSTD_compressStream2));
    _ = @typeName(@TypeOf(ZSTD_findDecompressedSize));
    _ = @typeName(@TypeOf(compress));
    _ = @typeName(@TypeOf(decompress));
    _ = @typeName(@TypeOf(decompressAlloc));
    _ = @typeName(@TypeOf(ZstdReaderArrayList.init));
    try std.testing.expectEqual(@as(c.ZSTD_EndDirective, 0), c.ZSTD_e_continue);
    try std.testing.expectEqual(@as(c.ZSTD_EndDirective, 1), c.ZSTD_e_flush);
    try std.testing.expectEqual(@as(c.ZSTD_EndDirective, 2), c.ZSTD_e_end);
    try std.testing.expectEqual(@as(c.ZSTD_ResetDirective, 1), c.ZSTD_reset_session_only);
    try std.testing.expectEqual(@as(c.ZSTD_ResetDirective, 3), c.ZSTD_reset_session_and_parameters);
    try std.testing.expectEqual(@sizeOf(usize) * 3, @sizeOf(c.ZSTD_inBuffer));
    try std.testing.expectEqual(@sizeOf(usize) * 3, @sizeOf(c.ZSTD_outBuffer));
}
