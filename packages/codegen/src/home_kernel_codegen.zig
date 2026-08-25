// Home Kernel Code Generator
// Compiles Home language kernel code to native x86-64 assembly
// with FFI calls to Zig stdlib modules

const std = @import("std");
const ast = @import("ast");
const parser_mod = @import("parser");
const Parser = parser_mod.Parser;
const SymbolTable = parser_mod.SymbolTable;
const ModuleResolver = parser_mod.ModuleResolver;
const Symbol = parser_mod.Symbol;
const kernel_codegen = @import("kernel_codegen.zig");

/// String literal entry for .rodata section
const StringLiteral = struct {
    label: usize,
    content: []const u8,
};

/// A module-level mutable binding, lowered to a symbol in .bss or .data.
/// Kernel subsystems keep their state in these — page bitmaps, counters,
/// descriptor tables — so nothing in kernel/src/ compiles without them.
const GlobalVar = struct {
    name: []const u8,
    /// The type exactly as written, so field and element access can resolve
    /// against it later.
    type_name: []const u8,
    /// Total size in bytes.
    size: usize,
    /// Element size for an array; equals `size` for a scalar.
    elem_size: usize,
    is_array: bool,
    /// Initial value for a scalar with a compile-time constant initializer.
    /// null means zero-initialized, which goes in .bss.
    init_value: ?i64,
};

/// One field of a laid-out struct.
const FieldInfo = struct {
    name: []const u8,
    type_name: []const u8,
    offset: usize,
    size: usize,
};

/// A struct type laid out in memory. Fields are placed in declaration order,
/// each aligned to its own size (capped at 8), which matches the C ABI for
/// the scalar and array fields kernel structs are built from.
const StructInfo = struct {
    name: []const u8,
    size: usize,
    alignment: usize,
    fields: []FieldInfo,
};

/// Size in bytes of a primitive type name, or null. Deliberately narrow:
/// guessing a size for an unrecognized type would silently produce a symbol
/// of the wrong length. Struct and array types are resolved by the codegen's
/// own sizeOf, which has the struct table.
fn sizeOfPrimitive(type_name: []const u8) ?usize {
    if (std.mem.eql(u8, type_name, "u8") or std.mem.eql(u8, type_name, "i8") or
        std.mem.eql(u8, type_name, "bool")) return 1;
    if (std.mem.eql(u8, type_name, "u16") or std.mem.eql(u8, type_name, "i16")) return 2;
    if (std.mem.eql(u8, type_name, "u32") or std.mem.eql(u8, type_name, "i32")) return 4;
    if (std.mem.eql(u8, type_name, "u64") or std.mem.eql(u8, type_name, "i64") or
        std.mem.eql(u8, type_name, "usize") or std.mem.eql(u8, type_name, "isize") or
        std.mem.eql(u8, type_name, "int") or std.mem.eql(u8, type_name, "uint")) return 8;
    // Pointers are word-sized whatever they point at.
    if (type_name.len > 0 and (type_name[0] == '*' or type_name[0] == '&')) return 8;
    return null;
}

/// Parse `[N]T` into an element count and the element's type name. The
/// element's *size* is resolved separately, because it may be a struct.
fn parseArrayType(type_name: []const u8) ?struct { count: usize, elem_type: []const u8 } {
    if (type_name.len < 3 or type_name[0] != '[') return null;
    const close = std.mem.indexOfScalar(u8, type_name, ']') orelse return null;
    const count_str = std.mem.trim(u8, type_name[1..close], " ");
    const count = std.fmt.parseInt(usize, count_str, 0) catch return null;
    const elem_name = std.mem.trim(u8, type_name[close + 1 ..], " ");
    if (elem_name.len == 0) return null;
    return .{ .count = count, .elem_type = elem_name };
}

/// True if the type is a pointer. Indexing one strides by the pointee.
fn isPointerType(type_name: []const u8) bool {
    return type_name.len > 1 and (type_name[0] == '*' or type_name[0] == '&');
}

/// The type a pointer or array refers to.
fn pointeeType(type_name: []const u8) ?[]const u8 {
    if (isPointerType(type_name)) {
        var rest = type_name[1..];
        // `&mut T` and `*const T` both point at T.
        if (std.mem.startsWith(u8, rest, "mut ")) rest = rest[4..];
        if (std.mem.startsWith(u8, rest, "const ")) rest = rest[6..];
        const trimmed = std.mem.trim(u8, rest, " ");
        return if (trimmed.len == 0) null else trimmed;
    }
    if (parseArrayType(type_name)) |arr| return arr.elem_type;
    return null;
}

/// The mov suffix and destination register for a load of the given width.
fn loadFor(size: usize) ?struct { insn: []const u8, reg: []const u8 } {
    return switch (size) {
        1 => .{ .insn = "movzbq", .reg = "rax" },
        2 => .{ .insn = "movzwq", .reg = "rax" },
        // A 32-bit mov into %eax zero-extends into %rax on x86-64.
        4 => .{ .insn = "movl", .reg = "eax" },
        8 => .{ .insn = "movq", .reg = "rax" },
        else => null,
    };
}

/// The mov suffix and source register for a store of the given width.
fn storeFor(size: usize) ?struct { insn: []const u8, reg: []const u8 } {
    return switch (size) {
        1 => .{ .insn = "movb", .reg = "al" },
        2 => .{ .insn = "movw", .reg = "ax" },
        4 => .{ .insn = "movl", .reg = "eax" },
        8 => .{ .insn = "movq", .reg = "rax" },
        else => null,
    };
}

/// Kernel code generator with Home language support
pub const HomeKernelCodegen = struct {
    allocator: std.mem.Allocator,
    /// Symbol table from parser (contains imported modules)
    symbol_table: *SymbolTable,
    /// Module resolver for finding imports
    module_resolver: *ModuleResolver,
    /// Output assembly code
    output: std.ArrayList(u8),
    /// Kernel codegen options
    kernel_opts: kernel_codegen.KernelCodegenOptions,
    /// Local variable tracking: name -> stack offset (in bytes from %rbp)
    locals: std.StringHashMap(i32),
    /// Current stack offset for allocating new variables
    stack_offset: i32,
    /// String literals to emit in .rodata section: (label_num, content)
    string_literals: std.ArrayList(StringLiteral),
    /// Monotonic label counter. Labels were previously derived from AST node
    /// addresses, which made output non-deterministic across runs — the same
    /// source produced a different .s file every build, so nothing downstream
    /// could be cached or byte-compared.
    next_label: usize,
    /// Name of the function being generated, for its epilogue label.
    current_fn: []const u8,
    /// Innermost loop's labels, for break/continue. Empty when not in a loop.
    loop_break: []const u8,
    loop_continue: []const u8,
    /// Every function declared in this program. An intrinsic name that the
    /// program also defines resolves to the program's definition, so adding
    /// intrinsics can never silently redirect an existing call.
    declared_fns: std.StringHashMap(void),
    /// Module-level integer constants, folded at compile time and substituted
    /// at each use. A kernel's register addresses and bit masks live here;
    /// they must not become stack slots, and before this existed a top-level
    /// `const` emitted stores to %rbp outside any function at all.
    globals: std.StringHashMap(i64),
    /// True while generating statements outside any function body.
    at_top_level: bool,
    /// Module-level mutable bindings, emitted as .bss/.data symbols.
    global_vars: std.StringHashMap(GlobalVar),
    /// Declaration order, so emitted symbols follow source order.
    global_order: std.ArrayList([]const u8),
    /// Every name that appears as an assignment target anywhere in the
    /// program. A module-level binding that is assigned to is storage, not a
    /// constant, however it was declared — this tree uses plain `let` for
    /// mutable subsystem state throughout.
    assigned_names: std.StringHashMap(void),
    /// The type exactly as written for each local, so field and element
    /// access can resolve against it.
    local_types: std.StringHashMap([]const u8),
    /// Laid-out struct types, by name.
    structs: std.StringHashMap(StructInfo),

    pub fn init(
        allocator: std.mem.Allocator,
        symbol_table: *SymbolTable,
        module_resolver: *ModuleResolver,
    ) HomeKernelCodegen {
        var result: HomeKernelCodegen = undefined;
        result.allocator = allocator;
        result.symbol_table = symbol_table;
        result.module_resolver = module_resolver;
        result.output = .{ .items = &[_]u8{}, .capacity = 0 };
        result.kernel_opts = kernel_codegen.KernelCodegenOptions{};
        result.locals = std.StringHashMap(i32).init(allocator);
        result.stack_offset = -8; // Start at -8 from %rbp (first local variable)
        result.string_literals = .{ .items = &[_]StringLiteral{}, .capacity = 0 };
        result.next_label = 0;
        result.current_fn = "";
        result.loop_break = "";
        result.loop_continue = "";
        result.declared_fns = std.StringHashMap(void).init(allocator);
        result.globals = std.StringHashMap(i64).init(allocator);
        result.at_top_level = true;
        result.global_vars = std.StringHashMap(GlobalVar).init(allocator);
        result.global_order = .{ .items = &[_][]const u8{}, .capacity = 0 };
        result.assigned_names = std.StringHashMap(void).init(allocator);
        result.local_types = std.StringHashMap([]const u8).init(allocator);
        result.structs = std.StringHashMap(StructInfo).init(allocator);
        return result;
    }

    pub fn deinit(self: *HomeKernelCodegen) void {
        self.output.deinit(self.allocator);
        self.locals.deinit();
        self.declared_fns.deinit();
        self.globals.deinit();
        self.global_vars.deinit();
        self.global_order.deinit(self.allocator);
        self.assigned_names.deinit();
        self.local_types.deinit();
        var struct_it = self.structs.valueIterator();
        while (struct_it.next()) |info| self.allocator.free(info.fields);
        self.structs.deinit();
        self.string_literals.deinit(self.allocator);
    }

    /// Helper to write string to output
    fn writeAll(self: *HomeKernelCodegen, bytes: []const u8) !void {
        try self.output.appendSlice(self.allocator, bytes);
    }

    /// Walk statements recording every name assigned to, so module-level
    /// bindings can be classified as constant or storage before any code is
    /// generated for them.
    fn collectAssignedNames(self: *HomeKernelCodegen, statements: []const ast.Stmt) !void {
        for (statements) |stmt| {
            switch (stmt) {
                .ExprStmt => |expr| try self.collectAssignedInExpr(expr),
                .LetDecl => |d| if (d.value) |v| try self.collectAssignedInExpr(v),
                .ReturnStmt => |r| if (r.value) |v| try self.collectAssignedInExpr(v),
                .IfStmt => |i| {
                    try self.collectAssignedInExpr(i.condition);
                    try self.collectAssignedNames(i.then_block.statements);
                    if (i.else_block) |eb| try self.collectAssignedNames(eb.statements);
                },
                .WhileStmt => |w| {
                    try self.collectAssignedInExpr(w.condition);
                    try self.collectAssignedNames(w.body.statements);
                },
                .BlockStmt => |b| try self.collectAssignedNames(b.statements),
                else => {},
            }
        }
    }

    fn collectAssignedInExpr(self: *HomeKernelCodegen, expr: *const ast.Expr) anyerror!void {
        switch (expr.*) {
            .AssignmentExpr => |a| {
                var target = a.target;
                // Reach through index and member access to the base name:
                // `buf[i] = x` writes to `buf`.
                while (true) {
                    switch (target.*) {
                        .IndexExpr => |idx| target = idx.array,
                        .MemberExpr => |m| target = m.object,
                        else => break,
                    }
                }
                if (target.* == .Identifier) {
                    try self.assigned_names.put(target.Identifier.name, {});
                }
                try self.collectAssignedInExpr(a.value);
            },
            .BinaryExpr => |b| {
                try self.collectAssignedInExpr(b.left);
                try self.collectAssignedInExpr(b.right);
            },
            .UnaryExpr => |u| try self.collectAssignedInExpr(u.operand),
            .CallExpr => |c| for (c.args) |arg| try self.collectAssignedInExpr(arg),
            .IndexExpr => |i| {
                try self.collectAssignedInExpr(i.array);
                try self.collectAssignedInExpr(i.index);
            },
            else => {},
        }
    }

    // ---- Type resolution -------------------------------------------------
    //
    // The backend has no type inference. What it has is the type each binding
    // was *declared* with, which is enough to resolve field offsets and array
    // strides — and refusing anything it cannot resolve is what keeps it from
    // guessing a stride and silently reading the wrong memory.

    /// Size of a type as written: primitive, struct, array, or pointer.
    fn sizeOf(self: *HomeKernelCodegen, type_name: []const u8) ?usize {
        if (sizeOfPrimitive(type_name)) |n| return n;
        if (isPointerType(type_name)) return 8;
        if (parseArrayType(type_name)) |arr| {
            const elem = self.sizeOf(arr.elem_type) orelse return null;
            return arr.count * elem;
        }
        if (self.structs.get(type_name)) |info| return info.size;
        return null;
    }

    /// Alignment of a type: its own size for scalars, capped at 8.
    fn alignOf(self: *HomeKernelCodegen, type_name: []const u8) usize {
        if (self.structs.get(type_name)) |info| return info.alignment;
        if (parseArrayType(type_name)) |arr| return self.alignOf(arr.elem_type);
        const size = self.sizeOf(type_name) orelse 8;
        return @min(size, @as(usize, 8));
    }

    /// Lay out every struct declared in the program. Runs to a fixed point so
    /// a struct may refer to one declared later in the file; a struct that
    /// still cannot be laid out after that is left out of the table, and any
    /// use of it is refused rather than assigned a made-up size.
    fn layoutStructs(self: *HomeKernelCodegen, program: *const ast.Program) !void {
        var progress = true;
        while (progress) {
            progress = false;
            for (program.statements) |stmt| {
                if (stmt != .StructDecl) continue;
                const decl = stmt.StructDecl;
                if (self.structs.contains(decl.name)) continue;

                // Every field must have a known size before this struct does.
                var resolvable = true;
                for (decl.fields) |f| {
                    if (self.sizeOf(f.type_name) == null) {
                        resolvable = false;
                        break;
                    }
                }
                if (!resolvable) continue;

                var fields = try self.allocator.alloc(FieldInfo, decl.fields.len);
                var offset: usize = 0;
                var max_align: usize = 1;
                for (decl.fields, 0..) |f, i| {
                    const fsize = self.sizeOf(f.type_name).?;
                    // `packed` means exactly what it says: no padding.
                    const falign = if (decl.layout == .Packed) 1 else self.alignOf(f.type_name);
                    max_align = @max(max_align, falign);
                    offset = (offset + falign - 1) / falign * falign;
                    fields[i] = .{
                        .name = f.name,
                        .type_name = f.type_name,
                        .offset = offset,
                        .size = fsize,
                    };
                    offset += fsize;
                }
                // Tail padding, so an array of this struct strides correctly.
                const total = (offset + max_align - 1) / max_align * max_align;
                try self.structs.put(decl.name, .{
                    .name = decl.name,
                    .size = total,
                    .alignment = max_align,
                    .fields = fields,
                });
                progress = true;
            }
        }
    }

    /// True for types whose value is their address: arrays and structs.
    fn isStorageType(self: *HomeKernelCodegen, type_name: []const u8) bool {
        return parseArrayType(type_name) != null or self.structs.contains(type_name);
    }

    fn findField(self: *HomeKernelCodegen, type_name: []const u8, member: []const u8) ?FieldInfo {
        const info = self.structs.get(type_name) orelse return null;
        for (info.fields) |f| {
            if (std.mem.eql(u8, f.name, member)) return f;
        }
        return null;
    }

    /// The declared type of an lvalue expression, or null if unknown.
    fn typeOfLValue(self: *HomeKernelCodegen, expr: *const ast.Expr) ?[]const u8 {
        switch (expr.*) {
            .Identifier => |id| {
                if (self.local_types.get(id.name)) |t| return t;
                if (self.global_vars.get(id.name)) |g| return g.type_name;
                return null;
            },
            .IndexExpr => |idx| {
                const base = self.typeOfLValue(idx.array) orelse return null;
                return pointeeType(base);
            },
            .MemberExpr => |m| {
                const base = self.typeOfLValue(m.object) orelse return null;
                const f = self.findField(base, m.member) orelse return null;
                return f.type_name;
            },
            else => return null,
        }
    }

    /// Emit the address of an lvalue into %rax, returning its declared type.
    /// Returns null — having already emitted an ERROR marker — when the
    /// expression is not an addressable form the backend understands.
    fn emitAddress(self: *HomeKernelCodegen, expr: *const ast.Expr) anyerror!?[]const u8 {
        switch (expr.*) {
            .Identifier => |id| {
                if (self.locals.get(id.name)) |offset| {
                    try self.print("    leaq {d}(%rbp), %rax\n", .{offset});
                    return self.local_types.get(id.name) orelse "";
                }
                if (self.global_vars.get(id.name)) |g| {
                    try self.print("    leaq {s}(%rip), %rax\n", .{g.name});
                    return g.type_name;
                }
                try self.print("    # ERROR: cannot take the address of {s}\n", .{id.name});
                return null;
            },
            .IndexExpr => |idx| {
                const base_type = self.typeOfLValue(idx.array) orelse {
                    try self.writeAll("    # ERROR: cannot index: the base has no known type\n");
                    return null;
                };
                const elem_type = pointeeType(base_type) orelse {
                    try self.print("    # ERROR: cannot index a value of type {s}\n", .{base_type});
                    return null;
                };
                const elem_size = self.sizeOf(elem_type) orelse {
                    try self.print("    # ERROR: cannot index: element type {s} has unknown size\n", .{elem_type});
                    return null;
                };

                // Base address first, stashed, then the index — so the index
                // expression cannot clobber the base.
                if (isPointerType(base_type)) {
                    // A pointer's *value* is the base address.
                    try self.generateExpr(idx.array);
                } else {
                    _ = try self.emitAddress(idx.array) orelse return null;
                }
                try self.writeAll("    pushq %rax\n");
                try self.generateExpr(idx.index);
                if (elem_size > 1) {
                    try self.print("    imulq ${d}, %rax\n", .{elem_size});
                }
                try self.writeAll("    popq %rcx\n");
                try self.writeAll("    addq %rcx, %rax\n");
                return elem_type;
            },
            .MemberExpr => |m| {
                const base_type = self.typeOfLValue(m.object) orelse {
                    try self.print("    # ERROR: cannot resolve .{s}: the base has no known type\n", .{m.member});
                    return null;
                };
                // Through a pointer, `p.f` means `(*p).f`.
                var owner = base_type;
                var through_pointer = false;
                if (isPointerType(base_type)) {
                    owner = pointeeType(base_type) orelse base_type;
                    through_pointer = true;
                }
                const field = self.findField(owner, m.member) orelse {
                    try self.print("    # ERROR: type {s} has no field {s}\n", .{ owner, m.member });
                    return null;
                };
                if (through_pointer) {
                    try self.generateExpr(m.object);
                } else {
                    _ = try self.emitAddress(m.object) orelse return null;
                }
                if (field.offset > 0) {
                    try self.print("    addq ${d}, %rax\n", .{field.offset});
                }
                return field.type_name;
            },
            .UnaryExpr => |unary| {
                // `*p` as an lvalue: the address is p's value.
                if (unary.op == .Deref) {
                    const t = self.typeOfLValue(unary.operand);
                    try self.generateExpr(unary.operand);
                    if (t) |base_type| {
                        if (pointeeType(base_type)) |pt| return pt;
                    }
                    return "";
                }
                try self.writeAll("    # ERROR: not an addressable expression\n");
                return null;
            },
            else => {
                try self.writeAll("    # ERROR: not an addressable expression\n");
                return null;
            },
        }
    }

    /// Load the value at the address in %rax, given its declared type.
    /// An array or struct loads as its own address: it is storage, not a
    /// value that fits in a register.
    fn emitLoadFromAddress(self: *HomeKernelCodegen, type_name: []const u8) !void {
        if (parseArrayType(type_name) != null or self.structs.contains(type_name)) return;
        const size = self.sizeOf(type_name) orelse 8;
        const ld = loadFor(size) orelse {
            try self.print("    # ERROR: cannot load a value of type {s} ({d} bytes)\n", .{ type_name, size });
            try self.writeAll("    movq $0, %rax\n");
            return;
        };
        try self.writeAll("    movq %rax, %rdx\n");
        if (size < 8) try self.writeAll("    xorq %rax, %rax\n");
        try self.print("    {s} (%rdx), %{s}\n", .{ ld.insn, ld.reg });
    }

    /// Evaluate `value` and store it at the address in %rax.
    fn emitStoreToAddress(
        self: *HomeKernelCodegen,
        type_name: []const u8,
        value: *const ast.Expr,
    ) !void {
        const size = self.sizeOf(type_name) orelse 8;
        const st = storeFor(size) orelse {
            try self.print("    # ERROR: cannot store a value of type {s} ({d} bytes)\n", .{ type_name, size });
            return;
        };
        // Address first, stashed, then the value — so the value expression
        // cannot clobber the address.
        try self.writeAll("    pushq %rax\n");
        try self.generateExpr(value);
        try self.writeAll("    popq %rdx\n");
        try self.print("    {s} %{s}, (%rdx)\n", .{ st.insn, st.reg });
    }

    /// Record a module-level binding as storage. Returns false when its size
    /// cannot be determined, which is a refusal rather than a guess: emitting
    /// a symbol of the wrong length would corrupt whatever follows it.
    fn declareGlobalVar(self: *HomeKernelCodegen, decl: *const ast.LetDecl) !bool {
        const type_name = decl.type_name orelse return false;

        if (parseArrayType(type_name)) |arr| {
            const elem = self.sizeOf(arr.elem_type) orelse return false;
            try self.global_vars.put(decl.name, .{
                .name = decl.name,
                .type_name = type_name,
                .size = arr.count * elem,
                .elem_size = elem,
                .is_array = true,
                .init_value = null,
            });
            try self.global_order.append(self.allocator, decl.name);
            return true;
        }

        // A struct-typed global is storage too, laid out by its own size.
        if (self.structs.get(type_name)) |info| {
            try self.global_vars.put(decl.name, .{
                .name = decl.name,
                .type_name = type_name,
                .size = info.size,
                .elem_size = info.alignment,
                .is_array = true, // storage: its value is its address
                .init_value = null,
            });
            try self.global_order.append(self.allocator, decl.name);
            return true;
        }

        const size = self.sizeOf(type_name) orelse return false;
        // `= undefined` and `= 0` are both zero-initialized storage; a nonzero
        // constant initializer goes in .data.
        var init_value: ?i64 = null;
        if (decl.value) |value| {
            if (self.foldConst(value)) |folded| {
                if (folded != 0) init_value = folded;
            }
        }
        try self.global_vars.put(decl.name, .{
            .name = decl.name,
            .type_name = type_name,
            .size = size,
            .elem_size = size,
            .is_array = false,
            .init_value = init_value,
        });
        try self.global_order.append(self.allocator, decl.name);
        return true;
    }

    /// Emit .data and .bss for the module-level bindings collected above.
    fn emitGlobals(self: *HomeKernelCodegen) !void {
        var data_count: usize = 0;
        var bss_count: usize = 0;
        for (self.global_order.items) |name| {
            const g = self.global_vars.get(name) orelse continue;
            if (g.init_value != null) data_count += 1 else bss_count += 1;
        }

        if (data_count > 0) {
            try self.writeAll("\n.section .data\n");
            for (self.global_order.items) |name| {
                const g = self.global_vars.get(name) orelse continue;
                const v = g.init_value orelse continue;
                const directive = switch (g.size) {
                    1 => ".byte",
                    2 => ".short",
                    4 => ".long",
                    else => ".quad",
                };
                try self.print(".align {d}\n", .{g.size});
                try self.print("{s}:\n", .{g.name});
                try self.print("    {s} {d}\n", .{ directive, v });
            }
        }

        if (bss_count > 0) {
            try self.writeAll("\n.section .bss\n");
            for (self.global_order.items) |name| {
                const g = self.global_vars.get(name) orelse continue;
                if (g.init_value != null) continue;
                // Align to the element width, capped at 16 — enough for the
                // scalars and byte arrays a kernel declares, without forcing
                // page alignment on everything.
                const alignment = @min(g.elem_size, @as(usize, 16));
                try self.print(".align {d}\n", .{alignment});
                try self.print("{s}:\n", .{g.name});
                try self.print("    .zero {d}\n", .{g.size});
            }
        }
    }

    /// Fold an expression to an integer at compile time, or null if it is not
    /// a constant. Handles literals, references to already-folded module
    /// constants, and the arithmetic and bitwise operators over them — enough
    /// for the register addresses and bit masks a kernel declares.
    fn foldConst(self: *HomeKernelCodegen, expr: *const ast.Expr) ?i64 {
        switch (expr.*) {
            // Literals are parsed as i128; anything outside i64 cannot become
            // a 64-bit immediate, so it is simply not a constant here.
            .IntegerLiteral => |lit| return std.math.cast(i64, lit.value),
            .BooleanLiteral => |lit| return if (lit.value) @as(i64, 1) else @as(i64, 0),
            .Identifier => |id| return self.globals.get(id.name),
            .UnaryExpr => |unary| {
                const v = self.foldConst(unary.operand) orelse return null;
                return switch (unary.op) {
                    .Neg => -v,
                    .BitNot => ~v,
                    .Not => if (v == 0) @as(i64, 1) else @as(i64, 0),
                    else => null,
                };
            },
            .BinaryExpr => |binary| {
                const l = self.foldConst(binary.left) orelse return null;
                const r = self.foldConst(binary.right) orelse return null;
                return switch (binary.op) {
                    .Add => l +% r,
                    .Sub => l -% r,
                    .Mul => l *% r,
                    .Div, .IntDiv => if (r == 0) null else @divTrunc(l, r),
                    .Mod => if (r == 0) null else @rem(l, r),
                    .BitAnd => l & r,
                    .BitOr => l | r,
                    .BitXor => l ^ r,
                    .LeftShift => if (r < 0 or r > 63) null else l << @intCast(r),
                    .RightShift => if (r < 0 or r > 63) null else l >> @intCast(r),
                    else => null,
                };
            },
            else => return null,
        }
    }

    /// Emit a kernel intrinsic, or return false if `name` is not one.
    ///
    /// Argument values are computed into %rax one at a time and parked in the
    /// register the instruction needs, right-to-left so the last computation
    /// does not clobber an earlier one. Intrinsics take simple operands in
    /// practice, but this ordering keeps a nested call correct.
    fn generateIntrinsic(
        self: *HomeKernelCodegen,
        name: []const u8,
        args: []const *const ast.Expr,
    ) !bool {
        const Kind = enum { none, out, in, plain, mmio_read, mmio_write };
        var kind: Kind = .none;
        var suffix: []const u8 = "";   // b / w / l / q
        var acc: []const u8 = "";      // al / ax / eax / rax
        var plain_insn: []const u8 = "";

        if (std.mem.eql(u8, name, "outb")) { kind = .out; suffix = "b"; acc = "al"; }
        else if (std.mem.eql(u8, name, "outw")) { kind = .out; suffix = "w"; acc = "ax"; }
        else if (std.mem.eql(u8, name, "outl")) { kind = .out; suffix = "l"; acc = "eax"; }
        else if (std.mem.eql(u8, name, "inb")) { kind = .in; suffix = "b"; acc = "al"; }
        else if (std.mem.eql(u8, name, "inw")) { kind = .in; suffix = "w"; acc = "ax"; }
        else if (std.mem.eql(u8, name, "inl")) { kind = .in; suffix = "l"; acc = "eax"; }
        else if (std.mem.eql(u8, name, "hlt")) { kind = .plain; plain_insn = "hlt"; }
        else if (std.mem.eql(u8, name, "cli")) { kind = .plain; plain_insn = "cli"; }
        else if (std.mem.eql(u8, name, "sti")) { kind = .plain; plain_insn = "sti"; }
        else if (std.mem.eql(u8, name, "nop")) { kind = .plain; plain_insn = "nop"; }
        else if (std.mem.eql(u8, name, "pause")) { kind = .plain; plain_insn = "pause"; }
        else if (std.mem.eql(u8, name, "mfence")) { kind = .plain; plain_insn = "mfence"; }
        else if (std.mem.eql(u8, name, "mmio_read8")) { kind = .mmio_read; suffix = "b"; acc = "al"; }
        else if (std.mem.eql(u8, name, "mmio_read16")) { kind = .mmio_read; suffix = "w"; acc = "ax"; }
        else if (std.mem.eql(u8, name, "mmio_read32")) { kind = .mmio_read; suffix = "l"; acc = "eax"; }
        else if (std.mem.eql(u8, name, "mmio_read64")) { kind = .mmio_read; suffix = "q"; acc = "rax"; }
        else if (std.mem.eql(u8, name, "mmio_write8")) { kind = .mmio_write; suffix = "b"; acc = "cl"; }
        else if (std.mem.eql(u8, name, "mmio_write16")) { kind = .mmio_write; suffix = "w"; acc = "cx"; }
        else if (std.mem.eql(u8, name, "mmio_write32")) { kind = .mmio_write; suffix = "l"; acc = "ecx"; }
        else if (std.mem.eql(u8, name, "mmio_write64")) { kind = .mmio_write; suffix = "q"; acc = "rcx"; }
        else return false;

        switch (kind) {
            .plain => {
                if (args.len != 0) {
                    try self.print("    # {s}() takes no arguments, {d} given\n", .{ name, args.len });
                    return false;
                }
                try self.print("    {s}\n", .{plain_insn});
            },
            .out => {
                // out<suffix> %acc, %dx  —  port in %dx, value in the accumulator.
                if (args.len != 2) {
                    try self.print("    # {s}(port, value) needs 2 arguments, {d} given\n", .{ name, args.len });
                    return false;
                }
                try self.generateExpr(args[1]);
                try self.writeAll("    pushq %rax\n");
                try self.generateExpr(args[0]);
                try self.writeAll("    movq %rax, %rdx\n");
                try self.writeAll("    popq %rax\n");
                try self.print("    out{s} %{s}, %dx\n", .{ suffix, acc });
            },
            .in => {
                if (args.len != 1) {
                    try self.print("    # {s}(port) needs 1 argument, {d} given\n", .{ name, args.len });
                    return false;
                }
                try self.generateExpr(args[0]);
                try self.writeAll("    movq %rax, %rdx\n");
                try self.writeAll("    xorq %rax, %rax\n");
                try self.print("    in{s} %dx, %{s}\n", .{ suffix, acc });
            },
            .mmio_read => {
                if (args.len != 1) {
                    try self.print("    # {s}(addr) needs 1 argument, {d} given\n", .{ name, args.len });
                    return false;
                }
                try self.generateExpr(args[0]);
                try self.writeAll("    movq %rax, %rdx\n");
                try self.writeAll("    xorq %rax, %rax\n");
                try self.print("    mov{s} (%rdx), %{s}\n", .{ suffix, acc });
            },
            .mmio_write => {
                if (args.len != 2) {
                    try self.print("    # {s}(addr, value) needs 2 arguments, {d} given\n", .{ name, args.len });
                    return false;
                }
                try self.generateExpr(args[1]);
                try self.writeAll("    pushq %rax\n");
                try self.generateExpr(args[0]);
                try self.writeAll("    movq %rax, %rdx\n");
                try self.writeAll("    popq %rcx\n");
                try self.print("    mov{s} %{s}, (%rdx)\n", .{ suffix, acc });
            },
            .none => unreachable,
        }
        return true;
    }

    /// Emit a comparison: %rax <op> %rcx, result 0 or 1 in %rax.
    fn emitCompare(self: *HomeKernelCodegen, setcc: []const u8) !void {
        try self.writeAll("    cmpq %rcx, %rax\n");
        try self.print("    {s} %al\n", .{setcc});
        try self.writeAll("    movzbq %al, %rax\n");
    }

    /// Allocate a fresh, deterministic label number.
    fn freshLabel(self: *HomeKernelCodegen) usize {
        self.next_label += 1;
        return self.next_label;
    }

    /// Assign a frame slot to every `let` reachable in a statement list,
    /// including nested blocks. An array local gets its full width; anything
    /// else gets one word. All declarations in a function share one flat
    /// frame, so shadowing in an inner scope reuses the outer slot — a known
    /// limitation recorded on the codegen ladder (home-lang/home-os#38)
    /// rather than a silent one.
    fn reserveLocals(self: *HomeKernelCodegen, statements: []const ast.Stmt) anyerror!void {
        for (statements) |stmt| {
            switch (stmt) {
                .LetDecl => |decl| {
                    if (self.locals.contains(decl.name)) continue;
                    var bytes: usize = 8;
                    if (decl.type_name) |tn| {
                        try self.local_types.put(decl.name, tn);
                        // An array or struct local needs its full width, not
                        // one word — it holds its elements, not a pointer.
                        if (self.isStorageType(tn)) {
                            bytes = self.sizeOf(tn) orelse 8;
                        }
                    }
                    // Keep every slot 8-byte aligned so word loads stay aligned.
                    const aligned = (bytes + 7) / 8 * 8;
                    self.stack_offset -= @intCast(aligned);
                    try self.locals.put(decl.name, self.stack_offset);
                },
                .IfStmt => |s2| {
                    try self.reserveLocals(s2.then_block.statements);
                    if (s2.else_block) |eb| try self.reserveLocals(eb.statements);
                },
                .WhileStmt => |s2| try self.reserveLocals(s2.body.statements),
                .BlockStmt => |s2| try self.reserveLocals(s2.statements),
                else => {},
            }
        }
    }

    /// Helper to format and write to output
    fn print(self: *HomeKernelCodegen, comptime fmt: []const u8, args: anytype) !void {
        const str = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(str);
        try self.output.appendSlice(self.allocator, str);
    }

    /// Generate kernel code from Home AST
    pub fn generate(self: *HomeKernelCodegen, program: *const ast.Program) ![]const u8 {

        // Emit assembly header
        // `.global` is emitted per function from its declaration. This header
        // used to hardcode `.global kernel_main`, which produced a duplicate
        // directive for the one function that needs it and no directive at
        // all for any other exported function.
        try self.writeAll(
            \\.section .text
            \\
            \\
        );

        // Lay out struct types first: sizing a global, an array stride, or a
        // field offset all depend on knowing them.
        try self.layoutStructs(program);

        // Collect declared function names before generating anything, so a
        // call to a function defined later in the file is still recognised
        // as a program function rather than an intrinsic.
        for (program.statements) |stmt| {
            if (stmt == .FnDecl) {
                try self.declared_fns.put(stmt.FnDecl.name, {});
                try self.collectAssignedNames(stmt.FnDecl.body.statements);
            }
        }

        // Generate code for each statement
        for (program.statements) |stmt| {
            try self.generateStmt(stmt);
        }

        try self.emitGlobals();

        // Emit .rodata section with string literals
        if (self.string_literals.items.len > 0) {
            try self.writeAll("\n.section .rodata\n");

            for (self.string_literals.items) |str_lit| {
                try self.print(".L_str_{d}:\n", .{str_lit.label});
                try self.print("    .asciz \"{s}\"\n", .{str_lit.content});
                // Byte-width loads do not exist yet, so reading a character
                // means a 64-bit load masked to its low byte. Seven bytes of
                // padding make that load in-bounds at every offset of the
                // string, including the last. Remove when the backend grows
                // sized loads (home-lang/home-os#38).
                try self.writeAll("    .zero 7\n");
            }
        }

        return self.output.items;
    }

    fn generateStmt(self: *HomeKernelCodegen, stmt: ast.Stmt) !void {
        switch (stmt) {
            .FnDecl => |func| {
                // Forward declarations (issue #17) bind the name only.
                if (func.is_forward_decl) return;

                // Respect the `export` keyword. The previous heuristic — any
                // name starting with "kernel_", plus "main" — both missed
                // genuinely exported functions and exported private helpers
                // that happened to be named kernel_something.
                const is_export = func.is_exported or
                    std.mem.eql(u8, func.name, "main") or
                    std.mem.eql(u8, func.name, "kernel_main");

                if (is_export) {
                    try self.print(".global {s}\n", .{func.name});
                }
                try self.print("{s}:\n", .{func.name});

                const noreturn_fn = if (func.return_type) |rt|
                    std.mem.eql(u8, rt, "never")
                else
                    false;

                // Each function gets a fresh frame. Previously `locals` and
                // `stack_offset` were never reset, so one function's variables
                // resolved inside the next one at meaningless offsets.
                self.locals.clearRetainingCapacity();
                self.local_types.clearRetainingCapacity();
                self.stack_offset = 0;
                self.current_fn = func.name;
                const was_top = self.at_top_level;
                self.at_top_level = false;
                defer self.at_top_level = was_top;

                // Lay the whole frame out before emitting anything. Locals
                // used to be created with `pushq`, which meant a local's
                // recorded offset was only correct if no expression had
                // pushed a temporary first — and expression codegen pushes
                // temporaries constantly. Fixed offsets from %rbp are correct
                // regardless of what %rsp is doing, and an array local needs
                // its full width reserved rather than one word.
                for (func.params) |param| {
                    self.stack_offset -= 8;
                    try self.locals.put(param.name, self.stack_offset);
                }
                try self.reserveLocals(func.body.statements);

                const frame_bytes: usize = @intCast(-self.stack_offset);
                // Keep %rsp 16-byte aligned at the call boundary.
                const frame_size: usize = (frame_bytes + 15) / 16 * 16;

                try self.writeAll("    pushq %rbp\n");
                try self.writeAll("    movq %rsp, %rbp\n");
                if (frame_size > 0) {
                    try self.print("    subq ${d}, %rsp\n", .{frame_size});
                }

                // Spill incoming arguments into their slots. Without this,
                // every parameter reference emitted a "# not in locals"
                // comment and read whatever happened to be in %rax.
                const arg_regs = [_][]const u8{ "rdi", "rsi", "rdx", "rcx", "r8", "r9" };
                for (func.params, 0..) |param, i| {
                    const slot = self.locals.get(param.name) orelse continue;
                    if (i < arg_regs.len) {
                        try self.print("    movq %{s}, {d}(%rbp)\n", .{ arg_regs[i], slot });
                    } else {
                        // Arguments 7+ arrive above the return address.
                        const caller_offset = 16 + (i - arg_regs.len) * 8;
                        try self.print("    movq {d}(%rbp), %rax\n", .{caller_offset});
                        try self.print("    movq %rax, {d}(%rbp)\n", .{slot});
                    }
                }

                for (func.body.statements) |body_stmt| {
                    try self.generateStmt(body_stmt);
                }

                // One epilogue per function, reached by `ret` jumping here.
                // Returns used to inline a full epilogue each, and a function
                // ending in `return` then got a second one appended.
                if (!noreturn_fn) {
                    try self.print(".L_epilogue_{s}:\n", .{func.name});
                    try self.writeAll("    movq %rbp, %rsp\n");
                    try self.writeAll("    popq %rbp\n");
                    try self.writeAll("    ret\n");
                }

                self.current_fn = "";
                try self.writeAll("\n");
            },
            .ExprStmt => |expr| {
                try self.generateExpr(expr);
            },
            .LetDecl => |decl| {
                // At module scope there is no frame to store into. An
                // immutable binding with a compile-time integer value becomes
                // a constant substituted at each use; anything else at this
                // scope is not representable yet and says so rather than
                // emitting stores against a nonexistent %rbp.
                if (self.at_top_level) {
                    // A binding with a compile-time integer value becomes a
                    // constant substituted at each use — but only if nothing
                    // in the program assigns to it. Mutability as declared is
                    // not a reliable signal here: this tree uses plain `let`
                    // for module state that is written to later.
                    if (!decl.is_mutable and !self.assigned_names.contains(decl.name)) {
                        if (decl.value) |value| {
                            if (self.foldConst(value)) |folded| {
                                try self.globals.put(decl.name, folded);
                                return;
                            }
                        }
                    }
                    // Otherwise it is storage: a symbol in .bss or .data.
                    if (try self.declareGlobalVar(decl)) return;
                    try self.print("# unsupported module-level binding: {s}{s}\n", .{
                        decl.name,
                        if (decl.type_name == null) " (no type annotation, so its size is unknown)" else "",
                    });
                    return;
                }
                // The slot was reserved by the prologue; store into it. The
                // old code used `pushq`, which recorded an offset that was
                // only right when no expression temporary had been pushed
                // first — and expression codegen pushes constantly.
                // An array local is storage, not a value: its slot holds the
                // elements themselves, so there is nothing to store into it.
                if (decl.type_name) |tn| {
                    if (self.isStorageType(tn)) return;
                }
                if (decl.value) |value| {
                    try self.generateExpr(value);
                    if (self.locals.get(decl.name)) |slot| {
                        try self.print("    movq %rax, {d}(%rbp)\n", .{slot});
                    } else {
                        try self.print("    # ERROR: no frame slot reserved for {s}\n", .{decl.name});
                    }
                }
            },
            .IfStmt => |if_stmt| {
                // Generate if statement
                try self.generateExpr(if_stmt.condition);

                // Test condition (result in %rax)
                try self.writeAll("    testq %rax, %rax\n");

                const label_num = self.freshLabel();
                try self.print("    jz .L_else_{d}\n", .{label_num});

                // Then block
                for (if_stmt.then_block.statements) |then_stmt| {
                    try self.generateStmt(then_stmt);
                }

                if (if_stmt.else_block) |else_block| {
                    try self.print("    jmp .L_endif_{d}\n", .{label_num});
                    try self.print(".L_else_{d}:\n", .{label_num});

                    for (else_block.statements) |else_stmt| {
                        try self.generateStmt(else_stmt);
                    }

                    try self.print(".L_endif_{d}:\n", .{label_num});
                } else {
                    try self.print(".L_else_{d}:\n", .{label_num});
                }
            },
            .WhileStmt => |while_stmt| {
                const label_num = self.freshLabel();

                const start = try std.fmt.allocPrint(self.allocator, ".L_while_start_{d}", .{label_num});
                defer self.allocator.free(start);
                const end = try std.fmt.allocPrint(self.allocator, ".L_while_end_{d}", .{label_num});
                defer self.allocator.free(end);

                try self.print("{s}:\n", .{start});
                try self.generateExpr(while_stmt.condition);
                try self.writeAll("    testq %rax, %rax\n");
                try self.print("    jz {s}\n", .{end});

                // break/continue inside the body target this loop; restore the
                // enclosing loop's labels afterwards so nesting works.
                const prev_break = self.loop_break;
                const prev_continue = self.loop_continue;
                self.loop_break = end;
                self.loop_continue = start;

                for (while_stmt.body.statements) |body_stmt| {
                    try self.generateStmt(body_stmt);
                }

                self.loop_break = prev_break;
                self.loop_continue = prev_continue;

                try self.print("    jmp {s}\n", .{start});
                try self.print("{s}:\n", .{end});
            },
            .ReturnStmt => |return_stmt| {
                // Value in %rax, then jump to the function's one epilogue.
                if (return_stmt.value) |value| {
                    try self.generateExpr(value);
                }
                if (self.current_fn.len > 0) {
                    try self.print("    jmp .L_epilogue_{s}\n", .{self.current_fn});
                } else {
                    try self.writeAll("    movq %rbp, %rsp\n");
                    try self.writeAll("    popq %rbp\n");
                    try self.writeAll("    ret\n");
                }
            },
            .BreakStmt => {
                if (self.loop_break.len > 0) {
                    try self.print("    jmp {s}\n", .{self.loop_break});
                }
            },
            .ContinueStmt => {
                if (self.loop_continue.len > 0) {
                    try self.print("    jmp {s}\n", .{self.loop_continue});
                }
            },
            .BlockStmt => |block| {
                for (block.statements) |inner| {
                    try self.generateStmt(inner);
                }
            },
            else => {
                // Unsupported statement type - skip for now
            },
        }
    }

    fn generateExpr(self: *HomeKernelCodegen, expr: *const ast.Expr) anyerror!void {
        switch (expr.*) {
            .IntegerLiteral => |lit| {
                // Literals are i128 in the AST. `movq $imm` takes a 32-bit
                // sign-extended immediate; anything wider needs movabsq, and
                // anything past 64 bits is not representable at all.
                if (std.math.cast(i64, lit.value)) |v| {
                    if (v >= -2147483648 and v <= 2147483647) {
                        try self.print("    movq ${d}, %rax\n", .{v});
                    } else {
                        try self.print("    movabsq ${d}, %rax\n", .{v});
                    }
                } else if (std.math.cast(u64, lit.value)) |uv| {
                    // Unsigned values above i64 max are still 64-bit patterns;
                    // reinterpret rather than refuse. u64 max is how a kernel
                    // spells an all-ones mask.
                    try self.print("    movabsq ${d}, %rax\n", .{@as(i64, @bitCast(uv))});
                } else {
                    try self.print("    # ERROR: integer literal {d} does not fit in 64 bits\n", .{lit.value});
                    try self.writeAll("    movq $0, %rax\n");
                }
            },
            .BooleanLiteral => |lit| {
                // Load boolean as integer (0 or 1) into %rax
                try self.print("    movq ${d}, %rax\n", .{if (lit.value) @as(i64, 1) else @as(i64, 0)});
            },
            .InlineAsm => |asm_node| {
                // Emit inline assembly instruction directly
                try self.print("    {s}\n", .{asm_node.instruction});
            },
            .StringLiteral => |lit| {
                // Intern by content: labels used to be the literal's pointer
                // address, so identical strings got separate .rodata copies
                // and every build produced different label numbers.
                var label_num: usize = 0;
                var found = false;
                for (self.string_literals.items) |existing| {
                    if (std.mem.eql(u8, existing.content, lit.value)) {
                        label_num = existing.label;
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    label_num = self.freshLabel();
                    try self.string_literals.append(self.allocator, .{
                        .label = label_num,
                        .content = lit.value,
                    });
                }
                try self.print("    leaq .L_str_{d}(%rip), %rax\n", .{label_num});
            },
            .CallExpr => |call| {
                // Check if this is a module member call (e.g., serial.init())
                if (call.callee.* == .MemberExpr) {
                    const member = call.callee.MemberExpr;

                    // Get module name from object
                    if (member.object.* == .Identifier) {
                        const module_name = member.object.Identifier.name;
                        const func_name = member.member;

                        // Look up the symbol in the symbol table
                        if (self.symbol_table.lookupMemberSymbol(module_name, func_name)) |symbol| {
                            // Generate FFI call to Zig function
                            try self.generateFFICall(symbol, call.args);
                        } else {
                            std.log.info("Unknown symbol: {s}.{s}", .{module_name, func_name});
                        }
                    }
                } else if (call.callee.* == .Identifier) {
                    // Direct function call
                    const func_name = call.callee.Identifier.name;

                    // Kernel intrinsics (MASTER_PLAN milestone A3): port I/O,
                    // control instructions, and volatile MMIO. These are the
                    // operations a kernel cannot express in portable source
                    // and that this project previously reached into the Home
                    // repo's asm.zig for. A program that declares a function
                    // of the same name wins — see declared_fns.
                    if (!self.declared_fns.contains(func_name)) {
                        if (try self.generateIntrinsic(func_name, call.args)) return;
                    }

                    // Check if it's a known symbol
                    if (self.symbol_table.lookupSymbol(func_name)) |symbol| {
                        try self.generateFFICall(symbol, call.args);
                    } else {
                        // Local function call
                        // Evaluate arguments (System V AMD64 ABI: rdi, rsi, rdx, rcx, r8, r9)
                        const arg_regs = [_][]const u8{ "rdi", "rsi", "rdx", "rcx", "r8", "r9" };

                        // To handle multiple arguments correctly, we need to save previous args
                        // Strategy: evaluate in reverse order and push to stack, then pop into registers
                        if (call.args.len > 0) {
                            // Evaluate all arguments and push them to stack in reverse order
                            var i: usize = call.args.len;
                            while (i > 0) {
                                i -= 1;
                                try self.generateExpr(call.args[i]);
                                try self.writeAll("    pushq %rax\n");
                            }

                            // Pop arguments into registers in correct order
                            for (0..call.args.len) |reg_idx| {
                                if (reg_idx < arg_regs.len) {
                                    try self.print("    popq %{s}\n", .{arg_regs[reg_idx]});
                                } else {
                                    // Arguments beyond 6 stay on stack for the call
                                    break;
                                }
                            }
                        }

                        // Call function
                        try self.print("    call {s}\n", .{func_name});
                    }
                }
            },
            .BinaryExpr => |binary| {
                // `&&` and `||` must short-circuit, so they cannot use the
                // evaluate-both-operands shape below.
                if (binary.op == .And or binary.op == .Or) {
                    const label_num = self.freshLabel();
                    try self.generateExpr(binary.left);
                    try self.writeAll("    testq %rax, %rax\n");
                    if (binary.op == .And) {
                        try self.print("    jz .L_logic_short_{d}\n", .{label_num});
                    } else {
                        try self.print("    jnz .L_logic_short_{d}\n", .{label_num});
                    }
                    try self.generateExpr(binary.right);
                    try self.writeAll("    testq %rax, %rax\n");
                    try self.writeAll("    setne %al\n");
                    try self.writeAll("    movzbq %al, %rax\n");
                    try self.print("    jmp .L_logic_end_{d}\n", .{label_num});
                    try self.print(".L_logic_short_{d}:\n", .{label_num});
                    // Short-circuited: the answer is the left operand's truth.
                    try self.print("    movq ${d}, %rax\n", .{if (binary.op == .And) @as(i64, 0) else @as(i64, 1)});
                    try self.print(".L_logic_end_{d}:\n", .{label_num});
                    return;
                }

                // Left in %rax, right in %rcx. Evaluate left first and stash
                // it, so operand order matches source order — the previous
                // code evaluated the right operand first, which is observable
                // as soon as either side has a side effect.
                try self.generateExpr(binary.left);
                try self.writeAll("    pushq %rax\n");
                try self.generateExpr(binary.right);
                try self.writeAll("    movq %rax, %rcx\n");
                try self.writeAll("    popq %rax\n");

                switch (binary.op) {
                    .Add, .CheckedAdd => try self.writeAll("    addq %rcx, %rax\n"),
                    .Sub, .CheckedSub => try self.writeAll("    subq %rcx, %rax\n"),
                    .Mul, .CheckedMul => try self.writeAll("    imulq %rcx, %rax\n"),
                    .Div, .IntDiv, .CheckedDiv => {
                        // cqto sign-extends %rax into %rdx:%rax for idivq.
                        try self.writeAll("    cqto\n");
                        try self.writeAll("    idivq %rcx\n");
                    },
                    .Mod => {
                        try self.writeAll("    cqto\n");
                        try self.writeAll("    idivq %rcx\n");
                        try self.writeAll("    movq %rdx, %rax\n");
                    },
                    .BitAnd => try self.writeAll("    andq %rcx, %rax\n"),
                    .BitOr => try self.writeAll("    orq %rcx, %rax\n"),
                    .BitXor => try self.writeAll("    xorq %rcx, %rax\n"),
                    // Shift counts must be in %cl.
                    .LeftShift => try self.writeAll("    shlq %cl, %rax\n"),
                    .RightShift => try self.writeAll("    sarq %cl, %rax\n"),
                    .Power => {
                        // Integer exponentiation by repeated multiplication;
                        // %rax = base, %rcx = exponent.
                        const lbl = self.freshLabel();
                        try self.writeAll("    movq %rax, %rsi\n");
                        try self.writeAll("    movq $1, %rax\n");
                        try self.print(".L_pow_start_{d}:\n", .{lbl});
                        try self.writeAll("    testq %rcx, %rcx\n");
                        try self.print("    jle .L_pow_end_{d}\n", .{lbl});
                        try self.writeAll("    imulq %rsi, %rax\n");
                        try self.writeAll("    decq %rcx\n");
                        try self.print("    jmp .L_pow_start_{d}\n", .{lbl});
                        try self.print(".L_pow_end_{d}:\n", .{lbl});
                    },
                    .Equal => try self.emitCompare("sete"),
                    .NotEqual => try self.emitCompare("setne"),
                    .Less => try self.emitCompare("setl"),
                    .LessEq => try self.emitCompare("setle"),
                    .Greater => try self.emitCompare("setg"),
                    .GreaterEq => try self.emitCompare("setge"),
                    else => {
                        try self.print("    # unsupported binary operator: {s}\n", .{@tagName(binary.op)});
                    },
                }
            },
            .IndexExpr, .MemberExpr => {
                // Address into %rax, then load the value it points at.
                const t = try self.emitAddress(expr) orelse {
                    try self.writeAll("    movq $0, %rax\n");
                    return;
                };
                try self.emitLoadFromAddress(t);
            },
            .UnaryExpr => |unary| {
                try self.generateExpr(unary.operand);
                switch (unary.op) {
                    .Neg => try self.writeAll("    negq %rax\n"),
                    .BitNot => try self.writeAll("    notq %rax\n"),
                    .Not => {
                        try self.writeAll("    testq %rax, %rax\n");
                        try self.writeAll("    sete %al\n");
                        try self.writeAll("    movzbq %al, %rax\n");
                    },
                    .Deref => try self.writeAll("    movq (%rax), %rax\n"),
                    else => {
                        try self.print("    # unsupported unary operator: {s}\n", .{@tagName(unary.op)});
                    },
                }
            },
            .AssignmentExpr => |assign| {
                switch (assign.target.*) {
                    .Identifier => |target| {
                        try self.generateExpr(assign.value);
                        // `_ = expr` evaluates for effect and drops the result.
                        if (std.mem.eql(u8, target.name, "_")) {
                            return;
                        }
                        if (self.locals.get(target.name)) |offset| {
                            try self.print("    movq %rax, {d}(%rbp)\n", .{offset});
                        } else if (self.global_vars.get(target.name)) |g| {
                            if (g.is_array) {
                                try self.print("    # ERROR: cannot assign to the array {s} as a whole\n", .{g.name});
                            } else if (storeFor(g.size)) |st| {
                                try self.print("    {s} %{s}, {s}(%rip)\n", .{ st.insn, st.reg, g.name });
                            } else {
                                try self.print("    # ERROR: cannot store {s} of size {d}\n", .{ g.name, g.size });
                            }
                        } else if (self.globals.contains(target.name)) {
                            try self.print("    # ERROR: {s} is a constant and cannot be assigned to\n", .{target.name});
                        } else {
                            try self.print("    # ERROR: assignment to undefined variable {s}\n", .{target.name});
                        }
                    },
                    else => {
                        // Index, field, and dereference targets all reduce to
                        // "compute an address, store through it".
                        const t = try self.emitAddress(assign.target) orelse return;
                        try self.emitStoreToAddress(t, assign.value);
                    },
                }
            },
            .Identifier => |id| {
                if (self.locals.get(id.name)) |offset| {
                    const t = self.local_types.get(id.name) orelse "";
                    if (t.len > 0 and self.isStorageType(t)) {
                        // An array or struct's value is its address, as in C.
                        try self.print("    leaq {d}(%rbp), %rax\n", .{offset});
                    } else {
                        try self.print("    movq {d}(%rbp), %rax\n", .{offset});
                    }
                } else if (self.globals.get(id.name)) |value| {
                    try self.print("    movq ${d}, %rax\n", .{value});
                } else if (self.global_vars.get(id.name)) |g| {
                    if (g.is_array) {
                        try self.print("    leaq {s}(%rip), %rax\n", .{g.name});
                    } else if (loadFor(g.size)) |ld| {
                        if (g.size < 8) try self.writeAll("    xorq %rax, %rax\n");
                        try self.print("    {s} {s}(%rip), %{s}\n", .{ ld.insn, g.name, ld.reg });
                    } else {
                        try self.print("    # ERROR: cannot load {s} of size {d}\n", .{ g.name, g.size });
                        try self.writeAll("    movq $0, %rax\n");
                    }
                } else {
                    // Emitting a comment and carrying on leaves %rax holding
                    // whatever the last expression left there, which reads as
                    // a working build that computes nonsense. Say so loudly
                    // in the output instead.
                    try self.print("    # ERROR: undefined variable {s}\n", .{id.name});
                    try self.writeAll("    movq $0, %rax\n");
                }
            },
            else => {
                // Unsupported expression - skip
            },
        }
    }

    /// Generate FFI call to a Zig function from imported module
    fn generateFFICall(
        self: *HomeKernelCodegen,
        symbol: Symbol,
        args: []const *const ast.Expr,
    ) !void {
        // Build the full symbol name for FFI
        // e.g., "serial.init" becomes "basics_os_serial_init"
        var ffi_name: std.ArrayList(u8) = .{ .items = &[_]u8{}, .capacity = 0 };
        defer ffi_name.deinit(self.allocator);

        // Convert module path to C-compatible name
        for (symbol.module_path) |segment| {
            try ffi_name.appendSlice(self.allocator, segment);
            try ffi_name.append(self.allocator, '_');
        }
        try ffi_name.appendSlice(self.allocator, symbol.name);

        // Evaluate arguments according to System V AMD64 ABI
        // First 6 integer args: rdi, rsi, rdx, rcx, r8, r9
        const arg_regs = [_][]const u8{ "rdi", "rsi", "rdx", "rcx", "r8", "r9" };

        // Save previous register values if needed
        for (args, 0..) |arg, i| {
            if (i < arg_regs.len) {
                // Evaluate argument (result in %rax)
                try self.generateExpr(arg);

                // Move to appropriate argument register
                if (i == 0) {
                    try self.print("    movq %rax, %{s}\n", .{arg_regs[i]});
                } else {
                    try self.print("    movq %rax, %{s}\n", .{arg_regs[i]});
                }
            } else {
                // Push additional arguments onto stack
                try self.generateExpr(arg);
                try self.writeAll("    pushq %rax\n");
            }
        }

        // Call the external Zig function
        try self.print("    call {s}\n", .{ffi_name.items});

        // Clean up stack if we pushed extra arguments
        if (args.len > arg_regs.len) {
            const stack_bytes = (args.len - arg_regs.len) * 8;
            try self.print("    addq ${d}, %rsp\n", .{stack_bytes});
        }
    }
};

// Tests
test "home kernel codegen basics" {
    const allocator = std.testing.allocator;

    var symbol_table = SymbolTable.init(allocator);
    defer symbol_table.deinit();

    var module_resolver = try ModuleResolver.init(allocator, null);
    defer module_resolver.deinit();

    var codegen = HomeKernelCodegen.init(allocator, &symbol_table, &module_resolver);
    defer codegen.deinit();

    // Test basic initialization
    try std.testing.expect(codegen.output.items.len == 0);
}
