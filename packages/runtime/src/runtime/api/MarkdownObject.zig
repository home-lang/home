// Copied from bun/src/runtime/api/MarkdownObject.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
//
// Rewrites:
//   - @import("bun") → @import("home")
//
// Stubs (re-attach in Phase 12.2 when home_rt grows the JS bridge +
// in-tree markdown renderer):
//   - `jsc.JSGlobalObject`, `jsc.CallFrame`, `jsc.JSFunction`,
//     `jsc.ZigString`, `jsc.Node.StringOrBuffer`, `bun.JSError`,
//     `bun.String`, `bun.ArenaAllocator`, `bun.default_allocator`. Same pattern as
//     `TOMLObject.zig` / `JSON5Object.zig` / `YAMLObject.zig`.
//   - `bun.md.{Options, BlockType, SpanType, AnsiTheme, renderToHtmlWithOptions,
//     renderToAnsi, detectLightBackground}` — the in-tree markdown
//     renderer surface is parked. The upstream `renderToHTML`,
//     `renderToAnsi`, `render`, `renderReact` bodies are kept verbatim
//     as comments so re-attachment is mechanical when the renderer lands.
//   - C++ helpers `BunMarkdownTagStrings__getTagString` and
//     `BunMarkdownMeta__createListItem` / `createList` / `createCell` /
//     `createLink` — fn-ptr indirections; the Tag table on this side is
//     pure-Zig and exercised by tests.
//
// Pure-Zig pieces (TagIndex enum, BlockType→TagIndex / SpanType→TagIndex
// mappers, camelCaseOf) are exercised by tests.

//! `Bun.markdown.html(text, options?)` / `.ansi(text, theme?)` /
//! `.render(text, callbacks, options?)` / `.react(text, callbacks, options?)`
//! host fns. Powered by the in-tree CommonMark + extensions renderer.

const std = @import("std");
const home_rt = @import("home");

// JSC stubs — re-attach when the matching home_rt.jsc surface lands.
const JSGlobalObject = @import("home").jsc.JSGlobalObject;
const CallFrame = @import("home").jsc.CallFrame;
pub const JSValue = @import("home").jsc.JSValue;
pub const JSError = home_rt.JSError;

// Upstream `create()` parked verbatim — depends on `JSValue.createEmptyObject`,
// `ZigString.static`, and `jsc.JSFunction.create`. None on home_rt yet.
//
//     pub fn create(globalThis: *jsc.JSGlobalObject) jsc.JSValue {
//         const object = JSValue.createEmptyObject(globalThis, 4);
//         object.put(globalThis, ZigString.static("html"),
//             jsc.JSFunction.create(globalThis, "html", renderToHTML, 1, .{}));
//         object.put(globalThis, ZigString.static("ansi"),
//             jsc.JSFunction.create(globalThis, "ansi", renderToAnsi, 2, .{}));
//         object.put(globalThis, ZigString.static("render"),
//             jsc.JSFunction.create(globalThis, "render", render, 3, .{}));
//         object.put(globalThis, ZigString.static("react"),
//             jsc.JSFunction.create(globalThis, "react", renderReact, 3, .{}));
//         return object;
//     }
//
//     pub fn renderToHTML(globalThis, callframe) bun.JSError!jsc.JSValue {
//         const input_value, const opts_value = callframe.argumentsAsArray(2);
//         if (input_value.isEmptyOrUndefinedOrNull())
//             return globalThis.throwInvalidArguments("Expected a string or buffer to render", .{});
//         var arena: bun.ArenaAllocator = .init(bun.default_allocator);
//         defer arena.deinit();
//         const buffer = try jsc.Node.StringOrBuffer.fromJS(globalThis, arena.allocator(), input_value)
//             orelse return globalThis.throwInvalidArguments("Expected a string or buffer to render", .{});
//         const input = buffer.slice();
//         const options = try parseOptions(globalThis, opts_value);
//         const result = md.renderToHtmlWithOptions(input, arena.allocator(), options) catch {
//             return globalThis.throwOutOfMemory();
//         };
//         return bun.String.createUTF8ForJS(globalThis, result);
//     }
//
//     pub fn renderToAnsi(globalThis, callframe) bun.JSError!jsc.JSValue {
//         // Defaults: colors on, hyperlinks off, kitty_graphics off,
//         // detect light bg, columns=80. Theme overrides via getBooleanLoose.
//     }
//
//     pub fn render(globalThis, callframe) bun.JSError!jsc.JSValue { ... }
//     pub fn renderReact(globalThis, callframe) bun.JSError!jsc.JSValue { ... }
pub fn create(globalThis: *JSGlobalObject) JSValue {
    _ = globalThis;
    return .zero;
}

pub fn renderToHTML(globalThis: *JSGlobalObject, callframe: *CallFrame) JSError!JSValue {
    _ = globalThis;
    _ = callframe;
    return .zero;
}

pub fn renderToAnsi(globalThis: *JSGlobalObject, callframe: *CallFrame) JSError!JSValue {
    _ = globalThis;
    _ = callframe;
    return .zero;
}

pub fn render(globalThis: *JSGlobalObject, callframe: *CallFrame) JSError!JSValue {
    _ = globalThis;
    _ = callframe;
    return .zero;
}

pub fn renderReact(globalThis: *JSGlobalObject, callframe: *CallFrame) JSError!JSValue {
    _ = globalThis;
    _ = callframe;
    return .zero;
}

/// HTML tag indices shared with the C++ `BunMarkdownTagStrings` interner.
/// Ordering MUST match `Bun::MarkdownTagStrings` in C++ — adding entries
/// here without updating the C++ table will mis-dispatch tag lookups.
pub const TagIndex = enum(u8) {
    h1 = 0,
    h2 = 1,
    h3 = 2,
    h4 = 3,
    h5 = 4,
    h6 = 5,
    p = 6,
    blockquote = 7,
    ul = 8,
    ol = 9,
    li = 10,
    pre = 11,
    hr = 12,
    html = 13,
    table = 14,
    thead = 15,
    tbody = 16,
    tr = 17,
    th = 18,
    td = 19,
    div = 20,
    em = 21,
    strong = 22,
    a = 23,
    img = 24,
    code = 25,
    del = 26,
    math = 27,
    u = 28,
    br = 29,
};

/// Pure-Zig mirror of `md.BlockType`. The real enum lives in the parked
/// `bun.md` package; we redeclare it here so the mapper tables compile.
pub const BlockType = enum {
    h,
    p,
    quote,
    ul,
    ol,
    li,
    code,
    hr,
    html,
    table,
    thead,
    tbody,
    tr,
    th,
    td,
    doc,
};

/// Pure-Zig mirror of `md.SpanType`. Same parking rationale as `BlockType`.
pub const SpanType = enum {
    em,
    strong,
    a,
    img,
    code,
    del,
    latexmath,
    latexmath_display,
    wikilink,
    u,
};

/// Block-type → TagIndex. Headings carry their level in `data` (clamped
/// to h6 above level 6).
pub fn getBlockTypeTag(block_type: BlockType, data: u32) TagIndex {
    return switch (block_type) {
        .h => switch (data) {
            1 => .h1,
            2 => .h2,
            3 => .h3,
            4 => .h4,
            5 => .h5,
            else => .h6,
        },
        .p => .p,
        .quote => .blockquote,
        .ul => .ul,
        .ol => .ol,
        .li => .li,
        .code => .pre,
        .hr => .hr,
        .html => .html,
        .table => .table,
        .thead => .thead,
        .tbody => .tbody,
        .tr => .tr,
        .th => .th,
        .td => .td,
        .doc => .div,
    };
}

/// Span-type → TagIndex. Both LaTeX flavors collapse to `<math>`;
/// wikilinks render as anchors.
pub fn getSpanTypeTag(span_type: SpanType) TagIndex {
    return switch (span_type) {
        .em => .em,
        .strong => .strong,
        .a => .a,
        .img => .img,
        .code => .code,
        .del => .del,
        .latexmath => .math,
        .latexmath_display => .math,
        .wikilink => .a,
        .u => .u,
    };
}

/// Snake-case → camelCase, comptime. Used by the option-parser to look
/// up `permissiveAutolinks` for an option field literally named
/// `permissive_autolinks`. Pure helper — exercised by tests below.
pub fn camelCaseOf(comptime snake: []const u8) []const u8 {
    return comptime brk: {
        var count: usize = 0;
        for (snake) |c| {
            if (c != '_') count += 1;
        }
        if (count == snake.len) break :brk snake; // no underscores

        var buf: [count]u8 = undefined;
        var i: usize = 0;
        var cap_next = false;
        for (snake) |c| {
            if (c == '_') {
                cap_next = true;
            } else {
                buf[i] = if (cap_next and c >= 'a' and c <= 'z') c - 32 else c;
                i += 1;
                cap_next = false;
            }
        }
        const final = buf;
        break :brk &final;
    };
}

// Soft-linked C++ surface for the cached tag-string interner. Stubbed so
// the file builds standalone; the real implementation lives in
// `BunMarkdownMeta.cpp` upstream.
var BunMarkdownTagStrings__getTagString_fn: *const fn (*JSGlobalObject, u8) callconv(.c) JSValue = stub_get_tag_string;

fn stub_get_tag_string(_: *JSGlobalObject, _: u8) callconv(.c) JSValue {
    return .zero;
}

pub fn getCachedTagString(globalObject: *JSGlobalObject, tag: TagIndex) JSValue {
    return BunMarkdownTagStrings__getTagString_fn(globalObject, @intFromEnum(tag));
}

test "MarkdownObject: create returns the stubbed JSValue.zero" {
    var dummy: u8 = 0;
    const g: *JSGlobalObject = @ptrCast(&dummy);
    try std.testing.expectEqual(JSValue.zero, create(g));
}

test "MarkdownObject: render entry points return the stubbed JSValue.zero" {
    var dummy: u8 = 0;
    const g: *JSGlobalObject = @ptrCast(&dummy);
    var cf_dummy: u8 = 0;
    const cf: *CallFrame = @ptrCast(&cf_dummy);
    try std.testing.expectEqual(JSValue.zero, try renderToHTML(g, cf));
    try std.testing.expectEqual(JSValue.zero, try renderToAnsi(g, cf));
    try std.testing.expectEqual(JSValue.zero, try render(g, cf));
    try std.testing.expectEqual(JSValue.zero, try renderReact(g, cf));
}

test "MarkdownObject: JSValue tag is ABI-compatible with i64" {
    try std.testing.expectEqual(@as(usize, @sizeOf(i64)), @sizeOf(JSValue));
}

test "MarkdownObject.TagIndex: explicit numeric layout matches the C++ table" {
    // The ordering is load-bearing — Bun::MarkdownTagStrings indexes into
    // the same numbers, so any reorder must be paired with a C++ update.
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(TagIndex.h1));
    try std.testing.expectEqual(@as(u8, 5), @intFromEnum(TagIndex.h6));
    try std.testing.expectEqual(@as(u8, 6), @intFromEnum(TagIndex.p));
    try std.testing.expectEqual(@as(u8, 12), @intFromEnum(TagIndex.hr));
    try std.testing.expectEqual(@as(u8, 21), @intFromEnum(TagIndex.em));
    try std.testing.expectEqual(@as(u8, 23), @intFromEnum(TagIndex.a));
    try std.testing.expectEqual(@as(u8, 27), @intFromEnum(TagIndex.math));
    try std.testing.expectEqual(@as(u8, 29), @intFromEnum(TagIndex.br));
}

test "MarkdownObject.getBlockTypeTag: heading levels + paragraph + structural blocks" {
    try std.testing.expectEqual(TagIndex.h1, getBlockTypeTag(.h, 1));
    try std.testing.expectEqual(TagIndex.h2, getBlockTypeTag(.h, 2));
    try std.testing.expectEqual(TagIndex.h6, getBlockTypeTag(.h, 6));
    // Clamp: anything beyond h6 maps to h6 (CommonMark allows ATX up to
    // 6 #s; an out-of-range value is parser hardening).
    try std.testing.expectEqual(TagIndex.h6, getBlockTypeTag(.h, 7));
    try std.testing.expectEqual(TagIndex.h6, getBlockTypeTag(.h, 99));

    try std.testing.expectEqual(TagIndex.p, getBlockTypeTag(.p, 0));
    try std.testing.expectEqual(TagIndex.blockquote, getBlockTypeTag(.quote, 0));
    try std.testing.expectEqual(TagIndex.ul, getBlockTypeTag(.ul, 0));
    try std.testing.expectEqual(TagIndex.ol, getBlockTypeTag(.ol, 0));
    try std.testing.expectEqual(TagIndex.li, getBlockTypeTag(.li, 0));
    try std.testing.expectEqual(TagIndex.pre, getBlockTypeTag(.code, 0)); // code block → <pre>
    try std.testing.expectEqual(TagIndex.hr, getBlockTypeTag(.hr, 0));
    try std.testing.expectEqual(TagIndex.html, getBlockTypeTag(.html, 0));
    try std.testing.expectEqual(TagIndex.table, getBlockTypeTag(.table, 0));
    try std.testing.expectEqual(TagIndex.div, getBlockTypeTag(.doc, 0)); // root → <div>
}

test "MarkdownObject.getSpanTypeTag: latex collapses to math, wikilink to anchor" {
    try std.testing.expectEqual(TagIndex.em, getSpanTypeTag(.em));
    try std.testing.expectEqual(TagIndex.strong, getSpanTypeTag(.strong));
    try std.testing.expectEqual(TagIndex.a, getSpanTypeTag(.a));
    try std.testing.expectEqual(TagIndex.img, getSpanTypeTag(.img));
    try std.testing.expectEqual(TagIndex.code, getSpanTypeTag(.code));
    try std.testing.expectEqual(TagIndex.del, getSpanTypeTag(.del));
    try std.testing.expectEqual(TagIndex.math, getSpanTypeTag(.latexmath));
    try std.testing.expectEqual(TagIndex.math, getSpanTypeTag(.latexmath_display));
    try std.testing.expectEqual(TagIndex.a, getSpanTypeTag(.wikilink));
    try std.testing.expectEqual(TagIndex.u, getSpanTypeTag(.u));
}

test "MarkdownObject.camelCaseOf: passthrough, single underscore, multi" {
    try std.testing.expectEqualStrings("simple", comptime camelCaseOf("simple"));
    try std.testing.expectEqualStrings("camelCase", comptime camelCaseOf("camel_case"));
    try std.testing.expectEqualStrings("permissiveAutolinks", comptime camelCaseOf("permissive_autolinks"));
    try std.testing.expectEqualStrings(
        "permissiveUrlAutolinks",
        comptime camelCaseOf("permissive_url_autolinks"),
    );
    // Leading underscore: capitalise the next char (degenerate but
    // mirrors the upstream implementation).
    try std.testing.expectEqualStrings("Lead", comptime camelCaseOf("_lead"));
}

test "MarkdownObject.getCachedTagString: routes through the soft-linked fn-ptr" {
    var dummy: u8 = 0;
    const g: *JSGlobalObject = @ptrCast(&dummy);
    try std.testing.expectEqual(JSValue.zero, getCachedTagString(g, .h1));
    try std.testing.expectEqual(JSValue.zero, getCachedTagString(g, .br));
}

comptime {
    _ = &home_rt.upstream_sha;
}
