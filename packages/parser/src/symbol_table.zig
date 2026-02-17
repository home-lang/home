const std = @import("std");
const Io = std.Io;
const ast = @import("ast");

/// Symbol kinds that can be imported from modules
pub const SymbolKind = enum {
    Function,
    Constant,
    Type,
    Variable,
};

/// Information about a symbol available in a module
pub const Symbol = struct {
    name: []const u8,
    kind: SymbolKind,
    /// Type information (if available)
    type_info: ?[]const u8,
    /// Is this symbol exported from the module?
    is_exported: bool,
    /// Original module this symbol comes from
    module_path: []const []const u8,

    pub fn deinit(self: *Symbol, allocator: std.mem.Allocator) void {
        _ = self;
        _ = allocator;
        // Note: We don't own the strings, they're owned by the module resolver
    }
};

/// Module information in the symbol table
pub const Module = struct {
    /// Module path segments (e.g., ["basics", "os", "serial"])
    path: []const []const u8,
    /// Full module name (e.g., "basics/os/serial")
    full_name: []const u8,
    /// Is this a Zig module requiring FFI?
    is_zig: bool,
    /// Symbols exported by this module
    symbols: std.StringHashMap(Symbol),
    /// Alias for this module (e.g., "import foo as bar")
    alias: ?[]const u8,

    pub fn deinit(self: *Module, allocator: std.mem.Allocator) void {
        var it = self.symbols.valueIterator();
        while (it.next()) |sym| {
            sym.deinit(allocator);
        }
        self.symbols.deinit();
        allocator.free(self.full_name);
    }
};

/// Selective import information
pub const SelectiveImportInfo = struct {
    module_path: []const u8,
    original_name: []const u8,
};

/// Symbol table for tracking imported modules and their symbols
pub const SymbolTable = struct {
    allocator: std.mem.Allocator,
    /// Modules indexed by their full path (e.g., "basics/os/serial")
    modules: std.StringHashMap(Module),
    /// Global scope symbols (from all imported modules)
    global_symbols: std.StringHashMap(Symbol),
    /// Selective imports: maps symbol name to (module_path, original_name)
    selective_imports: std.StringHashMap(SelectiveImportInfo),
    /// Optional I/O handle for filesystem operations
    io: ?Io = null,

    pub fn init(allocator: std.mem.Allocator) SymbolTable {
        return .{
            .allocator = allocator,
            .modules = std.StringHashMap(Module).init(allocator),
            .global_symbols = std.StringHashMap(Symbol).init(allocator),
            .selective_imports = std.StringHashMap(SelectiveImportInfo).init(allocator),
        };
    }

    pub fn deinit(self: *SymbolTable) void {
        var it = self.modules.valueIterator();
        while (it.next()) |module| {
            module.deinit(self.allocator);
        }
        self.modules.deinit();
        self.global_symbols.deinit();
        self.selective_imports.deinit();
    }

    /// Register a module in the symbol table
    pub fn registerModule(
        self: *SymbolTable,
        path: []const []const u8,
        is_zig: bool,
        alias: ?[]const u8,
    ) !void {
        // Create full module name
        var name_buf = std.ArrayList(u8){};
        defer name_buf.deinit(self.allocator);

        for (path, 0..) |segment, i| {
            if (i > 0) try name_buf.append(self.allocator, '/');
            try name_buf.appendSlice(self.allocator, segment);
        }

        const full_name = try name_buf.toOwnedSlice(self.allocator);

        // Check if already registered
        if (self.modules.get(full_name)) |_| {
            self.allocator.free(full_name);
            return; // Already registered
        }

        const module = Module{
            .path = path,
            .full_name = full_name,
            .is_zig = is_zig,
            .symbols = std.StringHashMap(Symbol).init(self.allocator),
            .alias = alias,
        };

        if (!self.modules.contains(full_name)) {
            try self.modules.put(full_name, module);
        } else {
            self.allocator.free(full_name);
        }
    }

    /// Add a symbol to a module
    pub fn addSymbol(
        self: *SymbolTable,
        module_path: []const u8,
        symbol_name: []const u8,
        kind: SymbolKind,
        type_info: ?[]const u8,
        is_exported: bool,
    ) !void {
        var module = self.modules.getPtr(module_path) orelse return error.ModuleNotFound;

        const symbol = Symbol{
            .name = symbol_name,
            .kind = kind,
            .type_info = type_info,
            .is_exported = is_exported,
            .module_path = module.path,
        };

        // Check if symbol already exists in module
        if (!module.symbols.contains(symbol_name)) {
            try module.symbols.put(symbol_name, symbol);
        }

        // If exported, add to global symbols (only if not already there)
        if (is_exported and !self.global_symbols.contains(symbol_name)) {
            try self.global_symbols.put(symbol_name, symbol);
        }
    }

    /// Register a selective import (e.g., import foo { bar, baz })
    pub fn registerSelectiveImport(
        self: *SymbolTable,
        module_path: []const u8,
        symbol_name: []const u8,
    ) !void {
        // Verify the symbol exists in the module
        const module = self.modules.get(module_path) orelse return error.ModuleNotFound;
        const symbol = module.symbols.get(symbol_name) orelse return error.SymbolNotFound;

        // Register the selective import (only if not already registered)
        if (!self.selective_imports.contains(symbol_name)) {
            try self.selective_imports.put(symbol_name, .{
                .module_path = module_path,
                .original_name = symbol_name,
            });
        }

        // Add to global symbols for easy lookup (only if not already there)
        if (!self.global_symbols.contains(symbol_name)) {
            try self.global_symbols.put(symbol_name, symbol);
        }
    }

    /// Look up a symbol by name
    pub fn lookupSymbol(self: *SymbolTable, name: []const u8) ?Symbol {
        // First check selective imports
        if (self.selective_imports.get(name)) |import_info| {
            if (self.modules.get(import_info.module_path)) |module| {
                return module.symbols.get(import_info.original_name);
            }
        }

        // Then check global symbols
        return self.global_symbols.get(name);
    }

    /// Look up a symbol with module prefix (e.g., "serial.init")
    pub fn lookupMemberSymbol(self: *SymbolTable, module_name: []const u8, symbol_name: []const u8) ?Symbol {
        // Check if module_name is an alias
        var target_module: ?Module = null;
        var module_iter = self.modules.valueIterator();
        while (module_iter.next()) |module| {
            if (module.alias) |alias| {
                if (std.mem.eql(u8, alias, module_name)) {
                    target_module = module.*;
                    break;
                }
            }
            // Check if it matches the last segment of the module path
            if (module.path.len > 0) {
                const last_segment = module.path[module.path.len - 1];
                if (std.mem.eql(u8, last_segment, module_name)) {
                    target_module = module.*;
                    break;
                }
            }
        }

        if (target_module) |module| {
            return module.symbols.get(symbol_name);
        }

        // Try looking up by full module path
        if (self.modules.get(module_name)) |module| {
            return module.symbols.get(symbol_name);
        }

        return null;
    }

    /// Get all symbols from a module
    pub fn getModuleSymbols(self: *SymbolTable, module_path: []const u8) ?std.StringHashMap(Symbol) {
        if (self.modules.get(module_path)) |module| {
            return module.symbols;
        }
        return null;
    }

    /// Check if a module is registered
    pub fn hasModule(self: *SymbolTable, module_path: []const u8) bool {
        return self.modules.contains(module_path);
    }

    /// Populate symbols for Home modules by scanning the source file
    pub fn populateHomeModuleSymbols(self: *SymbolTable, module_path: []const u8, file_path: []const u8) !void {
        // Read the file
        const io_val = self.io orelse return;
        const cwd = Io.Dir.cwd();
        const file = cwd.openFile(io_val, file_path, .{}) catch return;
        defer file.close(io_val);

        // Get file size
        const stat = file.stat() catch return;
        const file_size = stat.size;

        // Allocate buffer and read
        const source = self.allocator.alloc(u8, file_size) catch return;
        defer self.allocator.free(source);

        var total_read: usize = 0;
        while (total_read < file_size) {
            const bytes_read = file.read(source[total_read..]) catch return;
            if (bytes_read == 0) break;
            total_read += bytes_read;
        }

        // Simple scanner: look for struct, enum, fn, const at top level
        var i: usize = 0;
        while (i < source.len) {
            // Skip whitespace and comments
            while (i < source.len and (source[i] == ' ' or source[i] == '\n' or source[i] == '\r' or source[i] == '\t')) {
                i += 1;
            }

            // Skip line comments
            if (i + 1 < source.len and source[i] == '/' and source[i + 1] == '/') {
                while (i < source.len and source[i] != '\n') {
                    i += 1;
                }
                continue;
            }

            // Check for declarations
            if (i + 6 < source.len and std.mem.eql(u8, source[i .. i + 6], "struct")) {
                i += 6;
                // Skip whitespace
                while (i < source.len and (source[i] == ' ' or source[i] == '\t')) {
                    i += 1;
                }
                // Read identifier
                const name_start = i;
                while (i < source.len and (std.ascii.isAlphanumeric(source[i]) or source[i] == '_')) {
                    i += 1;
                }
                if (i > name_start) {
                    const name = source[name_start..i];
                    self.addSymbol(module_path, name, .Type, null, true) catch {};
                }
            } else if (i + 4 < source.len and std.mem.eql(u8, source[i .. i + 4], "enum")) {
                i += 4;
                while (i < source.len and (source[i] == ' ' or source[i] == '\t')) {
                    i += 1;
                }
                const name_start = i;
                while (i < source.len and (std.ascii.isAlphanumeric(source[i]) or source[i] == '_')) {
                    i += 1;
                }
                if (i > name_start) {
                    const name = source[name_start..i];
                    self.addSymbol(module_path, name, .Type, null, true) catch {};
                }
            } else if (i + 2 < source.len and std.mem.eql(u8, source[i .. i + 2], "fn")) {
                i += 2;
                while (i < source.len and (source[i] == ' ' or source[i] == '\t')) {
                    i += 1;
                }
                const name_start = i;
                while (i < source.len and (std.ascii.isAlphanumeric(source[i]) or source[i] == '_')) {
                    i += 1;
                }
                if (i > name_start) {
                    const name = source[name_start..i];
                    self.addSymbol(module_path, name, .Function, null, true) catch {};
                }
            } else if (i + 5 < source.len and std.mem.eql(u8, source[i .. i + 5], "const")) {
                i += 5;
                while (i < source.len and (source[i] == ' ' or source[i] == '\t')) {
                    i += 1;
                }
                const name_start = i;
                while (i < source.len and (std.ascii.isAlphanumeric(source[i]) or source[i] == '_')) {
                    i += 1;
                }
                if (i > name_start) {
                    const name = source[name_start..i];
                    self.addSymbol(module_path, name, .Constant, null, true) catch {};
                }
            } else {
                i += 1;
            }
        }
    }

    /// Populate symbols for Zig modules by introspecting the source
    /// For now, we'll manually define known symbols from basics/os modules
    pub fn populateZigModuleSymbols(self: *SymbolTable, module_path: []const u8) !void {
        // For basics/os/serial
        if (std.mem.eql(u8, module_path, "basics/os/serial")) {
            try self.addSymbol(module_path, "init", .Function, "fn(port: u16, baud_rate: u32) void", true);
            try self.addSymbol(module_path, "write", .Function, "fn(data: []const u8) void", true);
            try self.addSymbol(module_path, "write_hex", .Function, "fn(value: u32) void", true);
            try self.addSymbol(module_path, "COM1", .Constant, "u16", true);
            try self.addSymbol(module_path, "COM2", .Constant, "u16", true);
        }
        // For basics/os/cpu
        else if (std.mem.eql(u8, module_path, "basics/os/cpu")) {
            try self.addSymbol(module_path, "hlt", .Function, "fn() void", true);
            try self.addSymbol(module_path, "cli", .Function, "fn() void", true);
            try self.addSymbol(module_path, "sti", .Function, "fn() void", true);
            try self.addSymbol(module_path, "nop", .Function, "fn() void", true);
        }
        // For basics/os/interrupts
        else if (std.mem.eql(u8, module_path, "basics/os/interrupts")) {
            try self.addSymbol(module_path, "init_idt", .Function, "fn() void", true);
            try self.addSymbol(module_path, "enable", .Function, "fn() void", true);
            try self.addSymbol(module_path, "disable", .Function, "fn() void", true);
        }
        // For basics/os/console
        else if (std.mem.eql(u8, module_path, "basics/os/console")) {
            try self.addSymbol(module_path, "init", .Function, "fn() void", true);
            try self.addSymbol(module_path, "write", .Function, "fn(text: []const u8) void", true);
            try self.addSymbol(module_path, "clear", .Function, "fn() void", true);
        }
    }
};

// Tests
test "symbol table basics" {
    const allocator = std.testing.allocator;

    var table = SymbolTable.init(allocator);
    defer table.deinit();

    // Register a module
    const path = [_][]const u8{ "basics", "os", "serial" };
    try table.registerModule(&path, true, null);

    try std.testing.expect(table.hasModule("basics/os/serial"));
}

test "add and lookup symbols" {
    const allocator = std.testing.allocator;

    var table = SymbolTable.init(allocator);
    defer table.deinit();

    // Register module and add symbols
    const path = [_][]const u8{ "basics", "os", "serial" };
    try table.registerModule(&path, true, null);
    try table.populateZigModuleSymbols("basics/os/serial");

    // Lookup symbol
    const symbol = table.lookupMemberSymbol("serial", "init");
    try std.testing.expect(symbol != null);
    try std.testing.expectEqualStrings("init", symbol.?.name);
}

test "selective imports" {
    const allocator = std.testing.allocator;

    var table = SymbolTable.init(allocator);
    defer table.deinit();

    // Register module
    const path = [_][]const u8{ "basics", "os", "serial" };
    try table.registerModule(&path, true, null);
    try table.populateZigModuleSymbols("basics/os/serial");

    // Register selective import
    try table.registerSelectiveImport("basics/os/serial", "init");

    // Should be able to lookup directly
    const symbol = table.lookupSymbol("init");
    try std.testing.expect(symbol != null);
    try std.testing.expectEqualStrings("init", symbol.?.name);
}
