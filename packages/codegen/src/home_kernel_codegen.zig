// Home Kernel Code Generator
// Compiles Home language kernel code to native assembly for a freestanding
// target, with FFI calls to Zig stdlib modules.
//
// The lowering is architecture-neutral: it is a stack machine over the roles
// defined in `kernel_target.zig`, which owns every instruction this file
// emits. To add an architecture, implement it there.

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
const kernel_target = @import("kernel_target.zig");
const Arch = kernel_target.Arch;
const Reg = kernel_target.Reg;
const Cond = kernel_target.Cond;
const BinOp = kernel_target.BinOp;

/// String literal entry for .rodata section
const StringLiteral = struct {
    label: usize,
    content: []const u8,
};

/// A module-level mutable binding, lowered to a symbol in .bss or .data.
/// Kernel subsystems keep their state in these — page bitmaps, counters,
/// descriptor tables — so nothing in kernel/src/ compiles without them.
/// A module's symbol prefix, derived from its file path so that two modules
/// with the same basename — `kernel/src/serial.home` and
/// `kernel/src/drivers/serial.home` — do not collide. Everything outside
/// [A-Za-z0-9_] becomes `_`, and any leading path above the source tree is
/// dropped so the prefix does not depend on where the repository sits.
fn moduleIdFromPath(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    // Resolve `.` and `..` first. An import writes `../mm/buddy.home`, and the
    // same module reached from two directories must yield the same prefix or
    // the caller and the definition disagree about the symbol's name.
    var parts: std.ArrayList([]const u8) = .{ .items = &[_][]const u8{}, .capacity = 0 };
    defer parts.deinit(allocator);
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (parts.items.len > 0) _ = parts.pop();
            continue;
        }
        try parts.append(allocator, seg);
    }

    // Anchor at the last "src" segment so the prefix does not depend on where
    // the repository sits; otherwise fall back to the basename alone.
    var start: usize = if (parts.items.len > 0) parts.items.len - 1 else 0;
    var i: usize = parts.items.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, parts.items[i], "src")) {
            start = i + 1;
            break;
        }
    }

    var total: usize = 0;
    for (parts.items[start..], 0..) |seg, idx| {
        var s2 = seg;
        if (idx == parts.items.len - start - 1 and std.mem.endsWith(u8, s2, ".home")) {
            s2 = s2[0 .. s2.len - 5];
        }
        total += s2.len + (if (idx > 0) @as(usize, 1) else 0);
    }

    const out = try allocator.alloc(u8, total);
    var w: usize = 0;
    for (parts.items[start..], 0..) |seg, idx| {
        var s2 = seg;
        if (idx == parts.items.len - start - 1 and std.mem.endsWith(u8, s2, ".home")) {
            s2 = s2[0 .. s2.len - 5];
        }
        if (idx > 0) {
            out[w] = '_';
            w += 1;
        }
        for (s2) |c| {
            out[w] = if (std.ascii.isAlphanumeric(c) or c == '_') c else '_';
            w += 1;
        }
    }
    return out[0..w];
}

/// The register a constraint names, or null for an any-register class.
/// `{dx}` and `={al}` name one; `r`, `=r`, `+r` do not.
fn registerForConstraint(constraint: []const u8) ?[]const u8 {
    // `{reg}` may be preceded by modifiers — `N{dx}` is written in this tree —
    // so find the brace rather than requiring it at the front.
    if (std.mem.indexOfScalar(u8, constraint, '{')) |open| {
        if (std.mem.indexOfScalarPos(u8, constraint, open, '}')) |close| {
            if (close > open + 1) return constraint[open + 1 .. close];
        }
    }
    // Single-letter GCC register classes.
    var c = constraint;
    while (c.len > 0 and (c[0] == '=' or c[0] == '+' or c[0] == '&')) c = c[1..];
    if (c.len == 1) {
        return switch (c[0]) {
            'a' => "rax",
            'b' => "rbx",
            'c' => "rcx",
            'd' => "rdx",
            'S' => "rsi",
            'D' => "rdi",
            else => null,
        };
    }
    return null;
}

/// The name of `reg`'s enclosing register at the given width.
///
/// The template's mnemonic fixes the operand width — `cmpxchgl` takes a
/// 32-bit register — so substituting a 64-bit name produces an instruction
/// the assembler rejects. Sizes come from the operand's own Home type.
fn sizedRegister(reg: []const u8, size: usize) []const u8 {
    const full = fullRegister(reg);
    const table = [_]struct { q: []const u8, d: []const u8, w: []const u8, b: []const u8 }{
        .{ .q = "rax", .d = "eax", .w = "ax", .b = "al" },
        .{ .q = "rbx", .d = "ebx", .w = "bx", .b = "bl" },
        .{ .q = "rcx", .d = "ecx", .w = "cx", .b = "cl" },
        .{ .q = "rdx", .d = "edx", .w = "dx", .b = "dl" },
        .{ .q = "rsi", .d = "esi", .w = "si", .b = "sil" },
        .{ .q = "rdi", .d = "edi", .w = "di", .b = "dil" },
        .{ .q = "rbp", .d = "ebp", .w = "bp", .b = "bpl" },
        .{ .q = "rsp", .d = "esp", .w = "sp", .b = "spl" },
        .{ .q = "r8", .d = "r8d", .w = "r8w", .b = "r8b" },
        .{ .q = "r9", .d = "r9d", .w = "r9w", .b = "r9b" },
        .{ .q = "r10", .d = "r10d", .w = "r10w", .b = "r10b" },
        .{ .q = "r11", .d = "r11d", .w = "r11w", .b = "r11b" },
        .{ .q = "r12", .d = "r12d", .w = "r12w", .b = "r12b" },
        .{ .q = "r13", .d = "r13d", .w = "r13w", .b = "r13b" },
        .{ .q = "r14", .d = "r14d", .w = "r14w", .b = "r14b" },
        .{ .q = "r15", .d = "r15d", .w = "r15w", .b = "r15b" },
    };
    for (table) |t| {
        if (!std.mem.eql(u8, t.q, full)) continue;
        return switch (size) {
            1 => t.b,
            2 => t.w,
            4 => t.d,
            else => t.q,
        };
    }
    return reg;
}

/// The 64-bit register containing a named sub-register, so a value can be
/// moved with one `movq` regardless of the width the template asks for.
fn fullRegister(reg: []const u8) []const u8 {
    const map = [_]struct { part: []const u8, full: []const u8 }{
        .{ .part = "al", .full = "rax" },   .{ .part = "ax", .full = "rax" },
        .{ .part = "eax", .full = "rax" },  .{ .part = "rax", .full = "rax" },
        .{ .part = "bl", .full = "rbx" },   .{ .part = "bx", .full = "rbx" },
        .{ .part = "ebx", .full = "rbx" },  .{ .part = "rbx", .full = "rbx" },
        .{ .part = "cl", .full = "rcx" },   .{ .part = "cx", .full = "rcx" },
        .{ .part = "ecx", .full = "rcx" },  .{ .part = "rcx", .full = "rcx" },
        .{ .part = "dl", .full = "rdx" },   .{ .part = "dx", .full = "rdx" },
        .{ .part = "edx", .full = "rdx" },  .{ .part = "rdx", .full = "rdx" },
        .{ .part = "sil", .full = "rsi" },  .{ .part = "esi", .full = "rsi" },
        .{ .part = "rsi", .full = "rsi" },  .{ .part = "dil", .full = "rdi" },
        .{ .part = "edi", .full = "rdi" },  .{ .part = "rdi", .full = "rdi" },
    };
    for (map) |m| {
        if (std.mem.eql(u8, m.part, reg)) return m.full;
    }
    return reg;
}

/// Names that must keep an unmangled symbol: they are named by hand-written
/// assembly or by the linker script, which cannot know a module prefix.
///
/// `interrupt_dispatch` and `syscall_entry_dispatch` are called from the stubs in
/// kernel/src/idt_stubs.s, which are written in assembly because an interrupt
/// frame cannot be built in Home. Until a `link_name` attribute exists, a
/// fixed name is the contract between the two.
fn isBootEntryPoint(name: []const u8) bool {
    return std.mem.eql(u8, name, "kernel_main") or
        std.mem.eql(u8, name, "main") or
        std.mem.eql(u8, name, "_start") or
        std.mem.eql(u8, name, "interrupt_dispatch") or
        std.mem.eql(u8, name, "syscall_entry_dispatch");
}

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
    /// Elements of a module-level array literal, emitted as a table in
    /// .data. Kernel tables of message strings are declared this way.
    init_elements: ?[]const *ast.Expr = null,
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
    // A function type in a value position is a function pointer. Matched on
    // the leading `fn` rather than an exact prefix, because the parser
    // reconstructs an alias target's spelling and the exact punctuation that
    // follows is not something this needs to depend on.
    if (std.mem.startsWith(u8, type_name, "fn") and
        (type_name.len == 2 or !std.ascii.isAlphanumeric(type_name[2]))) return 8;
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
    /// Architecture this run is lowering for. Everything architecture-specific
    /// lives behind `kernel_target.Emitter`; this field only selects it.
    arch: Arch,
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
    /// Path of the file being compiled, which the module prefix derives from.
    source_file: ?[]const u8,
    /// Symbol prefix for functions defined in the file being compiled.
    module_id: []const u8,
    /// Import alias -> that module's symbol prefix, so `serial.writeChar()`
    /// can be lowered to the symbol serial.home actually defines.
    module_aliases: std.StringHashMap([]const u8),
    /// Functions declared `extern`. Their symbols are defined outside Home —
    /// by hand-written assembly or another object file — so they keep the name
    /// as written at every reference site. Mangling them produced calls to
    /// module-prefixed symbols that nothing defines.
    extern_fns: std.StringHashMap(void),
    /// Frame slot holding the hidden destination pointer, for a function that
    /// returns an aggregate. 0 means this function does not return one.
    sret_slot: i32,
    /// Declared return type of the function being generated, needed to size
    /// the copy into that destination.
    current_return_type: []const u8,
    /// Interned `*T` names, so pointerTo can return a stable slice.
    pointer_type_names: std.StringHashMap([]const u8),
    /// Type aliases: `type DriverInitFn = fn(): u32`. Resolved wherever a
    /// written type is sized, so an alias is as good as the type it names.
    type_aliases: std.StringHashMap([]const u8),
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
        result.arch = .x86_64;
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
        result.source_file = null;
        result.module_id = "";
        result.module_aliases = std.StringHashMap([]const u8).init(allocator);
        result.extern_fns = std.StringHashMap(void).init(allocator);
        result.type_aliases = std.StringHashMap([]const u8).init(allocator);
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
        // enum_values keys belong to import_arena, which is released below.
        self.enum_values.deinit();
        self.imported_files.deinit();
        self.module_aliases.deinit();
        self.type_aliases.deinit();
        self.pending_structs.deinit(self.allocator);
        self.pointer_type_names.deinit();
        self.import_arena.deinit();
        self.string_literals.deinit(self.allocator);
    }

    /// Helper to write string to output
    fn writeAll(self: *HomeKernelCodegen, bytes: []const u8) !void {
        try self.output.appendSlice(self.allocator, bytes);
    }

    /// The instruction emitter for the selected architecture.
    ///
    /// Constructed per call rather than stored, because it borrows `output`,
    /// which reallocates as the program grows.
    fn emit(self: *HomeKernelCodegen) kernel_target.Emitter {
        return .{ .arch = self.arch, .out = &self.output, .gpa = self.allocator };
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
                const digits = self.text[start..self.pos];
                if (std.fmt.parseInt(i64, digits, 0)) |signed| {
                    return signed;
                } else |_| {}
                // A u64 constant above i64::MAX is not an error, it is a bit
                // pattern with the top bit set — a type tag, a mask, a
                // canonical high-half address. Parsed only as i64 the constant
                // was dropped entirely and every use of it resolved to
                // nothing, which reads as "no such name" rather than as an
                // out-of-range literal.
                if (std.fmt.parseInt(u64, digits, 0)) |unsigned| {
                    return @bitCast(unsigned);
                } else |_| {}
                return null;
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
        // An alias is as good as what it names. A struct field written as a
        // type alias was otherwise unsizable, which makes the *whole* struct
        // unlayoutable — core/driver_init.home lost every field of
        // DriverDescriptor to one `init_fn: DriverInitFn`.
        if (self.resolveAlias(type_name)) |target| return self.sizeOf(target);
        return null;
    }

    /// Follow a type alias to the name it ultimately denotes, or null if this
    /// is not an alias. Bounded, so a cycle (`type A = B` / `type B = A`)
    /// cannot spin.
    fn resolveAlias(self: *HomeKernelCodegen, name: []const u8) ?[]const u8 {
        var current = name;
        var hops: usize = 0;
        while (hops < 8) : (hops += 1) {
            const next = self.type_aliases.get(current) orelse {
                return if (hops == 0) null else current;
            };
            if (std.mem.eql(u8, next, current)) return null;
            current = next;
        }
        return null;
    }

    /// Emit the address of a slice's data pointer's *target* — i.e. load the
    /// pointer word — given the address of the slice itself in %rax.
    fn emitSliceData(self: *HomeKernelCodegen) !void {
        try self.emit().loadIndirect(.acc, .acc, 8, false);
    }

    /// Alignment of a type: its own size for scalars, capped at 8.
    fn alignOf(self: *HomeKernelCodegen, raw: []const u8) usize {
        const split = splitAlign(raw);
        if (split.alignment) |explicit| return explicit;
        const type_name = split.bare;
        if (self.structs.get(type_name)) |info| return info.alignment;
        if (self.resolveAlias(type_name)) |target| return self.alignOf(target);
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

            // An alias belongs to the importer, not to the imported file, so
            // it must be recorded before the visited check below. Registering
            // it after meant that a module already pulled in through some
            // other path — these form a diamond around core/foundation.home —
            // was skipped here and its alias never recorded, so every call
            // through it failed to resolve.
            if (depth == 0) {
                const alias_now = decl.alias orelse resolved.name;
                const imported_id = try moduleIdFromPath(arena, resolved.file_path);
                try self.module_aliases.put(alias_now, imported_id);
            }

            // Collect each file's declarations once: cycles exist.
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
                // Keys are owned by the import arena, which the imported-enum
                // path above already uses. Splitting ownership between the
                // arena and the general allocator meant deinit freed arena
                // memory with the wrong allocator, which aborts the compiler
                // after a successful compile — visible on any module whose
                // import closure declares enums.
                const key = try std.fmt.allocPrint(self.import_arena.allocator(), "{s}.{s}", .{ decl.name, v.name });
                if (self.enum_values.contains(key)) continue;
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
        if (self.resolveAlias(type_name)) |target| return self.isStorageType(target);
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

    /// The linker symbol for a function defined in the module being compiled.
    ///
    /// `export` marks a module's public API, not a global C name. Two modules
    /// may both export `writeChar`, and callers reach them as
    /// `serial.writeChar` and `vga.writeChar` — so the symbol has to carry the
    /// module, or the two definitions collide at link time and the linker
    /// picks one. That is exactly what happened when the 39-file MVK set was
    /// first linked together: 13 duplicate symbols, every one of them a real
    /// pair of distinct functions.
    ///
    /// The boot entry points are the exception. `kernel_main` is called from
    /// hand-written assembly in boot.s, which cannot know a module prefix, so
    /// those keep their bare names and are the kernel's true ABI surface.
    /// True when `name` is a variable (local or module-level) whose declared
    /// or inferred type is a function pointer — the target of an indirect
    /// call, as in `wakeup_callback(pid)`.
    fn isCallableVariable(self: *HomeKernelCodegen, name: []const u8) !bool {
        if (self.local_types.get(name)) |t| {
            return self.namesFunctionType(t);
        }
        if (self.global_vars.get(name)) |g| {
            return self.namesFunctionType(g.type_name);
        }
        return false;
    }

    /// Whether a written type denotes a function pointer, following aliases.
    /// `type DeviceOp = fn(u64, u32, u64): u32` is as much a function pointer
    /// as the spelled-out type: without resolving the alias, a variable
    /// declared with it was not recognised as callable and `op(...)` compiled
    /// to a direct call to a symbol named `op`, which the linker then could
    /// not find. An alias exists precisely so the spelled-out type does not
    /// have to be repeated, and a name that stops working when you give it
    /// one is a name that cannot be used.
    fn namesFunctionType(self: *HomeKernelCodegen, type_name: []const u8) bool {
        const bare = splitAlign(type_name).bare;
        if (std.mem.indexOf(u8, bare, "fn(") != null) return true;
        const resolved = self.resolveAlias(bare) orelse return false;
        return std.mem.indexOf(u8, resolved, "fn(") != null;
    }

    fn functionSymbol(self: *HomeKernelCodegen, name: []const u8) ![]const u8 {
        if (isBootEntryPoint(name) or self.module_id.len == 0) return name;
        if (self.extern_fns.contains(name)) return name;
        return std.fmt.allocPrint(
            self.import_arena.allocator(),
            "{s}__{s}",
            .{ self.module_id, name },
        );
    }

    /// `line:col` for an expression, for refusal messages. A marker that
    /// says only *what* could not be lowered leaves the reader grepping the
    /// source for it; the ratchet's whole value is pointing at work to do.
    fn at(self: *HomeKernelCodegen, expr: *const ast.Expr) []const u8 {
        const loc = expr.getLocation();
        return std.fmt.allocPrint(
            self.import_arena.allocator(),
            "{d}:{d}",
            .{ loc.line, loc.column },
        ) catch "?:?";
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
    /// The width a dereference of `operand` should load, from the pointee
    /// type. Falls back to a machine word when the type is unknown or is an
    /// aggregate, which is what the aggregate paths already assume.
    fn derefLoadSize(self: *HomeKernelCodegen, operand: *ast.Expr) usize {
        const ptr_type = self.typeOfLValue(operand) orelse return 8;
        const pointee = pointeeType(ptr_type) orelse return 8;
        return sizeOfPrimitive(pointee) orelse 8;
    }

    /// Whether a dereference of `operand` yields a signed value, so a narrow
    /// load sign-extends rather than zero-extends.
    fn derefIsSigned(self: *HomeKernelCodegen, operand: *ast.Expr) bool {
        const ptr_type = self.typeOfLValue(operand) orelse return false;
        const pointee = pointeeType(ptr_type) orelse return false;
        return std.mem.eql(u8, pointee, "i8") or std.mem.eql(u8, pointee, "i16") or
            std.mem.eql(u8, pointee, "i32") or std.mem.eql(u8, pointee, "isize");
    }

    fn typeOfLValue(self: *HomeKernelCodegen, expr: *const ast.Expr) ?[]const u8 {
        switch (expr.*) {
            // A cast states the type outright, and it is the only thing that
            // does for `@as(*u32, @ptrFromInt(addr)).*` — the form used to
            // read a hardware or bootloader structure. Without this the
            // dereference falls back to a machine word and reads past the
            // field.
            .TypeCastExpr => |cast| return cast.target_type,
            .ReflectExpr => |r| return switch (r.kind) {
                .As, .PtrCast, .BitCast, .IntCast => r.target_type,
                else => null,
            },
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
            // Offsetting a pointer yields a pointer. `var ip = packet + 14`
            // is how this tree walks a frame, and without this the derived
            // local had no type at all, so every later `ip[n]` and `ip.field`
            // failed to resolve. Note the backend's `+` is a plain address
            // add, not a scaled one, so the pointee is carried across
            // unchanged and byte offsets stay byte offsets.
            .BinaryExpr => |b| {
                if (b.op != .Add and b.op != .Sub) return null;
                const left = self.typeOfLValue(b.left);
                const right = self.typeOfLValue(b.right);
                const left_ptr = left != null and isPointerType(splitAlign(left.?).bare);
                const right_ptr = right != null and isPointerType(splitAlign(right.?).bare);
                if (b.op == .Sub) {
                    // The distance between two pointers is a count, not a
                    // pointer.
                    if (left_ptr and right_ptr) return "usize";
                    return if (left_ptr) left else null;
                }
                if (left_ptr) return left;
                if (right_ptr) return right;
                return null;
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
                    try self.emit().leaLocal(.acc, @intCast(offset));
                    return self.local_types.get(id.name) orelse "";
                }
                if (self.global_vars.get(id.name)) |g| {
                    try self.emit().leaSymbol(.acc, g.symbol);
                    return g.type_name;
                }
                // A function's address is its label. Interrupt tables are
                // built out of these.
                if (self.declared_fns.contains(id.name)) {
                    // The address of a function is the address of its symbol,
                    // which carries the module prefix like any other. Emitting
                    // the bare name here produced a reference no object
                    // defined — `&scheduler_tick` handed to a callback
                    // registration linked against nothing.
                    try self.emit().leaSymbol(.acc, try self.functionSymbol(id.name));
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
                try self.emit().push(.acc);
                try self.generateExpr(idx.index);
                if (elem_size > 1) {
                    try self.emit().mulImm(@intCast(elem_size));
                }
                try self.emit().pop(.tmp);
                try self.emit().binOp(.add);
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
                    try self.emit().addImm(.acc, @intCast(SLICE_LEN_OFFSET));
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
                    try self.emit().addImm(.acc, @intCast(field.offset));
                }
                return field.type_name;
            },
            .StringLiteral => {
                // The literal's value already is the address of its bytes.
                try self.generateExpr(expr);
                return "str";
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
                try self.print("    # ERROR: not an addressable expression at {s}\n", .{self.at(expr)});
                return null;
            },
            else => {
                try self.print("    # ERROR: not an addressable expression at {s} ({s})\n", .{ self.at(expr), @tagName(expr.*) });
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
            try self.emit().movImm(0);
            return bit_offset % 64;
        }
        try self.emit().loadOffset(.acc, .acc, @intCast(word * 8));
        return bit_offset % 64;
    }

    fn emitLoadBacking(self: *HomeKernelCodegen, size: usize) !void {
        _ = loadFor(size) orelse {
            try self.print("    # ERROR: cannot load a bitfield container of {d} bytes\n", .{size});
            try self.emit().movImm(0);
            return;
        };
        try self.emit().movReg(.tmp3, .acc);
        if (size < 8) try self.emit().zero(.acc);
        try self.emit().loadIndirect(.acc, .tmp3, size, false);
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
            try self.emit().push(.acc);
            try self.generateExpr(start);
            if (elem_size > 1) {
                try self.emit().mulImm(@intCast(elem_size));
            }
            try self.emit().pop(.tmp);
            try self.emit().binOp(.add);
        }
        return elem_type;
    }

    /// Emit the length of a slice expression into %rax: `end - start`, or the
    /// base's own length when `end` is omitted.
    fn emitSliceLength(self: *HomeKernelCodegen, sl: *const ast.SliceExpr) anyerror!void {
        if (sl.end) |end| {
            try self.generateExpr(end);
            if (sl.start) |start| {
                try self.emit().push(.acc);
                try self.generateExpr(start);
                try self.emit().movReg(.tmp, .acc);
                try self.emit().pop(.acc);
                try self.emit().binOp(.sub);
            }
            return;
        }
        // No end: the length is the base's, minus any start offset.
        const base_type = self.typeOfLValue(sl.array) orelse {
            try self.writeAll("    # ERROR: cannot determine slice length\n");
            try self.emit().movImm(0);
            return;
        };
        const bare = splitAlign(base_type).bare;
        if (self.arrayType(bare)) |arr| {
            try self.emit().movImm(@intCast(arr.count));
        } else if (isSliceType(bare)) {
            _ = try self.emitAddress(sl.array) orelse return;
            try self.emit().addImm(.acc, @intCast(SLICE_LEN_OFFSET));
            try self.emit().loadIndirect(.acc, .acc, 8, false);
        } else {
            try self.print("    # ERROR: cannot determine the length of {s}\n", .{bare});
            try self.emit().movImm(0);
            return;
        }
        if (sl.start) |start| {
            try self.emit().push(.acc);
            try self.generateExpr(start);
            try self.emit().movReg(.tmp, .acc);
            try self.emit().pop(.acc);
            try self.emit().binOp(.sub);
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
        _ = loadFor(size) orelse {
            try self.print("    # ERROR: cannot load a value of type {s} ({d} bytes)\n", .{ type_name, size });
            try self.emit().movImm(0);
            return;
        };
        try self.emit().movReg(.tmp3, .acc);
        if (size < 8) try self.emit().zero(.acc);
        try self.emit().loadIndirect(.acc, .tmp3, size, false);
    }

    /// Assemble a bitfield literal whose container is wider than one machine
    /// word, into the storage whose address is on top of the stack.
    ///
    /// Each field is masked to its width and OR-ed into the word that holds
    /// it. A field that straddles a word boundary is written in two pieces —
    /// the low bits into the first word, the remainder into the next — which
    /// is the case an in-register build cannot express at all.
    ///
    /// The destination address is kept in `mem_dst` across the whole
    /// operation, and pushed around each field's value expression, since that
    /// expression is arbitrary Home code and may itself use every role.
    fn emitWideBitfieldLiteral(
        self: *HomeKernelCodegen,
        info: StructInfo,
        lit: *const ast.StructLiteralExpr,
    ) !void {
        try self.emit().pop(.mem_dst);

        // Unmentioned bits read as zero, which is what a literal means.
        try self.emit().push(.mem_dst);
        try self.emit().movImmReg(.mem_len, @intCast(info.size));
        try self.emit().zero(.acc);
        try self.emit().memFill(self.freshLabel());
        try self.emit().pop(.mem_dst);

        const word_bits: usize = 64;
        for (lit.fields) |fi| {
            var found: ?FieldInfo = null;
            for (info.fields) |f| {
                if (std.mem.eql(u8, f.name, fi.name)) {
                    found = f;
                    break;
                }
            }
            const field = found orelse {
                try self.print("    # ERROR: {s} has no field {s}\n", .{ info.name, fi.name });
                continue;
            };
            if (field.bit_width == 0 or field.bit_width > 64) {
                try self.print(
                    "    # ERROR: {s}.{s} is {d} bits; this backend places bitfields up to 64 bits wide\n",
                    .{ info.name, field.name, field.bit_width },
                );
                continue;
            }

            try self.emit().push(.mem_dst);
            try self.generateExpr(fi.value);
            try self.emit().pop(.mem_dst);

            // Mask the value to the field's width so a caller passing a wider
            // number cannot corrupt a neighbouring field.
            const mask: u64 = if (field.bit_width >= 64)
                std.math.maxInt(u64)
            else
                (@as(u64, 1) << @intCast(field.bit_width)) - 1;
            try self.emit().movImmReg(.tmp, @bitCast(mask));
            try self.emit().binOp(.bit_and);

            const word_index = field.bit_offset / word_bits;
            const shift = field.bit_offset % word_bits;
            const byte_offset: i64 = @intCast(word_index * 8);

            // Low piece: the part of the field that fits in this word.
            try self.emit().push(.acc);
            if (shift > 0) try self.emit().shiftImm(.shl, @intCast(shift));
            try self.emit().loadOffset(.tmp, .mem_dst, byte_offset);
            try self.emit().binOp(.bit_or);
            try self.emit().storeOffset(.acc, .mem_dst, byte_offset);
            try self.emit().pop(.acc);

            // High piece, only when the field straddles the boundary.
            if (shift > 0 and shift + field.bit_width > word_bits) {
                const next_offset = byte_offset + 8;
                if (word_index + 1 < (info.size + 7) / 8) {
                    try self.emit().shiftImm(.shr_logical, @intCast(word_bits - shift));
                    try self.emit().loadOffset(.tmp, .mem_dst, next_offset);
                    try self.emit().binOp(.bit_or);
                    try self.emit().storeOffset(.acc, .mem_dst, next_offset);
                } else {
                    try self.print(
                        "    # ERROR: {s}.{s} at bit {d} runs past the end of a {d}-byte container\n",
                        .{ info.name, field.name, field.bit_offset, info.size },
                    );
                }
            }
        }
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
            try self.emit().addStack(self.emit().pushStride());
            return;
        };
        if (info.is_bitfield) {
            if (info.size > 8) {
                // A container wider than a machine word is assembled a word at
                // a time in memory. The register path below cannot do it: it
                // holds the whole value in one register, so every field at bit
                // 64 or above would be shifted out. A 128-bit IDT entry is
                // exactly this shape, and it used to emit `shlq $64, %rax`,
                // which x86 masks to a shift of zero — the field landed on top
                // of bit 0 and a descriptor the CPU rejects was written
                // silently.
                try self.emitWideBitfieldLiteral(info, lit);
                return;
            }
            // A bitfield literal that fits in a register IS an integer: build
            // it via the expression path, then store over the destination.
            // generateExpr takes a pointer, so the wrapper needs storage.
            // The union holds a mutable pointer; nothing here writes through it.
            var as_expr = ast.Expr{ .StructLiteral = @constCast(lit) };
            try self.generateExpr(&as_expr);
            try self.emit().pop(.tmp3);
            try self.emit().storeIndirect(.acc, .tmp3, info.size);
            return;
        }

        try self.emit().pop(.mem_dst);
        // Zero the full width so unmentioned fields read as zero.
        try self.emit().movImmReg(.mem_len, @intCast(info.size));
        try self.emit().zero(.acc);
        try self.emit().memFill(self.freshLabel());

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
                try self.emit().push(.mem_dst);
                try self.emit().movReg(.acc, .mem_dst);
                if (f.offset > 0) try self.emit().addImm(.acc, @intCast(f.offset));
                if (fi.value.* == .StructLiteral) {
                    try self.emit().push(.acc);
                    try self.emitStructLiteralToMemory(f.type_name, fi.value.StructLiteral);
                } else {
                    try self.emitArrayLiteralToMemory(f.type_name, fi.value);
                }
                try self.emit().pop(.mem_dst);
                continue;
            }

            // Base address survives the field's value expression.
            try self.emit().push(.mem_dst);
            try self.generateExpr(fi.value);
            try self.emit().pop(.mem_dst);
            if (storeFor(f.size) == null) {
                // Wide fields — arrays, nested structs — do not fit in a
                // register. %rax holds the source address, %rdi the
                // destination; copy the field's own width.
                try self.emit().addImm(.mem_dst, @intCast(f.offset));
                try self.emit().movReg(.mem_src, .acc);
                try self.emit().movImmReg(.mem_len, @intCast(f.size));
                try self.emit().memCopy(self.freshLabel());
                // The copy advanced the destination and consumed the length;
                // wind both back so the next field starts from the base.
                try self.emit().aluRegs(.sub, .mem_dst, .mem_len);
                try self.emit().addImm(.mem_dst, -@as(i64, @intCast(f.offset)));
                continue;
            }
            _ = storeFor(f.size) orelse {
                // Unreachable: the null case is handled above.
                try self.print("    # ERROR: cannot lower field {s}.{s} of {d} bytes\n", .{ info.name, f.name, f.size });
                continue;
            };
            try self.emit().storeOffsetSized(.acc, .mem_dst, @intCast(f.offset), f.size);
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
        // Elements too wide for a register — an array of structs — are each
        // written as an aggregate into their own slot.
        _ = storeFor(elem_size) orelse {
            if (!self.isStorageType(arr.elem_type)) {
                try self.print("    # ERROR: cannot store array elements of {d} bytes\n", .{elem_size});
                return;
            }
            try self.emit().push(.acc); // base address
            var idx: usize = 0;
            while (idx < arr.count) : (idx += 1) {
                const element: ?*const ast.Expr = switch (value.*) {
                    .ArrayLiteral => |lit| if (idx < lit.elements.len) lit.elements[idx] else null,
                    .ArrayRepeat => |rep| rep.value,
                    else => null,
                };
                try self.emit().loadPushed(.acc, 0);
                if (idx > 0) try self.emit().addImm(.acc, @intCast(idx * elem_size));
                if (element) |e| {
                    if (e.* == .StructLiteral) {
                        try self.emit().push(.acc);
                        try self.emitStructLiteralToMemory(arr.elem_type, e.StructLiteral);
                    } else {
                        try self.emitStoreToAddress(arr.elem_type, e);
                    }
                } else {
                    // Unmentioned elements read as zero.
                    try self.emit().movReg(.mem_dst, .acc);
                    try self.emit().movImmReg(.mem_len, @intCast(elem_size));
                    try self.emit().zero(.acc);
                    try self.emit().memFill(self.freshLabel());
                }
            }
            try self.emit().pop(.acc);
            return;
        };

        try self.emit().push(.acc); // base address

        switch (value.*) {
            .ArrayLiteral => |lit| {
                for (lit.elements, 0..) |elem, i| {
                    if (i >= arr.count) {
                        try self.print("    # ERROR: array literal has more elements than the {d} declared\n", .{arr.count});
                        break;
                    }
                    try self.generateExpr(elem);
                    try self.emit().loadPushed(.tmp3, 0);
                    if (i > 0) try self.emit().addImm(.tmp3, @intCast(i * elem_size));
                    try self.emit().storeIndirect(.acc, .tmp3, elem_size);
                }
                // Elements the literal does not mention read as zero.
                var i: usize = lit.elements.len;
                while (i < arr.count) : (i += 1) {
                    try self.emit().loadPushed(.tmp3, 0);
                    if (i > 0) try self.emit().addImm(.tmp3, @intCast(i * elem_size));
                    try self.emit().zero(.acc);
                    try self.emit().storeIndirect(.acc, .tmp3, elem_size);
                }
            },
            .ArrayRepeat => |rep| {
                // `[0; N]` — one value, repeated. Evaluate it once: repeating
                // the expression would repeat its side effects too.
                try self.generateExpr(rep.value);
                try self.emit().movReg(.tmp2, .acc);
                var i: usize = 0;
                while (i < arr.count) : (i += 1) {
                    try self.emit().loadPushed(.tmp3, 0);
                    if (i > 0) try self.emit().addImm(.tmp3, @intCast(i * elem_size));
                    try self.emit().movReg(.acc, .tmp2);
                    try self.emit().storeIndirect(.acc, .tmp3, elem_size);
                }
            },
            else => {},
        }

        try self.emit().pop(.acc);
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
            try self.emit().push(.acc);
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
                        try self.emit().push(.acc); // destination
                        // The hidden pointer takes %rdi, so the declared
                        // arguments start one register later.
                        // Argument 0 is the hidden destination pointer, so
                        // the visible arguments start at register 1.
                        var words: usize = 0;
                        var i: usize = call.args.len;
                        while (i > 0) {
                            i -= 1;
                            words += try self.pushArgument(call.args[i]);
                        }
                        for (0..words) |reg_idx| {
                            const areg = self.emit().argReg(reg_idx + 1) orelse break;
                            try self.emit().popNamed(areg);
                        }
                        try self.emit().pop(.mem_dst);
                        try self.emit().call(try self.functionSymbol(callee));
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
            try self.emit().push(.acc);           // destination
            if (try self.emitAddress(value)) |_| {
                try self.emit().movReg(.mem_src, .acc);   // source
                try self.emit().pop(.mem_dst);            // destination
            } else {
                try self.generateExpr(value);
                try self.emit().movReg(.mem_src, .acc);
                try self.emit().pop(.mem_dst);
            }
            try self.emit().movImmReg(.mem_len, @intCast(size));
            try self.emit().memCopy(self.freshLabel());
            return;
        }

        _ = storeFor(size) orelse {
            try self.print("    # ERROR: cannot store a value of type {s} ({d} bytes)\n", .{ type_name, size });
            return;
        };
        // Address first, stashed, then the value — so the value expression
        // cannot clobber the address.
        try self.emit().push(.acc);
        try self.generateExpr(value);
        try self.emit().pop(.tmp3);
        try self.emit().storeIndirect(.acc, .tmp3, size);
    }

    /// Record a module-level binding as storage. Returns false when its size
    /// cannot be determined, which is a refusal rather than a guess: emitting
    /// a symbol of the wrong length would corrupt whatever follows it.
    fn declareGlobalVar(self: *HomeKernelCodegen, decl: *const ast.LetDecl) !bool {
        // Idempotent: the pre-pass above registers module storage before any
        // function body is lowered, and the statement itself is still walked
        // afterwards. Registering twice appends to global_order twice and
        // emits the symbol twice, which the assembler rejects as a duplicate
        // definition.
        if (self.global_vars.contains(decl.name)) return true;
        // A module-level array literal needs no annotation: its length is the
        // number of elements, and its element width comes from what they are.
        // `let exception_names = ["Division By Zero", ...]` is how this tree
        // declares its message tables, and without this the whole binding was
        // unsizable and every use of it — including `.len` — was refused.
        if (decl.type_name == null) {
            if (decl.value) |value| {
                if (value.* == .ArrayLiteral) {
                    const elements = value.ArrayLiteral.elements;
                    if (elements.len > 0) {
                        if (self.literalTableElemType(elements)) |elem_type| {
                            const elem_size = self.sizeOf(elem_type) orelse 8;
                            const sym = try std.fmt.allocPrint(
                                self.import_arena.allocator(),
                                GLOBAL_SYMBOL_PREFIX ++ "{s}",
                                .{decl.name},
                            );
                            const tn = try std.fmt.allocPrint(
                                self.import_arena.allocator(),
                                "[{d}]{s}",
                                .{ elements.len, elem_type },
                            );
                            try self.global_vars.put(decl.name, .{
                                .name = decl.name,
                                .symbol = sym,
                                .type_name = tn,
                                .size = elements.len * elem_size,
                                .elem_size = elem_size,
                                .is_array = true,
                                .init_value = null,
                                .init_elements = elements,
                            });
                            try self.global_order.append(self.allocator, decl.name);
                            return true;
                        }
                    }
                }
            }
        }

        const type_name = decl.type_name orelse return false;

        const symbol = try std.fmt.allocPrint(
            self.import_arena.allocator(),
            GLOBAL_SYMBOL_PREFIX ++ "{s}",
            .{decl.name},
        );

        if (self.arrayType(type_name)) |arr| {
            const elem = self.sizeOf(arr.elem_type) orelse return false;
            // An annotated array with a literal initializer is data, exactly
            // as an unannotated one is. Without this the initializer was
            // dropped and the symbol became zero-filled .bss — so every
            // constant table in a kernel (SHA-256's round constants, AES's
            // S-boxes, BLAKE2s's message schedule) silently read as zeros,
            // and the algorithms built on them computed confidently wrong
            // answers.
            const table_elements: ?[]const *ast.Expr = blk: {
                const value = decl.value orelse break :blk null;
                if (value.* != .ArrayLiteral) break :blk null;
                break :blk value.ArrayLiteral.elements;
            };
            try self.global_vars.put(decl.name, .{
                .name = decl.name,
                .symbol = symbol,
                .type_name = type_name,
                .size = arr.count * elem,
                .elem_size = elem,
                .is_array = true,
                .init_value = null,
                .init_elements = table_elements,
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
            } else if (size == 8) {
                // foldConst casts to i64 and gives up above i64's maximum, so
                // a u64 constant with the top bit set — a mask like
                // 0xC000000000000000, a sentinel, an address above 2^63 —
                // produced no initializer at all and the symbol was emitted
                // zero-filled. The constant then silently read as 0.
                //
                // The bit pattern is what goes on disk either way: `.quad`
                // emits the same eight bytes for the negative i64 as for the
                // u64 it was written as.
                if (value.* == .IntegerLiteral) {
                    const raw = value.IntegerLiteral.value;
                    if (raw > std.math.maxInt(i64) and raw <= std.math.maxInt(u64)) {
                        init_value = @bitCast(@as(u64, @intCast(raw)));
                    }
                }
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

    /// Label for a string literal's .rodata entry, reusing an existing one
    /// when the same text has already been emitted.
    fn internStringLiteral(self: *HomeKernelCodegen, content: []const u8) !usize {
        for (self.string_literals.items) |existing| {
            if (std.mem.eql(u8, existing.content, content)) return existing.label;
        }
        const label = self.freshLabel();
        try self.string_literals.append(self.allocator, .{ .label = label, .content = content });
        return label;
    }

    /// Element type of a module-level array literal, when every element is a
    /// form that can be emitted statically. Returns null otherwise, so a
    /// table needing runtime evaluation is refused rather than half-built.
    fn literalTableElemType(self: *HomeKernelCodegen, elements: []const *ast.Expr) ?[]const u8 {
        var all_strings = true;
        var all_ints = true;
        for (elements) |e| {
            switch (e.*) {
                .StringLiteral => all_ints = false,
                .IntegerLiteral, .BooleanLiteral => all_strings = false,
                .Identifier => {
                    // A named constant counts as an integer element.
                    if (self.globals.get(e.Identifier.name) == null) return null;
                    all_strings = false;
                },
                else => return null,
            }
        }
        if (all_strings) return "str";
        if (all_ints) return "u64";
        return null;
    }

    /// Emit .data and .bss for the module-level bindings collected above.
    fn emitGlobals(self: *HomeKernelCodegen) !void {
        var data_count: usize = 0;
        var bss_count: usize = 0;
        for (self.global_order.items) |name| {
            const g = self.global_vars.get(name) orelse continue;
            if (g.init_elements != null) continue;
            if (g.init_value != null) data_count += 1 else bss_count += 1;
        }

        // Tables first: an array literal is data even though it has no
        // scalar init_value.
        var table_count: usize = 0;
        for (self.global_order.items) |name| {
            const g = self.global_vars.get(name) orelse continue;
            if (g.init_elements != null) table_count += 1;
        }
        if (table_count > 0) {
            try self.emit().sectionData();
            for (self.global_order.items) |name| {
                const g = self.global_vars.get(name) orelse continue;
                const elements = g.init_elements orelse continue;
                // Each element is emitted at the array's element width. A
                // `.quad` per element of a [u32; N] would lay the table out at
                // twice its stride, so every indexed read but the first landed
                // between two entries.
                const directive = switch (g.elem_size) {
                    1 => ".byte",
                    2 => ".short",
                    4 => ".long",
                    else => ".quad",
                };
                try self.print(".align {d}\n", .{@min(g.elem_size, @as(usize, 8))});
                try self.print("{s}:\n", .{g.symbol});
                for (elements) |e| {
                    switch (e.*) {
                        .StringLiteral => |lit| {
                            // A string element is a pointer, whatever the
                            // array's nominal element width.
                            const label = try self.internStringLiteral(lit.value);
                            try self.print("    .quad .L_str_{d}\n", .{label});
                        },
                        .IntegerLiteral => |lit| try self.print("    {s} {d}\n", .{ directive, lit.value }),
                        .BooleanLiteral => |lit| try self.print("    {s} {d}\n", .{ directive, @as(i64, if (lit.value) 1 else 0) }),
                        .Identifier => |id| {
                            const v = self.globals.get(id.name) orelse 0;
                            try self.print("    {s} {d}\n", .{ directive, v });
                        },
                        else => try self.print("    {s} 0\n", .{directive}),
                    }
                }
                // A declared array longer than its initializer keeps its full
                // length, zero-filled, rather than running into whatever
                // symbol the assembler places next.
                const written = elements.len * g.elem_size;
                if (g.size > written) {
                    try self.print("    .zero {d}\n", .{g.size - written});
                }
            }
        }

        if (data_count > 0) {
            try self.emit().sectionData();
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
            try self.emit().sectionBss();
            for (self.global_order.items) |name| {
                const g = self.global_vars.get(name) orelse continue;
                if (g.init_value != null or g.init_elements != null) continue;
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
    /// Whether an expression mentions `@targetIs` anywhere inside it, so that
    /// `if (@targetIs("x86_64") and SOMETHING)` is still recognised as a
    /// target test rather than only the bare form.
    fn exprMentionsTargetIs(expr: *const ast.Expr) bool {
        return switch (expr.*) {
            .ReflectExpr => |r| r.kind == .TargetIs,
            .UnaryExpr => |u| exprMentionsTargetIs(u.operand),
            .BinaryExpr => |b| exprMentionsTargetIs(b.left) or exprMentionsTargetIs(b.right),
            else => false,
        };
    }

    fn foldConst(self: *HomeKernelCodegen, expr: *const ast.Expr) ?i64 {
        switch (expr.*) {
            // Literals are parsed as i128. Anything that fits in 64 bits is a
            // constant here, signed or not: a u64 above i64::MAX is not out of
            // range, it is a bit pattern with the top bit set — an object-type
            // tag, a mask, a canonical high-half address. Folded only through
            // std.math.cast(i64, ...) those constants were dropped, and since
            // a dropped constant is simply absent, every use of one failed to
            // resolve as though the name had never been declared.
            .IntegerLiteral => |lit| {
                if (std.math.cast(i64, lit.value)) |signed| return signed;
                if (std.math.cast(u64, lit.value)) |unsigned| {
                    return @bitCast(unsigned);
                }
                return null;
            },
            .BooleanLiteral => |lit| return if (lit.value) @as(i64, 1) else @as(i64, 0),
            .ReflectExpr => |r| {
                // `@targetIs("aarch64")` is the one builtin whose value is
                // known before any code is generated, which is what lets an
                // `if` on it drop the branch it does not take.
                if (r.kind != .TargetIs) return null;
                if (r.target.* != .StringLiteral) return null;
                const named = kernel_target.Arch.parse(r.target.StringLiteral.value) orelse
                    return null;
                return if (named == self.arch) @as(i64, 1) else @as(i64, 0);
            },
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

    /// Call through a function pointer held in a struct field. Returns false
    /// if the member is not such a field, so the caller can fall through to
    /// its own diagnostic.
    fn emitIndirectMemberCall(
        self: *HomeKernelCodegen,
        member: *const ast.MemberExpr,
        args: []const *const ast.Expr,
    ) anyerror!bool {
        const base_type = self.typeOfLValue(member.object) orelse return false;
        var owner = splitAlign(base_type).bare;
        if (isPointerType(owner)) owner = pointeeType(owner) orelse owner;
        const field = self.findField(owner, member.member) orelse return false;

        // Only a function-typed field is callable.
        const bare_field = splitAlign(field.type_name).bare;
        const resolved = self.resolveAlias(bare_field) orelse bare_field;
        if (!std.mem.startsWith(u8, resolved, "fn")) return false;
        if (args.len > 0) {
            var words: usize = 0;
            var i: usize = args.len;
            while (i > 0) {
                i -= 1;
                words += try self.pushArgument(args[i]);
            }
            for (0..words) |reg_idx| {
                const areg = self.emit().argReg(reg_idx) orelse break;
                try self.emit().popNamed(areg);
            }
        }

        // Load the pointer last, so evaluating the arguments cannot clobber it.
        _ = try self.emitAddress(member.object) orelse return false;
        if (field.offset > 0) {
            try self.emit().addImm(.acc, @intCast(field.offset));
        }
        try self.emit().loadIndirect(.acc, .acc, 8, false);
        try self.emit().callReg(.acc);
        return true;
    }

    /// Lower an inline-assembly block, marshalling its operands.
    ///
    /// Inputs are evaluated and placed where their constraints ask, the
    /// template's `%[name]` and `%0`-style placeholders are replaced, and
    /// register outputs are copied back out afterwards. Without this a block
    /// like
    ///
    ///     asm volatile ("inb %[port], %[result]"
    ///       : [result] "={al}" (result)
    ///       : [port] "{dx}" (port))
    ///
    /// emitted nothing at all, and every port read in the kernel returned
    /// whatever was in the stack slot.
    ///
    /// Constraints: `{reg}` and `={reg}` with an optional modifier prefix,
    /// single-letter GCC register classes, `r` from a scratch pool, `m` for a
    /// memory operand (the address is taken and the placeholder becomes
    /// `(%reg)`), and a digit for a matching constraint, which reuses the
    /// register of the operand it names.
    /// Lower an `asm volatile` block.
    ///
    /// The assembly text is passed through verbatim, which is what inline
    /// assembly means, so a block written for one architecture cannot work on
    /// another — and the operand machinery below maps constraint letters to
    /// x86 register names besides. On any other target the whole construct is
    /// refused with a located marker rather than emitted as text the
    /// assembler will reject with no reference to the Home source.
    fn emitInlineAsm(self: *HomeKernelCodegen, asm_node: ast.InlineAsm) anyerror!void {
        if (asm_node.instruction.len == 0) return;

        // Inline assembly is architecture-specific by definition: the text is
        // emitted verbatim. Passing an x86 block to the ARM assembler produces
        // an error naming a temporary .s file and no Home source location, so
        // refuse here instead, where the file and the construct are known.
        if (self.arch != .x86_64) {
            try self.print(
                "    # ERROR: inline asm in {s} is written for x86-64 and cannot be emitted for {s}\n",
                .{ self.current_fn, @tagName(self.arch) },
            );
            return;
        }

        const arena = self.import_arena.allocator();

        // No operands: emit as written, with GCC's `%%` escape reduced — this
        // backend emits assembly directly, so a doubled percent is a literal.
        if (asm_node.outputs.len == 0 and asm_node.inputs.len == 0) {
            try self.printAsmText(try self.reducePercent(arena, asm_node.instruction));
            return;
        }

        const Slot = struct {
            op: ast.AsmOperand,
            is_output: bool,
            is_memory: bool,
            reg: []const u8,
            /// What replaces the placeholder: `%reg`, or `(%reg)` for memory.
            text: []const u8,
            /// Inputs, read-write operands, and matching constraints are
            /// loaded before the instruction. Memory operands load an address.
            loads: bool,
            /// Register outputs are copied back after; memory outputs are
            /// written by the instruction itself.
            stores: bool,
        };

        const total = asm_node.outputs.len + asm_node.inputs.len;
        var slots = try arena.alloc(Slot, total);

        // Registers for operands whose constraint names no specific one.
        // Chosen to avoid %rax, which every evaluation clobbers.
        const scratch = [_][]const u8{ "r8", "r9", "r10", "r11", "r12", "r13" };
        var next_scratch: usize = 0;

        for (0..total) |i| {
            const is_output = i < asm_node.outputs.len;
            const op = if (is_output) asm_node.outputs[i] else asm_node.inputs[i - asm_node.outputs.len];

            var c = op.constraint;
            var read_write = false;
            while (c.len > 0 and (c[0] == '=' or c[0] == '+' or c[0] == '&')) {
                if (c[0] == '+') read_write = true;
                c = c[1..];
            }

            // A digit names an earlier operand and shares its location.
            if (c.len > 0 and std.ascii.isDigit(c[0])) {
                const idx = std.fmt.parseInt(usize, c, 10) catch total;
                if (idx >= i) {
                    try self.print("    # ERROR: asm matching constraint \"{s}\" names no earlier operand\n", .{op.constraint});
                    return;
                }
                slots[i] = .{
                    .op = op,
                    .is_output = is_output,
                    .is_memory = slots[idx].is_memory,
                    .reg = slots[idx].reg,
                    .text = slots[idx].text,
                    .loads = true,
                    .stores = false,
                };
                continue;
            }

            const is_memory = c.len > 0 and c[0] == 'm';
            const reg = if (is_memory) blk: {
                if (next_scratch >= scratch.len) break :blk "";
                const r = scratch[next_scratch];
                next_scratch += 1;
                break :blk r;
            } else registerForConstraint(op.constraint) orelse blk: {
                if (next_scratch >= scratch.len) break :blk "";
                const r = scratch[next_scratch];
                next_scratch += 1;
                break :blk r;
            };
            if (reg.len == 0) {
                try self.print("    # ERROR: too many register operands in asm\n", .{});
                return;
            }

            slots[i] = .{
                .op = op,
                .is_output = is_output,
                .is_memory = is_memory,
                .reg = reg,
                .text = if (is_memory)
                    try std.fmt.allocPrint(arena, "(%{s})", .{fullRegister(reg)})
                else
                    try std.fmt.allocPrint(arena, "%{s}", .{sizedRegister(reg, self.asmOperandSize(op))}),
                // A memory operand always needs its address, whichever
                // direction it goes in.
                .loads = is_memory or !is_output or read_write,
                .stores = !is_memory and is_output,
            };
        }

        // Evaluate everything that needs a value onto the stack first, then
        // distribute. Evaluating straight into the target registers would let
        // a later operand's own code generation clobber an earlier one.
        var pushed: usize = 0;
        for (slots) |slot| {
            if (!slot.loads) continue;
            if (slot.is_memory) {
                _ = try self.emitAddress(slot.op.expr) orelse {
                    try self.print("    # ERROR: asm memory operand has no address\n", .{});
                    return;
                };
            } else {
                try self.generateExpr(slot.op.expr);
            }
            try self.emit().push(.acc);
            pushed += 1;
        }
        var remaining = pushed;
        while (remaining > 0) : (remaining -= 1) {
            // Pops come back in reverse, so walk the loading slots backwards.
            var seen: usize = 0;
            for (slots) |slot| {
                if (!slot.loads) continue;
                seen += 1;
                if (seen != remaining) continue;
                try self.print("    popq %{s}\n", .{fullRegister(slot.reg)});
            }
        }

        // Substitute placeholders: named first, then positional.
        var text: []const u8 = try arena.dupe(u8, asm_node.instruction);
        for (slots) |slot| {
            if (slot.op.name) |n| text = try self.substituteText(arena, text, n, slot.text);
        }
        for (slots, 0..) |slot, i| {
            const pos = try std.fmt.allocPrint(arena, "{d}", .{i});
            text = try self.substituteText(arena, text, pos, slot.text);
        }
        try self.printAsmText(try self.reducePercent(arena, text));

        // Copy register outputs back to their destinations.
        for (slots) |slot| {
            if (!slot.stores) continue;
            if (slot.op.expr.* == .NullLiteral) continue; // `-> T` names no destination

            // Widen to the full register before storing. An instruction that
            // writes a sub-register leaves the rest of the enclosing register
            // alone — `inb %dx, %al` sets only %al — so copying the 64-bit
            // register carries whatever the operand marshalling happened to
            // leave in the upper bits. A u8 read back from a port then failed
            // `c == 10` because the comparison sees all 64.
            const osize = self.asmOperandSize(slot.op);
            const signed = self.asmOperandIsSigned(slot.op);
            if (osize < 8) {
                const sub = sizedRegister(slot.reg, osize);
                const insn = if (signed) switch (osize) {
                    1 => "movsbq",
                    2 => "movswq",
                    4 => "movslq",
                    else => unreachable,
                } else switch (osize) {
                    1 => "movzbq",
                    2 => "movzwq",
                    // A 32-bit mov zero-extends into the full register.
                    4 => "movl",
                    else => unreachable,
                };
                const dst = if (!signed and osize == 4) "eax" else "rax";
                try self.print("    {s} %{s}, %{s}\n", .{ insn, sub, dst });
            } else {
                // `fullRegister` returns a bare x86 name; the emitter's
                // named-register operations take the name the assembler wants,
                // sigil included.
                try self.emit().movFromNamed(.acc, try std.fmt.allocPrint(
                    self.import_arena.allocator(),
                    "%{s}",
                    .{fullRegister(slot.reg)},
                ));
            }
            if (slot.op.expr.* == .Identifier) {
                const name = slot.op.expr.Identifier.name;
                if (self.locals.get(name)) |offset| {
                    try self.emit().storeLocal(.acc, @intCast(offset));
                    continue;
                }
                if (self.global_vars.get(name)) |g| {
                    if (storeFor(g.size)) |_| {
                        try self.emit().storeSymbolSized(.acc, g.symbol, g.size);
                        continue;
                    }
                }
            }
            try self.print("    # ERROR: asm output has no assignable destination\n", .{});
        }
    }

    /// The width of an asm operand, from its own Home type. Falls back to a
    /// machine word, which is what a register name without a suffix means.
    fn asmOperandSize(self: *HomeKernelCodegen, op: ast.AsmOperand) usize {
        // An explicit sub-register in the constraint settles it: `{al}` is a
        // byte however the value is typed.
        if (registerForConstraint(op.constraint)) |named| {
            const full = fullRegister(named);
            if (!std.mem.eql(u8, full, named)) {
                if (std.mem.eql(u8, sizedRegister(named, 1), named)) return 1;
                if (std.mem.eql(u8, sizedRegister(named, 2), named)) return 2;
                if (std.mem.eql(u8, sizedRegister(named, 4), named)) return 4;
            }
        }
        const t = self.typeOfLValue(op.expr) orelse return 8;
        return sizeOfPrimitive(t) orelse 8;
    }

    /// Whether an asm operand's Home type is signed, so a narrow value read
    /// back from a register sign-extends rather than zero-extends.
    fn asmOperandIsSigned(self: *HomeKernelCodegen, op: ast.AsmOperand) bool {
        const t = self.typeOfLValue(op.expr) orelse return false;
        return std.mem.eql(u8, t, "i8") or std.mem.eql(u8, t, "i16") or
            std.mem.eql(u8, t, "i32") or std.mem.eql(u8, t, "isize");
    }

    /// Replace every `%[name]` (or `%N` when `name` is a number) in `text`
    /// with `replacement`.
    fn substituteText(
        self: *HomeKernelCodegen,
        arena: std.mem.Allocator,
        text: []const u8,
        name: []const u8,
        replacement: []const u8,
    ) ![]const u8 {
        _ = self;
        const needle = if (name.len > 0 and std.ascii.isDigit(name[0]))
            try std.fmt.allocPrint(arena, "%{s}", .{name})
        else
            try std.fmt.allocPrint(arena, "%[{s}]", .{name});
        const count = std.mem.count(u8, text, needle);
        if (count == 0) return text;
        const out = try arena.alloc(u8, text.len - count * needle.len + count * replacement.len);
        _ = std.mem.replace(u8, text, needle, replacement, out);
        return out;
    }

    /// Emit an assembly template, one instruction per line.
    ///
    /// A multi-instruction block is written with `\n` separators inside the
    /// string literal, and the lexeme reaches codegen with the escape
    /// *unprocessed* — so `"pushfq\npopq %0"` would otherwise be emitted as a
    /// single line containing a literal backslash, which the assembler
    /// rejects. Translate the escapes and give each instruction its own line.
    fn printAsmText(self: *HomeKernelCodegen, text: []const u8) !void {
        var line_start: usize = 0;
        var i: usize = 0;
        var pending = false; // something was written on the current line
        while (i < text.len) {
            if (text[i] == '\\' and i + 1 < text.len and (text[i + 1] == 'n' or text[i + 1] == 't')) {
                const kind = text[i + 1];
                if (i > line_start) {
                    if (!pending) try self.print("    ", .{});
                    try self.print("{s}", .{text[line_start..i]});
                    pending = true;
                }
                if (kind == 'n') {
                    if (pending) try self.print("\n", .{});
                    pending = false;
                } else {
                    if (!pending) try self.print("    ", .{});
                    try self.print(" ", .{});
                    pending = true;
                }
                i += 2;
                line_start = i;
                continue;
            }
            if (text[i] == '\n') {
                if (i > line_start) {
                    if (!pending) try self.print("    ", .{});
                    try self.print("{s}", .{text[line_start..i]});
                    pending = true;
                }
                if (pending) try self.print("\n", .{});
                pending = false;
                i += 1;
                line_start = i;
                continue;
            }
            i += 1;
        }
        if (line_start < text.len) {
            if (!pending) try self.print("    ", .{});
            try self.print("{s}", .{text[line_start..]});
            pending = true;
        }
        if (pending) try self.print("\n", .{});
    }

    /// Reduce GCC's doubled-percent escape. In a C compiler's asm template
    /// `%%` means a literal percent; this backend writes assembly directly, so
    /// the doubling has to come back out or the assembler sees `%%cr3`.
    fn reducePercent(self: *HomeKernelCodegen, arena: std.mem.Allocator, text: []const u8) ![]const u8 {
        _ = self;
        const count = std.mem.count(u8, text, "%%");
        if (count == 0) return text;
        const out = try arena.alloc(u8, text.len - count);
        _ = std.mem.replace(u8, text, "%%", "%", out);
        return out;
    }

    /// Push one call argument, returning how many machine words it occupies.
    /// Pushes happen in reverse argument order, so within a slice the length
    /// is pushed first and the pointer second — leaving the pointer on top,
    /// which is what pops into the lower-numbered register.
    fn pushArgument(self: *HomeKernelCodegen, arg: *const ast.Expr) anyerror!usize {
        // A string literal used where a slice is expected carries its length
        // with it: the length is known at compile time.
        if (arg.* == .StringLiteral) {
            try self.emit().movImm(@intCast(arg.StringLiteral.value.len));
            try self.emit().push(.acc);
            try self.generateExpr(arg);
            try self.emit().push(.acc);
            return 2;
        }
        // `ptr[0..len]` passed to a `[]T` parameter travels as the pair the
        // callee expects. Length first, pointer second: pushes happen in
        // reverse argument order, so this leaves the pointer on top, which is
        // what pops into the lower-numbered register.
        if (arg.* == .SliceExpr) {
            try self.emitSliceLength(arg.SliceExpr);
            try self.emit().push(.acc);
            _ = try self.emitSliceDataPointer(arg.SliceExpr) orelse {
                try self.emit().movImm(0);
            };
            try self.emit().push(.acc);
            return 2;
        }
        if (self.typeOfLValue(arg)) |t| {
            const bare = splitAlign(t).bare;
            if (isSliceType(bare)) {
                // Pass the pair through unchanged.
                _ = try self.emitAddress(arg) orelse {
                    try self.emit().push(.acc);
                    return 1;
                };
                try self.emit().push(.acc);           // save slice address
                try self.emit().loadOffset(.acc, .acc, @intCast(SLICE_LEN_OFFSET));
                try self.emit().movReg(.tmp, .acc);
                try self.emit().pop(.acc);
                try self.emit().push(.tmp);            // length
                try self.emit().loadIndirect(.acc, .acc, 8, false);     // data pointer
                try self.emit().push(.acc);
                return 2;
            }
            if (self.arrayType(bare)) |arr| {
                // A fixed array decays to (pointer, length).
                try self.emit().movImm(@intCast(arr.count));
                try self.emit().push(.acc);
                try self.generateExpr(arg);
                try self.emit().push(.acc);
                return 2;
            }
        }
        try self.generateExpr(arg);
        try self.emit().push(.acc);
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
        const Kind = enum { none, out, in, cpu, mmio_read, mmio_write, barrier, sys };
        // Operations both architectures genuinely have, but spell differently
        // enough that a caller cannot write one form and expect the other to
        // work (home-lang/home#584).
        const SysOp = enum {
            save_irq, restore_irq, timestamp, atomic_add, read_sysreg, write_sysreg,
            read_sp, write_sp, invlpg, compiler_barrier, memory_barrier,
            allow_user_access, forbid_user_access, user_access_allowed,
            cas32, xchg32, add32, load32, store32,
        };
        var sys_op: SysOp = .timestamp;
        // What the CPU-state intrinsics do, named for the effect rather than
        // for one architecture's mnemonic.
        const CpuOp = enum { halt, disable_irq, enable_irq, nop, spin_hint, wait_event };
        var kind: Kind = .none;
        var width: usize = 0;
        var cpu_op: CpuOp = .nop;
        var barrier_kind: kernel_target.Barrier = .full;

        if (std.mem.eql(u8, name, "outb")) { kind = .out; width = 1; }
        else if (std.mem.eql(u8, name, "outw")) { kind = .out; width = 2; }
        else if (std.mem.eql(u8, name, "outl")) { kind = .out; width = 4; }
        else if (std.mem.eql(u8, name, "inb")) { kind = .in; width = 1; }
        else if (std.mem.eql(u8, name, "inw")) { kind = .in; width = 2; }
        else if (std.mem.eql(u8, name, "inl")) { kind = .in; width = 4; }
        // Architecture-neutral names, so kernel source can stop wrapping an
        // x86 mnemonic in inline assembly to say "halt" or "mask interrupts".
        // The x86 spellings below stay accepted, because the whole kernel tree
        // uses them today (home-lang/home-os#60).
        //
        // `arch_` rather than `cpu_`: HomeOS already defines `cpu_halt` and
        // `cpu_pause` as Home functions, and a program's own definition wins
        // over an intrinsic — so a `cpu_halt` intrinsic would turn that
        // function's body into a call to itself.
        else if (std.mem.eql(u8, name, "arch_halt")) { kind = .cpu; cpu_op = .halt; }
        else if (std.mem.eql(u8, name, "arch_disable_interrupts")) { kind = .cpu; cpu_op = .disable_irq; }
        else if (std.mem.eql(u8, name, "arch_enable_interrupts")) { kind = .cpu; cpu_op = .enable_irq; }
        else if (std.mem.eql(u8, name, "arch_nop")) { kind = .cpu; cpu_op = .nop; }
        else if (std.mem.eql(u8, name, "arch_spin_hint")) { kind = .cpu; cpu_op = .spin_hint; }
        else if (std.mem.eql(u8, name, "arch_wait_event")) { kind = .cpu; cpu_op = .wait_event; }
        // `arch_`-prefixed aliases for the MMIO intrinsics. A module that
        // exports its own `mmio_read32` shadows the bare name — a program's
        // definition wins over an intrinsic — so without these it could not
        // call the intrinsic from inside that function without recursing.
        else if (std.mem.eql(u8, name, "arch_mmio_read8")) { kind = .mmio_read; width = 1; }
        else if (std.mem.eql(u8, name, "arch_mmio_read16")) { kind = .mmio_read; width = 2; }
        else if (std.mem.eql(u8, name, "arch_mmio_read32")) { kind = .mmio_read; width = 4; }
        else if (std.mem.eql(u8, name, "arch_mmio_read64")) { kind = .mmio_read; width = 8; }
        else if (std.mem.eql(u8, name, "arch_mmio_write8")) { kind = .mmio_write; width = 1; }
        else if (std.mem.eql(u8, name, "arch_mmio_write16")) { kind = .mmio_write; width = 2; }
        else if (std.mem.eql(u8, name, "arch_mmio_write32")) { kind = .mmio_write; width = 4; }
        else if (std.mem.eql(u8, name, "arch_mmio_write64")) { kind = .mmio_write; width = 8; }
        else if (std.mem.eql(u8, name, "arch_save_interrupts")) { kind = .sys; sys_op = .save_irq; }
        else if (std.mem.eql(u8, name, "arch_restore_interrupts")) { kind = .sys; sys_op = .restore_irq; }
        else if (std.mem.eql(u8, name, "arch_read_timestamp")) { kind = .sys; sys_op = .timestamp; }
        else if (std.mem.eql(u8, name, "arch_atomic_add64")) { kind = .sys; sys_op = .atomic_add; }
        else if (std.mem.eql(u8, name, "arch_read_sysreg")) { kind = .sys; sys_op = .read_sysreg; }
        else if (std.mem.eql(u8, name, "arch_write_sysreg")) { kind = .sys; sys_op = .write_sysreg; }
        else if (std.mem.eql(u8, name, "arch_read_stack_pointer")) { kind = .sys; sys_op = .read_sp; }
        else if (std.mem.eql(u8, name, "arch_write_stack_pointer")) { kind = .sys; sys_op = .write_sp; }
        else if (std.mem.eql(u8, name, "arch_invalidate_tlb_page")) { kind = .sys; sys_op = .invlpg; }
        else if (std.mem.eql(u8, name, "arch_compiler_barrier")) { kind = .sys; sys_op = .compiler_barrier; }
        else if (std.mem.eql(u8, name, "arch_memory_barrier")) { kind = .sys; sys_op = .memory_barrier; }
        else if (std.mem.eql(u8, name, "arch_allow_user_access")) { kind = .sys; sys_op = .allow_user_access; }
        else if (std.mem.eql(u8, name, "arch_forbid_user_access")) { kind = .sys; sys_op = .forbid_user_access; }
        else if (std.mem.eql(u8, name, "arch_user_access_allowed")) { kind = .sys; sys_op = .user_access_allowed; }
        else if (std.mem.eql(u8, name, "arch_atomic_cmpxchg32")) { kind = .sys; sys_op = .cas32; }
        else if (std.mem.eql(u8, name, "arch_atomic_xchg32")) { kind = .sys; sys_op = .xchg32; }
        else if (std.mem.eql(u8, name, "arch_atomic_add32")) { kind = .sys; sys_op = .add32; }
        else if (std.mem.eql(u8, name, "arch_atomic_load32")) { kind = .sys; sys_op = .load32; }
        else if (std.mem.eql(u8, name, "arch_atomic_store32")) { kind = .sys; sys_op = .store32; }
        else if (std.mem.eql(u8, name, "hlt")) { kind = .cpu; cpu_op = .halt; }
        else if (std.mem.eql(u8, name, "cli")) { kind = .cpu; cpu_op = .disable_irq; }
        else if (std.mem.eql(u8, name, "sti")) { kind = .cpu; cpu_op = .enable_irq; }
        else if (std.mem.eql(u8, name, "nop")) { kind = .cpu; cpu_op = .nop; }
        else if (std.mem.eql(u8, name, "pause")) { kind = .cpu; cpu_op = .spin_hint; }
        // Architecture-neutral spellings of the same five operations.
        //
        // The x86 names above are also the names the kernel tree gives its own
        // wrapper functions in `core/foundation.home`, and a program's own
        // definition wins over an intrinsic — which is what makes those
        // wrappers necessary today and what stops them from being written in
        // terms of the intrinsic they shadow. These names do not collide, so a
        // wrapper can call one and stop being inline assembly.
        else if (std.mem.eql(u8, name, "cpu_halt")) { kind = .cpu; cpu_op = .halt; }
        else if (std.mem.eql(u8, name, "cpu_disable_interrupts")) { kind = .cpu; cpu_op = .disable_irq; }
        else if (std.mem.eql(u8, name, "cpu_enable_interrupts")) { kind = .cpu; cpu_op = .enable_irq; }
        else if (std.mem.eql(u8, name, "cpu_nop")) { kind = .cpu; cpu_op = .nop; }
        else if (std.mem.eql(u8, name, "cpu_spin_hint")) { kind = .cpu; cpu_op = .spin_hint; }
        else if (std.mem.eql(u8, name, "mfence")) { kind = .barrier; barrier_kind = .full; }
        // Architecture-neutral barrier names (home-lang/home#584). The x86
        // spellings above stay accepted so existing kernel source keeps
        // building.
        else if (std.mem.eql(u8, name, "barrier_full")) { kind = .barrier; barrier_kind = .full; }
        else if (std.mem.eql(u8, name, "barrier_loads")) { kind = .barrier; barrier_kind = .loads; }
        else if (std.mem.eql(u8, name, "barrier_stores")) { kind = .barrier; barrier_kind = .stores; }
        else if (std.mem.eql(u8, name, "barrier_sync")) { kind = .barrier; barrier_kind = .isync; }
        else if (std.mem.eql(u8, name, "mmio_read8")) { kind = .mmio_read; width = 1; }
        else if (std.mem.eql(u8, name, "mmio_read16")) { kind = .mmio_read; width = 2; }
        else if (std.mem.eql(u8, name, "mmio_read32")) { kind = .mmio_read; width = 4; }
        else if (std.mem.eql(u8, name, "mmio_read64")) { kind = .mmio_read; width = 8; }
        else if (std.mem.eql(u8, name, "mmio_write8")) { kind = .mmio_write; width = 1; }
        else if (std.mem.eql(u8, name, "mmio_write16")) { kind = .mmio_write; width = 2; }
        else if (std.mem.eql(u8, name, "mmio_write32")) { kind = .mmio_write; width = 4; }
        else if (std.mem.eql(u8, name, "mmio_write64")) { kind = .mmio_write; width = 8; }
        else return false;

        switch (kind) {
            .cpu => {
                if (args.len != 0) {
                    try self.print("    # {s}() takes no arguments, {d} given\n", .{ name, args.len });
                    return false;
                }
                switch (cpu_op) {
                    .halt => try self.emit().halt(),
                    .disable_irq => try self.emit().disableInterrupts(),
                    .enable_irq => try self.emit().enableInterrupts(),
                    .nop => try self.emit().nop(),
                    .spin_hint => try self.emit().spinHint(),
                    .wait_event => try self.emit().waitForEvent(),
                }
            },
            .sys => switch (sys_op) {
                .save_irq, .timestamp => {
                    if (args.len != 0) {
                        try self.print("    # {s}() takes no arguments, {d} given\n", .{ name, args.len });
                        return false;
                    }
                    if (sys_op == .save_irq) {
                        try self.emit().saveInterrupts();
                    } else {
                        try self.emit().readTimestamp();
                    }
                },
                .restore_irq => {
                    if (args.len != 1) {
                        try self.print("    # {s}(flags) needs 1 argument, {d} given\n", .{ name, args.len });
                        return false;
                    }
                    try self.generateExpr(args[0]);
                    try self.emit().restoreInterrupts();
                },
                .atomic_add => {
                    if (args.len != 2) {
                        try self.print("    # {s}(addr, value) needs 2 arguments, {d} given\n", .{ name, args.len });
                        return false;
                    }
                    // Value first, parked; then the address, so a nested call
                    // in either argument cannot clobber the other.
                    try self.generateExpr(args[1]);
                    try self.emit().push(.acc);
                    try self.generateExpr(args[0]);
                    try self.emit().movReg(.tmp3, .acc);
                    try self.emit().pop(.tmp);
                    try self.emit().atomicAdd64(self.freshLabel());
                },
                .read_sp => {
                    if (args.len != 0) {
                        try self.print("    # {s}() takes no arguments, {d} given\n", .{ name, args.len });
                        return false;
                    }
                    try self.emit().movFromStackPtr(.acc);
                },
                .write_sp, .invlpg => {
                    if (args.len != 1) {
                        try self.print("    # {s} needs 1 argument, {d} given\n", .{ name, args.len });
                        return false;
                    }
                    try self.generateExpr(args[0]);
                    if (sys_op == .write_sp) {
                        try self.emit().writeStackPtr();
                    } else {
                        try self.emit().invalidateTlbPage();
                    }
                },
                .compiler_barrier => {
                    if (args.len != 0) {
                        try self.print("    # {s}() takes no arguments, {d} given\n", .{ name, args.len });
                        return false;
                    }
                    try self.emit().compilerBarrier();
                },
                .memory_barrier => {
                    if (args.len != 0) {
                        try self.print("    # {s}() takes no arguments, {d} given\n", .{ name, args.len });
                        return false;
                    }
                    try self.emit().memoryBarrier();
                },
                .allow_user_access => {
                    if (args.len != 0) {
                        try self.print("    # {s}() takes no arguments, {d} given\n", .{ name, args.len });
                        return false;
                    }
                    try self.emit().allowUserAccess();
                },
                .forbid_user_access => {
                    if (args.len != 0) {
                        try self.print("    # {s}() takes no arguments, {d} given\n", .{ name, args.len });
                        return false;
                    }
                    try self.emit().forbidUserAccess();
                },
                .user_access_allowed => {
                    if (args.len != 0) {
                        try self.print("    # {s}() takes no arguments, {d} given\n", .{ name, args.len });
                        return false;
                    }
                    try self.emit().userAccessAllowed();
                },
                .load32 => {
                    if (args.len != 1) {
                        try self.print("    # {s}(addr) needs 1 argument, {d} given\n", .{ name, args.len });
                        return false;
                    }
                    try self.generateExpr(args[0]);
                    try self.emit().movReg(.tmp3, .acc);
                    try self.emit().atomicLoad32();
                },
                .store32, .xchg32, .add32 => {
                    if (args.len != 2) {
                        try self.print("    # {s}(addr, value) needs 2 arguments, {d} given\n", .{ name, args.len });
                        return false;
                    }
                    // Value first, parked, then the address — so a nested call
                    // in either argument cannot clobber the other.
                    try self.generateExpr(args[1]);
                    try self.emit().push(.acc);
                    try self.generateExpr(args[0]);
                    try self.emit().movReg(.tmp3, .acc);
                    try self.emit().pop(.tmp);
                    switch (sys_op) {
                        .store32 => try self.emit().atomicStore32(),
                        .xchg32 => try self.emit().atomicExchange32(self.freshLabel()),
                        else => try self.emit().atomicAdd32(self.freshLabel()),
                    }
                },
                .cas32 => {
                    if (args.len != 3) {
                        try self.print("    # {s}(addr, expected, desired) needs 3 arguments, {d} given\n", .{ name, args.len });
                        return false;
                    }
                    // desired -> tmp, expected -> acc, addr -> tmp3.
                    try self.generateExpr(args[2]);
                    try self.emit().push(.acc);
                    try self.generateExpr(args[1]);
                    try self.emit().push(.acc);
                    try self.generateExpr(args[0]);
                    try self.emit().movReg(.tmp3, .acc);
                    try self.emit().pop(.acc);
                    try self.emit().pop(.tmp);
                    try self.emit().atomicCompareExchange32(self.freshLabel());
                },
                .read_sysreg, .write_sysreg => {
                    const want: usize = if (sys_op == .read_sysreg) 1 else 2;
                    if (args.len != want) {
                        try self.print("    # {s} needs {d} argument(s), {d} given\n", .{ name, want, args.len });
                        return false;
                    }
                    if (args[0].* != .StringLiteral) {
                        try self.print("    # ERROR: {s} names its register with a string literal\n", .{name});
                        return false;
                    }
                    const regname = args[0].StringLiteral.value;
                    if (!self.emit().knowsSysreg(regname)) {
                        try self.print(
                            "    # ERROR: {s} is not a system register this backend can reach on {s}\n",
                            .{ regname, @tagName(self.arch) },
                        );
                        return false;
                    }
                    if (sys_op == .read_sysreg) {
                        try self.emit().readSysreg(regname);
                    } else {
                        try self.generateExpr(args[1]);
                        try self.emit().writeSysreg(regname);
                    }
                },
            },
            .barrier => {
                if (args.len != 0) {
                    try self.print("    # {s}() takes no arguments, {d} given\n", .{ name, args.len });
                    return false;
                }
                try self.emit().barrier(barrier_kind);
            },
            .out, .in => {
                // A separate I/O address space is an x86 concept. Emitting
                // nothing, or an approximation, would leave a driver that
                // looks correct and touches no hardware — so refuse, and name
                // the replacement.
                if (!self.emit().hasPortIo()) {
                    try self.print(
                        "    # ERROR: {s}() needs a port I/O address space, which {s} does not have.\n" ++
                            "    # ERROR: use mmio_read{d}/mmio_write{d} against the device's register address instead.\n",
                        .{ name, @tagName(self.arch), width * 8, width * 8 },
                    );
                    return false;
                }
                const acc_reg = self.emit().subReg(.acc, width);
                const suffix = switch (width) {
                    1 => "b",
                    2 => "w",
                    else => "l",
                };
                if (kind == .out) {
                    if (args.len != 2) {
                        try self.print("    # {s}(port, value) needs 2 arguments, {d} given\n", .{ name, args.len });
                        return false;
                    }
                    try self.generateExpr(args[1]);
                    try self.emit().push(.acc);
                    try self.generateExpr(args[0]);
                    try self.emit().movReg(.tmp3, .acc);
                    try self.emit().pop(.acc);
                    try self.print("    out{s} {s}, %dx\n", .{ suffix, acc_reg });
                } else {
                    if (args.len != 1) {
                        try self.print("    # {s}(port) needs 1 argument, {d} given\n", .{ name, args.len });
                        return false;
                    }
                    try self.generateExpr(args[0]);
                    try self.emit().movReg(.tmp3, .acc);
                    try self.emit().zero(.acc);
                    try self.print("    in{s} %dx, {s}\n", .{ suffix, acc_reg });
                }
            },
            .mmio_read => {
                if (args.len != 1) {
                    try self.print("    # {s}(addr) needs 1 argument, {d} given\n", .{ name, args.len });
                    return false;
                }
                try self.generateExpr(args[0]);
                try self.emit().movReg(.tmp3, .acc);
                try self.emit().zero(.acc);
                try self.emit().loadIndirect(.acc, .tmp3, width, false);
                try self.emit().mmioBarrierAfterRead();
            },
            .mmio_write => {
                if (args.len != 2) {
                    try self.print("    # {s}(addr, value) needs 2 arguments, {d} given\n", .{ name, args.len });
                    return false;
                }
                try self.generateExpr(args[1]);
                try self.emit().push(.acc);
                try self.generateExpr(args[0]);
                try self.emit().movReg(.tmp3, .acc);
                try self.emit().pop(.tmp);
                try self.emit().mmioBarrierBeforeWrite();
                try self.emit().storeIndirect(.tmp, .tmp3, width);
            },
            .none => unreachable,
        }
        return true;
    }

    /// Narrow the accumulator to the width of `type_name`, if that width is
    /// known and smaller than a word. A widening or same-width cast needs no
    /// work: the
    /// value is already in the accumulator.
    fn emitNarrowTo(self: *HomeKernelCodegen, type_name: []const u8) !void {
        const bare = splitAlign(type_name).bare;
        const size = self.sizeOf(bare) orelse return;
        if (size >= 8) return;
        const signed = bare.len > 0 and bare[0] == 'i';
        try self.emit().narrow(size, signed);
    }

    /// Narrow the accumulator to `type_name` when that names a primitive
    /// integer narrower than a word.
    ///
    /// Home's arithmetic runs in 64-bit registers, so a u32 addition that
    /// carries past bit 31 keeps the carry. Storing it into a u32 without
    /// truncating leaves a value the type cannot represent, and every later
    /// read of that variable sees it. That is what made SHA-256 wrong here:
    /// the algorithm is defined modulo 2^32 and nothing was reducing it.
    ///
    /// Restricted to primitives on purpose. Pointers and aggregates are held
    /// as addresses, and narrowing one would corrupt it.
    fn narrowToDeclared(self: *HomeKernelCodegen, type_name: []const u8) !void {
        const bare = splitAlign(type_name).bare;
        if (bare.len == 0) return;
        if (!std.mem.eql(u8, bare, "bool") and bare[0] != 'u' and bare[0] != 'i') return;
        if (bitWidthOfType(bare) == null) return;
        try self.emitNarrowTo(bare);
    }

    /// Emit a comparison of the accumulator against `tmp`, leaving 0 or 1 in
    /// the accumulator.
    fn emitCompare(self: *HomeKernelCodegen, cond: Cond) !void {
        try self.emit().compareSet(cond);
    }

    /// Build a local label whose suffix is a name rather than a number.
    fn labelText2(self: *HomeKernelCodegen, comptime kind: []const u8, suffix: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.import_arena.allocator(), ".L_" ++ kind ++ "_{s}", .{suffix});
    }

    /// Build a local label, owned by the import arena so it outlives the call.
    fn labelText(self: *HomeKernelCodegen, comptime kind: []const u8, id: usize) ![]const u8 {
        return std.fmt.allocPrint(self.import_arena.allocator(), ".L_" ++ kind ++ "_{d}", .{id});
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
                // Loop bodies declare locals too. Only WhileStmt was walked,
                // so a `let` inside a for or do-while got no frame slot and no
                // recorded type — every later use of it was refused as an
                // undefined variable or an untyped base, pointing at the use
                // rather than at the declaration that was skipped.
                .ForStmt => |s2| {
                    // The iterator binding is a local of the loop as well.
                    if (!self.locals.contains(s2.iterator)) {
                        self.stack_offset -= 8;
                        try self.locals.put(s2.iterator, self.stack_offset);
                    }
                    // And so is the loop's limit. It is evaluated once, before
                    // the first iteration, so that `for i in 0..f()` calls f
                    // once rather than on every pass — and so that a body which
                    // changes what the bound was computed from does not change
                    // the number of iterations underneath itself.
                    {
                        const limit_name = try std.fmt.allocPrint(
                            self.import_arena.allocator(),
                            "__for_limit_{s}",
                            .{s2.iterator},
                        );
                        if (!self.locals.contains(limit_name)) {
                            self.stack_offset -= 8;
                            try self.locals.put(limit_name, self.stack_offset);
                        }
                    }
                    if (s2.index) |idx| {
                        if (!self.locals.contains(idx)) {
                            self.stack_offset -= 8;
                            try self.locals.put(idx, self.stack_offset);
                        }
                    }
                    try self.reserveLocals(s2.body.statements);
                },
                .DoWhileStmt => |s2| try self.reserveLocals(s2.body.statements),
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
        // Establish this module's symbol prefix before anything is emitted.
        if (self.module_id.len == 0) {
            if (self.source_file) |path| {
                self.module_id = try moduleIdFromPath(self.import_arena.allocator(), path);
            }
        }

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

        // Type aliases first: a struct field may be written as an alias, and
        // an unsizable field makes the whole struct unlayoutable.
        for (program.statements) |stmt| {
            if (stmt == .TypeAliasDecl) {
                const decl = stmt.TypeAliasDecl;
                if (!self.type_aliases.contains(decl.name)) {
                    try self.type_aliases.put(decl.name, decl.target_type);
                }
            }
        }

        // Extern names must be known before any call is lowered, since a call
        // can precede the declaration in the file.
        for (program.statements) |stmt| {
            if (stmt == .FnDecl and stmt.FnDecl.is_extern) {
                try self.extern_fns.put(stmt.FnDecl.name, {});
            }
        }

        try self.foldModuleConstants(program);
        try self.collectEnums(program);
        try self.layoutStructs(program);

        // Module-level storage, before any function body is lowered.
        //
        // Functions already forward-reference each other freely, because
        // declared_fns is populated in a pass of its own above. Module
        // variables were not: a `var` was registered only when the statement
        // was reached, so a function defined earlier in the file saw the name
        // as undefined and its assignment became
        // "# ERROR: assignment to undefined variable".
        //
        // That made a file's meaning depend on the order its declarations
        // happened to be written in, which nothing in the language says it
        // should — and the failure is quiet in the worst way: the read
        // compiles to zero rather than to a diagnostic the build stops on.
        //
        // Runs after struct layout because a variable's size may come from a
        // struct declared anywhere in the file.
        for (program.statements) |stmt| {
            if (stmt != .LetDecl) continue;
            const decl = stmt.LetDecl;
            if (decl.is_mutable or self.assigned_names.contains(decl.name)) {
                _ = self.declareGlobalVar(decl) catch continue;
            }
        }

        // Generate code for each statement
        for (program.statements) |stmt| {
            try self.generateStmt(stmt);
        }

        try self.emitGlobals();

        // Emit .rodata section with string literals
        if (self.string_literals.items.len > 0) {
            try self.emit().sectionRodata();

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
                // Forward declarations (issue #17) bind the name only, and an
                // extern names a symbol something else defines.
                if (func.is_forward_decl or func.is_extern) return;

                // Respect the `export` keyword. The previous heuristic — any
                // name starting with "kernel_", plus "main" — both missed
                // genuinely exported functions and exported private helpers
                // that happened to be named kernel_something.
                const is_export = func.is_exported or
                    std.mem.eql(u8, func.name, "main") or
                    std.mem.eql(u8, func.name, "kernel_main");

                const sym = try self.functionSymbol(func.name);
                if (is_export) {
                    try self.print(".global {s}\n", .{sym});
                }
                try self.print("{s}:\n", .{sym});

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

                try self.emit().prologue(frame_size);

                // Spill incoming arguments into their slots. Without this,
                // every parameter reference emitted a "# not in locals"
                // comment and read whatever happened to be in %rax.
                var reg_index: usize = 0;
                if (self.sret_slot != 0) {
                    try self.emit().storeNamedLocal(self.emit().argReg(0).?, self.sret_slot);
                    reg_index = 1;
                }
                for (func.params) |param| {
                    const slot = self.locals.get(param.name) orelse continue;
                    const words: usize = if (isSliceType(splitAlign(param.type_name).bare)) 2 else 1;
                    var w: usize = 0;
                    while (w < words) : (w += 1) {
                        const dest = slot + @as(i32, @intCast(w * 8));
                        if (self.emit().argReg(reg_index)) |areg| {
                            try self.emit().storeNamedLocal(areg, dest);
                        } else {
                            // Arguments past the registers arrive above the
                            // return address.
                            const caller_offset = 16 + (reg_index - self.arch.argRegCount()) * 8;
                            try self.emit().loadLocal(.acc, @intCast(caller_offset));
                            try self.emit().storeLocal(.acc, @intCast(dest));
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
                    try self.emit().epilogue();
                    try self.emit().ret();
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
                                    try self.emit().leaLocal(.acc, @intCast(slot));
                                    try self.emitStructLiteralToMemory(tn, value.StructLiteral);
                                }
                            } else if (value.* == .ArrayLiteral or value.* == .ArrayRepeat) {
                                if (self.locals.get(decl.name)) |slot| {
                                    try self.emit().leaLocal(.acc, @intCast(slot));
                                    try self.emitArrayLiteralToMemory(tn, value);
                                }
                            } else if (self.typeOfLValue(value) != null) {
                                if (self.locals.get(decl.name)) |slot| {
                                    try self.emit().leaLocal(.acc, @intCast(slot));
                                    try self.emitStoreToAddress(tn, value);
                                }
                            }
                        }
                        return;
                    }
                }
                if (decl.value) |value| {
                    try self.generateExpr(value);
                    if (decl.type_name) |tn| try self.narrowToDeclared(tn);
                    if (self.locals.get(decl.name)) |slot| {
                        try self.emit().storeLocal(.acc, @intCast(slot));
                    } else {
                        try self.print("    # ERROR: no frame slot reserved for {s}\n", .{decl.name});
                    }
                }
            },
            .IfStmt => |if_stmt| {
                // A condition known at compile time selects one branch, and
                // the other is not emitted at all. This is what makes
                // `@targetIs` usable for architecture-specific code: the
                // branch not taken holds inline assembly for the other
                // machine, and emitting it — even behind a jump that is never
                // taken — would hand x86 text to the ARM assembler.
                //
                // Restricted to conditions that mention `@targetIs`. Folding
                // every constant condition would also silently delete a
                // `if (DEBUG) { ... }` block, which is a much bigger change in
                // behaviour than this issue is asking for.
                if (exprMentionsTargetIs(if_stmt.condition)) {
                    if (self.foldConst(if_stmt.condition)) |value| {
                        if (value != 0) {
                            for (if_stmt.then_block.statements) |then_stmt| {
                                try self.generateStmt(then_stmt);
                            }
                        } else if (if_stmt.else_block) |else_block| {
                            for (else_block.statements) |else_stmt| {
                                try self.generateStmt(else_stmt);
                            }
                        }
                        return;
                    }
                }

                // Generate if statement
                try self.generateExpr(if_stmt.condition);

                // Branch on the condition, which the expression left in the
                // accumulator.
                const label_num = self.freshLabel();
                try self.emit().jumpIfZero(.acc, try self.labelText("else", label_num));

                // Then block
                for (if_stmt.then_block.statements) |then_stmt| {
                    try self.generateStmt(then_stmt);
                }

                if (if_stmt.else_block) |else_block| {
                    try self.emit().jump(try self.labelText("endif", label_num));
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
                try self.emit().jumpIfZero(.acc, end);

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

                try self.emit().jump(start);
                try self.print("{s}:\n", .{end});
            },
            .ForStmt => |for_stmt| {
                // `for i in a..b` and `for i in a..=b`. Iterating a collection
                // is a different lowering and is not done here; saying so
                // names the construct rather than emitting a loop that runs
                // zero times.
                if (for_stmt.iterable.* != .RangeExpr) {
                    try self.print("    # ERROR: unsupported statement: ForStmt over a non-range iterable\n", .{});
                    return;
                }
                const range = for_stmt.iterable.RangeExpr;
                if (range.step != null) {
                    try self.print("    # ERROR: unsupported statement: ForStmt with a step\n", .{});
                    return;
                }

                const iter_slot = self.locals.get(for_stmt.iterator) orelse {
                    try self.print("    # ERROR: no frame slot reserved for {s}\n", .{for_stmt.iterator});
                    return;
                };
                const limit_name = try std.fmt.allocPrint(
                    self.allocator,
                    "__for_limit_{s}",
                    .{for_stmt.iterator},
                );
                defer self.allocator.free(limit_name);
                const limit_slot = self.locals.get(limit_name) orelse {
                    try self.print("    # ERROR: no frame slot reserved for the bound of {s}\n", .{for_stmt.iterator});
                    return;
                };

                try self.generateExpr(range.start);
                try self.emit().storeLocal(.acc, @intCast(iter_slot));
                try self.generateExpr(range.end);
                try self.emit().storeLocal(.acc, @intCast(limit_slot));

                const label_num = self.freshLabel();
                const start = try std.fmt.allocPrint(self.allocator, ".L_for_start_{d}", .{label_num});
                defer self.allocator.free(start);
                const step_label = try std.fmt.allocPrint(self.allocator, ".L_for_step_{d}", .{label_num});
                defer self.allocator.free(step_label);
                const end = try std.fmt.allocPrint(self.allocator, ".L_for_end_{d}", .{label_num});
                defer self.allocator.free(end);

                try self.print("{s}:\n", .{start});
                // Left operand in the accumulator, right in tmp, matching what
                // a comparison expression builds.
                try self.emit().loadLocal(.acc, @intCast(iter_slot));
                try self.emit().push(.acc);
                try self.emit().loadLocal(.acc, @intCast(limit_slot));
                try self.emit().movReg(.tmp, .acc);
                try self.emit().pop(.acc);
                try self.emitCompare(if (range.inclusive) .le else .lt);
                try self.emit().jumpIfZero(.acc, end);

                // `continue` goes to the increment, not the top: jumping to the
                // top would skip it and spin forever.
                const prev_break = self.loop_break;
                const prev_continue = self.loop_continue;
                self.loop_break = end;
                self.loop_continue = step_label;

                for (for_stmt.body.statements) |body_stmt| {
                    try self.generateStmt(body_stmt);
                }

                self.loop_break = prev_break;
                self.loop_continue = prev_continue;

                try self.print("{s}:\n", .{step_label});
                try self.emit().loadLocal(.acc, @intCast(iter_slot));
                try self.emit().addImm(.acc, 1);
                try self.emit().storeLocal(.acc, @intCast(iter_slot));
                try self.emit().jump(start);
                try self.print("{s}:\n", .{end});
            },
            .ReturnStmt => |return_stmt| {
                // Value in %rax, then jump to the function's one epilogue.
                if (return_stmt.value) |value| {
                    if (self.sret_slot != 0) {
                        // Copy into the caller's destination and hand the
                        // pointer back in %rax, as the ABI expects.
                        try self.emit().loadLocal(.acc, @intCast(self.sret_slot));
                        if (value.* == .StructLiteral) {
                            try self.emit().push(.acc);
                            try self.emitStructLiteralToMemory(
                                self.current_return_type,
                                value.StructLiteral,
                            );
                        } else if (self.typeOfLValue(value) != null) {
                            try self.emit().push(.acc);
                            if (try self.emitAddress(value)) |_| {
                                try self.emit().movReg(.mem_src, .acc);
                                try self.emit().pop(.mem_dst);
                                try self.emit().movImmReg(.mem_len, @intCast(self.sizeOf(self.current_return_type) orelse 8));
                                try self.emit().memCopy(self.freshLabel());
                            } else {
                                try self.emit().addStack(self.emit().pushStride());
                            }
                        } else {
                            try self.print("    # ERROR: cannot return a {s} built from this expression\n", .{self.current_return_type});
                        }
                        try self.emit().loadLocal(.acc, @intCast(self.sret_slot));
                        if (self.current_fn.len > 0) {
                            try self.emit().jump(try self.labelText2("epilogue", self.current_fn));
                            return;
                        }
                    }
                    try self.generateExpr(value);
                    // A function declared to return a narrow integer returns
                    // one. Without this a u32-returning helper handed its
                    // caller the full 64-bit accumulator — which is how
                    // `rotr()` leaked bits above 31 into every round of
                    // SHA-256.
                    if (self.current_return_type.len > 0) {
                        try self.narrowToDeclared(self.current_return_type);
                    }
                }
                if (self.current_fn.len > 0) {
                    try self.emit().jump(try self.labelText2("epilogue", self.current_fn));
                } else {
                    try self.emit().epilogue();
                    try self.emit().ret();
                }
            },
            .BreakStmt => {
                if (self.loop_break.len > 0) {
                    try self.emit().jump(self.loop_break);
                }
            },
            .ContinueStmt => {
                if (self.loop_continue.len > 0) {
                    try self.emit().jump(self.loop_continue);
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
                try self.emit().push(.acc);

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
                        try self.emit().movReg(.tmp, .acc);
                        try self.emit().loadPushed(.acc, 0);
                        try self.emit().cmpRegs(.acc, .tmp);
                        try self.emit().jumpCond(.eq, b.label);
                    }
                }
                if (default_clause) |di| {
                    try self.emit().jump(try std.fmt.allocPrint(
                        self.import_arena.allocator(),
                        ".L_switch_case_{d}_{d}",
                        .{ label_num, di },
                    ));
                }
                try self.emit().jump(end_label);

                // Pass 2: bodies, each closed with a jump to the end.
                for (bodies.items) |b| {
                    try self.print("{s}:\n", .{b.label});
                    const clause = sw.cases[b.clause_idx];
                    for (clause.body) |body_stmt| {
                        try self.generateStmt(body_stmt);
                    }
                    try self.emit().jump(end_label);
                }
                if (default_clause) |di| {
                    try self.print(".L_switch_case_{d}_{d}:\n", .{ label_num, di });
                    for (sw.cases[di].body) |body_stmt| {
                        try self.generateStmt(body_stmt);
                    }
                    try self.emit().jump(end_label);
                }

                try self.print("{s}:\n", .{end_label});
                try self.emit().addStack(self.emit().pushStride());
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
                        try self.emit().movImm(@intCast(v));
                    } else {
                        try self.emit().movImm(@intCast(v));
                    }
                } else if (std.math.cast(u64, lit.value)) |uv| {
                    // Unsigned values above i64 max are still 64-bit patterns;
                    // reinterpret rather than refuse. u64 max is how a kernel
                    // spells an all-ones mask.
                    try self.emit().movImm(@intCast(@as(i64, @bitCast(uv))));
                } else {
                    try self.print("    # ERROR: integer literal {d} does not fit in 64 bits\n", .{lit.value});
                    try self.emit().movImm(0);
                }
            },
            .BooleanLiteral => |lit| {
                // Load boolean as integer (0 or 1) into %rax
                try self.emit().movImm(@intCast(if (lit.value) @as(i64, 1) else @as(i64, 0)));
            },
            .InlineAsm => |asm_node| {
                try self.emitInlineAsm(asm_node);
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
                try self.emit().leaSymbol(.acc, try self.labelText("str", label_num));
            },
            .CallExpr => |call| {
                // Check if this is a module member call (e.g., serial.init())
                if (call.callee.* == .MemberExpr) {
                    const member = call.callee.MemberExpr;

                    // Get module name from object
                    if (member.object.* == .Identifier) {
                        const module_name = member.object.Identifier.name;
                        const func_name = member.member;

                        // A Home module imported under this alias: call the
                        // symbol that module defines. This is the whole point
                        // of module-scoped names — `serial.writeChar` and
                        // `vga.writeChar` are different functions.
                        if (self.module_aliases.get(module_name)) |mod_id| {
                            if (call.args.len > 0) {
                                var words: usize = 0;
                                var i: usize = call.args.len;
                                while (i > 0) {
                                    i -= 1;
                                    words += try self.pushArgument(call.args[i]);
                                }
                                for (0..words) |reg_idx| {
                                    const areg = self.emit().argReg(reg_idx) orelse break;
                                    try self.emit().popNamed(areg);
                                }
                            }
                            if (isBootEntryPoint(func_name)) {
                                try self.emit().call(func_name);
                            } else {
                                try self.emit().call(try std.fmt.allocPrint(self.import_arena.allocator(), "{s}__{s}", .{ mod_id, func_name }));
                            }
                        } else if (self.symbol_table.lookupMemberSymbol(module_name, func_name)) |symbol| {
                            // A Zig module reached through FFI.
                            try self.generateFFICall(symbol, call.args);
                        } else if (try self.emitIndirectMemberCall(member, call.args)) {
                            // A function pointer held in a struct field —
                            // `driver.init_fn()`. Driver tables and callback
                            // records are built out of these.
                        } else {
                            try self.print("    # ERROR: unresolved call {s}.{s}\n", .{ module_name, func_name });
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
                                if (self.emit().argReg(reg_idx)) |areg| {
                                    try self.emit().popNamed(areg);
                                } else {
                                    // Arguments beyond six stay on the stack.
                                    break;
                                }
                            }
                        }

                        // A name declared in this file resolves to this
                        // module's symbol. Anything else is left bare — an
                        // external the linker must supply, which fails loudly
                        // if it does not exist.
                        if (self.declared_fns.contains(func_name)) {
                            try self.emit().call(try self.functionSymbol(func_name));
                        } else if (try self.isCallableVariable(func_name)) {
                            // Indirect call through a function-pointer
                            // variable: callbacks, handler tables, driver
                            // ops. The pointer is loaded AFTER the arguments
                            // are in place (it may live in a stack slot the
                            // argument pushes must not disturb).
                            var had_ptr: bool = false;
                            if (self.locals.get(func_name)) |slot| {
                                try self.emit().loadLocal(.scratch2, @intCast(slot));
                                had_ptr = true;
                            } else if (self.global_vars.get(func_name)) |gv| {
                                try self.emit().loadSymbol(.scratch2, gv.symbol);
                                had_ptr = true;
                            }
                            if (!had_ptr) {
                                try self.print("    # ERROR: cannot lower call through '{s}'\n", .{func_name});
                            }
                            try self.emit().callReg(.scratch2);
                        } else {
                            try self.emit().call(func_name);
                        }
                    }
                }
            },
            .BinaryExpr => |binary| {
                // `&&` and `||` must short-circuit, so they cannot use the
                // evaluate-both-operands shape below.
                if (binary.op == .And or binary.op == .Or) {
                    const label_num = self.freshLabel();
                    const short_label = try self.labelText("logic_short", label_num);
                    const end_label = try self.labelText("logic_end", label_num);
                    try self.generateExpr(binary.left);
                    if (binary.op == .And) {
                        try self.emit().jumpIfZero(.acc, short_label);
                    } else {
                        try self.emit().jumpIfNotZero(.acc, short_label);
                    }
                    try self.generateExpr(binary.right);
                    try self.emit().boolNormalize();
                    try self.emit().jump(end_label);
                    try self.print(".L_logic_short_{d}:\n", .{label_num});
                    // Short-circuited: the answer is the left operand's truth.
                    try self.emit().movImm(@intCast(if (binary.op == .And) @as(i64, 0) else @as(i64, 1)));
                    try self.print(".L_logic_end_{d}:\n", .{label_num});
                    return;
                }

                // Left in %rax, right in %rcx. Evaluate left first and stash
                // it, so operand order matches source order — the previous
                // code evaluated the right operand first, which is observable
                // as soon as either side has a side effect.
                try self.generateExpr(binary.left);
                try self.emit().push(.acc);
                try self.generateExpr(binary.right);
                try self.emit().movReg(.tmp, .acc);
                try self.emit().pop(.acc);

                switch (binary.op) {
                    .Add, .CheckedAdd => try self.emit().binOp(.add),
                    .Sub, .CheckedSub => try self.emit().binOp(.sub),
                    .Mul, .CheckedMul => try self.emit().binOp(.mul),
                    .Div, .IntDiv, .CheckedDiv => try self.emit().binOp(.div),
                    .Mod => try self.emit().binOp(.rem),
                    .BitAnd => try self.emit().binOp(.bit_and),
                    .BitOr => try self.emit().binOp(.bit_or),
                    .BitXor => try self.emit().binOp(.bit_xor),
                    .LeftShift => try self.emit().binOp(.shl),
                    .RightShift => {
                        // `sarq` propagates the sign bit. On an unsigned value
                        // with bit 63 set that fills the top with ones instead
                        // of zeros, so `x >> n` returned a number larger than
                        // `x` — wrong for every unsigned use, which is nearly
                        // all of them in a kernel: field extraction, byte
                        // splitting, and every checksum and hash.
                        //
                        // Arithmetic shift is correct only when the left
                        // operand is known to be signed. When the type cannot
                        // be recovered the logical shift is the safer default:
                        // this tree's integers are overwhelmingly unsigned.
                        const left_type = self.typeOfLValue(binary.left);
                        const signed = if (left_type) |t| blk: {
                            const bare = splitAlign(t).bare;
                            break :blk bare.len > 1 and bare[0] == 'i';
                        } else false;
                        try self.emit().binOp(if (signed) .shr_arith else .shr_logical);
                    },
                    .Power => {
                        // Integer exponentiation by repeated multiplication;
                        // %rax = base, %rcx = exponent.
                        const lbl = self.freshLabel();
                        try self.emit().movReg(.tmp2, .acc);
                        try self.emit().movImm(1);
                        try self.print(".L_pow_start_{d}:\n", .{lbl});
                        try self.emit().cmpImm(.tmp, 0);
                        try self.emit().jumpCond(.le, try self.labelText("pow_end", lbl));
                        try self.emit().aluRegs(.mul, .acc, .tmp2);
                        try self.emit().addImm(.tmp, -1);
                        try self.emit().jump(try self.labelText("pow_start", lbl));
                        try self.print(".L_pow_end_{d}:\n", .{lbl});
                    },
                    .Equal => try self.emitCompare(.eq),
                    .NotEqual => try self.emitCompare(.ne),
                    .Less => try self.emitCompare(.lt),
                    .LessEq => try self.emitCompare(.le),
                    .Greater => try self.emitCompare(.gt),
                    .GreaterEq => try self.emitCompare(.ge),
                    else => {
                        try self.print("    # unsupported binary operator: {s}\n", .{@tagName(binary.op)});
                    },
                }
            },
            .IndexExpr, .MemberExpr => {
                // `module.CONSTANT` is a compile-time value, not a field read.
                // Imported constants are registered under their qualified name,
                // but only the identifier path consulted that table — so a
                // constant reached through its module alias was treated as a
                // field of a value and refused.
                if (expr.* == .MemberExpr) {
                    const m = expr.MemberExpr;
                    if (m.object.* == .Identifier) {
                        const key = try std.fmt.allocPrint(
                            self.import_arena.allocator(),
                            "{s}.{s}",
                            .{ m.object.Identifier.name, m.member },
                        );
                        if (self.globals.get(key)) |value| {
                            try self.emit().movImm(@intCast(value));
                            return;
                        }
                        if (self.enum_values.get(key)) |value| {
                            try self.emit().movImm(@intCast(value));
                            return;
                        }
                    }
                }
                // A bitfield member is a bit range inside an integer, not a
                // value at a byte offset: load the whole backing integer,
                // shift it down, and mask.
                if (expr.* == .MemberExpr) {
                    if (try self.bitFieldOf(expr.MemberExpr)) |bf| {
                        const addr_type = try self.emitAddress(expr.MemberExpr.object) orelse {
                            try self.emit().movImm(0);
                            return;
                        };
                        _ = addr_type;
                        try self.emitLoadBacking(bf.container_size);
                        if (bf.field.bit_offset > 0) {
                            try self.emit().shiftImm(.shr_logical, @intCast(bf.field.bit_offset));
                        }
                        if (bf.field.bit_width < 64) {
                            const mask: u64 = (@as(u64, 1) << @intCast(bf.field.bit_width)) - 1;
                            try self.emit().movImmReg(.tmp, @intCast(@as(i64, @bitCast(mask))));
                            try self.emit().binOp(.bit_and);
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
                                try self.emit().movImm(@intCast(v));
                                return;
                            }
                            try self.print("    # ERROR: enum {s} has no variant {s}\n", .{ enum_name, m.member });
                            try self.emit().movImm(0);
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
                                try self.emit().movImm(@intCast(arr.count));
                                return;
                            }
                        }
                    }
                }
                // Address into %rax, then load the value it points at.
                const t = try self.emitAddress(expr) orelse {
                    try self.emit().movImm(0);
                    return;
                };
                try self.emitLoadFromAddress(t);
            },
            .UnaryExpr => |unary| {
                // `&x` is the address of an lvalue, not a value computation.
                if (unary.op == .AddressOf or unary.op == .Borrow or unary.op == .BorrowMut) {
                    _ = try self.emitAddress(unary.operand) orelse {
                        try self.emit().movImm(0);
                    };
                    return;
                }
                try self.generateExpr(unary.operand);
                switch (unary.op) {
                    .Neg => try self.emit().negate(),
                    .BitNot => {
                        try self.emit().bitNot();
                        // `not` is a full-width instruction. Complementing a
                        // value narrower than a word sets every bit above it
                        // too, and those bits are part of the result unless
                        // they are cleared: `~(x as u16)` for x = 0xFFFF must
                        // be 0, not 0xFFFFFFFFFFFF0000.
                        //
                        // Every internet checksum in the tree is computed this
                        // way, so the surviving high bits made a correct
                        // checksum compare unequal to zero and the network
                        // stack rejected every packet whose checksum was right.
                        if (self.typeOfLValue(unary.operand)) |operand_type| {
                            try self.emitNarrowTo(operand_type);
                        }
                    },
                    .Not => {
                        try self.emit().cmpImm(.acc, 0);
                        try self.emit().setFromFlags(.eq);
                    },
                    .Deref => {
                        // Load the pointee's width, not a machine word.
                        // Reading eight bytes through a *u32 pulls in whatever
                        // follows it: parse_boot_info_mb1 read Multiboot's
                        // flags and mem_lower as a single value, and the
                        // memory size printed empty.
                        const size = self.derefLoadSize(unary.operand);
                        const signed = self.derefIsSigned(unary.operand);
                        if (loadFor(size) != null) {
                            try self.emit().loadIndirect(.acc, .acc, size, signed);
                        } else {
                            // An aggregate has no register-sized load; the
                            // address itself is the value.
                            try self.emit().loadIndirect(.acc, .acc, 8, false);
                        }
                    },
                    else => {
                        try self.print("    # unsupported unary operator: {s}\n", .{@tagName(unary.op)});
                    },
                }
            },
            .AssignmentExpr => |assign| {
                switch (assign.target.*) {
                    .Identifier => |target| {
                        // Module-level storage takes the same copy as a local
                        // does. A struct global is recorded with is_array set
                        // — storage is storage — so the refusal below reported
                        // "cannot assign to the array" for what the source
                        // wrote as a plain struct assignment, and refused it.
                        if (self.global_vars.get(target.name)) |g| {
                            if (g.is_array and self.isStorageType(g.type_name)) {
                                try self.emit().leaSymbol(.acc, g.symbol);
                                try self.emitStoreToAddress(g.type_name, assign.value);
                                return;
                            }
                        }
                        // A struct or array variable is storage, not a value:
                        // its slot holds the bytes themselves. Evaluating the
                        // right-hand side yields its *address*, so the scalar
                        // path below would store that address over the first
                        // field and leave the rest of the destination as it
                        // was — `a = b` then reads back a pointer where the
                        // first member should be, and stale bytes after it.
                        //
                        // The declaration path already copies (`var a: T = b`);
                        // only assignment to an existing variable did not.
                        if (self.local_types.get(target.name)) |target_type| {
                            if (self.isStorageType(target_type)) {
                                if (self.locals.get(target.name)) |slot| {
                                    try self.emit().leaLocal(.acc, @intCast(slot));
                                    try self.emitStoreToAddress(target_type, assign.value);
                                    return;
                                }
                            }
                        }
                        try self.generateExpr(assign.value);
                        // `_ = expr` evaluates for effect and drops the result.
                        if (std.mem.eql(u8, target.name, "_")) {
                            return;
                        }
                        if (self.locals.get(target.name)) |offset| {
                            if (self.local_types.get(target.name)) |tn| {
                                try self.narrowToDeclared(tn);
                            }
                            try self.emit().storeLocal(.acc, @intCast(offset));
                        } else if (self.global_vars.get(target.name)) |g| {
                            if (g.is_array) {
                                try self.print("    # ERROR: cannot assign to the array {s} as a whole\n", .{g.name});
                            } else if (storeFor(g.size)) |_| {
                                try self.emit().storeSymbolSized(.acc, g.symbol, g.size);
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
                            try self.emit().push(.acc);        // container address
                            try self.generateExpr(assign.value);
                            const mask: u64 = if (bf.field.bit_width >= 64)
                                std.math.maxInt(u64)
                            else
                                (@as(u64, 1) << @intCast(bf.field.bit_width)) - 1;
                            try self.emit().movImmReg(.tmp, @intCast(@as(i64, @bitCast(mask))));
                            try self.emit().binOp(.bit_and);   // value, truncated
                            if (bf.field.bit_offset > 0) {
                                try self.emit().shiftImm(.shl, @intCast(bf.field.bit_offset));
                            }
                            try self.emit().movReg(.tmp2, .acc); // shifted value
                            try self.emit().pop(.tmp3);         // container address
                            try self.emit().push(.tmp3);
                            try self.emit().movReg(.acc, .tmp3);
                            try self.emitLoadBacking(bf.container_size);
                            const shifted_mask: u64 = if (bf.field.bit_offset >= 64)
                                0
                            else
                                mask << @intCast(bf.field.bit_offset);
                            try self.emit().movImmReg(.tmp, @intCast(@as(i64, @bitCast(~shifted_mask))));
                            try self.emit().binOp(.bit_and);   // clear the range
                            try self.emit().aluRegs(.bit_or, .acc, .tmp2);    // insert
                            try self.emit().pop(.tmp3);
                            _ = storeFor(bf.container_size) orelse {
                                try self.print("    # ERROR: cannot store a bitfield container of {d} bytes\n", .{bf.container_size});
                                return;
                            };
                            try self.emit().storeIndirect(.acc, .tmp3, bf.container_size);
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
                        try self.emit().leaLocal(.acc, @intCast(offset));
                    } else {
                        try self.emit().loadLocal(.acc, @intCast(offset));
                    }
                } else if (self.globals.get(id.name)) |value| {
                    try self.emit().movImm(@intCast(value));
                } else if (self.global_vars.get(id.name)) |g| {
                    if (g.is_array) {
                        try self.emit().leaSymbol(.acc, g.symbol);
                    } else if (loadFor(g.size)) |_| {
                        if (g.size < 8) try self.emit().zero(.acc);
                        try self.emit().loadSymbolSized(.acc, g.symbol, g.size, false);
                    } else {
                        try self.print("    # ERROR: cannot load {s} of size {d}\n", .{ g.name, g.size });
                        try self.emit().movImm(0);
                    }
                } else {
                    // Emitting a comment and carrying on leaves %rax holding
                    // whatever the last expression left there, which reads as
                    // a working build that computes nonsense. Say so loudly
                    // in the output instead.
                    try self.print("    # ERROR: undefined variable {s}\n", .{id.name});
                    try self.emit().movImm(0);
                }
            },
            .SliceExpr => |sl| {
                // A slice value in a register position is its data pointer.
                // The length only travels when the slice is passed to a
                // parameter that declares one — see pushArgument.
                _ = try self.emitSliceDataPointer(sl) orelse {
                    try self.emit().movImm(0);
                };
            },
            .ArrayLiteral => |lit| {
                // An array literal is storage, so as a bare expression there
                // is nowhere to put it. The declaration and assignment paths
                // write the elements straight into the destination.
                try self.print("    # ERROR: array literal of {d} elements needs a destination\n", .{lit.elements.len});
                try self.emit().movImm(0);
            },
            .StructLiteral => |lit| {
                // A bitfield struct literal is just an integer: shift each
                // field's value into place and OR them together. This is what
                // `PageFlags { present: true, address: n, ... }` means.
                if (self.structs.get(splitAlign(lit.type_name).bare)) |info| {
                    if (info.is_bitfield) {
                        // The value is assembled in one register, so a
                        // container wider than a machine word cannot be built
                        // this way: every field at bit 64 or above would be
                        // shifted out. This used to emit `shlq $64, %rax`,
                        // which x86 masks to a shift of zero — the field
                        // landed on top of bit 0 and the wrong bits reached
                        // the descriptor, silently. A 128-bit IDT entry is
                        // exactly this shape. Refuse instead, and say why.
                        if (info.size > 8) {
                            try self.print(
                                "    # ERROR: {s} is a {d}-byte bitfield; this backend builds a bitfield literal in one register and cannot place fields at or above bit 64\n",
                                .{ info.name, info.size },
                            );
                            try self.emit().movImm(0);
                            return;
                        }
                        try self.emit().zero(.acc);
                        try self.emit().push(.acc);     // accumulator
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
                            try self.emit().movImmReg(.tmp, @intCast(@as(i64, @bitCast(mask))));
                            try self.emit().binOp(.bit_and);
                            if (field.bit_offset > 0) {
                                try self.emit().shiftImm(.shl, @intCast(field.bit_offset));
                            }
                            try self.emit().pop(.tmp);
                            try self.emit().binOp(.bit_or);
                            try self.emit().push(.acc);
                        }
                        try self.emit().pop(.acc);
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
                    try self.emit().pushStackPtr();
                    try self.emitStructLiteralToMemory(lit.type_name, lit);
                    try self.emit().movFromStackPtr(.acc);
                    return;
                }
                try self.print("    # ERROR: struct literal of unknown type {s}\n", .{lit.type_name});
                try self.emit().movImm(0);
            },
            .CharLiteral => |lit| {
                // The lexeme still carries its quotes and any escape.
                if (charLiteralValue(lit.value)) |v| {
                    try self.emit().movImm(@intCast(v));
                } else {
                    try self.print("    # ERROR: unsupported character literal {s}\n", .{lit.value});
                    try self.emit().movImm(0);
                }
            },
            .NullLiteral => {
                try self.emit().movImm(0);
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
                        try self.emit().movImm(0);
                    },
                    .SizeOf => {
                        if (r.target_type orelse self.typeArgOf(r.target)) |t| {
                            if (self.sizeOf(t)) |n| {
                                try self.emit().movImm(@intCast(n));
                                return;
                            }
                        }
                        try self.writeAll("    # ERROR: @sizeOf of an unknown type\n");
                        try self.emit().movImm(0);
                    },
                    .TargetIs => {
                        try self.emit().movImm(self.foldConst(expr) orelse {
                            try self.writeAll("    # ERROR: @targetIs takes a string naming an architecture\n");
                            try self.emit().movImm(0);
                            return;
                        });
                    },
                    .AlignOf => {
                        if (r.target_type orelse self.typeArgOf(r.target)) |t| {
                            try self.emit().movImm(@intCast(self.alignOf(t)));
                            return;
                        }
                        try self.writeAll("    # ERROR: @alignOf of an unknown type\n");
                        try self.emit().movImm(0);
                    },
                    .OffsetOf => {
                        if (r.target_type orelse self.typeArgOf(r.target)) |t| {
                            if (r.field_name) |fname| {
                                if (self.findField(t, fname)) |f| {
                                    try self.emit().movImm(@intCast(f.offset));
                                    return;
                                }
                            }
                        }
                        try self.writeAll("    # ERROR: @offsetOf of an unknown field\n");
                        try self.emit().movImm(0);
                    },
                    .Min, .Max => {
                        const second = r.second_arg orelse {
                            try self.print("    # ERROR: {s} needs two arguments\n", .{@tagName(r.kind)});
                            return;
                        };
                        try self.generateExpr(r.target);
                        try self.emit().push(.acc);
                        try self.generateExpr(second);
                        try self.emit().movReg(.tmp, .acc);
                        try self.emit().pop(.acc);
                        try self.emit().cmpRegs(.acc, .tmp);
                        if (r.kind == .Min) {
                            try self.emit().condMove(.gt, .acc, .tmp);
                        } else {
                            try self.emit().condMove(.lt, .acc, .tmp);
                        }
                    },
                    .Abs => {
                        try self.generateExpr(r.target);
                        try self.emit().movReg(.tmp, .acc);
                        try self.emit().negateReg(.tmp);
                        try self.emit().cmpRegs(.acc, .tmp);
                        try self.emit().condMove(.lt, .acc, .tmp);
                    },
                    .MemCpy => {
                        // @memcpy(dest, src, len), and the two-argument form
                        // that takes its length from dest's type — the same
                        // sizing rule as @memset just below, so a fixed-size
                        // field copies without the caller restating its size.
                        const dest = r.target;
                        const src = r.second_arg orelse {
                            try self.writeAll("    # ERROR: @memcpy needs a source\n");
                            return;
                        };

                        // Size before any register is loaded, so a
                        // destination we cannot measure fails cleanly rather
                        // than emitting half a copy.
                        const length_expr: ?*ast.Expr = r.third_arg;
                        var static_length: usize = 0;
                        if (length_expr == null) {
                            const dest_type = self.typeOfLValue(dest) orelse {
                                try self.writeAll("    # ERROR: @memcpy cannot size this destination\n");
                                return;
                            };
                            const bare = splitAlign(dest_type).bare;
                            const sized = pointeeType(bare) orelse bare;
                            static_length = self.sizeOf(sized) orelse {
                                try self.print("    # ERROR: @memcpy cannot size {s}\n", .{sized});
                                return;
                            };
                        }

                        // Both addresses are stacked before the length is
                        // evaluated: computing the length runs arbitrary code
                        // through the accumulator, and the length register is
                        // not one the pops disturb.
                        try self.generateExpr(dest);
                        try self.emit().push(.acc);
                        try self.generateExpr(src);
                        try self.emit().push(.acc);
                        if (length_expr) |len| {
                            try self.generateExpr(len);
                        } else {
                            try self.emit().movImm(@intCast(static_length));
                        }
                        try self.emit().movReg(.mem_len, .acc);
                        try self.emit().pop(.mem_src);
                        try self.emit().pop(.mem_dst);
                        try self.emit().memCopy(self.freshLabel());
                    },
                    .MemSet => {
                        // @memset(dest, byte) takes its length from dest's
                        // type; @memset(ptr, byte, len) is told it. The first
                        // form is what a kernel writes for a fixed-size field,
                        // and refusing it sent callers to hand-rolled loops.
                        const dest = r.target;
                        const value = r.second_arg orelse {
                            try self.writeAll("    # ERROR: @memset needs a value\n");
                            return;
                        };

                        // Length first: it is the part that can fail, and
                        // failing before any register is loaded keeps the
                        // error from being half a memset.
                        const length_expr: ?*ast.Expr = r.third_arg;
                        var static_length: usize = 0;
                        if (length_expr == null) {
                            const dest_type = self.typeOfLValue(dest) orelse {
                                try self.writeAll("    # ERROR: @memset cannot size this destination\n");
                                return;
                            };
                            // `&x` has x's type through typeOfLValue; a
                            // pointer type is sized by its pointee.
                            const bare = splitAlign(dest_type).bare;
                            const sized = pointeeType(bare) orelse bare;
                            static_length = self.sizeOf(sized) orelse {
                                try self.print("    # ERROR: @memset cannot size {s}\n", .{sized});
                                return;
                            };
                        }

                        try self.generateExpr(dest);
                        try self.emit().push(.acc);
                        if (length_expr) |len| {
                            try self.generateExpr(len);
                        } else {
                            try self.emit().movImm(@intCast(static_length));
                        }
                        try self.emit().movReg(.mem_len, .acc);
                        try self.emit().pop(.mem_dst);
                        // The value goes last: it lands in the accumulator,
                        // which is what memFill writes from.
                        try self.generateExpr(value);
                        try self.emit().memFill(self.freshLabel());
                    },
                    else => {
                        // Floating-point and type-introspection builtins have
                        // no lowering in a freestanding integer backend.
                        try self.print("    # ERROR: unsupported builtin: {s}\n", .{@tagName(r.kind)});
                        try self.emit().movImm(0);
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
                try self.emit().jumpIfZero(.acc, try self.labelText("ifexpr_else", label_num));
                try self.generateExpr(if_expr.then_branch);
                try self.emit().jump(try self.labelText("ifexpr_end", label_num));
                try self.print(".L_ifexpr_else_{d}:\n", .{label_num});
                try self.generateExpr(if_expr.else_branch);
                try self.print(".L_ifexpr_end_{d}:\n", .{label_num});
            },
            .TernaryExpr => |t| {
                const label_num = self.freshLabel();
                try self.generateExpr(t.condition);
                try self.emit().jumpIfZero(.acc, try self.labelText("ternary_else", label_num));
                try self.generateExpr(t.true_val);
                try self.emit().jump(try self.labelText("ternary_end", label_num));
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
                try self.print("    # ERROR: unsupported expression: {s} at {s}\n", .{ @tagName(expr.*), self.at(expr) });
                try self.emit().movImm(0);
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

        // Save previous register values if needed
        for (args, 0..) |arg, i| {
            if (self.emit().argReg(i)) |areg| {
                // Evaluate argument (result in %rax)
                try self.generateExpr(arg);

                // Move to appropriate argument register
                if (i == 0) {
                    try self.emit().movToNamed(areg, .acc);
                } else {
                    try self.emit().movToNamed(areg, .acc);
                }
            } else {
                // Push additional arguments onto stack
                try self.generateExpr(arg);
                try self.emit().push(.acc);
            }
        }

        // Call the external Zig function
        try self.emit().call(ffi_name.items);

        // Clean up stack if we pushed extra arguments
        if (args.len > self.arch.argRegCount()) {
            const stack_bytes = (args.len - self.arch.argRegCount()) * 8;
            try self.emit().addStack(@intCast(stack_bytes));
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
