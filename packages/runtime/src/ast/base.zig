// Home Runtime — ported from Bun.
// Upstream:  packages/runtime/upstream/src/ast/base.zig
// Pinned SHA: fd0b6f1a271fca0b8124b69f230b100f4d636af6
//
// Renames applied (per packages/runtime/README.md naming convention):
//   - `@import("bun")` -> `@import("home")`
//   - `bun.Environment.allow_assert` -> `home_rt.Environment.allow_assert`
//   - `bun.hash(...)` -> local `wyhashU64` wrapper around the Home wyhash.
//
// **Symbol-dependent surface dropped**: `Ref.dump` and the
// `DumpImplData`/`dumpImpl` helpers require the full pretty-printer path and
// remain parked. `Ref.getSymbol` is restored now that the parser/printer
// bridge compiles against Home's copied `ast.Symbol` graph.

pub const RefHashCtx = struct {
    pub fn hash(_: @This(), key: Ref) u32 {
        return key.hash();
    }

    pub fn eql(_: @This(), ref: Ref, b: Ref, _: usize) bool {
        return ref.asU64() == b.asU64();
    }
};

pub const RefCtx = struct {
    pub fn hash(_: @This(), key: Ref) u64 {
        return key.hash64();
    }

    pub fn eql(_: @This(), ref: Ref, b: Ref) bool {
        return ref.asU64() == b.asU64();
    }
};

/// In some parts of Bun, we have many different IDs pointing to different things.
/// It's easy for them to get mixed up, so we use this type to make sure we don't.
pub const Index = packed struct(u32) {
    value: Int,

    pub fn set(this: *Index, val: Int) void {
        this.value = val;
    }

    /// if you are within the parser, use p.isSourceRuntime() instead, as the
    /// runtime index (0) is used as the id for single-file transforms.
    pub inline fn isRuntime(this: Index) bool {
        return this.value == (comptime runtime.value);
    }

    pub const invalid = Index{ .value = std.math.maxInt(Int) };
    pub const runtime = Index{ .value = 0 };

    pub const bake_server_data = Index{ .value = 1 };
    pub const bake_client_data = Index{ .value = 2 };

    pub const Int = u32;

    pub inline fn source(num: anytype) Index {
        return .{ .value = @as(Int, @truncate(num)) };
    }

    pub inline fn part(num: anytype) Index {
        return .{ .value = @as(Int, @truncate(num)) };
    }

    pub fn init(num: anytype) Index {
        const NumType = @TypeOf(num);
        if (comptime @typeInfo(NumType) == .pointer) {
            return init(num.*);
        }

        if (comptime home_rt.Environment.allow_assert) {
            return .{
                .value = @as(Int, @intCast(num)),
            };
        }

        return .{
            .value = @as(Int, @intCast(num)),
        };
    }

    pub inline fn isValid(this: Index) bool {
        return this.value != invalid.value;
    }

    pub inline fn isInvalid(this: Index) bool {
        return !this.isValid();
    }

    pub inline fn get(this: Index) Int {
        return this.value;
    }
};

/// -- original comment from esbuild --
///
/// Files are parsed in parallel for speed. We want to allow each parser to
/// generate symbol IDs that won't conflict with each other. We also want to be
/// able to quickly merge symbol tables from all files into one giant symbol
/// table.
///
/// We can accomplish both goals by giving each symbol ID two parts: a source
/// index that is unique to the parser goroutine, and an inner index that
/// increments as the parser generates new symbol IDs. Then a symbol map can
/// be an array of arrays indexed first by source index, then by inner index.
/// The maps can be merged quickly by creating a single outer array containing
/// all inner arrays from all parsed files.
pub const Ref = packed struct(u64) {
    pub const Int = u31;

    inner_index: Int = 0,

    tag: enum(u2) {
        invalid,
        allocated_name,
        source_contents_slice,
        symbol,
    },

    source_index: Int = 0,

    /// Represents a null state without using an extra bit
    pub const None = Ref{ .inner_index = 0, .source_index = 0, .tag = .invalid };

    comptime {
        home_rt.assert(None.isEmpty());
    }

    pub inline fn isEmpty(this: Ref) bool {
        return this.asU64() == 0;
    }

    pub const ArrayHashCtx = RefHashCtx;
    pub const HashCtx = RefCtx;

    pub fn isSourceIndexNull(this: anytype) bool {
        return this == std.math.maxInt(Int);
    }

    pub fn isSymbol(this: Ref) bool {
        return this.tag == .symbol;
    }

    pub fn format(ref: Ref, writer: *std.Io.Writer) !void {
        try writer.print(
            "Ref[inner={d}, src={d}, .{s}]",
            .{
                ref.innerIndex(),
                ref.sourceIndex(),
                @tagName(ref.tag),
            },
        );
    }

    // NOTE: `Ref.dump(symbol_table)` and `Ref.getSymbol(symbol_table)` from
    // upstream require `ast.Symbol`, which lands when the full AST is ported.

    pub fn isValid(this: Ref) bool {
        return this.tag != .invalid;
    }

    pub inline fn sourceIndex(this: Ref) Int {
        return this.source_index;
    }

    pub inline fn innerIndex(this: Ref) Int {
        return this.inner_index;
    }

    pub inline fn isSourceContentsSlice(this: Ref) bool {
        return this.tag == .source_contents_slice;
    }

    pub fn init(inner_index: Int, source_index: u32, is_source_contents_slice: bool) Ref {
        return .{
            .inner_index = inner_index,
            .source_index = @intCast(source_index),
            .tag = if (is_source_contents_slice) .source_contents_slice else .allocated_name,
        };
    }

    pub fn initSourceEnd(old: Ref) Ref {
        home_rt.assert(old.tag != .invalid);
        return init(old.inner_index, old.source_index, old.tag == .source_contents_slice);
    }

    pub fn hash(key: Ref) u32 {
        return @truncate(key.hash64());
    }

    pub inline fn asU64(key: Ref) u64 {
        return @bitCast(key);
    }

    pub inline fn hash64(key: Ref) u64 {
        return wyhashU64(&@as([8]u8, @bitCast(key.asU64())));
    }

    pub fn eql(ref: Ref, other: Ref) bool {
        return ref.asU64() == other.asU64();
    }

    pub const isNull = isEmpty; // deprecated

    pub fn jsonStringify(self: *const Ref, writer: anytype) !void {
        return try writer.write([2]u32{ self.sourceIndex(), self.innerIndex() });
    }

    pub fn getSymbol(ref: Ref, symbol_table: anytype) *home_rt.ast.Symbol {
        const resolved_symbol_table = switch (@TypeOf(symbol_table)) {
            *const std.array_list.Managed(home_rt.ast.Symbol) => symbol_table.items,
            *std.array_list.Managed(home_rt.ast.Symbol) => symbol_table.items,
            []home_rt.ast.Symbol => symbol_table,
            []const home_rt.ast.Symbol => @constCast(symbol_table),
            *home_rt.ast.Symbol.Map => return symbol_table.get(ref) orelse unreachable,
            *const home_rt.ast.Symbol.Map => return @constCast(symbol_table.getConst(ref) orelse unreachable),
            else => |T| @compileError("Unsupported type to Ref.getSymbol: " ++ @typeName(T)),
        };
        return &resolved_symbol_table[ref.innerIndex()];
    }
};

/// Local Wyhash wrapper. Upstream calls `bun.hash(bytes)`, which is also
/// `Wyhash.hash(0, bytes)`; we use Home's vendored Wyhash11 with the same
/// `0` seed so the produced 64-bit values match (Ref hashes are not
/// persisted across the FFI boundary, so seed compatibility only matters
/// within a single process — but keeping it aligned reduces surprise).
fn wyhashU64(bytes: []const u8) u64 {
    return home_rt.wyhash.Wyhash11.hash(0, bytes);
}

const std = @import("std");

const home_rt = @import("home");

test "Index sentinels round-trip" {
    try std.testing.expect(Index.runtime.isRuntime());
    try std.testing.expect(!Index.invalid.isValid());
    try std.testing.expect(Index.invalid.isInvalid());
    try std.testing.expectEqual(@as(u32, 0), Index.runtime.get());
    try std.testing.expectEqual(@as(u32, 1), Index.bake_server_data.get());
    try std.testing.expectEqual(@as(u32, 2), Index.bake_client_data.get());
}

test "Index.init from comptime int + pointer" {
    const i: u16 = 42;
    const a = Index.init(i);
    const b = Index.init(&i);
    try std.testing.expectEqual(@as(u32, 42), a.get());
    try std.testing.expectEqual(a.get(), b.get());
}

test "Ref.None is empty and invalid" {
    try std.testing.expect(Ref.None.isEmpty());
    try std.testing.expect(!Ref.None.isValid());
    try std.testing.expect(!Ref.None.isSymbol());
    try std.testing.expectEqual(@as(u64, 0), Ref.None.asU64());
}

test "Ref.init produces correct tag and indices" {
    const r = Ref.init(7, 3, false);
    try std.testing.expectEqual(@as(u31, 7), r.innerIndex());
    try std.testing.expectEqual(@as(u31, 3), r.sourceIndex());
    try std.testing.expect(r.isValid());
    try std.testing.expect(!r.isSourceContentsSlice());

    const s = Ref.init(7, 3, true);
    try std.testing.expect(s.isSourceContentsSlice());
}

test "Ref.hash64 is stable + nonzero for non-empty refs" {
    const r = Ref.init(1, 1, false);
    const h1 = r.hash64();
    const h2 = r.hash64();
    try std.testing.expectEqual(h1, h2);
    try std.testing.expect(h1 != 0);
}

test "RefHashCtx / RefCtx equality is bitwise" {
    const r1 = Ref.init(5, 2, false);
    const r2 = Ref.init(5, 2, false);
    const r3 = Ref.init(5, 2, true);
    const ctx: RefHashCtx = .{};
    try std.testing.expect(ctx.eql(r1, r2, 0));
    try std.testing.expect(!ctx.eql(r1, r3, 0));
}
