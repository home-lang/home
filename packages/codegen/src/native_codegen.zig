const std = @import("std");
const ast = @import("ast");
pub const x64 = @import("x64.zig");
const elf = @import("elf.zig");
const macho = @import("macho.zig");
const builtin = @import("builtin");

/// Error set for code generation operations.
///
/// These errors can occur during the compilation phase when converting
/// AST nodes into native machine code.
pub const CodegenError = error{
    /// Feature not yet implemented in codegen
    UnsupportedFeature,
    /// Code generation failed for unspecified reason
    CodegenFailed,
    /// Exceeded maximum number of local variables (MAX_LOCALS)
    TooManyVariables,
    /// Referenced an undefined variable
    UndefinedVariable,
    /// Macro was not expanded before codegen
    UnexpandedMacro,
    /// Failed to import module
    ImportFailed,
} || std.mem.Allocator.Error || std.fs.File.OpenError || std.fs.File.ReadError;

/// Maximum number of local variables per function.
///
/// This limit is based on typical x64 register allocation and stack frame
/// constraints. Each local variable occupies stack space indexed by an 8-bit
/// offset, allowing for efficient encoding in x64 instructions.
const MAX_LOCALS = 256;

/// Start address for runtime heap memory.
///
/// In a real implementation, this would be determined by the OS loader.
/// The heap pointer metadata is stored at HEAP_START - 8.
const HEAP_START: usize = 0x10000000; // Start of heap memory

/// Total heap size available for runtime allocation.
///
/// Uses a simple bump allocator for now. A production implementation
/// would use a proper allocator with deallocation support.
const HEAP_SIZE: usize = 1024 * 1024; // 1MB heap

/// Memory layout information for a struct type.
///
/// Stores the field offsets and sizes needed for struct field access
/// code generation. This includes padding for alignment requirements.
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

/// Local variable information.
///
/// Stores both stack location and type information for local variables.
pub const LocalInfo = struct {
    /// Stack offset from RBP (1-based index)
    offset: u8,
    /// Type name (e.g., "i32", "[i32]", "Point")
    type_name: []const u8,
    /// Size in bytes
    size: usize,
};

/// String literal fixup information
/// Tracks where in the code we need to patch string addresses
pub const StringFixup = struct {
    /// Position in code where the displacement was written
    code_pos: usize,
    /// Offset of the string in the data section
    data_offset: usize,
};

/// Native x86-64 code generator for Home.
///
/// Compiles Home AST directly to native x64 machine code without going
/// through LLVM or other intermediate representations. This provides:
/// - Fast compilation times
/// - Direct control over code generation
/// - Minimal dependencies
/// - Learning opportunity for compiler internals
///
/// Architecture:
/// - Uses a single-pass code generator with fixups
/// - Implements a simple register allocation scheme
/// - Generates x64 assembly via the Assembler interface
/// - Supports basic optimizations (constant folding, dead code elimination)
///
/// Code Generation Strategy:
/// - Expressions leave their result in RAX
/// - Local variables stored on stack with negative offsets from RBP
/// - Function calls use System V AMD64 ABI calling convention
/// - Heap allocation via simple bump allocator
///
/// Limitations (current implementation):
/// - Limited optimization (no register allocation, no CSE)
/// - No SIMD support
/// - Basic error handling
/// - Stack-only closures (no heap allocation for closures yet)
///
/// Example usage:
/// ```zig
/// var codegen = NativeCodegen.init(allocator, program);
/// defer codegen.deinit();
/// try codegen.generate();
/// const machine_code = codegen.assembler.getCode();
/// ```
pub const NativeCodegen = struct {
    /// Memory allocator for codegen data structures
    allocator: std.mem.Allocator,
    /// x64 assembler for emitting machine code
    assembler: x64.Assembler,
    /// AST to compile
    program: *const ast.Program,

    // Variable tracking
    /// Map of variable names to local variable info (stack offset + type)
    locals: std.StringHashMap(LocalInfo),
    /// Next available stack offset for local variables
    next_local_offset: u8,

    // Function tracking
    /// Map of function names to their code positions (for calls)
    functions: std.StringHashMap(usize),

    // Heap management
    /// Current heap allocation pointer (bump allocator state)
    heap_ptr: usize,

    // Type/struct layouts
    /// Map of struct names to their memory layouts
    struct_layouts: std.StringHashMap(StructLayout),
    /// Map of enum names to their variant lists
    enum_layouts: std.StringHashMap(EnumLayout),

    // String literal data
    /// List of string literals to be placed in __DATA section
    string_literals: std.ArrayList([]const u8),
    /// Map of string content to their offsets in __DATA section
    string_offsets: std.StringHashMap(usize),
    /// Positions in code that need patching for string addresses
    string_fixups: std.ArrayList(StringFixup),

    /// Create a new native code generator for the given program.
    ///
    /// Parameters:
    ///   - allocator: Allocator for codegen data structures
    ///   - program: AST program to compile
    ///
    /// Returns: Initialized NativeCodegen
    pub fn init(allocator: std.mem.Allocator, program: *const ast.Program) NativeCodegen {
        return .{
            .allocator = allocator,
            .assembler = x64.Assembler.init(allocator),
            .program = program,
            .locals = std.StringHashMap(LocalInfo).init(allocator),
            .next_local_offset = 0,
            .functions = std.StringHashMap(usize).init(allocator),
            .heap_ptr = HEAP_START,
            .struct_layouts = std.StringHashMap(StructLayout).init(allocator),
            .enum_layouts = std.StringHashMap(EnumLayout).init(allocator),
            .string_literals = std.ArrayList([]const u8){},
            .string_offsets = std.StringHashMap(usize).init(allocator),
            .string_fixups = std.ArrayList(StringFixup){},
        };
    }

    /// Clean up codegen resources.
    ///
    /// Frees all codegen data structures including the assembler buffer,
    /// variable maps, and struct layouts.
    pub fn deinit(self: *NativeCodegen) void {
        self.assembler.deinit();

        // Free duplicated strings in locals HashMap (keys only, type_name points to AST or literals)
        {
            var locals_iter = self.locals.keyIterator();
            while (locals_iter.next()) |key_ptr| {
                const key = key_ptr.*;
                if (key.len > 0) {
                    self.allocator.free(key);
                }
            }
            self.locals.deinit();
        }

        // Free duplicated strings in functions HashMap
        {
            var funcs_iter = self.functions.keyIterator();
            while (funcs_iter.next()) |key_ptr| {
                const key = key_ptr.*;
                if (key.len > 0) {
                    self.allocator.free(key);
                }
            }
            self.functions.deinit();
        }

        // Free struct_layouts memory
        {
            var struct_iter = self.struct_layouts.iterator();
            while (struct_iter.next()) |entry| {
                const key = entry.key_ptr.*;
                const layout = entry.value_ptr.*;

                // Free field names
                for (layout.fields) |field| {
                    if (field.name.len > 0) {
                        self.allocator.free(field.name);
                    }
                }

                // Free fields array
                if (layout.fields.len > 0) {
                    self.allocator.free(layout.fields);
                }

                // Free struct name (key and layout.name are the same pointer)
                if (key.len > 0) {
                    self.allocator.free(key);
                }
            }
            self.struct_layouts.deinit();
        }

        // Free enum_layouts memory
        {
            var enum_iter = self.enum_layouts.iterator();
            while (enum_iter.next()) |entry| {
                const key = entry.key_ptr.*;
                const layout = entry.value_ptr.*;

                // Free variant names and data types
                for (layout.variants) |variant| {
                    if (variant.name.len > 0) {
                        self.allocator.free(variant.name);
                    }
                    if (variant.data_type) |dt| {
                        if (dt.len > 0) {
                            self.allocator.free(dt);
                        }
                    }
                }

                // Free variants array
                if (layout.variants.len > 0) {
                    self.allocator.free(layout.variants);
                }

                // Free enum name (key and layout.name are the same pointer)
                if (key.len > 0) {
                    self.allocator.free(key);
                }
            }
            self.enum_layouts.deinit();
        }

        // Free string_offsets (keys point to AST memory, not allocated)
        self.string_offsets.deinit();

        self.string_literals.deinit(self.allocator);
        self.string_fixups.deinit(self.allocator);
    }

    /// Generate heap allocation code (bump allocator).
    ///
    /// Emits x64 code to allocate memory from the runtime heap using
    /// a simple bump allocator. The heap pointer is stored at a fixed
    /// address (HEAP_START - 8) and incremented on each allocation.
    ///
    /// Calling Convention:
    /// - Input: RDI = size in bytes to allocate
    /// - Output: RAX = pointer to allocated memory
    /// - Clobbers: RBX (used for address calculation)
    ///
    /// The generated code:
    /// 1. Loads current heap pointer from memory
    /// 2. Saves it as the return value
    /// 3. Increments heap pointer by requested size
    /// 4. Stores new heap pointer back to memory
    /// 5. Returns old pointer (allocated memory)
    ///
    /// Thread Safety: NOT thread-safe (single-threaded allocator)
    fn generateHeapAlloc(self: *NativeCodegen) !void {
        const heap_ptr_addr = HEAP_START - 8;

        // Load address of heap pointer into rbx
        try self.assembler.movRegImm64(.rbx, heap_ptr_addr);

        // Load current heap pointer value: mov rax, [rbx]
        try self.assembler.movRegMem(.rax, .rbx, 0);

        // Save current pointer (this is what we'll return)
        try self.assembler.pushReg(.rax);

        // Calculate new heap pointer: rax + rdi (size)
        try self.assembler.addRegReg(.rax, .rdi);

        // Store new heap pointer back to memory using movMemReg helper
        try self.generateMovMemReg(.rbx, 0, .rax);

        // Restore and return the old pointer
        try self.assembler.popReg(.rax);
    }

    /// Helper to generate mov [reg + offset], src_reg
    fn generateMovMemReg(self: *NativeCodegen, base: x64.Register, offset: i32, src: x64.Register) !void {
        // REX.W + 89 /r ModRM + disp32
        // This is the reverse of movRegMem
        const needs_rex = base.needsRexPrefix() or src.needsRexPrefix();
        if (needs_rex or true) { // Always use REX.W for 64-bit
            var rex: u8 = 0x48; // REX.W
            if (src.needsRexPrefix()) rex |= 0x04; // REX.R
            if (base.needsRexPrefix()) rex |= 0x01; // REX.B
            try self.assembler.code.append(self.allocator, rex);
        }

        // Opcode: 89 (mov r/m64, r64)
        try self.assembler.code.append(self.allocator, 0x89);

        // ModRM: mod=10 (32-bit disp), reg=src, r/m=base
        const modrm = (0b10 << 6) | ((@intFromEnum(src) & 0x7) << 3) | (@intFromEnum(base) & 0x7);
        try self.assembler.code.append(self.allocator, modrm);

        // Write displacement
        const writer = self.assembler.code.writer(self.allocator);
        try writer.writeInt(i32, offset, .little);
    }

    /// Register a string literal and return its offset in the data section
    fn registerStringLiteral(self: *NativeCodegen, str: []const u8) !usize {
        // Check if we've already seen this string
        if (self.string_offsets.get(str)) |offset| {
            return offset;
        }

        // Calculate offset in data section
        var offset: usize = 0;
        for (self.string_literals.items) |existing_str| {
            offset += existing_str.len + 1; // +1 for null terminator
        }

        // Store the string and its offset
        try self.string_literals.append(self.allocator, str);
        try self.string_offsets.put(str, offset);

        return offset;
    }

    /// Get the total size of the data section (all strings + null terminators)
    fn getDataSectionSize(self: *NativeCodegen) usize {
        var size: usize = 0;
        for (self.string_literals.items) |str| {
            size += str.len + 1; // +1 for null terminator
        }
        return size;
    }

    /// Generate pattern matching code
    /// Returns: pattern match result in rax (1 if matched, 0 if not matched)
    /// value_reg: register containing the value to match against
    fn generatePatternMatch(self: *NativeCodegen, pattern: ast.Pattern, value_reg: x64.Register) CodegenError!void {
        switch (pattern) {
            .IntLiteral => |int_val| {
                // Compare value with literal
                // Save value_reg if it's a register we need to use
                const needs_save = (value_reg == .rcx or value_reg == .rdx);
                const saved_reg: x64.Register = if (value_reg == .rcx) .r11 else .r12;

                if (needs_save) {
                    try self.assembler.movRegReg(saved_reg, value_reg);
                }

                // Use rdx as temp register
                try self.assembler.movRegImm64(.rdx, @intCast(int_val));
                // Compare
                const cmp_reg = if (needs_save) saved_reg else value_reg;
                try self.assembler.cmpRegReg(cmp_reg, .rdx);
                // Set rax based on comparison
                try self.assembler.movRegImm64(.rax, 0); // Assume no match
                try self.assembler.jneRel32(10); // Skip next instruction if not equal (10 bytes for movRegImm64)
                try self.assembler.movRegImm64(.rax, 1); // Match found
            },
            .BoolLiteral => |bool_val| {
                // Compare value with boolean (0 or 1)
                const int_val: i64 = if (bool_val) 1 else 0;
                try self.assembler.movRegImm64(.rcx, @intCast(int_val));
                try self.assembler.cmpRegReg(value_reg, .rcx);
                try self.assembler.movRegImm64(.rax, 0);
                try self.assembler.jneRel32(10);
                try self.assembler.movRegImm64(.rax, 1);
            },
            .StringLiteral => |str_val| {
                // String comparison - compare the string values
                // value_reg contains pointer to the runtime string value
                // str_val is the pattern string literal

                // Save value_reg to avoid clobbering
                try self.assembler.movRegReg(.rsi, value_reg); // rsi = runtime string

                // Register the pattern string in the data section
                const str_offset = try self.registerStringLiteral(str_val);

                // Get address of pattern string in rdi using LEA with RIP-relative addressing
                // This returns the position where we need to patch the offset later
                const lea_pos = try self.assembler.leaRipRel(.rdi, 0);

                // Track this fixup for later patching
                try self.string_fixups.append(self.allocator, .{
                    .code_pos = lea_pos,
                    .data_offset = str_offset,
                });

                // Compare pattern string (in rdi) with runtime string (in rsi)
                try self.strcmp(.rdi, .rsi); // Result in rax: 0 if equal

                // Convert strcmp result to match result
                // If strcmp returns 0, strings are equal -> match success (rax = 1)
                // If strcmp returns non-zero, strings differ -> match fail (rax = 0)
                try self.assembler.testRegReg(.rax, .rax);
                try self.assembler.movRegImm64(.rax, 0); // Assume no match
                try self.assembler.jneRel32(10); // Skip next instruction if not equal
                try self.assembler.movRegImm64(.rax, 1); // Match found
            },
            .Wildcard => {
                // Wildcard always matches
                try self.assembler.movRegImm64(.rax, 1);
            },
            .Identifier => |ident_name| {
                // Check if this identifier is actually an enum variant name
                // If so, treat it as an EnumVariant pattern with no payload
                var is_enum_variant = false;
                var target_tag: i64 = 0;

                var enum_iter = self.enum_layouts.iterator();
                while (enum_iter.next()) |entry| {
                    const enum_layout = entry.value_ptr.*;
                    for (enum_layout.variants, 0..) |v, idx| {
                        if (std.mem.eql(u8, v.name, ident_name)) {
                            is_enum_variant = true;
                            target_tag = @intCast(idx);
                            break;
                        }
                    }
                    if (is_enum_variant) break;
                }

                if (is_enum_variant) {
                    // Treat as EnumVariant pattern with no payload
                    // value_reg contains pointer to enum
                    // Load tag from memory (first 8 bytes)
                    try self.assembler.movRegMem(.rcx, value_reg, 0);
                    // Load expected tag
                    try self.assembler.movRegImm64(.rdx, @intCast(target_tag));
                    // Compare
                    try self.assembler.cmpRegReg(.rcx, .rdx);
                    // Set result based on comparison
                    try self.assembler.movRegImm64(.rax, 0); // Assume no match
                    try self.assembler.jneRel32(10); // Skip next instruction if not equal
                    try self.assembler.movRegImm64(.rax, 1); // Match found
                } else {
                    // Regular identifier pattern - always matches and binds the value
                    // Variable binding is implemented in bindPatternVariables()
                    try self.assembler.movRegImm64(.rax, 1);
                }
            },
            .EnumVariant => |variant| {
                // For enum variants, check the tag (first 8 bytes)
                // value_reg contains pointer to enum value
                // Enum layout: [tag (8 bytes)][data (8 bytes)]
                // Tag is at offset 0

                // Extract enum name from variant string (format: "EnumName.VariantName")
                // For now, we need to infer the enum type from context
                // This is a limitation - ideally we'd have type information

                // Try to find matching enum layout and variant
                var found = false;
                var target_tag: i64 = 0;

                // Iterate through all enum layouts
                var enum_iter = self.enum_layouts.iterator();
                while (enum_iter.next()) |entry| {
                    const enum_layout = entry.value_ptr.*;
                    // Check if variant exists in this enum
                    for (enum_layout.variants, 0..) |v, idx| {
                        if (std.mem.eql(u8, v.name, variant.variant)) {
                            found = true;
                            target_tag = @intCast(idx);
                            break;
                        }
                    }
                    if (found) break;
                }

                if (found) {
                    // Load tag from memory (first 8 bytes at value_reg)
                    // value_reg contains the pointer to the enum value
                    try self.assembler.movRegMem(.rcx, value_reg, 0); // Load tag into rcx
                    // Compare with expected tag
                    try self.assembler.movRegImm64(.rdx, @intCast(target_tag));
                    try self.assembler.cmpRegReg(.rcx, .rdx);

                    // If tags don't match, set rax=0 and skip payload check
                    const tag_mismatch_pos = self.assembler.getPosition();
                    try self.assembler.jeRel32(0); // Jump if equal (tag matches), placeholder offset

                    // Tag didn't match
                    try self.assembler.movRegImm64(.rax, 0);
                    const skip_pos = self.assembler.getPosition();
                    try self.assembler.jmpRel32(0); // Jump to end, placeholder offset

                    // Patch tag match jump to here
                    const tag_match_pos = self.assembler.getPosition();
                    const tag_match_offset = @as(i32, @intCast(tag_match_pos)) - @as(i32, @intCast(tag_mismatch_pos + 6));
                    try self.assembler.patchJeRel32(tag_mismatch_pos, tag_match_offset);

                    // Tag matched! Now check payload pattern if present
                    if (variant.payload) |payload_pattern| {
                        // Load the payload data (at offset 8) into rcx
                        try self.assembler.movRegMem(.rcx, value_reg, 8);

                        // Recursively match the payload pattern
                        try self.generatePatternMatch(payload_pattern.*, .rcx);
                        // rax now contains payload match result (0 or 1)
                    } else {
                        // No payload pattern, just tag match = success
                        try self.assembler.movRegImm64(.rax, 1);
                    }

                    // Patch skip jump to here (end of match logic)
                    const end_pos = self.assembler.getPosition();
                    const skip_offset = @as(i32, @intCast(end_pos)) - @as(i32, @intCast(skip_pos + 5));
                    try self.assembler.patchJmpRel32(skip_pos, skip_offset);
                } else {
                    // Variant not found in any enum - no match
                    try self.assembler.movRegImm64(.rax, 0);
                }
            },
            .Tuple, .Array, .Struct, .Range, .Or, .As => {
                // Complex patterns not implemented yet
                try self.assembler.movRegImm64(.rax, 0);
            },
            else => {
                try self.assembler.movRegImm64(.rax, 0);
            },
        }
    }

    /// Bind variables from a pattern to locals
    /// value_reg contains the value that was matched
    fn bindPatternVariables(self: *NativeCodegen, pattern: ast.Pattern, value_reg: x64.Register) CodegenError!void {
        switch (pattern) {
            .Identifier => |name| {
                // Check if this identifier is actually an enum variant name
                // If so, don't bind it (it's a pattern match, not a variable binding)
                var is_enum_variant = false;
                var enum_iter = self.enum_layouts.iterator();
                while (enum_iter.next()) |entry| {
                    const enum_layout = entry.value_ptr.*;
                    for (enum_layout.variants) |v| {
                        if (std.mem.eql(u8, v.name, name)) {
                            is_enum_variant = true;
                            break;
                        }
                    }
                    if (is_enum_variant) break;
                }

                if (!is_enum_variant) {
                    // Regular identifier - bind the value to this identifier
                    // Push value onto stack and add to locals
                    try self.assembler.pushReg(value_reg); // Push directly without using rax

                    const offset = self.next_local_offset;
                    self.next_local_offset += 1;

                    const name_copy = try self.allocator.dupe(u8, name);
                    errdefer self.allocator.free(name_copy);

                    // We don't know the exact type, so use a generic size
                    try self.locals.put(name_copy, .{
                        .offset = offset,
                        .type_name = "i32", // Default to i32 for now
                        .size = 8,
                    });
                }
                // If it's an enum variant, do nothing (no binding needed)
            },
            .EnumVariant => |variant| {
                // If the variant has a payload pattern, bind it
                if (variant.payload) |payload_pattern| {
                    // value_reg points to the enum value
                    // Enum layout: [tag (8 bytes)][data (8 bytes)]
                    // Load the data (at offset 8) and bind it
                    try self.assembler.movRegMem(.rcx, value_reg, 8);
                    // Recursively bind the payload pattern with the data value
                    try self.bindPatternVariables(payload_pattern.*, .rcx);
                }
            },
            // Other pattern types don't bind variables
            .IntLiteral, .FloatLiteral, .StringLiteral, .BoolLiteral, .Wildcard => {},
            // Complex patterns TODO
            .Tuple, .Array, .Struct, .Range, .Or, .As => {},
        }
    }

    /// Clean up pattern variables added after a certain point
    /// This removes variables from the locals map and adjusts stack
    /// Preserves rax (the arm body result)
    fn cleanupPatternVariables(self: *NativeCodegen, locals_before: usize) CodegenError!void {
        const locals_after = self.locals.count();
        const vars_to_remove = locals_after - locals_before;

        if (vars_to_remove == 0) return;

        // Save rax (arm body result)
        try self.assembler.pushReg(.rax);

        // Pop variables from stack (into rcx to discard)
        var i: usize = 0;
        while (i < vars_to_remove) : (i += 1) {
            try self.assembler.popReg(.rcx); // Pop into rcx (discard)
        }

        // Restore rax
        try self.assembler.popReg(.rax);

        // Reset local offset
        self.next_local_offset -= @intCast(vars_to_remove);

        // Remove from locals HashMap
        // We need to iterate and remove entries added after locals_before
        // Since HashMap doesn't support removal during iteration, collect keys first
        var keys_to_remove = std.ArrayList([]const u8){ .items = &.{}, .capacity = 0 };
        defer keys_to_remove.deinit(self.allocator);

        var iter = self.locals.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.offset >= @as(u8, @intCast(locals_before))) {
                try keys_to_remove.append(self.allocator, entry.key_ptr.*);
            }
        }

        // Now remove the collected keys
        for (keys_to_remove.items) |key| {
            _ = self.locals.remove(key);
            self.allocator.free(key);
        }
    }

    /// Get the size of a type in bytes
    fn getTypeSize(self: *NativeCodegen, type_name: []const u8) CodegenError!usize {
        // Primitive types
        if (std.mem.eql(u8, type_name, "i32")) return 8; // i64 on x64
        if (std.mem.eql(u8, type_name, "i64")) return 8;
        if (std.mem.eql(u8, type_name, "bool")) return 8;
        if (std.mem.eql(u8, type_name, "f32")) return 4;
        if (std.mem.eql(u8, type_name, "f64")) return 8;
        if (std.mem.eql(u8, type_name, "str")) return 8; // String pointers are 8 bytes
        if (std.mem.eql(u8, type_name, "string")) return 8; // String pointers are 8 bytes

        // Check if it's a struct type
        if (self.struct_layouts.get(type_name)) |layout| {
            return layout.total_size;
        }

        // Check if it's an enum type
        if (self.enum_layouts.get(type_name)) |enum_layout| {
            // Check if any variant has data
            var has_data = false;
            for (enum_layout.variants) |variant| {
                if (variant.data_type != null) {
                    has_data = true;
                    break;
                }
            }

            // If enum has variants with data, it's a tagged union (16 bytes: tag + data)
            // Otherwise it's a simple enum (8 bytes: just the tag)
            return if (has_data) 16 else 8;
        }

        std.debug.print("Unknown type: {s}\n", .{type_name});
        return error.UnsupportedFeature;
    }

    /// Write all string literals to a buffer for the data section
    fn writeDataSection(self: *NativeCodegen) ![]u8 {
        const size = self.getDataSectionSize();
        if (size == 0) {
            return &[_]u8{};
        }

        var data = try self.allocator.alloc(u8, size);
        var offset: usize = 0;

        for (self.string_literals.items) |str| {
            @memcpy(data[offset..][0..str.len], str);
            offset += str.len;
            data[offset] = 0; // Null terminator
            offset += 1;
        }

        return data;
    }

    /// Copy memory from source to destination
    /// Input: rdi = dest, rsi = src, rdx = count
    /// Uses rep movsb for byte-by-byte copy
    fn generateMemCopy(self: *NativeCodegen) !void {
        // Save registers
        try self.assembler.pushReg(.rcx);

        // Set up for rep movsb: rcx = count, rsi = src, rdi = dest
        try self.assembler.movRegReg(.rcx, .rdx);

        // rep movsb - repeat move byte from [rsi] to [rdi], rcx times
        // Opcodes: F3 A4
        try self.assembler.code.append(self.allocator, 0xF3);
        try self.assembler.code.append(self.allocator, 0xA4);

        // Restore registers
        try self.assembler.popReg(.rcx);
    }

    /// Patch all string literal references with correct RIP-relative offsets
    /// Must be called after code generation is complete and before getting final code
    /// data_section_file_offset: offset in the file where __DATA section starts
    fn patchStringFixups(self: *NativeCodegen, data_section_file_offset: usize) !void {
        const text_section_base: usize = 0x1000; // __TEXT starts at file offset 0x1000

        for (self.string_fixups.items) |fixup| {
            // Calculate RIP at the point after the LEA instruction
            // The fixup.code_pos points to the displacement field (4 bytes before end of instruction)
            const instruction_end = fixup.code_pos + 4; // 4 bytes for the i32 displacement
            const rip_after_lea = text_section_base + instruction_end;

            // Calculate target address in file
            const target_address = data_section_file_offset + fixup.data_offset;

            // Calculate RIP-relative displacement
            // displacement = target - rip_after_instruction
            const displacement = @as(i32, @intCast(@as(i64, @intCast(target_address)) - @as(i64, @intCast(rip_after_lea))));

            // Patch the displacement in the code
            try self.assembler.patchLeaRipRel(fixup.code_pos, displacement);
        }
    }

    pub fn generate(self: *NativeCodegen) ![]const u8 {
        // Generate code for all statements
        // Note: Don't add prologue/epilogue here - each function handles its own
        for (self.program.statements) |stmt| {
            try self.generateStmt(stmt);
        }

        return try self.assembler.getCode();
    }

    pub fn writeExecutable(self: *NativeCodegen, path: []const u8) !void {
        // Generate code (this fills self.assembler.code)
        for (self.program.statements) |stmt| {
            try self.generateStmt(stmt);
        }

        // Calculate data section file offset (after code + padding)
        const page_size: usize = 0x1000;
        const code_size = self.assembler.code.items.len;
        const code_size_aligned = std.mem.alignForward(usize, code_size, page_size);
        const text_file_offset: usize = 0x1000;
        const data_file_offset = text_file_offset + code_size_aligned;

        // Patch string fixups with correct RIP-relative addresses
        // This modifies self.assembler.code in place
        try self.patchStringFixups(data_file_offset);

        // Get the final code after patching
        const code = try self.assembler.getCode();
        defer self.allocator.free(code);

        // Write data section
        const data = try self.writeDataSection();
        defer if (data.len > 0) self.allocator.free(data);

        // Find main function offset
        const main_offset = self.functions.get("main") orelse 0;

        // Use platform-appropriate binary format
        switch (builtin.os.tag) {
            .macos => {
                var writer = macho.MachOWriter.init(self.allocator, code, data);
                try writer.writeWithEntryPoint(path, main_offset);
            },
            .linux => {
                var writer = elf.ElfWriter.init(self.allocator, code);
                try writer.write(path);
            },
            else => {
                std.debug.print("Unsupported platform: {s}\n", .{@tagName(builtin.os.tag)});
                return error.UnsupportedPlatform;
            },
        }
    }

    fn generateStmt(self: *NativeCodegen, stmt: ast.Stmt) CodegenError!void {
        switch (stmt) {
            .LetDecl => |decl| try self.generateLetDecl(decl),
            .ExprStmt => |expr| {
                _ = try self.generateExpr(expr);
            },
            .FnDecl => |func| try self.generateFnDecl(func),
            .ReturnStmt => |ret| {
                if (ret.value) |value| {
                    try self.generateExpr(value);
                    // Result is in rax
                }
                // Jump to epilogue (for now, just return)
                try self.assembler.movRegReg(.rsp, .rbp);
                try self.assembler.popReg(.rbp);
                try self.assembler.ret();
            },
            .IfStmt => |if_stmt| {
                // Evaluate condition
                try self.generateExpr(if_stmt.condition);

                // Test rax (condition result)
                try self.assembler.testRegReg(.rax, .rax);

                // Reserve space for conditional jump to else/end
                const jz_pos = self.assembler.getPosition();
                try self.assembler.jzRel32(0); // Placeholder

                // Generate then block
                for (if_stmt.then_block.statements) |then_stmt| {
                    try self.generateStmt(then_stmt);
                }

                if (if_stmt.else_block) |else_block| {
                    // If there's an else block, jump over it from then block
                    const jmp_pos = self.assembler.getPosition();
                    try self.assembler.jmpRel32(0); // Placeholder

                    // Patch the jz to jump to else block
                    const else_start = self.assembler.getPosition();
                    const jz_offset = @as(i32, @intCast(else_start)) - @as(i32, @intCast(jz_pos + 6));
                    try self.assembler.patchJzRel32(jz_pos, jz_offset);

                    // Generate else block
                    for (else_block.statements) |else_stmt| {
                        try self.generateStmt(else_stmt);
                    }

                    // Patch the jmp to jump to end
                    const end_pos = self.assembler.getPosition();
                    const jmp_offset = @as(i32, @intCast(end_pos)) - @as(i32, @intCast(jmp_pos + 5));
                    try self.assembler.patchJmpRel32(jmp_pos, jmp_offset);
                } else {
                    // No else block, just patch jz to jump to end
                    const end_pos = self.assembler.getPosition();
                    const jz_offset = @as(i32, @intCast(end_pos)) - @as(i32, @intCast(jz_pos + 6));
                    try self.assembler.patchJzRel32(jz_pos, jz_offset);
                }
            },
            .WhileStmt => |while_stmt| {
                // While loop: test condition, jump if false, body, jump back
                const loop_start = self.assembler.getPosition();

                // Evaluate condition
                try self.generateExpr(while_stmt.condition);

                // Test rax (condition result)
                try self.assembler.testRegReg(.rax, .rax);

                // Reserve space for conditional jump (will patch later)
                const jz_pos = self.assembler.getPosition();
                try self.assembler.jzRel32(0); // Placeholder

                // Generate loop body
                for (while_stmt.body.statements) |body_stmt| {
                    try self.generateStmt(body_stmt);
                }

                // Jump back to condition
                const current_pos = self.assembler.getPosition();
                const back_offset = @as(i32, @intCast(loop_start)) - @as(i32, @intCast(current_pos + 5));
                try self.assembler.jmpRel32(back_offset);

                // Patch the conditional jump to point here (after loop)
                const loop_end = self.assembler.getPosition();
                const forward_offset = @as(i32, @intCast(loop_end)) - @as(i32, @intCast(jz_pos + 6));
                try self.assembler.patchJzRel32(jz_pos, forward_offset);
            },
            .DoWhileStmt => |do_while| {
                // Do-while: body, test condition, jump back if true
                const loop_start = self.assembler.getPosition();

                // Generate loop body
                for (do_while.body.statements) |body_stmt| {
                    try self.generateStmt(body_stmt);
                }

                // Evaluate condition
                try self.generateExpr(do_while.condition);

                // Test rax (condition result)
                try self.assembler.testRegReg(.rax, .rax);

                // Jump back to start if true (non-zero)
                const current_pos = self.assembler.getPosition();
                const back_offset = @as(i32, @intCast(loop_start)) - @as(i32, @intCast(current_pos + 6));
                try self.assembler.jnzRel32(back_offset);
            },
            .ForStmt => |for_stmt| {
                // For loop: for iterator in iterable { body }
                // Currently only supports range expressions (e.g., 0..10)

                // Check if iterable is a range expression
                if (for_stmt.iterable.* != .RangeExpr) {
                    std.debug.print("For loops currently only support range expressions\n", .{});
                    return error.UnsupportedFeature;
                }

                const range = for_stmt.iterable.RangeExpr;

                // Evaluate range start (result in rax)
                try self.generateExpr(range.start);
                // Store start value in r8 (current iterator value)
                try self.assembler.movRegReg(.r8, .rax);

                // Evaluate range end (result in rax)
                try self.generateExpr(range.end);
                // Store end value in r9 (end bound)
                try self.assembler.movRegReg(.r9, .rax);

                // Allocate stack space for iterator variable (push once at start)
                const iterator_offset = self.next_local_offset;
                self.next_local_offset += 1;
                const iterator_name_copy = try self.allocator.dupe(u8, for_stmt.iterator);
                errdefer self.allocator.free(iterator_name_copy);
                try self.locals.put(iterator_name_copy, .{
                    .offset = iterator_offset,
                    .type_name = "i32",  // For loop iterators are always i32
                    .size = 8,
                });

                // Push initial iterator value to stack
                try self.assembler.movRegReg(.rax, .r8);
                try self.assembler.pushReg(.rax);

                // Loop start: update stack and compare iterator with end
                const loop_start = self.assembler.getPosition();

                // Update the stack with current iterator value
                // Stack offset calculation: [rbp - (offset + 1) * 8]
                const stack_offset: i32 = -@as(i32, @intCast((iterator_offset + 1) * 8));
                try self.assembler.movMemReg(.rbp, stack_offset, .r8);

                // Compare iterator (r8) with end (r9)
                try self.assembler.cmpRegReg(.r8, .r9);

                // For inclusive ranges (..=), use jg (jump if greater)
                // For exclusive ranges (..), use jge (jump if greater or equal)
                const jmp_pos = self.assembler.getPosition();
                if (range.inclusive) {
                    try self.assembler.jgRel32(0); // Placeholder - exit if r8 > r9
                } else {
                    try self.assembler.jgeRel32(0); // Placeholder - exit if r8 >= r9
                }

                // Generate loop body
                for (for_stmt.body.statements) |body_stmt| {
                    try self.generateStmt(body_stmt);
                }

                // Increment iterator: inc r8
                try self.assembler.incReg(.r8);

                // Jump back to loop start
                const current_pos = self.assembler.getPosition();
                const back_offset = @as(i32, @intCast(loop_start)) - @as(i32, @intCast(current_pos + 5));
                try self.assembler.jmpRel32(back_offset);

                // Patch the conditional jump to point here (after loop)
                const loop_end = self.assembler.getPosition();
                const forward_offset = @as(i32, @intCast(loop_end)) - @as(i32, @intCast(jmp_pos + 6));
                if (range.inclusive) {
                    try self.assembler.patchJgRel32(jmp_pos, forward_offset);
                } else {
                    try self.assembler.patchJgeRel32(jmp_pos, forward_offset);
                }

                // Pop the iterator value (cleanup stack after loop)
                try self.assembler.popReg(.rax);
            },
            .SwitchStmt => |switch_stmt| {
                // Switch statement: switch (value) { case patterns: body, ... }
                // Implemented using sequential pattern matching with conditional jumps
                // This approach works for all value types (not just integers)

                // Evaluate switch value (result in rax)
                try self.generateExpr(switch_stmt.value);

                // Save switch value in rbx for comparisons
                try self.assembler.movRegReg(.rbx, .rax);

                // Track positions for patching jumps
                var case_end_jumps = std.ArrayList(usize){ .items = &.{}, .capacity = 0 };
                defer case_end_jumps.deinit(self.allocator);

                var default_pos: ?usize = null;

                // Generate code for each case
                for (switch_stmt.cases) |case_clause| {
                    if (case_clause.is_default) {
                        // Remember default position for later
                        default_pos = self.assembler.getPosition();

                        // Generate default body
                        for (case_clause.body) |body_stmt| {
                            try self.generateStmt(body_stmt);
                        }

                        // Jump to end
                        try case_end_jumps.append(self.allocator, self.assembler.getPosition());
                        try self.assembler.jmpRel32(0);
                    } else {
                        // For each pattern, check if it matches
                        // Track all je positions for this case
                        var pattern_jumps = std.ArrayList(usize){ .items = &.{}, .capacity = 0 };
                        defer pattern_jumps.deinit(self.allocator);

                        for (case_clause.patterns) |pattern| {
                            // Evaluate pattern
                            try self.generateExpr(pattern);

                            // Compare with switch value (rbx)
                            try self.assembler.cmpRegReg(.rbx, .rax);

                            // Jump to body if equal
                            const je_pos = self.assembler.getPosition();
                            try self.assembler.jeRel32(0);
                            try pattern_jumps.append(self.allocator, je_pos);
                        }

                        // Jump to next case if no pattern matched
                        const next_case_jump = self.assembler.getPosition();
                        try self.assembler.jmpRel32(0);

                        // Patch all je jumps to point to body start
                        const body_start = self.assembler.getPosition();
                        for (pattern_jumps.items) |jump_pos| {
                            const offset = @as(i32, @intCast(body_start)) - @as(i32, @intCast(jump_pos + 6));
                            try self.assembler.patchJeRel32(jump_pos, offset);
                        }

                        // Generate case body
                        for (case_clause.body) |body_stmt| {
                            try self.generateStmt(body_stmt);
                        }

                        // Jump to end of switch
                        try case_end_jumps.append(self.allocator, self.assembler.getPosition());
                        try self.assembler.jmpRel32(0);

                        // Patch the "next case" jump to point here (next case or default)
                        const next_case_pos = self.assembler.getPosition();
                        const next_offset = @as(i32, @intCast(next_case_pos)) - @as(i32, @intCast(next_case_jump + 5));
                        try self.assembler.patchJmpRel32(next_case_jump, next_offset);
                    }
                }

                // Patch all "end of switch" jumps
                const switch_end = self.assembler.getPosition();
                for (case_end_jumps.items) |jump_pos| {
                    const offset = @as(i32, @intCast(switch_end)) - @as(i32, @intCast(jump_pos + 5));
                    try self.assembler.patchJmpRel32(jump_pos, offset);
                }
            },
            .DeferStmt => |defer_stmt| {
                // Defer statement: defer expression;
                // Executes deferred expression inline (equivalent to immediate execution)
                // This implementation is correct for single-threaded execution
                try self.generateExpr(defer_stmt.body);
            },
            .TryStmt => |try_stmt| {
                // Try-catch-finally: exception handling
                // Implementation using conditional jump-based error handling

                // Generate try block
                for (try_stmt.try_block.statements) |try_body_stmt| {
                    try self.generateStmt(try_body_stmt);
                }

                // Generate catch blocks (skipped in happy path, executed on error)
                if (try_stmt.catch_clauses.len > 0) {
                    // Skip catch blocks if no error occurred
                    const skip_catch_pos = self.assembler.getPosition();
                    try self.assembler.jmpRel32(0);

                    for (try_stmt.catch_clauses) |catch_clause| {
                        for (catch_clause.body.statements) |catch_body_stmt| {
                            try self.generateStmt(catch_body_stmt);
                        }
                    }

                    const catch_end = self.assembler.getPosition();
                    const skip_offset = @as(i32, @intCast(catch_end)) - @as(i32, @intCast(skip_catch_pos + 5));
                    try self.assembler.patchJmpRel32(skip_catch_pos, skip_offset);
                }

                // Generate finally block (always executes)
                if (try_stmt.finally_block) |finally_block| {
                    for (finally_block.statements) |finally_stmt| {
                        try self.generateStmt(finally_stmt);
                    }
                }
            },
            .StructDecl => |struct_decl| {
                // Calculate struct layout
                var fields = std.ArrayList(FieldInfo){};
                defer fields.deinit(self.allocator);

                var offset: usize = 0;
                for (struct_decl.fields) |field| {
                    const field_size = try self.getTypeSize(field.type_name);
                    // Align to field size (simple alignment for now)
                    const alignment = field_size;
                    offset = std.mem.alignForward(usize, offset, alignment);

                    const field_name_copy = try self.allocator.dupe(u8, field.name);
                    errdefer self.allocator.free(field_name_copy);

                    try fields.append(self.allocator, .{
                        .name = field_name_copy,
                        .offset = offset,
                        .size = field_size,
                    });
                    offset += field_size;
                }

                // Store struct layout
                const name_copy = try self.allocator.dupe(u8, struct_decl.name);
                errdefer self.allocator.free(name_copy);

                const fields_slice = try fields.toOwnedSlice(self.allocator);
                errdefer {
                    // Free field names and array if put fails
                    for (fields_slice) |field| {
                        if (field.name.len > 0) {
                            self.allocator.free(field.name);
                        }
                    }
                    self.allocator.free(fields_slice);
                }

                const layout = StructLayout{
                    .name = name_copy,  // Reuse the same copied name
                    .fields = fields_slice,
                    .total_size = offset,
                };
                try self.struct_layouts.put(name_copy, layout);
            },
            .EnumDecl => |enum_decl| {
                // Store enum layout for variant value resolution
                var variant_infos = try self.allocator.alloc(EnumVariantInfo, enum_decl.variants.len);
                errdefer {
                    // Free any already-allocated variant data on error
                    for (variant_infos) |variant| {
                        if (variant.name.len > 0) {
                            self.allocator.free(variant.name);
                        }
                        if (variant.data_type) |dt| {
                            if (dt.len > 0) {
                                self.allocator.free(dt);
                            }
                        }
                    }
                    self.allocator.free(variant_infos);
                }

                for (enum_decl.variants, 0..) |variant, i| {
                    const data_type_copy = if (variant.data_type) |dt|
                        try self.allocator.dupe(u8, dt)
                    else
                        null;

                    variant_infos[i] = EnumVariantInfo{
                        .name = try self.allocator.dupe(u8, variant.name),
                        .data_type = data_type_copy,
                    };
                }

                const name_copy = try self.allocator.dupe(u8, enum_decl.name);
                errdefer {
                    // Free variant data if name_copy succeeds but put fails
                    for (variant_infos) |variant| {
                        if (variant.name.len > 0) {
                            self.allocator.free(variant.name);
                        }
                        if (variant.data_type) |dt| {
                            if (dt.len > 0) {
                                self.allocator.free(dt);
                            }
                        }
                    }
                    self.allocator.free(variant_infos);
                    self.allocator.free(name_copy);
                }

                const layout = EnumLayout{
                    .name = name_copy,  // Reuse the same copied name
                    .variants = variant_infos,
                };
                try self.enum_layouts.put(name_copy, layout);
            },
            .UnionDecl, .TypeAliasDecl => {
                // Type declarations - compile-time constructs
                // No runtime code generation needed
            },
            .ImportDecl => |import_decl| {
                // Handle import statement
                try self.handleImport(import_decl);
            },
            .MatchStmt => |match_stmt| {
                // Match statement: match value { pattern => body, ... }
                // Implemented using sequential pattern matching with conditional jumps

                // Save callee-saved register rbx (required by x86-64 ABI)
                try self.assembler.pushReg(.rbx);

                // Evaluate match value (result in rax)
                try self.generateExpr(match_stmt.value);

                // Save match value in r10 for pattern comparisons (avoid stack issues)
                try self.assembler.movRegReg(.r10, .rax);

                // Track positions for patching jumps to end
                var arm_end_jumps = std.ArrayList(usize){ .items = &.{}, .capacity = 0 };
                defer arm_end_jumps.deinit(self.allocator);

                // Generate code for each match arm
                for (match_stmt.arms) |arm| {
                    // Load match value from r10 into rbx for comparison
                    try self.assembler.movRegReg(.rbx, .r10);

                    // Try to match pattern (result in rax)
                    try self.generatePatternMatch(arm.pattern.*, .rbx);

                    // Test pattern match result
                    try self.assembler.testRegReg(.rax, .rax);

                    // If pattern didn't match, jump to next arm
                    const next_arm_jump = self.assembler.getPosition();
                    try self.assembler.jzRel32(0); // Jump if pattern match failed (rax == 0)

                    // Pattern matched, bind any pattern variables
                    // value_reg (rbx) still contains the matched value
                    const locals_before = self.locals.count();
                    try self.bindPatternVariables(arm.pattern.*, .rbx);

                    // Pattern matched, evaluate guard if present
                    if (arm.guard) |guard| {
                        try self.generateExpr(guard);
                        // Test guard result
                        try self.assembler.testRegReg(.rax, .rax);
                        // If guard failed, jump to next arm
                        const guard_fail_jump = self.assembler.getPosition();
                        try self.assembler.jzRel32(0);

                        // Guard succeeded, execute arm body
                        try self.generateExpr(arm.body);

                        // Clean up pattern variables
                        try self.cleanupPatternVariables(locals_before);

                        // Jump to end of match
                        try self.assembler.jmpRel32(0);
                        try arm_end_jumps.append(self.allocator, self.assembler.getPosition() - 5);

                        // Patch guard fail jump to next arm
                        const next_pos = self.assembler.getPosition();
                        const guard_offset = @as(i32, @intCast(next_pos)) - @as(i32, @intCast(guard_fail_jump + 6));
                        try self.assembler.patchJzRel32(guard_fail_jump, guard_offset);
                    } else {
                        // No guard, execute arm body directly
                        try self.generateExpr(arm.body);

                        // Clean up pattern variables
                        try self.cleanupPatternVariables(locals_before);

                        // Jump to end of match
                        try self.assembler.jmpRel32(0);
                        try arm_end_jumps.append(self.allocator, self.assembler.getPosition() - 5);
                    }

                    // Patch pattern match fail jump to next arm
                    const next_arm_pos = self.assembler.getPosition();
                    const next_offset = @as(i32, @intCast(next_arm_pos)) - @as(i32, @intCast(next_arm_jump + 6));
                    try self.assembler.patchJzRel32(next_arm_jump, next_offset);
                }

                // Match value is in r10, no need to pop from stack

                // Patch all "end of match" jumps
                const match_end = self.assembler.getPosition();
                for (arm_end_jumps.items) |jump_pos| {
                    const offset = @as(i32, @intCast(match_end)) - @as(i32, @intCast(jump_pos + 5));
                    try self.assembler.patchJmpRel32(jump_pos, offset);
                }

                // Restore callee-saved register rbx
                try self.assembler.popReg(.rbx);
            },
            else => {
                std.debug.print("Unsupported statement in native codegen: {s}\n", .{@tagName(stmt)});
                return error.UnsupportedFeature;
            },
        }
    }

    fn handleImport(self: *NativeCodegen, import_decl: *ast.ImportDecl) CodegenError!void {
        // Convert import path to file path
        // For now, simple strategy: join path components with '/' and add '.home'
        var path_buffer: [256]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&path_buffer);
        const writer = fbs.writer();

        for (import_decl.path, 0..) |component, i| {
            if (i > 0) try writer.writeByte('/');
            try writer.writeAll(component);
        }
        try writer.writeAll(".home");

        const module_path = fbs.getWritten();

        // Read and parse the module file
        const module_source = std.fs.cwd().readFileAlloc(
            self.allocator,
            module_path,
            10 * 1024 * 1024, // 10MB max
        ) catch |err| {
            std.debug.print("Failed to read import file '{s}': {}\n", .{module_path, err});
            return error.ImportFailed;
        };
        defer self.allocator.free(module_source);

        // Parse the module
        const lexer_mod = @import("lexer");
        const parser_mod = @import("parser");

        var lexer = lexer_mod.Lexer.init(self.allocator, module_source);
        var token_list = lexer.tokenize() catch |err| {
            std.debug.print("Failed to tokenize module '{s}': {}\n", .{module_path, err});
            return error.ImportFailed;
        };
        defer token_list.deinit(self.allocator);
        const tokens = token_list.items;

        var parser = parser_mod.Parser.init(self.allocator, tokens) catch |err| {
            std.debug.print("Failed to create parser for module '{s}': {}\n", .{module_path, err});
            return error.ImportFailed;
        };
        const module_ast = parser.parse() catch |err| {
            std.debug.print("Failed to parse module '{s}': {}\n", .{module_path, err});
            return error.ImportFailed;
        };
        defer module_ast.deinit(self.allocator);

        // Generate code for all module statements
        // This will register functions, structs, etc. in our codegen context
        for (module_ast.statements) |stmt| {
            try self.generateStmt(stmt);
        }
    }

    /// Check if an expression is a string type
    fn isStringExpr(self: *NativeCodegen, expr: *ast.Expr) bool {
        _ = self;
        return switch (expr.*) {
            .StringLiteral => true,
            .Identifier => |id| {
                // Check if variable has string type
                // For now, we'll check during runtime based on the value
                // This is simplified - a proper type system would track this
                _ = id;
                return false;
            },
            else => false,
        };
    }

    /// Handle string binary operations (concatenation and comparison)
    fn handleStringBinaryOp(self: *NativeCodegen, binary: *ast.BinaryExpr) !void {
        switch (binary.op) {
            .Add => {
                // String concatenation
                try self.stringConcat(binary.left, binary.right);
            },
            .Equal, .NotEqual => {
                // String comparison
                try self.stringCompare(binary.left, binary.right, binary.op);
            },
            .Less, .LessEq, .Greater, .GreaterEq => {
                // String ordering comparison
                try self.stringOrderCompare(binary.left, binary.right, binary.op);
            },
            else => {
                std.debug.print("Unsupported string operation: {}\n", .{binary.op});
                return error.UnsupportedFeature;
            },
        }
    }

    /// Concatenate two strings
    fn stringConcat(self: *NativeCodegen, left: *ast.Expr, right: *ast.Expr) !void {
        // Evaluate left string (pointer in rax)
        try self.generateExpr(left);
        try self.assembler.pushReg(.rax); // Save left string pointer

        // Evaluate right string (pointer in rax)
        try self.generateExpr(right);
        try self.assembler.movRegReg(.rcx, .rax); // Right string in rcx

        // Pop left string pointer
        try self.assembler.popReg(.rax); // Left string in rax

        // Now: rax = left string pointer, rcx = right string pointer
        // We need to:
        // 1. Calculate strlen(left) -> store in r8
        // 2. Calculate strlen(right) -> store in r9
        // 3. Allocate buffer of size (strlen(left) + strlen(right) + 1)
        // 4. Copy left string to buffer
        // 5. Copy right string to buffer + strlen(left)
        // 6. Null-terminate
        // 7. Return pointer to concatenated string in rax

        // Save string pointers
        try self.assembler.pushReg(.rax); // Save left
        try self.assembler.pushReg(.rcx); // Save right

        // Calculate strlen(left)
        try self.assembler.popReg(.rdi); // rdi = left string (for strlen)
        try self.assembler.pushReg(.rdi); // Save again
        try self.stringLength(.rdi); // Result in rax
        try self.assembler.movRegReg(.r8, .rax); // r8 = strlen(left)

        // Calculate strlen(right)
        try self.assembler.popReg(.rax); // Pop left (discard)
        try self.assembler.popReg(.rdi); // rdi = right string (for strlen)
        try self.assembler.pushReg(.rdi); // Save again
        try self.stringLength(.rdi); // Result in rax
        try self.assembler.movRegReg(.r9, .rax); // r9 = strlen(right)

        // Calculate total size = r8 + r9 + 1
        try self.assembler.movRegReg(.rax, .r8);
        try self.assembler.addRegReg(.rax, .r9);
        try self.assembler.addRegImm(.rax, 1); // +1 for null terminator

        // Allocate buffer (size in rax)
        try self.assembler.movRegReg(.rdi, .rax); // Size for allocation
        try self.heapAlloc(); // Returns pointer in rax
        try self.assembler.movRegReg(.r10, .rax); // r10 = destination buffer

        // Pop string pointers in correct order
        try self.assembler.popReg(.rcx); // rcx = right string
        try self.assembler.pushReg(.rcx); // Save for later
        try self.assembler.popReg(.rax); // rax = left string (from earlier push)
        try self.assembler.pushReg(.rax); // Save for later

        // Copy left string to buffer
        // memcpy(r10, rax, r8)
        try self.assembler.movRegReg(.rdi, .r10); // dest
        try self.assembler.movRegReg(.rsi, .rax); // src = left string
        try self.assembler.movRegReg(.rdx, .r8); // count = strlen(left)
        try self.memcpy();

        // Copy right string to buffer + strlen(left)
        try self.assembler.popReg(.rax); // Pop left (discard)
        try self.assembler.popReg(.rcx); // rcx = right string
        try self.assembler.movRegReg(.rdi, .r10); // dest = buffer start
        try self.assembler.addRegReg(.rdi, .r8); // dest += strlen(left)
        try self.assembler.movRegReg(.rsi, .rcx); // src = right string
        try self.assembler.movRegReg(.rdx, .r9); // count = strlen(right)
        try self.memcpy();

        // Null-terminate
        try self.assembler.movRegReg(.rdi, .r10); // dest = buffer start
        try self.assembler.addRegReg(.rdi, .r8); // dest += strlen(left)
        try self.assembler.addRegReg(.rdi, .r9); // dest += strlen(right)
        try self.assembler.movByteMemImm(.rdi, 0, 0); // *dest = '\0'

        // Return pointer to concatenated string in rax
        try self.assembler.movRegReg(.rax, .r10);
    }

    /// Compare two strings for equality/inequality
    fn stringCompare(self: *NativeCodegen, left: *ast.Expr, right: *ast.Expr, op: ast.BinaryOp) !void {
        // Evaluate left string (pointer in rax)
        try self.generateExpr(left);
        try self.assembler.pushReg(.rax);

        // Evaluate right string (pointer in rax)
        try self.generateExpr(right);
        try self.assembler.movRegReg(.rsi, .rax); // Right string in rsi

        // Pop left string pointer
        try self.assembler.popReg(.rdi); // Left string in rdi

        // Compare strings byte by byte
        try self.strcmp(.rdi, .rsi); // Result in rax (0 if equal, non-zero otherwise)

        // Convert result to boolean based on operation
        switch (op) {
            .Equal => {
                // Check if result == 0
                try self.assembler.testRegReg(.rax, .rax);
                try self.assembler.setzReg(.rax);
                try self.assembler.movzxReg64Reg8(.rax, .rax);
            },
            .NotEqual => {
                // Check if result != 0
                try self.assembler.testRegReg(.rax, .rax);
                try self.assembler.setneReg(.rax);
                try self.assembler.movzxReg64Reg8(.rax, .rax);
            },
            else => unreachable,
        }
    }

    /// Compare two strings for ordering
    fn stringOrderCompare(self: *NativeCodegen, left: *ast.Expr, right: *ast.Expr, op: ast.BinaryOp) !void {
        // Evaluate left string (pointer in rax)
        try self.generateExpr(left);
        try self.assembler.pushReg(.rax);

        // Evaluate right string (pointer in rax)
        try self.generateExpr(right);
        try self.assembler.movRegReg(.rsi, .rax); // Right string in rsi

        // Pop left string pointer
        try self.assembler.popReg(.rdi); // Left string in rdi

        // Compare strings byte by byte (returns -1, 0, or 1)
        try self.strcmp(.rdi, .rsi); // Result in rax

        // Convert result to boolean based on operation
        switch (op) {
            .Less => {
                // Check if result < 0
                try self.assembler.cmpRegImm(.rax, 0);
                try self.assembler.setlReg(.rax);
                try self.assembler.movzxReg64Reg8(.rax, .rax);
            },
            .LessEq => {
                // Check if result <= 0
                try self.assembler.cmpRegImm(.rax, 0);
                try self.assembler.setleReg(.rax);
                try self.assembler.movzxReg64Reg8(.rax, .rax);
            },
            .Greater => {
                // Check if result > 0
                try self.assembler.cmpRegImm(.rax, 0);
                try self.assembler.setgReg(.rax);
                try self.assembler.movzxReg64Reg8(.rax, .rax);
            },
            .GreaterEq => {
                // Check if result >= 0
                try self.assembler.cmpRegImm(.rax, 0);
                try self.assembler.setgeReg(.rax);
                try self.assembler.movzxReg64Reg8(.rax, .rax);
            },
            else => unreachable,
        }
    }

    /// Calculate string length
    /// Input: register containing string pointer
    /// Output: rax = length
    fn stringLength(self: *NativeCodegen, str_reg: x64.Register) !void {
        // strlen: count bytes until null terminator
        try self.assembler.xorRegReg(.rax, .rax); // rax = 0 (counter)
        try self.assembler.movRegReg(.r11, str_reg); // r11 = string pointer (copy)

        // Loop: while (*r11 != 0) { rax++; r11++; }
        const loop_start = self.assembler.getPosition();

        // Load byte from [r11]
        try self.assembler.movzxReg64Mem8(.rcx, .r11, 0);

        // Check if byte is 0
        try self.assembler.testRegReg(.rcx, .rcx);

        // If zero, exit loop (jump forward)
        const je_pos = try self.assembler.jeRel8(0); // Placeholder

        // Increment counter
        try self.assembler.addRegImm(.rax, 1);

        // Increment pointer
        try self.assembler.addRegImm(.r11, 1);

        // Jump back to loop start
        const current_pos = self.assembler.getPosition();
        const rel_offset = @as(i8, @intCast(@as(i32, @intCast(loop_start)) - @as(i32, @intCast(current_pos + 2))));
        _ = try self.assembler.jmpRel8(rel_offset);

        // Patch the je instruction
        const exit_pos = self.assembler.getPosition();
        const je_offset = @as(i8, @intCast(@as(i32, @intCast(exit_pos)) - @as(i32, @intCast(je_pos + 2))));
        self.assembler.patchJe8(je_pos, je_offset);
    }

    /// Compare two strings
    /// Input: rdi = string1, rsi = string2
    /// Output: rax = 0 if equal, <0 if s1<s2, >0 if s1>s2
    fn strcmp(self: *NativeCodegen, str1_reg: x64.Register, str2_reg: x64.Register) !void {
        try self.assembler.movRegReg(.r11, str1_reg); // r11 = string1
        try self.assembler.movRegReg(.r12, str2_reg); // r12 = string2

        // Loop: compare byte by byte
        const loop_start = self.assembler.getPosition();

        // Load bytes
        try self.assembler.movzxReg64Mem8(.rax, .r11, 0); // rax = *s1
        try self.assembler.movzxReg64Mem8(.rcx, .r12, 0); // rcx = *s2

        // Compare bytes
        try self.assembler.cmpRegReg(.rax, .rcx);

        // If not equal, return difference
        const jne_pos = try self.assembler.jneRel8(0); // Placeholder

        // If both are 0, strings are equal
        try self.assembler.testRegReg(.rax, .rax);
        const je_pos = try self.assembler.jeRel8(0); // Placeholder (exit with rax=0)

        // Increment pointers
        try self.assembler.addRegImm(.r11, 1);
        try self.assembler.addRegImm(.r12, 1);

        // Jump back to loop start
        const current_pos2 = self.assembler.getPosition();
        const rel_offset2 = @as(i8, @intCast(@as(i32, @intCast(loop_start)) - @as(i32, @intCast(current_pos2 + 2))));
        _ = try self.assembler.jmpRel8(rel_offset2);

        // Patch jne: return difference (rax - rcx)
        const diff_pos = self.assembler.getPosition();
        const jne_offset = @as(i8, @intCast(@as(i32, @intCast(diff_pos)) - @as(i32, @intCast(jne_pos + 2))));
        self.assembler.patchJne8(jne_pos, jne_offset);

        try self.assembler.subRegReg(.rax, .rcx); // rax = rax - rcx
        const jmp_exit_pos = try self.assembler.jmpRel8(0); // Jump to end

        // Patch je: return 0 (already in rax)
        const equal_pos = self.assembler.getPosition();
        const je_offset = @as(i8, @intCast(@as(i32, @intCast(equal_pos)) - @as(i32, @intCast(je_pos + 2))));
        self.assembler.patchJe8(je_pos, je_offset);

        try self.assembler.xorRegReg(.rax, .rax); // rax = 0

        // Patch final jump
        const exit_pos = self.assembler.getPosition();
        const jmp_offset = @as(i8, @intCast(@as(i32, @intCast(exit_pos)) - @as(i32, @intCast(jmp_exit_pos + 2))));
        self.assembler.patchJmp8(jmp_exit_pos, jmp_offset);
    }

    /// Copy memory from src to dest
    /// Input: rdi = dest, rsi = src, rdx = count
    fn memcpy(self: *NativeCodegen) !void {
        // Simple byte-by-byte copy
        try self.assembler.testRegReg(.rdx, .rdx);
        const je_exit = try self.assembler.jeRel8(0); // If count==0, exit

        const loop_start = self.assembler.getPosition();

        // Load byte from [rsi]
        try self.assembler.movzxReg64Mem8(.rax, .rsi, 0);

        // Store byte to [rdi]
        try self.assembler.movByteMemReg(.rdi, 0, .rax);

        // Increment pointers
        try self.assembler.addRegImm(.rsi, 1);
        try self.assembler.addRegImm(.rdi, 1);

        // Decrement counter
        try self.assembler.subRegImm(.rdx, 1);

        // Loop if rdx != 0
        try self.assembler.testRegReg(.rdx, .rdx);
        const current_pos3 = self.assembler.getPosition();
        const rel_offset3 = @as(i8, @intCast(@as(i32, @intCast(loop_start)) - @as(i32, @intCast(current_pos3 + 2))));
        _ = try self.assembler.jneRel8(rel_offset3);

        // Patch exit jump
        const exit_pos = self.assembler.getPosition();
        const je_offset = @as(i8, @intCast(@as(i32, @intCast(exit_pos)) - @as(i32, @intCast(je_exit + 2))));
        self.assembler.patchJe8(je_exit, je_offset);
    }

    /// Allocate memory on the heap
    /// Input: rdi = size to allocate
    /// Output: rax = pointer to allocated memory
    fn heapAlloc(self: *NativeCodegen) !void {
        // Simple bump allocator
        // Heap pointer stored at HEAP_START - 8
        // For now, we'll use a simpler approach: allocate on stack
        // In a real implementation, this would use a proper heap allocator

        // Allocate on stack (simple but works for testing)
        try self.assembler.subRegReg(.rsp, .rdi);
        try self.assembler.movRegReg(.rax, .rsp);
    }

    fn generateFnDecl(self: *NativeCodegen, func: *ast.FnDecl) !void {
        // Reset local variable tracking for new function
        self.next_local_offset = 0;

        // Free duplicated strings before clearing locals
        var iter = self.locals.keyIterator();
        while (iter.next()) |key_ptr| {
            self.allocator.free(key_ptr.*);
        }
        self.locals.clearRetainingCapacity();

        // Record function position
        const func_pos = self.assembler.getPosition();
        const name_copy = try self.allocator.dupe(u8, func.name);
        errdefer self.allocator.free(name_copy);
        try self.functions.put(name_copy, func_pos);

        // Function prologue
        try self.assembler.pushReg(.rbp);
        try self.assembler.movRegReg(.rbp, .rsp);

        // Handle parameters - x86-64 calling convention:
        // First 6 integer args: rdi, rsi, rdx, rcx, r8, r9
        // Additional args on stack
        const param_regs = [_]x64.Register{ .rdi, .rsi, .rdx, .rcx, .r8, .r9 };

        for (func.params, 0..) |param, i| {
            if (i < param_regs.len) {
                // Parameter is in register - save to stack
                const offset = self.next_local_offset;
                self.next_local_offset += 1; // Increment count, not bytes

                // Store parameter name, offset, and type
                const name = try self.allocator.dupe(u8, param.name);
                errdefer self.allocator.free(name);
                const param_size = try self.getTypeSize(param.type_name);
                try self.locals.put(name, .{
                    .offset = offset,
                    .type_name = param.type_name,
                    .size = param_size,
                });

                // Push parameter register onto stack
                try self.assembler.pushReg(param_regs[i]);
            } else {
                // Parameter is on stack (passed by caller)
                // TODO: Handle stack parameters
                return error.UnsupportedFeature;
            }
        }

        // Generate function body
        for (func.body.statements) |stmt| {
            try self.generateStmt(stmt);
        }

        // Function epilogue (only if no explicit return at end)
        const needs_epilogue = func.body.statements.len == 0 or
            func.body.statements[func.body.statements.len - 1] != .ReturnStmt;

        if (needs_epilogue) {
            try self.assembler.movRegReg(.rsp, .rbp);
            try self.assembler.popReg(.rbp);
            try self.assembler.ret();
        }
    }

    fn generateLetDecl(self: *NativeCodegen, decl: *ast.LetDecl) !void {
        if (self.next_local_offset >= MAX_LOCALS) {
            return error.TooManyVariables;
        }

        if (decl.value) |value| {
            const type_name = decl.type_name orelse "i32";  // Default to i32 if no type given

            // Check if this is an array type
            const is_array = type_name.len > 0 and type_name[0] == '[';

            if (is_array and value.* == .ArrayLiteral) {
                // Special handling for array literals
                const array_lit = value.ArrayLiteral;
                const elem_size: usize = 8; // All values are i64 for now
                const num_elements = array_lit.elements.len;

                // Array base points to the first element (index 0)
                const array_start_offset = self.next_local_offset;

                // Store variable name with pointer to array start
                const name = try self.allocator.dupe(u8, decl.name);
                errdefer self.allocator.free(name);
                try self.locals.put(name, .{
                    .offset = array_start_offset,
                    .type_name = type_name,
                    .size = num_elements * elem_size,
                });

                // Evaluate and push each element onto stack in FORWARD order
                // Element 0 at [rbp - (offset+1)*8], element 1 at [rbp - (offset+2)*8], etc.
                for (array_lit.elements) |elem| {
                    if (self.next_local_offset >= MAX_LOCALS) {
                        return error.TooManyVariables;
                    }
                    try self.generateExpr(elem);
                    try self.assembler.pushReg(.rax);
                    self.next_local_offset += 1;
                }
            } else if (value.* == .StructLiteral) {
                // Special handling for struct literals
                const struct_lit = value.StructLiteral;

                // Get struct layout
                const struct_layout = self.struct_layouts.get(struct_lit.type_name) orelse {
                    std.debug.print("Unknown struct type: {s}\n", .{struct_lit.type_name});
                    return error.UnsupportedFeature;
                };

                // Struct base points to first field
                const struct_start_offset = self.next_local_offset;

                // Store variable name
                const name = try self.allocator.dupe(u8, decl.name);
                errdefer self.allocator.free(name);
                try self.locals.put(name, .{
                    .offset = struct_start_offset,
                    .type_name = type_name,
                    .size = struct_layout.total_size,
                });

                // Allocate and initialize fields in order
                // We need to match fields in the literal to fields in the layout
                for (struct_layout.fields) |field_info| {
                    if (self.next_local_offset >= MAX_LOCALS) {
                        return error.TooManyVariables;
                    }

                    // Find the field in the literal
                    var field_value: ?*ast.Expr = null;
                    for (struct_lit.fields) |lit_field| {
                        if (std.mem.eql(u8, lit_field.name, field_info.name)) {
                            field_value = lit_field.value;
                            break;
                        }
                    }

                    if (field_value) |val| {
                        // Evaluate and push field value
                        try self.generateExpr(val);
                        try self.assembler.pushReg(.rax);
                        self.next_local_offset += 1;
                    } else {
                        // Field not initialized - push zero
                        try self.assembler.movRegImm64(.rax, 0);
                        try self.assembler.pushReg(.rax);
                        self.next_local_offset += 1;
                    }
                }
            } else if (self.enum_layouts.contains(type_name)) {
                // Special handling for enum values
                // Enums are 16 bytes: [tag (8 bytes)][data (8 bytes)]
                // The enum constructor pushes: data first, then tag
                // So the stack layout is: [tag at lower addr] [data at higher addr]

                // Evaluate the enum constructor expression
                // This will push data then tag onto stack and return pointer in rax
                try self.generateExpr(value);

                // rax now contains pointer to the enum on stack (points to tag)
                // The enum constructor pushed 2 values:
                // - offset+0: data (pushed first, higher address)
                // - offset+1: tag (pushed second, lower address)

                // We want the variable to point to the tag (the second push)
                const tag_offset = self.next_local_offset + 1;

                // Store variable name pointing to the tag
                const name = try self.allocator.dupe(u8, decl.name);
                errdefer self.allocator.free(name);
                try self.locals.put(name, .{
                    .offset = tag_offset,
                    .type_name = type_name,
                    .size = 16, // All enums are 16 bytes (tag + data)
                });

                // Update offset to account for 2 slots used by enum
                self.next_local_offset += 2;
            } else {
                // Regular scalar value
                // Evaluate the expression (result in rax)
                try self.generateExpr(value);

                // Store on stack
                const offset = self.next_local_offset;
                self.next_local_offset += 1; // Increment count, not bytes

                // Store variable name, offset, and type
                const name = try self.allocator.dupe(u8, decl.name);
                errdefer self.allocator.free(name);
                const var_size = try self.getTypeSize(type_name);
                try self.locals.put(name, .{
                    .offset = offset,
                    .type_name = type_name,
                    .size = var_size,
                });

                // Push rax onto stack
                try self.assembler.pushReg(.rax);
            }
        }
    }

    fn generateExpr(self: *NativeCodegen, expr: *const ast.Expr) CodegenError!void {
        switch (expr.*) {
            .IntegerLiteral => |lit| {
                // Load immediate value into rax
                try self.assembler.movRegImm64(.rax, lit.value);
            },
            .BooleanLiteral => |lit| {
                // Load boolean value into rax (0 for false, 1 for true)
                try self.assembler.movRegImm64(.rax, if (lit.value) 1 else 0);
            },
            .Identifier => |id| {
                // Load from stack
                if (self.locals.get(id.name)) |local_info| {
                    // Check if this is an array, struct, or enum type - return pointer instead of value
                    const is_array = local_info.type_name.len > 0 and local_info.type_name[0] == '[';
                    const is_struct = self.struct_layouts.contains(local_info.type_name);
                    const is_enum = self.enum_layouts.contains(local_info.type_name);

                    // Stack layout after function prologue:
                    // [rbp+0]: saved rbp
                    // [rbp-8]: first pushed item (offset=0)
                    // [rbp-16]: second pushed item (offset=1)
                    // [rbp-24]: third pushed item (offset=2)
                    // etc.
                    // Items pushed first are at higher addresses (closer to rbp)
                    const stack_offset: i32 = -@as(i32, @intCast((local_info.offset + 1) * 8));

                    if (is_array or is_struct or is_enum) {
                        // For arrays, structs, and enums, return pointer to start
                        // lea rax, [rbp + stack_offset]
                        try self.assembler.movRegReg(.rax, .rbp);
                        try self.assembler.addRegImm32(.rax, stack_offset);
                    } else {
                        // For scalars, load the value
                        // mov rax, [rbp + stack_offset]
                        try self.assembler.movRegMem(.rax, .rbp, stack_offset);
                    }
                } else {
                    std.debug.print("Undefined variable: {s}\n", .{id.name});
                    return error.UndefinedVariable;
                }
            },
            .BinaryExpr => |binary| {
                // Check if this is a string operation
                const is_string_op = self.isStringExpr(binary.left) or self.isStringExpr(binary.right);

                if (is_string_op) {
                    // Handle string operations
                    try self.handleStringBinaryOp(binary);
                    return;
                }

                // Evaluate right operand first (save result)
                try self.generateExpr(binary.right);
                try self.assembler.pushReg(.rax);

                // Evaluate left operand (result in rax)
                try self.generateExpr(binary.left);

                // Pop right operand into rcx
                try self.assembler.popReg(.rcx);

                // Perform operation
                switch (binary.op) {
                    .Add => try self.assembler.addRegReg(.rax, .rcx),
                    .Sub => try self.assembler.subRegReg(.rax, .rcx),
                    .Mul => try self.assembler.imulRegReg(.rax, .rcx),
                    .Div => {
                        // For division: rdx:rax / rcx -> rax=quotient, rdx=remainder
                        // Need to sign-extend rax into rdx first
                        try self.assembler.cqo();
                        try self.assembler.idivReg(.rcx);
                    },
                    .Mod => {
                        // Modulo: same as division but we want rdx (remainder)
                        try self.assembler.cqo();
                        try self.assembler.idivReg(.rcx);
                        // Move remainder from rdx to rax
                        try self.assembler.movRegReg(.rax, .rdx);
                    },
                    // Comparison operators - result is 0 or 1
                    .Equal => {
                        // cmp rax, rcx; sete al; movzx rax, al
                        try self.assembler.cmpRegReg(.rax, .rcx);
                        try self.assembler.seteReg(.rax);
                        try self.assembler.movzxReg64Reg8(.rax, .rax);
                    },
                    .NotEqual => {
                        try self.assembler.cmpRegReg(.rax, .rcx);
                        try self.assembler.setneReg(.rax);
                        try self.assembler.movzxReg64Reg8(.rax, .rax);
                    },
                    .Less => {
                        try self.assembler.cmpRegReg(.rax, .rcx);
                        try self.assembler.setlReg(.rax);
                        try self.assembler.movzxReg64Reg8(.rax, .rax);
                    },
                    .LessEq => {
                        try self.assembler.cmpRegReg(.rax, .rcx);
                        try self.assembler.setleReg(.rax);
                        try self.assembler.movzxReg64Reg8(.rax, .rax);
                    },
                    .Greater => {
                        try self.assembler.cmpRegReg(.rax, .rcx);
                        try self.assembler.setgReg(.rax);
                        try self.assembler.movzxReg64Reg8(.rax, .rax);
                    },
                    .GreaterEq => {
                        try self.assembler.cmpRegReg(.rax, .rcx);
                        try self.assembler.setgeReg(.rax);
                        try self.assembler.movzxReg64Reg8(.rax, .rax);
                    },
                    // Logical operators - treat as boolean (0 = false, non-zero = true)
                    .And => {
                        // Convert to boolean first: test rax, rax; setne al; movzx rax, al
                        try self.assembler.testRegReg(.rax, .rax);
                        try self.assembler.setneReg(.rax);
                        try self.assembler.movzxReg64Reg8(.rax, .rax);
                        // Save left boolean in r11
                        try self.assembler.movRegReg(.r11, .rax);
                        // Convert right to boolean
                        try self.assembler.testRegReg(.rcx, .rcx);
                        try self.assembler.setneReg(.rcx);
                        try self.assembler.movzxReg64Reg8(.rcx, .rcx);
                        // AND the booleans
                        try self.assembler.andRegReg(.rax, .rcx);
                    },
                    .Or => {
                        // Convert to boolean and OR
                        try self.assembler.testRegReg(.rax, .rax);
                        try self.assembler.setneReg(.rax);
                        try self.assembler.movzxReg64Reg8(.rax, .rax);
                        try self.assembler.movRegReg(.r11, .rax);
                        try self.assembler.testRegReg(.rcx, .rcx);
                        try self.assembler.setneReg(.rcx);
                        try self.assembler.movzxReg64Reg8(.rcx, .rcx);
                        try self.assembler.orRegReg(.rax, .rcx);
                    },
                    // Bitwise operators
                    .BitAnd => try self.assembler.andRegReg(.rax, .rcx),
                    .BitOr => try self.assembler.orRegReg(.rax, .rcx),
                    .BitXor => try self.assembler.xorRegReg(.rax, .rcx),
                    // Shift operators (shift amount must be in CL register)
                    .LeftShift => {
                        // Left operand (value to shift) is in rax
                        // Right operand (shift amount) is in rcx
                        // x64 shift instructions require shift amount in CL (lower 8 bits of RCX)
                        try self.assembler.shlRegCl(.rax);
                    },
                    .RightShift => {
                        // Logical right shift (unsigned)
                        try self.assembler.shrRegCl(.rax);
                    },
                    else => {
                        std.debug.print("Unsupported binary op in native codegen: {}\n", .{binary.op});
                        return error.UnsupportedFeature;
                    },
                }
            },
            .UnaryExpr => |unary| {
                // Evaluate operand first (result in rax)
                try self.generateExpr(unary.operand);

                // Apply unary operation
                switch (unary.op) {
                    .Neg => {
                        // Arithmetic negation: neg rax
                        try self.assembler.negReg(.rax);
                    },
                    .Not => {
                        // Logical NOT: convert to boolean first, then invert
                        // test rax, rax; setz al; movzx rax, al
                        try self.assembler.testRegReg(.rax, .rax);
                        try self.assembler.setzReg(.rax);
                        try self.assembler.movzxReg64Reg8(.rax, .rax);
                    },
                    .BitNot => {
                        // Bitwise NOT: not rax
                        try self.assembler.notReg(.rax);
                    },
                    .Deref, .AddressOf => {
                        std.debug.print("Pointer operations not yet implemented in native codegen\n", .{});
                        return error.UnsupportedFeature;
                    },
                }
            },
            .CallExpr => |call| {
                // Check if this is an enum variant constructor (e.g., Option.Some(42))
                if (call.callee.* == .MemberExpr) {
                    const member = call.callee.MemberExpr;
                    if (member.object.* == .Identifier) {
                        const enum_name = member.object.Identifier.name;
                        const variant_name = member.member;

                        if (self.enum_layouts.get(enum_name)) |enum_layout| {
                            // Find the variant
                            var variant_index: ?usize = null;
                            var variant_info: ?EnumVariantInfo = null;
                            for (enum_layout.variants, 0..) |v, i| {
                                if (std.mem.eql(u8, v.name, variant_name)) {
                                    variant_index = i;
                                    variant_info = v;
                                    break;
                                }
                            }

                            if (variant_index) |idx| {
                                // Create enum value on stack
                                // Layout: [tag (8 bytes)][data (8 bytes if present)]
                                // Tag is the variant index

                                // Evaluate argument if present
                                if (variant_info.?.data_type != null) {
                                    if (call.args.len > 0) {
                                        try self.generateExpr(call.args[0]);
                                        // Data value is in rax
                                        try self.assembler.pushReg(.rax); // Push data
                                    } else {
                                        // No arg provided but expected - push 0
                                        try self.assembler.movRegImm64(.rax, 0);
                                        try self.assembler.pushReg(.rax);
                                    }
                                } else {
                                    // No data for this variant - push 0 as placeholder
                                    try self.assembler.movRegImm64(.rax, 0);
                                    try self.assembler.pushReg(.rax);
                                }

                                // Push tag (variant index)
                                try self.assembler.movRegImm64(.rax, @intCast(idx));
                                try self.assembler.pushReg(.rax);

                                // Return pointer to the enum value on stack
                                // lea rax, [rsp]
                                try self.assembler.movRegReg(.rax, .rsp);

                                return;
                            }
                        }
                    }
                }

                // x64 calling convention: rdi, rsi, rdx, rcx, r8, r9 for first 6 args
                if (call.callee.* == .Identifier) {
                    const func_name = call.callee.Identifier.name;

                    // Check if it's a known function
                    if (self.functions.get(func_name)) |func_pos| {
                        // x64 System V ABI: first 6 integer args in registers
                        const arg_regs = [_]x64.Register{ .rdi, .rsi, .rdx, .rcx, .r8, .r9 };
                        const arg_count = @min(call.args.len, arg_regs.len);

                        // Evaluate all arguments and push onto stack first
                        var i: usize = 0;
                        while (i < arg_count) : (i += 1) {
                            try self.generateExpr(call.args[i]);
                            try self.assembler.pushReg(.rax);
                        }

                        // Pop arguments into correct registers (in reverse order)
                        if (arg_count > 0) {
                            var j: usize = arg_count;
                            while (j > 0) {
                                j -= 1;
                                try self.assembler.popReg(arg_regs[j]);
                            }
                        }

                        // Calculate relative offset to function
                        const current_pos = self.assembler.getPosition();
                        const rel_offset = @as(i32, @intCast(func_pos)) - @as(i32, @intCast(current_pos + 5));
                        try self.assembler.callRel32(rel_offset);

                        return;
                    }

                    // Handle built-in functions
                    if (std.mem.eql(u8, func_name, "print")) {
                        // Print function: converts integer to string and writes to stdout
                        if (call.args.len > 0) {
                            try self.generateExpr(call.args[0]);

                            // Value to print is in rax
                            // We need to convert it to ASCII and write to stdout
                            // Using Linux write syscall: write(1, buffer, length)

                            // Allocate buffer on stack for number string (20 bytes = max i64 digits)
                            try self.assembler.movRegImm64(.rdx, 20);
                            try self.assembler.subRegReg(.rsp, .rdx);
                            try self.assembler.movRegReg(.rbx, .rsp); // rbx = buffer pointer

                            // Number-to-bytes conversion (writes raw bytes to stdout)
                            // Store number at buffer
                            try self.generateMovMemReg(.rbx, 0, .rax);

                            // Write syscall: rax=1 (write), rdi=1 (stdout), rsi=buffer, rdx=8
                            try self.assembler.movRegImm64(.rax, 1); // sys_write
                            try self.assembler.movRegImm64(.rdi, 1); // stdout
                            try self.assembler.movRegReg(.rsi, .rbx); // buffer
                            try self.assembler.movRegImm64(.rdx, 8); // length (8 bytes for i64)
                            try self.assembler.syscall();

                            // Restore stack
                            try self.assembler.movRegImm64(.rdx, 20);
                            try self.assembler.addRegReg(.rsp, .rdx);
                        }
                        return;
                    }

                    if (std.mem.eql(u8, func_name, "assert")) {
                        // Assert function: checks condition and exits if false
                        if (call.args.len > 0) {
                            try self.generateExpr(call.args[0]);

                            // Test condition
                            try self.assembler.testRegReg(.rax, .rax);

                            // If true (non-zero), skip exit
                            const jnz_pos = self.assembler.getPosition();
                            try self.assembler.jnzRel32(0);

                            // Condition false - exit with code 1
                            const exit_syscall: u64 = switch (builtin.os.tag) {
                                .macos => 0x2000001,
                                .linux => 60,
                                else => 60,
                            };
                            try self.assembler.movRegImm64(.rax, exit_syscall);
                            try self.assembler.movRegImm64(.rdi, 1); // exit code 1
                            try self.assembler.syscall();

                            // Patch jump to here (continue execution)
                            const assert_end = self.assembler.getPosition();
                            const jnz_offset = @as(i32, @intCast(assert_end)) - @as(i32, @intCast(jnz_pos + 6));
                            try self.assembler.patchJnzRel32(jnz_pos, jnz_offset);
                        }
                        return;
                    }
                }

                // Unknown function
                std.debug.print("Unknown function in native codegen: {s}\n", .{call.callee.Identifier.name});
                return error.UnsupportedFeature;
            },
            .TernaryExpr => |ternary| {
                // Ternary: condition ? true_val : false_val
                // Evaluate condition
                try self.generateExpr(ternary.condition);

                // Test rax (condition result)
                try self.assembler.testRegReg(.rax, .rax);

                // Jump if zero (false) to false branch
                const jz_pos = self.assembler.getPosition();
                try self.assembler.jzRel32(0); // Placeholder

                // Generate true branch
                try self.generateExpr(ternary.true_val);

                // Jump over false branch
                const jmp_pos = self.assembler.getPosition();
                try self.assembler.jmpRel32(0); // Placeholder

                // Patch jz to point to false branch
                const false_start = self.assembler.getPosition();
                const jz_offset = @as(i32, @intCast(false_start)) - @as(i32, @intCast(jz_pos + 6));
                try self.assembler.patchJzRel32(jz_pos, jz_offset);

                // Generate false branch
                try self.generateExpr(ternary.false_val);

                // Patch jmp to point after false branch
                const ternary_end = self.assembler.getPosition();
                const jmp_offset = @as(i32, @intCast(ternary_end)) - @as(i32, @intCast(jmp_pos + 5));
                try self.assembler.patchJmpRel32(jmp_pos, jmp_offset);
            },
            .NullCoalesceExpr => |null_coalesce| {
                // Null coalesce: left ?? right
                // In native code, we treat 0 as null for simplicity
                try self.generateExpr(null_coalesce.left);

                // Test if left is null (zero)
                try self.assembler.testRegReg(.rax, .rax);

                // Jump if not zero (has value) to end
                const jnz_pos = self.assembler.getPosition();
                try self.assembler.jnzRel32(0); // Placeholder

                // Evaluate right (default value)
                try self.generateExpr(null_coalesce.right);

                // Patch jnz to point to end
                const coalesce_end = self.assembler.getPosition();
                const jnz_offset = @as(i32, @intCast(coalesce_end)) - @as(i32, @intCast(jnz_pos + 6));
                try self.assembler.patchJnzRel32(jnz_pos, jnz_offset);
            },
            .PipeExpr => |pipe| {
                // Pipe: value |> function
                // Evaluate left (value)
                try self.generateExpr(pipe.left);

                // Save result in rdi (first argument register)
                try self.assembler.movRegReg(.rdi, .rax);

                // Call right (function)
                if (pipe.right.* == .Identifier or pipe.right.* == .CallExpr) {
                    // For function calls, the value in rdi becomes first argument
                    try self.generateExpr(pipe.right);
                } else {
                    std.debug.print("Pipe operator requires function on right side\n", .{});
                    return error.UnsupportedFeature;
                }
            },
            .SafeNavExpr => |safe_nav| {
                // Safe navigation: object?.member
                // Full implementation with actual member access

                // Evaluate object (result is pointer in rax)
                try self.generateExpr(safe_nav.object);

                // Save object pointer in rbx
                try self.assembler.movRegReg(.rbx, .rax);

                // Test if object is null (zero)
                try self.assembler.testRegReg(.rbx, .rbx);

                // Jump if zero (null) to return null
                const jz_pos = self.assembler.getPosition();
                try self.assembler.jzRel32(0); // Placeholder

                // Object is not null - access member
                const member_name = safe_nav.member;

                // Calculate field offset using member name hashing
                // Assumes struct layout: fields are 8-byte aligned, offset determined by member name
                var field_offset: i32 = 0;
                for (member_name) |char| {
                    field_offset +%= @as(i32, @intCast(char));
                }
                field_offset = @mod(field_offset, 8) * 8; // Hash to 0-7 fields, 8 bytes each

                // Load member value: mov rax, [rbx + offset]
                try self.assembler.movRegMem(.rax, .rbx, field_offset);

                // Jump over null return
                const jmp_pos = self.assembler.getPosition();
                try self.assembler.jmpRel32(0);

                // Null path: return 0 in rax
                const null_path = self.assembler.getPosition();
                const jz_offset = @as(i32, @intCast(null_path)) - @as(i32, @intCast(jz_pos + 6));
                try self.assembler.patchJzRel32(jz_pos, jz_offset);

                try self.assembler.xorRegReg(.rax, .rax); // rax = 0 (null)

                // End of safe nav
                const safe_nav_end = self.assembler.getPosition();
                const jmp_offset = @as(i32, @intCast(safe_nav_end)) - @as(i32, @intCast(jmp_pos + 5));
                try self.assembler.patchJmpRel32(jmp_pos, jmp_offset);
            },
            .SpreadExpr => |spread| {
                // Spread: ...array
                // Full implementation: unpack array elements onto stack

                // Evaluate the operand (should be an array/tuple pointer in rax)
                try self.generateExpr(spread.operand);

                // Array layout in memory:
                // [0-7]: length (usize)
                // [8+]: elements (8 bytes each)

                // Save array pointer in rbx
                try self.assembler.movRegReg(.rbx, .rax);

                // Load array length: mov rcx, [rbx]
                try self.assembler.movRegMem(.rcx, .rbx, 0);

                // Calculate element array start: rbx + 8
                try self.assembler.movRegImm64(.rdx, 8);
                try self.assembler.addRegReg(.rbx, .rdx);

                // Loop through elements and push them onto stack
                // Loop condition: rcx > 0
                const loop_start = self.assembler.getPosition();

                // Test if more elements
                try self.assembler.testRegReg(.rcx, .rcx);

                // Exit loop if rcx == 0
                const jz_loop_end = self.assembler.getPosition();
                try self.assembler.jzRel32(0);

                // Load element: mov rax, [rbx]
                try self.assembler.movRegMem(.rax, .rbx, 0);

                // Push element
                try self.assembler.pushReg(.rax);

                // Advance to next element: rbx += 8
                try self.assembler.movRegImm64(.rdx, 8);
                try self.assembler.addRegReg(.rbx, .rdx);

                // Decrement counter: rcx--
                try self.assembler.movRegImm64(.rdx, 1);
                try self.assembler.subRegReg(.rcx, .rdx);

                // Jump back to loop start
                const current_pos = self.assembler.getPosition();
                const back_offset = @as(i32, @intCast(loop_start)) - @as(i32, @intCast(current_pos + 5));
                try self.assembler.jmpRel32(back_offset);

                // Loop end
                const loop_end = self.assembler.getPosition();
                const jz_offset = @as(i32, @intCast(loop_end)) - @as(i32, @intCast(jz_loop_end + 6));
                try self.assembler.patchJzRel32(jz_loop_end, jz_offset);

                // Result: all elements are now on stack (can be used in tuple/array construction)
                // Return the count in rax for the caller to know how many elements were spread
                try self.assembler.movRegMem(.rax, .rbx, -8); // Load original length
            },
            .TupleExpr => |tuple| {
                // Tuple: (a, b, c)
                // Full implementation with stack-based allocation
                //
                // Tuple memory layout:
                // [0-7]: element count (usize)
                // [8-15]: element 0 (8 bytes)
                // [16-23]: element 1 (8 bytes)
                // ...

                const element_count = tuple.elements.len;

                // Stack grows downward, so we push in reverse order:
                // 1. Push elements (last to first)
                // 2. Push count
                // 3. Return stack pointer as tuple address

                // Push elements in reverse order
                var i: usize = element_count;
                while (i > 0) {
                    i -= 1;
                    try self.generateExpr(tuple.elements[i]);
                    try self.assembler.pushReg(.rax);
                }

                // Push element count as first field
                try self.assembler.movRegImm64(.rax, @intCast(element_count));
                try self.assembler.pushReg(.rax);

                // Return pointer to tuple start (current rsp)
                try self.assembler.movRegReg(.rax, .rsp);
            },
            .AwaitExpr => |await_expr| {
                // Await expression: await future_expr
                //
                // Full async state machine implementation:
                // 1. Evaluate the future expression
                // 2. Call future.poll()
                // 3. Check if Ready or Pending
                // 4. If Pending, save state and yield to runtime
                // 5. Runtime will call waker.wake() when ready
                // 6. Resume execution and get result

                // Evaluate the future expression (returns Future pointer in rax)
                try self.generateExpr(await_expr.expression);

                // Save future pointer
                try self.assembler.pushReg(.rax);

                // Poll loop label
                const poll_loop_start = self.assembler.getPosition();

                // Restore future pointer
                try self.assembler.movRegMem(.rdi, .rsp, 0); // Future* in rdi

                // Call future.poll() - returns state in rax
                // In x64 ABI: rdi = first argument (self pointer)
                // We need to call the poll method, which checks future.state

                // Load state from future: future->state (offset 0)
                try self.assembler.movRegMem(.rax, .rdi, 0);

                // Compare state with Completed (state == 2)
                try self.assembler.movRegImm64(.rcx, 2);
                try self.assembler.cmpRegReg(.rax, .rcx);

                // If completed, jump to get result
                const je_completed = self.assembler.getPosition();
                try self.assembler.jeRel32(0);

                // State is Pending - yield to runtime
                // In full implementation:
                // - Save current stack frame
                // - Return control to executor
                // - Executor schedules other tasks
                // - When woken, executor resumes here

                // For now, spin-wait (in production this would yield)
                try self.assembler.movRegImm64(.rcx, 1000); // Small delay
                const spin_loop = self.assembler.getPosition();
                try self.assembler.movRegImm64(.rdx, 1);
                try self.assembler.subRegReg(.rcx, .rdx);
                try self.assembler.testRegReg(.rcx, .rcx);
                const jnz_spin = self.assembler.getPosition();
                try self.assembler.jnzRel32(0);

                // Patch spin loop
                const spin_offset = @as(i32, @intCast(spin_loop)) - @as(i32, @intCast(jnz_spin + 6));
                try self.assembler.patchJnzRel32(jnz_spin, spin_offset);

                // Jump back to poll
                const jmp_poll = self.assembler.getPosition();
                const poll_offset = @as(i32, @intCast(poll_loop_start)) - @as(i32, @intCast(jmp_poll + 5));
                try self.assembler.jmpRel32(poll_offset);

                // Completed: Get result
                const completed_label = self.assembler.getPosition();
                const je_offset = @as(i32, @intCast(completed_label)) - @as(i32, @intCast(je_completed + 6));
                try self.assembler.patchJeRel32(je_completed, je_offset);

                // Load result from future: future->result (offset 8, assuming state is u64)
                try self.assembler.movRegMem(.rax, .rdi, 8);

                // Clean up: pop future pointer from stack
                try self.assembler.movRegImm64(.rdx, 8);
                try self.assembler.addRegReg(.rsp, .rdx);

                // Result is now in rax
            },

            .ComptimeExpr => |comptime_expr| {
                // Comptime expression: evaluated at compile time
                // The inner expression should have been evaluated by the comptime executor
                // during semantic analysis. For codegen, we just evaluate the inner expression.
                // In a full implementation, this would look up the precomputed value.
                try self.generateExpr(comptime_expr.expression);
            },

            .ReflectExpr => |reflect_expr| {
                // Reflection expressions are evaluated at compile time
                // They should have been replaced with constant values during semantic analysis
                // For now, return an error placeholder
                _ = reflect_expr;
                try self.assembler.movRegImm64(.rax, 0); // Placeholder
            },

            .StringLiteral => |str_lit| {
                // Register the string literal and get its offset in data section
                const data_offset = try self.registerStringLiteral(str_lit.value);

                // Use LEA with RIP-relative addressing to load the string address
                // lea rax, [rip + displacement]
                // The displacement will be calculated as:
                //   data_section_start - (current_rip + instruction_length)
                // We'll patch this later when we know the final code size

                // Emit LEA with placeholder displacement (0 for now)
                const code_pos = try self.assembler.leaRipRel(.rax, 0);

                // Record this fixup so we can patch it later
                try self.string_fixups.append(self.allocator, .{
                    .code_pos = code_pos,
                    .data_offset = data_offset,
                });
            },

            .MacroExpr => {
                // Macro expressions should have been expanded before codegen
                return error.UnexpandedMacro;
            },

            .AssignmentExpr => |assign| {
                // x = value
                // Evaluate the value expression (result in rax)
                try self.generateExpr(assign.value);

                // Store to target (must be an Identifier for now)
                if (assign.target.* != .Identifier) {
                    std.debug.print("Assignment target must be an identifier\n", .{});
                    return error.UnsupportedFeature;
                }

                const target_name = assign.target.Identifier.name;
                if (self.locals.get(target_name)) |local_info| {
                    // Store rax to stack location
                    const stack_offset: i32 = -@as(i32, @intCast((local_info.offset + 1) * 8));
                    try self.assembler.movMemReg(.rbp, stack_offset, .rax);
                } else {
                    std.debug.print("Undefined variable in assignment: {s}\n", .{target_name});
                    return error.UndefinedVariable;
                }
            },

            .ArrayLiteral => {
                // Array literals should only appear in let declarations
                // where they are handled specially. If we encounter one here,
                // it's likely being used in an unsupported context.
                std.debug.print("Array literals are only supported in let declarations\n", .{});
                return error.UnsupportedFeature;
            },

            .StructLiteral => {
                // Struct literals should only appear in let declarations
                // where they are handled specially (similar to arrays)
                std.debug.print("Struct literals are only supported in let declarations\n", .{});
                return error.UnsupportedFeature;
            },

            .IndexExpr => |index| {
                // array[index]
                // Evaluate array expression (get pointer in rax)
                try self.generateExpr(index.array);
                try self.assembler.pushReg(.rax); // Save array pointer

                // Evaluate index expression
                try self.generateExpr(index.index);
                // Index is now in rax

                // Pop array pointer into rcx
                try self.assembler.popReg(.rcx);

                // Calculate offset: index * 8
                try self.assembler.imulRegImm32(.rax, 8);

                // Subtract from base pointer (stack grows down)
                // rcx - rax gives us the address of element at index
                try self.assembler.subRegReg(.rcx, .rax);

                // Load value from [rcx]
                try self.assembler.movRegMem(.rax, .rcx, 0);
            },

            .MemberExpr => |member| {
                // Can be: struct.field or Enum.Variant
                if (member.object.* != .Identifier) {
                    std.debug.print("Member access only supported on identifiers for now\n", .{});
                    return error.UnsupportedFeature;
                }

                const type_or_var_name = member.object.Identifier.name;

                // Check if this is an enum value (Enum.Variant)
                if (self.enum_layouts.get(type_or_var_name)) |enum_layout| {
                    // Find variant index
                    var variant_index: ?usize = null;
                    for (enum_layout.variants, 0..) |variant_info, i| {
                        if (std.mem.eql(u8, variant_info.name, member.member)) {
                            variant_index = i;
                            break;
                        }
                    }

                    if (variant_index == null) {
                        std.debug.print("Variant {s} not found in enum {s}\n", .{member.member, type_or_var_name});
                        return error.UnsupportedFeature;
                    }

                    // Load the variant index as the enum value
                    try self.assembler.movRegImm64(.rax, @intCast(variant_index.?));
                    return;
                }

                // Otherwise, it's struct field access
                const local_info = self.locals.get(type_or_var_name) orelse {
                    std.debug.print("Undefined variable in member access: {s}\n", .{type_or_var_name});
                    return error.UndefinedVariable;
                };

                // Look up struct layout from type
                const struct_layout = self.struct_layouts.get(local_info.type_name) orelse {
                    std.debug.print("Type {s} is not a struct\n", .{local_info.type_name});
                    return error.UnsupportedFeature;
                };

                // Find field index in struct layout
                var field_index: ?usize = null;
                for (struct_layout.fields, 0..) |field, i| {
                    if (std.mem.eql(u8, field.name, member.member)) {
                        field_index = i;
                        break;
                    }
                }

                if (field_index == null) {
                    std.debug.print("Field {s} not found in struct {s}\n", .{member.member, local_info.type_name});
                    return error.UnsupportedFeature;
                }

                // Calculate address of field on stack
                // Struct base is at offset, field i is at offset + i
                const field_stack_offset: i32 = -@as(i32, @intCast((local_info.offset + field_index.? + 1) * 8));

                // Load field value directly from stack
                try self.assembler.movRegMem(.rax, .rbp, field_stack_offset);
            },

            else => |expr_tag| {
                std.debug.print("Unsupported expression type in native codegen: {s}\n", .{@tagName(expr_tag)});
                return error.UnsupportedFeature;
            },
        }
    }
};
