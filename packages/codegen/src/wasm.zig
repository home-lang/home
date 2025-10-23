const std = @import("std");

/// WebAssembly code generator
/// Generates .wasm files for web and serverless environments
pub const WasmCodegen = struct {
    allocator: std.mem.Allocator,
    module: Module,

    pub const Module = struct {
        types: std.ArrayList(FuncType),
        functions: std.ArrayList(Function),
        exports: std.ArrayList(Export),
        code: std.ArrayList(u8),

        pub fn init(allocator: std.mem.Allocator) Module {
            return .{
                .types = std.ArrayList(FuncType).init(allocator),
                .functions = std.ArrayList(Function).init(allocator),
                .exports = std.ArrayList(Export).init(allocator),
                .code = std.ArrayList(u8).init(allocator),
            };
        }

        pub fn deinit(self: *Module) void {
            self.types.deinit();
            self.functions.deinit();
            self.exports.deinit();
            self.code.deinit();
        }
    };

    pub const FuncType = struct {
        params: []ValueType,
        results: []ValueType,
    };

    pub const Function = struct {
        type_idx: u32,
        locals: []ValueType,
        body: []const u8,
    };

    pub const Export = struct {
        name: []const u8,
        kind: ExportKind,
        index: u32,
    };

    pub const ExportKind = enum(u8) {
        func = 0x00,
        table = 0x01,
        memory = 0x02,
        global = 0x03,
    };

    pub const ValueType = enum(u8) {
        i32 = 0x7F,
        i64 = 0x7E,
        f32 = 0x7D,
        f64 = 0x7C,
    };

    // WASM opcodes
    pub const Opcode = enum(u8) {
        @"unreachable" = 0x00,
        nop = 0x01,
        block = 0x02,
        loop = 0x03,
        @"if" = 0x04,
        @"else" = 0x05,
        end = 0x0B,
        br = 0x0C,
        br_if = 0x0D,
        @"return" = 0x0F,
        call = 0x10,
        drop = 0x1A,
        select = 0x1B,

        // Local variables
        local_get = 0x20,
        local_set = 0x21,
        local_tee = 0x22,

        // Memory
        i32_load = 0x28,
        i64_load = 0x29,
        i32_store = 0x36,
        i64_store = 0x37,

        // Constants
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

        // i64 operations
        i64_eqz = 0x50,
        i64_eq = 0x51,
        i64_ne = 0x52,
        i64_lt_s = 0x53,
        i64_lt_u = 0x54,
        i64_gt_s = 0x55,
        i64_gt_u = 0x56,
        i64_le_s = 0x57,
        i64_le_u = 0x58,
        i64_ge_s = 0x59,
        i64_ge_u = 0x5A,

        // Arithmetic
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

        i64_add = 0x7C,
        i64_sub = 0x7D,
        i64_mul = 0x7E,
        i64_div_s = 0x7F,
        i64_div_u = 0x80,
        i64_rem_s = 0x81,
        i64_rem_u = 0x82,
        i64_and = 0x83,
        i64_or = 0x84,
        i64_xor = 0x85,
    };

    pub fn init(allocator: std.mem.Allocator) WasmCodegen {
        return .{
            .allocator = allocator,
            .module = Module.init(allocator),
        };
    }

    pub fn deinit(self: *WasmCodegen) void {
        self.module.deinit();
    }

    /// Emit WASM binary format
    pub fn emitWasm(self: *WasmCodegen) ![]u8 {
        var output = std.ArrayList(u8).init(self.allocator);
        defer output.deinit();

        // Magic number
        try output.appendSlice(&[_]u8{ 0x00, 0x61, 0x73, 0x6D });

        // Version 1
        try output.appendSlice(&[_]u8{ 0x01, 0x00, 0x00, 0x00 });

        // Type section
        if (self.module.types.items.len > 0) {
            try self.emitTypeSection(&output);
        }

        // Function section
        if (self.module.functions.items.len > 0) {
            try self.emitFunctionSection(&output);
        }

        // Export section
        if (self.module.exports.items.len > 0) {
            try self.emitExportSection(&output);
        }

        // Code section
        if (self.module.functions.items.len > 0) {
            try self.emitCodeSection(&output);
        }

        return try output.toOwnedSlice();
    }

    fn emitTypeSection(self: *WasmCodegen, output: *std.ArrayList(u8)) !void {
        try output.append(0x01); // Type section ID

        var section_data = std.ArrayList(u8).init(self.allocator);
        defer section_data.deinit();

        try encodeUleb128(&section_data, self.module.types.items.len);

        for (self.module.types.items) |func_type| {
            try section_data.append(0x60); // func type

            // Parameters
            try encodeUleb128(&section_data, func_type.params.len);
            for (func_type.params) |param| {
                try section_data.append(@intFromEnum(param));
            }

            // Results
            try encodeUleb128(&section_data, func_type.results.len);
            for (func_type.results) |result| {
                try section_data.append(@intFromEnum(result));
            }
        }

        try encodeUleb128(output, section_data.items.len);
        try output.appendSlice(section_data.items);
    }

    fn emitFunctionSection(self: *WasmCodegen, output: *std.ArrayList(u8)) !void {
        try output.append(0x03); // Function section ID

        var section_data = std.ArrayList(u8).init(self.allocator);
        defer section_data.deinit();

        try encodeUleb128(&section_data, self.module.functions.items.len);

        for (self.module.functions.items) |func| {
            try encodeUleb128(&section_data, func.type_idx);
        }

        try encodeUleb128(output, section_data.items.len);
        try output.appendSlice(section_data.items);
    }

    fn emitExportSection(self: *WasmCodegen, output: *std.ArrayList(u8)) !void {
        try output.append(0x07); // Export section ID

        var section_data = std.ArrayList(u8).init(self.allocator);
        defer section_data.deinit();

        try encodeUleb128(&section_data, self.module.exports.items.len);

        for (self.module.exports.items) |exp| {
            // Name
            try encodeUleb128(&section_data, exp.name.len);
            try section_data.appendSlice(exp.name);

            // Kind
            try section_data.append(@intFromEnum(exp.kind));

            // Index
            try encodeUleb128(&section_data, exp.index);
        }

        try encodeUleb128(output, section_data.items.len);
        try output.appendSlice(section_data.items);
    }

    fn emitCodeSection(self: *WasmCodegen, output: *std.ArrayList(u8)) !void {
        try output.append(0x0A); // Code section ID

        var section_data = std.ArrayList(u8).init(self.allocator);
        defer section_data.deinit();

        try encodeUleb128(&section_data, self.module.functions.items.len);

        for (self.module.functions.items) |func| {
            var func_data = std.ArrayList(u8).init(self.allocator);
            defer func_data.deinit();

            // Locals
            try encodeUleb128(&func_data, func.locals.len);
            if (func.locals.len > 0) {
                try encodeUleb128(&func_data, func.locals.len);
                try func_data.append(@intFromEnum(func.locals[0]));
            }

            // Body
            try func_data.appendSlice(func.body);
            try func_data.append(@intFromEnum(Opcode.end));

            // Function size
            try encodeUleb128(&section_data, func_data.items.len);
            try section_data.appendSlice(func_data.items);
        }

        try encodeUleb128(output, section_data.items.len);
        try output.appendSlice(section_data.items);
    }

    /// Add a function to the module
    pub fn addFunction(
        self: *WasmCodegen,
        params: []const ValueType,
        results: []const ValueType,
        locals: []const ValueType,
        body: []const u8,
    ) !u32 {
        // Add type
        const type_idx = @as(u32, @intCast(self.module.types.items.len));
        try self.module.types.append(.{
            .params = try self.allocator.dupe(ValueType, params),
            .results = try self.allocator.dupe(ValueType, results),
        });

        // Add function
        const func_idx = @as(u32, @intCast(self.module.functions.items.len));
        try self.module.functions.append(.{
            .type_idx = type_idx,
            .locals = try self.allocator.dupe(ValueType, locals),
            .body = body,
        });

        return func_idx;
    }

    /// Export a function
    pub fn exportFunction(self: *WasmCodegen, name: []const u8, func_idx: u32) !void {
        try self.module.exports.append(.{
            .name = try self.allocator.dupe(u8, name),
            .kind = .func,
            .index = func_idx,
        });
    }
};

/// Encode unsigned LEB128
fn encodeUleb128(output: *std.ArrayList(u8), value_input: usize) !void {
    var value = value_input;
    while (true) {
        const byte = @as(u8, @intCast(value & 0x7F));
        value >>= 7;

        if (value != 0) {
            try output.append(byte | 0x80);
        } else {
            try output.append(byte);
            break;
        }
    }
}

/// Encode signed LEB128
fn encodeSleb128(output: *std.ArrayList(u8), value_input: i64) !void {
    var value = value_input;
    var more = true;

    while (more) {
        var byte = @as(u8, @intCast(value & 0x7F));
        value >>= 7;

        if ((value == 0 and (byte & 0x40) == 0) or (value == -1 and (byte & 0x40) != 0)) {
            more = false;
        } else {
            byte |= 0x80;
        }

        try output.append(byte);
    }
}
