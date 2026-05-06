//! JSDoc comment parser — §3.A.14 of TS_PARITY_PLAN.
//!
//! Used by the TS frontend when `compilerOptions.checkJs` is true:
//! `.js` files use JSDoc `@type {T}` / `@param {T} name` /
//! `@returns {T}` / `@template T` annotations instead of TS syntax.
//!
//! This is the standalone tag scanner — given a comment block, it
//! extracts each `@tag {Type} name description` triple and produces
//! a structured `Tag` per line. Later phases plug the resulting
//! tags onto the corresponding HIR nodes during binding so the
//! checker sees the same shape it would if the annotations had
//! been written in TS syntax.
//!
//! Format support (per the TS spec):
//!   /** @type {T} */
//!   /** @param {T} name [optional desc] */
//!   /** @returns {T} */
//!   /** @template T */
//!   /** @typedef {T} Name */
//!
//! Out of scope here (Phase 6 follow-ups):
//!   - Type-expression parsing (we capture the raw `{T}` slice; the
//!     binder lowers it through the regular type-annotation parser).
//!   - `@callback` and `@interface` declaration tags.
//!   - Inline `@type` casts (`/** @type {T} */ (expr)`).

const std = @import("std");

pub const TagKind = enum {
    /// `@type {T}`
    type_tag,
    /// `@param {T} name [desc]`
    param_tag,
    /// `@returns {T}` or `@return {T}`
    returns_tag,
    /// `@template T`
    template_tag,
    /// `@typedef {T} Name`
    typedef_tag,
    /// Anything else (preserved as-is for tooling).
    other,
};

pub const Tag = struct {
    kind: TagKind,
    /// Raw text of the type expression between `{` and `}`. May be
    /// empty if the tag carries no type annotation.
    type_text: []const u8,
    /// Identifier name on the tag (`@param NAME`, `@template NAME`,
    /// etc.). Empty when not applicable.
    name: []const u8,
    /// Free-form description trailing the tag. Empty when not
    /// present.
    description: []const u8,
};

/// Parse a single JSDoc comment block (the bytes *between* `/**`
/// and `*/`, i.e. callers strip the comment markers). Each line
/// starting with `@<tag>` produces a `Tag`. Caller owns the
/// returned slice.
pub fn parse(gpa: std.mem.Allocator, body: []const u8) ![]Tag {
    var tags: std.ArrayListUnmanaged(Tag) = .empty;
    errdefer tags.deinit(gpa);
    var line_start: usize = 0;
    var i: usize = 0;
    while (i <= body.len) : (i += 1) {
        const at_end = i == body.len;
        if (!at_end and body[i] != '\n') continue;
        const line = body[line_start..i];
        line_start = i + 1;
        const stripped = stripLeadingStar(line);
        if (stripped.len == 0) continue;
        if (stripped[0] != '@') continue;
        const tag = parseLine(stripped) orelse continue;
        try tags.append(gpa, tag);
    }
    return tags.toOwnedSlice(gpa);
}

/// Strip `\s*\*\s?` from a line — JSDoc convention.
fn stripLeadingStar(line: []const u8) []const u8 {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    if (i < line.len and line[i] == '*') {
        i += 1;
        if (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    }
    return std.mem.trimEnd(u8, line[i..], " \t\r");
}

fn parseLine(line: []const u8) ?Tag {
    std.debug.assert(line[0] == '@');
    // Skip the `@`.
    var rest = line[1..];
    // Tag name = the run of identifier-shaped chars.
    var n: usize = 0;
    while (n < rest.len and isTagNameChar(rest[n])) n += 1;
    const tag_name = rest[0..n];
    rest = std.mem.trimStart(u8, rest[n..], " \t");
    const kind: TagKind = if (std.mem.eql(u8, tag_name, "type"))
        .type_tag
    else if (std.mem.eql(u8, tag_name, "param"))
        .param_tag
    else if (std.mem.eql(u8, tag_name, "returns") or std.mem.eql(u8, tag_name, "return"))
        .returns_tag
    else if (std.mem.eql(u8, tag_name, "template"))
        .template_tag
    else if (std.mem.eql(u8, tag_name, "typedef"))
        .typedef_tag
    else
        .other;
    // Optional `{T}` type expression.
    var type_text: []const u8 = "";
    if (rest.len > 0 and rest[0] == '{') {
        const end = matchBalancedBrace(rest);
        if (end == 0) return null;
        type_text = rest[1 .. end - 1];
        rest = std.mem.trimStart(u8, rest[end..], " \t");
    }
    // Optional name token.
    var name_text: []const u8 = "";
    if (kind == .param_tag or kind == .template_tag or kind == .typedef_tag) {
        var m: usize = 0;
        while (m < rest.len and isIdentChar(rest[m])) m += 1;
        name_text = rest[0..m];
        rest = std.mem.trimStart(u8, rest[m..], " \t");
    }
    return .{
        .kind = kind,
        .type_text = type_text,
        .name = name_text,
        .description = rest,
    };
}

fn isTagNameChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or c == '_' or c == '$';
}

/// Returns the index *after* the matching `}` for a brace at offset 0.
/// Handles nesting. Returns 0 on unmatched braces.
fn matchBalancedBrace(s: []const u8) usize {
    if (s.len == 0 or s[0] != '{') return 0;
    var depth: i32 = 1;
    var i: usize = 1;
    while (i < s.len) : (i += 1) {
        if (s[i] == '{') depth += 1;
        if (s[i] == '}') {
            depth -= 1;
            if (depth == 0) return i + 1;
        }
    }
    return 0;
}

const T = std.testing;

test "jsdoc: simple @type" {
    const body =
        \\ @type {number}
    ;
    const tags = try parse(T.allocator, body);
    defer T.allocator.free(tags);
    try T.expectEqual(@as(usize, 1), tags.len);
    try T.expectEqual(TagKind.type_tag, tags[0].kind);
    try T.expectEqualStrings("number", tags[0].type_text);
}

test "jsdoc: param with name and description" {
    const body =
        \\ * @param {string} name The user's name
    ;
    const tags = try parse(T.allocator, body);
    defer T.allocator.free(tags);
    try T.expectEqual(@as(usize, 1), tags.len);
    try T.expectEqual(TagKind.param_tag, tags[0].kind);
    try T.expectEqualStrings("string", tags[0].type_text);
    try T.expectEqualStrings("name", tags[0].name);
    try T.expectEqualStrings("The user's name", tags[0].description);
}

test "jsdoc: returns is normalized" {
    const body1 =
        \\ * @returns {boolean}
    ;
    const tags1 = try parse(T.allocator, body1);
    defer T.allocator.free(tags1);
    try T.expectEqual(TagKind.returns_tag, tags1[0].kind);

    const body2 =
        \\ * @return {boolean}
    ;
    const tags2 = try parse(T.allocator, body2);
    defer T.allocator.free(tags2);
    try T.expectEqual(TagKind.returns_tag, tags2[0].kind);
}

test "jsdoc: template" {
    const body =
        \\ * @template T
    ;
    const tags = try parse(T.allocator, body);
    defer T.allocator.free(tags);
    try T.expectEqual(TagKind.template_tag, tags[0].kind);
    try T.expectEqualStrings("T", tags[0].name);
}

test "jsdoc: nested braces in type" {
    const body =
        \\ @type {{ a: number, b: { c: string } }}
    ;
    const tags = try parse(T.allocator, body);
    defer T.allocator.free(tags);
    try T.expectEqual(@as(usize, 1), tags.len);
    try T.expectEqualStrings("{ a: number, b: { c: string } }", tags[0].type_text);
}

test "jsdoc: multi-tag block" {
    const body =
        \\ * @param {number} x
        \\ * @param {number} y
        \\ * @returns {number}
    ;
    const tags = try parse(T.allocator, body);
    defer T.allocator.free(tags);
    try T.expectEqual(@as(usize, 3), tags.len);
    try T.expectEqualStrings("x", tags[0].name);
    try T.expectEqualStrings("y", tags[1].name);
    try T.expectEqual(TagKind.returns_tag, tags[2].kind);
}

test "jsdoc: unrecognized tag preserved as .other" {
    const body =
        \\ * @deprecated Use bar instead.
    ;
    const tags = try parse(T.allocator, body);
    defer T.allocator.free(tags);
    try T.expectEqual(@as(usize, 1), tags.len);
    try T.expectEqual(TagKind.other, tags[0].kind);
}
