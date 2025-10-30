const std = @import("std");
const ast = @import("ast.zig");
const Node = ast.Node;
const NodeType = ast.NodeType;
const SourceLocation = ast.SourceLocation;
const Expr = ast.Expr;
const BlockStmt = ast.BlockStmt;

/// Closure expression node
/// Represents anonymous functions with capture semantics
/// Examples: |x| x + 1, |a, b| { a + b }, || println("hello")
pub const ClosureExpr = struct {
    node: Node,
    params: []const ClosureParam,
    return_type: ?*TypeExpr,
    body: ClosureBody,
    captures: []const Capture,
    is_async: bool,
    is_move: bool,  // move semantics (takes ownership of captures)

    pub fn init(
        params: []const ClosureParam,
        return_type: ?*TypeExpr,
        body: ClosureBody,
        captures: []const Capture,
        is_async: bool,
        is_move: bool,
        loc: SourceLocation,
    ) ClosureExpr {
        return .{
            .node = .{ .type = .ClosureExpr, .loc = loc },
            .params = params,
            .return_type = return_type,
            .body = body,
            .captures = captures,
            .is_async = is_async,
            .is_move = is_move,
        };
    }

    pub fn deinit(self: *ClosureExpr, allocator: std.mem.Allocator) void {
        for (self.params) |*param| {
            param.deinit(allocator);
        }
        allocator.free(self.params);
        
        if (self.return_type) |rt| {
            rt.deinit(allocator);
            allocator.destroy(rt);
        }
        
        self.body.deinit(allocator);
        
        for (self.captures) |*capture| {
            capture.deinit(allocator);
        }
        allocator.free(self.captures);
    }
};

/// Closure parameter
pub const ClosureParam = struct {
    name: []const u8,
    type_annotation: ?*TypeExpr,
    is_mut: bool,

    pub fn deinit(self: *ClosureParam, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        if (self.type_annotation) |ta| {
            ta.deinit(allocator);
            allocator.destroy(ta);
        }
    }
};

/// Closure body - either an expression or a block
pub const ClosureBody = union(enum) {
    Expression: *Expr,
    Block: *BlockStmt,

    pub fn deinit(self: *ClosureBody, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .Expression => |expr| allocator.destroy(expr),
            .Block => |block| allocator.destroy(block),
        }
    }
};

/// Variable capture in a closure
pub const Capture = struct {
    name: []const u8,
    mode: CaptureMode,
    source_location: SourceLocation,

    pub const CaptureMode = enum {
        ByValue,      // Copy the value
        ByRef,        // Borrow immutably (&)
        ByMutRef,     // Borrow mutably (&mut)
        ByMove,       // Take ownership (move)
    };

    pub fn deinit(self: *Capture, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

/// Type expression for closures
pub const TypeExpr = union(enum) {
    Named: []const u8,
    Generic: struct {
        base: []const u8,
        args: []const *TypeExpr,
    },
    Reference: struct {
        is_mut: bool,
        inner: *TypeExpr,
    },
    Pointer: struct {
        is_mut: bool,
        inner: *TypeExpr,
    },
    Function: struct {
        params: []const *TypeExpr,
        return_type: ?*TypeExpr,
    },
    Closure: struct {
        params: []const *TypeExpr,
        return_type: ?*TypeExpr,
        captures: CaptureKind,
    },

    pub const CaptureKind = enum {
        None,      // No captures
        Shared,    // Shared references
        Unique,    // Unique/mutable references
        Owned,     // Owned values
    };

    pub fn deinit(self: *TypeExpr, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .Named => |name| allocator.free(name),
            .Generic => |gen| {
                allocator.free(gen.base);
                for (gen.args) |arg| {
                    arg.deinit(allocator);
                    allocator.destroy(arg);
                }
                allocator.free(gen.args);
            },
            .Reference, .Pointer => |ref| {
                ref.inner.deinit(allocator);
                allocator.destroy(ref.inner);
            },
            .Function => |func| {
                for (func.params) |param| {
                    param.deinit(allocator);
                    allocator.destroy(param);
                }
                allocator.free(func.params);
                if (func.return_type) |rt| {
                    rt.deinit(allocator);
                    allocator.destroy(rt);
                }
            },
            .Closure => |closure| {
                for (closure.params) |param| {
                    param.deinit(allocator);
                    allocator.destroy(param);
                }
                allocator.free(closure.params);
                if (closure.return_type) |rt| {
                    rt.deinit(allocator);
                    allocator.destroy(rt);
                }
            },
        }
    }
};

/// Closure traits for type system
/// Fn, FnMut, FnOnce (like Rust)
pub const ClosureTrait = enum {
    /// Fn - Can be called multiple times with shared references
    /// Captures by reference, can be called concurrently
    Fn,
    
    /// FnMut - Can be called multiple times with mutable references
    /// Captures by mutable reference, requires exclusive access
    FnMut,
    
    /// FnOnce - Can be called only once, consumes captured values
    /// Captures by move, takes ownership
    FnOnce,

    pub fn toString(self: ClosureTrait) []const u8 {
        return switch (self) {
            .Fn => "Fn",
            .FnMut => "FnMut",
            .FnOnce => "FnOnce",
        };
    }
};

/// Closure environment - captured variables
pub const ClosureEnvironment = struct {
    captures: std.StringHashMap(CapturedVar),
    allocator: std.mem.Allocator,

    pub const CapturedVar = struct {
        name: []const u8,
        mode: Capture.CaptureMode,
        type_name: []const u8,
        offset: usize,  // Offset in closure struct
    };

    pub fn init(allocator: std.mem.Allocator) ClosureEnvironment {
        return .{
            .captures = std.StringHashMap(CapturedVar).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ClosureEnvironment) void {
        var it = self.captures.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.type_name);
        }
        self.captures.deinit();
    }

    pub fn addCapture(
        self: *ClosureEnvironment,
        name: []const u8,
        mode: Capture.CaptureMode,
        type_name: []const u8,
    ) !void {
        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);
        
        const type_copy = try self.allocator.dupe(u8, type_name);
        errdefer self.allocator.free(type_copy);

        const offset = self.captures.count();
        
        try self.captures.put(name_copy, .{
            .name = name_copy,
            .mode = mode,
            .type_name = type_copy,
            .offset = offset,
        });
    }

    pub fn getCapture(self: *const ClosureEnvironment, name: []const u8) ?CapturedVar {
        return self.captures.get(name);
    }

    pub fn hasCapture(self: *const ClosureEnvironment, name: []const u8) bool {
        return self.captures.contains(name);
    }
};

/// Closure analysis result
pub const ClosureAnalysis = struct {
    trait: ClosureTrait,
    environment: ClosureEnvironment,
    is_pure: bool,  // No side effects
    is_recursive: bool,

    pub fn deinit(self: *ClosureAnalysis) void {
        self.environment.deinit();
    }
};
