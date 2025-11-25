const std = @import("std");
const ast = @import("ast");
const macro_system = @import("macro_system.zig");
const Macro = macro_system.Macro;
const MacroRule = macro_system.MacroRule;
const MacroPattern = macro_system.MacroPattern;
const MacroFragment = macro_system.MacroFragment;

/// Macro expansion engine with hygiene
pub const MacroExpander = struct {
    allocator: std.mem.Allocator,
    /// Registered macros
    macros: std.StringHashMap(*Macro),
    /// Hygiene context for preventing name capture
    hygiene_ctx: HygieneContext,
    /// Expansion counter for generating unique names
    expansion_counter: usize,
    /// Recursion depth tracking
    recursion_depth: usize,
    /// Maximum recursion depth
    max_recursion: usize,
    errors: std.ArrayList(ExpansionError),

    pub const ExpansionError = struct {
        message: []const u8,
        loc: ast.SourceLocation,
    };

    pub fn init(allocator: std.mem.Allocator) MacroExpander {
        return .{
            .allocator = allocator,
            .macros = std.StringHashMap(*Macro).init(allocator),
            .hygiene_ctx = HygieneContext.init(allocator),
            .expansion_counter = 0,
            .recursion_depth = 0,
            .max_recursion = 128,
            .errors = std.ArrayList(ExpansionError){},
        };
    }

    pub fn deinit(self: *MacroExpander) void {
        self.macros.deinit();
        self.hygiene_ctx.deinit();
        for (self.errors.items) |err| {
            self.allocator.free(err.message);
        }
        self.errors.deinit(self.allocator);
    }

    /// Register a macro definition
    pub fn registerMacro(self: *MacroExpander, macro: *Macro) !void {
        try self.macros.put(macro.name, macro);
    }

    /// Expand a macro invocation
    pub fn expand(
        self: *MacroExpander,
        macro_name: []const u8,
        args: []const ast.Expr,
        loc: ast.SourceLocation,
    ) !?[]ast.Stmt {
        // Check recursion depth
        if (self.recursion_depth >= self.max_recursion) {
            try self.addError("Macro recursion limit exceeded", loc);
            return null;
        }

        // Find the macro
        const macro = self.macros.get(macro_name) orelse {
            const msg = try std.fmt.allocPrint(
                self.allocator,
                "Undefined macro '{s}'",
                .{macro_name},
            );
            try self.errors.append(self.allocator, .{ .message = msg, .loc = loc });
            return null;
        };

        self.recursion_depth += 1;
        defer self.recursion_depth -= 1;

        // Try each rule until one matches
        for (macro.rules) |rule| {
            if (try self.matchPattern(rule.pattern, args)) |bindings| {
                defer bindings.deinit();

                // Expand the template with bindings
                const result = try self.expandTemplate(rule.template, bindings, loc);
                return result;
            }
        }

        try self.addError("No matching macro rule found", loc);
        return null;
    }

    /// Match macro arguments against a pattern
    fn matchPattern(
        self: *MacroExpander,
        pattern: MacroPattern,
        args: []const ast.Expr,
    ) !?MacroBindings {
        const bindings = MacroBindings.init(self.allocator);

        // Simple matching for now
        // TODO: Implement full pattern matching with repetitions
        _ = pattern;
        _ = args;

        return bindings;
    }

    /// Expand a template with variable bindings
    fn expandTemplate(
        self: *MacroExpander,
        template: macro_system.MacroTemplate,
        bindings: MacroBindings,
        loc: ast.SourceLocation,
    ) ![]ast.Stmt {
        _ = self;
        _ = template;
        _ = bindings;
        _ = loc;

        // TODO: Implement template expansion
        return &[_]ast.Stmt{};
    }

    /// Apply hygiene to prevent variable capture
    fn applyHygiene(self: *MacroExpander, stmt: *ast.Stmt) !void {
        _ = self;
        _ = stmt;
        // TODO: Rename variables to prevent capture
    }

    /// Generate a unique hygienic name
    fn generateHygienicName(self: *MacroExpander, base_name: []const u8) ![]const u8 {
        const name = try std.fmt.allocPrint(
            self.allocator,
            "{s}_{d}",
            .{ base_name, self.expansion_counter },
        );
        self.expansion_counter += 1;
        return name;
    }

    fn addError(self: *MacroExpander, message: []const u8, loc: ast.SourceLocation) !void {
        const msg = try self.allocator.dupe(u8, message);
        try self.errors.append(self.allocator, .{ .message = msg, .loc = loc });
    }

    pub fn hasErrors(self: *MacroExpander) bool {
        return self.errors.items.len > 0;
    }
};

/// Variable bindings during macro expansion
const MacroBindings = struct {
    bindings: std.StringHashMap([]const ast.Expr),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MacroBindings {
        return .{
            .bindings = std.StringHashMap([]const ast.Expr).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MacroBindings) void {
        self.bindings.deinit();
    }

    pub fn bind(self: *MacroBindings, name: []const u8, exprs: []const ast.Expr) !void {
        try self.bindings.put(name, exprs);
    }

    pub fn get(self: *MacroBindings, name: []const u8) ?[]const ast.Expr {
        return self.bindings.get(name);
    }
};

/// Hygiene context for preventing variable capture
const HygieneContext = struct {
    /// Map from original names to hygienic names
    renames: std.StringHashMap([]const u8),
    allocator: std.mem.Allocator,
    /// Scope depth
    scope_depth: usize,

    pub fn init(allocator: std.mem.Allocator) HygieneContext {
        return .{
            .renames = std.StringHashMap([]const u8).init(allocator),
            .allocator = allocator,
            .scope_depth = 0,
        };
    }

    pub fn deinit(self: *HygieneContext) void {
        var it = self.renames.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.renames.deinit();
    }

    pub fn enterScope(self: *HygieneContext) void {
        self.scope_depth += 1;
    }

    pub fn exitScope(self: *HygieneContext) void {
        if (self.scope_depth > 0) {
            self.scope_depth -= 1;
        }
    }

    pub fn addRename(self: *HygieneContext, original: []const u8, hygienic: []const u8) !void {
        try self.renames.put(original, hygienic);
    }

    pub fn getRename(self: *HygieneContext, name: []const u8) ?[]const u8 {
        return self.renames.get(name);
    }
};

/// Derive macro processor
pub const DeriveMacro = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) DeriveMacro {
        return .{ .allocator = allocator };
    }

    /// Generate Debug trait implementation
    pub fn deriveDebug(self: *DeriveMacro, struct_decl: *ast.StructDecl) ![]ast.Stmt {
        _ = self;
        _ = struct_decl;
        // TODO: Generate Debug implementation
        return &[_]ast.Stmt{};
    }

    /// Generate Clone trait implementation
    pub fn deriveClone(self: *DeriveMacro, struct_decl: *ast.StructDecl) ![]ast.Stmt {
        _ = self;
        _ = struct_decl;
        // TODO: Generate Clone implementation
        return &[_]ast.Stmt{};
    }

    /// Generate PartialEq trait implementation
    pub fn derivePartialEq(self: *DeriveMacro, struct_decl: *ast.StructDecl) ![]ast.Stmt {
        _ = self;
        _ = struct_decl;
        // TODO: Generate PartialEq implementation
        return &[_]ast.Stmt{};
    }

    /// Generate Serialize trait implementation
    pub fn deriveSerialize(self: *DeriveMacro, struct_decl: *ast.StructDecl) ![]ast.Stmt {
        _ = self;
        _ = struct_decl;
        // TODO: Generate Serialize implementation
        return &[_]ast.Stmt{};
    }
};

/// Built-in declarative macros
pub const BuiltinMacros = struct {
    /// vec! macro for creating vectors
    pub fn vec(allocator: std.mem.Allocator) !*Macro {
        const macro = try Macro.init(allocator, "vec", .Declarative, .{ .line = 0, .column = 0 });

        // Rule: vec!($($x:expr),*) => { ... }
        // TODO: Add actual rule implementation

        return macro;
    }

    /// println! macro for formatted printing
    pub fn println(allocator: std.mem.Allocator) !*Macro {
        const macro = try Macro.init(allocator, "println", .Declarative, .{ .line = 0, .column = 0 });
        return macro;
    }

    /// assert! macro for runtime assertions
    pub fn assert(allocator: std.mem.Allocator) !*Macro {
        const macro = try Macro.init(allocator, "assert", .Declarative, .{ .line = 0, .column = 0 });
        return macro;
    }

    /// matches! macro for pattern matching
    pub fn matches(allocator: std.mem.Allocator) !*Macro {
        const macro = try Macro.init(allocator, "matches", .Declarative, .{ .line = 0, .column = 0 });
        return macro;
    }
};
