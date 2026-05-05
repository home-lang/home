//! Layout descriptors for native code generation.
//!
//! Extracted verbatim from `native_codegen.zig` per TS_PARITY_PLAN §0
//! Phase 0.8. Pure data structures — no side effects, no embedded
//! methods (except for the `init`/`deinit` of `LoopContext`'s
//! `ArrayList` fixups, which the caller manages).
//!
//! Used by: `NativeCodegen` to track struct/enum/function/local-variable
//! layout while emitting machine code.

const std = @import("std");
const ast = @import("ast");

/// Layout information for a struct type, used during code generation.
///
/// Tracks field offsets, sizes, and total struct size to enable
/// efficient member access code generation. Computed once per struct
/// declaration.
pub const StructLayout = struct {
    /// Struct type name
    name: []const u8,
    /// Field layout information (ordered by declaration)
    fields: []const FieldInfo,
    /// Total size of the struct in bytes (including padding)
    total_size: usize,
};

/// Layout information for a single struct field.
///
/// Contains the offset and size needed to generate field access code.
pub const FieldInfo = struct {
    /// Field name
    name: []const u8,
    /// Byte offset from struct base pointer
    offset: usize,
    /// Size of field in bytes
    size: usize,
    /// Type name of the field (for nested member access)
    type_name: []const u8 = "",
};

/// Enum variant information.
pub const EnumVariantInfo = struct {
    /// Variant name
    name: []const u8,
    /// Optional data type (null for unit variants like None)
    data_type: ?[]const u8,
};

/// Enum layout information.
///
/// Maps enum variant names to their integer values (indices) and data types.
pub const EnumLayout = struct {
    /// Enum type name
    name: []const u8,
    /// Variant information (ordered by declaration)
    variants: []const EnumVariantInfo,
};

/// Loop context for break/continue statements.
///
/// Tracks loop entry and exit points for control flow jumps.
pub const LoopContext = struct {
    /// Position of loop start (condition test, used by while-continue)
    loop_start: usize,
    /// Position that `continue` should jump to. For while loops this
    /// equals loop_start (re-test condition). For for loops it points
    /// to the iterator increment so the counter advances before the
    /// next iteration. Null means "use loop_start".
    continue_target: ?usize = null,
    /// List of positions that need patching for break (jumps to end)
    break_fixups: std.ArrayList(usize),
    /// Positions emitted by continue that need patching to the increment
    continue_fixups: std.ArrayList(usize),
    /// Optional label for labeled break/continue
    label: ?[]const u8,
};

/// Local variable information.
///
/// Stores both stack location and type information for local variables.
pub const LocalInfo = struct {
    /// Stack offset from RBP (1-based index)
    offset: u32,
    /// Type name (e.g., "i32", "[i32]", "Point")
    type_name: []const u8,
    /// Size in bytes
    size: usize,
};

/// Function parameter information (for default values support).
pub const FunctionParamInfo = struct {
    /// Parameter name
    name: []const u8,
    /// Parameter type
    type_name: []const u8,
    /// Default value expression (null if no default)
    default_value: ?*ast.Expr,
};

/// Function info for code generation.
pub const FunctionInfo = struct {
    /// Code position
    position: usize,
    /// Parameters with default value info
    params: []FunctionParamInfo,
    /// Number of required parameters (without defaults)
    required_params: usize,
};

/// String literal fixup information.
/// Tracks where in the code we need to patch string addresses.
pub const StringFixup = struct {
    /// Position in code where the displacement was written
    code_pos: usize,
    /// Offset of the string in the data section
    data_offset: usize,
};

// =============================================================================
// Tests
// =============================================================================

const t = std.testing;

test "FieldInfo: defaults and zero-init" {
    const f: FieldInfo = .{
        .name = "x",
        .offset = 0,
        .size = 4,
    };
    try t.expectEqualStrings("x", f.name);
    try t.expectEqual(@as(usize, 0), f.offset);
    try t.expectEqual(@as(usize, 4), f.size);
    try t.expectEqualStrings("", f.type_name);
}

test "StructLayout: holds fields by reference" {
    const fields = [_]FieldInfo{
        .{ .name = "a", .offset = 0, .size = 4, .type_name = "i32" },
        .{ .name = "b", .offset = 4, .size = 4, .type_name = "i32" },
    };
    const layout: StructLayout = .{
        .name = "Point",
        .fields = &fields,
        .total_size = 8,
    };
    try t.expectEqualStrings("Point", layout.name);
    try t.expectEqual(@as(usize, 8), layout.total_size);
    try t.expectEqual(@as(usize, 2), layout.fields.len);
    try t.expectEqualStrings("a", layout.fields[0].name);
    try t.expectEqualStrings("b", layout.fields[1].name);
    try t.expectEqual(@as(usize, 4), layout.fields[1].offset);
}

test "EnumLayout: unit variant has null data_type" {
    const variants = [_]EnumVariantInfo{
        .{ .name = "None", .data_type = null },
        .{ .name = "Some", .data_type = "i32" },
    };
    const e: EnumLayout = .{ .name = "Option", .variants = &variants };
    try t.expectEqualStrings("Option", e.name);
    try t.expectEqual(@as(usize, 2), e.variants.len);
    try t.expectEqual(@as(?[]const u8, null), e.variants[0].data_type);
    try t.expectEqualStrings("i32", e.variants[1].data_type.?);
}

test "LocalInfo: round-trip" {
    const l: LocalInfo = .{ .offset = 1, .type_name = "i64", .size = 8 };
    try t.expectEqual(@as(u32, 1), l.offset);
    try t.expectEqualStrings("i64", l.type_name);
    try t.expectEqual(@as(usize, 8), l.size);
}

test "FunctionParamInfo: default_value is optional" {
    const p1: FunctionParamInfo = .{ .name = "x", .type_name = "i32", .default_value = null };
    try t.expectEqual(@as(?*ast.Expr, null), p1.default_value);
}

test "FunctionInfo: separates required from total params" {
    const params = [_]FunctionParamInfo{
        .{ .name = "x", .type_name = "i32", .default_value = null },
        .{ .name = "y", .type_name = "i32", .default_value = null },
    };
    const fi: FunctionInfo = .{
        .position = 0x200,
        .params = @constCast(&params),
        .required_params = 2,
    };
    try t.expectEqual(@as(usize, 0x200), fi.position);
    try t.expectEqual(@as(usize, 2), fi.required_params);
    try t.expectEqual(@as(usize, 2), fi.params.len);
}

test "StringFixup: round-trip" {
    const fx: StringFixup = .{ .code_pos = 100, .data_offset = 0x1000 };
    try t.expectEqual(@as(usize, 100), fx.code_pos);
    try t.expectEqual(@as(usize, 0x1000), fx.data_offset);
}

test "LoopContext: break_fixups and continue_fixups are caller-managed" {
    const allocator = t.allocator;
    var lc: LoopContext = .{
        .loop_start = 0x10,
        .continue_target = null,
        .break_fixups = std.ArrayList(usize).empty,
        .continue_fixups = std.ArrayList(usize).empty,
        .label = null,
    };
    defer {
        lc.break_fixups.deinit(allocator);
        lc.continue_fixups.deinit(allocator);
    }
    try lc.break_fixups.append(allocator, 0x20);
    try lc.continue_fixups.append(allocator, 0x30);
    try t.expectEqual(@as(usize, 1), lc.break_fixups.items.len);
    try t.expectEqual(@as(usize, 0x20), lc.break_fixups.items[0]);
    try t.expectEqual(@as(usize, 1), lc.continue_fixups.items.len);
    try t.expectEqual(@as(usize, 0x30), lc.continue_fixups.items[0]);
}
