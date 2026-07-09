//! Provenance manifest for Bun's native Node URL/assert/util and Web
//! text-encoding source slice.
//!
//! This module records copied Bun Zig sources without adding replacement JS
//! behavior. The listed implementations are promoted into runnable Home
//! surfaces only when their JSC/generated-module dependencies compile here.

const std = @import("std");

pub const upstream_sha = "fd0b6f1a271fca0b8124b69f230b100f4d636af6";

pub const Slice = enum {
    url,
    text_encoding,
    node_assert,
    node_util,
    node_error,
};

pub const PortStatus = enum {
    verbatim,
    adapted,
    js_source_required,
};

pub const SourceFile = struct {
    slice: Slice,
    upstream: []const u8,
    local: []const u8,
    status: PortStatus,
    note: []const u8,
};

pub const sources = [_]SourceFile{
    .{ .slice = .url, .upstream = "bun/src/url/url.zig", .local = "packages/runtime/src/url/url.zig", .status = .verbatim, .note = "WHATWG/native URL backing copied from Bun." },
    .{ .slice = .url, .upstream = "bun/src/jsc/URL.zig", .local = "packages/runtime/src/jsc/URL.zig", .status = .verbatim, .note = "JSC URL host binding copied from Bun." },
    .{ .slice = .url, .upstream = "bun/src/jsc/URLSearchParams.zig", .local = "packages/runtime/src/jsc/URLSearchParams.zig", .status = .verbatim, .note = "JSC URLSearchParams host binding copied from Bun." },
    .{ .slice = .text_encoding, .upstream = "bun/src/jsc/TextCodec.zig", .local = "packages/runtime/src/jsc/TextCodec.zig", .status = .verbatim, .note = "TextCodec host binding copied from Bun." },
    .{ .slice = .text_encoding, .upstream = "bun/src/runtime/webcore/encoding.zig", .local = "packages/runtime/src/runtime/webcore/encoding.zig", .status = .verbatim, .note = "TextEncoder/TextDecoder byte conversion helpers copied from Bun." },
    .{ .slice = .node_assert, .upstream = "bun/src/runtime/node/node_assert.zig", .local = "packages/runtime/src/runtime/node/node_assert.zig", .status = .verbatim, .note = "Native node:assert diff implementation copied from Bun." },
    .{ .slice = .node_assert, .upstream = "bun/src/runtime/node/node_assert_binding.zig", .local = "packages/runtime/src/runtime/node/node_assert_binding.zig", .status = .verbatim, .note = "Native node:assert JSC binding copied from Bun." },
    .{ .slice = .node_assert, .upstream = "bun/src/runtime/node/assert/myers_diff.zig", .local = "packages/runtime/src/runtime/node/assert/myers_diff.zig", .status = .verbatim, .note = "Shared assert diff primitive copied from Bun." },
    .{ .slice = .node_util, .upstream = "bun/src/runtime/node/node_util_binding.zig", .local = "packages/runtime/src/runtime/node/node_util_binding.zig", .status = .verbatim, .note = "Native node:util binding copied from Bun." },
    .{ .slice = .node_util, .upstream = "bun/src/runtime/node/util/parse_args.zig", .local = "packages/runtime/src/runtime/node/util/parse_args.zig", .status = .adapted, .note = "Copied util.parseArgs implementation with Zig 0.17 array-repeat syntax adaptation." },
    .{ .slice = .node_util, .upstream = "bun/src/runtime/node/util/parse_args_utils.zig", .local = "packages/runtime/src/runtime/node/util/parse_args_utils.zig", .status = .verbatim, .note = "util.parseArgs helper types copied from Bun." },
    .{ .slice = .node_util, .upstream = "bun/src/runtime/node/util/validators.zig", .local = "packages/runtime/src/runtime/node/util/validators.zig", .status = .verbatim, .note = "Native util validators copied from Bun." },
    .{ .slice = .node_error, .upstream = "bun/src/runtime/node/nodejs_error_code.zig", .local = "packages/runtime/src/runtime/node/nodejs_error_code.zig", .status = .verbatim, .note = "Native Node error-code table copied from Bun." },
    .{ .slice = .node_util, .upstream = "bun/src/js/node/querystring.ts", .local = "pending-js-hardcoded-module-migration", .status = .js_source_required, .note = "Bun implements node:querystring in JS, not Zig; this must be copied as a hardcoded module source asset." },
};

test "manifest records Node URL/assert/util/text-encoding Bun source provenance" {
    try std.testing.expectEqualStrings("fd0b6f1a271fca0b8124b69f230b100f4d636af6", upstream_sha);
    try std.testing.expect(sources.len >= 10);

    var saw = std.EnumSet(Slice).empty;
    var saw_js_source_required = false;

    for (sources) |entry| {
        try std.testing.expect(std.mem.startsWith(u8, entry.upstream, "bun/src/"));
        try std.testing.expect(entry.local.len > 0);
        try std.testing.expect(entry.note.len > 0);
        saw.insert(entry.slice);
        if (entry.status == .js_source_required) saw_js_source_required = true;
    }

    try std.testing.expect(saw.contains(.url));
    try std.testing.expect(saw.contains(.text_encoding));
    try std.testing.expect(saw.contains(.node_assert));
    try std.testing.expect(saw.contains(.node_util));
    try std.testing.expect(saw.contains(.node_error));
    try std.testing.expect(saw_js_source_required);
}
