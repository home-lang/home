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

const JSGlobalObject = @import("home").jsc.JSGlobalObject;
const CallFrame = @import("home").jsc.CallFrame;
pub const JSValue = @import("home").jsc.JSValue;
pub const JSError = home_rt.JSError;

// Re-attached 2026-06-27: the in-tree markdown renderer (`home_rt.md`) has
// landed, so `create`/`renderToHTML`/`renderToAnsi`/`parseOptions` are wired
// to it (was all `JSValue.zero` stubs — `Bun.markdown` PANICKED via the lazy
// getter contract). `render`/`react` still throw (they need the parked C++
// BunMarkdownMeta callbacks), but cleanly rather than crashing.
const bun = home_rt;
const jsc = home_rt.jsc;
const ZigString = jsc.ZigString;
const StringOrBuffer = jsc.Node.StringOrBuffer;
const md = home_rt.md;

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
    const object = JSValue.createEmptyObject(globalThis, 4);
    object.put(globalThis, ZigString.static("html"), jsc.JSFunction.create(globalThis, "html", renderToHTML, 1, .{}));
    object.put(globalThis, ZigString.static("ansi"), jsc.JSFunction.create(globalThis, "ansi", renderToAnsi, 2, .{}));
    object.put(globalThis, ZigString.static("render"), jsc.JSFunction.create(globalThis, "render", render, 3, .{}));
    object.put(globalThis, ZigString.static("react"), jsc.JSFunction.create(globalThis, "react", renderReact, 3, .{}));
    return object;
}

pub fn renderToHTML(globalThis: *JSGlobalObject, callframe: *CallFrame) JSError!JSValue {
    const input_value, const opts_value = callframe.argumentsAsArray(2);
    if (input_value.isEmptyOrUndefinedOrNull()) {
        return globalThis.throwInvalidArguments("Expected a string or buffer to render", .{});
    }
    var arena: bun.ArenaAllocator = .init(bun.default_allocator);
    defer arena.deinit();
    const buffer = try StringOrBuffer.fromJS(globalThis, arena.allocator(), input_value) orelse {
        return globalThis.throwInvalidArguments("Expected a string or buffer to render", .{});
    };
    const input = buffer.slice();
    const options = try parseOptions(globalThis, opts_value);
    const result = md.renderToHtmlWithOptions(input, arena.allocator(), options) catch {
        return globalThis.throwOutOfMemory();
    };
    return bun.String.createUTF8ForJS(globalThis, result);
}

/// `Bun.markdown.ansi(text, theme?)` — render markdown to an ANSI-colored
/// terminal string. The ANSI renderer (`home_rt.md.renderToAnsi` →
/// ansi_renderer.zig) still has unported deps (the QuickAndDirty JS syntax
/// highlighter), so wiring it would drag in non-compiling code. Throw cleanly
/// until that lands — NOT `.zero` (which would crash via the host-call assert).
pub fn renderToAnsi(globalThis: *JSGlobalObject, callframe: *CallFrame) JSError!JSValue {
    const input_value, const theme_value = callframe.argumentsAsArray(2);

    if (input_value.isEmptyOrUndefinedOrNull()) {
        return globalThis.throwInvalidArguments("Expected a string or buffer to render", .{});
    }

    var arena: bun.ArenaAllocator = .init(bun.default_allocator);
    defer arena.deinit();

    const buffer = try jsc.Node.StringOrBuffer.fromJS(globalThis, arena.allocator(), input_value) orelse {
        return globalThis.throwInvalidArguments("Expected a string or buffer to render", .{});
    };

    const input = buffer.slice();

    var theme: md.AnsiTheme = .{
        .colors = true,
        .hyperlinks = false,
        .kitty_graphics = false,
        .light = md.detectLightBackground(),
        .columns = 80,
    };
    if (theme_value.isObject()) {
        if (try theme_value.getBooleanLoose(globalThis, "colors")) |v| theme.colors = v;
        if (try theme_value.getBooleanLoose(globalThis, "hyperlinks")) |v| theme.hyperlinks = v;
        if (try theme_value.getBooleanLoose(globalThis, "kittyGraphics")) |v| theme.kitty_graphics = v;
        if (try theme_value.getBooleanLoose(globalThis, "light")) |v| theme.light = v;
        if (try theme_value.get(globalThis, "columns")) |cols| {
            if (cols.isNumber()) {
                const n = cols.toInt32();
                theme.columns = if (n <= 0) 0 else @intCast(@min(n, std.math.maxInt(u16)));
            }
        }
    }

    const result = md.renderToAnsi(input, arena.allocator(), .terminal, theme) catch |err| switch (err) {
        error.OutOfMemory => return globalThis.throwOutOfMemory(),
        error.StackOverflow => return globalThis.throwStackOverflow(),
    } orelse {
        // The parser can only return null via JSError / JSTerminated
        // from a renderer callback; the ANSI renderer has none, so this
        // path is unreachable but handle it safely.
        return globalThis.throwOutOfMemory();
    };

    return bun.String.createUTF8ForJS(globalThis, result);
}

fn parseOptions(globalThis: *JSGlobalObject, opts_value: JSValue) JSError!md.Options {
    @setEvalBranchQuota(10_000);
    var options: md.Options = .{};
    if (opts_value.isObject()) {
        // Compound autolinks: true | { url, www, email }
        if (try opts_value.get(globalThis, "autolinks")) |autolinks_val| {
            if (autolinks_val.isBoolean()) {
                if (autolinks_val.toBoolean()) options.permissive_autolinks = true;
            } else if (autolinks_val.isObject()) {
                if (try autolinks_val.getBooleanLoose(globalThis, "url")) |v| options.permissive_url_autolinks = v;
                if (try autolinks_val.getBooleanLoose(globalThis, "www")) |v| options.permissive_www_autolinks = v;
                if (try autolinks_val.getBooleanLoose(globalThis, "email")) |v| options.permissive_email_autolinks = v;
            }
        }
        // Compound headings: true | { ids, autolink }
        if (try opts_value.get(globalThis, "headings")) |headings_val| {
            if (headings_val.isBoolean()) {
                if (headings_val.toBoolean()) {
                    options.heading_ids = true;
                    options.autolink_headings = true;
                }
            } else if (headings_val.isObject()) {
                if (try headings_val.getBooleanLoose(globalThis, "ids")) |v| options.heading_ids = v;
                if (try headings_val.getBooleanLoose(globalThis, "autolink")) |v| options.autolink_headings = v;
            }
        }
        // Remaining boolean options (autolinks/headings only via compound above).
        inline for (bun.meta.fieldsOf(md.Options)) |field| {
            comptime if (field.type != bool or
                std.mem.eql(u8, field.name, "permissive_autolinks") or
                std.mem.eql(u8, field.name, "permissive_url_autolinks") or
                std.mem.eql(u8, field.name, "permissive_www_autolinks") or
                std.mem.eql(u8, field.name, "permissive_email_autolinks") or
                std.mem.eql(u8, field.name, "heading_ids") or
                std.mem.eql(u8, field.name, "autolink_headings")) continue;
            if (try opts_value.getBooleanLoose(globalThis, comptime camelCaseOf(field.name))) |val| {
                @field(options, field.name) = val;
            } else if (comptime !std.mem.eql(u8, camelCaseOf(field.name), field.name)) {
                if (try opts_value.getBooleanLoose(globalThis, field.name)) |val| {
                    @field(options, field.name) = val;
                }
            }
        }
    }
    return options;
}

/// `Bun.markdown.render(text, callbacks, options?)` — render markdown, calling
/// the provided JS callbacks for each element to build a custom string result.
pub fn render(globalThis: *JSGlobalObject, callframe: *CallFrame) JSError!JSValue {
    const input_value, const callbacks_value, const opts_value = callframe.argumentsAsArray(3);

    if (input_value.isEmptyOrUndefinedOrNull()) {
        return globalThis.throwInvalidArguments("Expected a string or buffer to render", .{});
    }

    var arena: bun.ArenaAllocator = .init(bun.default_allocator);
    defer arena.deinit();

    const buffer = try StringOrBuffer.fromJS(globalThis, arena.allocator(), input_value) orelse {
        return globalThis.throwInvalidArguments("Expected a string or buffer to render", .{});
    };

    const input = buffer.slice();

    const options = try parseOptions(globalThis, opts_value);

    var js_renderer = JsCallbackRenderer.init(globalThis, input, options.heading_ids) catch {
        return globalThis.throwOutOfMemory();
    };
    defer js_renderer.deinit();

    try js_renderer.extractCallbacks(if (callbacks_value.isObject()) callbacks_value else .js_undefined);

    md.renderWithRenderer(input, arena.allocator(), options, js_renderer.renderer()) catch |err| return switch (err) {
        error.JSError, error.JSTerminated, error.OutOfMemory => |e| e,
        error.StackOverflow => globalThis.throwStackOverflow(),
    };

    const result = js_renderer.getResult();
    return bun.String.createUTF8ForJS(globalThis, result);
}

/// `Bun.markdown.react(text, components?, options?)` — returns a React Fragment
/// element containing the parsed markdown as children.
pub const renderReact = jsc.MarkedArgumentBuffer.wrap(renderReactImpl);

extern fn JSReactElement__createFragment(
    globalObject: *JSGlobalObject,
    react_version: u8,
    children: JSValue,
) JSValue;

fn renderReactImpl(
    globalThis: *JSGlobalObject,
    callframe: *CallFrame,
    marked_args: *jsc.MarkedArgumentBuffer,
) JSError!JSValue {
    const args = callframe.argumentsAsArray(3);
    const opts_value = args[2];

    var react_version: u8 = 1; // default: react.transitional.element (React 19+)
    if (opts_value.isObject()) {
        if (try opts_value.get(globalThis, "reactVersion")) |rv| {
            if (rv.isNumber()) {
                const num = rv.toInt32();
                if (num <= 18) react_version = 0; // react.element (React 18 and older)
            }
        }
    }

    const children = try renderAST(globalThis, callframe, marked_args, react_version);
    const fragment = JSReactElement__createFragment(globalThis, react_version, children);
    marked_args.append(fragment);
    return fragment;
}

fn renderAST(
    globalThis: *JSGlobalObject,
    callframe: *CallFrame,
    marked_args: *jsc.MarkedArgumentBuffer,
    react_version: ?u8,
) JSError!JSValue {
    const input_value, const components_value, const opts_value = callframe.argumentsAsArray(3);

    if (input_value.isEmptyOrUndefinedOrNull()) {
        return globalThis.throwInvalidArguments("Expected a string or buffer to render", .{});
    }

    var arena: bun.ArenaAllocator = .init(bun.default_allocator);
    defer arena.deinit();

    const buffer = try StringOrBuffer.fromJS(globalThis, arena.allocator(), input_value) orelse {
        return globalThis.throwInvalidArguments("Expected a string or buffer to render", .{});
    };

    const input = buffer.slice();

    const options = try parseOptions(globalThis, opts_value);

    var parse_renderer = ParseRenderer.init(globalThis, input, marked_args, options.heading_ids, react_version) catch {
        return globalThis.throwOutOfMemory();
    };
    defer parse_renderer.deinit();

    try parse_renderer.extractComponents(if (components_value.isObject()) components_value else .js_undefined);

    md.renderWithRenderer(input, arena.allocator(), options, parse_renderer.renderer()) catch |err| return switch (err) {
        error.JSError, error.JSTerminated, error.OutOfMemory => |e| e,
        error.StackOverflow => globalThis.throwStackOverflow(),
    };

    return parse_renderer.getResult();
}

fn extractLanguage(src_text: []const u8, info_beg: u32) []const u8 {
    var lang_end: u32 = info_beg;
    while (lang_end < src_text.len) {
        const c = src_text[lang_end];
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') break;
        lang_end += 1;
    }
    if (lang_end > info_beg) return src_text[info_beg..lang_end];
    return "";
}

// Fast-path meta-object constructors + cached tag-string interner, implemented
// in the pinned C++ obj (BunMarkdownMeta.cpp / BunMarkdownTagStrings). All
// `extern "C"`.
extern fn BunMarkdownTagStrings__getTagString(*JSGlobalObject, u8) JSValue;
extern fn BunMarkdownMeta__createListItem(*JSGlobalObject, u32, u32, bool, JSValue, JSValue) JSValue;
extern fn BunMarkdownMeta__createList(*JSGlobalObject, bool, JSValue, u32) JSValue;
extern fn BunMarkdownMeta__createCell(*JSGlobalObject, JSValue) JSValue;
extern fn BunMarkdownMeta__createLink(*JSGlobalObject, JSValue, JSValue) JSValue;

/// Renderer that builds an object AST from markdown (for `react()`). In React
/// mode each element is a real React element via the C++ fast path; in plain
/// mode a `{ type, props }` object.
const ParseRenderer = struct {
    globalObject: *JSGlobalObject,
    marked_args: *jsc.MarkedArgumentBuffer,
    stack: std.ArrayListUnmanaged(StackEntry) = .empty,
    stack_check: bun.StackCheck,
    src_text: []const u8,
    heading_tracker: md.helpers.HeadingIdTracker = md.helpers.HeadingIdTracker.init(false),
    components: Components = .{},
    react_version: ?u8 = null,

    extern fn JSReactElement__create(
        globalObject: *JSGlobalObject,
        react_version: u8,
        element_type: JSValue,
        props: JSValue,
    ) JSValue;

    const Components = struct {
        h1: JSValue = .zero,
        h2: JSValue = .zero,
        h3: JSValue = .zero,
        h4: JSValue = .zero,
        h5: JSValue = .zero,
        h6: JSValue = .zero,
        p: JSValue = .zero,
        blockquote: JSValue = .zero,
        ul: JSValue = .zero,
        ol: JSValue = .zero,
        li: JSValue = .zero,
        pre: JSValue = .zero,
        hr: JSValue = .zero,
        html: JSValue = .zero,
        table: JSValue = .zero,
        thead: JSValue = .zero,
        tbody: JSValue = .zero,
        tr: JSValue = .zero,
        th: JSValue = .zero,
        td: JSValue = .zero,
        em: JSValue = .zero,
        strong: JSValue = .zero,
        a: JSValue = .zero,
        img: JSValue = .zero,
        code: JSValue = .zero,
        del: JSValue = .zero,
        math: JSValue = .zero,
        u: JSValue = .zero,
        br: JSValue = .zero,
    };

    const StackEntry = struct {
        children: JSValue,
        block_type: ?md.BlockType = null,
        span_type: ?md.SpanType = null,
        data: u32 = 0,
        flags: u32 = 0,
        detail: md.SpanDetail = .{},
    };

    fn init(
        globalObject: *JSGlobalObject,
        src_text: []const u8,
        marked_args: *jsc.MarkedArgumentBuffer,
        heading_ids: bool,
        react_version: ?u8,
    ) error{OutOfMemory}!ParseRenderer {
        var self = ParseRenderer{
            .globalObject = globalObject,
            .marked_args = marked_args,
            .src_text = src_text,
            .heading_tracker = md.helpers.HeadingIdTracker.init(heading_ids),
            .stack_check = bun.StackCheck.init(),
            .react_version = react_version,
        };
        const root_array = JSValue.createEmptyArray(globalObject, 0) catch return error.OutOfMemory;
        marked_args.append(root_array);
        try self.stack.append(bun.default_allocator, .{ .children = root_array, .block_type = .doc });
        return self;
    }

    fn deinit(self: *ParseRenderer) void {
        self.stack.deinit(bun.default_allocator);
        self.heading_tracker.deinit(bun.default_allocator);
    }

    fn extractComponents(self: *ParseRenderer, opts: JSValue) JSError!void {
        if (opts.isUndefinedOrNull() or !opts.isObject()) return;
        inline for (bun.meta.fieldsOf(Components)) |field| {
            if (try opts.getTruthy(self.globalObject, field.name)) |val| {
                if (!val.isBoolean()) {
                    @field(self.components, field.name) = val;
                    self.marked_args.append(val);
                }
            }
        }
    }

    fn getBlockComponent(self: *ParseRenderer, block_type: md.BlockType, data: u32) JSValue {
        return switch (block_type) {
            .h => switch (data) {
                1 => self.components.h1,
                2 => self.components.h2,
                3 => self.components.h3,
                4 => self.components.h4,
                5 => self.components.h5,
                else => self.components.h6,
            },
            .p => self.components.p,
            .quote => self.components.blockquote,
            .ul => self.components.ul,
            .ol => self.components.ol,
            .li => self.components.li,
            .code => self.components.pre,
            .hr => self.components.hr,
            .html => self.components.html,
            .table => self.components.table,
            .thead => self.components.thead,
            .tbody => self.components.tbody,
            .tr => self.components.tr,
            .th => self.components.th,
            .td => self.components.td,
            .doc => .zero,
        };
    }

    fn getSpanComponent(self: *ParseRenderer, span_type: md.SpanType) JSValue {
        return switch (span_type) {
            .em => self.components.em,
            .strong => self.components.strong,
            .a => self.components.a,
            .img => self.components.img,
            .code => self.components.code,
            .del => self.components.del,
            .latexmath, .latexmath_display => self.components.math,
            .wikilink => self.components.a,
            .u => self.components.u,
        };
    }

    fn renderer(self: *ParseRenderer) md.Renderer {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn getResult(self: *ParseRenderer) JSValue {
        if (self.stack.items.len == 0) return .js_undefined;
        return self.stack.items[0].children;
    }

    fn createElement(self: *ParseRenderer, type_val: JSValue, props: JSValue) JSValue {
        if (self.react_version) |version| {
            const obj = JSReactElement__create(self.globalObject, version, type_val, props);
            self.marked_args.append(obj);
            return obj;
        } else {
            const obj = JSValue.createEmptyObject(self.globalObject, 2);
            self.marked_args.append(obj);
            obj.put(self.globalObject, ZigString.static("type"), type_val);
            obj.put(self.globalObject, ZigString.static("props"), props);
            return obj;
        }
    }

    const vtable: md.Renderer.VTable = .{
        .enterBlock = enterBlockImpl,
        .leaveBlock = leaveBlockImpl,
        .enterSpan = enterSpanImpl,
        .leaveSpan = leaveSpanImpl,
        .text = textImpl,
    };

    fn enterBlockImpl(ptr: *anyopaque, block_type: md.BlockType, data: u32, flags: u32) JSError!void {
        const self: *ParseRenderer = @ptrCast(@alignCast(ptr));
        if (!self.stack_check.isSafeToRecurse()) return self.globalObject.throwStackOverflow();
        if (block_type == .doc) return;

        if (block_type == .h) {
            self.heading_tracker.enterHeading();
        }

        const array = try JSValue.createEmptyArray(self.globalObject, 0);
        self.marked_args.append(array);
        try self.stack.append(bun.default_allocator, .{
            .children = array,
            .block_type = block_type,
            .data = data,
            .flags = flags,
        });
    }

    fn leaveBlockImpl(ptr: *anyopaque, block_type: md.BlockType, _: u32) JSError!void {
        const self: *ParseRenderer = @ptrCast(@alignCast(ptr));
        if (!self.stack_check.isSafeToRecurse()) return self.globalObject.throwStackOverflow();
        if (block_type == .doc) return;

        if (self.stack.items.len <= 1) return;
        const entry = self.stack.pop().?;
        const g = self.globalObject;

        const tag_index = getBlockTypeTag(block_type, entry.data);

        const slug: ?[]const u8 = if (block_type == .h) self.heading_tracker.leaveHeading(bun.default_allocator) else null;

        var props_count: usize = if (block_type == .hr) 0 else 1; // children
        switch (block_type) {
            .h => if (slug != null) {
                props_count += 1;
            },
            .ol => props_count += 1, // start
            .li => {
                const task_mark = md.types.taskMarkFromData(entry.data);
                if (task_mark != 0) props_count += 1;
            },
            .code => {
                if (entry.flags & md.BLOCK_FENCED_CODE != 0) {
                    const lang = extractLanguage(self.src_text, entry.data);
                    if (lang.len > 0) props_count += 1;
                }
            },
            .th, .td => {
                const alignment = md.types.alignmentFromData(entry.data);
                if (alignment != .default) props_count += 1;
            },
            else => {},
        }

        const component = self.getBlockComponent(block_type, entry.data);
        const type_val: JSValue = if (component != .zero) component else getCachedTagString(g, tag_index);

        const props = JSValue.createEmptyObject(g, props_count);
        self.marked_args.append(props);

        switch (block_type) {
            .h => {
                if (slug) |s| {
                    props.put(g, ZigString.static("id"), try bun.String.createUTF8ForJS(g, s));
                }
            },
            .ol => {
                props.put(g, ZigString.static("start"), JSValue.jsNumber(entry.data));
            },
            .li => {
                const task_mark = md.types.taskMarkFromData(entry.data);
                if (task_mark != 0) {
                    props.put(g, ZigString.static("checked"), JSValue.jsBoolean(md.types.isTaskChecked(task_mark)));
                }
            },
            .code => {
                if (entry.flags & md.BLOCK_FENCED_CODE != 0) {
                    const lang = extractLanguage(self.src_text, entry.data);
                    if (lang.len > 0) {
                        props.put(g, ZigString.static("language"), try bun.String.createUTF8ForJS(g, lang));
                    }
                }
            },
            .th, .td => {
                const alignment = md.types.alignmentFromData(entry.data);
                if (md.types.alignmentName(alignment)) |align_str| {
                    props.put(g, ZigString.static("align"), try bun.String.createUTF8ForJS(g, align_str));
                }
            },
            else => {},
        }

        if (block_type != .hr) {
            props.put(g, ZigString.static("children"), entry.children);
        }

        const obj = self.createElement(type_val, props);

        if (self.stack.items.len > 0) {
            try self.stack.items[self.stack.items.len - 1].children.push(g, obj);
        }

        if (block_type == .h) {
            self.heading_tracker.clearAfterHeading();
        }
    }

    fn enterSpanImpl(ptr: *anyopaque, _: md.SpanType, detail: md.SpanDetail) JSError!void {
        const self: *ParseRenderer = @ptrCast(@alignCast(ptr));
        if (!self.stack_check.isSafeToRecurse()) return self.globalObject.throwStackOverflow();

        const array = try JSValue.createEmptyArray(self.globalObject, 0);
        self.marked_args.append(array);
        try self.stack.append(bun.default_allocator, .{ .children = array, .detail = detail });
    }

    fn leaveSpanImpl(ptr: *anyopaque, span_type: md.SpanType) JSError!void {
        const self: *ParseRenderer = @ptrCast(@alignCast(ptr));
        if (!self.stack_check.isSafeToRecurse()) return self.globalObject.throwStackOverflow();

        if (self.stack.items.len <= 1) return;
        const entry = self.stack.pop().?;
        const g = self.globalObject;

        const tag_index = getSpanTypeTag(span_type);

        var props_count: usize = 1; // children (or alt for img)
        switch (span_type) {
            .a => {
                props_count += 1; // href
                if (entry.detail.title.len > 0) props_count += 1;
            },
            .img => {
                props_count += 1; // src
                if (entry.detail.title.len > 0) props_count += 1;
            },
            .wikilink => props_count += 1, // target
            .latexmath_display => props_count += 1, // display
            else => {},
        }

        const component = self.getSpanComponent(span_type);
        const type_val: JSValue = if (component != .zero) component else getCachedTagString(g, tag_index);

        const props = JSValue.createEmptyObject(g, props_count);
        self.marked_args.append(props);

        switch (span_type) {
            .a => {
                props.put(g, ZigString.static("href"), try bun.String.createUTF8ForJS(g, entry.detail.href));
                if (entry.detail.title.len > 0) {
                    props.put(g, ZigString.static("title"), try bun.String.createUTF8ForJS(g, entry.detail.title));
                }
            },
            .img => {
                props.put(g, ZigString.static("src"), try bun.String.createUTF8ForJS(g, entry.detail.href));
                if (entry.detail.title.len > 0) {
                    props.put(g, ZigString.static("title"), try bun.String.createUTF8ForJS(g, entry.detail.title));
                }
            },
            .wikilink => {
                props.put(g, ZigString.static("target"), try bun.String.createUTF8ForJS(g, entry.detail.href));
            },
            .latexmath_display => {
                props.put(g, ZigString.static("display"), .true);
            },
            else => {},
        }

        if (span_type == .img) {
            const len: u32 = @truncate(try entry.children.getLength(g));
            if (len == 1) {
                const child = try entry.children.getIndex(g, 0);
                if (child.isString()) {
                    props.put(g, ZigString.static("alt"), child);
                }
            } else if (len > 1) {
                var alt_buf: std.ArrayListUnmanaged(u8) = .empty;
                defer alt_buf.deinit(bun.default_allocator);
                for (0..len) |i| {
                    const child = try entry.children.getIndex(g, @truncate(i));
                    if (child.isString()) {
                        const str = try child.toSlice(g, bun.default_allocator);
                        defer str.deinit();
                        alt_buf.appendSlice(bun.default_allocator, str.slice()) catch {};
                    }
                }
                if (alt_buf.items.len > 0) {
                    props.put(g, ZigString.static("alt"), try bun.String.createUTF8ForJS(g, alt_buf.items));
                }
            }
        } else {
            props.put(g, ZigString.static("children"), entry.children);
        }

        const obj = self.createElement(type_val, props);

        if (self.stack.items.len > 0) {
            try self.stack.items[self.stack.items.len - 1].children.push(g, obj);
        }
    }

    fn textImpl(ptr: *anyopaque, text_type: md.TextType, content: []const u8) JSError!void {
        const self: *ParseRenderer = @ptrCast(@alignCast(ptr));
        if (!self.stack_check.isSafeToRecurse()) return self.globalObject.throwStackOverflow();

        const g = self.globalObject;

        self.heading_tracker.trackText(text_type, content, bun.default_allocator);

        if (self.stack.items.len == 0) return;
        const parent = &self.stack.items[self.stack.items.len - 1];

        switch (text_type) {
            .br => {
                const br_component = self.components.br;
                const br_type: JSValue = if (br_component != .zero) br_component else getCachedTagString(g, .br);
                const empty_props = JSValue.createEmptyObject(g, 0);
                self.marked_args.append(empty_props);
                const obj = self.createElement(br_type, empty_props);
                try parent.children.push(g, obj);
            },
            .softbr => {
                const str = try bun.String.createUTF8ForJS(g, "\n");
                self.marked_args.append(str);
                try parent.children.push(g, str);
            },
            .null_char => {
                const str = try bun.String.createUTF8ForJS(g, "\xEF\xBF\xBD");
                self.marked_args.append(str);
                try parent.children.push(g, str);
            },
            .entity => {
                var buf: [8]u8 = undefined;
                const decoded = md.helpers.decodeEntityToUtf8(content, &buf) orelse content;
                const str = try bun.String.createUTF8ForJS(g, decoded);
                self.marked_args.append(str);
                try parent.children.push(g, str);
            },
            else => {
                const str = try bun.String.createUTF8ForJS(g, content);
                self.marked_args.append(str);
                try parent.children.push(g, str);
            },
        }
    }
};

/// Renderer that calls JavaScript callbacks for each markdown element (for
/// `render()`). Content-stack pattern: each enter pushes a buffer, text appends
/// to the top buffer, each leave pops it, calls the JS callback with the
/// accumulated children, and appends the callback's return to the parent.
const JsCallbackRenderer = struct {
    globalObject: *JSGlobalObject,
    allocator: std.mem.Allocator,
    src_text: []const u8,
    stack: std.ArrayListUnmanaged(StackEntry) = .empty,
    callbacks: Callbacks = .{},
    heading_tracker: md.helpers.HeadingIdTracker = md.helpers.HeadingIdTracker.init(false),
    stack_check: bun.StackCheck,

    fn init(globalObject: *JSGlobalObject, src_text: []const u8, heading_ids: bool) error{OutOfMemory}!JsCallbackRenderer {
        var self = JsCallbackRenderer{
            .globalObject = globalObject,
            .allocator = bun.default_allocator,
            .src_text = src_text,
            .heading_tracker = md.helpers.HeadingIdTracker.init(heading_ids),
            .stack_check = bun.StackCheck.init(),
        };
        try self.stack.append(bun.default_allocator, .{});
        return self;
    }

    const Callbacks = struct {
        heading: JSValue = .zero,
        paragraph: JSValue = .zero,
        blockquote: JSValue = .zero,
        code: JSValue = .zero,
        list: JSValue = .zero,
        listItem: JSValue = .zero,
        hr: JSValue = .zero,
        table: JSValue = .zero,
        thead: JSValue = .zero,
        tbody: JSValue = .zero,
        tr: JSValue = .zero,
        th: JSValue = .zero,
        td: JSValue = .zero,
        html: JSValue = .zero,
        strong: JSValue = .zero,
        emphasis: JSValue = .zero,
        link: JSValue = .zero,
        image: JSValue = .zero,
        codespan: JSValue = .zero,
        strikethrough: JSValue = .zero,
        text: JSValue = .zero,
    };

    const StackEntry = struct {
        buffer: std.ArrayListUnmanaged(u8) = .empty,
        block_type: md.BlockType = .doc,
        data: u32 = 0,
        flags: u32 = 0,
        child_index: u32 = 0,
        detail: md.SpanDetail = .{},
    };

    fn extractCallbacks(self: *JsCallbackRenderer, opts: JSValue) JSError!void {
        if (opts.isUndefinedOrNull() or !opts.isObject()) return;
        inline for (bun.meta.fieldsOf(Callbacks)) |field| {
            if (try opts.getTruthy(self.globalObject, field.name)) |val| {
                if (val.isCallable()) {
                    @field(self.callbacks, field.name) = val;
                }
            }
        }
    }

    fn deinit(self: *JsCallbackRenderer) void {
        for (self.stack.items) |*entry| {
            entry.buffer.deinit(self.allocator);
        }
        self.stack.deinit(self.allocator);
        self.heading_tracker.deinit(self.allocator);
    }

    fn renderer(self: *JsCallbackRenderer) md.Renderer {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: md.Renderer.VTable = .{
        .enterBlock = enterBlockImpl,
        .leaveBlock = leaveBlockImpl,
        .enterSpan = enterSpanImpl,
        .leaveSpan = leaveSpanImpl,
        .text = textImpl,
    };

    fn appendToTop(self: *JsCallbackRenderer, data: []const u8) error{OutOfMemory}!void {
        if (self.stack.items.len == 0) return;
        const top = &self.stack.items[self.stack.items.len - 1];
        try top.buffer.appendSlice(self.allocator, data);
    }

    fn popAndCallback(self: *JsCallbackRenderer, callback: JSValue, meta: ?JSValue) JSError!void {
        if (self.stack.items.len <= 1) return; // don't pop root
        var entry = self.stack.pop() orelse return;
        defer entry.buffer.deinit(self.allocator);

        const children = entry.buffer.items;

        if (callback == .zero) {
            try self.appendToTop(children);
            return;
        }

        if (!self.stack_check.isSafeToRecurse()) {
            return self.globalObject.throwStackOverflow();
        }

        const children_js = try bun.String.createUTF8ForJS(self.globalObject, children);

        const result = if (meta) |m|
            try callback.call(self.globalObject, .js_undefined, &[_]JSValue{ children_js, m })
        else
            try callback.call(self.globalObject, .js_undefined, &[_]JSValue{children_js});

        if (result.isUndefinedOrNull()) return;
        const slice = try result.toSlice(self.globalObject, self.allocator);
        defer slice.deinit();
        try self.appendToTop(slice.slice());
    }

    fn getResult(self: *JsCallbackRenderer) []const u8 {
        if (self.stack.items.len == 0) return "";
        return self.stack.items[0].buffer.items;
    }

    fn enterBlockImpl(ptr: *anyopaque, block_type: md.BlockType, data: u32, flags: u32) JSError!void {
        const self: *JsCallbackRenderer = @ptrCast(@alignCast(ptr));
        if (!self.stack_check.isSafeToRecurse()) return self.globalObject.throwStackOverflow();
        if (block_type == .doc) return;
        if (block_type == .h) {
            self.heading_tracker.enterHeading();
        }

        var child_index: u32 = 0;
        if (block_type == .li and self.stack.items.len > 0) {
            const parent = &self.stack.items[self.stack.items.len - 1];
            child_index = parent.child_index;
            parent.child_index += 1;
        }

        try self.stack.append(self.allocator, .{
            .block_type = block_type,
            .data = data,
            .flags = flags,
            .child_index = child_index,
        });
    }

    fn leaveBlockImpl(ptr: *anyopaque, block_type: md.BlockType, _: u32) JSError!void {
        const self: *JsCallbackRenderer = @ptrCast(@alignCast(ptr));
        if (!self.stack_check.isSafeToRecurse()) return self.globalObject.throwStackOverflow();
        if (block_type == .doc) return;

        const callback = self.getBlockCallback(block_type);
        const saved = if (self.stack.items.len > 1)
            self.stack.items[self.stack.items.len - 1]
        else
            StackEntry{};
        const meta = try self.createBlockMeta(block_type, saved.data, saved.flags);
        try self.popAndCallback(callback, meta);

        if (block_type == .h) {
            self.heading_tracker.clearAfterHeading();
        }
    }

    fn enterSpanImpl(ptr: *anyopaque, _: md.SpanType, detail: md.SpanDetail) JSError!void {
        const self: *JsCallbackRenderer = @ptrCast(@alignCast(ptr));
        if (!self.stack_check.isSafeToRecurse()) return self.globalObject.throwStackOverflow();
        try self.stack.append(self.allocator, .{ .detail = detail });
    }

    fn leaveSpanImpl(ptr: *anyopaque, span_type: md.SpanType) JSError!void {
        const self: *JsCallbackRenderer = @ptrCast(@alignCast(ptr));
        if (!self.stack_check.isSafeToRecurse()) return self.globalObject.throwStackOverflow();

        const callback = self.getSpanCallback(span_type);
        const detail = if (self.stack.items.len > 1)
            self.stack.items[self.stack.items.len - 1].detail
        else
            md.SpanDetail{};
        const meta = try self.createSpanMeta(span_type, detail);
        try self.popAndCallback(callback, meta);
    }

    fn textImpl(ptr: *anyopaque, text_type: md.TextType, content: []const u8) JSError!void {
        const self: *JsCallbackRenderer = @ptrCast(@alignCast(ptr));
        if (!self.stack_check.isSafeToRecurse()) return self.globalObject.throwStackOverflow();

        self.heading_tracker.trackText(text_type, content, self.allocator);

        switch (text_type) {
            .null_char => try self.appendToTop("\xEF\xBF\xBD"),
            .br => try self.appendToTop("\n"),
            .softbr => try self.appendToTop("\n"),
            .entity => try self.decodeAndAppendEntity(content),
            else => {
                if (self.callbacks.text != .zero) {
                    try self.callTextCallback(content);
                } else {
                    try self.appendToTop(content);
                }
            },
        }
    }

    fn callTextCallback(self: *JsCallbackRenderer, content: []const u8) JSError!void {
        if (!self.stack_check.isSafeToRecurse()) {
            return self.globalObject.throwStackOverflow();
        }
        const text_js = try bun.String.createUTF8ForJS(self.globalObject, content);
        const result = try self.callbacks.text.call(self.globalObject, .js_undefined, &[_]JSValue{text_js});
        if (!result.isUndefinedOrNull()) {
            const slice = try result.toSlice(self.globalObject, self.allocator);
            defer slice.deinit();
            try self.appendToTop(slice.slice());
        }
    }

    fn decodeAndAppendEntity(self: *JsCallbackRenderer, entity_text: []const u8) JSError!void {
        var buf: [8]u8 = undefined;
        try self.appendTextOrRaw(md.helpers.decodeEntityToUtf8(entity_text, &buf) orelse entity_text);
    }

    fn appendTextOrRaw(self: *JsCallbackRenderer, content: []const u8) JSError!void {
        if (self.callbacks.text != .zero) {
            try self.callTextCallback(content);
        } else {
            try self.appendToTop(content);
        }
    }

    fn getBlockCallback(self: *JsCallbackRenderer, block_type: md.BlockType) JSValue {
        return switch (block_type) {
            .h => self.callbacks.heading,
            .p => self.callbacks.paragraph,
            .quote => self.callbacks.blockquote,
            .code => self.callbacks.code,
            .ul, .ol => self.callbacks.list,
            .li => self.callbacks.listItem,
            .hr => self.callbacks.hr,
            .table => self.callbacks.table,
            .thead => self.callbacks.thead,
            .tbody => self.callbacks.tbody,
            .tr => self.callbacks.tr,
            .th => self.callbacks.th,
            .td => self.callbacks.td,
            .html => self.callbacks.html,
            .doc => .zero,
        };
    }

    fn getSpanCallback(self: *JsCallbackRenderer, span_type: md.SpanType) JSValue {
        return switch (span_type) {
            .em => self.callbacks.emphasis,
            .strong => self.callbacks.strong,
            .a => self.callbacks.link,
            .img => self.callbacks.image,
            .code => self.callbacks.codespan,
            .del => self.callbacks.strikethrough,
            else => .zero,
        };
    }

    fn countListDepth(self: *JsCallbackRenderer) u32 {
        var depth: u32 = 0;
        const len = self.stack.items.len;
        if (len < 2) return 0;
        for (self.stack.items[0 .. len - 1]) |entry| {
            if (entry.block_type == .ul or entry.block_type == .ol) depth += 1;
        }
        return depth;
    }

    fn parentList(self: *JsCallbackRenderer) ?*const StackEntry {
        const len = self.stack.items.len;
        if (len < 2) return null;
        const parent = &self.stack.items[len - 2];
        if (parent.block_type == .ul or parent.block_type == .ol) return parent;
        return null;
    }

    fn createBlockMeta(self: *JsCallbackRenderer, block_type: md.BlockType, data: u32, flags: u32) JSError!?JSValue {
        const g = self.globalObject;
        switch (block_type) {
            .h => {
                const slug = self.heading_tracker.leaveHeading(self.allocator);
                const field_count: usize = if (slug != null) 2 else 1;
                const obj = JSValue.createEmptyObject(g, field_count);
                obj.put(g, ZigString.static("level"), JSValue.jsNumber(data));
                if (slug) |s| {
                    obj.put(g, ZigString.static("id"), try bun.String.createUTF8ForJS(g, s));
                }
                return obj;
            },
            .ol => {
                return BunMarkdownMeta__createList(g, true, JSValue.jsNumber(data), self.countListDepth());
            },
            .ul => {
                return BunMarkdownMeta__createList(g, false, .js_undefined, self.countListDepth());
            },
            .code => {
                if (flags & md.BLOCK_FENCED_CODE != 0) {
                    const lang = extractLanguage(self.src_text, data);
                    if (lang.len > 0) {
                        const obj = JSValue.createEmptyObject(g, 1);
                        obj.put(g, ZigString.static("language"), try bun.String.createUTF8ForJS(g, lang));
                        return obj;
                    }
                }
                return null;
            },
            .th, .td => {
                const alignment = md.types.alignmentFromData(data);
                const align_js = if (md.types.alignmentName(alignment)) |align_str|
                    try bun.String.createUTF8ForJS(g, align_str)
                else
                    JSValue.js_undefined;
                return BunMarkdownMeta__createCell(g, align_js);
            },
            .li => {
                const len = self.stack.items.len;
                const item_index = if (len > 1) self.stack.items[len - 1].child_index else 0;
                const parent = self.parentList();
                const is_ordered = parent != null and parent.?.block_type == .ol;
                const enclosing = self.countListDepth();
                const depth: u32 = if (enclosing > 0) enclosing - 1 else 0;
                const task_mark = md.types.taskMarkFromData(data);

                const start_js = if (is_ordered) JSValue.jsNumber(parent.?.data) else JSValue.js_undefined;
                const checked_js = if (task_mark != 0)
                    JSValue.jsBoolean(md.types.isTaskChecked(task_mark))
                else
                    JSValue.js_undefined;

                return BunMarkdownMeta__createListItem(g, item_index, depth, is_ordered, start_js, checked_js);
            },
            else => return null,
        }
    }

    fn createSpanMeta(self: *JsCallbackRenderer, span_type: md.SpanType, detail: md.SpanDetail) JSError!?JSValue {
        const g = self.globalObject;
        switch (span_type) {
            .a => {
                const href = try bun.String.createUTF8ForJS(g, detail.href);
                const title = if (detail.title.len > 0)
                    try bun.String.createUTF8ForJS(g, detail.title)
                else
                    JSValue.js_undefined;
                return BunMarkdownMeta__createLink(g, href, title);
            },
            .img => {
                const obj = JSValue.createEmptyObject(g, 2);
                obj.put(g, ZigString.static("src"), try bun.String.createUTF8ForJS(g, detail.href));
                if (detail.title.len > 0) {
                    obj.put(g, ZigString.static("title"), try bun.String.createUTF8ForJS(g, detail.title));
                }
                return obj;
            },
            else => return null,
        }
    }
};

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

/// Block-type → TagIndex. Headings carry their level in `data` (clamped
/// to h6 above level 6).
pub fn getBlockTypeTag(block_type: md.BlockType, data: u32) TagIndex {
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
pub fn getSpanTypeTag(span_type: md.SpanType) TagIndex {
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

/// Cached HTML tag-string interner from the pinned C++ obj (BunMarkdownTagStrings).
pub fn getCachedTagString(globalObject: *JSGlobalObject, tag: TagIndex) JSValue {
    return BunMarkdownTagStrings__getTagString(globalObject, @intFromEnum(tag));
}

// (Removed the two `create`/render return-`.zero` stub tests — `create` now
// builds a real object and the render entry points hit the live `home_rt.md`
// renderer or throw, so they can't run against a fake `@ptrCast` global. The
// behavior is covered at the JS level by BunObject.test.ts + markdown tests.)

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

comptime {
    _ = &home_rt.upstream_sha;
}
