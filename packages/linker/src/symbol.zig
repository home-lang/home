// Home Programming Language - Linker Symbol Visibility Control
// Defines symbols and their visibility for linker scripts

const std = @import("std");
const linker = @import("linker.zig");

pub const Symbol = struct {
    name: []const u8,
    symbol_type: linker.SymbolType,
    visibility: linker.SymbolVisibility,
    value: ?u64, // Optional value (address or constant)
    section: ?[]const u8, // Optional section name

    pub fn init(
        name: []const u8,
        symbol_type: linker.SymbolType,
        visibility: linker.SymbolVisibility,
    ) Symbol {
        return .{
            .name = name,
            .symbol_type = symbol_type,
            .visibility = visibility,
            .value = null,
            .section = null,
        };
    }

    pub fn withValue(self: Symbol, value: u64) Symbol {
        var result = self;
        result.value = value;
        return result;
    }

    pub fn withSection(self: Symbol, section: []const u8) Symbol {
        var result = self;
        result.section = section;
        return result;
    }

    pub fn isGlobal(self: Symbol) bool {
        return self.visibility == .Global;
    }

    pub fn isLocal(self: Symbol) bool {
        return self.visibility == .Local;
    }

    pub fn isWeak(self: Symbol) bool {
        return self.visibility == .Weak;
    }

    pub fn isFunction(self: Symbol) bool {
        return self.symbol_type == .Func;
    }

    pub fn isObject(self: Symbol) bool {
        return self.symbol_type == .Object;
    }

    pub fn format(
        self: Symbol,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        // Visibility prefix
        const vis_prefix = switch (self.visibility) {
            .Local => "",
            .Global => "PROVIDE(",
            .Weak => "PROVIDE_WEAK(",
            .Hidden => "HIDDEN(",
            .Protected => "PROTECTED(",
            .Internal => "INTERNAL(",
        };

        const vis_suffix = switch (self.visibility) {
            .Local => "",
            else => ")",
        };

        try writer.print("{s}{s} = ", .{ vis_prefix, self.name });

        if (self.value) |value| {
            try writer.print("0x{x:0>16}", .{value});
        } else if (self.section) |section| {
            try writer.print("ADDR({s})", .{section});
        } else {
            try writer.print(".", .{});
        }

        try writer.print(";{s}", .{vis_suffix});
    }
};

// Symbol table for managing multiple symbols
pub const SymbolTable = struct {
    symbols: std.ArrayList(Symbol),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SymbolTable {
        return .{
            .symbols = std.ArrayList(Symbol){},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SymbolTable) void {
        self.symbols.deinit(self.allocator);
    }

    pub fn add(self: *SymbolTable, symbol: Symbol) !void {
        try self.symbols.append(self.allocator, symbol);
    }

    pub fn find(self: *SymbolTable, name: []const u8) ?*Symbol {
        for (self.symbols.items) |*symbol| {
            if (std.mem.eql(u8, symbol.name, name)) {
                return symbol;
            }
        }
        return null;
    }

    pub fn remove(self: *SymbolTable, name: []const u8) bool {
        for (self.symbols.items, 0..) |symbol, i| {
            if (std.mem.eql(u8, symbol.name, name)) {
                _ = self.symbols.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    pub fn count(self: *SymbolTable) usize {
        return self.symbols.items.len;
    }

    pub fn getGlobalSymbols(self: *SymbolTable) []Symbol {
        var result = std.ArrayList(Symbol){};
        for (self.symbols.items) |symbol| {
            if (symbol.isGlobal()) {
                result.append(self.allocator, symbol) catch unreachable;
            }
        }
        return result.toOwnedSlice(self.allocator) catch unreachable;
    }
};

// Common kernel symbols
pub const KernelSymbols = struct {
    // Kernel start/end
    pub fn kernel_start() Symbol {
        return Symbol.init(
            "__kernel_start",
            .Section,
            .Global,
        ).withSection(".text");
    }

    pub fn kernel_end() Symbol {
        return Symbol.init(
            "__kernel_end",
            .Section,
            .Global,
        ).withSection(".bss");
    }

    // Text section boundaries
    pub fn text_start() Symbol {
        return Symbol.init(
            "__text_start",
            .Section,
            .Global,
        ).withSection(".text");
    }

    pub fn text_end() Symbol {
        return Symbol.init(
            "__text_end",
            .Section,
            .Global,
        ).withSection(".text");
    }

    // Rodata section boundaries
    pub fn rodata_start() Symbol {
        return Symbol.init(
            "__rodata_start",
            .Section,
            .Global,
        ).withSection(".rodata");
    }

    pub fn rodata_end() Symbol {
        return Symbol.init(
            "__rodata_end",
            .Section,
            .Global,
        ).withSection(".rodata");
    }

    // Data section boundaries
    pub fn data_start() Symbol {
        return Symbol.init(
            "__data_start",
            .Section,
            .Global,
        ).withSection(".data");
    }

    pub fn data_end() Symbol {
        return Symbol.init(
            "__data_end",
            .Section,
            .Global,
        ).withSection(".data");
    }

    // BSS section boundaries
    pub fn bss_start() Symbol {
        return Symbol.init(
            "__bss_start",
            .Section,
            .Global,
        ).withSection(".bss");
    }

    pub fn bss_end() Symbol {
        return Symbol.init(
            "__bss_end",
            .Section,
            .Global,
        ).withSection(".bss");
    }

    // TLS boundaries
    pub fn tls_start() Symbol {
        return Symbol.init(
            "__tls_start",
            .Section,
            .Global,
        ).withSection(".tdata");
    }

    pub fn tls_end() Symbol {
        return Symbol.init(
            "__tls_end",
            .Section,
            .Global,
        ).withSection(".tbss");
    }

    // Stack
    pub fn stack_top() Symbol {
        return Symbol.init(
            "__stack_top",
            .Object,
            .Global,
        );
    }

    pub fn stack_bottom() Symbol {
        return Symbol.init(
            "__stack_bottom",
            .Object,
            .Global,
        );
    }

    // Heap
    pub fn heap_start() Symbol {
        return Symbol.init(
            "__heap_start",
            .Object,
            .Global,
        );
    }

    pub fn heap_end() Symbol {
        return Symbol.init(
            "__heap_end",
            .Object,
            .Global,
        );
    }

    // Get all standard kernel symbols (without TLS)
    pub fn standard_symbols(allocator: std.mem.Allocator) ![]Symbol {
        var list = std.ArrayList(Symbol){};

        try list.append(allocator, kernel_start());
        try list.append(allocator, kernel_end());
        try list.append(allocator, text_start());
        try list.append(allocator, text_end());
        try list.append(allocator, rodata_start());
        try list.append(allocator, rodata_end());
        try list.append(allocator, data_start());
        try list.append(allocator, data_end());
        try list.append(allocator, bss_start());
        try list.append(allocator, bss_end());
        try list.append(allocator, stack_top());
        try list.append(allocator, stack_bottom());
        try list.append(allocator, heap_start());
        try list.append(allocator, heap_end());

        return list.toOwnedSlice(allocator);
    }

    // Get all standard kernel symbols including TLS
    pub fn standard_symbols_with_tls(allocator: std.mem.Allocator) ![]Symbol {
        var list = std.ArrayList(Symbol){};

        try list.append(allocator, kernel_start());
        try list.append(allocator, kernel_end());
        try list.append(allocator, text_start());
        try list.append(allocator, text_end());
        try list.append(allocator, rodata_start());
        try list.append(allocator, rodata_end());
        try list.append(allocator, data_start());
        try list.append(allocator, data_end());
        try list.append(allocator, bss_start());
        try list.append(allocator, bss_end());
        try list.append(allocator, tls_start());
        try list.append(allocator, tls_end());
        try list.append(allocator, stack_top());
        try list.append(allocator, stack_bottom());
        try list.append(allocator, heap_start());
        try list.append(allocator, heap_end());

        return list.toOwnedSlice(allocator);
    }
};

// Symbol export list for controlling what gets exported
pub const ExportMode = enum { Whitelist, Blacklist };

pub const ExportList = struct {
    symbols: std.StringHashMap(void),
    mode: ExportMode,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, mode: ExportMode) ExportList {
        return .{
            .symbols = std.StringHashMap(void).init(allocator),
            .mode = mode,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ExportList) void {
        self.symbols.deinit();
    }

    pub fn add(self: *ExportList, name: []const u8) !void {
        try self.symbols.put(name, {});
    }

    pub fn shouldExport(self: *ExportList, name: []const u8) bool {
        const in_list = self.symbols.contains(name);
        return switch (self.mode) {
            .Whitelist => in_list,
            .Blacklist => !in_list,
        };
    }
};

// Tests
test "symbol basic operations" {
    const testing = std.testing;

    const symbol = Symbol.init(
        "test_func",
        .Func,
        .Global,
    );

    try testing.expect(std.mem.eql(u8, symbol.name, "test_func"));
    try testing.expectEqual(linker.SymbolType.Func, symbol.symbol_type);
    try testing.expectEqual(linker.SymbolVisibility.Global, symbol.visibility);
    try testing.expect(symbol.isGlobal());
    try testing.expect(symbol.isFunction());
}

test "symbol with value" {
    const testing = std.testing;

    const symbol = Symbol.init("test", .Object, .Global)
        .withValue(0x1000);

    try testing.expectEqual(@as(u64, 0x1000), symbol.value.?);
}

test "symbol with section" {
    const testing = std.testing;

    const symbol = Symbol.init("test", .Section, .Global)
        .withSection(".text");

    try testing.expect(std.mem.eql(u8, symbol.section.?, ".text"));
}

test "symbol table operations" {
    const testing = std.testing;

    var table = SymbolTable.init(testing.allocator);
    defer table.deinit();

    try table.add(Symbol.init("sym1", .Func, .Global));
    try table.add(Symbol.init("sym2", .Object, .Local));

    try testing.expectEqual(@as(usize, 2), table.count());

    const found = table.find("sym1");
    try testing.expect(found != null);
    try testing.expect(std.mem.eql(u8, found.?.name, "sym1"));

    const not_found = table.find("sym3");
    try testing.expect(not_found == null);
}

test "symbol table remove" {
    const testing = std.testing;

    var table = SymbolTable.init(testing.allocator);
    defer table.deinit();

    try table.add(Symbol.init("sym1", .Func, .Global));
    try table.add(Symbol.init("sym2", .Object, .Local));

    try testing.expectEqual(@as(usize, 2), table.count());

    const removed = table.remove("sym1");
    try testing.expect(removed);
    try testing.expectEqual(@as(usize, 1), table.count());

    const not_removed = table.remove("sym3");
    try testing.expect(!not_removed);
}

test "kernel symbols" {
    const testing = std.testing;

    const symbols = try KernelSymbols.standard_symbols(testing.allocator);
    defer testing.allocator.free(symbols);

    // Without TLS: 14 symbols
    try testing.expectEqual(@as(usize, 14), symbols.len);

    // Check some key symbols
    var has_kernel_start = false;
    var has_text_start = false;
    var has_bss_end = false;

    for (symbols) |symbol| {
        if (std.mem.eql(u8, symbol.name, "__kernel_start")) has_kernel_start = true;
        if (std.mem.eql(u8, symbol.name, "__text_start")) has_text_start = true;
        if (std.mem.eql(u8, symbol.name, "__bss_end")) has_bss_end = true;
    }

    try testing.expect(has_kernel_start);
    try testing.expect(has_text_start);
    try testing.expect(has_bss_end);
}

test "kernel symbols with TLS" {
    const testing = std.testing;

    const symbols = try KernelSymbols.standard_symbols_with_tls(testing.allocator);
    defer testing.allocator.free(symbols);

    // With TLS: 16 symbols
    try testing.expectEqual(@as(usize, 16), symbols.len);
}

test "export list whitelist" {
    const testing = std.testing;

    var list = ExportList.init(testing.allocator, .Whitelist);
    defer list.deinit();

    try list.add("exported_func");

    try testing.expect(list.shouldExport("exported_func"));
    try testing.expect(!list.shouldExport("internal_func"));
}

test "export list blacklist" {
    const testing = std.testing;

    var list = ExportList.init(testing.allocator, .Blacklist);
    defer list.deinit();

    try list.add("internal_func");

    try testing.expect(!list.shouldExport("internal_func"));
    try testing.expect(list.shouldExport("exported_func"));
}

test "symbol visibility types" {
    const testing = std.testing;

    const global = Symbol.init("global", .Func, .Global);
    const local = Symbol.init("local", .Func, .Local);
    const weak = Symbol.init("weak", .Func, .Weak);

    try testing.expect(global.isGlobal());
    try testing.expect(!global.isLocal());
    try testing.expect(!global.isWeak());

    try testing.expect(!local.isGlobal());
    try testing.expect(local.isLocal());
    try testing.expect(!local.isWeak());

    try testing.expect(!weak.isGlobal());
    try testing.expect(!weak.isLocal());
    try testing.expect(weak.isWeak());
}
