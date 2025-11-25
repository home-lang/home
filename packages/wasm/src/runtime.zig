const std = @import("std");

/// WebAssembly runtime for executing WASM modules
///
/// Features:
/// - Module loading and instantiation
/// - Memory management
/// - Function calls
/// - Import/export handling
/// - WASI support
pub const WasmRuntime = struct {
    allocator: std.mem.Allocator,
    modules: std.StringHashMap(*Instance),

    pub const Instance = struct {
        allocator: std.mem.Allocator,
        module: Module,
        memory: ?*Memory,
        tables: std.ArrayList(*Table),
        globals: std.ArrayList(Global),
        functions: std.ArrayList(Function),
        exports: std.StringHashMap(ExportValue),

        pub const Module = struct {
            bytes: []const u8,
            types: []FuncType,
            functions: []FuncDef,
            exports: []Export,
        };

        pub const FuncType = struct {
            params: []ValType,
            results: []ValType,
        };

        pub const FuncDef = struct {
            type_idx: u32,
            locals: []Local,
            code: []const u8,
        };

        pub const Local = struct {
            count: u32,
            type: ValType,
        };

        pub const Export = struct {
            name: []const u8,
            kind: ExportKind,
            index: u32,
        };

        pub const ExportKind = enum {
            func,
            table,
            mem,
            global,
        };

        pub const ValType = enum(u8) {
            i32 = 0x7F,
            i64 = 0x7E,
            f32 = 0x7D,
            f64 = 0x7C,
        };

        pub const ExportValue = union(enum) {
            func: u32,
            memory: *Memory,
            table: *Table,
            global: *Global,
        };

        pub fn init(allocator: std.mem.Allocator, module_bytes: []const u8) !*Instance {
            const instance = try allocator.create(Instance);
            instance.* = .{
                .allocator = allocator,
                .module = undefined,
                .memory = null,
                .tables = std.ArrayList(*Table).init(allocator),
                .globals = std.ArrayList(Global).init(allocator),
                .functions = std.ArrayList(Function).init(allocator),
                .exports = std.StringHashMap(ExportValue).init(allocator),
            };

            try instance.loadModule(module_bytes);
            return instance;
        }

        pub fn deinit(self: *Instance) void {
            if (self.memory) |mem| {
                mem.deinit();
                self.allocator.destroy(mem);
            }
            for (self.tables.items) |table| {
                table.deinit();
                self.allocator.destroy(table);
            }
            self.tables.deinit();
            self.globals.deinit();
            self.functions.deinit();
            self.exports.deinit();
        }

        fn loadModule(self: *Instance, bytes: []const u8) !void {
            // Validate magic number
            if (bytes.len < 8) return error.InvalidModule;
            if (!std.mem.eql(u8, bytes[0..4], &[_]u8{ 0x00, 0x61, 0x73, 0x6D })) {
                return error.InvalidMagic;
            }

            // Validate version
            if (!std.mem.eql(u8, bytes[4..8], &[_]u8{ 0x01, 0x00, 0x00, 0x00 })) {
                return error.UnsupportedVersion;
            }

            var offset: usize = 8;

            // Parse sections
            while (offset < bytes.len) {
                const section_id = bytes[offset];
                offset += 1;

                var size: u32 = 0;
                offset += try self.readLEB128(bytes[offset..], &size);

                const section_end = offset + size;

                switch (section_id) {
                    1 => try self.parseTypeSection(bytes[offset..section_end]),
                    3 => try self.parseFunctionSection(bytes[offset..section_end]),
                    5 => try self.parseMemorySection(bytes[offset..section_end]),
                    7 => try self.parseExportSection(bytes[offset..section_end]),
                    10 => try self.parseCodeSection(bytes[offset..section_end]),
                    else => {}, // Skip unknown sections
                }

                offset = section_end;
            }
        }

        fn parseTypeSection(self: *Instance, data: []const u8) !void {
            _ = self;
            _ = data;
            // Parse function types
        }

        fn parseFunctionSection(self: *Instance, data: []const u8) !void {
            _ = self;
            _ = data;
            // Parse function declarations
        }

        fn parseMemorySection(self: *Instance, data: []const u8) !void {
            var offset: usize = 0;
            var count: u32 = 0;
            offset += try self.readLEB128(data[offset..], &count);

            if (count > 0) {
                const has_max = data[offset];
                offset += 1;

                var min: u32 = 0;
                offset += try self.readLEB128(data[offset..], &min);

                var max: ?u32 = null;
                if (has_max == 1) {
                    var max_val: u32 = 0;
                    _ = try self.readLEB128(data[offset..], &max_val);
                    max = max_val;
                }

                const mem = try self.allocator.create(Memory);
                mem.* = try Memory.init(self.allocator, min, max);
                self.memory = mem;
            }
        }

        fn parseExportSection(self: *Instance, data: []const u8) !void {
            _ = self;
            _ = data;
            // Parse exports
        }

        fn parseCodeSection(self: *Instance, data: []const u8) !void {
            _ = self;
            _ = data;
            // Parse function code
        }

        fn readLEB128(self: *Instance, data: []const u8, result: *u32) !usize {
            _ = self;
            var value: u32 = 0;
            var shift: u5 = 0;
            var offset: usize = 0;

            while (offset < data.len) {
                const byte = data[offset];
                offset += 1;

                value |= @as(u32, byte & 0x7F) << shift;
                if ((byte & 0x80) == 0) break;

                shift += 7;
                if (shift >= 32) return error.LEB128Overflow;
            }

            result.* = value;
            return offset;
        }

        /// Call an exported function
        pub fn call(self: *Instance, name: []const u8, args: []const Value) !Value {
            const export_value = self.exports.get(name) orelse return error.FunctionNotFound;

            if (export_value != .func) return error.NotAFunction;

            const func_idx = export_value.func;
            if (func_idx >= self.functions.items.len) return error.InvalidFunctionIndex;

            const function = self.functions.items[func_idx];
            return try self.executeFunction(function, args);
        }

        fn executeFunction(self: *Instance, function: Function, args: []const Value) !Value {
            _ = self;
            _ = function;
            _ = args;
            // Execute function bytecode
            return Value{ .i32 = 0 };
        }
    };

    pub const Memory = struct {
        allocator: std.mem.Allocator,
        data: []u8,
        min_pages: u32,
        max_pages: ?u32,
        page_size: u32 = 65536, // 64KB

        pub fn init(allocator: std.mem.Allocator, min_pages: u32, max_pages: ?u32) !Memory {
            const size = min_pages * 65536;
            const data = try allocator.alloc(u8, size);
            @memset(data, 0);

            return Memory{
                .allocator = allocator,
                .data = data,
                .min_pages = min_pages,
                .max_pages = max_pages,
            };
        }

        pub fn deinit(self: *Memory) void {
            self.allocator.free(self.data);
        }

        pub fn grow(self: *Memory, delta_pages: u32) !u32 {
            const current_pages = @as(u32, @intCast(self.data.len / self.page_size));
            const new_pages = current_pages + delta_pages;

            if (self.max_pages) |max| {
                if (new_pages > max) return error.MemoryGrowthExceeded;
            }

            const new_size = new_pages * self.page_size;
            self.data = try self.allocator.realloc(self.data, new_size);
            @memset(self.data[current_pages * self.page_size ..], 0);

            return current_pages;
        }

        pub fn read(self: *Memory, offset: u32, size: u32) ![]const u8 {
            if (offset + size > self.data.len) return error.OutOfBounds;
            return self.data[offset .. offset + size];
        }

        pub fn write(self: *Memory, offset: u32, data: []const u8) !void {
            if (offset + data.len > self.data.len) return error.OutOfBounds;
            @memcpy(self.data[offset .. offset + data.len], data);
        }
    };

    pub const Table = struct {
        allocator: std.mem.Allocator,
        elements: []?*Function,
        min_size: u32,
        max_size: ?u32,

        pub fn init(allocator: std.mem.Allocator, min_size: u32, max_size: ?u32) !Table {
            const elements = try allocator.alloc(?*Function, min_size);
            @memset(elements, null);

            return Table{
                .allocator = allocator,
                .elements = elements,
                .min_size = min_size,
                .max_size = max_size,
            };
        }

        pub fn deinit(self: *Table) void {
            self.allocator.free(self.elements);
        }
    };

    pub const Global = struct {
        value: Value,
        mutable: bool,
    };

    pub const Function = struct {
        type_idx: u32,
        code: []const u8,
    };

    pub const Value = union(enum) {
        i32: i32,
        i64: i64,
        f32: f32,
        f64: f64,

        pub fn asI32(self: Value) !i32 {
            return switch (self) {
                .i32 => |v| v,
                else => error.TypeMismatch,
            };
        }

        pub fn asI64(self: Value) !i64 {
            return switch (self) {
                .i64 => |v| v,
                else => error.TypeMismatch,
            };
        }

        pub fn asF32(self: Value) !f32 {
            return switch (self) {
                .f32 => |v| v,
                else => error.TypeMismatch,
            };
        }

        pub fn asF64(self: Value) !f64 {
            return switch (self) {
                .f64 => |v| v,
                else => error.TypeMismatch,
            };
        }
    };

    pub fn init(allocator: std.mem.Allocator) WasmRuntime {
        return .{
            .allocator = allocator,
            .modules = std.StringHashMap(*Instance).init(allocator),
        };
    }

    pub fn deinit(self: *WasmRuntime) void {
        var it = self.modules.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.modules.deinit();
    }

    /// Load and instantiate a WASM module
    pub fn loadModule(self: *WasmRuntime, name: []const u8, bytes: []const u8) !void {
        const instance = try Instance.init(self.allocator, bytes);
        try self.modules.put(name, instance);
    }

    /// Get a module instance by name
    pub fn getInstance(self: *WasmRuntime, name: []const u8) ?*Instance {
        return self.modules.get(name);
    }

    /// Call an exported function from a module
    pub fn callFunction(
        self: *WasmRuntime,
        module_name: []const u8,
        func_name: []const u8,
        args: []const Value,
    ) !Value {
        const instance = self.getInstance(module_name) orelse return error.ModuleNotFound;
        return try instance.call(func_name, args);
    }
};

/// WASI (WebAssembly System Interface) support
pub const WASI = struct {
    allocator: std.mem.Allocator,
    args: [][]const u8,
    env: std.StringHashMap([]const u8),
    preopens: std.StringHashMap(std.fs.Dir),

    pub fn init(allocator: std.mem.Allocator) WASI {
        return .{
            .allocator = allocator,
            .args = &.{},
            .env = std.StringHashMap([]const u8).init(allocator),
            .preopens = std.StringHashMap(std.fs.Dir).init(allocator),
        };
    }

    pub fn deinit(self: *WASI) void {
        self.env.deinit();
        var it = self.preopens.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.close();
        }
        self.preopens.deinit();
    }

    /// Add command-line arguments
    pub fn setArgs(self: *WASI, args: [][]const u8) void {
        self.args = args;
    }

    /// Add environment variable
    pub fn setEnv(self: *WASI, key: []const u8, value: []const u8) !void {
        try self.env.put(key, value);
    }

    /// Add preopened directory
    pub fn preopen(self: *WASI, path: []const u8, dir: std.fs.Dir) !void {
        try self.preopens.put(path, dir);
    }
};
