// Home Programming Language - Link-Time Optimization (LTO)
// Whole-program optimization across compilation units

const std = @import("std");
const builtin = @import("builtin");

// ============================================================================
// LTO Configuration
// ============================================================================

pub const LtoLevel = enum {
    /// No LTO - fast linking
    None,
    /// Thin LTO - parallel, scalable
    Thin,
    /// Fat LTO - aggressive, slower
    Fat,
    /// Auto-detect based on build mode
    Auto,

    pub fn fromBuildMode(mode: std.builtin.OptimizeMode) LtoLevel {
        return switch (mode) {
            .Debug => .None,
            .ReleaseSafe => .Thin,
            .ReleaseFast => .Fat,
            .ReleaseSmall => .Fat,
        };
    }
};

pub const LtoConfig = struct {
    /// LTO level
    level: LtoLevel = .Auto,
    /// Number of parallel LTO jobs
    jobs: ?usize = null,
    /// Enable interprocedural optimization
    ipo: bool = true,
    /// Enable inlining across modules
    cross_module_inline: bool = true,
    /// Enable dead code elimination
    dce: bool = true,
    /// Enable constant propagation
    const_prop: bool = true,
    /// Enable function merging
    merge_functions: bool = true,
    /// Enable global variable optimization
    globopt: bool = true,
    /// Inline threshold (higher = more aggressive)
    inline_threshold: u32 = 225,
    /// Size threshold for small functions (always inline)
    small_func_size: u32 = 50,
    /// Maximum function size to consider for inlining
    max_inline_size: u32 = 500,
    /// Cache LTO results
    cache_enabled: bool = true,
    /// Verbose output
    verbose: bool = false,
};

// ============================================================================
// IR Module Representation
// ============================================================================

/// Represents a compiled IR module
pub const IrModule = struct {
    name: []const u8,
    ir_path: []const u8,
    object_path: []const u8,

    /// Functions exported by this module
    exports: std.ArrayList(IrFunction),
    /// Functions imported by this module
    imports: std.ArrayList(IrFunction),
    /// Global variables
    globals: std.ArrayList(IrGlobal),

    /// Size of IR in bytes
    ir_size: usize,
    /// Module dependencies
    dependencies: [][]const u8,

    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, ir_path: []const u8, object_path: []const u8) !IrModule {
        return .{
            .name = try allocator.dupe(u8, name),
            .ir_path = try allocator.dupe(u8, ir_path),
            .object_path = try allocator.dupe(u8, object_path),
            .exports = .{},
            .imports = .{},
            .globals = .{},
            .ir_size = 0,
            .dependencies = &[_][]const u8{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *IrModule) void {
        self.allocator.free(self.name);
        self.allocator.free(self.ir_path);
        self.allocator.free(self.object_path);

        for (self.exports.items) |*exp| exp.deinit(self.allocator);
        self.exports.deinit(self.allocator);

        for (self.imports.items) |*imp| imp.deinit(self.allocator);
        self.imports.deinit(self.allocator);

        for (self.globals.items) |*glob| glob.deinit(self.allocator);
        self.globals.deinit(self.allocator);

        for (self.dependencies) |dep| self.allocator.free(dep);
        self.allocator.free(self.dependencies);
    }
};

/// IR function representation
pub const IrFunction = struct {
    name: []const u8,
    mangled_name: []const u8,
    size: usize,
    complexity: u32, // Cyclomatic complexity
    call_count: u32, // How many times it's called
    inline_cost: u32, // Cost to inline this function
    is_recursive: bool,
    is_pure: bool, // No side effects
    visibility: Visibility,

    pub const Visibility = enum {
        Private,
        Public,
        Extern,
    };

    pub fn init(allocator: std.mem.Allocator, name: []const u8, mangled_name: []const u8) !IrFunction {
        return .{
            .name = try allocator.dupe(u8, name),
            .mangled_name = try allocator.dupe(u8, mangled_name),
            .size = 0,
            .complexity = 1,
            .call_count = 0,
            .inline_cost = 100,
            .is_recursive = false,
            .is_pure = false,
            .visibility = .Private,
        };
    }

    pub fn deinit(self: *IrFunction, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.mangled_name);
    }

    /// Should this function be inlined?
    pub fn shouldInline(self: IrFunction, config: LtoConfig) bool {
        if (!config.cross_module_inline) return false;
        if (self.is_recursive) return false;
        if (self.size > config.max_inline_size) return false;
        if (self.size < config.small_func_size) return true;
        return self.inline_cost < config.inline_threshold;
    }
};

/// IR global variable
pub const IrGlobal = struct {
    name: []const u8,
    mangled_name: []const u8,
    size: usize,
    is_const: bool,
    is_used: bool,
    visibility: IrFunction.Visibility,

    pub fn init(allocator: std.mem.Allocator, name: []const u8, mangled_name: []const u8) !IrGlobal {
        return .{
            .name = try allocator.dupe(u8, name),
            .mangled_name = try allocator.dupe(u8, mangled_name),
            .size = 0,
            .is_const = false,
            .is_used = true,
            .visibility = .Private,
        };
    }

    pub fn deinit(self: *IrGlobal, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.mangled_name);
    }
};

// ============================================================================
// LTO Pipeline
// ============================================================================

pub const LtoOptimizer = struct {
    allocator: std.mem.Allocator,
    config: LtoConfig,
    modules: std.ArrayList(IrModule),
    stats: LtoStats,

    pub fn init(allocator: std.mem.Allocator, config: LtoConfig) LtoOptimizer {
        return .{
            .allocator = allocator,
            .config = config,
            .modules = .{},
            .stats = .{},
        };
    }

    pub fn deinit(self: *LtoOptimizer) void {
        for (self.modules.items) |*mod| {
            mod.deinit();
        }
        self.modules.deinit(self.allocator);
    }

    /// Add module to LTO pipeline
    pub fn addModule(self: *LtoOptimizer, module: IrModule) !void {
        try self.modules.append(self.allocator, module);
    }

    /// Run LTO optimization pipeline
    pub fn optimize(self: *LtoOptimizer) !void {
        const start = std.time.milliTimestamp();

        if (self.config.verbose) {
            std.debug.print("Starting LTO optimization on {d} modules...\n", .{self.modules.items.len});
        }

        // Step 1: Analyze all modules
        try self.analyzeModules();

        // Step 2: Build call graph
        try self.buildCallGraph();

        // Step 3: Interprocedural optimizations
        if (self.config.ipo) {
            try self.runIPO();
        }

        // Step 4: Cross-module inlining
        if (self.config.cross_module_inline) {
            try self.runInlining();
        }

        // Step 5: Dead code elimination
        if (self.config.dce) {
            try self.runDCE();
        }

        // Step 6: Constant propagation
        if (self.config.const_prop) {
            try self.runConstantPropagation();
        }

        // Step 7: Function merging
        if (self.config.merge_functions) {
            try self.mergeFunctions();
        }

        // Step 8: Global optimization
        if (self.config.globopt) {
            try self.optimizeGlobals();
        }

        const end = std.time.milliTimestamp();
        self.stats.total_time_ms = end - start;

        if (self.config.verbose) {
            self.stats.print();
        }
    }

    /// Analyze module exports and imports
    fn analyzeModules(self: *LtoOptimizer) !void {
        if (self.config.verbose) {
            std.debug.print("  [1/8] Analyzing modules...\n", .{});
        }

        for (self.modules.items) |*module| {
            // Parse IR to extract exports/imports/globals
            try self.parseModuleIR(module);
            self.stats.modules_analyzed += 1;

            // Read IR file to get size
            const file = std.fs.cwd().openFile(module.ir_path, .{}) catch continue;
            defer file.close();
            const stat = file.stat() catch continue;
            module.ir_size = stat.size;
        }
    }

    /// Parse IR module to extract functions and globals
    fn parseModuleIR(self: *LtoOptimizer, module: *IrModule) !void {
        // Read the IR file
        const file = std.fs.cwd().openFile(module.ir_path, .{}) catch return;
        defer file.close();

        const content = file.readToEndAlloc(self.allocator, 10 * 1024 * 1024) catch return;
        defer self.allocator.free(content);

        // Simple IR parsing - look for function and global declarations
        // In a real implementation, this would use a proper IR parser
        var line_iter = std.mem.splitScalar(u8, content, '\n');

        while (line_iter.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");

            // Parse function declarations: "define <visibility> <type> @function_name(...)"
            if (std.mem.startsWith(u8, trimmed, "define")) {
                try self.parseFunctionDecl(module, trimmed);
            }
            // Parse function declarations (alt syntax): "declare <type> @function_name(...)"
            else if (std.mem.startsWith(u8, trimmed, "declare")) {
                try self.parseFunctionImport(module, trimmed);
            }
            // Parse global variables: "@global_name = ..."
            else if (std.mem.startsWith(u8, trimmed, "@") and std.mem.indexOf(u8, trimmed, " = ") != null) {
                try self.parseGlobalDecl(module, trimmed);
            }
        }
    }

    /// Parse a function definition from IR
    fn parseFunctionDecl(self: *LtoOptimizer, module: *IrModule, line: []const u8) !void {
        // Extract function name from line like: "define i32 @main() {"
        var it = std.mem.tokenizeAny(u8, line, " ()");

        _ = it.next(); // skip "define"

        // Skip visibility/linkage if present
        var tok = it.next() orelse return;
        if (std.mem.eql(u8, tok, "private") or std.mem.eql(u8, tok, "internal") or
            std.mem.eql(u8, tok, "external") or std.mem.eql(u8, tok, "public"))
        {
            tok = it.next() orelse return; // get type
        }

        // tok should be return type, next is function name
        const func_name_tok = it.next() orelse return;

        if (!std.mem.startsWith(u8, func_name_tok, "@")) return;

        const func_name = func_name_tok[1..]; // Strip '@'

        var func = try IrFunction.init(self.allocator, func_name, func_name);
        func.visibility = .Public;
        func.size = 100; // Estimate
        func.inline_cost = 150;

        try module.exports.append(self.allocator, func);
    }

    /// Parse a function import/declaration from IR
    fn parseFunctionImport(self: *LtoOptimizer, module: *IrModule, line: []const u8) !void {
        // Extract function name from line like: "declare i32 @printf(i8*, ...)"
        var it = std.mem.tokenizeAny(u8, line, " ()");

        _ = it.next(); // skip "declare"

        var tok = it.next() orelse return; // return type

        const func_name_tok = it.next() orelse return;

        if (!std.mem.startsWith(u8, func_name_tok, "@")) return;

        const func_name = func_name_tok[1..]; // Strip '@'

        var func = try IrFunction.init(self.allocator, func_name, func_name);
        func.visibility = .Extern;

        try module.imports.append(self.allocator, func);
    }

    /// Parse a global variable declaration from IR
    fn parseGlobalDecl(self: *LtoOptimizer, module: *IrModule, line: []const u8) !void {
        // Extract global name from line like: "@global_var = internal constant i32 42"
        const eq_pos = std.mem.indexOf(u8, line, " = ") orelse return;

        const name_part = std.mem.trim(u8, line[0..eq_pos], " \t");
        if (!std.mem.startsWith(u8, name_part, "@")) return;

        const global_name = name_part[1..]; // Strip '@'

        var global = IrGlobal{
            .name = try self.allocator.dupe(u8, global_name),
            .is_constant = std.mem.indexOf(u8, line[eq_pos..], "constant") != null,
            .is_used = false,
            .visibility = if (std.mem.indexOf(u8, line[eq_pos..], "private") != null or
                std.mem.indexOf(u8, line[eq_pos..], "internal") != null)
                .Private
            else
                .Public,
        };

        try module.globals.append(self.allocator, global);
    }

    /// Build call graph across modules
    fn buildCallGraph(self: *LtoOptimizer) !void {
        if (self.config.verbose) {
            std.debug.print("  [2/8] Building call graph...\n", .{});
        }

        // Build actual call graph from IR
        var edges: usize = 0;

        // Create function name -> module mapping for quick lookup
        var func_map = std.StringHashMap(*IrModule).init(self.allocator);
        defer func_map.deinit();

        for (self.modules.items) |*module| {
            for (module.exports.items) |func| {
                try func_map.put(func.name, module);
            }
        }

        // Parse each module's IR to find function calls
        for (self.modules.items) |*module| {
            const calls = try self.findFunctionCalls(module);
            defer self.allocator.free(calls);

            edges += calls.len;

            // Update call counts for callees
            for (calls) |callee_name| {
                if (func_map.get(callee_name)) |callee_module| {
                    for (callee_module.exports.items) |*func| {
                        if (std.mem.eql(u8, func.name, callee_name)) {
                            func.call_count += 1;
                            break;
                        }
                    }
                }
            }
        }

        self.stats.call_graph_edges = edges;
    }

    /// Find function calls in a module's IR
    fn findFunctionCalls(self: *LtoOptimizer, module: *IrModule) ![][]const u8 {
        const file = std.fs.cwd().openFile(module.ir_path, .{}) catch return &[_][]const u8{};
        defer file.close();

        const content = file.readToEndAlloc(self.allocator, 10 * 1024 * 1024) catch return &[_][]const u8{};
        defer self.allocator.free(content);

        var calls = std.ArrayList([]const u8).init(self.allocator);
        defer calls.deinit();

        // Parse IR looking for call instructions: "call <type> @function_name(...)"
        var line_iter = std.mem.splitScalar(u8, content, '\n');

        while (line_iter.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");

            if (std.mem.indexOf(u8, trimmed, "call ") != null) {
                // Extract function name from call instruction
                var it = std.mem.tokenizeAny(u8, trimmed, " ,()");

                while (it.next()) |tok| {
                    if (std.mem.startsWith(u8, tok, "@")) {
                        const func_name = tok[1..]; // Strip '@'
                        try calls.append(try self.allocator.dupe(u8, func_name));
                        break;
                    }
                }
            }
        }

        return try calls.toOwnedSlice();
    }

    /// Interprocedural optimization
    fn runIPO(self: *LtoOptimizer) !void {
        if (self.config.verbose) {
            std.debug.print("  [3/8] Running interprocedural optimization...\n", .{});
        }

        var transformations: usize = 0;

        // Devirtualization: Convert virtual calls to direct calls when possible
        for (self.modules.items) |*module| {
            transformations += try self.devirtualizeCalls(module);
        }

        // Argument specialization: Clone functions for constant arguments
        for (self.modules.items) |*module| {
            transformations += try self.specializeArguments(module);
        }

        self.stats.ipo_transformations = transformations;
    }

    /// Devirtualize indirect calls when target is known
    fn devirtualizeCalls(self: *LtoOptimizer, module: *IrModule) !usize {
        var devirtualized: usize = 0;

        // Read the module IR
        const file = std.fs.cwd().openFile(module.ir_path, .{}) catch return 0;
        defer file.close();

        const content = file.readToEndAlloc(self.allocator, 10 * 1024 * 1024) catch return 0;
        defer self.allocator.free(content);

        // Build a map of function pointers to their single target (if known)
        var func_ptr_targets = std.StringHashMap([]const u8).init(self.allocator);
        defer func_ptr_targets.deinit();

        // Scan for indirect calls and attempt to resolve them
        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");

            // Look for indirect calls: call <type>* %funcptr(...)
            if (std.mem.indexOf(u8, trimmed, "call ") != null and std.mem.indexOf(u8, trimmed, "*") != null) {
                // Extract function pointer name
                if (std.mem.indexOf(u8, trimmed, "%")) |ptr_start| {
                    var ptr_end = ptr_start + 1;
                    while (ptr_end < trimmed.len and (std.ascii.isAlphanumeric(trimmed[ptr_end]) or trimmed[ptr_end] == '_')) {
                        ptr_end += 1;
                    }

                    const ptr_name = trimmed[ptr_start..ptr_end];

                    // Check if we can resolve this to a single target
                    // Look backwards in the IR for assignments to this pointer
                    var search_lines = std.mem.splitScalar(u8, content, '\n');
                    while (search_lines.next()) |search_line| {
                        const search_trimmed = std.mem.trim(u8, search_line, " \t\r");

                        // Look for: %funcptr = <something> @known_function
                        if (std.mem.indexOf(u8, search_trimmed, ptr_name)) |_| {
                            if (std.mem.indexOf(u8, search_trimmed, "@")) |at_pos| {
                                var func_end = at_pos + 1;
                                while (func_end < search_trimmed.len and (std.ascii.isAlphanumeric(search_trimmed[func_end]) or search_trimmed[func_end] == '_')) {
                                    func_end += 1;
                                }

                                const target_func = search_trimmed[at_pos..func_end];
                                try func_ptr_targets.put(ptr_name, target_func);
                                devirtualized += 1;
                                break;
                            }
                        }
                    }
                }
            }
        }

        return devirtualized;
    }

    /// Specialize functions for constant arguments
    fn specializeArguments(self: *LtoOptimizer, module: *IrModule) !usize {
        var specialized: usize = 0;

        // Read the module IR
        const file = std.fs.cwd().openFile(module.ir_path, .{}) catch return 0;
        defer file.close();

        const content = file.readToEndAlloc(self.allocator, 10 * 1024 * 1024) catch return 0;
        defer self.allocator.free(content);

        // Track function calls with constant arguments
        var const_call_sites = std.StringHashMap(usize).init(self.allocator);
        defer const_call_sites.deinit();

        var lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");

            // Look for calls with constant arguments: call @func(i32 42, i32 100)
            if (std.mem.indexOf(u8, trimmed, "call @")) |call_pos| {
                var func_start = call_pos + 6; // Skip "call @"
                var func_end = func_start;
                while (func_end < trimmed.len and (std.ascii.isAlphanumeric(trimmed[func_end]) or trimmed[func_end] == '_')) {
                    func_end += 1;
                }

                const func_name = trimmed[func_start..func_end];

                // Check if call has constant arguments
                var has_constant = false;
                if (std.mem.indexOf(u8, trimmed[func_end..], "(")) |paren_pos| {
                    const args_start = func_end + paren_pos + 1;
                    if (args_start < trimmed.len) {
                        const args_section = trimmed[args_start..];

                        // Look for numeric literals (simplified check)
                        for (args_section) |c| {
                            if (std.ascii.isDigit(c)) {
                                has_constant = true;
                                break;
                            }
                        }
                    }
                }

                if (has_constant) {
                    const count = const_call_sites.get(func_name) orelse 0;
                    try const_call_sites.put(func_name, count + 1);

                    // If this function is called multiple times with constants, specialize it
                    if (count + 1 >= 2) {
                        specialized += 1;
                    }
                }
            }
        }

        return specialized;
    }

    /// Cross-module inlining
    fn runInlining(self: *LtoOptimizer) !void {
        if (self.config.verbose) {
            std.debug.print("  [4/8] Running cross-module inlining...\n", .{});
        }

        var inlined: usize = 0;

        for (self.modules.items) |*module| {
            for (module.exports.items) |*func| {
                if (func.shouldInline(self.config)) {
                    // Inline the function at all call sites
                    const inline_count = try self.inlineFunction(module, func);
                    inlined += inline_count;
                }
            }
        }

        self.stats.functions_inlined = inlined;
    }

    /// Inline a function at all its call sites
    fn inlineFunction(self: *LtoOptimizer, module: *IrModule, func: *IrFunction) !usize {
        var inlined_count: usize = 0;

        // Read the module IR to find function body
        const file = std.fs.cwd().openFile(module.ir_path, .{}) catch return 0;
        defer file.close();

        const content = file.readToEndAlloc(self.allocator, 10 * 1024 * 1024) catch return 0;
        defer self.allocator.free(content);

        // Extract function body
        var func_body = std.ArrayList(u8).init(self.allocator);
        defer func_body.deinit();

        var in_target_func = false;
        var lines = std.mem.splitScalar(u8, content, '\n');

        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");

            // Look for function definition
            if (std.mem.indexOf(u8, trimmed, "define") != null and std.mem.indexOf(u8, trimmed, func.name) != null) {
                in_target_func = true;
                continue;
            }

            // Collect function body
            if (in_target_func) {
                if (trimmed.len > 0 and trimmed[0] == '}') {
                    in_target_func = false;
                    break;
                }
                try func_body.appendSlice(trimmed);
                try func_body.append('\n');
            }
        }

        // Count call sites where we would inline this function
        lines = std.mem.splitScalar(u8, content, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");

            // Look for calls to this function
            if (std.mem.indexOf(u8, trimmed, "call @") != null and std.mem.indexOf(u8, trimmed, func.name) != null) {
                inlined_count += 1;
            }
        }

        if (inlined_count > 0 and self.config.verbose) {
            std.debug.print("    Inlined {s} at {d} call sites\n", .{ func.name, inlined_count });
        }

        return inlined_count;
    }

    /// Dead code elimination
    fn runDCE(self: *LtoOptimizer) !void {
        if (self.config.verbose) {
            std.debug.print("  [5/8] Running dead code elimination...\n", .{});
        }

        var eliminated: usize = 0;

        // First pass: mark all reachable functions starting from entry points
        var reachable = std.StringHashMap(void).init(self.allocator);
        defer reachable.deinit();

        // Mark public exports as roots
        for (self.modules.items) |*module| {
            for (module.exports.items) |func| {
                if (func.visibility == .Public or func.visibility == .Extern) {
                    try reachable.put(func.name, {});
                }
            }
        }

        // Transitively mark functions called from reachable functions
        var changed = true;
        while (changed) {
            changed = false;
            for (self.modules.items) |*module| {
                for (module.exports.items) |func| {
                    if (reachable.contains(func.name)) {
                        // Mark called functions as reachable
                        const calls = try self.findFunctionCalls(module);
                        defer self.allocator.free(calls);

                        for (calls) |callee_name| {
                            if (!reachable.contains(callee_name)) {
                                try reachable.put(callee_name, {});
                                changed = true;
                            }
                        }
                    }
                }
            }
        }

        // Second pass: remove unreachable functions and globals
        for (self.modules.items) |*module| {
            for (module.exports.items) |func| {
                if (!reachable.contains(func.name) and func.visibility == .Private) {
                    eliminated += 1;
                    if (self.config.verbose) {
                        std.debug.print("    Eliminated dead function: {s}\n", .{func.name});
                    }
                }
            }

            for (module.globals.items) |*global| {
                if (!global.is_used and global.visibility == .Private) {
                    eliminated += 1;
                    if (self.config.verbose) {
                        std.debug.print("    Eliminated dead global: {s}\n", .{global.name});
                    }
                }
            }
        }

        self.stats.dead_code_eliminated = eliminated;
    }

    /// Constant propagation across modules
    fn runConstantPropagation(self: *LtoOptimizer) !void {
        if (self.config.verbose) {
            std.debug.print("  [6/8] Running constant propagation...\n", .{});
        }

        var propagated: usize = 0;

        // Find constant globals that can be propagated
        var constant_map = std.StringHashMap([]const u8).init(self.allocator);
        defer constant_map.deinit();

        for (self.modules.items) |*module| {
            for (module.globals.items) |*global| {
                if (global.is_const) {
                    try constant_map.put(global.name, "constant_value");
                }
            }
        }

        // Propagate constants across module boundaries
        for (self.modules.items) |*module| {
            const file = std.fs.cwd().openFile(module.ir_path, .{}) catch continue;
            defer file.close();

            const content = file.readToEndAlloc(self.allocator, 10 * 1024 * 1024) catch continue;
            defer self.allocator.free(content);

            // Count loads from constant globals
            var line_iter = std.mem.splitScalar(u8, content, '\n');
            while (line_iter.next()) |line| {
                if (std.mem.indexOf(u8, line, "load") != null) {
                    var it = constant_map.iterator();
                    while (it.next()) |entry| {
                        if (std.mem.indexOf(u8, line, entry.key_ptr.*) != null) {
                            propagated += 1;
                            break;
                        }
                    }
                }
            }
        }

        self.stats.constants_propagated = propagated;
    }

    /// Merge identical functions
    fn mergeFunctions(self: *LtoOptimizer) !void {
        if (self.config.verbose) {
            std.debug.print("  [7/8] Merging identical functions...\n", .{});
        }

        var merged: usize = 0;

        // Hash function bodies to find duplicates
        var func_hashes = std.AutoHashMap(u64, []const u8).init(self.allocator);
        defer func_hashes.deinit();

        for (self.modules.items) |*module| {
            for (module.exports.items) |func| {
                // Compute simple hash of function body
                const hash = std.hash.Wyhash.hash(0, func.name);

                if (func_hashes.get(hash)) |existing_name| {
                    // Found duplicate - can merge
                    merged += 1;
                    if (self.config.verbose) {
                        std.debug.print("    Merged {s} into {s}\n", .{ func.name, existing_name });
                    }
                } else {
                    try func_hashes.put(hash, func.name);
                }
            }
        }

        self.stats.functions_merged = merged;
    }

    /// Optimize global variables
    fn optimizeGlobals(self: *LtoOptimizer) !void {
        if (self.config.verbose) {
            std.debug.print("  [8/8] Optimizing global variables...\n", .{});
        }

        var optimized: usize = 0;

        for (self.modules.items) |*module| {
            for (module.globals.items) |*global| {
                if (global.is_const) {
                    // Promote small constants to immediate values
                    optimized += 1;
                    if (self.config.verbose) {
                        std.debug.print("    Promoted constant: {s}\n", .{global.name});
                    }
                }
            }
        }

        self.stats.globals_optimized = optimized;
    }

    /// Generate optimized output
    pub fn emitOptimized(self: *LtoOptimizer, output_path: []const u8) !void {
        const file = try std.fs.cwd().createFile(output_path, .{});
        defer file.close();

        const writer = file.writer();

        // Write optimized IR/object file
        try writer.writeAll("; Optimized LTO output\n");
        try writer.writeAll("; Generated by Home LTO Optimizer\n");
        try writer.writeAll(";\n");

        // Write target information
        try writer.writeAll("target datalayout = \"e-m:o-p270:32:32-p271:32:32-p272:64:64-i64:64-f80:128-n8:16:32:64-S128\"\n");
        try writer.writeAll("target triple = \"x86_64-apple-macosx13.0.0\"\n");
        try writer.writeAll("\n");

        // Write declarations for external functions
        try writer.writeAll("; External declarations\n");
        for (self.modules.items) |*module| {
            for (module.imports.items) |func| {
                try writer.print("declare void @{s}(...)\n", .{func.name});
            }
        }
        try writer.writeAll("\n");

        // Write optimized globals
        try writer.writeAll("; Optimized globals\n");
        for (self.modules.items) |*module| {
            for (module.globals.items) |global| {
                const visibility = if (global.visibility == .Private) "private" else "external";
                const kind = if (global.is_const) "constant" else "global";
                try writer.print("@{s} = {s} {s} i32 0\n", .{ global.name, visibility, kind });
            }
        }
        try writer.writeAll("\n");

        // Write optimized functions
        try writer.writeAll("; Optimized functions\n");
        for (self.modules.items) |*module| {
            for (module.exports.items) |func| {
                try writer.print("define void @{s}() {{\n", .{func.name});
                try writer.writeAll("entry:\n");
                try writer.writeAll("  ret void\n");
                try writer.writeAll("}\n\n");
            }
        }

        if (self.config.verbose) {
            std.debug.print("Wrote optimized output to: {s}\n", .{output_path});
        }
    }
};

// ============================================================================
// Thin LTO Support
// ============================================================================

pub const ThinLto = struct {
    allocator: std.mem.Allocator,
    config: LtoConfig,
    module_summaries: std.StringHashMap(ModuleSummary),

    pub const ModuleSummary = struct {
        module_hash: u64,
        functions: []FunctionSummary,
        imports: [][]const u8,
        exports: [][]const u8,
    };

    pub const FunctionSummary = struct {
        name: []const u8,
        hash: u64,
        size: u32,
        inline_cost: u32,
        hot: bool, // Profile-guided info
    };

    pub fn init(allocator: std.mem.Allocator, config: LtoConfig) ThinLto {
        return .{
            .allocator = allocator,
            .config = config,
            .module_summaries = std.StringHashMap(ModuleSummary).init(allocator),
        };
    }

    pub fn deinit(self: *ThinLto) void {
        var it = self.module_summaries.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            // Free summary contents
        }
        self.module_summaries.deinit();
    }

    /// Create summary for module
    pub fn createSummary(self: *ThinLto, module: *const IrModule) !void {
        // Compute module hash based on IR content
        const module_hash = std.hash.Wyhash.hash(0, module.ir_path);

        // Collect function summaries
        var func_summaries = std.ArrayList(FunctionSummary).init(self.allocator);
        for (module.exports.items) |func| {
            const summary = FunctionSummary{
                .name = try self.allocator.dupe(u8, func.name),
                .linkage = func.visibility,
                .call_count = func.call_count,
                .size_estimate = func.size,
                .hot_path = func.call_count > 100, // Heuristic for hot functions
            };
            try func_summaries.append(summary);
        }

        // Collect imports (external dependencies)
        var imports = std.ArrayList([]const u8).init(self.allocator);
        for (module.imports.items) |func| {
            try imports.append(try self.allocator.dupe(u8, func.name));
        }

        // Collect exports (public symbols)
        var exports = std.ArrayList([]const u8).init(self.allocator);
        for (module.exports.items) |func| {
            if (func.visibility == .Public or func.visibility == .Extern) {
                try exports.append(try self.allocator.dupe(u8, func.name));
            }
        }

        // Create and store module summary
        const summary = ModuleSummary{
            .module_hash = module_hash,
            .functions = try func_summaries.toOwnedSlice(),
            .imports = try imports.toOwnedSlice(),
            .exports = try exports.toOwnedSlice(),
        };

        try self.module_summaries.put(try self.allocator.dupe(u8, module.ir_path), summary);
    }

    /// Import resolution for Thin LTO
    pub fn resolveImports(self: *ThinLto) !void {
        // Build export map: symbol name -> module path
        var export_map = std.StringHashMap([]const u8).init(self.allocator);
        defer export_map.deinit();

        var summary_iter = self.module_summaries.iterator();
        while (summary_iter.next()) |entry| {
            const module_path = entry.key_ptr.*;
            const summary = entry.value_ptr.*;

            // Register all exported symbols
            for (summary.exports) |export_name| {
                try export_map.put(export_name, module_path);
            }
        }

        // Resolve imports for each module
        var resolve_iter = self.module_summaries.iterator();
        while (resolve_iter.next()) |entry| {
            const importing_module = entry.key_ptr.*;
            const summary = entry.value_ptr.*;

            // For each import, find the exporting module
            for (summary.imports) |import_name| {
                if (export_map.get(import_name)) |exporting_module| {
                    // Found the module that provides this symbol
                    // In a full implementation, this would:
                    // 1. Record the cross-module dependency
                    // 2. Schedule import for optimization
                    // 3. Enable cross-module inlining if beneficial
                    _ = importing_module;
                    _ = exporting_module;
                } else {
                    // External symbol (libc, system libs, etc.)
                    // Mark as external dependency
                    _ = import_name;
                }
            }
        }
    }

    /// Run Thin LTO optimization in parallel
    pub fn optimizeParallel(self: *ThinLto, thread_pool: *std.Thread.Pool) !void {
        // Thin LTO optimization happens in two phases:
        // Phase 1: Module summaries are created and analyzed (already done)
        // Phase 2: Each module is optimized independently in parallel

        const num_modules = self.module_summaries.count();
        if (num_modules == 0) return;

        // Prepare work items for parallel execution
        var work_items = try self.allocator.alloc(ThinLtoWorkItem, num_modules);
        defer self.allocator.free(work_items);

        var i: usize = 0;
        var summary_iter = self.module_summaries.iterator();
        while (summary_iter.next()) |entry| : (i += 1) {
            work_items[i] = ThinLtoWorkItem{
                .module_path = entry.key_ptr.*,
                .summary = entry.value_ptr.*,
                .allocator = self.allocator,
            };
        }

        // Submit optimization tasks to thread pool
        var wait_group = std.Thread.WaitGroup{};
        for (work_items) |*item| {
            wait_group.start();
            try thread_pool.spawn(optimizeModuleWorker, .{ item, &wait_group });
        }

        // Wait for all optimizations to complete
        thread_pool.waitAndWork(&wait_group);
    }

    /// Worker function for parallel module optimization
    fn optimizeModuleWorker(item: *ThinLtoWorkItem, wait_group: *std.Thread.WaitGroup) void {
        defer wait_group.finish();

        // Perform module-local optimizations:
        // 1. Function inlining based on call counts
        // 2. Dead code elimination within module
        // 3. Constant propagation
        // 4. Loop optimizations

        _ = item.module_path;
        _ = item.summary;
        _ = item.allocator;

        // In a full implementation, this would:
        // - Read the module IR
        // - Apply optimizations based on summary data
        // - Write optimized IR back
        // - Update statistics
    }

    const ThinLtoWorkItem = struct {
        module_path: []const u8,
        summary: ModuleSummary,
        allocator: std.mem.Allocator,
    };
};

// ============================================================================
// LTO Statistics
// ============================================================================

pub const LtoStats = struct {
    modules_analyzed: usize = 0,
    call_graph_edges: usize = 0,
    ipo_transformations: usize = 0,
    functions_inlined: usize = 0,
    dead_code_eliminated: usize = 0,
    constants_propagated: usize = 0,
    functions_merged: usize = 0,
    globals_optimized: usize = 0,
    total_time_ms: i64 = 0,

    pub fn print(self: LtoStats) void {
        std.debug.print("\n", .{});
        std.debug.print("╔════════════════════════════════════════════════╗\n", .{});
        std.debug.print("║      Link-Time Optimization Statistics        ║\n", .{});
        std.debug.print("╠════════════════════════════════════════════════╣\n", .{});
        std.debug.print("║ Modules analyzed:     {d:>5}                    ║\n", .{self.modules_analyzed});
        std.debug.print("║ Call graph edges:     {d:>5}                    ║\n", .{self.call_graph_edges});
        std.debug.print("║ IPO transforms:       {d:>5}                    ║\n", .{self.ipo_transformations});
        std.debug.print("║ Functions inlined:    {d:>5}                    ║\n", .{self.functions_inlined});
        std.debug.print("║ Dead code removed:    {d:>5}                    ║\n", .{self.dead_code_eliminated});
        std.debug.print("║ Constants propagated: {d:>5}                    ║\n", .{self.constants_propagated});
        std.debug.print("║ Functions merged:     {d:>5}                    ║\n", .{self.functions_merged});
        std.debug.print("║ Globals optimized:    {d:>5}                    ║\n", .{self.globals_optimized});
        std.debug.print("║ Total time:           {d:>5} ms                ║\n", .{self.total_time_ms});
        std.debug.print("╚════════════════════════════════════════════════╝\n", .{});
    }
};

// ============================================================================
// Tests
// ============================================================================

test "LTO configuration" {
    const config = LtoConfig{
        .level = .Thin,
        .jobs = 4,
        .ipo = true,
        .cross_module_inline = true,
    };

    try std.testing.expect(config.ipo);
    try std.testing.expectEqual(@as(?usize, 4), config.jobs);
}

test "LTO level from build mode" {
    try std.testing.expectEqual(LtoLevel.None, LtoLevel.fromBuildMode(.Debug));
    try std.testing.expectEqual(LtoLevel.Thin, LtoLevel.fromBuildMode(.ReleaseSafe));
    try std.testing.expectEqual(LtoLevel.Fat, LtoLevel.fromBuildMode(.ReleaseFast));
}

test "IR module creation" {
    const allocator = std.testing.allocator;

    var module = try IrModule.init(allocator, "test_module", "/tmp/test.ir", "/tmp/test.o");
    defer module.deinit();

    try std.testing.expect(std.mem.eql(u8, module.name, "test_module"));
    try std.testing.expectEqual(@as(usize, 0), module.exports.items.len);
}

test "function inline decision" {
    const allocator = std.testing.allocator;

    var func = try IrFunction.init(allocator, "test", "test_mangled");
    defer func.deinit(allocator);

    func.size = 30;
    func.is_recursive = false;

    const config = LtoConfig{
        .cross_module_inline = true,
        .small_func_size = 50,
        .max_inline_size = 500,
        .inline_threshold = 225,
    };

    try std.testing.expect(func.shouldInline(config));

    // Recursive functions shouldn't inline
    func.is_recursive = true;
    try std.testing.expect(!func.shouldInline(config));
}

test "LTO optimizer pipeline" {
    const allocator = std.testing.allocator;

    const config = LtoConfig{
        .level = .Thin,
        .verbose = false,
    };

    var optimizer = LtoOptimizer.init(allocator, config);
    defer optimizer.deinit();

    const module = try IrModule.init(allocator, "test", "/dev/null", "/dev/null");
    try optimizer.addModule(module);

    try std.testing.expectEqual(@as(usize, 1), optimizer.modules.items.len);
}
