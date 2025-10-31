// Home Programming Language - Inline Functions
// Function inlining for performance optimization

const std = @import("std");

// ============================================================================
// Public API Exports
// ============================================================================

pub const InlineHint = enum {
    /// No inlining hint
    None,
    /// Suggest inlining (compiler may ignore)
    Inline,
    /// Force inlining (compiler should always inline)
    AlwaysInline,
    /// Prevent inlining
    NoInline,
};

pub const InlineStrategy = enum {
    /// Automatic: compiler decides based on heuristics
    Auto,
    /// Size-based: inline small functions only
    Small,
    /// Hot path: inline functions in performance-critical paths
    Hot,
    /// Aggressive: inline everything possible
    Aggressive,
    /// Conservative: only inline when explicitly marked
    Conservative,
};

// ============================================================================
// Function Metadata
// ============================================================================

pub const FunctionMetadata = struct {
    /// Function name
    name: []const u8,
    /// Inline hint from source code
    hint: InlineHint,
    /// Estimated instruction count
    instruction_count: u32,
    /// Number of times the function is called
    call_count: u32,
    /// Whether function is recursive
    is_recursive: bool,
    /// Whether function has side effects
    has_side_effects: bool,
    /// Function size in bytes
    size_bytes: u32,

    pub fn init(name: []const u8) FunctionMetadata {
        return .{
            .name = name,
            .hint = .None,
            .instruction_count = 0,
            .call_count = 0,
            .is_recursive = false,
            .has_side_effects = false,
            .size_bytes = 0,
        };
    }

    /// Determine if function should be inlined based on heuristics
    pub fn shouldInline(self: FunctionMetadata, strategy: InlineStrategy) bool {
        // Always respect explicit hints
        switch (self.hint) {
            .AlwaysInline => return true,
            .NoInline => return false,
            .Inline => return true, // Treat as strong suggestion
            .None => {},
        }

        // Recursive functions should not be inlined
        if (self.is_recursive) return false;

        // Apply strategy
        return switch (strategy) {
            .Auto => self.autoInlineHeuristic(),
            .Small => self.size_bytes < 128 or self.instruction_count < 10,
            .Hot => self.call_count > 10 and self.instruction_count < 50,
            .Aggressive => self.instruction_count < 100,
            .Conservative => false,
        };
    }

    fn autoInlineHeuristic(self: FunctionMetadata) bool {
        // Small functions are good candidates
        if (self.size_bytes < 64 or self.instruction_count < 5) {
            return true;
        }

        // Frequently called small-medium functions
        if (self.call_count > 5 and self.instruction_count < 20) {
            return true;
        }

        // Very frequently called functions
        if (self.call_count > 20 and self.instruction_count < 50) {
            return true;
        }

        return false;
    }
};

// ============================================================================
// Inline Decision Engine
// ============================================================================

pub const InlineDecisionEngine = struct {
    strategy: InlineStrategy,
    max_inline_depth: u32,
    max_inline_size: u32,
    functions: std.StringHashMap(FunctionMetadata),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, strategy: InlineStrategy) InlineDecisionEngine {
        return .{
            .strategy = strategy,
            .max_inline_depth = 3,
            .max_inline_size = 512,
            .functions = std.StringHashMap(FunctionMetadata).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *InlineDecisionEngine) void {
        self.functions.deinit();
    }

    /// Register a function with the engine
    pub fn registerFunction(self: *InlineDecisionEngine, metadata: FunctionMetadata) !void {
        try self.functions.put(metadata.name, metadata);
    }

    /// Update function call count
    pub fn recordCall(self: *InlineDecisionEngine, name: []const u8) !void {
        if (self.functions.getPtr(name)) |func| {
            func.call_count += 1;
        }
    }

    /// Check if function should be inlined
    pub fn shouldInline(self: *InlineDecisionEngine, name: []const u8) bool {
        const func = self.functions.get(name) orelse return false;
        return func.shouldInline(self.strategy);
    }

    /// Get inline statistics
    pub fn getStatistics(self: *InlineDecisionEngine) Statistics {
        var stats = Statistics.init();

        var it = self.functions.iterator();
        while (it.next()) |entry| {
            const func = entry.value_ptr.*;
            stats.total_functions += 1;

            if (func.shouldInline(self.strategy)) {
                stats.inlined_functions += 1;
                stats.total_inlined_size += func.size_bytes;
            }
        }

        return stats;
    }
};

pub const Statistics = struct {
    total_functions: u32,
    inlined_functions: u32,
    total_inlined_size: u32,

    pub fn init() Statistics {
        return .{
            .total_functions = 0,
            .inlined_functions = 0,
            .total_inlined_size = 0,
        };
    }

    pub fn inlineRatio(self: Statistics) f32 {
        if (self.total_functions == 0) return 0.0;
        return @as(f32, @floatFromInt(self.inlined_functions)) / @as(f32, @floatFromInt(self.total_functions));
    }
};

// ============================================================================
// Code Transformation
// ============================================================================

pub const InlineTransformer = struct {
    allocator: std.mem.Allocator,
    engine: *InlineDecisionEngine,
    depth: u32,

    pub fn init(allocator: std.mem.Allocator, engine: *InlineDecisionEngine) InlineTransformer {
        return .{
            .allocator = allocator,
            .engine = engine,
            .depth = 0,
        };
    }

    /// Transform function call to inline expansion
    pub fn transformCall(self: *InlineTransformer, call: CallSite) !?InlinedCode {
        // Check depth limit
        if (self.depth >= self.engine.max_inline_depth) {
            return null;
        }

        // Check if should inline
        if (!self.engine.shouldInline(call.function_name)) {
            return null;
        }

        // Get function metadata
        const func = self.engine.functions.get(call.function_name) orelse return null;

        // Check size limit
        if (func.size_bytes > self.engine.max_inline_size) {
            return null;
        }

        // Create inlined code
        self.depth += 1;
        defer self.depth -= 1;

        return InlinedCode{
            .original_call = call,
            .inlined_size = func.size_bytes,
            .instruction_count = func.instruction_count,
        };
    }
};

pub const CallSite = struct {
    function_name: []const u8,
    location: SourceLocation,
    arguments: []const []const u8,
};

pub const InlinedCode = struct {
    original_call: CallSite,
    inlined_size: u32,
    instruction_count: u32,
};

pub const SourceLocation = struct {
    file: []const u8,
    line: u32,
    column: u32,
};

// ============================================================================
// Inline Attributes
// ============================================================================

/// Attribute builder for inline hints
pub const InlineAttribute = struct {
    hint: InlineHint,

    pub fn always() InlineAttribute {
        return .{ .hint = .AlwaysInline };
    }

    pub fn never() InlineAttribute {
        return .{ .hint = .NoInline };
    }

    pub fn suggest() InlineAttribute {
        return .{ .hint = .Inline };
    }
};

// ============================================================================
// Cost Model
// ============================================================================

pub const CostModel = struct {
    /// Cost of a function call (baseline)
    call_overhead: u32 = 10,
    /// Cost per instruction in function body
    instruction_cost: u32 = 1,
    /// Cost of parameter passing (per parameter)
    parameter_cost: u32 = 2,
    /// Cost of stack frame setup
    frame_cost: u32 = 5,

    pub fn calculateCallCost(self: CostModel, param_count: u32) u32 {
        return self.call_overhead + self.frame_cost + (param_count * self.parameter_cost);
    }

    pub fn calculateInlineCost(self: CostModel, instruction_count: u32) u32 {
        return instruction_count * self.instruction_cost;
    }

    /// Returns true if inlining would reduce cost
    pub fn benefitsFromInlining(self: CostModel, func: FunctionMetadata, param_count: u32) bool {
        const call_cost = self.calculateCallCost(param_count) * func.call_count;
        const inline_cost = self.calculateInlineCost(func.instruction_count) * func.call_count;
        return inline_cost < call_cost;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "inline hint" {
    const testing = std.testing;

    const hints = [_]InlineHint{ .None, .Inline, .AlwaysInline, .NoInline };
    try testing.expectEqual(@as(usize, 4), hints.len);
}

test "function metadata" {
    const testing = std.testing;

    var func = FunctionMetadata.init("test_function");
    func.instruction_count = 5;
    func.size_bytes = 32;

    try testing.expect(func.shouldInline(.Small));
    try testing.expect(func.shouldInline(.Auto));

    func.hint = .NoInline;
    try testing.expect(!func.shouldInline(.Small));
    try testing.expect(!func.shouldInline(.Auto));

    func.hint = .AlwaysInline;
    try testing.expect(func.shouldInline(.Small));
    try testing.expect(func.shouldInline(.Conservative));
}

test "inline decision engine" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var engine = InlineDecisionEngine.init(allocator, .Auto);
    defer engine.deinit();

    var func = FunctionMetadata.init("small_func");
    func.instruction_count = 3;
    func.size_bytes = 24;

    try engine.registerFunction(func);
    try testing.expect(engine.shouldInline("small_func"));

    try engine.recordCall("small_func");
    try engine.recordCall("small_func");
    try engine.recordCall("small_func");

    const func_ptr = engine.functions.get("small_func");
    try testing.expect(func_ptr != null);
    try testing.expectEqual(@as(u32, 3), func_ptr.?.call_count);
}

test "inline statistics" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var engine = InlineDecisionEngine.init(allocator, .Small);
    defer engine.deinit();

    var func1 = FunctionMetadata.init("func1");
    func1.instruction_count = 5;
    func1.size_bytes = 32;
    try engine.registerFunction(func1);

    var func2 = FunctionMetadata.init("func2");
    func2.instruction_count = 100;
    func2.size_bytes = 512;
    try engine.registerFunction(func2);

    const stats = engine.getStatistics();
    try testing.expectEqual(@as(u32, 2), stats.total_functions);
    try testing.expectEqual(@as(u32, 1), stats.inlined_functions);
    try testing.expectEqual(@as(f32, 0.5), stats.inlineRatio());
}

test "cost model" {
    const testing = std.testing;

    const model = CostModel{};

    const call_cost = model.calculateCallCost(3);
    try testing.expect(call_cost > 0);

    const inline_cost = model.calculateInlineCost(10);
    try testing.expect(inline_cost > 0);

    var func = FunctionMetadata.init("test");
    func.instruction_count = 5;
    func.call_count = 10;
    func.size_bytes = 40;

    try testing.expect(model.benefitsFromInlining(func, 2));
}

test "inline transformer" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var engine = InlineDecisionEngine.init(allocator, .Auto);
    defer engine.deinit();

    var func = FunctionMetadata.init("inline_me");
    func.hint = .AlwaysInline;
    func.instruction_count = 3;
    func.size_bytes = 24;
    try engine.registerFunction(func);

    var transformer = InlineTransformer.init(allocator, &engine);

    const call = CallSite{
        .function_name = "inline_me",
        .location = .{ .file = "test.zig", .line = 1, .column = 1 },
        .arguments = &[_][]const u8{},
    };

    const result = try transformer.transformCall(call);
    try testing.expect(result != null);
    try testing.expectEqual(@as(u32, 24), result.?.inlined_size);
}

test "recursive function not inlined" {
    const testing = std.testing;

    var func = FunctionMetadata.init("recursive");
    func.is_recursive = true;
    func.instruction_count = 5;
    func.size_bytes = 32;

    try testing.expect(!func.shouldInline(.Auto));
    try testing.expect(!func.shouldInline(.Aggressive));
}

test "inline attributes" {
    const testing = std.testing;

    const always = InlineAttribute.always();
    try testing.expectEqual(InlineHint.AlwaysInline, always.hint);

    const never = InlineAttribute.never();
    try testing.expectEqual(InlineHint.NoInline, never.hint);

    const suggest_attr = InlineAttribute.suggest();
    try testing.expectEqual(InlineHint.Inline, suggest_attr.hint);
}
