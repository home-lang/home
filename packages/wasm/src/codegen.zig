const std = @import("std");
const ast = @import("ast");

/// WebAssembly code generator for Home language
///
/// Generates WebAssembly bytecode from Home AST.
/// Features:
/// - Function compilation
/// - Memory management
/// - Import/export handling
/// - Type mapping
/// - Optimization
pub const WasmCodeGen = struct {
    allocator: std.mem.Allocator,
    module: Module,
    current_function: ?*Function,
    local_counter: u32,
    label_counter: u32,

    pub const Module = struct {
        allocator: std.mem.Allocator,
        types: std.ArrayList(FuncType),
        functions: std.ArrayList(Function),
        tables: std.ArrayList(Table),
        memories: std.ArrayList(Memory),
        globals: std.ArrayList(Global),
        exports: std.ArrayList(Export),
        imports: std.ArrayList(Import),
        start: ?u32,
        data: std.ArrayList(DataSegment),

        pub fn init(allocator: std.mem.Allocator) Module {
            return .{
                .allocator = allocator,
                .types = std.ArrayList(FuncType).init(allocator),
                .functions = std.ArrayList(Function).init(allocator),
                .tables = std.ArrayList(Table).init(allocator),
                .memories = std.ArrayList(Memory).init(allocator),
                .globals = std.ArrayList(Global).init(allocator),
                .exports = std.ArrayList(Export).init(allocator),
                .imports = std.ArrayList(Import).init(allocator),
                .start = null,
                .data = std.ArrayList(DataSegment).init(allocator),
            };
        }

        pub fn deinit(self: *Module) void {
            self.types.deinit();
            for (self.functions.items) |*func| {
                func.deinit();
            }
            self.functions.deinit();
            self.tables.deinit();
            self.memories.deinit();
            self.globals.deinit();
            self.exports.deinit();
            self.imports.deinit();
            self.data.deinit();
        }
    };

    pub const ValType = enum(u8) {
        i32 = 0x7F,
        i64 = 0x7E,
        f32 = 0x7D,
        f64 = 0x7C,
        v128 = 0x7B,
        funcref = 0x70,
        externref = 0x6F,
    };

    pub const FuncType = struct {
        params: []ValType,
        results: []ValType,
    };

    pub const Function = struct {
        type_idx: u32,
        locals: std.ArrayList(Local),
        body: std.ArrayList(u8),
        allocator: std.mem.Allocator,

        pub const Local = struct {
            count: u32,
            type: ValType,
        };

        pub fn init(allocator: std.mem.Allocator, type_idx: u32) Function {
            return .{
                .type_idx = type_idx,
                .locals = std.ArrayList(Local).init(allocator),
                .body = std.ArrayList(u8).init(allocator),
                .allocator = allocator,
            };
        }

        pub fn deinit(self: *Function) void {
            self.locals.deinit();
            self.body.deinit();
        }
    };

    pub const Table = struct {
        elem_type: ValType,
        limits: Limits,
    };

    pub const Memory = struct {
        limits: Limits,
    };

    pub const Limits = struct {
        min: u32,
        max: ?u32,
    };

    pub const Global = struct {
        type: ValType,
        mutable: bool,
        init: []const u8,
    };

    pub const Export = struct {
        name: []const u8,
        kind: ExportKind,
        index: u32,
    };

    pub const ExportKind = enum(u8) {
        func = 0x00,
        table = 0x01,
        mem = 0x02,
        global = 0x03,
    };

    pub const Import = struct {
        module: []const u8,
        name: []const u8,
        kind: ImportKind,
    };

    pub const ImportKind = union(enum) {
        func: u32,
        table: Table,
        mem: Memory,
        global: Global,
    };

    pub const DataSegment = struct {
        memory_idx: u32,
        offset: []const u8,
        data: []const u8,
    };

    /// WebAssembly opcodes
    pub const Opcode = enum(u8) {
        // Control instructions
        @"unreachable" = 0x00,
        nop = 0x01,
        block = 0x02,
        loop = 0x03,
        @"if" = 0x04,
        @"else" = 0x05,
        end = 0x0B,
        br = 0x0C,
        br_if = 0x0D,
        br_table = 0x0E,
        @"return" = 0x0F,
        call = 0x10,
        call_indirect = 0x11,

        // Parametric instructions
        drop = 0x1A,
        select = 0x1B,

        // Variable instructions
        local_get = 0x20,
        local_set = 0x21,
        local_tee = 0x22,
        global_get = 0x23,
        global_set = 0x24,

        // Memory instructions
        i32_load = 0x28,
        i64_load = 0x29,
        f32_load = 0x2A,
        f64_load = 0x2B,
        i32_store = 0x36,
        i64_store = 0x37,
        f32_store = 0x38,
        f64_store = 0x39,
        memory_size = 0x3F,
        memory_grow = 0x40,

        // Numeric instructions
        i32_const = 0x41,
        i64_const = 0x42,
        f32_const = 0x43,
        f64_const = 0x44,

        // i32 operations
        i32_eqz = 0x45,
        i32_eq = 0x46,
        i32_ne = 0x47,
        i32_lt_s = 0x48,
        i32_lt_u = 0x49,
        i32_gt_s = 0x4A,
        i32_gt_u = 0x4B,
        i32_le_s = 0x4C,
        i32_le_u = 0x4D,
        i32_ge_s = 0x4E,
        i32_ge_u = 0x4F,

        i32_add = 0x6A,
        i32_sub = 0x6B,
        i32_mul = 0x6C,
        i32_div_s = 0x6D,
        i32_div_u = 0x6E,
        i32_rem_s = 0x6F,
        i32_rem_u = 0x70,
        i32_and = 0x71,
        i32_or = 0x72,
        i32_xor = 0x73,
        i32_shl = 0x74,
        i32_shr_s = 0x75,
        i32_shr_u = 0x76,

        // i64 operations
        i64_add = 0x7C,
        i64_sub = 0x7D,
        i64_mul = 0x7E,

        // f32 operations
        f32_add = 0x92,
        f32_sub = 0x93,
        f32_mul = 0x94,
        f32_div = 0x95,

        // f64 operations
        f64_add = 0xA0,
        f64_sub = 0xA1,
        f64_mul = 0xA2,
        f64_div = 0xA3,
    };

    pub fn init(allocator: std.mem.Allocator) WasmCodeGen {
        return .{
            .allocator = allocator,
            .module = Module.init(allocator),
            .current_function = null,
            .local_counter = 0,
            .label_counter = 0,
        };
    }

    pub fn deinit(self: *WasmCodeGen) void {
        self.module.deinit();
    }

    /// Generate WASM module from AST program
    pub fn generate(self: *WasmCodeGen, program: *ast.Program) ![]const u8 {
        // Add default memory
        try self.module.memories.append(.{
            .limits = .{ .min = 1, .max = null },
        });

        try self.module.exports.append(.{
            .name = "memory",
            .kind = .mem,
            .index = 0,
        });

        // Process all statements
        for (program.statements) |*stmt| {
            try self.generateStmt(stmt);
        }

        // Encode module to binary
        return try self.encodeModule();
    }

    fn generateStmt(self: *WasmCodeGen, stmt: *ast.Stmt) !void {
        switch (stmt.*) {
            .FunctionDecl => |*func| {
                try self.generateFunction(func);
            },
            else => {},
        }
    }

    fn generateFunction(self: *WasmCodeGen, func: *ast.FunctionDecl) !void {
        // Create function type
        var params = std.ArrayList(ValType).init(self.allocator);
        defer params.deinit();

        for (func.params) |param| {
            const val_type = try self.homeTypeToWasm(param.type_annotation);
            try params.append(val_type);
        }

        var results = std.ArrayList(ValType).init(self.allocator);
        defer results.deinit();

        if (func.return_type) |ret_type| {
            const val_type = try self.homeTypeToWasm(ret_type);
            try results.append(val_type);
        }

        const type_idx: u32 = @intCast(self.module.types.items.len);
        try self.module.types.append(.{
            .params = try params.toOwnedSlice(),
            .results = try results.toOwnedSlice(),
        });

        // Create function
        var function = Function.init(self.allocator, type_idx);
        self.current_function = &function;
        self.local_counter = @intCast(func.params.len);

        // Generate function body
        try self.generateBlock(&func.body);

        // Add implicit return if no explicit return
        try function.body.append(@intFromEnum(Opcode.end));

        try self.module.functions.append(function);

        // Export function
        try self.module.exports.append(.{
            .name = func.name,
            .kind = .func,
            .index = @intCast(self.module.functions.items.len - 1),
        });

        self.current_function = null;
    }

    fn generateBlock(self: *WasmCodeGen, block: *ast.Block) !void {
        for (block.statements) |*stmt| {
            try self.generateStmtInFunction(stmt);
        }
    }

    fn generateStmtInFunction(self: *WasmCodeGen, stmt: *ast.Stmt) !void {
        const func = self.current_function orelse return error.NotInFunction;

        switch (stmt.*) {
            .ReturnStmt => |ret_stmt| {
                if (ret_stmt.expression) |expr| {
                    try self.generateExpr(expr);
                }
                try func.body.append(@intFromEnum(Opcode.@"return"));
            },
            .LetDecl => |let_decl| {
                // Allocate local
                const local_idx = self.local_counter;
                self.local_counter += 1;

                const val_type = ValType.i32; // Default type
                try func.locals.append(.{
                    .count = 1,
                    .type = val_type,
                });

                // Generate initializer
                if (let_decl.initializer) |init| {
                    try self.generateExpr(init);
                    try func.body.append(@intFromEnum(Opcode.local_set));
                    try self.writeLEB128(local_idx, &func.body);
                }
            },
            .ExprStmt => |expr| {
                try self.generateExpr(expr);
                try func.body.append(@intFromEnum(Opcode.drop));
            },
            else => {},
        }
    }

    fn generateExpr(self: *WasmCodeGen, expr: *ast.Expr) !void {
        const func = self.current_function orelse return error.NotInFunction;

        switch (expr.*) {
            .IntegerLiteral => |int_lit| {
                try func.body.append(@intFromEnum(Opcode.i32_const));
                try self.writeLEB128(@as(u32, @intCast(int_lit.value)), &func.body);
            },
            .BinaryExpr => |bin| {
                // Generate left operand
                try self.generateExpr(bin.left);
                // Generate right operand
                try self.generateExpr(bin.right);
                // Generate operator
                try self.generateBinaryOp(bin.operator);
            },
            .CallExpr => |call| {
                // Generate arguments
                for (call.arguments) |arg| {
                    try self.generateExpr(arg);
                }
                // Generate call
                if (call.callee.* == .Identifier) {
                    const name = call.callee.Identifier.name;
                    const func_idx = try self.findFunctionIndex(name);
                    try func.body.append(@intFromEnum(Opcode.call));
                    try self.writeLEB128(func_idx, &func.body);
                }
            },
            .Identifier => |id| {
                // Load local variable
                const local_idx = try self.findLocalIndex(id.name);
                try func.body.append(@intFromEnum(Opcode.local_get));
                try self.writeLEB128(local_idx, &func.body);
            },
            else => {},
        }
    }

    fn generateBinaryOp(self: *WasmCodeGen, op: ast.BinaryOperator) !void {
        const func = self.current_function orelse return error.NotInFunction;

        const opcode: Opcode = switch (op) {
            .Add => .i32_add,
            .Sub => .i32_sub,
            .Mul => .i32_mul,
            .Div => .i32_div_s,
            .Eq => .i32_eq,
            .Ne => .i32_ne,
            .Lt => .i32_lt_s,
            .Gt => .i32_gt_s,
            .Le => .i32_le_s,
            .Ge => .i32_ge_s,
            else => return error.UnsupportedOperator,
        };

        try func.body.append(@intFromEnum(opcode));
    }

    fn homeTypeToWasm(self: *WasmCodeGen, home_type: []const u8) !ValType {
        _ = self;
        return if (std.mem.eql(u8, home_type, "i32"))
            .i32
        else if (std.mem.eql(u8, home_type, "i64"))
            .i64
        else if (std.mem.eql(u8, home_type, "f32"))
            .f32
        else if (std.mem.eql(u8, home_type, "f64"))
            .f64
        else
            .i32; // Default
    }

    fn findFunctionIndex(self: *WasmCodeGen, name: []const u8) !u32 {
        for (self.module.exports.items, 0..) |exp, i| {
            if (exp.kind == .func and std.mem.eql(u8, exp.name, name)) {
                return @intCast(i);
            }
        }
        return error.FunctionNotFound;
    }

    fn findLocalIndex(self: *WasmCodeGen, name: []const u8) !u32 {
        _ = self;
        _ = name;
        // Simplified: would need symbol table
        return 0;
    }

    fn writeLEB128(self: *WasmCodeGen, value: u32, buffer: *std.ArrayList(u8)) !void {
        _ = self;
        var val = value;
        while (true) {
            var byte: u8 = @intCast(val & 0x7F);
            val >>= 7;
            if (val != 0) {
                byte |= 0x80;
            }
            try buffer.append(byte);
            if (val == 0) break;
        }
    }

    /// Encode module to binary format
    fn encodeModule(self: *WasmCodeGen) ![]const u8 {
        var buffer = std.ArrayList(u8).init(self.allocator);

        // Magic number
        try buffer.appendSlice(&[_]u8{ 0x00, 0x61, 0x73, 0x6D });
        // Version
        try buffer.appendSlice(&[_]u8{ 0x01, 0x00, 0x00, 0x00 });

        // Type section
        if (self.module.types.items.len > 0) {
            try self.encodeTypeSection(&buffer);
        }

        // Function section
        if (self.module.functions.items.len > 0) {
            try self.encodeFunctionSection(&buffer);
        }

        // Memory section
        if (self.module.memories.items.len > 0) {
            try self.encodeMemorySection(&buffer);
        }

        // Export section
        if (self.module.exports.items.len > 0) {
            try self.encodeExportSection(&buffer);
        }

        // Code section
        if (self.module.functions.items.len > 0) {
            try self.encodeCodeSection(&buffer);
        }

        return try buffer.toOwnedSlice();
    }

    fn encodeTypeSection(self: *WasmCodeGen, buffer: *std.ArrayList(u8)) !void {
        var section = std.ArrayList(u8).init(self.allocator);
        defer section.deinit();

        try self.writeLEB128(@intCast(self.module.types.items.len), &section);
        for (self.module.types.items) |func_type| {
            try section.append(0x60); // func type
            try self.writeLEB128(@intCast(func_type.params.len), &section);
            for (func_type.params) |param| {
                try section.append(@intFromEnum(param));
            }
            try self.writeLEB128(@intCast(func_type.results.len), &section);
            for (func_type.results) |result| {
                try section.append(@intFromEnum(result));
            }
        }

        try buffer.append(1); // Type section ID
        try self.writeLEB128(@intCast(section.items.len), buffer);
        try buffer.appendSlice(section.items);
    }

    fn encodeFunctionSection(self: *WasmCodeGen, buffer: *std.ArrayList(u8)) !void {
        var section = std.ArrayList(u8).init(self.allocator);
        defer section.deinit();

        try self.writeLEB128(@intCast(self.module.functions.items.len), &section);
        for (self.module.functions.items) |func| {
            try self.writeLEB128(func.type_idx, &section);
        }

        try buffer.append(3); // Function section ID
        try self.writeLEB128(@intCast(section.items.len), buffer);
        try buffer.appendSlice(section.items);
    }

    fn encodeMemorySection(self: *WasmCodeGen, buffer: *std.ArrayList(u8)) !void {
        var section = std.ArrayList(u8).init(self.allocator);
        defer section.deinit();

        try self.writeLEB128(@intCast(self.module.memories.items.len), &section);
        for (self.module.memories.items) |mem| {
            if (mem.limits.max) |max| {
                try section.append(0x01); // Has max
                try self.writeLEB128(mem.limits.min, &section);
                try self.writeLEB128(max, &section);
            } else {
                try section.append(0x00); // No max
                try self.writeLEB128(mem.limits.min, &section);
            }
        }

        try buffer.append(5); // Memory section ID
        try self.writeLEB128(@intCast(section.items.len), buffer);
        try buffer.appendSlice(section.items);
    }

    fn encodeExportSection(self: *WasmCodeGen, buffer: *std.ArrayList(u8)) !void {
        var section = std.ArrayList(u8).init(self.allocator);
        defer section.deinit();

        try self.writeLEB128(@intCast(self.module.exports.items.len), &section);
        for (self.module.exports.items) |exp| {
            try self.writeLEB128(@intCast(exp.name.len), &section);
            try section.appendSlice(exp.name);
            try section.append(@intFromEnum(exp.kind));
            try self.writeLEB128(exp.index, &section);
        }

        try buffer.append(7); // Export section ID
        try self.writeLEB128(@intCast(section.items.len), buffer);
        try buffer.appendSlice(section.items);
    }

    fn encodeCodeSection(self: *WasmCodeGen, buffer: *std.ArrayList(u8)) !void {
        var section = std.ArrayList(u8).init(self.allocator);
        defer section.deinit();

        try self.writeLEB128(@intCast(self.module.functions.items.len), &section);
        for (self.module.functions.items) |func| {
            var func_body = std.ArrayList(u8).init(self.allocator);
            defer func_body.deinit();

            // Locals
            try self.writeLEB128(@intCast(func.locals.items.len), &func_body);
            for (func.locals.items) |local| {
                try self.writeLEB128(local.count, &func_body);
                try func_body.append(@intFromEnum(local.type));
            }

            // Code
            try func_body.appendSlice(func.body.items);

            // Write function size and body
            try self.writeLEB128(@intCast(func_body.items.len), &section);
            try section.appendSlice(func_body.items);
        }

        try buffer.append(10); // Code section ID
        try self.writeLEB128(@intCast(section.items.len), buffer);
        try buffer.appendSlice(section.items);
    }
};
