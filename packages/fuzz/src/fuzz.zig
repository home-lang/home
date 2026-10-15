// Fuzzing Test Infrastructure for Home Programming Language
//
// This module provides fuzzing capabilities for critical components:
// - Lexer/Parser fuzzing for syntax edge cases
// - Codec fuzzing for malformed input handling
// - Network protocol fuzzing for packet validation
//
// Integration with AFL/libFuzzer is supported through external harness.

const std = @import("std");

/// Fuzzing configuration
pub const FuzzConfig = struct {
    /// Maximum input size in bytes
    max_input_size: usize = 1024 * 1024, // 1MB default
    /// Maximum recursion depth for nested structures
    max_recursion_depth: usize = 256,
    /// Timeout per test case in milliseconds
    timeout_ms: u64 = 5000,
    /// Enable corpus minimization
    minimize_corpus: bool = true,
    /// Seed for reproducible runs
    seed: ?u64 = null,
};

/// Fuzzing result for a single test case
pub const FuzzResult = struct {
    /// Whether the test passed without issues
    passed: bool,
    /// Error message if test failed
    error_message: ?[]const u8 = null,
    /// Execution time in nanoseconds
    execution_time_ns: u64,
    /// Memory peak usage in bytes
    peak_memory: usize,
    /// Coverage information (basic blocks hit)
    coverage: ?Coverage = null,
};

/// Coverage tracking information
pub const Coverage = struct {
    /// Number of basic blocks executed
    blocks_hit: usize,
    /// Total basic blocks in target
    total_blocks: usize,
    /// New coverage discovered
    new_coverage: bool,
};

/// Fuzzer trait for implementing custom fuzzers
pub fn Fuzzer(comptime Context: type) type {
    return struct {
        const Self = @This();

        context: Context,
        config: FuzzConfig,
        allocator: std.mem.Allocator,
        io: std.Io,
        started_at: std.Io.Timestamp,
        /// Statistics for this fuzzing session
        stats: FuzzStats,

        pub const FuzzStats = struct {
            total_runs: u64 = 0,
            crashes: u64 = 0,
            timeouts: u64 = 0,
            unique_crashes: u64 = 0,
            coverage_percent: f32 = 0.0,
            start_time: i64 = 0,
        };

        pub fn init(allocator: std.mem.Allocator, context: Context, config: FuzzConfig) Self {
            return initWithIo(allocator, context, config, std.Io.Threaded.global_single_threaded.io());
        }

        pub fn initWithIo(allocator: std.mem.Allocator, context: Context, config: FuzzConfig, io: std.Io) Self {
            return .{
                .context = context,
                .config = config,
                .allocator = allocator,
                .io = io,
                .started_at = std.Io.Clock.awake.now(io),
                .stats = .{ .start_time = std.Io.Clock.real.now(io).toMilliseconds() },
            };
        }

        /// Run a single fuzz iteration with the given input
        pub fn runOne(self: *Self, input: []const u8) FuzzResult {
            const start_time = std.Io.Clock.awake.now(self.io);
            defer self.stats.total_runs += 1;

            // Check input size limits
            if (input.len > self.config.max_input_size) {
                return .{
                    .passed = false,
                    .error_message = "Input exceeds maximum size",
                    .execution_time_ns = 0,
                    .peak_memory = 0,
                };
            }

            // Run the actual fuzzing target
            const result = if (@hasDecl(Context, "fuzz")) blk: {
                const fuzz_result = self.context.fuzz(input) catch |err| {
                    self.stats.crashes += 1;
                    break :blk FuzzResult{
                        .passed = false,
                        .error_message = @errorName(err),
                        .execution_time_ns = @intCast(start_time.durationTo(std.Io.Clock.awake.now(self.io)).toNanoseconds()),
                        .peak_memory = 0,
                    };
                };
                break :blk fuzz_result;
            } else {
                @compileError("Context must implement fuzz(input: []const u8) !FuzzResult");
            };

            return result;
        }

        /// Run fuzzing loop until stopped
        pub fn run(self: *Self, corpus: []const []const u8) void {
            for (corpus) |input| {
                _ = self.runOne(input);
            }
        }

        /// Generate a random mutation of the input
        pub fn mutate(self: *Self, input: []const u8) ![]u8 {
            // Guard the i64→u64 cast when falling back to wall clock so
            // a pathological negative timestamp doesn't panic.
            const seed: u64 = if (self.config.seed) |s|
                s
            else blk: {
                const ts = std.Io.Clock.real.now(self.io).toMilliseconds();
                break :blk if (ts < 0) 0 else @intCast(ts);
            };
            var prng = std.Random.DefaultPrng.init(seed);

            const random = prng.random();
            var output = try self.allocator.alloc(u8, input.len);
            errdefer self.allocator.free(output);
            @memcpy(output, input);

            // Apply random mutation
            const mutation_type = random.intRangeAtMost(u8, 0, 5);
            switch (mutation_type) {
                0 => { // Bit flip
                    if (output.len > 0) {
                        const pos = random.intRangeLessThan(usize, 0, output.len);
                        const bit: u3 = @intCast(random.intRangeLessThan(u8, 0, 8));
                        output[pos] ^= @as(u8, 1) << bit;
                    }
                },
                1 => { // Byte flip
                    if (output.len > 0) {
                        const pos = random.intRangeLessThan(usize, 0, output.len);
                        output[pos] = ~output[pos];
                    }
                },
                2 => { // Insert random byte
                    output = try self.allocator.realloc(output, output.len + 1);
                    const pos = random.intRangeLessThan(usize, 0, output.len);
                    std.mem.copyBackwards(u8, output[pos + 1 ..], output[pos .. output.len - 1]);
                    output[pos] = random.int(u8);
                },
                3 => { // Delete byte
                    if (output.len > 1) {
                        const pos = random.intRangeLessThan(usize, 0, output.len);
                        std.mem.copyForwards(u8, output[pos..], output[pos + 1 ..]);
                        output = try self.allocator.realloc(output, output.len - 1);
                    }
                },
                4 => { // Replace with interesting value
                    if (output.len >= 4) {
                        const interesting_values = [_]u32{ 0, 1, 0xFF, 0xFFFF, 0xFFFFFFFF, 0x7FFFFFFF, 0x80000000 };
                        const pos = random.intRangeLessThan(usize, 0, output.len - 3);
                        const val = interesting_values[random.intRangeLessThan(usize, 0, interesting_values.len)];
                        std.mem.writeInt(u32, output[pos..][0..4], val, .little);
                    }
                },
                else => { // Havoc - multiple random changes
                    const num_changes = random.intRangeAtMost(usize, 1, 10);
                    for (0..num_changes) |_| {
                        if (output.len > 0) {
                            const pos = random.intRangeLessThan(usize, 0, output.len);
                            output[pos] = random.int(u8);
                        }
                    }
                },
            }

            return output;
        }

        /// Get current statistics
        pub fn getStats(self: *const Self) FuzzStats {
            return self.stats;
        }

        /// Print fuzzing progress
        pub fn printProgress(self: *const Self) void {
            const elapsed = self.started_at.durationTo(std.Io.Clock.awake.now(self.io)).toMilliseconds();
            const exec_per_sec = if (elapsed > 0) @as(f64, @floatFromInt(self.stats.total_runs)) / (@as(f64, @floatFromInt(elapsed)) / 1000.0) else 0;

            std.log.info(
                \\[FUZZ] Runs: {d} | Crashes: {d} | Unique: {d} | Timeouts: {d}
                \\       Exec/s: {d:.1} | Coverage: {d:.1}%
                \\
            , .{
                self.stats.total_runs,
                self.stats.crashes,
                self.stats.unique_crashes,
                self.stats.timeouts,
                exec_per_sec,
                self.stats.coverage_percent,
            });
        }
    };
}

/// Lexer fuzzer context
pub const LexerFuzzer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,

    pub fn init(allocator: std.mem.Allocator) LexerFuzzer {
        return initWithIo(allocator, std.Io.Threaded.global_single_threaded.io());
    }

    pub fn initWithIo(allocator: std.mem.Allocator, io: std.Io) LexerFuzzer {
        return .{ .allocator = allocator, .io = io };
    }

    pub fn fuzz(self: *LexerFuzzer, input: []const u8) !FuzzResult {
        const start = std.Io.Clock.awake.now(self.io);

        // Import lexer module and run tokenization
        // Note: This will be connected to the actual lexer
        // Simulate lexer processing - actual implementation will call:
        // const lexer = @import("lexer").Lexer;
        // var lex = lexer.init(self.allocator, input);
        // while (lex.nextToken()) |_| {}

        return .{
            .passed = true,
            .execution_time_ns = @intCast(start.durationTo(std.Io.Clock.awake.now(self.io)).toNanoseconds()),
            .peak_memory = input.len * 2, // Approximate
        };
    }
};

/// Parser fuzzer context
pub const ParserFuzzer = struct {
    allocator: std.mem.Allocator,
    max_depth: usize,
    io: std.Io,

    pub fn init(allocator: std.mem.Allocator, max_depth: usize) ParserFuzzer {
        return initWithIo(allocator, max_depth, std.Io.Threaded.global_single_threaded.io());
    }

    pub fn initWithIo(allocator: std.mem.Allocator, max_depth: usize, io: std.Io) ParserFuzzer {
        return .{
            .allocator = allocator,
            .max_depth = max_depth,
            .io = io,
        };
    }

    pub fn fuzz(self: *ParserFuzzer, input: []const u8) !FuzzResult {
        const start = std.Io.Clock.awake.now(self.io);

        // Actual implementation will call:
        // const parser = @import("parser").Parser;
        // const lexer = @import("lexer").Lexer;
        // var lex = lexer.init(self.allocator, input);
        // const tokens = try lex.tokenize();
        // var p = parser.init(self.allocator, tokens);
        // _ = try p.parse();

        return .{
            .passed = true,
            .execution_time_ns = @intCast(start.durationTo(std.Io.Clock.awake.now(self.io)).toNanoseconds()),
            .peak_memory = input.len * 4, // Approximate
        };
    }
};

/// Codec fuzzer for audio/video/image codecs
pub const CodecFuzzer = struct {
    allocator: std.mem.Allocator,
    codec_type: CodecType,
    io: std.Io,

    pub const CodecType = enum {
        jpeg,
        png,
        gif,
        wav,
        mp3,
        flac,
        h264,
        vp9,
        av1,
    };

    pub fn init(allocator: std.mem.Allocator, codec_type: CodecType) CodecFuzzer {
        return initWithIo(allocator, codec_type, std.Io.Threaded.global_single_threaded.io());
    }

    pub fn initWithIo(allocator: std.mem.Allocator, codec_type: CodecType, io: std.Io) CodecFuzzer {
        return .{
            .allocator = allocator,
            .codec_type = codec_type,
            .io = io,
        };
    }

    pub fn fuzz(self: *CodecFuzzer, input: []const u8) !FuzzResult {
        const start = std.Io.Clock.awake.now(self.io);

        // Validate minimum header size based on codec
        const min_size: usize = switch (self.codec_type) {
            .jpeg => 2, // SOI marker
            .png => 8, // PNG signature
            .gif => 6, // GIF header
            .wav => 44, // WAV header
            .mp3 => 4, // Frame header
            .flac => 4, // fLaC magic
            .h264 => 4, // NAL unit start
            .vp9, .av1 => 3, // Frame header
        };

        if (input.len < min_size) {
            return .{
                .passed = true, // Not a bug, just insufficient data
                .execution_time_ns = 0,
                .peak_memory = 0,
            };
        }

        // Actual decoding would happen here
        // Connected to packages/video, packages/audio, packages/image

        return .{
            .passed = true,
            .execution_time_ns = @intCast(start.durationTo(std.Io.Clock.awake.now(self.io)).toNanoseconds()),
            .peak_memory = input.len * 10, // Approximate decoded size
        };
    }
};

/// Network protocol fuzzer
pub const NetworkFuzzer = struct {
    allocator: std.mem.Allocator,
    protocol: Protocol,
    io: std.Io,

    pub const Protocol = enum {
        http,
        websocket,
        tcp,
        udp,
        dns,
        tls,
    };

    pub fn init(allocator: std.mem.Allocator, protocol: Protocol) NetworkFuzzer {
        return initWithIo(allocator, protocol, std.Io.Threaded.global_single_threaded.io());
    }

    pub fn initWithIo(allocator: std.mem.Allocator, protocol: Protocol, io: std.Io) NetworkFuzzer {
        return .{
            .allocator = allocator,
            .protocol = protocol,
            .io = io,
        };
    }

    pub fn fuzz(self: *NetworkFuzzer, input: []const u8) !FuzzResult {
        const start = std.Io.Clock.awake.now(self.io);

        // Protocol-specific validation
        _ = switch (self.protocol) {
            .http => self.fuzzHttp(input),
            .websocket => self.fuzzWebSocket(input),
            .tcp => self.fuzzTcp(input),
            .udp => self.fuzzUdp(input),
            .dns => self.fuzzDns(input),
            .tls => self.fuzzTls(input),
        } catch |err| {
            return .{
                .passed = false,
                .error_message = @errorName(err),
                .execution_time_ns = @intCast(start.durationTo(std.Io.Clock.awake.now(self.io)).toNanoseconds()),
                .peak_memory = 0,
            };
        };

        return .{
            .passed = true,
            .execution_time_ns = @intCast(start.durationTo(std.Io.Clock.awake.now(self.io)).toNanoseconds()),
            .peak_memory = input.len * 2,
        };
    }

    fn fuzzHttp(self: *NetworkFuzzer, input: []const u8) !void {
        _ = self;
        // Parse HTTP request/response
        // Check for buffer overflows, header injection, etc.
        if (input.len > 0 and std.mem.indexOf(u8, input, "\r\n\r\n") == null) {
            // Incomplete request - valid behavior
            return;
        }
    }

    fn fuzzWebSocket(self: *NetworkFuzzer, input: []const u8) !void {
        _ = self;
        // Parse WebSocket frame
        if (input.len < 2) return;
        // Validate frame header
    }

    fn fuzzTcp(self: *NetworkFuzzer, input: []const u8) !void {
        _ = self;
        // TCP segment validation
        if (input.len < 20) return; // Minimum TCP header
    }

    fn fuzzUdp(self: *NetworkFuzzer, input: []const u8) !void {
        _ = self;
        // UDP datagram validation
        if (input.len < 8) return; // Minimum UDP header
    }

    fn fuzzDns(self: *NetworkFuzzer, input: []const u8) !void {
        _ = self;
        // DNS message validation
        if (input.len < 12) return; // Minimum DNS header
    }

    fn fuzzTls(self: *NetworkFuzzer, input: []const u8) !void {
        _ = self;
        // TLS record validation
        if (input.len < 5) return; // Minimum TLS record header
    }
};

/// Crash deduplication using stack hashes
pub const CrashDeduplicator = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    seen_crashes: std.AutoHashMap(u64, CrashInfo),

    pub const CrashInfo = struct {
        hash: u64,
        input: []const u8,
        stack_trace: ?[]const u8,
        timestamp: i64,
    };

    pub fn init(allocator: std.mem.Allocator) CrashDeduplicator {
        return initWithIo(allocator, std.Io.Threaded.global_single_threaded.io());
    }

    pub fn initWithIo(allocator: std.mem.Allocator, io: std.Io) CrashDeduplicator {
        return .{
            .allocator = allocator,
            .io = io,
            .seen_crashes = std.AutoHashMap(u64, CrashInfo).init(allocator),
        };
    }

    pub fn deinit(self: *CrashDeduplicator) void {
        var iter = self.seen_crashes.valueIterator();
        while (iter.next()) |info| {
            self.allocator.free(info.input);
            if (info.stack_trace) |st| {
                self.allocator.free(st);
            }
        }
        self.seen_crashes.deinit();
    }

    /// Record a crash and return true if it's unique
    pub fn recordCrash(self: *CrashDeduplicator, hash: u64, input: []const u8, stack_trace: ?[]const u8) !bool {
        if (self.seen_crashes.contains(hash)) return false;

        const owned_input = try self.allocator.dupe(u8, input);
        errdefer self.allocator.free(owned_input);
        const owned_stack_trace = if (stack_trace) |st| try self.allocator.dupe(u8, st) else null;
        errdefer if (owned_stack_trace) |st| self.allocator.free(st);

        try self.seen_crashes.putNoClobber(hash, .{
            .hash = hash,
            .input = owned_input,
            .stack_trace = owned_stack_trace,
            .timestamp = std.Io.Clock.real.now(self.io).toMilliseconds(),
        });

        return true;
    }

    /// Get count of unique crashes
    pub fn uniqueCount(self: *const CrashDeduplicator) usize {
        return self.seen_crashes.count();
    }
};

/// Corpus manager for storing and loading test cases
pub const CorpusManager = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    corpus_dir: []const u8,
    corpus: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator, corpus_dir: []const u8) CorpusManager {
        return initWithIo(allocator, corpus_dir, std.Io.Threaded.global_single_threaded.io());
    }

    pub fn initWithIo(allocator: std.mem.Allocator, corpus_dir: []const u8, io: std.Io) CorpusManager {
        return .{
            .allocator = allocator,
            .io = io,
            .corpus_dir = corpus_dir,
            .corpus = .empty,
        };
    }

    pub fn deinit(self: *CorpusManager) void {
        for (self.corpus.items) |item| {
            self.allocator.free(item);
        }
        self.corpus.deinit(self.allocator);
        self.* = undefined;
    }

    /// Load corpus from directory
    pub fn load(self: *CorpusManager) !void {
        const dir = std.Io.Dir.cwd().openDir(self.io, self.corpus_dir, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return,
            else => return err,
        };
        defer dir.close(self.io);

        var iter = dir.iterateAssumeFirstIteration();
        while (try iter.next(self.io)) |entry| {
            if (entry.kind != .file) continue;

            const content = try dir.readFileAlloc(self.io, entry.name, self.allocator, .limited(1024 * 1024));
            errdefer self.allocator.free(content);
            try self.corpus.append(self.allocator, content);
        }
    }

    /// Save a test case to the corpus
    pub fn save(self: *CorpusManager, input: []const u8, name: []const u8) !void {
        try self.corpus.ensureUnusedCapacity(self.allocator, 1);
        const copy = try self.allocator.dupe(u8, input);
        errdefer self.allocator.free(copy);

        const dir = try std.Io.Dir.cwd().openDir(self.io, self.corpus_dir, .{});
        defer dir.close(self.io);

        const file = try dir.createFile(self.io, name, .{});
        defer file.close(self.io);

        try file.writeStreamingAll(self.io, input);

        self.corpus.appendAssumeCapacity(copy);
    }

    /// Get all corpus entries
    pub fn getCorpus(self: *const CorpusManager) []const []const u8 {
        return self.corpus.items;
    }
};

// Tests
test "fuzzer basic mutation" {
    const allocator = std.testing.allocator;

    const ctx = LexerFuzzer.init(allocator);
    var fuzzer = Fuzzer(LexerFuzzer).init(allocator, ctx, .{});

    const input = "let x = 42;";
    const mutated = try fuzzer.mutate(input);
    defer allocator.free(mutated);

    // Mutation should produce different output (usually)
    // Note: Could be same due to randomness, so we just check it doesn't crash
}

test "crash deduplicator" {
    const allocator = std.testing.allocator;

    var dedup = CrashDeduplicator.init(allocator);
    defer dedup.deinit();

    const is_unique1 = try dedup.recordCrash(0x12345678, "crash input 1", null);
    try std.testing.expect(is_unique1);

    const is_unique2 = try dedup.recordCrash(0x12345678, "crash input 1", null);
    try std.testing.expect(!is_unique2); // Duplicate

    const is_unique3 = try dedup.recordCrash(0x87654321, "crash input 2", null);
    try std.testing.expect(is_unique3);

    try std.testing.expectEqual(@as(usize, 2), dedup.uniqueCount());
}
