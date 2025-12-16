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
            return .{
                .context = context,
                .config = config,
                .allocator = allocator,
                .stats = .{ .start_time = std.time.milliTimestamp() },
            };
        }

        /// Run a single fuzz iteration with the given input
        pub fn runOne(self: *Self, input: []const u8) FuzzResult {
            const start_time = std.time.nanoTimestamp();
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
                        .execution_time_ns = @intCast(@as(i64, @intCast(std.time.nanoTimestamp())) - start_time),
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
            var prng = if (self.config.seed) |s|
                std.Random.DefaultPrng.init(s)
            else
                std.Random.DefaultPrng.init(@intCast(std.time.milliTimestamp()));

            const random = prng.random();
            var output = try self.allocator.alloc(u8, input.len);
            @memcpy(output, input);

            // Apply random mutation
            const mutation_type = random.intRangeAtMost(u8, 0, 5);
            switch (mutation_type) {
                0 => { // Bit flip
                    if (output.len > 0) {
                        const pos = random.intRangeLessThan(usize, 0, output.len);
                        const bit = random.intRangeLessThan(u3, 0, 8);
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
            const elapsed = std.time.milliTimestamp() - self.stats.start_time;
            const exec_per_sec = if (elapsed > 0) @as(f64, @floatFromInt(self.stats.total_runs)) / (@as(f64, @floatFromInt(elapsed)) / 1000.0) else 0;

            std.debug.print(
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

    pub fn init(allocator: std.mem.Allocator) LexerFuzzer {
        return .{ .allocator = allocator };
    }

    pub fn fuzz(self: *LexerFuzzer, input: []const u8) !FuzzResult {
        const start = std.time.nanoTimestamp();

        // Import lexer module and run tokenization
        // Note: This will be connected to the actual lexer
        _ = self;

        // Simulate lexer processing - actual implementation will call:
        // const lexer = @import("lexer").Lexer;
        // var lex = lexer.init(self.allocator, input);
        // while (lex.nextToken()) |_| {}

        const end = std.time.nanoTimestamp();
        return .{
            .passed = true,
            .execution_time_ns = @intCast(end - start),
            .peak_memory = input.len * 2, // Approximate
        };
    }
};

/// Parser fuzzer context
pub const ParserFuzzer = struct {
    allocator: std.mem.Allocator,
    max_depth: usize,

    pub fn init(allocator: std.mem.Allocator, max_depth: usize) ParserFuzzer {
        return .{
            .allocator = allocator,
            .max_depth = max_depth,
        };
    }

    pub fn fuzz(self: *ParserFuzzer, input: []const u8) !FuzzResult {
        const start = std.time.nanoTimestamp();

        // Actual implementation will call:
        // const parser = @import("parser").Parser;
        // const lexer = @import("lexer").Lexer;
        // var lex = lexer.init(self.allocator, input);
        // const tokens = try lex.tokenize();
        // var p = parser.init(self.allocator, tokens);
        // _ = try p.parse();

        _ = self;
        const end = std.time.nanoTimestamp();
        return .{
            .passed = true,
            .execution_time_ns = @intCast(end - start),
            .peak_memory = input.len * 4, // Approximate
        };
    }
};

/// Codec fuzzer for audio/video/image codecs
pub const CodecFuzzer = struct {
    allocator: std.mem.Allocator,
    codec_type: CodecType,

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
        return .{
            .allocator = allocator,
            .codec_type = codec_type,
        };
    }

    pub fn fuzz(self: *CodecFuzzer, input: []const u8) !FuzzResult {
        const start = std.time.nanoTimestamp();

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

        const end = std.time.nanoTimestamp();
        return .{
            .passed = true,
            .execution_time_ns = @intCast(end - start),
            .peak_memory = input.len * 10, // Approximate decoded size
        };
    }
};

/// Network protocol fuzzer
pub const NetworkFuzzer = struct {
    allocator: std.mem.Allocator,
    protocol: Protocol,

    pub const Protocol = enum {
        http,
        websocket,
        tcp,
        udp,
        dns,
        tls,
    };

    pub fn init(allocator: std.mem.Allocator, protocol: Protocol) NetworkFuzzer {
        return .{
            .allocator = allocator,
            .protocol = protocol,
        };
    }

    pub fn fuzz(self: *NetworkFuzzer, input: []const u8) !FuzzResult {
        const start = std.time.nanoTimestamp();

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
                .execution_time_ns = @intCast(std.time.nanoTimestamp() - start),
                .peak_memory = 0,
            };
        };

        const end = std.time.nanoTimestamp();
        return .{
            .passed = true,
            .execution_time_ns = @intCast(end - start),
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
    seen_crashes: std.StringHashMap(CrashInfo),

    pub const CrashInfo = struct {
        hash: u64,
        input: []const u8,
        stack_trace: ?[]const u8,
        timestamp: i64,
    };

    pub fn init(allocator: std.mem.Allocator) CrashDeduplicator {
        return .{
            .allocator = allocator,
            .seen_crashes = std.StringHashMap(CrashInfo).init(allocator),
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
        var hash_str: [16]u8 = undefined;
        _ = std.fmt.bufPrint(&hash_str, "{x:0>16}", .{hash}) catch return false;

        const result = try self.seen_crashes.getOrPut(&hash_str);
        if (result.found_existing) {
            return false; // Duplicate crash
        }

        result.value_ptr.* = .{
            .hash = hash,
            .input = try self.allocator.dupe(u8, input),
            .stack_trace = if (stack_trace) |st| try self.allocator.dupe(u8, st) else null,
            .timestamp = std.time.milliTimestamp(),
        };

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
    corpus_dir: []const u8,
    corpus: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator, corpus_dir: []const u8) CorpusManager {
        return .{
            .allocator = allocator,
            .corpus_dir = corpus_dir,
            .corpus = std.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *CorpusManager) void {
        for (self.corpus.items) |item| {
            self.allocator.free(item);
        }
        self.corpus.deinit();
    }

    /// Load corpus from directory
    pub fn load(self: *CorpusManager) !void {
        var dir = std.fs.cwd().openDir(self.corpus_dir, .{ .iterate = true }) catch return;
        defer dir.close();

        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind != .file) continue;

            const file = try dir.openFile(entry.name, .{});
            defer file.close();

            const content = try file.readToEndAlloc(self.allocator, 1024 * 1024);
            try self.corpus.append(content);
        }
    }

    /// Save a test case to the corpus
    pub fn save(self: *CorpusManager, input: []const u8, name: []const u8) !void {
        var dir = try std.fs.cwd().openDir(self.corpus_dir, .{});
        defer dir.close();

        const file = try dir.createFile(name, .{});
        defer file.close();

        try file.writeAll(input);

        // Also keep in memory
        const copy = try self.allocator.dupe(u8, input);
        try self.corpus.append(copy);
    }

    /// Get all corpus entries
    pub fn getCorpus(self: *const CorpusManager) []const []const u8 {
        return self.corpus.items;
    }
};

// Tests
test "fuzzer basic mutation" {
    const allocator = std.testing.allocator;

    var ctx = LexerFuzzer.init(allocator);
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
