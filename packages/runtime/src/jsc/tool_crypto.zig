//! OS entropy and managed streaming SHA-256 for the repository tool.
const std = @import("std");
const api = @import("extern_fns.zig");
const types = @import("opaques.zig");
const callback = @import("callback.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;
const state_length = 32 + 64 + 1 + 8;

// A canonical private state carries no allocator, pointer, struct padding or
// uninitialized tail bytes. JS owns its lifetime; copying it forks the digest.
fn encodeState(hasher: *const Sha256) [state_length]u8 {
    var bytes: [state_length]u8 = @splat(0);
    for (hasher.s, 0..) |word, index| std.mem.writeInt(u32, bytes[index * 4 ..][0..4], word, .big);
    @memcpy(bytes[32..][0..hasher.buf_len], hasher.buf[0..hasher.buf_len]);
    bytes[96] = hasher.buf_len;
    std.mem.writeInt(u64, bytes[97..105], hasher.total_len, .big);
    return bytes;
}

fn decodeState(bytes: *const [state_length]u8) ?Sha256 {
    if (bytes[96] >= 64) return null;
    var hasher = Sha256.init(.{});
    for (&hasher.s, 0..) |*word, index| word.* = std.mem.readInt(u32, bytes[index * 4 ..][0..4], .big);
    hasher.buf_len = bytes[96];
    hasher.total_len = std.mem.readInt(u64, bytes[97..105], .big);
    if (hasher.total_len % 64 != hasher.buf_len) return null;
    @memcpy(hasher.buf[0..hasher.buf_len], bytes[32..][0..hasher.buf_len]);
    return hasher;
}

fn managedBytes(ctx: *types.JSContextRef, bytes: []const u8, exception: api.ExceptionRef) ?*types.JSValue {
    const result = api.JSObjectMakeTypedArray(ctx, .kJSTypedArrayTypeUint8Array, bytes.len, exception) orelse return null;
    const raw = api.JSObjectGetTypedArrayBytesPtr(ctx, result, exception) orelse return null;
    @memcpy(@as([*]u8, @ptrCast(raw))[0..bytes.len], bytes);
    return @ptrCast(result);
}

fn sha256(
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
    if (count < 1 or args[0] == null) return api.JSValueMakeBoolean(c, false);
    const mode = api.JSValueToNumber(c, args[0], exception);
    if (mode == 0 and count == 1) {
        const hasher = Sha256.init(.{});
        return managedBytes(c, &encodeState(&hasher), exception);
    }
    if ((mode != 1 and mode != 2) or count != (if (mode == 1) @as(usize, 3) else 2) or
        args[1] == null or api.JSValueGetTypedArrayType(c, args[1], exception) != .kJSTypedArrayTypeUint8Array)
        return api.JSValueMakeBoolean(c, false);
    const state = api.JSValueToObject(c, args[1], exception) orelse return null;
    if (api.JSObjectGetTypedArrayByteLength(c, state, exception) != state_length) return api.JSValueMakeBoolean(c, false);
    const raw = api.JSObjectGetTypedArrayBytesPtr(c, state, exception) orelse return null;
    // Decode before another JS call can invalidate the borrowed managed view.
    const state_bytes: *const [state_length]u8 = @ptrCast(raw);
    var hasher = decodeState(state_bytes) orelse return api.JSValueMakeBoolean(c, false);
    if (mode == 2) {
        var digest: [Sha256.digest_length]u8 = undefined;
        hasher.final(&digest);
        return managedBytes(c, &digest, exception);
    }
    if (args[2] == null or api.JSValueGetTypedArrayType(c, args[2], exception) != .kJSTypedArrayTypeUint8Array)
        return api.JSValueMakeBoolean(c, false);
    const input = api.JSValueToObject(c, args[2], exception) orelse return null;
    const length = api.JSObjectGetTypedArrayByteLength(c, input, exception);
    const offset = api.JSObjectGetTypedArrayByteOffset(c, input, exception);
    if (length != 0) {
        const input_raw = api.JSObjectGetTypedArrayBytesPtr(c, input, exception) orelse return null;
        // JSC returns the backing buffer pointer; consume only the view window.
        hasher.update(@as([*]const u8, @ptrCast(input_raw))[offset..][0..length]);
    }
    const next = encodeState(&hasher);
    const target = api.JSObjectGetTypedArrayBytesPtr(c, state, exception) orelse return null;
    @memcpy(@as([*]u8, @ptrCast(target))[0..state_length], &next);
    return api.JSValueMakeBoolean(c, true);
}

fn randomBytes(
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
    if (count != 1 or args[0] == null or api.JSValueGetTypedArrayType(c, args[0], exception) != .kJSTypedArrayTypeUint8Array)
        return api.JSValueMakeBoolean(c, false);
    const object = api.JSValueToObject(c, args[0], exception) orelse return api.JSValueMakeBoolean(c, false);
    const length = api.JSObjectGetTypedArrayByteLength(c, object, exception);
    if (length == 0) return api.JSValueMakeBoolean(c, true);
    const raw = api.JSObjectGetTypedArrayBytesPtr(c, object, exception) orelse return api.JSValueMakeBoolean(c, false);
    const bytes: [*]u8 = @ptrCast(raw);
    // Unlike Io.random, randomSecure never substitutes a weak seed when the
    // OS entropy source fails. No JS calls occur while the borrowed view is held.
    const io = std.Io.Threaded.global_single_threaded.io();
    io.randomSecure(bytes[0..length]) catch return api.JSValueMakeBoolean(c, false);
    return api.JSValueMakeBoolean(c, true);
}

pub fn install(ctx: *types.JSContextRef, global: *types.JSGlobalObject) void {
    callback.registerCallback(ctx, global, "__home_tool_random_bytes", randomBytes);
    callback.registerCallback(ctx, global, "__home_tool_sha256", sha256);
}

test "managed SHA256 state round trips all block boundaries and copies" {
    var data: [300]u8 = undefined;
    for (&data, 0..) |*byte, index| byte.* = "abc"[index % 3];
    var expected: [32]u8 = undefined;
    Sha256.hash(&data, &expected, .{});
    for (0..data.len + 1) |split| {
        var hasher = Sha256.init(.{});
        hasher.update(data[0..split]);
        const saved = encodeState(&hasher);
        var restored = decodeState(&saved).?;
        restored.update(data[split..]);
        var actual: [32]u8 = undefined;
        restored.final(&actual);
        try std.testing.expectEqualSlices(u8, &expected, &actual);
        try std.testing.expectEqualSlices(u8, &saved, &encodeState(&hasher));
    }
    var invalid = encodeState(&Sha256.init(.{}));
    invalid[96] = 64;
    try std.testing.expect(decodeState(&invalid) == null);
    invalid[96] = 1;
    try std.testing.expect(decodeState(&invalid) == null);
}
