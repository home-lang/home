const std = @import("std");
const ast = @import("ast");
const Lexer = @import("lexer").Lexer;
const ModuleResolver = @import("module_resolver.zig").ModuleResolver;

// Forward declaration - Parser will be passed in at runtime
const Parser = @import("parser.zig").Parser;

/// A compiled module with its AST
pub const CompiledModule = struct {
    /// Module file path
    file_path: []const u8,
    /// Module path segments (e.g., ["engine", "entity"])
    path_segments: []const []const u8,
    /// Parsed AST
    program: *ast.Program,
    /// Is this a Zig FFI module?
    is_zig: bool,
    /// Allocator used for this module
    allocator: std.mem.Allocator,

    pub fn deinit(self: *CompiledModule) void {
        // Don't free file_path or path_segments - owned by resolver cache
        // Program will be freed by caller
        _ = self;
    }
};

/// Manages multi-file compilation
pub const CompilationUnit = struct {
    allocator: std.mem.Allocator,
    /// Map of module path -> compiled module
    modules: std.StringHashMap(*CompiledModule),
    /// Module resolver
    resolver: ModuleResolver,
    /// Stack to detect circular dependencies
    parsing_stack: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator) !CompilationUnit {
        return .{
            .allocator = allocator,
            .modules = std.StringHashMap(*CompiledModule).init(allocator),
            .resolver = try ModuleResolver.init(allocator),
            .parsing_stack = std.ArrayList([]const u8){},
        };
    }

    pub fn deinit(self: *CompilationUnit) void {
        // Free all compiled modules
        var it = self.modules.valueIterator();
        while (it.next()) |module_ptr| {
            module_ptr.*.deinit();
            self.allocator.destroy(module_ptr.*);
        }
        self.modules.deinit();

        // Free parsing stack
        for (self.parsing_stack.items) |path| {
            self.allocator.free(path);
        }
        self.parsing_stack.deinit(self.allocator);

        self.resolver.deinit();
    }

    /// Compile a file and all its dependencies
    pub fn compileFile(self: *CompilationUnit, file_path: []const u8) !*CompiledModule {
        // Read the file
        const source = try std.fs.cwd().readFileAlloc(self.allocator, file_path, 10 * 1024 * 1024);
        defer self.allocator.free(source);

        // Lex
        var lexer = Lexer.init(self.allocator, source);
        const tokens = try lexer.tokenize();
        defer tokens.deinit(self.allocator);

        // Parse
        var parser = try Parser.init(self.allocator, tokens.items);
        parser.source_file = file_path;
        const program = try parser.parse();

        // Check for parse errors
        if (parser.errors.items.len > 0) {
            std.debug.print("Parse errors in {s}:\n", .{file_path});
            for (parser.errors.items) |err_info| {
                std.debug.print("  {s}\n", .{err_info.message});
            }
            return error.ParseFailed;
        }

        // Create compiled module
        const module = try self.allocator.create(CompiledModule);
        module.* = .{
            .file_path = try self.allocator.dupe(u8, file_path),
            .path_segments = &.{},  // Will be set by caller
            .program = program,
            .is_zig = false,
            .allocator = self.allocator,
        };

        // Now recursively compile all imports
        for (program.statements) |stmt| {
            if (stmt == .ImportDecl) {
                const import_decl = stmt.ImportDecl;

                // Skip Zig modules for now
                const resolved = try self.resolver.resolve(import_decl.path);
                if (resolved.is_zig) {
                    std.debug.print("[CompilationUnit] Skipping Zig module: {s}\n", .{resolved.file_path});
                    continue;
                }

                // Check if already compiled
                const module_key = try self.pathToString(import_decl.path);
                defer self.allocator.free(module_key);

                if (self.modules.get(module_key)) |existing| {
                    std.debug.print("[CompilationUnit] Module already compiled: {s}\n", .{module_key});
                    _ = existing;
                    continue;
                }

                // Check for circular dependency
                for (self.parsing_stack.items) |path| {
                    if (std.mem.eql(u8, path, module_key)) {
                        std.debug.print("Circular dependency detected: {s}\n", .{module_key});
                        return error.CircularDependency;
                    }
                }

                // Add to parsing stack
                const stack_entry = try self.allocator.dupe(u8, module_key);
                try self.parsing_stack.append(self.allocator, stack_entry);

                // Recursively compile the imported module
                std.debug.print("[CompilationUnit] Compiling dependency: {s} -> {s}\n", .{module_key, resolved.file_path});
                const dep_module = try self.compileFile(resolved.file_path);
                dep_module.path_segments = import_decl.path;

                // Register in modules map
                const map_key = try self.allocator.dupe(u8, module_key);
                try self.modules.put(map_key, dep_module);

                // Remove from parsing stack
                const popped = self.parsing_stack.pop();
                self.allocator.free(popped);
            }
        }

        parser.deinit();

        return module;
    }

    /// Helper to convert path segments to string
    fn pathToString(self: *CompilationUnit, segments: []const []const u8) ![]const u8 {
        var buf = std.ArrayList(u8){};
        for (segments, 0..) |segment, i| {
            if (i > 0) try buf.append(self.allocator, '/');
            try buf.appendSlice(self.allocator, segment);
        }
        return buf.toOwnedSlice(self.allocator);
    }
};
