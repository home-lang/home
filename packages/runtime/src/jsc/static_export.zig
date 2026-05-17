// Copied verbatim from bun/src/jsc/static_export.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.

Type: type,
symbol_name: []const u8,
local_name: []const u8,

Parent: type,

pub fn Decl(comptime this: *const @This()) std.builtin.Type.Declaration {
    return comptime std.meta.declarationInfo(this.Parent, this.local_name);
}

pub fn wrappedName(comptime this: *const @This()) []const u8 {
    return comptime "wrap" ++ this.symbol_name;
}

const std = @import("std");
