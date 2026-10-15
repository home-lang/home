const std = @import("std");
const fuzz = @import("fuzz");

fn containsEntry(entries: []const []const u8, expected: []const u8) bool {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry, expected)) return true;
    }
    return false;
}

test "all public fuzz contexts use the injected clocks" {
    std.testing.refAllDecls(fuzz);
    std.testing.refAllDecls(fuzz.Fuzzer(fuzz.LexerFuzzer));

    var lexer = fuzz.LexerFuzzer.initWithIo(std.testing.allocator, std.testing.io);
    const lexer_result = try lexer.fuzz("let value = 1");
    try std.testing.expect(lexer_result.passed);

    var parser = fuzz.ParserFuzzer.initWithIo(std.testing.allocator, 32, std.testing.io);
    const parser_result = try parser.fuzz("value + 1");
    try std.testing.expect(parser_result.passed);

    var codec = fuzz.CodecFuzzer.initWithIo(std.testing.allocator, .png, std.testing.io);
    const codec_result = try codec.fuzz("\x89PNG\r\n\x1a\n");
    try std.testing.expect(codec_result.passed);

    var network = fuzz.NetworkFuzzer.initWithIo(std.testing.allocator, .http, std.testing.io);
    const network_result = try network.fuzz("GET / HTTP/1.1\r\n\r\n");
    try std.testing.expect(network_result.passed);

    var runner = fuzz.Fuzzer(fuzz.LexerFuzzer).initWithIo(
        std.testing.allocator,
        lexer,
        .{ .seed = 42 },
        std.testing.io,
    );
    const run_result = runner.runOne("const answer = 42");
    try std.testing.expect(run_result.passed);
    try std.testing.expectEqual(@as(u64, 1), runner.getStats().total_runs);
}

test "crash deduplication owns inputs and rejects duplicate hashes" {
    var dedup = fuzz.CrashDeduplicator.initWithIo(std.testing.allocator, std.testing.io);
    defer dedup.deinit();

    var input = [_]u8{ 1, 2, 3 };
    var stack = [_]u8{ 4, 5, 6 };
    try std.testing.expect(try dedup.recordCrash(7, &input, &stack));
    input[0] = 9;
    stack[0] = 9;

    const stored = dedup.seen_crashes.get(7).?;
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, stored.input);
    try std.testing.expectEqualSlices(u8, &.{ 4, 5, 6 }, stored.stack_trace.?);
    try std.testing.expect(!try dedup.recordCrash(7, "different", null));
}

fn recordCrashesWithAllocator(allocator: std.mem.Allocator) !void {
    var dedup = fuzz.CrashDeduplicator.initWithIo(allocator, std.testing.io);
    defer dedup.deinit();
    try std.testing.expect(try dedup.recordCrash(1, "first", "stack one"));
    try std.testing.expect(try dedup.recordCrash(2, "second", "stack two"));
}

test "crash deduplication releases partial allocations" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        recordCrashesWithAllocator,
        .{},
    );
}

const CorpusContext = struct {
    root: []const u8,
    io: std.Io,
};

fn loadCorpusWithAllocator(allocator: std.mem.Allocator, context: CorpusContext) !void {
    var corpus = fuzz.CorpusManager.initWithIo(allocator, context.root, context.io);
    defer corpus.deinit();
    try corpus.load();
    try std.testing.expectEqual(@as(usize, 2), corpus.getCorpus().len);
    try std.testing.expect(containsEntry(corpus.getCorpus(), "alpha"));
    try std.testing.expect(containsEntry(corpus.getCorpus(), "beta"));
}

test "corpus manager loads and saves through explicit IO" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "one", .data = "alpha" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "two", .data = "beta" });
    try tmp.dir.createDir(std.testing.io, "ignored", .default_dir);

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    var corpus = fuzz.CorpusManager.initWithIo(std.testing.allocator, root, std.testing.io);
    defer corpus.deinit();
    try corpus.load();
    try std.testing.expectEqual(@as(usize, 2), corpus.getCorpus().len);

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        loadCorpusWithAllocator,
        .{CorpusContext{ .root = root, .io = std.testing.io }},
    );

    try corpus.save("gamma", "three");
    try std.testing.expectEqual(@as(usize, 3), corpus.getCorpus().len);

    const persisted = try tmp.dir.readFileAlloc(std.testing.io, "three", std.testing.allocator, .limited(32));
    defer std.testing.allocator.free(persisted);
    try std.testing.expectEqualStrings("gamma", persisted);
}

test "missing corpus directory is an empty corpus" {
    var corpus = fuzz.CorpusManager.initWithIo(
        std.testing.allocator,
        "does-not-exist-home-fuzz-corpus",
        std.testing.io,
    );
    defer corpus.deinit();
    try corpus.load();
    try std.testing.expectEqual(@as(usize, 0), corpus.getCorpus().len);
}
