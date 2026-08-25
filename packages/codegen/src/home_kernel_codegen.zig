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
const Lexer = @import("lexer").Lexer;
const Io = std.Io;
const kernel_codegen = @import("kernel_codegen.zig");

/// String literal entry for .rodata section
const StringLiteral = struct {
    label: usize,
    content: []const u8,
};

/// A module-level mutable binding, lowered to a symbol in .bss or .data.
/// Kernel subsystems keep their state in these — page bitmaps, counters,
/// descriptor tables — so nothing in kernel/src/ compiles without them.
/// Prefix for module-variable symbols. Home keeps functions and variables in
/// separate namespaces; assembly does not, and this tree has files where a
/// `var free_pages` sits alongside a `fn free_pages`. Emitting both under the
/// bare name makes the assembler reject the file outright.
const GLOBAL_SYMBOL_PREFIX = "__home_g_";

const GlobalVar = struct {
    name: []const u8,
    /// The emitted assembly symbol, which is the name with the module-variable
    /// prefix applied.
    symbol: []const u8,
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
    /// Byte offset for an ordinary field; unused for a bitfield.
    offset: usize,
    size: usize,
    /// Bit placement within the backing integer, for a bitfield struct.
    bit_offset: usize = 0,
    bit_width: usize = 0,
};

/// A struct declaration imported from another module, with the qualified
/// name the importing file writes it as.
const PendingStruct = struct {
    decl: *const ast.StructDecl,
    qualified: []const u8,
};

/// A struct type laid out in memory. Fields are placed in declaration order,
/// each aligned to its own size (capped at 8), which matches the C ABI for
/// the scalar and array fields kernel structs are built from.
const StructInfo = struct {
    name: []const u8,
    size: usize,
    alignment: usize,
    fields: []FieldInfo,
    /// True when the struct IS an integer and its fields are bit ranges
    /// within it: `packed struct PageFlags: u64 { present: bool, ... }`.
    /// Page tables, descriptor tables, and hardware registers are all this
    /// shape, so a kernel backend that cannot express it cannot express a
    /// page table entry.
    is_bitfield: bool = false,
};

/// Value of a character literal lexeme, which still carries its quotes and
/// any escape sequence.
fn charLiteralValue(lexeme: []const u8) ?i64 {
    var body = lexeme;
    if (body.len >= 2 and (body[0] == '\'' or body[0] == '"')) {
        body = body[1 .. body.len - 1];
    }
    if (body.len == 0) return null;
    if (body[0] != '\\') {
        return if (body.len == 1) @as(i64, body[0]) else null;
    }
    if (body.len < 2) return null;
    return switch (body[1]) {
        'n' => 10,
        'r' => 13,
        't' => 9,
        '0' => 0,
        '\\' => 92,
        '\'' => 39,
        '"' => 34,
        // Additional C-style escapes; kernel sources use these in console
        // and keyboard handling paths.
        'a' => 7, // bell
        'b' => 8, // backspace
        'f' => 12, // form feed
        'v' => 11, // vertical tab
        else => null,
    };
}

/// The type name an expression names, when the expression IS a type — as in
/// `@sizeOf(PageTable)`, where the argument parses as an identifier.
fn typeNameOfExpr(expr: *const ast.Expr) ?[]const u8 {
    return switch (expr.*) {
        .Identifier => |id| id.name,
        else => null,
    };
}

/// Bit width of a type used as a bitfield member. `bool` is one bit; `uN`
/// and `iN` are N. Anything else has no bit width and makes the containing
/// struct un-layoutable rather than being assumed to be some default.
fn bitWidthOfType(type_name: []const u8) ?usize {
    if (std.mem.eql(u8, type_name, "bool")) return 1;
    if (type_name.len < 2) return null;
    if (type_name[0] != 'u' and type_name[0] != 'i') return null;
    const n = std.fmt.parseInt(usize, type_name[1..], 10) catch return null;
    if (n == 0 or n > 64) return null;
    return n;
}

/// Size in bytes of a primitive type name, or null. Deliberately narrow:
/// guessing a size for an unrecognized type would silently produce a symbol
/// of the wrong length. Struct and array types are resolved by the codegen's
/// own sizeOf, which has the struct table.
fn sizeOfPrimitive(type_name: []const u8) ?usize {
    if (std.mem.eql(u8, type_name, "u8") or std.mem.eql(u8, type_name, "i8") or
        std.mem.eql(u8, type_name, "bool")) return 1;
    if (std.mem.eql(u8, type_name, "u16") or std.mem.eql(u8, type_name, "i16")) return 2;
    if (std.mem.eql(u8, type_name, "str") or std.mem.eql(u8, type_name, "string")) return 8;
    if (std.mem.eql(u8, type_name, "u32") or std.mem.eql(u8, type_name, "i32")) return 4;
    // 128-bit descriptors: an IDT or GDT entry is one of these.
    if (std.mem.eql(u8, type_name, "u128") or std.mem.eql(u8, type_name, "i128")) return 16;
    if (std.mem.eql(u8, type_name, "u64") or std.mem.eql(u8, type_name, "i64") or
        std.mem.eql(u8, type_name, "usize") or std.mem.eql(u8, type_name, "isize") or
        std.mem.eql(u8, type_name, "int") or std.mem.eql(u8, type_name, "uint")) return 8;
    // Pointers are word-sized whatever they point at.
    if (type_name.len > 0 and (type_name[0] == '*' or type_name[0] == '&')) return 8;
    // A function type in a value position is a function pointer.
    if (std.mem.startsWith(u8, type_name, "fn(") or
        std.mem.startsWith(u8, type_name, "fn (")) return 8;
    return null;
}

/// Parse `[N]T` into an element count and the element's type name. The
/// element's *size* is resolved separately, because it may be a struct.
/// Index of the `]` matching the `[` at position 0, or null. Scanning for the
/// first `]` is wrong for a nested array: `[[u8; 4]; 3]` would split at the
/// inner bracket and yield nonsense.
fn matchingBracket(type_name: []const u8) ?usize {
    if (type_name.len == 0 or type_name[0] != '[') return null;
    var depth: usize = 0;
    for (type_name, 0..) |c, i| {
        if (c == '[') depth += 1;
        if (c == ']') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

/// Index of the last `;` outside any nested brackets.
fn lastTopLevelSemicolon(inside: []const u8) ?usize {
    var depth: usize = 0;
    var found: ?usize = null;
    for (inside, 0..) |c, i| {
        switch (c) {
            '[' => depth += 1,
            ']' => if (depth > 0) {
                depth -= 1;
            },
            ';' => if (depth == 0) {
                found = i;
            },
            else => {},
        }
    }
    return found;
}

fn parseArrayType(type_name: []const u8) ?struct { count: usize, elem_type: []const u8 } {
    if (type_name.len < 3 or type_name[0] != '[') return null;
    const close = matchingBracket(type_name) orelse return null;
    const inside = std.mem.trim(u8, type_name[1..close], " ");

    // `[T; N]` — the form this tree uses most. The separator is the last `;`
    // at depth zero, so a nested `[[u8; 4]; 3]` splits at the outer one.
    if (lastTopLevelSemicolon(inside)) |semi| {
        const elem_name = std.mem.trim(u8, inside[0..semi], " ");
        const count_str = std.mem.trim(u8, inside[semi + 1 ..], " ");
        const count = std.fmt.parseInt(usize, count_str, 0) catch return null;
        if (elem_name.len == 0) return null;
        return .{ .count = count, .elem_type = elem_name };
    }

    // `[N]T`.
    const count = std.fmt.parseInt(usize, inside, 0) catch return null;
    const elem_name = std.mem.trim(u8, type_name[close + 1 ..], " ");
    if (elem_name.len == 0) return null;
    return .{ .count = count, .elem_type = elem_name };
}

/// Strip a trailing `align(N)` qualifier and surrounding space from a written
/// type, returning the bare type and the requested alignment. Alignment is a
/// placement constraint, not part of the type's identity, so everything
/// downstream works on the bare name.
fn splitAlign(type_name: []const u8) struct { bare: []const u8, alignment: ?usize } {
    var trimmed = std.mem.trim(u8, type_name, " ");
    // Qualifiers constrain access, not layout: `volatile [N]u16` is laid out
    // exactly like `[N]u16`. Strip them so everything downstream sees a type
    // it recognizes. (Volatile *semantics* are the mmio_* intrinsics' job.)
    while (true) {
        if (std.mem.startsWith(u8, trimmed, "volatile ")) {
            trimmed = std.mem.trim(u8, trimmed["volatile ".len..], " ");
        } else if (std.mem.startsWith(u8, trimmed, "const ")) {
            trimmed = std.mem.trim(u8, trimmed["const ".len..], " ");
        } else if (std.mem.startsWith(u8, trimmed, "mut ")) {
            trimmed = std.mem.trim(u8, trimmed["mut ".len..], " ");
        } else break;
    }
    const marker = " align(";
    const at = std.mem.indexOf(u8, trimmed, marker) orelse return .{ .bare = trimmed, .alignment = null };
    const open = at + marker.len;
    const close = std.mem.indexOfScalarPos(u8, trimmed, open, ')') orelse
        return .{ .bare = trimmed, .alignment = null };
    const n = std.fmt.parseInt(usize, std.mem.trim(u8, trimmed[open..close], " "), 0) catch null;
    return .{ .bare = std.mem.trim(u8, trimmed[0..at], " "), .alignment = n };
}

/// A slice is written `[]T` and is two words: a pointer then a length.
fn isSliceType(type_name: []const u8) bool {
    return type_name.len > 2 and type_name[0] == '[' and type_name[1] == ']';
}

/// `[*]T` — a pointer you may index, carrying no length.
fn isManyPointer(type_name: []const u8) bool {
    return std.mem.startsWith(u8, type_name, "[*]");
}

fn sliceElem(type_name: []const u8) ?[]const u8 {
    if (!isSliceType(type_name)) return null;
    const e = std.mem.trim(u8, type_name[2..], " ");
    return if (e.len == 0) null else e;
}

/// Byte offset of a slice's length word.
const SLICE_LEN_OFFSET: usize = 8;
const SLICE_SIZE: usize = 16;

/// Parse an array type whose length is a named constant rather than a
/// literal — `[MAGAZINE_SIZE]u64` or `[u64; MAGAZINE_SIZE]`. The name is
/// resolved against the constants table by the codegen, which has it.
fn parseArrayTypeNamed(type_name: []const u8) ?struct { count_name: []const u8, elem_type: []const u8 } {
    if (type_name.len < 3 or type_name[0] != '[') return null;
    const close = matchingBracket(type_name) orelse return null;
    const inside = std.mem.trim(u8, type_name[1..close], " ");

    // The count slot may be any constant expression — `MAX_PAGE_TABLES / 8`,
    // `1 << 12` — not just a bare name. Accept anything made of identifier,
    // digit, and arithmetic characters and let the evaluator judge it; a
    // plain integer literal was already handled by parseArrayType.
    const isIdent = struct {
        fn f(t: []const u8) bool {
            if (t.len == 0) return false;
            var has_name_or_digit = false;
            for (t) |c| {
                if (std.ascii.isAlphanumeric(c) or c == '_' or c == '.') {
                    has_name_or_digit = true;
                    continue;
                }
                switch (c) {
                    ' ', '\t', '+', '-', '*', '/', '%', '<', '>', '(', ')' => {},
                    else => return false,
                }
            }
            return has_name_or_digit;
        }
    }.f;

    if (lastTopLevelSemicolon(inside)) |semi| {
        const elem_name = std.mem.trim(u8, inside[0..semi], " ");
        const count_name = std.mem.trim(u8, inside[semi + 1 ..], " ");
        if (elem_name.len == 0 or !isIdent(count_name)) return null;
        return .{ .count_name = count_name, .elem_type = elem_name };
    }

    const elem_name = std.mem.trim(u8, type_name[close + 1 ..], " ");
    if (elem_name.len == 0 or !isIdent(inside)) return null;
    return .{ .count_name = inside, .elem_type = elem_name };
}

/// True if the type is a pointer. Indexing one strides by the pointee.
fn isPointerType(type_name: []const u8) bool {
    // `[*]T` is a many-item pointer: an address you may index, with no length.
    if (std.mem.startsWith(u8, type_name, "[*]")) return true;
    // A string value is the address of its bytes.
    if (std.mem.eql(u8, type_name, "str") or std.mem.eql(u8, type_name, "string")) return true;
    return type_name.len > 1 and (type_name[0] == '*' or type_name[0] == '&');
}

/// The type a pointer or array refers to.
fn pointeeType(raw: []const u8) ?[]const u8 {
    const type_name = splitAlign(raw).bare;
    // A string is a run of bytes; indexing one yields a byte.
    if (std.mem.eql(u8, type_name, "str") or std.mem.eql(u8, type_name, "string")) return "u8";
    if (std.mem.startsWith(u8, type_name, "[*]")) {
        const e = std.mem.trim(u8, type_name[3..], " ");
        return if (e.len == 0) null else e;
    }
    if (isSliceType(type_name)) return sliceElem(type_name);
    if (isPointerType(type_name)) {
        var rest = type_name[1..];
        // `&mut T` and `*const T` both point at T.
        if (std.mem.startsWith(u8, rest, "mut ")) rest = rest[4..];
        if (std.mem.startsWith(u8, rest, "const ")) rest = rest[6..];
        const trimmed = std.mem.trim(u8, rest, " ");
        return if (trimmed.len == 0) null else trimmed;
    }
    if (parseArrayType(type_name)) |arr| return arr.elem_type;
    if (parseArrayTypeNamed(type_name)) |named| return named.elem_type;
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
    /// Declared return type of each function, for inferring the type of a
    /// local initialized from a call.
    fn_return_types: std.StringHashMap([]const u8),
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
    /// Enum tag width by enum name, so an enum-typed field or global is sized.
    enum_sizes: std.StringHashMap(usize),
    /// Enum variant values, keyed "EnumName.VariantName".
    enum_values: std.StringHashMap(i64),
    /// Arena holding every imported module's source and AST. Type names are
    /// slices into that source, so it must outlive code generation.
    import_arena: std.heap.ArenaAllocator,
    /// Files already pulled in, so a cycle or a diamond import is visited once.
    imported_files: std.StringHashMap(void),
    /// Frame slot holding the hidden destination pointer, for a function that
    /// returns an aggregate. 0 means this function does not return one.
    sret_slot: i32,
    /// Declared return type of the function being generated, needed to size
    /// the copy into that destination.
    current_return_type: []const u8,
    /// Interned `*T` names, so pointerTo can return a stable slice.
    pointer_type_names: std.StringHashMap([]const u8),
    /// Struct declarations from imported modules, awaiting layout alongside
    /// this file's own. Each carries the qualified name it is written as.
    pending_structs: std.ArrayList(PendingStruct),

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
        result.fn_return_types = std.StringHashMap([]const u8).init(allocator);
        result.globals = std.StringHashMap(i64).init(allocator);
        result.at_top_level = true;
        result.global_vars = std.StringHashMap(GlobalVar).init(allocator);
        result.global_order = .{ .items = &[_][]const u8{}, .capacity = 0 };
        result.assigned_names = std.StringHashMap(void).init(allocator);
        result.local_types = std.StringHashMap([]const u8).init(allocator);
        result.structs = std.StringHashMap(StructInfo).init(allocator);
        result.enum_sizes = std.StringHashMap(usize).init(allocator);
        result.enum_values = std.StringHashMap(i64).init(allocator);
        result.import_arena = std.heap.ArenaAllocator.init(allocator);
        result.imported_files = std.StringHashMap(void).init(allocator);
        result.pending_structs = .{ .items = &[_]PendingStruct{}, .capacity = 0 };
        result.pointer_type_names = std.StringHashMap([]const u8).init(allocator);
        result.sret_slot = 0;
        result.current_return_type = "";
        return result;
    }

    pub fn deinit(self: *HomeKernelCodegen) void {
        self.output.deinit(self.allocator);
        self.locals.deinit();
        self.declared_fns.deinit();
        self.fn_return_types.deinit();
        self.globals.deinit();
        self.global_vars.deinit();
        self.global_order.deinit(self.allocator);
        self.assigned_names.deinit();
        self.local_types.deinit();
        var struct_it = self.structs.valueIterator();
        while (struct_it.next()) |info| self.allocator.free(info.fields);
        self.structs.deinit();
        self.enum_sizes.deinit();
        var ev_it = self.enum_values.keyIterator();
        while (ev_it.next()) |k| self.allocator.free(k.*);
        self.enum_values.deinit();
        self.imported_files.deinit();
        self.pending_structs.deinit(self.allocator);
        self.pointer_type_names.deinit();
        self.import_arena.deinit();
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
    /// Evaluate a constant expression written inside an array type's
    /// brackets — `[MAX_PAGE_TABLES / 8]u8`. The constant folder works on the
    /// AST, but a type is a string by the time it reaches here, so this is a
    /// small recursive-descent evaluator over that text. Identifiers resolve
    /// against the module constants table.
    const ConstExprParser = struct {
        text: []const u8,
        pos: usize = 0,
        cg: *HomeKernelCodegen,

        fn skipSpace(self: *ConstExprParser) void {
            while (self.pos < self.text.len and (self.text[self.pos] == ' ' or self.text[self.pos] == '\t')) {
                self.pos += 1;
            }
        }

        fn peek(self: *ConstExprParser) ?u8 {
            self.skipSpace();
            return if (self.pos < self.text.len) self.text[self.pos] else null;
        }

        fn eat(self: *ConstExprParser, c: u8) bool {
            if (self.peek() == c) {
                self.pos += 1;
                return true;
            }
            return false;
        }

        fn eatOp2(self: *ConstExprParser, a: u8, b: u8) bool {
            self.skipSpace();
            if (self.pos + 1 < self.text.len and self.text[self.pos] == a and self.text[self.pos + 1] == b) {
                self.pos += 2;
                return true;
            }
            return false;
        }

        fn primary(self: *ConstExprParser) ?i64 {
            self.skipSpace();
            if (self.pos >= self.text.len) return null;
            const c = self.text[self.pos];

            if (c == '(') {
                self.pos += 1;
                const v = self.additive() orelse return null;
                if (!self.eat(')')) return null;
                return v;
            }
            if (c == '-') {
                self.pos += 1;
                const v = self.primary() orelse return null;
                return -v;
            }
            if (std.ascii.isDigit(c)) {
                const start = self.pos;
                // Accept 0x / 0b prefixes and the digits after them.
                while (self.pos < self.text.len and
                    (std.ascii.isAlphanumeric(self.text[self.pos]) or self.text[self.pos] == '_'))
                {
                    self.pos += 1;
                }
                return std.fmt.parseInt(i64, self.text[start..self.pos], 0) catch null;
            }
            if (std.ascii.isAlphabetic(c) or c == '_') {
                const start = self.pos;
                while (self.pos < self.text.len and
                    (std.ascii.isAlphanumeric(self.text[self.pos]) or self.text[self.pos] == '_' or self.text[self.pos] == '.'))
                {
                    self.pos += 1;
                }
                return self.cg.globals.get(self.text[start..self.pos]);
            }
            return null;
        }

        fn multiplicative(self: *ConstExprParser) ?i64 {
            var left = self.primary() orelse return null;
            while (true) {
                self.skipSpace();
                if (self.eat('*')) {
                    const r = self.primary() orelse return null;
                    left *%= r;
                } else if (self.eat('/')) {
                    const r = self.primary() orelse return null;
                    if (r == 0) return null;
                    left = @divTrunc(left, r);
                } else if (self.eat('%')) {
                    const r = self.primary() orelse return null;
                    if (r == 0) return null;
                    left = @rem(left, r);
                } else return left;
            }
        }

        fn additive(self: *ConstExprParser) ?i64 {
            var left = self.multiplicative() orelse return null;
            while (true) {
                self.skipSpace();
                if (self.eatOp2('<', '<')) {
                    const r = self.multiplicative() orelse return null;
                    if (r < 0 or r > 63) return null;
                    left <<= @intCast(r);
                } else if (self.eatOp2('>', '>')) {
                    const r = self.multiplicative() orelse return null;
                    if (r < 0 or r > 63) return null;
                    left >>= @intCast(r);
                } else if (self.eat('+')) {
                    const r = self.multiplicative() orelse return null;
                    left +%= r;
                } else if (self.eat('-')) {
                    const r = self.multiplicative() orelse return null;
                    left -%= r;
                } else return left;
            }
        }
    };

    fn evalConstExprText(self: *HomeKernelCodegen, text: []const u8) ?i64 {
        var parser = ConstExprParser{ .text = text, .cg = self };
        const value = parser.additive() orelse return null;
        parser.skipSpace();
        // Trailing junk means this was not a constant expression after all.
        if (parser.pos != parser.text.len) return null;
        return value;
    }

    /// Parse an array type, resolving a length written as a named constant.
    /// `[MAGAZINE_SIZE]u64` is how this tree sizes most of its tables, and a
    /// struct containing one cannot be laid out until the name resolves.
    fn arrayType(self: *HomeKernelCodegen, raw: []const u8) ?struct { count: usize, elem_type: []const u8 } {
        const type_name = splitAlign(raw).bare;
        if (parseArrayType(type_name)) |arr| return .{ .count = arr.count, .elem_type = arr.elem_type };
        if (parseArrayTypeNamed(type_name)) |named| {
            const value = self.evalConstExprText(named.count_name) orelse return null;
            if (value < 0) return null;
            return .{ .count = @intCast(value), .elem_type = named.elem_type };
        }
        return null;
    }

    fn sizeOf(self: *HomeKernelCodegen, raw: []const u8) ?usize {
        const type_name = splitAlign(raw).bare;
        if (sizeOfPrimitive(type_name)) |n| return n;
        if (isPointerType(type_name)) return 8;
        if (isSliceType(type_name)) return SLICE_SIZE;
        if (self.arrayType(type_name)) |arr| {
            const elem = self.sizeOf(arr.elem_type) orelse return null;
            return arr.count * elem;
        }
        if (self.structs.get(type_name)) |info| return info.size;
        if (self.enum_sizes.get(type_name)) |n| return n;
        return null;
    }

    /// Emit the address of a slice's data pointer's *target* — i.e. load the
    /// pointer word — given the address of the slice itself in %rax.
    fn emitSliceData(self: *HomeKernelCodegen) !void {
        try self.writeAll("    movq (%rax), %rax\n");
    }

    /// Alignment of a type: its own size for scalars, capped at 8.
    fn alignOf(self: *HomeKernelCodegen, raw: []const u8) usize {
        const split = splitAlign(raw);
        if (split.alignment) |explicit| return explicit;
        const type_name = split.bare;
        if (self.structs.get(type_name)) |info| return info.alignment;
        if (self.arrayType(type_name)) |arr| return self.alignOf(arr.elem_type);
        if (isSliceType(type_name)) return 8;
        const size = self.sizeOf(type_name) orelse 8;
        return @min(size, @as(usize, 8));
    }

    /// Maximum import depth. Kernel modules import their direct dependencies
    /// and little else; a few levels covers the real graph, and the bound
    /// means a pathological graph degrades to "some types unresolved" rather
    /// than a hang.
    const MAX_IMPORT_DEPTH: usize = 4;

    /// Pull struct, enum, and constant declarations from imported modules into
    /// scope, registered under the importing alias so `spinlock.Spinlock`
    /// resolves. Recurses, because an imported module's structs may themselves
    /// have fields from a further module.
    fn collectImports(self: *HomeKernelCodegen, program: *const ast.Program, depth: usize) anyerror!void {
        if (depth >= MAX_IMPORT_DEPTH) return;
        const arena = self.import_arena.allocator();

        for (program.statements) |stmt| {
            if (stmt != .ImportDecl) continue;
            const decl = stmt.ImportDecl;

            const resolved = self.module_resolver.resolve(decl.path) catch continue;
            // A Zig module has no Home declarations to read.
            if (resolved.is_zig) continue;

            // Visit each file once: kernel modules form a diamond around
            // core/foundation.home, and cycles exist.
            if (self.imported_files.contains(resolved.file_path)) continue;
            const key = arena.dupe(u8, resolved.file_path) catch continue;
            self.imported_files.put(key, {}) catch continue;

            // The resolver carries the Io context. Without one no file can be
            // opened, so every type from this module would silently go
            // missing — and a missing type is not an error at its own site,
            // it is an unlayoutable struct three files away. Say so here.
            const io = self.module_resolver.io orelse {
                try self.print("# ERROR: no Io context; cannot read imported module {s}\n", .{resolved.file_path});
                continue;
            };
            const source = Io.Dir.cwd().readFileAlloc(
                io,
                resolved.file_path,
                arena,
                Io.Limit.limited(16 * 1024 * 1024),
            ) catch {
                try self.print("# ERROR: cannot read imported module {s}\n", .{resolved.file_path});
                continue;
            };

            var lexer = Lexer.init(arena, source);
            const tokens = lexer.tokenize() catch continue;
            var parser = Parser.init(arena, tokens.items) catch continue;
            parser.source_text = source;
            parser.source_file = resolved.file_path;
            parser.module_resolver.setSourceRoot(resolved.file_path) catch {};
            // A module that does not fully parse still yields the declarations
            // that did, which is better than treating every type in it as
            // unknown.
            const imported = parser.parse() catch continue;

            // The alias the importing file uses, or the module's own name.
            const alias = decl.alias orelse resolved.name;

            try self.registerImportedDecls(imported, alias);
            try self.collectImports(imported, depth + 1);
        }
    }

    /// Register one imported module's types under `alias`, both qualified
    /// (`spinlock.Spinlock`, which is how the type is written at the use site)
    /// and bare, so a struct field written without the qualifier still
    /// resolves. A bare name already taken by the importing file is never
    /// overwritten: the local declaration wins.
    fn registerImportedDecls(
        self: *HomeKernelCodegen,
        program: *const ast.Program,
        alias: []const u8,
    ) !void {
        const arena = self.import_arena.allocator();

        for (program.statements) |stmt| {
            switch (stmt) {
                .StructDecl => |decl| {
                    const qualified = try std.fmt.allocPrint(arena, "{s}.{s}", .{ alias, decl.name });
                    try self.pending_structs.append(self.allocator, .{
                        .decl = decl,
                        .qualified = qualified,
                    });
                },
                .EnumDecl => |decl| {
                    const size = if (decl.tag_type) |t| (sizeOfPrimitive(t) orelse 4) else 4;
                    const qualified = try std.fmt.allocPrint(arena, "{s}.{s}", .{ alias, decl.name });
                    if (!self.enum_sizes.contains(qualified)) try self.enum_sizes.put(qualified, size);
                    if (!self.enum_sizes.contains(decl.name)) try self.enum_sizes.put(decl.name, size);

                    var next: i64 = 0;
                    for (decl.variants) |v| {
                        const value = v.value orelse next;
                        next = value + 1;
                        for ([_][]const u8{ qualified, decl.name }) |owner| {
                            const key = try std.fmt.allocPrint(arena, "{s}.{s}", .{ owner, v.name });
                            if (!self.enum_values.contains(key)) try self.enum_values.put(key, value);
                        }
                    }
                },
                .LetDecl => |decl| {
                    // Only constants cross a module boundary here. Imported
                    // *storage* would need a symbol reference, which is the
                    // linker's business and a separate step.
                    if (decl.is_mutable) continue;
                    const value = decl.value orelse continue;
                    const folded = self.foldConst(value) orelse continue;
                    const qualified = try std.fmt.allocPrint(arena, "{s}.{s}", .{ alias, decl.name });
                    if (!self.globals.contains(qualified)) try self.globals.put(qualified, folded);
                    if (!self.globals.contains(decl.name)) try self.globals.put(decl.name, folded);
                },
                else => {},
            }
        }
    }

    /// Fold module-level constants before anything that depends on them.
    /// Runs to a fixed point so a constant may be defined in terms of one
    /// declared later in the file.
    fn foldModuleConstants(self: *HomeKernelCodegen, program: *const ast.Program) !void {
        var progress = true;
        while (progress) {
            progress = false;
            for (program.statements) |stmt| {
                if (stmt != .LetDecl) continue;
                const decl = stmt.LetDecl;
                if (decl.is_mutable) continue;
                if (self.assigned_names.contains(decl.name)) continue;
                if (self.globals.contains(decl.name)) continue;
                const value = decl.value orelse continue;
                if (self.foldConst(value)) |folded| {
                    try self.globals.put(decl.name, folded);
                    progress = true;
                }
            }
        }
    }

    /// Record each enum's tag width and its variants' values. An enum is an
    /// integer of its tag type; a variant is a compile-time constant.
    /// Variants without an explicit value continue from the previous one,
    /// starting at zero, which is what both spellings of the syntax mean.
    fn collectEnums(self: *HomeKernelCodegen, program: *const ast.Program) !void {
        for (program.statements) |stmt| {
            if (stmt != .EnumDecl) continue;
            const decl = stmt.EnumDecl;
            // Default tag width is 4 bytes when the declaration does not say.
            const size = if (decl.tag_type) |t| (sizeOfPrimitive(t) orelse 4) else 4;
            try self.enum_sizes.put(decl.name, size);

            var next: i64 = 0;
            for (decl.variants) |v| {
                const value = v.value orelse next;
                next = value + 1;
                const key = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ decl.name, v.name });
                // A duplicate key would leak the second allocation.
                if (self.enum_values.contains(key)) {
                    self.allocator.free(key);
                    continue;
                }
                try self.enum_values.put(key, value);
            }
        }
    }

    /// Lay out every struct declared in the program. Runs to a fixed point so
    /// a struct may refer to one declared later in the file; a struct that
    /// still cannot be laid out after that is left out of the table, and any
    /// use of it is refused rather than assigned a made-up size.
    fn layoutStructs(self: *HomeKernelCodegen, program: *const ast.Program) !void {
        var progress = true;
        while (progress) {
            progress = false;
            // This file's own structs first, so a local declaration wins any
            // bare-name collision with an imported one.
            for (program.statements) |stmt| {
                if (stmt != .StructDecl) continue;
                if (try self.layoutOneStruct(stmt.StructDecl, null)) progress = true;
            }
            // Then imported structs, registered under both their qualified
            // name (how the use site writes them) and their bare name.
            for (self.pending_structs.items) |pending| {
                if (try self.layoutOneStruct(pending.decl, pending.qualified)) progress = true;
            }
        }
    }

    /// Lay out one struct if every field can be sized. Returns true when it
    /// made progress, so the caller's fixed-point loop knows to go again.
    fn layoutOneStruct(
        self: *HomeKernelCodegen,
        decl: *const ast.StructDecl,
        qualified: ?[]const u8,
    ) !bool {
        const primary = qualified orelse decl.name;
        if (self.structs.contains(primary)) return false;

        // A bitfield struct is its backing integer; its fields are bit ranges
        // laid out from the least significant bit up, in declaration order.
        if (decl.backing_type) |backing| {
            const total_bytes = sizeOfPrimitive(backing) orelse return false;
            var bits = try self.allocator.alloc(FieldInfo, decl.fields.len);
            errdefer self.allocator.free(bits);
            var bit_pos: usize = 0;
            for (decl.fields, 0..) |f, i| {
                // An explicit `x: u32:4` width wins over the type's own.
                const width = if (f.bit_width) |bw| @as(usize, bw) else (bitWidthOfType(f.type_name) orelse {
                    self.allocator.free(bits);
                    return false;
                });
                if (bit_pos + width > total_bytes * 8) {
                    self.allocator.free(bits);
                    return false;
                }
                bits[i] = .{
                    .name = f.name,
                    .type_name = f.type_name,
                    .offset = 0,
                    .size = total_bytes,
                    .bit_offset = bit_pos,
                    .bit_width = width,
                };
                bit_pos += width;
            }
            try self.structs.put(primary, .{
                .name = primary,
                .size = total_bytes,
                .alignment = @min(total_bytes, @as(usize, 8)),
                .fields = bits,
                .is_bitfield = true,
            });
            if (qualified != null and !self.structs.contains(decl.name)) {
                const copy = try self.allocator.dupe(FieldInfo, bits);
                try self.structs.put(decl.name, .{
                    .name = decl.name,
                    .size = total_bytes,
                    .alignment = @min(total_bytes, @as(usize, 8)),
                    .fields = copy,
                    .is_bitfield = true,
                });
            }
            return true;
        }

        // Every field must have a known size before this struct does. A
        // struct with one unsizable field is left out entirely rather than
        // laid out with a guessed offset, which would misplace every field
        // after it.
        for (decl.fields) |f| {
            if (self.sizeOf(f.type_name) == null) return false;
        }

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
        const info: StructInfo = .{
            .name = primary,
            .size = total,
            .alignment = max_align,
            .fields = fields,
        };
        try self.structs.put(primary, info);

        // Also register the bare name, unless this file already declares one.
        if (qualified != null and !self.structs.contains(decl.name)) {
            const copy = try self.allocator.dupe(FieldInfo, fields);
            try self.structs.put(decl.name, .{
                .name = decl.name,
                .size = total,
                .alignment = max_align,
                .fields = copy,
            });
        }
        return true;
    }

    /// True for types whose value is their address: arrays and structs.
    fn isStorageType(self: *HomeKernelCodegen, raw: []const u8) bool {
        const type_name = splitAlign(raw).bare;
        if (self.arrayType(type_name) != null) return true;
        if (isSliceType(type_name)) return true;
        if (self.structs.get(type_name)) |info| {
            // A bitfield struct IS its backing integer, so one that fits in a
            // register is a value and is assigned like one — otherwise
            // `entry.flags = emptyPageFlags()` would demand an lvalue on the
            // right. A wider one (a u128 descriptor) does not fit in any
            // register and is storage like any other aggregate.
            return !info.is_bitfield or info.size > 8;
        }
        return false;
    }

    fn findField(self: *HomeKernelCodegen, raw: []const u8, member: []const u8) ?FieldInfo {
        const info = self.structs.get(splitAlign(raw).bare) orelse return null;
        for (info.fields) |f| {
            if (std.mem.eql(u8, f.name, member)) return f;
        }
        return null;
    }

    /// The type an argument in type position denotes: a bare name is the type
    /// itself, and `@TypeOf(x)` is x's declared type — which is how this tree
    /// writes `@sizeOf(@TypeOf(idt))`.
    fn typeArgOf(self: *HomeKernelCodegen, expr: *const ast.Expr) ?[]const u8 {
        switch (expr.*) {
            .Identifier => |id| {
                if (self.structs.contains(id.name) or self.enum_sizes.contains(id.name)) return id.name;
                if (sizeOfPrimitive(id.name) != null) return id.name;
                return self.typeOfLValue(expr) orelse id.name;
            },
            .ReflectExpr => |r| {
                if (r.kind == .TypeOf) {
                    if (r.target_type) |t| return t;
                    return self.typeOfLValue(r.target);
                }
                return null;
            },
            else => return self.typeOfLValue(expr),
        }
    }

    /// `*T` for a given T, interned in the import arena so the returned name
    /// outlives the call. Falls back to T if the name cannot be built, which
    /// only loses precision rather than correctness.
    fn pointerTo(self: *HomeKernelCodegen, inner: []const u8) []const u8 {
        if (self.pointer_type_names.get(inner)) |cached| return cached;
        const name = std.fmt.allocPrint(self.import_arena.allocator(), "*{s}", .{inner}) catch return inner;
        self.pointer_type_names.put(inner, name) catch return name;
        return name;
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
                const inner = pointeeType(base) orelse return null;
                // `entries: *[DirEntryInfo; 256]` indexed reaches an element,
                // not the array: a pointer to an array is a handle on the
                // array, and this tree writes `entries[i].size`.
                if (isPointerType(splitAlign(base).bare)) {
                    if (pointeeType(inner)) |elem| return elem;
                }
                return inner;
            },
            .MemberExpr => |m| {
                var base = splitAlign(self.typeOfLValue(m.object) orelse return null).bare;
                if (isSliceType(base) and std.mem.eql(u8, m.member, "len")) return "usize";
                if (isPointerType(base)) base = pointeeType(base) orelse base;
                const f = self.findField(base, m.member) orelse return null;
                return f.type_name;
            },
            .UnaryExpr => |u| {
                // `*p` has the pointee's type; `&x` has x's, as a pointer we
                // only need for further member access, so report x's type.
                const inner = self.typeOfLValue(u.operand) orelse return null;
                return switch (u.op) {
                    .Deref => pointeeType(inner),
                    // `&x` is a pointer to x, not an x. Reporting the inner
                    // type made `let e = &table[i]` look like storage, so the
                    // binding was sized for a whole struct and initialized by
                    // an aggregate copy — from an address-of expression, which
                    // is a value and has no address of its own to copy from.
                    .AddressOf, .Borrow, .BorrowMut => self.pointerTo(inner),
                    else => null,
                };
            },
            .CallExpr => |c| {
                if (c.callee.* != .Identifier) return null;
                return self.fn_return_types.get(c.callee.Identifier.name);
            },
            // A string literal's value is the address of its bytes, so a local
            // initialized from one is a byte pointer and may be indexed.
            .StringLiteral => return "[*]u8",
            .IfExpr => |ie| {
                // The value of an if-expression is whichever branch runs, so
                // its type is the branches' common type. Take the then-branch
                // and fall back to the else-branch when it is unknown — a
                // branch may end in `null`, which carries no type.
                if (self.typeOfLValue(ie.then_branch)) |t| return t;
                return self.typeOfLValue(ie.else_branch);
            },
            .BlockExpr => |b| {
                // A block's value is its trailing expression.
                if (b.statements.len == 0) return null;
                const last = b.statements[b.statements.len - 1];
                if (last == .ExprStmt) return self.typeOfLValue(last.ExprStmt);
                return null;
            },
            .SliceExpr => |sl| {
                const base = self.typeOfLValue(sl.array) orelse return null;
                return pointeeType(splitAlign(base).bare);
            },
            // A struct literal has the type it names; this sizes an inferred
            // local's slot to the full struct, not one word.
            .StructLiteral => |lit| return lit.type_name,
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
                    try self.print("    leaq {s}(%rip), %rax\n", .{g.symbol});
                    return g.type_name;
                }
                // A function's address is its label. Interrupt tables are
                // built out of these.
                if (self.declared_fns.contains(id.name)) {
                    try self.print("    leaq {s}(%rip), %rax\n", .{id.name});
                    return "fn()";
                }
                try self.print("    # ERROR: cannot take the address of {s}\n", .{id.name});
                return null;
            },
            .IndexExpr => |idx| {
                const base_type = self.typeOfLValue(idx.array) orelse {
                    try self.writeAll("    # ERROR: cannot index: the base has no known type\n");
                    return null;
                };
                var elem_type = pointeeType(base_type) orelse {
                    try self.print("    # ERROR: cannot index a value of type {s}\n", .{base_type});
                    return null;
                };
                const bare_base = splitAlign(base_type).bare;
                // Through a pointer-to-array, indexing reaches the element:
                // `entries: *[DirEntryInfo; 256]` written as `entries[i].size`.
                if (isPointerType(bare_base)) {
                    if (pointeeType(elem_type)) |inner| elem_type = inner;
                }
                const elem_size = self.sizeOf(elem_type) orelse {
                    try self.print("    # ERROR: cannot index: element type {s} has unknown size\n", .{elem_type});
                    return null;
                };

                // Get the address of element zero, stash it, then evaluate the
                // index — so the index expression cannot clobber the base.
                if (isSliceType(bare_base)) {
                    // A slice indexes through its data pointer, not through
                    // the address of the (pointer, length) pair itself.
                    _ = try self.emitAddress(idx.array) orelse return null;
                    try self.emitSliceData();
                } else if (isPointerType(bare_base)) {
                    // A pointer's value is already the base address.
                    try self.generateExpr(idx.array);
                } else {
                    // An array's storage starts at its own address.
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
                // `.ptr` is the address of the data, whatever carries it:
                // a slice's first word, or an array or pointer's own value.
                if (std.mem.eql(u8, m.member, "ptr")) {
                    const bare = splitAlign(base_type).bare;
                    if (isSliceType(bare)) {
                        _ = try self.emitAddress(m.object) orelse return null;
                        return "[*]u8";
                    }
                    if (self.arrayType(bare) != null or isPointerType(bare)) {
                        _ = try self.emitAddress(m.object) orelse return null;
                        return "[*]u8";
                    }
                }
                // A slice's only field is its length, the second word.
                if (isSliceType(splitAlign(base_type).bare) and std.mem.eql(u8, m.member, "len")) {
                    _ = try self.emitAddress(m.object) orelse return null;
                    try self.print("    addq ${d}, %rax\n", .{SLICE_LEN_OFFSET});
                    return "usize";
                }
                // An array's length is known at compile time.
                if (self.arrayType(splitAlign(base_type).bare)) |arr| {
                    if (std.mem.eql(u8, m.member, "len")) {
                        try self.print("    # ERROR: {s}.len is a compile-time constant; use it as a value, not an address\n", .{m.member});
                        _ = arr;
                        return null;
                    }
                }
                // Through a pointer, `p.f` means `(*p).f`.
                var owner = splitAlign(base_type).bare;
                var through_pointer = false;
                if (isPointerType(owner)) {
                    owner = pointeeType(owner) orelse owner;
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

    /// If `m` names a member of a bitfield struct, return its placement.
    fn bitFieldOf(self: *HomeKernelCodegen, m: *const ast.MemberExpr) !?struct {
        field: FieldInfo,
        container_size: usize,
    } {
        const base_type = self.typeOfLValue(m.object) orelse return null;
        var owner = splitAlign(base_type).bare;
        if (isPointerType(owner)) owner = pointeeType(owner) orelse owner;
        const info = self.structs.get(owner) orelse return null;
        if (!info.is_bitfield) return null;
        for (info.fields) |f| {
            if (std.mem.eql(u8, f.name, m.member)) {
                return .{ .field = f, .container_size = info.size };
            }
        }
        return null;
    }

    /// Load a bitfield struct's backing integer from the address in %rax.
    /// Load the 64-bit word of a bitfield container that holds `bit_offset`,
    /// from the container address in %rax, and return the bit offset within
    /// that word. A container wider than a register — a u128 descriptor — is
    /// addressed a word at a time rather than refused.
    fn emitLoadBackingWord(self: *HomeKernelCodegen, size: usize, bit_offset: usize) !usize {
        if (size <= 8) {
            try self.emitLoadBacking(size);
            return bit_offset;
        }
        const word = bit_offset / 64;
        if (word * 8 >= size) {
            try self.print("    # ERROR: bit offset {d} lies outside a {d}-byte container\n", .{ bit_offset, size });
            try self.writeAll("    movq $0, %rax\n");
            return bit_offset % 64;
        }
        try self.print("    movq {d}(%rax), %rax\n", .{word * 8});
        return bit_offset % 64;
    }

    fn emitLoadBacking(self: *HomeKernelCodegen, size: usize) !void {
        const ld = loadFor(size) orelse {
            try self.print("    # ERROR: cannot load a bitfield container of {d} bytes\n", .{size});
            try self.writeAll("    movq $0, %rax\n");
            return;
        };
        try self.writeAll("    movq %rax, %rdx\n");
        if (size < 8) try self.writeAll("    xorq %rax, %rax\n");
        try self.print("    {s} (%rdx), %{s}\n", .{ ld.insn, ld.reg });
    }

    /// Emit the address of `base[start..]` into %rax, returning the element
    /// type. `base` may be an array, a pointer, or another slice.
    fn emitSliceDataPointer(self: *HomeKernelCodegen, sl: *const ast.SliceExpr) anyerror!?[]const u8 {
        const base_type = self.typeOfLValue(sl.array) orelse {
            try self.writeAll("    # ERROR: cannot slice: the base has no known type\n");
            return null;
        };
        const bare = splitAlign(base_type).bare;
        const elem_type = pointeeType(bare) orelse {
            try self.print("    # ERROR: cannot slice a value of type {s}\n", .{bare});
            return null;
        };
        const elem_size = self.sizeOf(elem_type) orelse {
            try self.print("    # ERROR: cannot slice: element type {s} has unknown size\n", .{elem_type});
            return null;
        };

        if (isSliceType(bare)) {
            _ = try self.emitAddress(sl.array) orelse return null;
            try self.emitSliceData();
        } else if (isPointerType(bare)) {
            try self.generateExpr(sl.array);
        } else {
            _ = try self.emitAddress(sl.array) orelse return null;
        }

        // Offset by the start index, when there is one.
        if (sl.start) |start| {
            try self.writeAll("    pushq %rax\n");
            try self.generateExpr(start);
            if (elem_size > 1) {
                try self.print("    imulq ${d}, %rax\n", .{elem_size});
            }
            try self.writeAll("    popq %rcx\n");
            try self.writeAll("    addq %rcx, %rax\n");
        }
        return elem_type;
    }

    /// Emit the length of a slice expression into %rax: `end - start`, or the
    /// base's own length when `end` is omitted.
    fn emitSliceLength(self: *HomeKernelCodegen, sl: *const ast.SliceExpr) anyerror!void {
        if (sl.end) |end| {
            try self.generateExpr(end);
            if (sl.start) |start| {
                try self.writeAll("    pushq %rax\n");
                try self.generateExpr(start);
                try self.writeAll("    movq %rax, %rcx\n");
                try self.writeAll("    popq %rax\n");
                try self.writeAll("    subq %rcx, %rax\n");
            }
            return;
        }
        // No end: the length is the base's, minus any start offset.
        const base_type = self.typeOfLValue(sl.array) orelse {
            try self.writeAll("    # ERROR: cannot determine slice length\n");
            try self.writeAll("    movq $0, %rax\n");
            return;
        };
        const bare = splitAlign(base_type).bare;
        if (self.arrayType(bare)) |arr| {
            try self.print("    movq ${d}, %rax\n", .{arr.count});
        } else if (isSliceType(bare)) {
            _ = try self.emitAddress(sl.array) orelse return;
            try self.print("    addq ${d}, %rax\n", .{SLICE_LEN_OFFSET});
            try self.writeAll("    movq (%rax), %rax\n");
        } else {
            try self.print("    # ERROR: cannot determine the length of {s}\n", .{bare});
            try self.writeAll("    movq $0, %rax\n");
            return;
        }
        if (sl.start) |start| {
            try self.writeAll("    pushq %rax\n");
            try self.generateExpr(start);
            try self.writeAll("    movq %rax, %rcx\n");
            try self.writeAll("    popq %rax\n");
            try self.writeAll("    subq %rcx, %rax\n");
        }
    }

    /// Load the value at the address in %rax, given its declared type.
    /// An array or struct loads as its own address: it is storage, not a
    /// value that fits in a register.
    fn emitLoadFromAddress(self: *HomeKernelCodegen, type_name: []const u8) !void {
        if (self.arrayType(type_name) != null) return;
        if (self.structs.get(type_name)) |info| {
            // A bitfield struct loads as its backing integer; every other
            // struct's "value" is its address.
            if (!info.is_bitfield) return;
        }
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

    /// Write a struct literal's fields directly into the struct storage whose
    /// address is on top of the stack (the caller pushes it). Bytes no field
    /// covers are zeroed first, which is what a literal means: fields you do
    /// not mention are zero, not garbage. Field value expressions run with
    /// the base address pushed again so they cannot clobber it.
    fn emitStructLiteralToMemory(
        self: *HomeKernelCodegen,
        type_name: []const u8,
        lit: *const ast.StructLiteralExpr,
    ) !void {
        const bare = splitAlign(type_name).bare;
        const info = self.structs.get(bare) orelse {
            try self.print("    # ERROR: struct literal of unknown type {s}\n", .{type_name});
            try self.writeAll("    addq $8, %rsp\n");
            return;
        };
        if (info.is_bitfield) {
            // A bitfield literal IS an integer: build it in %rax via the
            // expression path, then store over the destination.
            // generateExpr takes a pointer, so the wrapper needs storage.
            // The union holds a mutable pointer; nothing here writes through it.
            var as_expr = ast.Expr{ .StructLiteral = @constCast(lit) };
            try self.generateExpr(&as_expr);
            try self.writeAll("    popq %rdx\n");
            try self.print("    movq %rax, (%rdx)\n", .{});
            return;
        }

        try self.writeAll("    popq %rdi\n");
        // Zero the full width so unmentioned fields read as zero.
        try self.print("    movq ${d}, %rcx\n", .{info.size});
        try self.writeAll("    xorq %rax, %rax\n");
        try self.writeAll("    cld\n");
        try self.writeAll("    rep stosb\n");

        for (lit.fields) |fi| {
            var field: ?FieldInfo = null;
            for (info.fields) |f| {
                if (std.mem.eql(u8, f.name, fi.name)) {
                    field = f;
                    break;
                }
            }
            const f = field orelse {
                try self.print("    # ERROR: {s} has no field {s}\n", .{ info.name, fi.name });
                continue;
            };
            // An aggregate field is written in place — it has no value to
            // load into a register, only a destination to fill.
            if (fi.value.* == .ArrayLiteral or fi.value.* == .ArrayRepeat or
                fi.value.* == .StructLiteral)
            {
                try self.writeAll("    pushq %rdi\n");
                try self.writeAll("    movq %rdi, %rax\n");
                if (f.offset > 0) try self.print("    addq ${d}, %rax\n", .{f.offset});
                if (fi.value.* == .StructLiteral) {
                    try self.writeAll("    pushq %rax\n");
                    try self.emitStructLiteralToMemory(f.type_name, fi.value.StructLiteral);
                } else {
                    try self.emitArrayLiteralToMemory(f.type_name, fi.value);
                }
                try self.writeAll("    popq %rdi\n");
                continue;
            }

            // Base address survives the field's value expression.
            try self.writeAll("    pushq %rdi\n");
            try self.generateExpr(fi.value);
            try self.writeAll("    popq %rdi\n");
            if (storeFor(f.size) == null) {
                // Wide fields — arrays, nested structs — do not fit in a
                // register. %rax holds the source address, %rdi the
                // destination; copy the field's own width.
                try self.print("    addq ${d}, %rdi\n", .{f.offset});
                try self.writeAll("    movq %rax, %rsi\n");
                try self.print("    movq ${d}, %rcx\n", .{f.size});
                try self.writeAll("    cld\n");
                try self.writeAll("    rep movsb\n");
                // %rdi advanced; recompute it for the next field.
                try self.writeAll("    subq %rcx, %rdi\n");
                try self.print("    subq ${d}, %rdi\n", .{f.offset});
                continue;
            }
            const st = storeFor(f.size) orelse {
                // Unreachable: the null case is handled above.
                try self.print("    # ERROR: cannot lower field {s}.{s} of {d} bytes\n", .{ info.name, f.name, f.size });
                continue;
            };
            try self.print("    {s} %{s}, {d}(%rdi)\n", .{ st.insn, st.reg, f.offset });
        }
    }

    /// Evaluate `value` and store it at the address in %rax.
    /// Write an array literal or repeat into the destination address in %rax.
    /// The address is preserved across each element's value expression.
    fn emitArrayLiteralToMemory(
        self: *HomeKernelCodegen,
        type_name: []const u8,
        value: *const ast.Expr,
    ) anyerror!void {
        const arr = self.arrayType(splitAlign(type_name).bare) orelse {
            try self.print("    # ERROR: array literal needs an array-typed destination, not {s}\n", .{type_name});
            return;
        };
        const elem_size = self.sizeOf(arr.elem_type) orelse {
            try self.print("    # ERROR: array element type {s} has unknown size\n", .{arr.elem_type});
            return;
        };
        const st = storeFor(elem_size) orelse {
            try self.print("    # ERROR: cannot store array elements of {d} bytes\n", .{elem_size});
            return;
        };

        try self.writeAll("    pushq %rax\n"); // base address

        switch (value.*) {
            .ArrayLiteral => |lit| {
                for (lit.elements, 0..) |elem, i| {
                    if (i >= arr.count) {
                        try self.print("    # ERROR: array literal has more elements than the {d} declared\n", .{arr.count});
                        break;
                    }
                    try self.generateExpr(elem);
                    try self.writeAll("    movq (%rsp), %rdx\n");
                    if (i > 0) try self.print("    addq ${d}, %rdx\n", .{i * elem_size});
                    try self.print("    {s} %{s}, (%rdx)\n", .{ st.insn, st.reg });
                }
                // Elements the literal does not mention read as zero.
                var i: usize = lit.elements.len;
                while (i < arr.count) : (i += 1) {
                    try self.writeAll("    movq (%rsp), %rdx\n");
                    if (i > 0) try self.print("    addq ${d}, %rdx\n", .{i * elem_size});
                    try self.writeAll("    xorq %rax, %rax\n");
                    try self.print("    {s} %{s}, (%rdx)\n", .{ st.insn, st.reg });
                }
            },
            .ArrayRepeat => |rep| {
                // `[0; N]` — one value, repeated. Evaluate it once: repeating
                // the expression would repeat its side effects too.
                try self.generateExpr(rep.value);
                try self.writeAll("    movq %rax, %rsi\n");
                var i: usize = 0;
                while (i < arr.count) : (i += 1) {
                    try self.writeAll("    movq (%rsp), %rdx\n");
                    if (i > 0) try self.print("    addq ${d}, %rdx\n", .{i * elem_size});
                    try self.writeAll("    movq %rsi, %rax\n");
                    try self.print("    {s} %{s}, (%rdx)\n", .{ st.insn, st.reg });
                }
            },
            else => {},
        }

        try self.writeAll("    popq %rax\n");
    }

    fn emitStoreToAddress(
        self: *HomeKernelCodegen,
        type_name: []const u8,
        value: *const ast.Expr,
    ) !void {
        const size = self.sizeOf(type_name) orelse 8;

        // A struct literal is lowered field-by-field straight into the
        // destination; no intermediate copy exists anywhere.
        if (value.* == .StructLiteral) {
            try self.writeAll("    pushq %rax\n");
            try self.emitStructLiteralToMemory(type_name, value.StructLiteral);
            return;
        }

        // An array literal or repeat is written element by element into the
        // destination. Like a struct literal it is storage, not a value, so
        // there is nothing to copy it *from* — it only exists once written.
        if (value.* == .ArrayLiteral or value.* == .ArrayRepeat) {
            try self.emitArrayLiteralToMemory(type_name, value);
            return;
        }

        // A call returning an aggregate writes straight into the destination:
        // the address already in %rax becomes the hidden first argument that
        // the callee copies through. No temporary, and no assumption about
        // where a returned struct lives — there is nowhere for it to live but
        // the destination.
        if (self.isStorageType(type_name) and value.* == .CallExpr) {
            const call = value.CallExpr;
            if (call.callee.* == .Identifier) {
                const callee = call.callee.Identifier.name;
                if (self.fn_return_types.get(callee)) |rt| {
                    if (self.isStorageType(rt) and self.declared_fns.contains(callee)) {
                        try self.writeAll("    pushq %rax\n"); // destination
                        // The hidden pointer takes %rdi, so the declared
                        // arguments start one register later.
                        const sret_arg_regs = [_][]const u8{ "rsi", "rdx", "rcx", "r8", "r9" };
                        var words: usize = 0;
                        var i: usize = call.args.len;
                        while (i > 0) {
                            i -= 1;
                            words += try self.pushArgument(call.args[i]);
                        }
                        for (0..words) |reg_idx| {
                            if (reg_idx >= sret_arg_regs.len) break;
                            try self.print("    popq %{s}\n", .{sret_arg_regs[reg_idx]});
                        }
                        try self.writeAll("    popq %rdi\n");
                        try self.print("    call {s}\n", .{callee});
                        return;
                    }
                }
            }
        }

        // A struct or array does not fit in a register: assigning one is a
        // memory copy. Both sides are addresses. When the source is a plain
        // addressable form its address is emitted; anything else (a call
        // returning a struct, say) is evaluated first — the convention is
        // that such an expression leaves the struct's address in %rax — and
        // copied out of immediately, before that storage can go stale.
        if (self.isStorageType(type_name)) {
            try self.writeAll("    pushq %rax\n");           // destination
            if (try self.emitAddress(value)) |_| {
                try self.writeAll("    movq %rax, %rsi\n");      // source
                try self.writeAll("    popq %rdi\n");            // destination
            } else {
                try self.generateExpr(value);
                try self.writeAll("    movq %rax, %rsi\n");
                try self.writeAll("    popq %rdi\n");
            }
            try self.print("    movq ${d}, %rcx\n", .{size});
            try self.writeAll("    cld\n");
            try self.writeAll("    rep movsb\n");
            return;
        }

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

        const symbol = try std.fmt.allocPrint(
            self.import_arena.allocator(),
            GLOBAL_SYMBOL_PREFIX ++ "{s}",
            .{decl.name},
        );

        if (self.arrayType(type_name)) |arr| {
            const elem = self.sizeOf(arr.elem_type) orelse return false;
            try self.global_vars.put(decl.name, .{
                .name = decl.name,
                .symbol = symbol,
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
                .symbol = symbol,
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
            .symbol = symbol,
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
                try self.print("{s}:\n", .{g.symbol});
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
                try self.print("{s}:\n", .{g.symbol});
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
            .MemberExpr => |m| {
                if (m.object.* != .Identifier) return null;
                const enum_name = m.object.Identifier.name;
                if (!self.enum_sizes.contains(enum_name)) return null;
                const key = std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ enum_name, m.member }) catch return null;
                defer self.allocator.free(key);
                return self.enum_values.get(key);
            },
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

    /// Push one call argument, returning how many machine words it occupies.
    /// Pushes happen in reverse argument order, so within a slice the length
    /// is pushed first and the pointer second — leaving the pointer on top,
    /// which is what pops into the lower-numbered register.
    fn pushArgument(self: *HomeKernelCodegen, arg: *const ast.Expr) anyerror!usize {
        // A string literal used where a slice is expected carries its length
        // with it: the length is known at compile time.
        if (arg.* == .StringLiteral) {
            try self.print("    movq ${d}, %rax\n", .{arg.StringLiteral.value.len});
            try self.writeAll("    pushq %rax\n");
            try self.generateExpr(arg);
            try self.writeAll("    pushq %rax\n");
            return 2;
        }
        // `ptr[0..len]` passed to a `[]T` parameter travels as the pair the
        // callee expects. Length first, pointer second: pushes happen in
        // reverse argument order, so this leaves the pointer on top, which is
        // what pops into the lower-numbered register.
        if (arg.* == .SliceExpr) {
            try self.emitSliceLength(arg.SliceExpr);
            try self.writeAll("    pushq %rax\n");
            _ = try self.emitSliceDataPointer(arg.SliceExpr) orelse {
                try self.writeAll("    movq $0, %rax\n");
            };
            try self.writeAll("    pushq %rax\n");
            return 2;
        }
        if (self.typeOfLValue(arg)) |t| {
            const bare = splitAlign(t).bare;
            if (isSliceType(bare)) {
                // Pass the pair through unchanged.
                _ = try self.emitAddress(arg) orelse {
                    try self.writeAll("    pushq %rax\n");
                    return 1;
                };
                try self.writeAll("    pushq %rax\n");           // save slice address
                try self.print("    movq {d}(%rax), %rax\n", .{SLICE_LEN_OFFSET});
                try self.writeAll("    movq %rax, %rcx\n");
                try self.writeAll("    popq %rax\n");
                try self.writeAll("    pushq %rcx\n");            // length
                try self.writeAll("    movq (%rax), %rax\n");     // data pointer
                try self.writeAll("    pushq %rax\n");
                return 2;
            }
            if (self.arrayType(bare)) |arr| {
                // A fixed array decays to (pointer, length).
                try self.print("    movq ${d}, %rax\n", .{arr.count});
                try self.writeAll("    pushq %rax\n");
                try self.generateExpr(arg);
                try self.writeAll("    pushq %rax\n");
                return 2;
            }
        }
        try self.generateExpr(arg);
        try self.writeAll("    pushq %rax\n");
        return 1;
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

    /// Narrow %rax to the width of `type_name`, if that width is known and
    /// smaller than a word. A widening or same-width cast needs no work: the
    /// value is already in %rax.
    fn emitNarrowTo(self: *HomeKernelCodegen, type_name: []const u8) !void {
        const bare = splitAlign(type_name).bare;
        const size = self.sizeOf(bare) orelse return;
        if (size >= 8) return;
        const signed = bare.len > 0 and bare[0] == 'i';
        const insn = switch (size) {
            1 => if (signed) "movsbq %al, %rax" else "movzbq %al, %rax",
            2 => if (signed) "movswq %ax, %rax" else "movzwq %ax, %rax",
            4 => if (signed) "movslq %eax, %rax" else "movl %eax, %eax",
            else => return,
        };
        try self.print("    {s}\n", .{insn});
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
                    // Prefer the written type; otherwise infer it from the
                    // initializer, which is how most locals in this tree are
                    // declared. Without this, every `let s = something()` had
                    // no type and every later `s.field` was refused.
                    var declared: ?[]const u8 = decl.type_name;
                    if (declared == null) {
                        if (decl.value) |v| declared = self.typeOfLValue(v);
                    }
                    if (declared) |tn| {
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
                .ReturnStmt => |s2| {
                    if (s2.value) |v| try self.reserveLocalsInExpr(v);
                },
                .ExprStmt => |e| try self.reserveLocalsInExpr(e),
                else => {},
            }
            // A declaration's initializer can itself contain declarations:
            // `let p = if c { a() } else { let tmp = f(); g(tmp) }`. Those
            // need frame slots too.
            if (stmt == .LetDecl) {
                if (stmt.LetDecl.value) |v| try self.reserveLocalsInExpr(v);
            }
        }
    }

    /// Reserve frame slots for declarations nested inside an expression.
    /// Since if-expression branches became blocks, a `let` can live inside
    /// one — and a local with no frame slot is a hard error at every use.
    fn reserveLocalsInExpr(self: *HomeKernelCodegen, expr: *const ast.Expr) anyerror!void {
        switch (expr.*) {
            .IfExpr => |ie| {
                try self.reserveLocalsInExpr(ie.condition);
                try self.reserveLocalsInExpr(ie.then_branch);
                try self.reserveLocalsInExpr(ie.else_branch);
            },
            .TernaryExpr => |t| {
                try self.reserveLocalsInExpr(t.condition);
                try self.reserveLocalsInExpr(t.true_val);
                try self.reserveLocalsInExpr(t.false_val);
            },
            .BlockExpr => |b| try self.reserveLocals(b.statements),
            else => {},
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

        // Pre-passes, in dependency order. Each one needs the previous:
        //   names assigned to  ->  which bindings are constants
        //   constants          ->  array lengths written as `[SIZE]T`
        //   array lengths      ->  struct field sizes and offsets
        //   struct layouts     ->  global sizes, strides, field offsets
        for (program.statements) |stmt| {
            if (stmt == .FnDecl) {
                // Two definitions of one name emit two labels with it, and
                // the assembler rejects the whole file with no indication of
                // which source line is at fault. Say so here instead.
                if (!stmt.FnDecl.is_forward_decl and self.declared_fns.contains(stmt.FnDecl.name)) {
                    try self.print(
                        "# ERROR: {s} is defined more than once in this module\n",
                        .{stmt.FnDecl.name},
                    );
                }
                try self.declared_fns.put(stmt.FnDecl.name, {});
                if (stmt.FnDecl.return_type) |rt| {
                    try self.fn_return_types.put(stmt.FnDecl.name, rt);
                }
                try self.collectAssignedNames(stmt.FnDecl.body.statements);
            }
        }
        // Imported type declarations first: a struct in this file may have a
        // field of a type declared in another module, and until that type can
        // be sized the *whole* struct is unlayoutable — not just the field.
        try self.collectImports(program, 0);

        try self.foldModuleConstants(program);
        try self.collectEnums(program);
        try self.layoutStructs(program);

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
                // A slice parameter is two words — pointer then length — so
                // it occupies two argument registers and two frame words.
                // A function returning an aggregate does not return it in a
                // register: the caller passes the address of the destination
                // as a hidden first argument, and the callee copies into it.
                self.sret_slot = 0;
                self.current_return_type = func.return_type orelse "";
                if (func.return_type) |rt| {
                    if (self.isStorageType(rt)) {
                        self.stack_offset -= 8;
                        self.sret_slot = self.stack_offset;
                    }
                }

                for (func.params) |param| {
                    try self.local_types.put(param.name, param.type_name);
                    const words: i32 = if (isSliceType(splitAlign(param.type_name).bare)) 2 else 1;
                    self.stack_offset -= words * 8;
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
                var reg_index: usize = 0;
                if (self.sret_slot != 0) {
                    try self.print("    movq %rdi, {d}(%rbp)\n", .{self.sret_slot});
                    reg_index = 1;
                }
                for (func.params) |param| {
                    const slot = self.locals.get(param.name) orelse continue;
                    const words: usize = if (isSliceType(splitAlign(param.type_name).bare)) 2 else 1;
                    var w: usize = 0;
                    while (w < words) : (w += 1) {
                        const dest = slot + @as(i32, @intCast(w * 8));
                        if (reg_index < arg_regs.len) {
                            try self.print("    movq %{s}, {d}(%rbp)\n", .{ arg_regs[reg_index], dest });
                        } else {
                            // Arguments past the registers arrive above the
                            // return address.
                            const caller_offset = 16 + (reg_index - arg_regs.len) * 8;
                            try self.print("    movq {d}(%rbp), %rax\n", .{caller_offset});
                            try self.print("    movq %rax, {d}(%rbp)\n", .{dest});
                        }
                        reg_index += 1;
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
                // The written type is preferred; an inferred binding whose
                // initializer reveals a storage type (a struct literal, say)
                // gets the same treatment — the slot was sized for it.
                var storage_type: ?[]const u8 = decl.type_name;
                if (storage_type == null) {
                    if (decl.value) |v| {
                        if (v.* == .StructLiteral) {
                            storage_type = v.StructLiteral.type_name;
                        } else if (self.local_types.get(decl.name)) |inferred| {
                            storage_type = inferred;
                        }
                    }
                }
                if (storage_type) |tn| {
                    if (self.isStorageType(tn)) {
                        // `let buf: [N]u8 = undefined` reserves storage and
                        // initializes nothing. An initializer that is itself
                        // an aggregate is copied into the slot.
                        if (decl.value) |value| {
                            if (value.* == .StructLiteral) {
                                if (self.locals.get(decl.name)) |slot| {
                                    try self.print("    leaq {d}(%rbp), %rax\n", .{slot});
                                    try self.emitStructLiteralToMemory(tn, value.StructLiteral);
                                }
                            } else if (value.* == .ArrayLiteral or value.* == .ArrayRepeat) {
                                if (self.locals.get(decl.name)) |slot| {
                                    try self.print("    leaq {d}(%rbp), %rax\n", .{slot});
                                    try self.emitArrayLiteralToMemory(tn, value);
                                }
                            } else if (self.typeOfLValue(value) != null) {
                                if (self.locals.get(decl.name)) |slot| {
                                    try self.print("    leaq {d}(%rbp), %rax\n", .{slot});
                                    try self.emitStoreToAddress(tn, value);
                                }
                            }
                        }
                        return;
                    }
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
                    if (self.sret_slot != 0) {
                        // Copy into the caller's destination and hand the
                        // pointer back in %rax, as the ABI expects.
                        try self.print("    movq {d}(%rbp), %rax\n", .{self.sret_slot});
                        if (value.* == .StructLiteral) {
                            try self.writeAll("    pushq %rax\n");
                            try self.emitStructLiteralToMemory(
                                self.current_return_type,
                                value.StructLiteral,
                            );
                        } else if (self.typeOfLValue(value) != null) {
                            try self.writeAll("    pushq %rax\n");
                            if (try self.emitAddress(value)) |_| {
                                try self.writeAll("    movq %rax, %rsi\n");
                                try self.writeAll("    popq %rdi\n");
                                try self.print("    movq ${d}, %rcx\n", .{self.sizeOf(self.current_return_type) orelse 8});
                                try self.writeAll("    cld\n");
                                try self.writeAll("    rep movsb\n");
                            } else {
                                try self.writeAll("    addq $8, %rsp\n");
                            }
                        } else {
                            try self.print("    # ERROR: cannot return a {s} built from this expression\n", .{self.current_return_type});
                        }
                        try self.print("    movq {d}(%rbp), %rax\n", .{self.sret_slot});
                        if (self.current_fn.len > 0) {
                            try self.print("    jmp .L_epilogue_{s}\n", .{self.current_fn});
                            return;
                        }
                    }
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
            .SwitchStmt => |sw| {
                // Match-style switch statement: `switch x { pat => {...}, _ => {...} }`.
                // Lowered as a comparison chain: all comparisons first, then
                // all bodies — so a non-matching clause falls through to the
                // next comparison, never into a foreign body. The scrutinee
                // is evaluated once and kept on the stack. Case bodies do
                // not fall through; `break` inside a case continues to
                // target the enclosing loop.
                const label_num = self.freshLabel();
                const end_label = try std.fmt.allocPrint(self.allocator, ".L_switch_end_{d}", .{label_num});
                defer self.allocator.free(end_label);

                try self.generateExpr(sw.value);
                try self.writeAll("    pushq %rax\n");

                // Pass 1: one body label per non-default clause, then all
                // the comparisons.
                const BodyLabel = struct { label: []const u8, clause_idx: usize };
                // Unmanaged ArrayList: this Zig version takes the allocator
                // per call rather than storing it.
                var bodies: std.ArrayList(BodyLabel) = .{ .items = &[_]BodyLabel{}, .capacity = 0 };
                defer {
                    for (bodies.items) |b| self.allocator.free(b.label);
                    bodies.deinit(self.allocator);
                }
                var default_clause: ?usize = null;
                for (sw.cases, 0..) |clause, idx| {
                    if (clause.is_default) {
                        default_clause = idx;
                    } else {
                        const lbl = try std.fmt.allocPrint(self.allocator, ".L_switch_case_{d}_{d}", .{ label_num, idx });
                        try bodies.append(self.allocator, .{ .label = lbl, .clause_idx = idx });
                    }
                }

                for (bodies.items) |b| {
                    const clause = sw.cases[b.clause_idx];
                    for (clause.patterns) |pattern| {
                        // Pattern into %rax, saved to %rcx; scrutinee loaded
                        // from the stack; compare and branch on equality.
                        try self.generateExpr(pattern);
                        try self.writeAll("    movq %rax, %rcx\n");
                        try self.writeAll("    movq (%rsp), %rax\n");
                        try self.writeAll("    cmpq %rcx, %rax\n");
                        try self.print("    je {s}\n", .{b.label});
                    }
                }
                if (default_clause) |di| {
                    try self.print("    jmp .L_switch_case_{d}_{d}\n", .{ label_num, di });
                }
                try self.print("    jmp {s}\n", .{end_label});

                // Pass 2: bodies, each closed with a jump to the end.
                for (bodies.items) |b| {
                    try self.print("{s}:\n", .{b.label});
                    const clause = sw.cases[b.clause_idx];
                    for (clause.body) |body_stmt| {
                        try self.generateStmt(body_stmt);
                    }
                    try self.print("    jmp {s}\n", .{end_label});
                }
                if (default_clause) |di| {
                    try self.print(".L_switch_case_{d}_{d}:\n", .{ label_num, di });
                    for (sw.cases[di].body) |body_stmt| {
                        try self.generateStmt(body_stmt);
                    }
                    try self.print("    jmp {s}\n", .{end_label});
                }

                try self.print("{s}:\n", .{end_label});
                try self.writeAll("    addq $8, %rsp\n");
            },
            // Declarations that describe types or module structure emit no
            // code by design; they are consumed by the pre-passes.
            .ImportDecl, .StructDecl, .EnumDecl, .TypeAliasDecl, .TraitDecl, .ImplDecl => {},
            else => {
                // Same rule as expressions: a statement that emits nothing
                // reads as working code. Say what was dropped.
                try self.print("# ERROR: unsupported statement: {s}\n", .{@tagName(stmt)});
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
                            // Evaluate arguments in reverse and push, then pop
                            // into the ABI registers in order. A slice
                            // argument contributes two words, pointer then
                            // length, matching how the callee spills them.
                            var words: usize = 0;
                            var i: usize = call.args.len;
                            while (i > 0) {
                                i -= 1;
                                words += try self.pushArgument(call.args[i]);
                            }
                            for (0..words) |reg_idx| {
                                if (reg_idx < arg_regs.len) {
                                    try self.print("    popq %{s}\n", .{arg_regs[reg_idx]});
                                } else {
                                    // Arguments beyond six stay on the stack.
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
                // A bitfield member is a bit range inside an integer, not a
                // value at a byte offset: load the whole backing integer,
                // shift it down, and mask.
                if (expr.* == .MemberExpr) {
                    if (try self.bitFieldOf(expr.MemberExpr)) |bf| {
                        const addr_type = try self.emitAddress(expr.MemberExpr.object) orelse {
                            try self.writeAll("    movq $0, %rax\n");
                            return;
                        };
                        _ = addr_type;
                        try self.emitLoadBacking(bf.container_size);
                        if (bf.field.bit_offset > 0) {
                            try self.print("    shrq ${d}, %rax\n", .{bf.field.bit_offset});
                        }
                        if (bf.field.bit_width < 64) {
                            const mask: u64 = (@as(u64, 1) << @intCast(bf.field.bit_width)) - 1;
                            try self.print("    movabsq ${d}, %rcx\n", .{@as(i64, @bitCast(mask))});
                            try self.writeAll("    andq %rcx, %rax\n");
                        }
                        return;
                    }
                }
                // `Enum.Variant` is a compile-time constant, not a field read.
                if (expr.* == .MemberExpr) {
                    const m = expr.MemberExpr;
                    if (m.object.* == .Identifier) {
                        const enum_name = m.object.Identifier.name;
                        if (self.enum_sizes.contains(enum_name)) {
                            const key = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ enum_name, m.member });
                            defer self.allocator.free(key);
                            if (self.enum_values.get(key)) |v| {
                                try self.print("    movq ${d}, %rax\n", .{v});
                                return;
                            }
                            try self.print("    # ERROR: enum {s} has no variant {s}\n", .{ enum_name, m.member });
                            try self.writeAll("    movq $0, %rax\n");
                            return;
                        }
                    }
                }
                // `arr.len` on a fixed-size array is a compile-time constant,
                // not a field read: there is no length word to load.
                if (expr.* == .MemberExpr) {
                    const m = expr.MemberExpr;
                    if (std.mem.eql(u8, m.member, "len")) {
                        if (self.typeOfLValue(m.object)) |bt| {
                            if (self.arrayType(splitAlign(bt).bare)) |arr| {
                                try self.print("    movq ${d}, %rax\n", .{arr.count});
                                return;
                            }
                        }
                    }
                }
                // Address into %rax, then load the value it points at.
                const t = try self.emitAddress(expr) orelse {
                    try self.writeAll("    movq $0, %rax\n");
                    return;
                };
                try self.emitLoadFromAddress(t);
            },
            .UnaryExpr => |unary| {
                // `&x` is the address of an lvalue, not a value computation.
                if (unary.op == .AddressOf or unary.op == .Borrow or unary.op == .BorrowMut) {
                    _ = try self.emitAddress(unary.operand) orelse {
                        try self.writeAll("    movq $0, %rax\n");
                    };
                    return;
                }
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
                                try self.print("    {s} %{s}, {s}(%rip)\n", .{ st.insn, st.reg, g.symbol });
                            } else {
                                try self.print("    # ERROR: cannot store {s} of size {d}\n", .{ g.name, g.size });
                            }
                        } else if (self.globals.contains(target.name)) {
                            try self.print("    # ERROR: {s} is a constant and cannot be assigned to\n", .{target.name});
                        } else {
                            try self.print("    # ERROR: assignment to undefined variable {s}\n", .{target.name});
                        }
                    },
                    .MemberExpr => |m| {
                        // A bitfield member is read-modify-write: clear its
                        // bit range in the backing integer, then OR the new
                        // value in. Storing at a byte offset would clobber
                        // every neighbouring field.
                        if (try self.bitFieldOf(m)) |bf| {
                            _ = try self.emitAddress(m.object) orelse return;
                            try self.writeAll("    pushq %rax\n");        // container address
                            try self.generateExpr(assign.value);
                            const mask: u64 = if (bf.field.bit_width >= 64)
                                std.math.maxInt(u64)
                            else
                                (@as(u64, 1) << @intCast(bf.field.bit_width)) - 1;
                            try self.print("    movabsq ${d}, %rcx\n", .{@as(i64, @bitCast(mask))});
                            try self.writeAll("    andq %rcx, %rax\n");   // value, truncated
                            if (bf.field.bit_offset > 0) {
                                try self.print("    shlq ${d}, %rax\n", .{bf.field.bit_offset});
                            }
                            try self.writeAll("    movq %rax, %rsi\n");   // shifted value
                            try self.writeAll("    popq %rdx\n");         // container address
                            try self.writeAll("    pushq %rdx\n");
                            try self.writeAll("    movq %rdx, %rax\n");
                            try self.emitLoadBacking(bf.container_size);
                            const shifted_mask: u64 = if (bf.field.bit_offset >= 64)
                                0
                            else
                                mask << @intCast(bf.field.bit_offset);
                            try self.print("    movabsq ${d}, %rcx\n", .{@as(i64, @bitCast(~shifted_mask))});
                            try self.writeAll("    andq %rcx, %rax\n");   // clear the range
                            try self.writeAll("    orq %rsi, %rax\n");    // insert
                            try self.writeAll("    popq %rdx\n");
                            const st = storeFor(bf.container_size) orelse {
                                try self.print("    # ERROR: cannot store a bitfield container of {d} bytes\n", .{bf.container_size});
                                return;
                            };
                            try self.print("    {s} %{s}, (%rdx)\n", .{ st.insn, st.reg });
                            return;
                        }
                        const t = try self.emitAddress(assign.target) orelse return;
                        try self.emitStoreToAddress(t, assign.value);
                    },
                    else => {
                        // Index and dereference targets reduce to "compute an
                        // address, store through it".
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
                        try self.print("    leaq {s}(%rip), %rax\n", .{g.symbol});
                    } else if (loadFor(g.size)) |ld| {
                        if (g.size < 8) try self.writeAll("    xorq %rax, %rax\n");
                        try self.print("    {s} {s}(%rip), %{s}\n", .{ ld.insn, g.symbol, ld.reg });
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
            .SliceExpr => |sl| {
                // A slice value in a register position is its data pointer.
                // The length only travels when the slice is passed to a
                // parameter that declares one — see pushArgument.
                _ = try self.emitSliceDataPointer(sl) orelse {
                    try self.writeAll("    movq $0, %rax\n");
                };
            },
            .ArrayLiteral => |lit| {
                // An array literal is storage, so as a bare expression there
                // is nowhere to put it. The declaration and assignment paths
                // write the elements straight into the destination.
                try self.print("    # ERROR: array literal of {d} elements needs a destination\n", .{lit.elements.len});
                try self.writeAll("    movq $0, %rax\n");
            },
            .StructLiteral => |lit| {
                // A bitfield struct literal is just an integer: shift each
                // field's value into place and OR them together. This is what
                // `PageFlags { present: true, address: n, ... }` means.
                if (self.structs.get(splitAlign(lit.type_name).bare)) |info| {
                    if (info.is_bitfield) {
                        try self.writeAll("    xorq %rax, %rax\n");
                        try self.writeAll("    pushq %rax\n");     // accumulator
                        for (lit.fields) |fi| {
                            const field = blk: {
                                for (info.fields) |f| {
                                    if (std.mem.eql(u8, f.name, fi.name)) break :blk f;
                                }
                                try self.print("    # ERROR: {s} has no field {s}\n", .{ info.name, fi.name });
                                break :blk null;
                            } orelse continue;

                            try self.generateExpr(fi.value);
                            const mask: u64 = if (field.bit_width >= 64)
                                std.math.maxInt(u64)
                            else
                                (@as(u64, 1) << @intCast(field.bit_width)) - 1;
                            try self.print("    movabsq ${d}, %rcx\n", .{@as(i64, @bitCast(mask))});
                            try self.writeAll("    andq %rcx, %rax\n");
                            if (field.bit_offset > 0) {
                                try self.print("    shlq ${d}, %rax\n", .{field.bit_offset});
                            }
                            try self.writeAll("    popq %rcx\n");
                            try self.writeAll("    orq %rcx, %rax\n");
                            try self.writeAll("    pushq %rax\n");
                        }
                        try self.writeAll("    popq %rax\n");
                        return;
                    }
                }
                // A bare struct literal materializes on the stack and leaves
                // its address in %rax — the same "structs are storage" rule
                // loads use. The LetDecl and assignment paths bypass this
                // and write fields straight into the destination slot.
                if (self.structs.get(splitAlign(lit.type_name).bare)) |info| {
                    const aligned = (info.size + 15) / 16 * 16;
                    try self.print("    subq ${d}, %rsp\n", .{aligned});
                    try self.writeAll("    pushq %rsp\n");
                    try self.emitStructLiteralToMemory(lit.type_name, lit);
                    try self.writeAll("    movq %rsp, %rax\n");
                    return;
                }
                try self.print("    # ERROR: struct literal of unknown type {s}\n", .{lit.type_name});
                try self.writeAll("    movq $0, %rax\n");
            },
            .CharLiteral => |lit| {
                // The lexeme still carries its quotes and any escape.
                if (charLiteralValue(lit.value)) |v| {
                    try self.print("    movq ${d}, %rax\n", .{v});
                } else {
                    try self.print("    # ERROR: unsupported character literal {s}\n", .{lit.value});
                    try self.writeAll("    movq $0, %rax\n");
                }
            },
            .NullLiteral => {
                try self.writeAll("    movq $0, %rax\n");
            },
            .TypeCastExpr => |cast| {
                try self.generateExpr(cast.value);
                try self.emitNarrowTo(cast.target_type);
            },
            .ReflectExpr => |r| {
                switch (r.kind) {
                    // Pointer and bit reinterpretations are no-ops on a
                    // 64-bit value: the bits are already in %rax.
                    .IntFromPtr, .PtrFromInt, .PtrToInt, .PtrCast, .BitCast => {
                        try self.generateExpr(r.target);
                    },
                    // Width changes: evaluate, then narrow to the named type.
                    .Truncate, .IntCast, .As, .EnumToInt, .IntToEnum => {
                        try self.generateExpr(r.target);
                        if (r.target_type) |t| try self.emitNarrowTo(t);
                    },
                    .TypeOf => {
                        // @TypeOf is only meaningful inside another builtin;
                        // on its own it has no runtime value.
                        try self.writeAll("    # ERROR: @TypeOf has no value outside @sizeOf / @alignOf\n");
                        try self.writeAll("    movq $0, %rax\n");
                    },
                    .SizeOf => {
                        if (r.target_type orelse self.typeArgOf(r.target)) |t| {
                            if (self.sizeOf(t)) |n| {
                                try self.print("    movq ${d}, %rax\n", .{n});
                                return;
                            }
                        }
                        try self.writeAll("    # ERROR: @sizeOf of an unknown type\n");
                        try self.writeAll("    movq $0, %rax\n");
                    },
                    .AlignOf => {
                        if (r.target_type orelse self.typeArgOf(r.target)) |t| {
                            try self.print("    movq ${d}, %rax\n", .{self.alignOf(t)});
                            return;
                        }
                        try self.writeAll("    # ERROR: @alignOf of an unknown type\n");
                        try self.writeAll("    movq $0, %rax\n");
                    },
                    .OffsetOf => {
                        if (r.target_type orelse self.typeArgOf(r.target)) |t| {
                            if (r.field_name) |fname| {
                                if (self.findField(t, fname)) |f| {
                                    try self.print("    movq ${d}, %rax\n", .{f.offset});
                                    return;
                                }
                            }
                        }
                        try self.writeAll("    # ERROR: @offsetOf of an unknown field\n");
                        try self.writeAll("    movq $0, %rax\n");
                    },
                    .Min, .Max => {
                        const second = r.second_arg orelse {
                            try self.print("    # ERROR: {s} needs two arguments\n", .{@tagName(r.kind)});
                            return;
                        };
                        try self.generateExpr(r.target);
                        try self.writeAll("    pushq %rax\n");
                        try self.generateExpr(second);
                        try self.writeAll("    movq %rax, %rcx\n");
                        try self.writeAll("    popq %rax\n");
                        try self.writeAll("    cmpq %rcx, %rax\n");
                        if (r.kind == .Min) {
                            try self.writeAll("    cmovgq %rcx, %rax\n");
                        } else {
                            try self.writeAll("    cmovlq %rcx, %rax\n");
                        }
                    },
                    .Abs => {
                        try self.generateExpr(r.target);
                        try self.writeAll("    movq %rax, %rcx\n");
                        try self.writeAll("    negq %rcx\n");
                        try self.writeAll("    cmpq %rcx, %rax\n");
                        try self.writeAll("    cmovlq %rcx, %rax\n");
                    },
                    else => {
                        // Floating-point and type-introspection builtins have
                        // no lowering in a freestanding integer backend.
                        try self.print("    # ERROR: unsupported builtin: {s}\n", .{@tagName(r.kind)});
                        try self.writeAll("    movq $0, %rax\n");
                    },
                }
            },
            .IfExpr => |if_expr| {
                // `let x = if c { a() } else { b() }` — a value, not a
                // statement. This used to fall through to the silent default
                // below, so the initializer emitted nothing at all and the
                // binding took whatever happened to be in %rax.
                const label_num = self.freshLabel();
                try self.generateExpr(if_expr.condition);
                try self.writeAll("    testq %rax, %rax\n");
                try self.print("    jz .L_ifexpr_else_{d}\n", .{label_num});
                try self.generateExpr(if_expr.then_branch);
                try self.print("    jmp .L_ifexpr_end_{d}\n", .{label_num});
                try self.print(".L_ifexpr_else_{d}:\n", .{label_num});
                try self.generateExpr(if_expr.else_branch);
                try self.print(".L_ifexpr_end_{d}:\n", .{label_num});
            },
            .TernaryExpr => |t| {
                const label_num = self.freshLabel();
                try self.generateExpr(t.condition);
                try self.writeAll("    testq %rax, %rax\n");
                try self.print("    jz .L_ternary_else_{d}\n", .{label_num});
                try self.generateExpr(t.true_val);
                try self.print("    jmp .L_ternary_end_{d}\n", .{label_num});
                try self.print(".L_ternary_else_{d}:\n", .{label_num});
                try self.generateExpr(t.false_val);
                try self.print(".L_ternary_end_{d}:\n", .{label_num});
            },
            .BlockExpr => |block| {
                // The block's value is its last expression statement, which
                // is whatever it leaves in %rax.
                for (block.statements) |inner| {
                    try self.generateStmt(inner);
                }
            },
            else => {
                // Never silently emit nothing. An expression that produces no
                // code leaves %rax holding the previous computation, so the
                // surrounding statement compiles cleanly and computes the
                // wrong answer — the worst failure mode this backend has.
                try self.print("    # ERROR: unsupported expression: {s}\n", .{@tagName(expr.*)});
                try self.writeAll("    movq $0, %rax\n");
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
