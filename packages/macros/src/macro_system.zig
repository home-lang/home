const std = @import("std");
const ast = @import("ast");

/// Macro definition types
pub const MacroKind = enum {
    Declarative, // Pattern-based macros like macro_rules! in Rust
    Procedural, // Function-like macros that operate on AST
    Attribute, // Attribute macros like #[derive(...)]
    Derive, // Special case for deriving traits
};

/// A macro definition
pub const Macro = struct {
    name: []const u8,
    kind: MacroKind,
    rules: []MacroRule,
    loc: ast.SourceLocation,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, kind: MacroKind, loc: ast.SourceLocation) !*Macro {
        const macro = try allocator.create(Macro);
        macro.* = .{
            .name = name,
            .kind = kind,
            .rules = &[_]MacroRule{},
            .loc = loc,
            .allocator = allocator,
        };
        return macro;
    }

    pub fn deinit(self: *Macro) void {
        for (self.rules) |*rule| {
            rule.deinit();
        }
        if (self.rules.len > 0) {
            self.allocator.free(self.rules);
        }
        self.allocator.destroy(self);
    }

    pub fn addRule(self: *Macro, rule: MacroRule) !void {
        const new_rules = try self.allocator.alloc(MacroRule, self.rules.len + 1);
        if (self.rules.len > 0) {
            @memcpy(new_rules[0..self.rules.len], self.rules);
            self.allocator.free(self.rules);
        }
        new_rules[self.rules.len] = rule;
        self.rules = new_rules;
    }
};

/// A single rule in a declarative macro
pub const MacroRule = struct {
    pattern: MacroPattern,
    template: MacroTemplate,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *MacroRule) void {
        self.pattern.deinit();
        self.template.deinit();
    }
};

/// Pattern for matching macro input
pub const MacroPattern = struct {
    fragments: []MacroFragment,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MacroPattern {
        return .{
            .fragments = &[_]MacroFragment{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MacroPattern) void {
        for (self.fragments) |*frag| {
            frag.deinit();
        }
        if (self.fragments.len > 0) {
            self.allocator.free(self.fragments);
        }
    }

    pub fn addFragment(self: *MacroPattern, fragment: MacroFragment) !void {
        const new_frags = try self.allocator.alloc(MacroFragment, self.fragments.len + 1);
        if (self.fragments.len > 0) {
            @memcpy(new_frags[0..self.fragments.len], self.fragments);
            self.allocator.free(self.fragments);
        }
        new_frags[self.fragments.len] = fragment;
        self.fragments = new_frags;
    }
};

/// Fragment of a macro pattern
pub const MacroFragment = union(enum) {
    Literal: []const u8, // Exact token match
    Variable: MacroVariable, // Capture like $name:ty
    Repetition: MacroRepetition, // $(...)+ or $(...)*
    Optional: *MacroPattern, // $(...)?

    pub fn deinit(self: *MacroFragment) void {
        switch (self.*) {
            .Repetition => |*rep| rep.deinit(),
            .Optional => |pattern| pattern.deinit(),
            else => {},
        }
    }
};

/// Variable capture in macro pattern
pub const MacroVariable = struct {
    name: []const u8,
    kind: MacroVariableKind,
};

pub const MacroVariableKind = enum {
    Expr, // Expression
    Stmt, // Statement
    Type, // Type
    Ident, // Identifier
    Path, // Path like std::io::File
    Block, // Block expression
    Item, // Top-level item (function, struct, etc.)
    Literal, // Literal value
    Token, // Single token
};

/// Repetition pattern like $(...)+ or $(...)*
pub const MacroRepetition = struct {
    pattern: MacroPattern,
    separator: ?[]const u8, // Optional separator like ','
    kind: RepetitionKind,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *MacroRepetition) void {
        self.pattern.deinit();
    }
};

pub const RepetitionKind = enum {
    ZeroOrMore, // *
    OneOrMore, // +
    ZeroOrOne, // ?
};

/// Template for generating macro output
pub const MacroTemplate = struct {
    fragments: []TemplateFragment,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MacroTemplate {
        return .{
            .fragments = &[_]TemplateFragment{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MacroTemplate) void {
        if (self.fragments.len > 0) {
            self.allocator.free(self.fragments);
        }
    }
};

/// Fragment in macro template output
pub const TemplateFragment = union(enum) {
    Literal: []const u8,
    Variable: []const u8,
    Repetition: struct {
        fragments: []TemplateFragment,
        separator: ?[]const u8,
    },
};

/// Manages all macros and expansion
pub const MacroSystem = struct {
    allocator: std.mem.Allocator,
    macros: std.StringHashMap(*Macro),
    builtin_macros: std.StringHashMap(BuiltinMacro),
    expansion_stack: std.ArrayList([]const u8), // Track recursive expansions
    errors: std.ArrayList(MacroError),

    pub fn init(allocator: std.mem.Allocator) MacroSystem {
        var system = MacroSystem{
            .allocator = allocator,
            .macros = std.StringHashMap(*Macro).init(allocator),
            .builtin_macros = std.StringHashMap(BuiltinMacro).init(allocator),
            .expansion_stack = std.ArrayList([]const u8).init(allocator),
            .errors = std.ArrayList(MacroError).init(allocator),
        };

        // Register built-in macros
        system.initBuiltinMacros() catch {};

        return system;
    }

    pub fn deinit(self: *MacroSystem) void {
        var macro_iter = self.macros.iterator();
        while (macro_iter.next()) |entry| {
            entry.value_ptr.*.deinit();
        }
        self.macros.deinit();
        self.builtin_macros.deinit();
        self.expansion_stack.deinit();
        self.errors.deinit();
    }

    /// Initialize built-in macros
    fn initBuiltinMacros(self: *MacroSystem) !void {
        try self.builtin_macros.put("println", .{
            .name = "println",
            .expand_fn = expandPrintln,
        });

        try self.builtin_macros.put("vec", .{
            .name = "vec",
            .expand_fn = expandVec,
        });

        try self.builtin_macros.put("format", .{
            .name = "format",
            .expand_fn = expandFormat,
        });

        try self.builtin_macros.put("assert", .{
            .name = "assert",
            .expand_fn = expandAssert,
        });

        try self.builtin_macros.put("debug_assert", .{
            .name = "debug_assert",
            .expand_fn = expandDebugAssert,
        });

        try self.builtin_macros.put("todo", .{
            .name = "todo",
            .expand_fn = expandTodo,
        });

        try self.builtin_macros.put("unimplemented", .{
            .name = "unimplemented",
            .expand_fn = expandUnimplemented,
        });
    }

    /// Register a user-defined macro
    pub fn registerMacro(self: *MacroSystem, macro: *Macro) !void {
        if (self.macros.contains(macro.name)) {
            try self.addError(.{
                .kind = .DuplicateMacro,
                .message = try std.fmt.allocPrint(self.allocator, "macro '{s}' is already defined", .{macro.name}),
                .loc = macro.loc,
            });
            return error.DuplicateMacro;
        }
        try self.macros.put(macro.name, macro);
    }

    /// Expand a macro invocation
    pub fn expand(self: *MacroSystem, invocation: MacroInvocation) ![]const u8 {
        // Check for infinite recursion
        if (self.expansion_stack.items.len > 128) {
            try self.addError(.{
                .kind = .RecursionLimit,
                .message = try std.fmt.allocPrint(self.allocator, "macro recursion limit exceeded", .{}),
                .loc = invocation.loc,
            });
            return error.RecursionLimit;
        }

        // Check if already expanding this macro (direct recursion)
        for (self.expansion_stack.items) |name| {
            if (std.mem.eql(u8, name, invocation.name)) {
                try self.addError(.{
                    .kind = .RecursiveMacro,
                    .message = try std.fmt.allocPrint(self.allocator, "recursive macro expansion detected", .{}),
                    .loc = invocation.loc,
                });
                return error.RecursiveMacro;
            }
        }

        try self.expansion_stack.append(invocation.name);
        defer _ = self.expansion_stack.pop();

        // Check for built-in macros first
        if (self.builtin_macros.get(invocation.name)) |builtin| {
            return try builtin.expand_fn(self, invocation);
        }

        // Look up user-defined macro
        const macro = self.macros.get(invocation.name) orelse {
            try self.addError(.{
                .kind = .UnknownMacro,
                .message = try std.fmt.allocPrint(self.allocator, "macro '{s}' is not defined", .{invocation.name}),
                .loc = invocation.loc,
            });
            return error.UnknownMacro;
        };

        // Try each rule until one matches
        for (macro.rules) |*rule| {
            if (try self.matchPattern(&rule.pattern, invocation.input)) |captures| {
                return try self.instantiateTemplate(&rule.template, captures);
            }
        }

        try self.addError(.{
            .kind = .NoMatchingRule,
            .message = try std.fmt.allocPrint(
                self.allocator,
                "no matching rule for macro '{s}'",
                .{invocation.name},
            ),
            .loc = invocation.loc,
        });
        return error.NoMatchingRule;
    }

    /// Match macro input against a pattern
    fn matchPattern(self: *MacroSystem, pattern: *const MacroPattern, input: []const u8) !?MacroCaptures {
        _ = self;
        _ = pattern;
        _ = input;
        // This would implement pattern matching logic
        // For now, return null (no match)
        return null;
    }

    /// Instantiate a template with captured values
    fn instantiateTemplate(self: *MacroSystem, template: *const MacroTemplate, captures: MacroCaptures) ![]const u8 {
        _ = captures;
        var result = std.ArrayList(u8).init(self.allocator);

        for (template.fragments) |frag| {
            switch (frag) {
                .Literal => |lit| try result.appendSlice(lit),
                .Variable => |var_name| {
                    _ = var_name;
                    // Look up captured value and append
                },
                .Repetition => {
                    // Expand repetition
                },
            }
        }

        return result.toOwnedSlice();
    }

    fn addError(self: *MacroSystem, err: MacroError) !void {
        try self.errors.append(err);
    }
};

/// Macro invocation
pub const MacroInvocation = struct {
    name: []const u8,
    input: []const u8,
    loc: ast.SourceLocation,
};

/// Captured values from pattern matching
pub const MacroCaptures = struct {
    values: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) MacroCaptures {
        return .{
            .values = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *MacroCaptures) void {
        self.values.deinit();
    }
};

/// Built-in macro definition
pub const BuiltinMacro = struct {
    name: []const u8,
    expand_fn: *const fn (*MacroSystem, MacroInvocation) anyerror![]const u8,
};

/// Built-in macro expansion functions
fn expandPrintln(system: *MacroSystem, invocation: MacroInvocation) ![]const u8 {
    return try std.fmt.allocPrint(
        system.allocator,
        "print({s}); print(\"\\n\");",
        .{invocation.input},
    );
}

fn expandVec(system: *MacroSystem, invocation: MacroInvocation) ![]const u8 {
    return try std.fmt.allocPrint(
        system.allocator,
        "Vec::from([{s}])",
        .{invocation.input},
    );
}

fn expandFormat(system: *MacroSystem, invocation: MacroInvocation) ![]const u8 {
    return try std.fmt.allocPrint(
        system.allocator,
        "std::fmt::format({s})",
        .{invocation.input},
    );
}

fn expandAssert(system: *MacroSystem, invocation: MacroInvocation) ![]const u8 {
    return try std.fmt.allocPrint(
        system.allocator,
        "if (!({s})) {{ panic(\"assertion failed: {s}\"); }}",
        .{ invocation.input, invocation.input },
    );
}

fn expandDebugAssert(system: *MacroSystem, invocation: MacroInvocation) ![]const u8 {
    return try std.fmt.allocPrint(
        system.allocator,
        "#if DEBUG\nif (!({s})) {{ panic(\"assertion failed: {s}\"); }}\n#endif",
        .{ invocation.input, invocation.input },
    );
}

fn expandTodo(system: *MacroSystem, invocation: MacroInvocation) ![]const u8 {
    _ = invocation;
    return try std.fmt.allocPrint(
        system.allocator,
        "panic(\"not yet implemented\")",
        .{},
    );
}

fn expandUnimplemented(system: *MacroSystem, invocation: MacroInvocation) ![]const u8 {
    _ = invocation;
    return try std.fmt.allocPrint(
        system.allocator,
        "panic(\"not implemented\")",
        .{},
    );
}

/// Macro errors
pub const MacroError = struct {
    kind: MacroErrorKind,
    message: []const u8,
    loc: ast.SourceLocation,
};

pub const MacroErrorKind = enum {
    DuplicateMacro,
    UnknownMacro,
    NoMatchingRule,
    RecursiveMacro,
    RecursionLimit,
    InvalidPattern,
    InvalidTemplate,
};
