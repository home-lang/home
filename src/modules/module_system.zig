const std = @import("std");
const ast = @import("../ast/ast.zig");
const lexer_mod = @import("../lexer/lexer.zig");
const parser_mod = @import("../parser/parser.zig");

/// Module represents a compiled Ion module
pub const Module = struct {
    name: []const u8,
    file_path: []const u8,
    program: *ast.Program,
    exports: std.StringHashMap(Export),
    allocator: std.mem.Allocator,

    pub const Export = struct {
        name: []const u8,
        kind: ExportKind,
    };

    pub const ExportKind = enum {
        Function,
        Type,
        Constant,
    };

    pub fn init(allocator: std.mem.Allocator, name: []const u8, file_path: []const u8, program: *ast.Program) Module {
        return .{
            .name = name,
            .file_path = file_path,
            .program = program,
            .exports = std.StringHashMap(Export).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Module) void {
        var it = self.exports.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.exports.deinit();
    }

    pub fn addExport(self: *Module, name: []const u8, kind: ExportKind) !void {
        const name_copy = try self.allocator.dupe(u8, name);
        try self.exports.put(name_copy, .{ .name = name_copy, .kind = kind });
    }
};

/// Module loader and resolver
pub const ModuleLoader = struct {
    allocator: std.mem.Allocator,
    modules: std.StringHashMap(*Module),
    search_paths: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator) ModuleLoader {
        return .{
            .allocator = allocator,
            .modules = std.StringHashMap(*Module).init(allocator),
            .search_paths = std.ArrayList([]const u8){},
        };
    }

    pub fn deinit(self: *ModuleLoader) void {
        var it = self.modules.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.*.deinit();
            self.allocator.destroy(entry.value_ptr.*);
        }
        self.modules.deinit();

        for (self.search_paths.items) |path| {
            self.allocator.free(path);
        }
        self.search_paths.deinit(self.allocator);
    }

    pub fn addSearchPath(self: *ModuleLoader, path: []const u8) !void {
        const path_copy = try self.allocator.dupe(u8, path);
        try self.search_paths.append(self.allocator, path_copy);
    }

    pub fn loadModule(self: *ModuleLoader, module_name: []const u8) !*Module {
        // Check if already loaded
        if (self.modules.get(module_name)) |module| {
            return module;
        }

        // Try to find the module file
        const file_path = try self.findModuleFile(module_name);
        defer self.allocator.free(file_path);

        // Read the file
        const file = try std.fs.cwd().openFile(file_path, .{});
        defer file.close();

        const source = try file.readToEndAlloc(self.allocator, 1024 * 1024 * 10);
        defer self.allocator.free(source);

        // Tokenize and parse
        var lex = lexer_mod.Lexer.init(self.allocator, source);
        var tokens = try lex.tokenize();
        defer tokens.deinit(self.allocator);

        var par = parser_mod.Parser.init(self.allocator, tokens.items);
        const program = try par.parse();

        // Create module
        const module = try self.allocator.create(Module);
        module.* = Module.init(self.allocator, module_name, file_path, program);

        // Collect exports (functions marked as pub)
        for (program.statements) |stmt| {
            if (stmt == .FnDecl) {
                // In future, check for pub keyword
                const fn_name = stmt.FnDecl.name;
                try module.addExport(fn_name, .Function);
            }
        }

        // Cache the module
        const name_copy = try self.allocator.dupe(u8, module_name);
        try self.modules.put(name_copy, module);

        return module;
    }

    fn findModuleFile(self: *ModuleLoader, module_name: []const u8) ![]const u8 {
        // Try current directory first
        const filename = try std.fmt.allocPrint(self.allocator, "{s}.ion", .{module_name});
        defer self.allocator.free(filename);

        // Check if file exists in current directory
        if (std.fs.cwd().openFile(filename, .{})) |file| {
            file.close();
            return try self.allocator.dupe(u8, filename);
        } else |_| {}

        // Try search paths
        for (self.search_paths.items) |search_path| {
            const path = try std.fs.path.join(self.allocator, &[_][]const u8{ search_path, filename });
            defer self.allocator.free(path);

            if (std.fs.cwd().openFile(path, .{})) |file| {
                file.close();
                return try self.allocator.dupe(u8, path);
            } else |_| {}
        }

        return error.ModuleNotFound;
    }

    pub fn resolveImport(self: *ModuleLoader, from_module: []const u8, import_name: []const u8) !*Module {
        _ = from_module;
        return try self.loadModule(import_name);
    }
};
