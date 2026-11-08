//! Bounded RFC 1952 data operations for the repository-tool host.
const std = @import("std");
const api = @import("extern_fns.zig");
const types = @import("opaques.zig");
const callback = @import("callback.zig");

pub const max_bytes = 2 * 1024 * 1024;

pub fn compress(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    if (input.len > max_bytes) return error.LimitExceeded;
    const storage = try allocator.alloc(u8, input.len + input.len / 8 + 1024);
    errdefer allocator.free(storage);
    var output: std.Io.Writer = .fixed(storage);
    const history = try allocator.alloc(u8, std.compress.flate.max_window_len);
    defer allocator.free(history);
    const compressor = try allocator.create(std.compress.flate.Compress);
    defer allocator.destroy(compressor);
    compressor.* = try .init(&output, history, .gzip, .default);
    try compressor.writer.writeAll(input);
    try compressor.finish();
    return try allocator.realloc(storage, output.end);
}

// stdlib's decoder exposes footer metadata rather than verifying it. Check
// RFC 1952 header flags/header CRC and each member's data CRC/ISIZE ourselves.
fn header(input: []const u8) !void {
    if (input.len >= 2 and !std.mem.eql(u8, input[0..2], &.{ 0x1f, 0x8b })) return error.BadHeader;
    if (input.len >= 4 and (input[2] != 8 or input[3] & 0xe0 != 0)) return error.BadHeader;
    if (input.len < 10) return error.TruncatedInput;
    var end: usize = 10;
    if (input[3] & 4 != 0) {
        if (input.len - end < 2) return error.TruncatedInput;
        const length = std.mem.readInt(u16, input[end..][0..2], .little);
        end += 2;
        if (input.len - end < length) return error.TruncatedInput;
        end += length;
    }
    for ([_]u8{ 8, 16 }) |flag| {
        if (input[3] & flag == 0) continue;
        const length = std.mem.indexOfScalar(u8, input[end..], 0) orelse return error.TruncatedInput;
        end += length + 1;
    }
    if (input[3] & 2 != 0) {
        if (input.len - end < 2) return error.TruncatedInput;
        if (@as(u16, @truncate(std.hash.Crc32.hash(input[0..end]))) != std.mem.readInt(u16, input[end..][0..2], .little))
            return error.BadHeaderChecksum;
    }
}

pub fn decompress(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    if (input.len > max_bytes + max_bytes / 8 + 1024) return error.LimitExceeded;
    if (input.len == 0) return error.TruncatedInput;
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    var offset: usize = 0;
    while (offset < input.len) {
        // Node accepts zero padding after the final member, but not a member
        // hidden after that padding or arbitrary trailing bytes.
        if (offset != 0 and input[offset] == 0) {
            if (!std.mem.allEqual(u8, input[offset..], 0)) return error.BadHeader;
            break;
        }
        try header(input[offset..]);
        var source: std.Io.Reader = .fixed(input[offset..]);
        const history = try allocator.alloc(u8, std.compress.flate.max_window_len);
        defer allocator.free(history);
        var decoder: std.compress.flate.Decompress = .init(&source, .gzip, history);
        const bytes = decoder.reader.allocRemaining(allocator, .limited(max_bytes - result.items.len)) catch |err| {
            if (err == error.StreamTooLong) return error.LimitExceeded;
            if (decoder.err) |reason| {
                if (reason == error.EndOfStream) return error.TruncatedInput;
                return reason;
            }
            return err;
        };
        defer allocator.free(bytes);
        const metadata = decoder.container_metadata.gzip;
        if (metadata.crc != std.hash.Crc32.hash(bytes)) return error.BadDataChecksum;
        if (metadata.count != @as(u32, @truncate(bytes.len))) return error.BadDataSize;
        if (source.seek == 0) return error.BadHeader;
        offset += source.seek;
        try result.appendSlice(allocator, bytes);
    }
    return try result.toOwnedSlice(allocator);
}

fn failure(ctx: *types.JSContextRef, err: anyerror) ?*types.JSValue {
    const code: [:0]const u8 = switch (err) {
        error.LimitExceeded => "ERR_BUFFER_TOO_LARGE",
        error.TruncatedInput => "Z_BUF_ERROR",
        error.OutOfMemory => "ERR_HOME_COMPRESSION",
        else => "Z_DATA_ERROR",
    };
    const text = api.JSStringCreateWithUTF8CString(code.ptr) orelse return null;
    defer api.JSStringRelease(text);
    return api.JSValueMakeString(ctx, text);
}

fn operation(
    ctx: ?*types.JSContextRef,
    function: ?*types.JSObject,
    this: ?*types.JSObject,
    count: usize,
    args: [*c]const ?*types.JSValue,
    exception: api.ExceptionRef,
) callconv(.c) ?*types.JSValue {
    _ = function;
    _ = this;
    const c = ctx orelse return null;
    if (count != 2 or args[0] == null or args[1] == null or api.JSValueGetTypedArrayType(c, args[1], exception) != .kJSTypedArrayTypeUint8Array)
        return failure(c, error.BadInput);
    const mode = api.JSValueToNumber(c, args[0], exception);
    if (mode != 0 and mode != 1) return failure(c, error.BadInput);
    const object = api.JSValueToObject(c, args[1], exception) orelse return null;
    const length = api.JSObjectGetTypedArrayByteLength(c, object, exception);
    if (length > max_bytes + max_bytes / 8 + 1024) return failure(c, error.LimitExceeded);
    const allocator = std.heap.smp_allocator;
    const raw = if (length != 0) api.JSObjectGetTypedArrayBytesPtr(c, object, exception) orelse return null else null;
    const borrowed: []const u8 = if (raw) |p| @as([*]const u8, @ptrCast(p))[0..length] else &.{};
    // The managed view can relocate when the result is allocated. Copy it
    // before any further JS allocation and never retain a borrowed pointer.
    const input = allocator.dupe(u8, borrowed) catch return failure(c, error.OutOfMemory);
    defer allocator.free(input);
    const output = (if (mode == 0) compress(allocator, input) else decompress(allocator, input)) catch |err| return failure(c, err);
    defer allocator.free(output);
    const result = api.JSObjectMakeTypedArray(c, .kJSTypedArrayTypeUint8Array, output.len, exception) orelse return null;
    if (output.len != 0) {
        const target = api.JSObjectGetTypedArrayBytesPtr(c, result, exception) orelse return null;
        @memcpy(@as([*]u8, @ptrCast(target))[0..output.len], output);
    }
    return @ptrCast(result);
}

pub fn install(ctx: *types.JSContextRef, global: *types.JSGlobalObject) void {
    callback.registerCallback(ctx, global, "__home_tool_gzip", operation);
}

test "gzip members validate actual bytes, checksum, size and truncation" {
    const allocator = std.testing.allocator;
    const encoded = try compress(allocator, "actual bytes\x00\xffactual bytes");
    defer allocator.free(encoded);
    const decoded = try decompress(allocator, encoded);
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings("actual bytes\x00\xffactual bytes", decoded);
    encoded[encoded.len - 8] ^= 1;
    try std.testing.expectError(error.BadDataChecksum, decompress(allocator, encoded));
    encoded[encoded.len - 8] ^= 1;
    encoded[encoded.len - 4] ^= 1;
    try std.testing.expectError(error.BadDataSize, decompress(allocator, encoded));
    encoded[encoded.len - 4] ^= 1;
    for (0..encoded.len) |length|
        try std.testing.expectError(error.TruncatedInput, decompress(allocator, encoded[0..length]));
}

test "gzip concatenated members and bounded decompression" {
    const allocator = std.testing.allocator;
    const a = try compress(allocator, "first");
    defer allocator.free(a);
    const b = try compress(allocator, "second");
    defer allocator.free(b);
    const input = try std.mem.concat(allocator, u8, &.{ a, b, &.{ 0, 0 } });
    defer allocator.free(input);
    const decoded = try decompress(allocator, input);
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings("firstsecond", decoded);
    const big = try allocator.alloc(u8, max_bytes);
    defer allocator.free(big);
    @memset(big, 'a');
    const encoded_big = try compress(allocator, big);
    defer allocator.free(encoded_big);
    const bomb = try std.mem.concat(allocator, u8, &.{ encoded_big, encoded_big });
    defer allocator.free(bomb);
    try std.testing.expectError(error.LimitExceeded, decompress(allocator, bomb));
}

test "gzip optional header fields verify their header CRC and reject reserved flags" {
    const allocator = std.testing.allocator;
    const encoded = try compress(allocator, "header fields");
    defer allocator.free(encoded);
    const prefix = try std.mem.concat(allocator, u8, &.{ encoded[0..10], &.{ 2, 0, 7, 9 }, "file\x00comment\x00" });
    defer allocator.free(prefix);
    prefix[3] = 0x1e;
    const checksum: u16 = @truncate(std.hash.Crc32.hash(prefix));
    const input = try std.mem.concat(allocator, u8, &.{ prefix, &.{ @truncate(checksum), @truncate(checksum >> 8) }, encoded[10..] });
    defer allocator.free(input);
    const decoded = try decompress(allocator, input);
    defer allocator.free(decoded);
    try std.testing.expectEqualStrings("header fields", decoded);
    input[prefix.len] ^= 1;
    try std.testing.expectError(error.BadHeaderChecksum, decompress(allocator, input));
    input[3] |= 0x20;
    try std.testing.expectError(error.BadHeader, decompress(allocator, input));
    try std.testing.expectError(error.BadHeader, decompress(allocator, &.{ 0, 0 }));
}
