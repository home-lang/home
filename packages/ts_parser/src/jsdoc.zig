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
//!   /** @type {T} */ or /** @type T */
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
    /// empty if the tag carries no type annotation. The trailing `=`
    /// optional-suffix marker (`{number=}`) is stripped — see
    /// `optional` below.
    type_text: []const u8,
    /// Identifier name on the tag (`@param NAME`, `@template NAME`,
    /// etc.). Empty when not applicable. For `@param {T} [name]` and
    /// `@param {T} [name=default]` the brackets are stripped and the
    /// inner identifier is exposed here.
    name: []const u8,
    /// Free-form description trailing the tag. Empty when not
    /// present.
    description: []const u8,
    /// True for `@param` declarations marked optional via either the
    /// `{T=}` type-suffix or `[name]` / `[name=default]` bracket
    /// forms. Mirrors the JSDoc spec used by upstream tsc.
    optional: bool = false,
    /// True only for the `{T=}` type-suffix form. The checker uses
    /// this to model postfix optionality without conflating it with
    /// bracket-name optionality.
    optional_from_type_suffix: bool = false,
    /// Captured default-value expression when the source used the
    /// `@param {T} [name=DEFAULT]` form. Empty otherwise.
    default_text: []const u8 = "",
    /// True when the tag used Closure's name-first spelling
    /// (`@param name {T}`). Upstream suppresses unmatched-name
    /// TS8024 for that spelling.
    is_name_first: bool = false,
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
    var optional = false;
    var optional_from_type_suffix = false;
    var is_name_first = false;
    if (rest.len > 0 and rest[0] == '{') {
        const parsed = parseTypeExpression(rest) orelse return null;
        type_text = parsed.type_text;
        rest = std.mem.trimStart(u8, rest[parsed.len..], " \t");
        if (parsed.optional_from_type_suffix) {
            optional = true;
            optional_from_type_suffix = true;
        }
    }
    if (kind == .type_tag and type_text.len == 0) {
        type_text = std.mem.trim(u8, rest, " \t");
        rest = "";
    }
    // Optional name token. `@param`, `@template`, `@typedef` all
    // carry a trailing identifier. `@param` additionally supports
    // the `[name]` / `[name=default]` bracket forms to mark optional
    // parameters.
    var name_text: []const u8 = "";
    var default_text: []const u8 = "";
    if (kind == .param_tag or kind == .template_tag or kind == .typedef_tag) {
        if (kind == .param_tag and rest.len > 0 and rest[0] == '[') {
            const close = std.mem.indexOfScalar(u8, rest, ']') orelse return null;
            const inner = rest[1..close];
            optional = true;
            if (std.mem.indexOfScalar(u8, inner, '=')) |eq| {
                name_text = std.mem.trim(u8, inner[0..eq], " \t");
                default_text = std.mem.trim(u8, inner[eq + 1 ..], " \t");
            } else {
                name_text = std.mem.trim(u8, inner, " \t");
            }
            rest = std.mem.trimStart(u8, rest[close + 1 ..], " \t");
        } else if (kind == .param_tag and rest.len > 0 and rest[0] == '`') {
            const close = std.mem.indexOfScalarPos(u8, rest, 1, '`') orelse return null;
            name_text = rest[1..close];
            rest = std.mem.trimStart(u8, rest[close + 1 ..], " \t");
        } else {
            // `@template const T` — `const` is a const-type-parameter
            // modifier, not the parameter name. Skip it so the real name
            // (`T`) is read (jsdocTemplateTag6).
            if (kind == .template_tag and std.mem.startsWith(u8, rest, "const") and
                rest.len > 5 and (rest[5] == ' ' or rest[5] == '\t'))
            {
                rest = std.mem.trimStart(u8, rest[5..], " \t");
            }
            var m: usize = 0;
            while (m < rest.len and isIdentChar(rest[m])) m += 1;
            name_text = rest[0..m];
            rest = std.mem.trimStart(u8, rest[m..], " \t");
        }
        if (kind == .param_tag and type_text.len == 0 and rest.len > 0 and rest[0] == '{') {
            const parsed = parseTypeExpression(rest) orelse return null;
            type_text = parsed.type_text;
            rest = std.mem.trimStart(u8, rest[parsed.len..], " \t");
            is_name_first = true;
            if (parsed.optional_from_type_suffix) {
                optional = true;
                optional_from_type_suffix = true;
            }
        }
    }
    return .{
        .kind = kind,
        .type_text = type_text,
        .name = name_text,
        .description = rest,
        .optional = optional,
        .optional_from_type_suffix = optional_from_type_suffix,
        .default_text = default_text,
        .is_name_first = is_name_first,
    };
}

fn isTagNameChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

fn isIdentChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or c == '_' or c == '$';
}

const ParsedTypeExpression = struct {
    type_text: []const u8,
    len: usize,
    optional_from_type_suffix: bool,
};

fn parseTypeExpression(rest: []const u8) ?ParsedTypeExpression {
    const end = matchBalancedBrace(rest);
    if (end == 0) return null;
    var type_text = rest[1 .. end - 1];
    if (firstInvalidPostfixNullableOffset(type_text)) |invalid| {
        type_text = type_text[0..invalid];
        return .{
            .type_text = type_text,
            .len = 1 + invalid,
            .optional_from_type_suffix = false,
        };
    }
    var optional_from_type_suffix = false;
    // JSDoc `{T=}` form: trailing `=` inside the braces marks the
    // parameter as optional. Strip the marker so downstream type
    // resolution sees the plain `T`.
    if (type_text.len > 0 and type_text[type_text.len - 1] == '=') {
        optional_from_type_suffix = true;
        type_text = std.mem.trimEnd(u8, type_text[0 .. type_text.len - 1], " \t");
    }
    return .{
        .type_text = type_text,
        .len = end,
        .optional_from_type_suffix = optional_from_type_suffix,
    };
}

/// TypeScript accepts postfix JSDoc nullable (`T?`) only after the full
/// primary/postfix type. `T?[]` and `T?!` are parse errors at `?`; callers use
/// the offset both for diagnostics and for TS-like tag recovery.
pub fn firstInvalidPostfixNullableOffset(type_text: []const u8) ?usize {
    var paren_depth: i32 = 0;
    var bracket_depth: i32 = 0;
    var brace_depth: i32 = 0;
    var angle_depth: i32 = 0;
    var quote: u8 = 0;
    var i: usize = 0;
    while (i < type_text.len) : (i += 1) {
        const c = type_text[i];
        if (quote != 0) {
            if (c == '\\') {
                i += 1;
            } else if (c == quote) {
                quote = 0;
            }
            continue;
        }
        if (c == '\'' or c == '"') {
            quote = c;
            continue;
        }
        switch (c) {
            '(' => paren_depth += 1,
            ')' => {
                if (paren_depth > 0) paren_depth -= 1;
            },
            '[' => bracket_depth += 1,
            ']' => {
                if (bracket_depth > 0) bracket_depth -= 1;
            },
            '{' => brace_depth += 1,
            '}' => {
                if (brace_depth > 0) brace_depth -= 1;
            },
            '<' => angle_depth += 1,
            '>' => {
                if (angle_depth > 0) angle_depth -= 1;
            },
            '?' => {
                if (paren_depth == 0 and bracket_depth == 0 and brace_depth == 0 and angle_depth == 0) {
                    const next = nextNonWhitespace(type_text, i + 1);
                    if (next < type_text.len and (type_text[next] == '[' or type_text[next] == '!')) return i;
                }
            },
            else => {},
        }
    }
    return null;
}

pub fn isValidRestType(type_text: []const u8) bool {
    const trimmed = std.mem.trim(u8, type_text, " \t\r\n");
    if (!std.mem.startsWith(u8, trimmed, "...")) return false;
    return firstInvalidPostfixNullableOffset(trimmed[3..]) == null;
}

fn nextNonWhitespace(s: []const u8, start: usize) usize {
    var i = start;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t' or s[i] == '\r' or s[i] == '\n')) : (i += 1) {}
    return i;
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

test "jsdoc: unbraced @type" {
    const body =
        \\ @type Parameters<typeof fn>
    ;
    const tags = try parse(T.allocator, body);
    defer T.allocator.free(tags);
    try T.expectEqual(@as(usize, 1), tags.len);
    try T.expectEqual(TagKind.type_tag, tags[0].kind);
    try T.expectEqualStrings("Parameters<typeof fn>", tags[0].type_text);
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

test "jsdoc: @param with bracket-optional name" {
    const body =
        \\ * @param {string} [s]
    ;
    const tags = try parse(T.allocator, body);
    defer T.allocator.free(tags);
    try T.expectEqual(@as(usize, 1), tags.len);
    try T.expectEqual(TagKind.param_tag, tags[0].kind);
    try T.expectEqualStrings("string", tags[0].type_text);
    try T.expectEqualStrings("s", tags[0].name);
    try T.expect(tags[0].optional);
    try T.expectEqualStrings("", tags[0].default_text);
}

test "jsdoc: @param with bracket-default expression" {
    const body =
        \\ * @param {number} [r=101] explanation
    ;
    const tags = try parse(T.allocator, body);
    defer T.allocator.free(tags);
    try T.expectEqual(@as(usize, 1), tags.len);
    try T.expectEqual(TagKind.param_tag, tags[0].kind);
    try T.expectEqualStrings("number", tags[0].type_text);
    try T.expectEqualStrings("r", tags[0].name);
    try T.expect(tags[0].optional);
    try T.expectEqualStrings("101", tags[0].default_text);
    try T.expectEqualStrings("explanation", tags[0].description);
}

test "jsdoc: @param with type-suffix `=` optional marker" {
    const body =
        \\ * @param {number=} q
    ;
    const tags = try parse(T.allocator, body);
    defer T.allocator.free(tags);
    try T.expectEqual(@as(usize, 1), tags.len);
    try T.expectEqual(TagKind.param_tag, tags[0].kind);
    try T.expectEqualStrings("number", tags[0].type_text);
    try T.expectEqualStrings("q", tags[0].name);
    try T.expect(tags[0].optional);
    try T.expect(tags[0].optional_from_type_suffix);
}

test "jsdoc: @param plain name is not optional" {
    const body =
        \\ * @param {number} a
    ;
    const tags = try parse(T.allocator, body);
    defer T.allocator.free(tags);
    try T.expectEqual(@as(usize, 1), tags.len);
    try T.expectEqualStrings("a", tags[0].name);
    try T.expect(!tags[0].optional);
}

test "jsdoc: backquoted param names support type before and after name" {
    const body =
        \\ * @param {string=} `args`
        \\ * @param `bwarg` {?number?}
    ;
    const tags = try parse(T.allocator, body);
    defer T.allocator.free(tags);
    try T.expectEqual(@as(usize, 2), tags.len);
    try T.expectEqual(TagKind.param_tag, tags[0].kind);
    try T.expectEqualStrings("string", tags[0].type_text);
    try T.expectEqualStrings("args", tags[0].name);
    try T.expect(tags[0].optional);
    try T.expect(tags[0].optional_from_type_suffix);
    try T.expectEqual(TagKind.param_tag, tags[1].kind);
    try T.expectEqualStrings("?number?", tags[1].type_text);
    try T.expectEqualStrings("bwarg", tags[1].name);
    try T.expect(!tags[1].optional);
}

test "jsdoc: postfix nullable before array recovers before the invalid marker" {
    const body =
        \\ * @param {number?[]} a
        \\ * @param {...number?!} h
    ;
    const tags = try parse(T.allocator, body);
    defer T.allocator.free(tags);
    try T.expectEqual(@as(usize, 2), tags.len);
    try T.expectEqualStrings("number", tags[0].type_text);
    try T.expectEqualStrings("", tags[0].name);
    try T.expectEqualStrings("...number", tags[1].type_text);
    try T.expectEqualStrings("", tags[1].name);
}

test "jsdoc: rest type syntax recognizes valid prefix and postfix forms" {
    try T.expect(isValidRestType("...?number"));
    try T.expect(isValidRestType("...number?"));
    try T.expect(isValidRestType("...number!?"));
    try T.expect(isValidRestType("...number![]?"));
    try T.expect(!isValidRestType("...number?!"));
    try T.expect(!isValidRestType("...number?[]!"));
}

test "jsdoc: bracket-optional mixed with required parameters keeps each tag distinct" {
    const body =
        \\ * @param {number} a
        \\ * @param {number} [b]
        \\ * @param {number} c
    ;
    const tags = try parse(T.allocator, body);
    defer T.allocator.free(tags);
    try T.expectEqual(@as(usize, 3), tags.len);
    try T.expectEqualStrings("a", tags[0].name);
    try T.expect(!tags[0].optional);
    try T.expectEqualStrings("b", tags[1].name);
    try T.expect(tags[1].optional);
    try T.expectEqualStrings("c", tags[2].name);
    try T.expect(!tags[2].optional);
}
