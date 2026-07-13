// Copied from bun/src/brotli/brotli.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// ArrayList-streaming Brotli reader + writer over the vendored
// google/brotli C ABI surface (`brotli_sys.brotli_c`). Mirrors upstream's
// `BunBrotli` module verbatim minus three rewrites:
//
//   1. `@import("bun")` collapses to `@import("home")` — `BrotliDecoder`/
//      `BrotliEncoder` come from `home_rt.brotli_sys.brotli_c`.
//   2. The optional `bun.heap_breakdown` zone fallback is dropped (no
//      heap-breakdown substrate in home_rt yet); allocations go straight
//      to mimalloc. Re-attaches when `home_rt.heap_breakdown` lands.
//   3. `bun.TrivialNew` is replaced by an inline `allocator.create()`
//      idiom — the upstream marker re-attaches once
//      `home_rt.TrivialNew` is ported.
//   4. `bun.assert` and `bun.outOfMemory` are routed through `home_rt`.
//   5. `bun.destroy` is replaced by an inline allocator-free pattern;
//      since we now thread an explicit `allocator` we can free
//      symmetrically.
//   6. `bun.Output.debugWarn` falls back to `home_rt.Output.errorln`
//      since the debug-only warn channel hasn't landed yet.

pub const c = @import("home").brotli_sys.brotli_c;
const BrotliDecoder = c.BrotliDecoder;
const BrotliEncoder = c.BrotliEncoder;

pub const BrotliAllocator = struct {
    pub fn alloc(_: ?*anyopaque, len: usize) callconv(.c) *anyopaque {
        return mimalloc.mi_malloc(len) orelse @panic("brotli: mimalloc out of memory");
    }

    pub fn free(_: ?*anyopaque, data: ?*anyopaque) callconv(.c) void {
        mimalloc.mi_free(data);
    }
};

pub const DecoderOptions = struct {
    pub const Params = std.enums.EnumFieldStruct(c.BrotliDecoderParameter, bool, false);

    params: Params = Params{
        .LARGE_WINDOW = true,
        .DISABLE_RING_BUFFER_REALLOCATION = false,
    },
};

pub const BrotliReaderArrayList = struct {
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
    brotli: *BrotliDecoder,
    state: State = State.Uninitialized,
    total_out: usize = 0,
    total_in: usize = 0,
    /// Decompression-bomb cap: fail once the output buffer exceeds this size.
    max_output_size: usize = std.math.maxInt(usize),
    flushOp: BrotliEncoder.Operation,
    finishFlushOp: BrotliEncoder.Operation,
    fullFlushOp: BrotliEncoder.Operation,
    /// Owning allocator for the reader struct itself. Upstream stashes this
    /// inside `bun.TrivialNew`/`bun.destroy`; we carry it explicitly so the
    /// `deinit()` path can free symmetrically.
    owner_allocator: std.mem.Allocator,

    pub fn newWithOptions(
        input: []const u8,
        list: *std.ArrayListUnmanaged(u8),
        allocator: std.mem.Allocator,
        options: DecoderOptions,
    ) !*BrotliReaderArrayList {
        var reader = try allocator.create(BrotliReaderArrayList);
        errdefer allocator.destroy(reader);
        reader.* = try initWithOptions(input, list, allocator, options, .process, .finish, .flush);
        reader.owner_allocator = allocator;
        return reader;
    }

    pub fn initWithOptions(
        input: []const u8,
        list: *std.ArrayListUnmanaged(u8),
        allocator: std.mem.Allocator,
        options: DecoderOptions,
        flushOp: BrotliEncoder.Operation,
        finishFlushOp: BrotliEncoder.Operation,
        fullFlushOp: BrotliEncoder.Operation,
    ) !BrotliReaderArrayList {
        if (!BrotliDecoder.initializeBrotli()) {
            return error.BrotliFailedToLoad;
        }

        var brotli = BrotliDecoder.createInstance(&BrotliAllocator.alloc, &BrotliAllocator.free, null) orelse return error.BrotliFailedToCreateInstance;
        if (options.params.LARGE_WINDOW)
            _ = brotli.setParameter(c.BrotliDecoderParameter.LARGE_WINDOW, 1);
        if (options.params.DISABLE_RING_BUFFER_REALLOCATION)
            _ = brotli.setParameter(c.BrotliDecoderParameter.DISABLE_RING_BUFFER_REALLOCATION, 1);

        home_rt.assert(list.items.ptr != input.ptr);

        return .{
            .input = input,
            .list_ptr = list,
            .list = list.*,
            .list_allocator = allocator,
            .brotli = brotli,
            .flushOp = flushOp,
            .finishFlushOp = finishFlushOp,
            .fullFlushOp = fullFlushOp,
            .owner_allocator = allocator,
        };
    }

    pub fn end(this: *BrotliReaderArrayList) void {
        this.state = .End;
    }

    pub fn readAll(this: *BrotliReaderArrayList, is_done: bool) !void {
        defer this.list_ptr.* = this.list;

        if (this.state == .End or this.state == .Error) {
            return;
        }

        home_rt.assert(this.list.items.ptr != this.input.ptr);

        while (this.state == State.Uninitialized or this.state == State.Inflating) {
            var unused_capacity = this.list.unusedCapacitySlice();

            if (unused_capacity.len < 4096) {
                try this.list.ensureUnusedCapacity(this.list_allocator, 4096);
                unused_capacity = this.list.unusedCapacitySlice();
            }

            home_rt.assert(unused_capacity.len > 0);

            var next_in = this.input[this.total_in..];

            var in_remaining = next_in.len;
            var out_remaining = unused_capacity.len;

            // https://github.com/google/brotli/blob/fef82ea10435abb1500b615b1b2c6175d429ec6c/go/cbrotli/reader.go#L15-L27
            const result = this.brotli.decompressStream(
                &in_remaining,
                @ptrCast(&next_in),
                &out_remaining,
                @ptrCast(&unused_capacity.ptr),
                null,
            );

            const bytes_written = unused_capacity.len -| out_remaining;
            const bytes_read = next_in.len -| in_remaining;

            this.list.items.len += bytes_written;
            this.total_in += bytes_read;
            if (this.list.items.len > this.max_output_size) {
                this.state = .Error;
                return error.BrotliDecompressionError;
            }

            switch (result) {
                .success => {
                    if (comptime home_rt.Environment.allow_assert) {
                        home_rt.assert(this.brotli.isFinished());
                    }
                    this.end();
                    return;
                },
                .err => {
                    this.state = .Error;
                    if (comptime home_rt.Environment.allow_assert) {
                        const code = this.brotli.getErrorCode();
                        home_rt.Output.errorln("Brotli error: {s} ({d})", .{ @tagName(code), @intFromEnum(code) });
                    }

                    return error.BrotliDecompressionError;
                },

                .needs_more_input => {
                    if (in_remaining > 0) {
                        @panic("Brotli wants more data");
                    }
                    this.state = .Inflating;
                    if (is_done) {
                        // Stream is truncated - we're at EOF but decoder needs more data
                        this.state = .Error;
                        return error.BrotliDecompressionError;
                    }
                    // Not at EOF - we can retry with more data
                    return error.ShortRead;
                },
                .needs_more_output => {
                    try this.list.ensureTotalCapacity(this.list_allocator, this.list.capacity + 4096);
                    this.state = .Inflating;
                },
            }
        }
    }

    pub fn deinit(this: *BrotliReaderArrayList) void {
        const owner = this.owner_allocator;
        this.brotli.destroyInstance();
        owner.destroy(this);
    }
};

pub const BrotliCompressionStream = struct {
    pub const State = enum {
        Inflating,
        End,
        Error,
    };

    brotli: *BrotliEncoder,
    state: State = State.Inflating,
    total_out: usize = 0,
    total_in: usize = 0,
    flushOp: BrotliEncoder.Operation,
    finishFlushOp: BrotliEncoder.Operation,
    fullFlushOp: BrotliEncoder.Operation,

    pub fn init(
        flushOp: BrotliEncoder.Operation,
        finishFlushOp: BrotliEncoder.Operation,
        fullFlushOp: BrotliEncoder.Operation,
    ) !BrotliCompressionStream {
        const instance = BrotliEncoder.createInstance(&BrotliAllocator.alloc, &BrotliAllocator.free, null) orelse return error.BrotliFailedToCreateInstance;

        return BrotliCompressionStream{
            .brotli = instance,
            .flushOp = flushOp,
            .finishFlushOp = finishFlushOp,
            .fullFlushOp = fullFlushOp,
        };
    }

    pub fn writeChunk(this: *BrotliCompressionStream, input: []const u8, last: bool) ![]const u8 {
        this.total_in += input.len;
        const result = this.brotli.compressStream(if (last) this.finishFlushOp else this.flushOp, input);

        if (!result.success) {
            this.state = .Error;
            return error.BrotliCompressionError;
        }

        return result.output;
    }

    pub fn write(this: *BrotliCompressionStream, input: []const u8, last: bool) ![]const u8 {
        if (this.state == .End or this.state == .Error) {
            return "";
        }

        return this.writeChunk(input, last);
    }

    pub fn end(this: *BrotliCompressionStream) ![]const u8 {
        defer this.state = .End;

        return try this.write("", true);
    }

    pub fn deinit(this: *BrotliCompressionStream) void {
        this.brotli.destroyInstance();
    }

    fn NewWriter(comptime InputWriter: type) type {
        return struct {
            compressor: *BrotliCompressionStream,
            input_writer: InputWriter,

            const Self = @This();
            pub const WriteError = error{BrotliCompressionError} || InputWriter.Error;
            pub const Writer = home_rt.io.GenericWriter(@This(), WriteError, Self.write);

            pub fn init(compressor: *BrotliCompressionStream, input_writer: InputWriter) Self {
                return Self{
                    .compressor = compressor,
                    .input_writer = input_writer,
                };
            }

            pub fn write(self: Self, to_compress: []const u8) WriteError!usize {
                const decompressed = try self.compressor.write(to_compress, false);
                try self.input_writer.writeAll(decompressed);
                return to_compress.len;
            }

            pub fn end(self: Self) !usize {
                const decompressed = try self.compressor.end();
                try self.input_writer.writeAll(decompressed);
            }

            pub fn writer(self: Self) Writer {
                return Writer{ .context = self };
            }
        };
    }

    pub fn writerContext(this: *BrotliCompressionStream, writable: anytype) NewWriter(@TypeOf(writable)) {
        return NewWriter(@TypeOf(writable)).init(this, writable);
    }

    pub fn writer(this: *BrotliCompressionStream, writable: anytype) NewWriter(@TypeOf(writable)).Writer {
        return this.writerContext(writable).writer();
    }
};

const std = @import("std");

const home_rt = @import("home");
const mimalloc = home_rt.mimalloc_sys.mimalloc;

test "brotli wrapper compiles" {
    // Smoke: the extern symbols and struct shapes resolve at compile time.
    _ = @typeName(@TypeOf(BrotliAllocator.alloc));
    _ = @typeName(@TypeOf(BrotliAllocator.free));
    _ = @typeName(@TypeOf(BrotliReaderArrayList.newWithOptions));
    _ = @typeName(@TypeOf(BrotliReaderArrayList.readAll));
    _ = @typeName(@TypeOf(BrotliCompressionStream.init));
    _ = @typeName(@TypeOf(BrotliCompressionStream.writeChunk));
    try std.testing.expect(@sizeOf(DecoderOptions) > 0);
    // DecoderOptions defaults: LARGE_WINDOW is enabled by default.
    const opts: DecoderOptions = .{};
    try std.testing.expect(opts.params.LARGE_WINDOW);
    try std.testing.expect(!opts.params.DISABLE_RING_BUFFER_REALLOCATION);
}
