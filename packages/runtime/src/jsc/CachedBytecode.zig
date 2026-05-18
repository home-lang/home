// Copied from bun/src/jsc/CachedBytecode.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
//
// `bun.String` and `bun.options.Format` are not yet ported. Local opaque /
// enum stubs preserve the public surface; the JSC bridge re-attaches in
// Phase 12.2.

const std = @import("std");

// JSC bridge bun.String stubbed — re-attaches in Phase 12.2.
const String = opaque {};
// JSC bridge bun.options.Format stubbed — re-attaches in Phase 12.2.
const Format = enum { esm, cjs, iife };

pub const CachedBytecode = opaque {
    extern fn generateCachedModuleByteCodeFromSourceCode(sourceProviderURL: *String, input_code: [*]const u8, inputSourceCodeSize: usize, outputByteCode: *?[*]u8, outputByteCodeSize: *usize, cached_bytecode: *?*CachedBytecode) bool;
    extern fn generateCachedCommonJSProgramByteCodeFromSourceCode(sourceProviderURL: *String, input_code: [*]const u8, inputSourceCodeSize: usize, outputByteCode: *?[*]u8, outputByteCodeSize: *usize, cached_bytecode: *?*CachedBytecode) bool;

    pub fn generateForESM(sourceProviderURL: *String, input: []const u8) ?struct { []const u8, *CachedBytecode } {
        var this: ?*CachedBytecode = null;

        var input_code_size: usize = 0;
        var input_code_ptr: ?[*]u8 = null;
        if (generateCachedModuleByteCodeFromSourceCode(sourceProviderURL, input.ptr, input.len, &input_code_ptr, &input_code_size, &this)) {
            return .{ input_code_ptr.?[0..input_code_size], this.? };
        }

        return null;
    }

    pub fn generateForCJS(sourceProviderURL: *String, input: []const u8) ?struct { []const u8, *CachedBytecode } {
        var this: ?*CachedBytecode = null;
        var input_code_size: usize = 0;
        var input_code_ptr: ?[*]u8 = null;
        if (generateCachedCommonJSProgramByteCodeFromSourceCode(sourceProviderURL, input.ptr, input.len, &input_code_ptr, &input_code_size, &this)) {
            return .{ input_code_ptr.?[0..input_code_size], this.? };
        }

        return null;
    }

    extern "c" fn CachedBytecode__deref(this: *CachedBytecode) void;
    pub fn deref(this: *CachedBytecode) void {
        return CachedBytecode__deref(this);
    }

    pub fn generate(format: Format, input: []const u8, source_provider_url: *String) ?struct { []const u8, *CachedBytecode } {
        return switch (format) {
            .esm => generateForESM(source_provider_url, input),
            .cjs => generateForCJS(source_provider_url, input),
            else => null,
        };
    }

    pub const VTable = &std.mem.Allocator.VTable{
        .alloc = struct {
            pub fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
                _ = ctx;
                _ = len;
                _ = alignment;
                _ = ret_addr;
                @panic("Unexpectedly called CachedBytecode.alloc");
            }
        }.alloc,
        .free = struct {
            pub fn free(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
                _ = buf;
                _ = alignment;
                _ = ret_addr;
                CachedBytecode__deref(@ptrCast(ctx));
            }
        }.free,
        .resize = &std.mem.Allocator.noResize,
        .remap = &std.mem.Allocator.noRemap,
    };

    pub fn allocator(this: *CachedBytecode) std.mem.Allocator {
        return .{
            .ptr = this,
            .vtable = VTable,
        };
    }

    pub fn isInstance(allocator_: std.mem.Allocator) bool {
        return allocator_.vtable == VTable;
    }
};

test "CachedBytecode is an opaque pointer-only type" {
    try std.testing.expect(@sizeOf(*CachedBytecode) == @sizeOf(usize));
}

test "Format enum tags" {
    try std.testing.expectEqual(@as(Format, .esm), Format.esm);
    try std.testing.expectEqual(@as(Format, .cjs), Format.cjs);
    try std.testing.expectEqual(@as(Format, .iife), Format.iife);
}

test "String stub is opaque pointer-sized" {
    try std.testing.expect(@sizeOf(*String) == @sizeOf(usize));
}
