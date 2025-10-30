const std = @import("std");
const TraitSystem = @import("traits.zig").TraitSystem;

/// Operator overloading traits for Home
/// Operators are implemented via traits, similar to Rust
/// This provides type-safe, explicit operator overloading

/// Add trait (+)
/// Allows types to be added together
pub const Add = struct {
    pub const name = "Add";
    pub const generic_params = [_][]const u8{"Rhs"};
    pub const associated_types = [_]TraitSystem.TraitDef.AssociatedType{
        .{ .name = "Output", .bounds = &[_][]const u8{} },
    };
    pub const methods = [_]TraitSystem.TraitDef.MethodSignature{
        .{
            .name = "add",
            .params = &[_]TraitSystem.TraitDef.MethodSignature.Param{
                .{ .name = "self", .type_name = "Self" },
                .{ .name = "rhs", .type_name = "Rhs" },
            },
            .return_type = "Self::Output",
            .is_async = false,
            .is_required = true,
        },
    };
};

/// Sub trait (-)
pub const Sub = struct {
    pub const name = "Sub";
    pub const generic_params = [_][]const u8{"Rhs"};
    pub const associated_types = [_]TraitSystem.TraitDef.AssociatedType{
        .{ .name = "Output", .bounds = &[_][]const u8{} },
    };
    pub const methods = [_]TraitSystem.TraitDef.MethodSignature{
        .{
            .name = "sub",
            .params = &[_]TraitSystem.TraitDef.MethodSignature.Param{
                .{ .name = "self", .type_name = "Self" },
                .{ .name = "rhs", .type_name = "Rhs" },
            },
            .return_type = "Self::Output",
            .is_async = false,
            .is_required = true,
        },
    };
};

/// Mul trait (*)
pub const Mul = struct {
    pub const name = "Mul";
    pub const generic_params = [_][]const u8{"Rhs"};
    pub const associated_types = [_]TraitSystem.TraitDef.AssociatedType{
        .{ .name = "Output", .bounds = &[_][]const u8{} },
    };
    pub const methods = [_]TraitSystem.TraitDef.MethodSignature{
        .{
            .name = "mul",
            .params = &[_]TraitSystem.TraitDef.MethodSignature.Param{
                .{ .name = "self", .type_name = "Self" },
                .{ .name = "rhs", .type_name = "Rhs" },
            },
            .return_type = "Self::Output",
            .is_async = false,
            .is_required = true,
        },
    };
};

/// Div trait (/)
pub const Div = struct {
    pub const name = "Div";
    pub const generic_params = [_][]const u8{"Rhs"};
    pub const associated_types = [_]TraitSystem.TraitDef.AssociatedType{
        .{ .name = "Output", .bounds = &[_][]const u8{} },
    };
    pub const methods = [_]TraitSystem.TraitDef.MethodSignature{
        .{
            .name = "div",
            .params = &[_]TraitSystem.TraitDef.MethodSignature.Param{
                .{ .name = "self", .type_name = "Self" },
                .{ .name = "rhs", .type_name = "Rhs" },
            },
            .return_type = "Self::Output",
            .is_async = false,
            .is_required = true,
        },
    };
};

/// Rem trait (%)
pub const Rem = struct {
    pub const name = "Rem";
    pub const generic_params = [_][]const u8{"Rhs"};
    pub const associated_types = [_]TraitSystem.TraitDef.AssociatedType{
        .{ .name = "Output", .bounds = &[_][]const u8{} },
    };
    pub const methods = [_]TraitSystem.TraitDef.MethodSignature{
        .{
            .name = "rem",
            .params = &[_]TraitSystem.TraitDef.MethodSignature.Param{
                .{ .name = "self", .type_name = "Self" },
                .{ .name = "rhs", .type_name = "Rhs" },
            },
            .return_type = "Self::Output",
            .is_async = false,
            .is_required = true,
        },
    };
};

/// Neg trait (unary -)
pub const Neg = struct {
    pub const name = "Neg";
    pub const associated_types = [_]TraitSystem.TraitDef.AssociatedType{
        .{ .name = "Output", .bounds = &[_][]const u8{} },
    };
    pub const methods = [_]TraitSystem.TraitDef.MethodSignature{
        .{
            .name = "neg",
            .params = &[_]TraitSystem.TraitDef.MethodSignature.Param{
                .{ .name = "self", .type_name = "Self" },
            },
            .return_type = "Self::Output",
            .is_async = false,
            .is_required = true,
        },
    };
};

/// Not trait (unary !)
pub const Not = struct {
    pub const name = "Not";
    pub const associated_types = [_]TraitSystem.TraitDef.AssociatedType{
        .{ .name = "Output", .bounds = &[_][]const u8{} },
    };
    pub const methods = [_]TraitSystem.TraitDef.MethodSignature{
        .{
            .name = "not",
            .params = &[_]TraitSystem.TraitDef.MethodSignature.Param{
                .{ .name = "self", .type_name = "Self" },
            },
            .return_type = "Self::Output",
            .is_async = false,
            .is_required = true,
        },
    };
};

/// BitAnd trait (&)
pub const BitAnd = struct {
    pub const name = "BitAnd";
    pub const generic_params = [_][]const u8{"Rhs"};
    pub const associated_types = [_]TraitSystem.TraitDef.AssociatedType{
        .{ .name = "Output", .bounds = &[_][]const u8{} },
    };
    pub const methods = [_]TraitSystem.TraitDef.MethodSignature{
        .{
            .name = "bitand",
            .params = &[_]TraitSystem.TraitDef.MethodSignature.Param{
                .{ .name = "self", .type_name = "Self" },
                .{ .name = "rhs", .type_name = "Rhs" },
            },
            .return_type = "Self::Output",
            .is_async = false,
            .is_required = true,
        },
    };
};

/// BitOr trait (|)
pub const BitOr = struct {
    pub const name = "BitOr";
    pub const generic_params = [_][]const u8{"Rhs"};
    pub const associated_types = [_]TraitSystem.TraitDef.AssociatedType{
        .{ .name = "Output", .bounds = &[_][]const u8{} },
    };
    pub const methods = [_]TraitSystem.TraitDef.MethodSignature{
        .{
            .name = "bitor",
            .params = &[_]TraitSystem.TraitDef.MethodSignature.Param{
                .{ .name = "self", .type_name = "Self" },
                .{ .name = "rhs", .type_name = "Rhs" },
            },
            .return_type = "Self::Output",
            .is_async = false,
            .is_required = true,
        },
    };
};

/// BitXor trait (^)
pub const BitXor = struct {
    pub const name = "BitXor";
    pub const generic_params = [_][]const u8{"Rhs"};
    pub const associated_types = [_]TraitSystem.TraitDef.AssociatedType{
        .{ .name = "Output", .bounds = &[_][]const u8{} },
    };
    pub const methods = [_]TraitSystem.TraitDef.MethodSignature{
        .{
            .name = "bitxor",
            .params = &[_]TraitSystem.TraitDef.MethodSignature.Param{
                .{ .name = "self", .type_name = "Self" },
                .{ .name = "rhs", .type_name = "Rhs" },
            },
            .return_type = "Self::Output",
            .is_async = false,
            .is_required = true,
        },
    };
};

/// Shl trait (<<)
pub const Shl = struct {
    pub const name = "Shl";
    pub const generic_params = [_][]const u8{"Rhs"};
    pub const associated_types = [_]TraitSystem.TraitDef.AssociatedType{
        .{ .name = "Output", .bounds = &[_][]const u8{} },
    };
    pub const methods = [_]TraitSystem.TraitDef.MethodSignature{
        .{
            .name = "shl",
            .params = &[_]TraitSystem.TraitDef.MethodSignature.Param{
                .{ .name = "self", .type_name = "Self" },
                .{ .name = "rhs", .type_name = "Rhs" },
            },
            .return_type = "Self::Output",
            .is_async = false,
            .is_required = true,
        },
    };
};

/// Shr trait (>>)
pub const Shr = struct {
    pub const name = "Shr";
    pub const generic_params = [_][]const u8{"Rhs"};
    pub const associated_types = [_]TraitSystem.TraitDef.AssociatedType{
        .{ .name = "Output", .bounds = &[_][]const u8{} },
    };
    pub const methods = [_]TraitSystem.TraitDef.MethodSignature{
        .{
            .name = "shr",
            .params = &[_]TraitSystem.TraitDef.MethodSignature.Param{
                .{ .name = "self", .type_name = "Self" },
                .{ .name = "rhs", .type_name = "Rhs" },
            },
            .return_type = "Self::Output",
            .is_async = false,
            .is_required = true,
        },
    };
};

/// AddAssign trait (+=)
pub const AddAssign = struct {
    pub const name = "AddAssign";
    pub const generic_params = [_][]const u8{"Rhs"};
    pub const methods = [_]TraitSystem.TraitDef.MethodSignature{
        .{
            .name = "add_assign",
            .params = &[_]TraitSystem.TraitDef.MethodSignature.Param{
                .{ .name = "self", .type_name = "&mut Self" },
                .{ .name = "rhs", .type_name = "Rhs" },
            },
            .return_type = null,
            .is_async = false,
            .is_required = true,
        },
    };
};

/// SubAssign trait (-=)
pub const SubAssign = struct {
    pub const name = "SubAssign";
    pub const generic_params = [_][]const u8{"Rhs"};
    pub const methods = [_]TraitSystem.TraitDef.MethodSignature{
        .{
            .name = "sub_assign",
            .params = &[_]TraitSystem.TraitDef.MethodSignature.Param{
                .{ .name = "self", .type_name = "&mut Self" },
                .{ .name = "rhs", .type_name = "Rhs" },
            },
            .return_type = null,
            .is_async = false,
            .is_required = true,
        },
    };
};

/// MulAssign trait (*=)
pub const MulAssign = struct {
    pub const name = "MulAssign";
    pub const generic_params = [_][]const u8{"Rhs"};
    pub const methods = [_]TraitSystem.TraitDef.MethodSignature{
        .{
            .name = "mul_assign",
            .params = &[_]TraitSystem.TraitDef.MethodSignature.Param{
                .{ .name = "self", .type_name = "&mut Self" },
                .{ .name = "rhs", .type_name = "Rhs" },
            },
            .return_type = null,
            .is_async = false,
            .is_required = true,
        },
    };
};

/// DivAssign trait (/=)
pub const DivAssign = struct {
    pub const name = "DivAssign";
    pub const generic_params = [_][]const u8{"Rhs"};
    pub const methods = [_]TraitSystem.TraitDef.MethodSignature{
        .{
            .name = "div_assign",
            .params = &[_]TraitSystem.TraitDef.MethodSignature.Param{
                .{ .name = "self", .type_name = "&mut Self" },
                .{ .name = "rhs", .type_name = "Rhs" },
            },
            .return_type = null,
            .is_async = false,
            .is_required = true,
        },
    };
};

/// RemAssign trait (%=)
pub const RemAssign = struct {
    pub const name = "RemAssign";
    pub const generic_params = [_][]const u8{"Rhs"};
    pub const methods = [_]TraitSystem.TraitDef.MethodSignature{
        .{
            .name = "rem_assign",
            .params = &[_]TraitSystem.TraitDef.MethodSignature.Param{
                .{ .name = "self", .type_name = "&mut Self" },
                .{ .name = "rhs", .type_name = "Rhs" },
            },
            .return_type = null,
            .is_async = false,
            .is_required = true,
        },
    };
};

/// Index trait ([])
pub const Index = struct {
    pub const name = "Index";
    pub const generic_params = [_][]const u8{"Idx"};
    pub const associated_types = [_]TraitSystem.TraitDef.AssociatedType{
        .{ .name = "Output", .bounds = &[_][]const u8{} },
    };
    pub const methods = [_]TraitSystem.TraitDef.MethodSignature{
        .{
            .name = "index",
            .params = &[_]TraitSystem.TraitDef.MethodSignature.Param{
                .{ .name = "self", .type_name = "&Self" },
                .{ .name = "index", .type_name = "Idx" },
            },
            .return_type = "&Self::Output",
            .is_async = false,
            .is_required = true,
        },
    };
};

/// IndexMut trait ([] for mutable access)
pub const IndexMut = struct {
    pub const name = "IndexMut";
    pub const generic_params = [_][]const u8{"Idx"};
    pub const super_traits = [_][]const u8{"Index<Idx>"};
    pub const methods = [_]TraitSystem.TraitDef.MethodSignature{
        .{
            .name = "index_mut",
            .params = &[_]TraitSystem.TraitDef.MethodSignature.Param{
                .{ .name = "self", .type_name = "&mut Self" },
                .{ .name = "index", .type_name = "Idx" },
            },
            .return_type = "&mut Self::Output",
            .is_async = false,
            .is_required = true,
        },
    };
};

/// Deref trait (*)
pub const Deref = struct {
    pub const name = "Deref";
    pub const associated_types = [_]TraitSystem.TraitDef.AssociatedType{
        .{ .name = "Target", .bounds = &[_][]const u8{} },
    };
    pub const methods = [_]TraitSystem.TraitDef.MethodSignature{
        .{
            .name = "deref",
            .params = &[_]TraitSystem.TraitDef.MethodSignature.Param{
                .{ .name = "self", .type_name = "&Self" },
            },
            .return_type = "&Self::Target",
            .is_async = false,
            .is_required = true,
        },
    };
};

/// DerefMut trait (* for mutable access)
pub const DerefMut = struct {
    pub const name = "DerefMut";
    pub const super_traits = [_][]const u8{"Deref"};
    pub const methods = [_]TraitSystem.TraitDef.MethodSignature{
        .{
            .name = "deref_mut",
            .params = &[_]TraitSystem.TraitDef.MethodSignature.Param{
                .{ .name = "self", .type_name = "&mut Self" },
            },
            .return_type = "&mut Self::Target",
            .is_async = false,
            .is_required = true,
        },
    };
};

/// Operator to trait mapping
pub const OperatorTraitMap = struct {
    pub fn getTraitForBinaryOp(op: []const u8) ?[]const u8 {
        const map = std.StaticStringMap([]const u8).initComptime(.{
            .{ "+", "Add" },
            .{ "-", "Sub" },
            .{ "*", "Mul" },
            .{ "/", "Div" },
            .{ "%", "Rem" },
            .{ "&", "BitAnd" },
            .{ "|", "BitOr" },
            .{ "^", "BitXor" },
            .{ "<<", "Shl" },
            .{ ">>", "Shr" },
            .{ "+=", "AddAssign" },
            .{ "-=", "SubAssign" },
            .{ "*=", "MulAssign" },
            .{ "/=", "DivAssign" },
            .{ "%=", "RemAssign" },
        });
        return map.get(op);
    }

    pub fn getTraitForUnaryOp(op: []const u8) ?[]const u8 {
        const map = std.StaticStringMap([]const u8).initComptime(.{
            .{ "-", "Neg" },
            .{ "!", "Not" },
            .{ "*", "Deref" },
        });
        return map.get(op);
    }

    pub fn getMethodForBinaryOp(op: []const u8) ?[]const u8 {
        const map = std.StaticStringMap([]const u8).initComptime(.{
            .{ "+", "add" },
            .{ "-", "sub" },
            .{ "*", "mul" },
            .{ "/", "div" },
            .{ "%", "rem" },
            .{ "&", "bitand" },
            .{ "|", "bitor" },
            .{ "^", "bitxor" },
            .{ "<<", "shl" },
            .{ ">>", "shr" },
            .{ "+=", "add_assign" },
            .{ "-=", "sub_assign" },
            .{ "*=", "mul_assign" },
            .{ "/=", "div_assign" },
            .{ "%=", "rem_assign" },
        });
        return map.get(op);
    }

    pub fn getMethodForUnaryOp(op: []const u8) ?[]const u8 {
        const map = std.StaticStringMap([]const u8).initComptime(.{
            .{ "-", "neg" },
            .{ "!", "not" },
            .{ "*", "deref" },
        });
        return map.get(op);
    }
};
