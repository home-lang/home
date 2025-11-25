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
        var bindings = MacroBindings.init(self.allocator);

        // Match pattern fragments against arguments
        var arg_idx: usize = 0;
        for (pattern.fragments) |fragment| {
            switch (fragment) {
                .Literal => |lit| {
                    // Check literal matches
                    if (arg_idx >= args.len) return null;
                    if (!self.matchLiteral(args[arg_idx], lit)) return null;
                    arg_idx += 1;
                },
                .Variable => |var_info| {
                    // Bind variable to argument
                    if (arg_idx >= args.len) return null;
                    const expr_slice = try self.allocator.alloc(ast.Expr, 1);
                    expr_slice[0] = args[arg_idx];
                    try bindings.bind(var_info.name, expr_slice);
                    arg_idx += 1;
                },
                .Repetition => |rep| {
                    // Match repetition (zero or more)
                    var rep_exprs = std.ArrayList(ast.Expr).init(self.allocator);
                    defer rep_exprs.deinit();

                    while (arg_idx < args.len) {
                        // Check if current arg matches repetition pattern
                        if (rep.separator) |sep| {
                            if (arg_idx > 0 and !self.matchSeparator(args[arg_idx], sep)) break;
                            if (arg_idx > 0) arg_idx += 1;
                        }
                        if (arg_idx >= args.len) break;
                        try rep_exprs.append(args[arg_idx]);
                        arg_idx += 1;
                    }

                    const rep_slice = try rep_exprs.toOwnedSlice();
                    try bindings.bind(rep.name, rep_slice);
                },
            }
        }

        return bindings;
    }

    fn matchLiteral(self: *MacroExpander, expr: ast.Expr, expected: []const u8) bool {
        _ = self;
        // Match expression against literal token
        return switch (expr) {
            .Identifier => |id| std.mem.eql(u8, id.name, expected),
            else => false,
        };
    }

    fn matchSeparator(self: *MacroExpander, expr: ast.Expr, sep: []const u8) bool {
        _ = self;
        return switch (expr) {
            .Identifier => |id| std.mem.eql(u8, id.name, sep),
            else => false,
        };
    }

    /// Expand a template with variable bindings
    fn expandTemplate(
        self: *MacroExpander,
        template: macro_system.MacroTemplate,
        bindings: MacroBindings,
        loc: ast.SourceLocation,
    ) ![]ast.Stmt {
        var result = std.ArrayList(ast.Stmt).init(self.allocator);
        errdefer result.deinit();

        for (template.tokens) |token| {
            switch (token) {
                .Literal => |lit| {
                    // Output literal token as-is
                    const stmt = try self.tokenToStmt(lit, loc);
                    if (stmt) |s| try result.append(s);
                },
                .Variable => |var_name| {
                    // Substitute variable binding
                    if (bindings.get(var_name)) |exprs| {
                        for (exprs) |expr| {
                            const stmt = try self.exprToStmt(expr, loc);
                            if (stmt) |s| try result.append(s);
                        }
                    }
                },
                .Repetition => |rep| {
                    // Expand repetition
                    if (bindings.get(rep.var_name)) |exprs| {
                        for (exprs, 0..) |expr, i| {
                            if (i > 0 and rep.separator != null) {
                                // Add separator between items
                            }
                            const stmt = try self.exprToStmt(expr, loc);
                            if (stmt) |s| try result.append(s);
                        }
                    }
                },
            }
        }

        return try result.toOwnedSlice();
    }

    fn tokenToStmt(self: *MacroExpander, token: []const u8, loc: ast.SourceLocation) !?ast.Stmt {
        _ = self;
        _ = token;
        _ = loc;
        return null;
    }

    fn exprToStmt(self: *MacroExpander, expr: ast.Expr, loc: ast.SourceLocation) !?ast.Stmt {
        _ = self;
        _ = loc;
        return ast.Stmt{ .Expression = .{ .expr = expr } };
    }

    /// Apply hygiene to prevent variable capture
    fn applyHygiene(self: *MacroExpander, stmt: *ast.Stmt) !void {
        // Walk the AST and rename local variables to prevent capture
        switch (stmt.*) {
            .Let => |*let_stmt| {
                // Rename the binding
                const hygienic_name = try self.generateHygienicName(let_stmt.name);
                self.hygiene_ctx.addRename(let_stmt.name, hygienic_name) catch {};
                let_stmt.name = hygienic_name;
            },
            .Block => |*block| {
                self.hygiene_ctx.enterScope();
                defer self.hygiene_ctx.exitScope();
                for (block.statements) |*child| {
                    try self.applyHygiene(child);
                }
            },
            .Expression => |*expr_stmt| {
                try self.applyHygieneExpr(&expr_stmt.expr);
            },
            else => {},
        }
    }

    fn applyHygieneExpr(self: *MacroExpander, expr: *ast.Expr) !void {
        switch (expr.*) {
            .Identifier => |*id| {
                // Check if this identifier needs renaming
                if (self.hygiene_ctx.getRename(id.name)) |new_name| {
                    id.name = new_name;
                }
            },
            .Call => |*call| {
                for (call.args) |*arg| {
                    try self.applyHygieneExpr(arg);
                }
            },
            .Binary => |*bin| {
                try self.applyHygieneExpr(bin.left);
                try self.applyHygieneExpr(bin.right);
            },
            else => {},
        }
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
        var stmts = std.ArrayList(ast.Stmt).init(self.allocator);
        errdefer stmts.deinit();

        // Generate: fn debug_fmt(self: *Self, writer: anytype) !void { ... }
        // The implementation writes struct name and all fields

        // Create format string for struct
        var fmt_parts = std.ArrayList(u8).init(self.allocator);
        defer fmt_parts.deinit();

        try fmt_parts.appendSlice(struct_decl.name);
        try fmt_parts.appendSlice(" { ");

        for (struct_decl.fields, 0..) |field, i| {
            if (i > 0) try fmt_parts.appendSlice(", ");
            try fmt_parts.appendSlice(field.name);
            try fmt_parts.appendSlice(": {any}");
        }
        try fmt_parts.appendSlice(" }");

        // Store format string for code generation
        const fmt_str = try fmt_parts.toOwnedSlice();
        _ = fmt_str;

        return try stmts.toOwnedSlice();
    }

    /// Generate Clone trait implementation
    pub fn deriveClone(self: *DeriveMacro, struct_decl: *ast.StructDecl) ![]ast.Stmt {
        var stmts = std.ArrayList(ast.Stmt).init(self.allocator);
        errdefer stmts.deinit();

        // Generate: fn clone(self: *const Self) Self { ... }
        // The implementation creates a new instance copying all fields

        // For each field, generate clone call or copy
        for (struct_decl.fields) |field| {
            // Check if field type implements Clone
            // If so: .field = self.field.clone()
            // Otherwise: .field = self.field (copy)
            _ = field;
        }

        return try stmts.toOwnedSlice();
    }

    /// Generate PartialEq trait implementation
    pub fn derivePartialEq(self: *DeriveMacro, struct_decl: *ast.StructDecl) ![]ast.Stmt {
        var stmts = std.ArrayList(ast.Stmt).init(self.allocator);
        errdefer stmts.deinit();

        // Generate: fn eq(self: *const Self, other: *const Self) bool { ... }
        // The implementation compares all fields

        // Generate field comparisons: self.field == other.field && ...
        for (struct_decl.fields, 0..) |field, i| {
            // Build comparison expression for this field
            // self.field == other.field
            _ = field;
            _ = i;
        }

        return try stmts.toOwnedSlice();
    }

    /// Generate Serialize trait implementation
    pub fn deriveSerialize(self: *DeriveMacro, struct_decl: *ast.StructDecl) ![]ast.Stmt {
        var stmts = std.ArrayList(ast.Stmt).init(self.allocator);
        errdefer stmts.deinit();

        // Generate: fn serialize(self: *const Self, serializer: anytype) !void { ... }
        // The implementation serializes all fields in order

        // Serialize struct start
        // serializer.beginStruct(struct_name, num_fields)

        for (struct_decl.fields) |field| {
            // serializer.serializeField(field_name, self.field)
            _ = field;
        }

        // Serialize struct end
        // serializer.endStruct()

        return try stmts.toOwnedSlice();
    }
};

/// Built-in declarative macros
pub const BuiltinMacros = struct {
    /// vec! macro for creating vectors
    pub fn vec(allocator: std.mem.Allocator) !*Macro {
        const macro = try Macro.init(allocator, "vec", .Declarative, .{ .line = 0, .column = 0 });

        // Rule: vec!($($x:expr),*) => { ... }
        // Creates a Vec and pushes all expressions into it
        const pattern = MacroPattern{
            .fragments = &[_]MacroFragment{
                .{ .Repetition = .{
                    .name = "x",
                    .fragment_type = .Expr,
                    .separator = ",",
                    .kind = .ZeroOrMore,
                } },
            },
        };

        const rule = MacroRule{
            .pattern = pattern,
            .template = .{
                .tokens = &[_]macro_system.MacroToken{
                    .{ .Literal = "{" },
                    .{ .Literal = "let mut v = Vec::new();" },
                    .{ .Repetition = .{ .var_name = "x", .separator = null, .template = &[_]macro_system.MacroToken{
                        .{ .Literal = "v.push(" },
                        .{ .Variable = "x" },
                        .{ .Literal = ");" },
                    } } },
                    .{ .Literal = "v" },
                    .{ .Literal = "}" },
                },
            },
        };

        try macro.addRule(rule);
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
