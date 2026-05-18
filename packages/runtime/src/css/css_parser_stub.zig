// css_parser_stub.zig
//
// Home-original stub of bun/src/css/css_parser.zig (NOT a verbatim copy).
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6 is the reference. MIT context —
// see ../cli/LICENSE.bun.md.
//
// The real `css_parser.zig` is a ~4 kLOC module that pulls in 80+ siblings
// (Selectors / Tokenizer / Printer / DeclarationBlock / TokenList / SmallList /
// the entire `css_properties.*` + `css_rules.*` + `css_values.*` trees). None of
// that has landed in `home_rt` yet, so individual css leaves cannot
// `@import("../css_parser.zig")` until the substrate ports.
//
// Strategy B (per wave-7 port plan): provide a thin, locally-defined surface
// with just enough opaques + comptime helpers to let pure-data leaves resolve
// their references at compile time. Method bodies that would normally call
// into a Parser / Printer return placeholder values or trip
// `@compileError("css_parser not yet ported")` — leaves that exercise runtime
// paths (the printer, the tokenizer) are still parked on the upstream port.
//
// Public surface (only what wave-7 leaves reach for):
//   - `Result(T)`            — placeholder union mirroring the `Maybe(T, E)`
//                              shape used at upstream call sites.
//   - `Parser`, `Printer`    — opaque structs; no methods (callers go through
//                              `@compileError` if they try to use them at
//                              runtime).
//   - `PrintErr`             — error set carrying the single `CSSPrintError`
//                              variant the leaves bubble up.
//   - `Location`             — pure-data `{source_index, line, column}`; lifted
//                              verbatim from `rules/rules.zig`.
//   - `DeclarationBlock`,
//     `TokenList`            — opaque empty structs.
//   - `VendorPrefix`         — packed u8 mirroring upstream's bit layout, with
//                              the constructor constants (`NONE`/`WEBKIT`/…)
//                              and the `toCss` stub.
//   - `DefineEnumProperty`,
//     `DeriveParse`,
//     `DeriveToCss`          — comptime helpers that fabricate matching
//                              `parse`/`toCss` decls so leaves type-check.
//   - `implementEql`,
//     `implementHash`,
//     `implementDeepClone`   — placeholder stand-ins. `Eql` returns `false`;
//                              the others trip `@compileError` at instantiation
//                              if a runtime path reaches them.
//
// When upstream `css_parser.zig` finally lands, every consumer rewrites
// `@import("./css_parser_stub.zig")` → `@import("../css_parser.zig")` and this
// file is removed.

const std = @import("std");

// ---- Result -----------------------------------------------------------------

/// Mirrors `Maybe(T, ParseError(ParserError))` from upstream — the only shape
/// css leaves spell at call sites is `.result = ...` / `.err = ...`.
pub fn Result(comptime T: type) type {
    return union(enum) {
        result: T,
        err: ParseError,

        pub fn asErr(self: @This()) ?ParseError {
            return switch (self) {
                .err => |e| e,
                else => null,
            };
        }

        pub fn isOk(self: @This()) bool {
            return self == .result;
        }
    };
}

/// Placeholder error payload; real type pulls in `errors_.ParseError` +
/// `errors_.ParserError` from upstream.
pub const ParseError = struct {
    /// Source byte offset of the error (zero if unknown).
    offset: u32 = 0,
};

pub const PrintErr = error{CSSPrintError};

// ---- Opaques ----------------------------------------------------------------

/// Opaque-ish struct (single dummy field) so leaves can spell `*Parser`
/// without taking a method on it. Real Parser carries ~30 fields and 100+
/// methods — `tryParse`, `expectDelim`, `expectString`, `expectNumber`,
/// `newCustomError`, … — all parked.
pub const Parser = struct {
    _unused: u8 = 0,

    pub fn expectDelim(_: *Parser, _: u8) Result(void) {
        @compileError("css_parser not yet ported — Parser.expectDelim");
    }

    pub fn expectString(_: *Parser) Result([]const u8) {
        @compileError("css_parser not yet ported — Parser.expectString");
    }
};

/// Same opaque-ish shape as Parser. Methods that leaves' `toCss`
/// implementations call (`writeStr`, `writeChar`, `whitespace`, `indent`,
/// `dedent`, `newline`, `delim`, `addFmtError`, `context`) are stubbed as
/// `@compileError` so they fail loud if exercised at runtime; this is the
/// signal that the caller leaf still needs the real `css_parser` port.
pub const Printer = struct {
    _unused: u8 = 0,

    pub fn writeStr(_: *Printer, _: []const u8) PrintErr!void {
        @compileError("css_parser not yet ported — Printer.writeStr");
    }
    pub fn writeChar(_: *Printer, _: u8) PrintErr!void {
        @compileError("css_parser not yet ported — Printer.writeChar");
    }
    pub fn whitespace(_: *Printer) PrintErr!void {
        @compileError("css_parser not yet ported — Printer.whitespace");
    }
    pub fn newline(_: *Printer) PrintErr!void {
        @compileError("css_parser not yet ported — Printer.newline");
    }
    pub fn indent(_: *Printer) void {
        @compileError("css_parser not yet ported — Printer.indent");
    }
    pub fn dedent(_: *Printer) void {
        @compileError("css_parser not yet ported — Printer.dedent");
    }
    pub fn delim(_: *Printer, _: u8, _: bool) PrintErr!void {
        @compileError("css_parser not yet ported — Printer.delim");
    }
    pub fn addFmtError(_: *Printer) PrintErr {
        @compileError("css_parser not yet ported — Printer.addFmtError");
    }
    pub fn context(_: *Printer) ?*anyopaque {
        @compileError("css_parser not yet ported — Printer.context");
    }
};

pub const DeclarationBlock = struct {
    pub fn toCssBlock(_: *const DeclarationBlock, _: *Printer) PrintErr!void {
        @compileError("css_parser not yet ported — DeclarationBlock.toCssBlock");
    }
};

pub const TokenList = struct {
    /// Real upstream type has `.v: std.ArrayList(TokenOrValue)` plus methods;
    /// the field exists here so `unknown.zig`'s `prelude.v.items.len` reference
    /// type-checks. Length is fixed to zero in the stub.
    v: struct {
        items: []const u8 = &.{},
    } = .{},

    pub fn toCss(_: *const TokenList, _: *Printer, _: bool) PrintErr!void {
        @compileError("css_parser not yet ported — TokenList.toCss");
    }
};

// ---- Location ---------------------------------------------------------------

/// Verbatim from upstream rules/rules.zig:Location.
pub const Location = struct {
    source_index: u32,
    line: u32,
    column: u32,

    pub fn dummy() Location {
        return .{
            .source_index = std.math.maxInt(u32),
            .line = std.math.maxInt(u32),
            .column = std.math.maxInt(u32),
        };
    }
};

// ---- VendorPrefix -----------------------------------------------------------

/// Bit-compatible with upstream `VendorPrefix`. Methods that would write to
/// a Printer trip `@compileError`; the constants are real.
pub const VendorPrefix = packed struct(u8) {
    none: bool = false,
    webkit: bool = false,
    moz: bool = false,
    ms: bool = false,
    o: bool = false,
    __unused: u3 = 0,

    pub const empty = VendorPrefix{};
    pub const all = VendorPrefix{
        .none = true,
        .moz = true,
        .ms = true,
        .o = true,
        .webkit = true,
    };

    pub const NONE = VendorPrefix{ .none = true };
    pub const WEBKIT = VendorPrefix{ .webkit = true };
    pub const MOZ = VendorPrefix{ .moz = true };
    pub const MS = VendorPrefix{ .ms = true };
    pub const O = VendorPrefix{ .o = true };

    pub const FIELDS: []const []const u8 = &.{ "webkit", "moz", "ms", "o", "none" };

    pub fn toCss(_: *const VendorPrefix, _: *Printer) PrintErr!void {
        @compileError("css_parser not yet ported — VendorPrefix.toCss requires a real Printer");
    }
};

// ---- Comptime helpers -------------------------------------------------------

/// Fabricates the same `{ parse, toCss, eql, deepClone, hash }` surface that
/// upstream's `DefineEnumProperty` generates. The runtime paths trip
/// `@compileError`; leaves that only spell the names through
/// `pub const Foo = css.DefineEnumProperty(...)` still compile.
pub fn DefineEnumProperty(comptime _: anytype) type {
    return struct {
        pub fn parse(_: *Parser) Result(@This()) {
            @compileError("css_parser not yet ported — DefineEnumProperty.parse");
        }
        pub fn toCss(_: *const @This(), _: *Printer) PrintErr!void {
            @compileError("css_parser not yet ported — DefineEnumProperty.toCss");
        }
    };
}

pub fn DeriveParse(comptime T: type) type {
    return struct {
        pub fn parse(_: *Parser) Result(T) {
            @compileError("css_parser not yet ported — DeriveParse.parse");
        }
    };
}

pub fn DeriveToCss(comptime T: type) type {
    return struct {
        pub fn toCss(_: *const T, _: *Printer) PrintErr!void {
            @compileError("css_parser not yet ported — DeriveToCss.toCss");
        }
    };
}

pub fn implementEql(comptime _: type, _: anytype, _: anytype) bool {
    // `eql` is the most common method on css value structs and is called from
    // comptime tests + a few cross-leaf invariants. Returning `false`
    // unconditionally is the conservative stub — real impls re-attach with
    // css_parser.
    return false;
}

pub fn implementHash(comptime _: type, _: anytype, _: *std.hash.Wyhash) void {
    @compileError("css_parser not yet ported — implementHash");
}

pub fn implementDeepClone(comptime T: type, this: *const T, _: std.mem.Allocator) T {
    // Shallow copy is correct for the pure-data leaves wave-7 lands; structs
    // that own heap-backed `TokenList`s / `DeclarationBlock`s replace this
    // when css_parser ports.
    return this.*;
}

// ---- Sub-namespace placeholders --------------------------------------------

/// Mirrors the `css.todo_stuff.depth` sentinel some unfinished upstream files
/// reference. Surfaced as a `@compileError` so any leaf that touches it fails
/// loud at copy time.
pub const todo_stuff = struct {
    pub const depth = "todo_stuff.depth — leaf parked on css_parser port";
};

/// Top-level `Ident` alias upstream resolves to `css_values.ident.Ident`,
/// which is `[]const u8`. Leaves spell it as both `css.Ident` and
/// `css.css_values.ident.Ident` so we re-export both paths.
pub const Ident = []const u8;
pub const CustomIdent = []const u8;
pub const CSSString = []const u8;

/// Generic `CssRuleList(R)` placeholder. Real upstream owns an
/// `ArrayList(CssRule(R))` and has methods `toCss` / `minify` / `deepClone`.
/// For wave-7's `MozDocumentRule(R)`, `NestingRule(R)`, `StartingStyleRule(R)`
/// leaves we only need the type to resolve at the field-declaration site.
pub fn CssRuleList(comptime R: type) type {
    return struct {
        _phantom: ?*R = null,

        pub fn toCss(_: *const @This(), _: *Printer) PrintErr!void {
            @compileError("css_parser not yet ported — CssRuleList.toCss");
        }
    };
}

/// Mirror of the `css.css_properties.*` sub-namespace touched by wave-7
/// leaves (`outline.zig` reaches for `border.GenericBorder`+`border.LineStyle`).
pub const css_properties = struct {
    pub const border = struct {
        /// Placeholder `GenericBorder(S, P)` carrying only the comptime-shape
        /// `outline.zig` needs (`style: S` plus matching default()).
        pub fn GenericBorder(comptime S: type, comptime P: u8) type {
            return struct {
                style: S,

                pub const VENDOR_PREFIX: u8 = P;

                pub fn default() @This() {
                    return .{ .style = S.default() };
                }

                pub fn eql(_: *const @This(), _: *const @This()) bool {
                    return false;
                }

                pub fn deepClone(this: *const @This(), _: std.mem.Allocator) @This() {
                    return this.*;
                }
            };
        }

        /// Surface-only stand-in for upstream's `LineStyle` enum. The real
        /// list is `{none, hidden, inset, groove, outset, ridge, dotted,
        /// dashed, solid, double}`; we keep those tags here so `OutlineStyle`
        /// in outline.zig compiles unchanged.
        pub const LineStyle = enum {
            none,
            hidden,
            inset,
            groove,
            outset,
            ridge,
            dotted,
            dashed,
            solid,
            double,

            pub fn default() LineStyle {
                return .none;
            }
        };
    };
};

/// Mirror of the `css.css_rules.*` sub-namespace touched by wave-7 leaves.
pub const css_rules = struct {
    pub const Location = @import("./css_parser_stub.zig").Location;
    pub const style = struct {
        /// Generic placeholder for `style.StyleRule(R)`. Real upstream
        /// carries `selectors`, `vendor_prefixes`, `declarations`, `rules`,
        /// `loc`; only the type-name and a stub `toCss` are needed for
        /// `NestingRule(R)` to compile.
        pub fn StyleRule(comptime R: type) type {
            return struct {
                _phantom: ?*R = null,

                pub fn toCss(_: *const @This(), _: *Printer) PrintErr!void {
                    @compileError("css_parser not yet ported — StyleRule.toCss");
                }
            };
        }
    };
};

/// Mirror of the `css.css_values.*` sub-namespace surface used by wave-7
/// leaves: `string.CSSStringFns`, `ident.Ident`/`IdentFns`/`CustomIdent`/
/// `CustomIdentFns`. Methods that need a real Printer trip `@compileError`.
pub const css_values = struct {
    pub const string = struct {
        pub const CSSString = []const u8;
        pub const CSSStringFns = struct {
            pub fn toCss(_: *const []const u8, _: *Printer) PrintErr!void {
                @compileError("css_parser not yet ported — CSSStringFns.toCss");
            }
            pub fn parse(_: *Parser) Result([]const u8) {
                @compileError("css_parser not yet ported — CSSStringFns.parse");
            }
        };
    };
    pub const ident = struct {
        pub const Ident = []const u8;
        pub const IdentFns = struct {
            pub fn toCss(_: *const []const u8, _: *Printer) PrintErr!void {
                @compileError("css_parser not yet ported — IdentFns.toCss");
            }
        };
        pub const CustomIdent = []const u8;
        pub const CustomIdentFns = struct {
            pub fn toCss(_: *const []const u8, _: *Printer) PrintErr!void {
                @compileError("css_parser not yet ported — CustomIdentFns.toCss");
            }
        };
    };
    pub const number = struct {
        pub const CSSNumber = f32;
        pub const CSSNumberFns = struct {
            pub fn parse(_: *Parser) Result(CSSNumber) {
                @compileError("css_parser not yet ported — CSSNumberFns.parse");
            }
            pub fn toCss(_: *const CSSNumber, _: *Printer) PrintErr!void {
                @compileError("css_parser not yet ported — CSSNumberFns.toCss");
            }
        };
    };
    pub const percentage = struct {
        /// Used by `alpha.zig` — real upstream is a tagged union; the stub
        /// keeps it as an opaque struct so the type name resolves. The
        /// `parse` path trips `@compileError`.
        pub const NumberOrPercentage = union(enum) {
            number: f32,
            percentage: struct { v: f32 },

            pub fn parse(_: *Parser) Result(NumberOrPercentage) {
                @compileError("css_parser not yet ported — NumberOrPercentage.parse");
            }
        };
    };
};

// ---- Tests ------------------------------------------------------------------

test "Result(T) tags work" {
    const R = Result(u32);
    const ok: R = .{ .result = 7 };
    const err: R = .{ .err = .{ .offset = 12 } };
    try std.testing.expect(ok.isOk());
    try std.testing.expect(!err.isOk());
    try std.testing.expectEqual(@as(?ParseError, .{ .offset = 12 }), err.asErr());
}

test "Location.dummy returns sentinel values" {
    const loc = Location.dummy();
    try std.testing.expectEqual(std.math.maxInt(u32), loc.source_index);
    try std.testing.expectEqual(std.math.maxInt(u32), loc.line);
    try std.testing.expectEqual(std.math.maxInt(u32), loc.column);
}

test "VendorPrefix constants pack correctly" {
    try std.testing.expectEqual(@as(u8, 0b00000001), @as(u8, @bitCast(VendorPrefix.NONE)));
    try std.testing.expectEqual(@as(u8, 0b00000010), @as(u8, @bitCast(VendorPrefix.WEBKIT)));
    try std.testing.expectEqual(@as(u8, 0b00000100), @as(u8, @bitCast(VendorPrefix.MOZ)));
    try std.testing.expectEqual(@as(u8, 0b00001000), @as(u8, @bitCast(VendorPrefix.MS)));
    try std.testing.expectEqual(@as(u8, 0b00010000), @as(u8, @bitCast(VendorPrefix.O)));
}

test "VendorPrefix.empty is zero" {
    try std.testing.expectEqual(@as(u8, 0), @as(u8, @bitCast(VendorPrefix.empty)));
}

test "TokenList default has zero items" {
    const tl = TokenList{};
    try std.testing.expectEqual(@as(usize, 0), tl.v.items.len);
}

test "PrintErr error set contains CSSPrintError" {
    const e: PrintErr = error.CSSPrintError;
    try std.testing.expectEqual(@as(PrintErr, error.CSSPrintError), e);
}
