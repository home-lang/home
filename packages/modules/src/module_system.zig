const std = @import("std");
const ast = @import("ast");
const lexer_mod = @import("lexer");
const parser_mod = @import("parser");

/// Maximum size of a module file in bytes (10 MB)
/// This prevents loading extremely large files that could exhaust memory
const MAX_MODULE_SIZE = 10 * 1024 * 1024;

/// Module represents a compiled Home module
pub const Module = struct {
    name: []const u8,
    file_path: []const u8,
    /// Owned source backing token and AST name slices for the module lifetime.
    source: []const u8,
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
        Variable,
    };

    pub fn init(allocator: std.mem.Allocator, name: []const u8, file_path: []const u8, source: []const u8, program: *ast.Program) Module {
        return .{
            .name = name,
            .file_path = file_path,
            .source = source,
            .program = program,
            .exports = std.StringHashMap(Export).init(allocator),
            .allocator = allocator,
        };
    }

    fn deinitExports(self: *Module) void {
        var it = self.exports.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.exports.deinit();
    }

    pub fn deinit(self: *Module) void {
        self.deinitExports();
        self.program.deinit(self.allocator);
        self.allocator.free(self.source);
        self.allocator.free(self.file_path);
        self.allocator.free(self.name);
    }

    pub fn addExport(self: *Module, name: []const u8, kind: ExportKind) !void {
        // Replacing an existing export must free the old key — otherwise
        // `put` keeps the old key and leaks the new dupe.
        if (self.exports.fetchRemove(name)) |old| {
            self.allocator.free(old.key);
        }
        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);
        try self.exports.put(name_copy, .{ .name = name_copy, .kind = kind });
    }
};

/// Module loader and resolver
pub const ModuleLoader = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    modules: std.StringHashMap(*Module),
    search_paths: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator, io: std.Io) ModuleLoader {
        return .{
            .allocator = allocator,
            .io = io,
            .modules = std.StringHashMap(*Module).init(allocator),
            .search_paths = std.ArrayList([]const u8).empty,
        };
    }

    pub fn deinit(self: *ModuleLoader) void {
        var it = self.modules.iterator();
        while (it.next()) |entry| {
            // The canonical cache key borrows Module.file_path. Each module
            // owns that path and is destroyed exactly once by this map.
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
        errdefer self.allocator.free(path_copy);
        try self.search_paths.append(self.allocator, path_copy);
    }

    pub fn loadModule(self: *ModuleLoader, module_name: []const u8) !*Module {
        const file_path = try self.findModuleFile(module_name);
        defer self.allocator.free(file_path);
        return self.loadResolvedFile(module_name, file_path);
    }

    fn loadResolvedFile(self: *ModuleLoader, module_name: []const u8, file_path: []const u8) !*Module {
        // Resolve aliases and repeated imports to the same owned program.
        if (self.modules.get(file_path)) |module| return module;

        // Retain source: AST names may borrow slices from lexer tokens.
        // readFileAlloc rejects a length that reaches its limit, so include
        // one extra byte to admit a file of exactly MAX_MODULE_SIZE bytes.
        const source = try std.Io.Dir.cwd().readFileAlloc(self.io, file_path, self.allocator, .limited(MAX_MODULE_SIZE + 1));
        errdefer self.allocator.free(source);

        // Tokenize and parse
        var lex = lexer_mod.Lexer.init(self.allocator, source);
        var tokens = try lex.tokenize();
        defer tokens.deinit(self.allocator);

        var par = try parser_mod.Parser.init(self.allocator, tokens.items);
        defer par.deinit();
        const program = try par.parse();
        errdefer program.deinit(self.allocator);
        if (par.errors.items.len != 0) return error.ModuleParseFailed;

        // Dupe the name and path so Module owns them independently of the
        // file_path/module_name arguments (both of which are owned by the
        // caller / freed by defer above).
        const owned_name = try self.allocator.dupe(u8, module_name);
        errdefer self.allocator.free(owned_name);
        const owned_path = try self.allocator.dupe(u8, file_path);
        errdefer self.allocator.free(owned_path);

        // Create module
        const module = try self.allocator.create(Module);
        errdefer self.allocator.destroy(module);
        module.* = Module.init(self.allocator, owned_name, owned_path, source, program);
        errdefer module.deinitExports();

        // Export declaration ownership comes from the parser's visibility
        // flags, never from the presence of a top-level name alone.
        for (program.statements) |stmt| {
            switch (stmt) {
                .FnDecl => |decl| if (decl.is_public) try module.addExport(decl.name, .Function),
                .LetDecl => |decl| if (decl.is_public) try module.addExport(decl.name, if (decl.is_mutable) .Variable else .Constant),
                .StructDecl => |decl| if (decl.is_public) try module.addExport(decl.name, .Type),
                .EnumDecl => |decl| if (decl.is_public) try module.addExport(decl.name, .Type),
                .UnionDecl => |decl| if (decl.is_public) try module.addExport(decl.name, .Type),
                .TypeAliasDecl => |decl| if (decl.is_public) try module.addExport(decl.name, .Type),
                .TraitDecl => |decl| if (decl.is_public) try module.addExport(decl.name, .Type),
                else => {},
            }
        }

        // The canonical path is owned by Module and borrowed by the map.
        // No alias gets a second ownership entry (or a second deinit).
        try self.modules.put(module.file_path, module);

        return module;
    }

    fn findModuleFile(self: *ModuleLoader, module_name: []const u8) ![]const u8 {
        // Try current directory first
        const filename = try std.fmt.allocPrint(self.allocator, "{s}.home", .{module_name});
        defer self.allocator.free(filename);

        // Check if file exists in current directory
        const cwd = std.Io.Dir.cwd();
        if (try self.openCandidate(cwd, filename)) |file| {
            file.close(self.io);
            return self.canonicalFilePath(filename);
        }

        // Try search paths
        for (self.search_paths.items) |search_path| {
            const path = try std.fs.path.join(self.allocator, &[_][]const u8{ search_path, filename });
            defer self.allocator.free(path);

            if (try self.openCandidate(cwd, path)) |file| {
                file.close(self.io);
                return self.canonicalFilePath(path);
            }
        }

        return error.ModuleNotFound;
    }

    fn openCandidate(self: *ModuleLoader, dir: std.Io.Dir, path: []const u8) !?std.Io.File {
        return dir.openFile(self.io, path, .{}) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => null,
            else => |other| return other,
        };
    }

    fn canonicalFilePath(self: *ModuleLoader, path: []const u8) ![]u8 {
        var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const len = try std.Io.Dir.cwd().realPathFile(self.io, path, &buffer);
        return self.allocator.dupe(u8, buffer[0..len]);
    }

    pub fn resolveImport(self: *ModuleLoader, from_module: []const u8, import_name: []const u8) !*Module {
        // Bare names keep the cwd/search-path lookup order. Relative names
        // require the canonical path of an already loaded importing module.
        if (!isRelativeImport(import_name)) return self.loadModule(import_name);
        const importer = self.modules.get(from_module) orelse return error.ImportingModuleNotLoaded;
        const parent = std.fs.path.dirname(importer.file_path) orelse unreachable;
        const filename = if (std.fs.path.extension(import_name).len == 0)
            try std.fmt.allocPrint(self.allocator, "{s}.home", .{import_name})
        else
            try self.allocator.dupe(u8, import_name);
        defer self.allocator.free(filename);
        const candidate = try std.fs.path.join(self.allocator, &.{ parent, filename });
        defer self.allocator.free(candidate);
        const cwd = std.Io.Dir.cwd();
        if (try self.openCandidate(cwd, candidate)) |file| {
            file.close(self.io);
            const canonical = try self.canonicalFilePath(candidate);
            defer self.allocator.free(canonical);
            return self.loadResolvedFile(import_name, canonical);
        }
        return error.ModuleNotFound;
    }

    fn isRelativeImport(import_name: []const u8) bool {
        return (import_name.len >= 2 and import_name[0] == '.' and std.fs.path.isSep(import_name[1])) or
            (import_name.len >= 3 and import_name[0] == '.' and import_name[1] == '.' and std.fs.path.isSep(import_name[2]));
    }
};
