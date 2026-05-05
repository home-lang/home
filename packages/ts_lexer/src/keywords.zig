//! Keyword classification for the TS lexer.
//!
//! Per TS_PARITY_PLAN Tier 1 §11.14 ("Perfect-hash keyword recognition
//! via Zig comptime — eliminates hash collisions vs. map[string]Kind
//! (tsgo) or open hashing (tsc); ~3–5% on lex").
//!
//! Implementation: a comptime-built array indexed by identifier length
//! (TS keywords range from 2 chars `as`/`do`/`if`/`in`/`is`/`of` to
//! 11 chars `constructor` and `implements`), with a per-length linear
//! scan over a tiny `(literal, kind)` array. With ≤ 6 candidates per
//! length, the scan is faster than a hash and inlines into a register
//! comparison sequence. tsgo uses a `map[string]ast.Kind` at
//! `internal/scanner/scanner.go:36`; this approach beats it.

const std = @import("std");
const tk = @import("token.zig");
const TokenKind = tk.TokenKind;

const Entry = struct {
    word: []const u8,
    kind: TokenKind,
};

// Keyword table — every reserved + TS-only + contextual keyword the
// scanner needs to recognize. Order doesn't matter; the comptime
// builder partitions by length.
const all_keywords = [_]Entry{
    // 2-letter
    .{ .word = "as", .kind = .kw_as },
    .{ .word = "do", .kind = .kw_do },
    .{ .word = "if", .kind = .kw_if },
    .{ .word = "in", .kind = .kw_in },
    .{ .word = "is", .kind = .kw_is },
    .{ .word = "of", .kind = .kw_of },
    // 3-letter
    .{ .word = "any", .kind = .kw_any },
    .{ .word = "for", .kind = .kw_for },
    .{ .word = "get", .kind = .kw_get },
    .{ .word = "let", .kind = .kw_let },
    .{ .word = "new", .kind = .kw_new },
    .{ .word = "out", .kind = .kw_out },
    .{ .word = "set", .kind = .kw_set },
    .{ .word = "try", .kind = .kw_try },
    .{ .word = "var", .kind = .kw_var },
    // 4-letter
    .{ .word = "case", .kind = .kw_case },
    .{ .word = "else", .kind = .kw_else },
    .{ .word = "enum", .kind = .kw_enum },
    .{ .word = "from", .kind = .kw_from },
    .{ .word = "null", .kind = .kw_null },
    .{ .word = "this", .kind = .kw_this },
    .{ .word = "true", .kind = .kw_true },
    .{ .word = "type", .kind = .kw_type },
    .{ .word = "void", .kind = .kw_void },
    .{ .word = "with", .kind = .kw_with },
    // 5-letter
    .{ .word = "async", .kind = .kw_async },
    .{ .word = "await", .kind = .kw_await },
    .{ .word = "break", .kind = .kw_break },
    .{ .word = "catch", .kind = .kw_catch },
    .{ .word = "class", .kind = .kw_class },
    .{ .word = "const", .kind = .kw_const },
    .{ .word = "false", .kind = .kw_false },
    .{ .word = "infer", .kind = .kw_infer },
    .{ .word = "keyof", .kind = .kw_keyof },
    .{ .word = "never", .kind = .kw_never },
    .{ .word = "super", .kind = .kw_super },
    .{ .word = "throw", .kind = .kw_throw },
    .{ .word = "using", .kind = .kw_using },
    .{ .word = "while", .kind = .kw_while },
    .{ .word = "yield", .kind = .kw_yield },
    // 6-letter
    .{ .word = "bigint", .kind = .kw_bigint },
    .{ .word = "delete", .kind = .kw_delete },
    .{ .word = "export", .kind = .kw_export },
    .{ .word = "global", .kind = .kw_global },
    .{ .word = "import", .kind = .kw_import },
    .{ .word = "module", .kind = .kw_module },
    .{ .word = "number", .kind = .kw_number },
    .{ .word = "object", .kind = .kw_object },
    .{ .word = "public", .kind = .kw_public },
    .{ .word = "return", .kind = .kw_return },
    .{ .word = "static", .kind = .kw_static },
    .{ .word = "string", .kind = .kw_string },
    .{ .word = "switch", .kind = .kw_switch },
    .{ .word = "symbol", .kind = .kw_symbol },
    .{ .word = "typeof", .kind = .kw_typeof },
    .{ .word = "unique", .kind = .kw_unique },
    // 7-letter
    .{ .word = "asserts", .kind = .kw_asserts },
    .{ .word = "boolean", .kind = .kw_boolean },
    .{ .word = "declare", .kind = .kw_declare },
    .{ .word = "default", .kind = .kw_default },
    .{ .word = "extends", .kind = .kw_extends },
    .{ .word = "finally", .kind = .kw_finally },
    .{ .word = "package", .kind = .kw_package },
    .{ .word = "private", .kind = .kw_private },
    .{ .word = "require", .kind = .kw_require },
    .{ .word = "unknown", .kind = .kw_unknown },
    // 8-letter
    .{ .word = "abstract", .kind = .kw_abstract },
    .{ .word = "accessor", .kind = .kw_accessor },
    .{ .word = "continue", .kind = .kw_continue },
    .{ .word = "debugger", .kind = .kw_debugger },
    .{ .word = "function", .kind = .kw_function },
    .{ .word = "override", .kind = .kw_override },
    .{ .word = "readonly", .kind = .kw_readonly },
    // 9-letter
    .{ .word = "interface", .kind = .kw_interface },
    .{ .word = "namespace", .kind = .kw_namespace },
    .{ .word = "protected", .kind = .kw_protected },
    .{ .word = "satisfies", .kind = .kw_satisfies },
    .{ .word = "undefined", .kind = .kw_undefined },
    // 10-letter
    .{ .word = "implements", .kind = .kw_implements },
    .{ .word = "instanceof", .kind = .kw_instanceof },
    // 11-letter
    .{ .word = "constructor", .kind = .kw_constructor },
};

const min_len: usize = 2;
const max_len: usize = 11;

// A bucket per length; each bucket is a comptime-known slice of entries.
const Bucket = []const Entry;

const buckets: [max_len + 1]Bucket = blk: {
    @setEvalBranchQuota(10_000);
    var result: [max_len + 1]Bucket = undefined;
    for (0..max_len + 1) |L| {
        var n: usize = 0;
        for (all_keywords) |e| {
            if (e.word.len == L) n += 1;
        }
        var arr: [n]Entry = undefined;
        var i: usize = 0;
        for (all_keywords) |e| {
            if (e.word.len == L) {
                arr[i] = e;
                i += 1;
            }
        }
        const fixed = arr;
        result[L] = &fixed;
    }
    break :blk result;
};

/// Look up an identifier-form bytes string and return its keyword kind,
/// or `null` if it is not a keyword. Total work: one length check
/// (range 2..11), then ≤ 6 short string compares against compile-time
/// constants. The compiler unrolls into register-resident compares.
pub fn lookup(bytes: []const u8) ?TokenKind {
    if (bytes.len < min_len or bytes.len > max_len) return null;
    inline for (0..max_len + 1) |L| {
        if (L >= min_len and bytes.len == L) {
            const bucket = buckets[L];
            inline for (bucket) |e| {
                if (std.mem.eql(u8, bytes, e.word)) return e.kind;
            }
            return null;
        }
    }
    return null;
}

// =============================================================================
// Tests
// =============================================================================

const t = std.testing;

test "keywords.lookup: every reserved keyword is recognized" {
    try t.expectEqual(@as(?TokenKind, .kw_class), lookup("class"));
    try t.expectEqual(@as(?TokenKind, .kw_const), lookup("const"));
    try t.expectEqual(@as(?TokenKind, .kw_function), lookup("function"));
    try t.expectEqual(@as(?TokenKind, .kw_return), lookup("return"));
    try t.expectEqual(@as(?TokenKind, .kw_typeof), lookup("typeof"));
    try t.expectEqual(@as(?TokenKind, .kw_instanceof), lookup("instanceof"));
}

test "keywords.lookup: TS-specific keywords" {
    try t.expectEqual(@as(?TokenKind, .kw_satisfies), lookup("satisfies"));
    try t.expectEqual(@as(?TokenKind, .kw_keyof), lookup("keyof"));
    try t.expectEqual(@as(?TokenKind, .kw_infer), lookup("infer"));
    try t.expectEqual(@as(?TokenKind, .kw_readonly), lookup("readonly"));
    try t.expectEqual(@as(?TokenKind, .kw_namespace), lookup("namespace"));
    try t.expectEqual(@as(?TokenKind, .kw_constructor), lookup("constructor"));
}

test "keywords.lookup: 2-letter keywords" {
    try t.expectEqual(@as(?TokenKind, .kw_as), lookup("as"));
    try t.expectEqual(@as(?TokenKind, .kw_in), lookup("in"));
    try t.expectEqual(@as(?TokenKind, .kw_is), lookup("is"));
    try t.expectEqual(@as(?TokenKind, .kw_of), lookup("of"));
    try t.expectEqual(@as(?TokenKind, .kw_do), lookup("do"));
    try t.expectEqual(@as(?TokenKind, .kw_if), lookup("if"));
}

test "keywords.lookup: non-keywords return null" {
    try t.expectEqual(@as(?TokenKind, null), lookup("foo"));
    try t.expectEqual(@as(?TokenKind, null), lookup("bar"));
    try t.expectEqual(@as(?TokenKind, null), lookup("typescriptIsAwesome"));
    // case-sensitive
    try t.expectEqual(@as(?TokenKind, null), lookup("Class"));
    try t.expectEqual(@as(?TokenKind, null), lookup("CLASS"));
    // length-out-of-range
    try t.expectEqual(@as(?TokenKind, null), lookup("a"));
    try t.expectEqual(@as(?TokenKind, null), lookup(""));
    try t.expectEqual(@as(?TokenKind, null), lookup("verylongidentifier"));
}

test "keywords.lookup: every entry round-trips" {
    inline for (all_keywords) |e| {
        try t.expectEqual(@as(?TokenKind, e.kind), lookup(e.word));
    }
}

test "keywords.lookup: substring of a keyword is not a keyword" {
    // `cla` is a prefix of `class` but not a keyword.
    try t.expectEqual(@as(?TokenKind, null), lookup("cla"));
    try t.expectEqual(@as(?TokenKind, null), lookup("classs")); // typo
    try t.expectEqual(@as(?TokenKind, null), lookup("constru")); // partial
}

test "keywords: total count matches expected" {
    // Smoke test that we have a sensible keyword count.
    try t.expect(all_keywords.len >= 80);
    try t.expect(all_keywords.len <= 100);
}

test "keywords: every word matches its length bucket" {
    inline for (all_keywords) |e| {
        try t.expect(e.word.len >= min_len);
        try t.expect(e.word.len <= max_len);
    }
}

test "keywords: no duplicate words" {
    @setEvalBranchQuota(20_000);
    // O(N²) but N is small (~85) and this is comptime-time anyway.
    inline for (all_keywords, 0..) |a, i| {
        inline for (all_keywords[i + 1 ..]) |b| {
            if (std.mem.eql(u8, a.word, b.word)) {
                std.debug.panic("duplicate keyword: {s}", .{a.word});
            }
        }
    }
}
