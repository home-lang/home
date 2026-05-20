// Home Runtime - Phase 12.7 `node:string_decoder` Zig substrate.
//
// Bun exposes this through its Node compatibility layer; the upstream fallback
// delegates to the npm `string_decoder` package when the native binding is not
// available. This file keeps the JSC-free part native for Home: an allocator
// owned decoder that preserves incomplete trailing bytes across writes and
// flushes them with Node-compatible replacement/grouping rules.

const std = @import("std");
const buffer = @import("buffer.zig");

const replacement = "\xef\xbf\xbd";

pub const Encoding = buffer.Encoding;

pub const StringDecoder = struct {
    allocator: std.mem.Allocator,
    encoding: Encoding,
    pending: [8]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
    pending_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator, encoding: Encoding) StringDecoder {
        return .{
            .allocator = allocator,
            .encoding = normalizeEncoding(encoding),
        };
    }

    pub fn write(self: *StringDecoder, chunk: []const u8) ![]u8 {
        return switch (self.encoding) {
            .utf8 => self.writeUtf8(chunk),
            .utf16le, .ucs2 => self.writeUtf16Le(chunk),
            .base64 => self.writeBase64(chunk, false),
            .base64url => self.writeBase64(chunk, true),
            .hex => encodeHex(self.allocator, chunk),
            .ascii => encodeAscii(self.allocator, chunk),
            .latin1, .binary => encodeLatin1(self.allocator, chunk),
        };
    }

    pub fn end(self: *StringDecoder) ![]u8 {
        return switch (self.encoding) {
            .utf8 => self.endUtf8(),
            .utf16le, .ucs2 => self.endUtf16Le(),
            .base64 => self.endBase64(false),
            .base64url => self.endBase64(true),
            .hex, .ascii, .latin1, .binary => self.allocator.alloc(u8, 0),
        };
    }

    pub fn endWith(self: *StringDecoder, final_chunk: []const u8) ![]u8 {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(self.allocator);

        const written = try self.write(final_chunk);
        defer self.allocator.free(written);
        try out.appendSlice(self.allocator, written);

        const flushed = try self.end();
        defer self.allocator.free(flushed);
        try out.appendSlice(self.allocator, flushed);

        return try out.toOwnedSlice(self.allocator);
    }

    pub fn text(self: *StringDecoder, chunk: []const u8, offset: usize) ![]u8 {
        if (offset >= chunk.len) return self.allocator.alloc(u8, 0);
        return self.write(chunk[offset..]);
    }

    fn writeUtf8(self: *StringDecoder, chunk: []const u8) ![]u8 {
        var input_buf: [self.pending.len + 4096]u8 = undefined;
        var input: []const u8 = chunk;
        if (self.pending_len > 0) {
            if (chunk.len > input_buf.len - self.pending_len) {
                var heap = try self.allocator.alloc(u8, self.pending_len + chunk.len);
                defer self.allocator.free(heap);
                @memcpy(heap[0..self.pending_len], self.pending[0..self.pending_len]);
                @memcpy(heap[self.pending_len..], chunk);
                self.pending_len = 0;
                return self.decodeUtf8(heap);
            }
            @memcpy(input_buf[0..self.pending_len], self.pending[0..self.pending_len]);
            @memcpy(input_buf[self.pending_len .. self.pending_len + chunk.len], chunk);
            input = input_buf[0 .. self.pending_len + chunk.len];
            self.pending_len = 0;
        }
        return self.decodeUtf8(input);
    }

    fn decodeUtf8(self: *StringDecoder, input: []const u8) ![]u8 {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(self.allocator);

        var index: usize = 0;
        while (index < input.len) {
            const first = input[index];
            if (first < 0x80) {
                try out.append(self.allocator, first);
                index += 1;
                continue;
            }

            const len = utf8ExpectedLen(first) orelse {
                if (isInvalidTrailingLead(input[index..])) {
                    self.savePending(input[index..]);
                    break;
                }
                try out.appendSlice(self.allocator, replacement);
                index += 1;
                continue;
            };

            const remaining = input.len - index;
            if (remaining < len) {
                if (validUtf8Prefix(input[index..])) {
                    self.savePending(input[index..]);
                    break;
                }
                try out.appendSlice(self.allocator, replacement);
                index += 1;
                continue;
            }

            const candidate = input[index .. index + len];
            if (validUtf8Scalar(candidate)) {
                try out.appendSlice(self.allocator, candidate);
                index += len;
            } else {
                try out.appendSlice(self.allocator, replacement);
                index += 1;
            }
        }

        return try out.toOwnedSlice(self.allocator);
    }

    fn endUtf8(self: *StringDecoder) ![]u8 {
        if (self.pending_len == 0) return self.allocator.alloc(u8, 0);
        if (utf8ExpectedLen(self.pending[0]) == null) {
            var out = std.ArrayList(u8).empty;
            errdefer out.deinit(self.allocator);
            for (0..self.pending_len) |_| try out.appendSlice(self.allocator, replacement);
            self.pending_len = 0;
            return try out.toOwnedSlice(self.allocator);
        }

        self.pending_len = 0;
        return self.allocator.dupe(u8, replacement);
    }

    fn writeUtf16Le(self: *StringDecoder, chunk: []const u8) ![]u8 {
        var combined: [12]u8 = undefined;
        var input: []const u8 = chunk;
        var carried_pending = false;
        if (self.pending_len > 0 and chunk.len <= combined.len - self.pending_len) {
            @memcpy(combined[0..self.pending_len], self.pending[0..self.pending_len]);
            @memcpy(combined[self.pending_len .. self.pending_len + chunk.len], chunk);
            input = combined[0 .. self.pending_len + chunk.len];
            self.pending_len = 0;
            carried_pending = true;
        } else if (self.pending_len > 0) {
            var heap = try self.allocator.alloc(u8, self.pending_len + chunk.len);
            defer self.allocator.free(heap);
            @memcpy(heap[0..self.pending_len], self.pending[0..self.pending_len]);
            @memcpy(heap[self.pending_len..], chunk);
            self.pending_len = 0;
            return self.decodeUtf16Le(heap, true);
        }
        return self.decodeUtf16Le(input, carried_pending);
    }

    fn decodeUtf16Le(self: *StringDecoder, input: []const u8, carried_pending: bool) ![]u8 {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(self.allocator);

        var index: usize = 0;
        while (index + 1 < input.len) {
            const unit = readU16Le(input[index .. index + 2]);

            if (isHighSurrogate(unit)) {
                if (index + 3 >= input.len) {
                    if (input.len - index == 2) {
                        self.savePending(input[index..]);
                    } else if (carried_pending) {
                        self.savePending(input[index..]);
                    } else {
                        try appendWtf8Unit(self.allocator, &out, unit);
                    }
                    index = input.len;
                    break;
                }

                const next = readU16Le(input[index + 2 .. index + 4]);
                if (isLowSurrogate(next)) {
                    try appendCodepoint(self.allocator, &out, surrogateCodepoint(unit, next));
                    index += 4;
                    continue;
                }

                try appendWtf8Unit(self.allocator, &out, unit);
                index += 2;
                continue;
            }

            if (isLowSurrogate(unit)) {
                try appendWtf8Unit(self.allocator, &out, unit);
            } else {
                try appendCodepoint(self.allocator, &out, unit);
            }
            index += 2;
        }

        if (index < input.len) self.savePending(input[index..]);
        return try out.toOwnedSlice(self.allocator);
    }

    fn endUtf16Le(self: *StringDecoder) ![]u8 {
        if (self.pending_len >= 2) {
            const unit = readU16Le(self.pending[0..2]);
            self.pending_len = 0;
            return encodeWtf8Unit(self.allocator, unit);
        }

        self.pending_len = 0;
        return self.allocator.alloc(u8, 0);
    }

    fn writeBase64(self: *StringDecoder, chunk: []const u8, url_safe: bool) ![]u8 {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(self.allocator);

        var index: usize = 0;
        if (self.pending_len > 0) {
            while (self.pending_len < 3 and index < chunk.len) : (index += 1) {
                self.pending[self.pending_len] = chunk[index];
                self.pending_len += 1;
            }
            if (self.pending_len == 3) {
                const encoded = try encodeBase64(self.allocator, self.pending[0..3], url_safe);
                defer self.allocator.free(encoded);
                try out.appendSlice(self.allocator, encoded);
                self.pending_len = 0;
            }
        }

        const complete_len = ((chunk.len - index) / 3) * 3;
        if (complete_len > 0) {
            const encoded = try encodeBase64(self.allocator, chunk[index .. index + complete_len], url_safe);
            defer self.allocator.free(encoded);
            try out.appendSlice(self.allocator, encoded);
            index += complete_len;
        }

        if (index < chunk.len) {
            self.savePending(chunk[index..]);
        }

        return try out.toOwnedSlice(self.allocator);
    }

    fn endBase64(self: *StringDecoder, url_safe: bool) ![]u8 {
        defer self.pending_len = 0;
        if (self.pending_len == 0) return self.allocator.alloc(u8, 0);
        return encodeBase64(self.allocator, self.pending[0..self.pending_len], url_safe);
    }

    fn savePending(self: *StringDecoder, bytes: []const u8) void {
        std.debug.assert(bytes.len <= self.pending.len);
        @memcpy(self.pending[0..bytes.len], bytes);
        self.pending_len = bytes.len;
    }
};

fn normalizeEncoding(encoding: Encoding) Encoding {
    return switch (encoding) {
        .ucs2 => .utf16le,
        .binary => .latin1,
        else => encoding,
    };
}

fn utf8ExpectedLen(first: u8) ?usize {
    return switch (first) {
        0xc2...0xdf => 2,
        0xe0...0xef => 3,
        0xf0...0xf4 => 4,
        else => null,
    };
}

fn validUtf8Prefix(bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    const len = utf8ExpectedLen(bytes[0]) orelse return false;
    if (bytes.len >= len) return validUtf8Scalar(bytes[0..len]);
    var index: usize = 1;
    while (index < bytes.len) : (index += 1) {
        if (!isContinuation(bytes[index])) return false;
        if (!validContinuationForPosition(bytes[0], bytes[index], index)) return false;
    }
    return true;
}

fn validUtf8Scalar(bytes: []const u8) bool {
    const len = utf8ExpectedLen(bytes[0]) orelse return false;
    if (bytes.len != len) return false;
    var index: usize = 1;
    while (index < bytes.len) : (index += 1) {
        if (!isContinuation(bytes[index])) return false;
        if (!validContinuationForPosition(bytes[0], bytes[index], index)) return false;
    }
    return true;
}

fn validContinuationForPosition(first: u8, byte: u8, index: usize) bool {
    if (index != 1) return true;
    return switch (first) {
        0xe0 => byte >= 0xa0,
        0xed => byte <= 0x9f,
        0xf0 => byte >= 0x90,
        0xf4 => byte <= 0x8f,
        else => true,
    };
}

fn isContinuation(byte: u8) bool {
    return byte >= 0x80 and byte <= 0xbf;
}

fn isInvalidTrailingLead(bytes: []const u8) bool {
    if (bytes.len == 0 or bytes[0] <= 0xf4) return false;
    for (bytes[1..]) |byte| {
        if (!isContinuation(byte)) return false;
    }
    return true;
}

fn encodeHex(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const hex = "0123456789abcdef";
    const out = try allocator.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |byte, index| {
        out[index * 2] = hex[byte >> 4];
        out[index * 2 + 1] = hex[byte & 0x0f];
    }
    return out;
}

fn encodeAscii(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, bytes.len);
    for (bytes, 0..) |byte, index| out[index] = byte & 0x7f;
    return out;
}

fn encodeLatin1(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    for (bytes) |byte| try appendCodepoint(allocator, &out, byte);
    return try out.toOwnedSlice(allocator);
}

fn encodeBase64(allocator: std.mem.Allocator, bytes: []const u8, url_safe: bool) ![]u8 {
    if (url_safe) {
        const encoder = std.base64.url_safe_no_pad.Encoder;
        const out = try allocator.alloc(u8, encoder.calcSize(bytes.len));
        _ = encoder.encode(out, bytes);
        return out;
    }

    const encoder = std.base64.standard.Encoder;
    const out = try allocator.alloc(u8, encoder.calcSize(bytes.len));
    _ = encoder.encode(out, bytes);
    return out;
}

fn readU16Le(bytes: []const u8) u16 {
    return @as(u16, bytes[0]) | (@as(u16, bytes[1]) << 8);
}

fn isHighSurrogate(unit: u16) bool {
    return unit >= 0xd800 and unit <= 0xdbff;
}

fn isLowSurrogate(unit: u16) bool {
    return unit >= 0xdc00 and unit <= 0xdfff;
}

fn surrogateCodepoint(high: u16, low: u16) u21 {
    const hi = @as(u21, high - 0xd800);
    const lo = @as(u21, low - 0xdc00);
    return 0x10000 + ((hi << 10) | lo);
}

fn appendCodepoint(allocator: std.mem.Allocator, out: *std.ArrayList(u8), codepoint: u21) !void {
    var buf: [4]u8 = undefined;
    const len = try std.unicode.utf8Encode(codepoint, &buf);
    try out.appendSlice(allocator, buf[0..len]);
}

fn appendWtf8Unit(allocator: std.mem.Allocator, out: *std.ArrayList(u8), unit: u16) !void {
    const encoded = try encodeWtf8Unit(allocator, unit);
    defer allocator.free(encoded);
    try out.appendSlice(allocator, encoded);
}

fn encodeWtf8Unit(allocator: std.mem.Allocator, unit: u16) ![]u8 {
    if (!isHighSurrogate(unit) and !isLowSurrogate(unit)) {
        var out = std.ArrayList(u8).empty;
        try appendCodepoint(allocator, &out, unit);
        return try out.toOwnedSlice(allocator);
    }

    const out = try allocator.alloc(u8, 3);
    out[0] = 0xe0 | @as(u8, @intCast(unit >> 12));
    out[1] = 0x80 | @as(u8, @intCast((unit >> 6) & 0x3f));
    out[2] = 0x80 | @as(u8, @intCast(unit & 0x3f));
    return out;
}

const testing = std.testing;

test "StringDecoder utf8 preserves split scalars" {
    var decoder = StringDecoder.init(testing.allocator, .utf8);

    const part = try decoder.write(&[_]u8{ 0xe2, 0x82 });
    defer testing.allocator.free(part);
    try testing.expectEqualStrings("", part);

    const done = try decoder.write(&[_]u8{0xac});
    defer testing.allocator.free(done);
    try testing.expectEqualStrings("€", done);

    const end = try decoder.end();
    defer testing.allocator.free(end);
    try testing.expectEqualStrings("", end);
}

test "StringDecoder utf8 flushes incomplete input with replacement" {
    var decoder = StringDecoder.init(testing.allocator, .utf8);

    const part = try decoder.write(&[_]u8{ 0xe1, 0x8b });
    defer testing.allocator.free(part);
    try testing.expectEqualStrings("", part);

    const end = try decoder.end();
    defer testing.allocator.free(end);
    try testing.expectEqualStrings(replacement, end);
}

test "StringDecoder utf8 replaces invalid continuation and keeps new pending lead" {
    var decoder = StringDecoder.init(testing.allocator, .utf8);

    const first = try decoder.write(&[_]u8{0xf1});
    defer testing.allocator.free(first);
    try testing.expectEqualStrings("", first);

    const second = try decoder.write(&[_]u8{ 0x41, 0xf2 });
    defer testing.allocator.free(second);
    try testing.expectEqualStrings(replacement ++ "A", second);

    const end = try decoder.end();
    defer testing.allocator.free(end);
    try testing.expectEqualStrings(replacement, end);
}

test "StringDecoder utf8 flushes invalid trailing lead bytes individually" {
    var decoder = StringDecoder.init(testing.allocator, .utf8);

    const first = try decoder.write(&[_]u8{ 0x36, 0xf5, 0x9c });
    defer testing.allocator.free(first);
    try testing.expectEqualStrings("6", first);

    const end = try decoder.end();
    defer testing.allocator.free(end);
    try testing.expectEqualStrings(replacement ++ replacement, end);
}

test "StringDecoder endWith writes final utf8 chunk before flushing" {
    var decoder = StringDecoder.init(testing.allocator, .utf8);

    const first = try decoder.write(&[_]u8{ 0x36, 0xf5 });
    defer testing.allocator.free(first);
    try testing.expectEqualStrings("6", first);

    const end = try decoder.endWith(&[_]u8{0x9c});
    defer testing.allocator.free(end);
    try testing.expectEqualStrings(replacement ++ replacement, end);
}

test "StringDecoder utf16le joins surrogate pair across writes" {
    var decoder = StringDecoder.init(testing.allocator, .utf16le);

    const first = try decoder.write(&[_]u8{ 0x3d, 0xd8 });
    defer testing.allocator.free(first);
    try testing.expectEqualStrings("", first);

    const second = try decoder.write(&[_]u8{0x4d});
    defer testing.allocator.free(second);
    try testing.expectEqualStrings("", second);

    const third = try decoder.write(&[_]u8{0xdc});
    defer testing.allocator.free(third);
    try testing.expectEqualStrings("👍", third);
}

test "StringDecoder utf16le emits high surrogate before odd trailing byte" {
    var decoder = StringDecoder.init(testing.allocator, .utf16le);

    const first = try decoder.write(&[_]u8{ 0x3d, 0xd8, 0x4d });
    defer testing.allocator.free(first);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xed, 0xa0, 0xbd }, first);

    const end = try decoder.end();
    defer testing.allocator.free(end);
    try testing.expectEqualStrings("", end);
}

test "StringDecoder utf16le flushes lone high surrogate as WTF-8" {
    var decoder = StringDecoder.init(testing.allocator, .utf16le);

    const first = try decoder.write(&[_]u8{ 0x3d, 0xd8 });
    defer testing.allocator.free(first);
    try testing.expectEqualStrings("", first);

    const end = try decoder.end();
    defer testing.allocator.free(end);
    try testing.expectEqualSlices(u8, &[_]u8{ 0xed, 0xa0, 0xbd }, end);
}

test "StringDecoder base64 buffers partial triples" {
    var decoder = StringDecoder.init(testing.allocator, .base64);

    const first = try decoder.write("a");
    defer testing.allocator.free(first);
    try testing.expectEqualStrings("", first);

    const second = try decoder.write("aa");
    defer testing.allocator.free(second);
    try testing.expectEqualStrings("YWFh", second);

    const third = try decoder.write("a");
    defer testing.allocator.free(third);
    try testing.expectEqualStrings("", third);

    const end = try decoder.end();
    defer testing.allocator.free(end);
    try testing.expectEqualStrings("YQ==", end);
}

test "StringDecoder base64url omits padding" {
    var decoder = StringDecoder.init(testing.allocator, .base64url);

    const first = try decoder.write("a");
    defer testing.allocator.free(first);
    try testing.expectEqualStrings("", first);

    const end = try decoder.end();
    defer testing.allocator.free(end);
    try testing.expectEqualStrings("YQ", end);
}

test "StringDecoder hex ascii and latin1 encodings" {
    var hex_decoder = StringDecoder.init(testing.allocator, .hex);
    const hex = try hex_decoder.write(&[_]u8{ 0xde, 0xad, 0xbe, 0xef });
    defer testing.allocator.free(hex);
    try testing.expectEqualStrings("deadbeef", hex);

    var ascii_decoder = StringDecoder.init(testing.allocator, .ascii);
    const ascii = try ascii_decoder.write(&[_]u8{ 0xc1, 0x42 });
    defer testing.allocator.free(ascii);
    try testing.expectEqualSlices(u8, &[_]u8{ 0x41, 0x42 }, ascii);

    var latin1_decoder = StringDecoder.init(testing.allocator, .latin1);
    const latin1 = try latin1_decoder.write(&[_]u8{ 0xa3 });
    defer testing.allocator.free(latin1);
    try testing.expectEqualStrings("£", latin1);
}
