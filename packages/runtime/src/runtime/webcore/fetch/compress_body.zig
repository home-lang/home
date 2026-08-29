//! JS option parsing; the HTTP-thread implementation owns compression buffers.
const bun = @import("home");
const jsc = bun.jsc;
const compression = @import("../../../http/compress_body.zig");
pub const CompressOption = compression.CompressOption;
const CompressEncoding = compression.CompressEncoding;

const encodings = bun.ComptimeStringMap(CompressEncoding, .{
    .{ "gzip", .gzip }, .{ "deflate", .deflate }, .{ "br", .br }, .{ "zstd", .zstd },
});

fn encodingFromJS(global: *jsc.JSGlobalObject, value: jsc.JSValue) bun.JSError!?CompressEncoding {
    const string = try value.toSlice(global, bun.default_allocator);
    defer string.deinit();
    return encodings.get(string.slice());
}

pub fn fromJS(global: *jsc.JSGlobalObject, value: jsc.JSValue) bun.JSError!?CompressOption {
    if (value.isUndefinedOrNull()) return null;
    if (value.isBoolean()) return if (value.asBoolean()) .{ .encoding = .gzip } else null;
    if (value.isString()) {
        const encoding = try encodingFromJS(global, value) orelse
            return global.throwInvalidArguments("fetch: 'compress' must be \"gzip\", \"deflate\", \"br\", or \"zstd\"", .{});
        return .{ .encoding = encoding };
    }
    if (value.isObject()) {
        const enc = try value.get(global, "encoding") orelse .js_undefined;
        if (!enc.isString()) return global.throwInvalidArgumentTypeValue("compress.encoding", "string", enc);
        const encoding = try encodingFromJS(global, enc) orelse
            return global.throwInvalidArguments("fetch: 'compress.encoding' must be \"gzip\", \"deflate\", \"br\", or \"zstd\"", .{});
        var level: ?i32 = null;
        if (try value.get(global, "level")) |lvl| {
            if (!lvl.isUndefinedOrNull()) {
                level = switch (encoding) {
                    .gzip, .deflate => try global.validateIntegerRange(lvl, i32, compression.default_deflate_level, .{ .min = 0, .max = 12, .field_name = "compress.level", .always_allow_zero = false }),
                    .br => try global.validateIntegerRange(lvl, i32, compression.default_brotli_quality, .{ .min = 0, .max = 11, .field_name = "compress.level", .always_allow_zero = false }),
                    .zstd => try global.validateIntegerRange(lvl, i32, compression.default_zstd_level, .{ .min = 1, .max = 22, .field_name = "compress.level", .always_allow_zero = false }),
                };
            }
        }
        return .{ .encoding = encoding, .level = level };
    }
    return global.throwInvalidArgumentTypeValue("compress", "boolean, string, or object", value);
}
