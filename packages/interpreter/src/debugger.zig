const std = @import("std");
const ast = @import("ast");
const Value = @import("value.zig").Value;
const Environment = @import("environment.zig").Environment;

/// Breakpoint information
pub const Breakpoint = struct {
    file: []const u8,
    line: usize,
    enabled: bool = true,
    hit_count: usize = 0,
};

/// Stack frame information for debugging
pub const StackFrame = struct {
    function_name: []const u8,
    file: []const u8,
    line: usize,
    column: usize,
    environment: *Environment,
};

/// Debug event types
pub const DebugEvent = union(enum) {
    /// Program stopped at a breakpoint
    Breakpoint: struct {
        file: []const u8,
        line: usize,
    },
    /// Program stopped at entry point
    Entry,
    /// Program stopped for step operation
    Step,
    /// Program stopped due to exception
    Exception: []const u8,
    /// Program terminated
    Terminated: ?i32, // exit code
};

/// Debug command from debugger client
pub const DebugCommand = union(enum) {
    /// Continue execution
    Continue,
    /// Step over (next line, don't step into functions)
    StepOver,
    /// Step into (enter function calls)
    StepIn,
    /// Step out (return from current function)
    StepOut,
    /// Pause execution
    Pause,
    /// Evaluate expression
    Evaluate: []const u8,
    /// Get variable value
    GetVariable: []const u8,
    /// Set variable value
    SetVariable: struct {
        name: []const u8,
        value: []const u8,
    },
};

/// Debugger state machine
pub const DebugState = enum {
    /// Debugger not active
    Inactive,
    /// Running normally
    Running,
    /// Stopped at breakpoint or step
    Stopped,
    /// Paused by user
    Paused,
    /// Program terminated
    Terminated,
};

/// Debugger interface for Home interpreter
///
/// Provides debugging capabilities including:
/// - Breakpoint management
/// - Step-by-step execution
/// - Stack trace inspection
/// - Variable inspection and modification
/// - Expression evaluation
///
/// Communication Protocol:
/// The debugger communicates via JSON messages over stdio:
/// - Input: Debug commands from DAP client
/// - Output: Debug events and responses
pub const Debugger = struct {
    allocator: std.mem.Allocator,
    breakpoints: std.ArrayList(Breakpoint),
    call_stack: std.ArrayList(StackFrame),
    state: DebugState,
    current_file: []const u8,
    current_line: usize,
    stop_on_entry: bool,
    command_queue: std.ArrayList(DebugCommand),
    event_queue: std.ArrayList(DebugEvent),
    /// Stack depth when step over/out was initiated
    step_target_depth: ?usize,
    /// Line number when step over was initiated
    step_over_line: ?usize,

    /// Initialize the debugger
    pub fn init(allocator: std.mem.Allocator) Debugger {
        return .{
            .allocator = allocator,
            .breakpoints = std.ArrayList(Breakpoint).init(allocator),
            .call_stack = std.ArrayList(StackFrame).init(allocator),
            .state = .Inactive,
            .current_file = "",
            .current_line = 0,
            .stop_on_entry = false,
            .command_queue = std.ArrayList(DebugCommand).init(allocator),
            .event_queue = std.ArrayList(DebugEvent).init(allocator),
            .step_target_depth = null,
            .step_over_line = null,
        };
    }

    pub fn deinit(self: *Debugger) void {
        self.breakpoints.deinit();
        self.call_stack.deinit();
        self.command_queue.deinit();
        self.event_queue.deinit();
    }

    /// Start debugging session
    pub fn start(self: *Debugger, stop_on_entry: bool) !void {
        self.state = if (stop_on_entry) .Stopped else .Running;
        self.stop_on_entry = stop_on_entry;

        if (stop_on_entry) {
            try self.event_queue.append(.Entry);
        }
    }

    /// Add a breakpoint
    pub fn addBreakpoint(self: *Debugger, file: []const u8, line: usize) !void {
        const bp = Breakpoint{
            .file = file,
            .line = line,
        };
        try self.breakpoints.append(bp);
    }

    /// Remove a breakpoint
    pub fn removeBreakpoint(self: *Debugger, file: []const u8, line: usize) void {
        var i: usize = 0;
        while (i < self.breakpoints.items.len) {
            const bp = &self.breakpoints.items[i];
            if (std.mem.eql(u8, bp.file, file) and bp.line == line) {
                _ = self.breakpoints.orderedRemove(i);
                return;
            }
            i += 1;
        }
    }

    /// Check if we should stop at the current location
    pub fn shouldStop(self: *Debugger, file: []const u8, line: usize) bool {
        if (self.state != .Running) return false;

        // Check step operations first
        const current_depth = self.call_stack.items.len;

        // Step over: stop when we're on a different line at same or shallower depth
        if (self.step_over_line) |target_line| {
            if (self.step_target_depth) |target_depth| {
                if (current_depth <= target_depth and line != target_line) {
                    return true;
                }
            }
        }

        // Step out: stop when stack depth is shallower than target
        if (self.step_target_depth) |target_depth| {
            if (self.step_over_line == null) {
                // Only for step out (not step over)
                if (current_depth <= target_depth) {
                    return true;
                }
            }
        }

        // Step in: stop at any new line (handled by always stopping if no target set)
        if (self.step_target_depth == null and self.step_over_line == null) {
            // Step in mode - stop at first line change
            if (line != self.current_line or !std.mem.eql(u8, file, self.current_file)) {
                return true;
            }
        }

        // Check breakpoints
        for (self.breakpoints.items) |*bp| {
            if (bp.enabled and std.mem.eql(u8, bp.file, file) and bp.line == line) {
                bp.hit_count += 1;
                return true;
            }
        }

        return false;
    }

    /// Update current location
    pub fn updateLocation(self: *Debugger, file: []const u8, line: usize) !void {
        self.current_file = file;
        self.current_line = line;

        if (self.shouldStop(file, line)) {
            self.state = .Stopped;
            try self.event_queue.append(.{ .Breakpoint = .{
                .file = file,
                .line = line,
            }});
        }
    }

    /// Push a stack frame (entering a function)
    pub fn pushFrame(
        self: *Debugger,
        function_name: []const u8,
        file: []const u8,
        line: usize,
        column: usize,
        environment: *Environment,
    ) !void {
        const frame = StackFrame{
            .function_name = function_name,
            .file = file,
            .line = line,
            .column = column,
            .environment = environment,
        };
        try self.call_stack.append(frame);
    }

    /// Pop a stack frame (returning from a function)
    pub fn popFrame(self: *Debugger) void {
        if (self.call_stack.items.len > 0) {
            _ = self.call_stack.pop();
        }
    }

    /// Get current stack trace
    pub fn getStackTrace(self: *Debugger) []const StackFrame {
        return self.call_stack.items;
    }

    /// Get variables in current scope
    pub fn getVariables(self: *Debugger, scope: enum { Local, Global }) !std.ArrayList(Variable) {
        var variables = std.ArrayList(Variable).init(self.allocator);

        const env = if (self.call_stack.items.len > 0)
            self.call_stack.items[self.call_stack.items.len - 1].environment
        else
            return variables;

        // Iterate through environment bindings
        var iter = env.bindings.iterator();
        while (iter.next()) |entry| {
            const variable = Variable{
                .name = entry.key_ptr.*,
                .value = entry.value_ptr.*,
                .scope = scope,
            };
            try variables.append(variable);
        }

        // If requesting global scope, also check parent environments
        if (scope == .Global) {
            var current_env = env.parent;
            while (current_env) |parent| {
                var parent_iter = parent.bindings.iterator();
                while (parent_iter.next()) |entry| {
                    const variable = Variable{
                        .name = entry.key_ptr.*,
                        .value = entry.value_ptr.*,
                        .scope = .Global,
                    };
                    try variables.append(variable);
                }
                current_env = parent.parent;
            }
        }

        return variables;
    }

    /// Process a debug command
    pub fn processCommand(self: *Debugger, command: DebugCommand) !void {
        switch (command) {
            .Continue => {
                self.state = .Running;
                self.step_target_depth = null;
                self.step_over_line = null;
            },
            .StepOver => {
                // Step over: execute until next line at same or shallower stack depth
                // Don't enter function calls
                self.state = .Running;
                self.step_target_depth = self.call_stack.items.len;
                self.step_over_line = self.current_line;
            },
            .StepIn => {
                // Step in: execute one statement, entering function calls
                // Simply stop at the very next line
                self.state = .Running;
                self.step_target_depth = null;
                self.step_over_line = null;
            },
            .StepOut => {
                // Step out: execute until we return from current function
                // Stop when stack depth decreases
                self.state = .Running;
                if (self.call_stack.items.len > 0) {
                    self.step_target_depth = self.call_stack.items.len - 1;
                } else {
                    self.step_target_depth = 0;
                }
                self.step_over_line = null;
            },
            .Pause => {
                self.state = .Paused;
            },
            .Evaluate => |expr| {
                // Evaluate expression in current context
                try self.evaluateExpression(expr);
            },
            .GetVariable => |var_name| {
                // Get variable value from current environment
                try self.getVariable(var_name);
            },
            .SetVariable => |set_var| {
                // Set variable value in current environment
                try self.setVariable(set_var.name, set_var.value);
            },
        }
    }

    /// Evaluate an expression in the current debugging context
    fn evaluateExpression(self: *Debugger, expr: []const u8) !void {
        // Get current stack frame environment
        if (self.call_stack.items.len == 0) {
            std.debug.print("No stack frame available for evaluation\n", .{});
            return;
        }

        const frame = self.call_stack.items[self.call_stack.items.len - 1];

        // For now, just try to look up as a variable
        if (frame.environment.get(expr)) |value| {
            std.debug.print("Eval: {s} = {any}\n", .{ expr, value });
        } else {
            std.debug.print("Eval: {s} = <undefined>\n", .{expr});
        }

        // In a full implementation, this would:
        // 1. Parse the expression string into AST
        // 2. Evaluate using the interpreter with current environment
        // 3. Return the result value
    }

    /// Get a variable value from the current environment
    fn getVariable(self: *Debugger, var_name: []const u8) !void {
        if (self.call_stack.items.len == 0) {
            std.debug.print("Variable {s}: <no stack frame>\n", .{var_name});
            return;
        }

        const frame = self.call_stack.items[self.call_stack.items.len - 1];

        if (frame.environment.get(var_name)) |value| {
            std.debug.print("Variable {s} = {any}\n", .{ var_name, value });
        } else {
            std.debug.print("Variable {s}: <undefined>\n", .{var_name});
        }
    }

    /// Set a variable value in the current environment
    fn setVariable(self: *Debugger, var_name: []const u8, value_str: []const u8) !void {
        if (self.call_stack.items.len == 0) {
            std.debug.print("Cannot set {s}: no stack frame\n", .{var_name});
            return;
        }

        const frame = self.call_stack.items[self.call_stack.items.len - 1];

        // Parse the value string (simplified - just handle integers for now)
        const value = std.fmt.parseInt(i64, value_str, 10) catch {
            std.debug.print("Cannot parse value: {s}\n", .{value_str});
            return;
        };

        // Create a Value and store it
        const val = Value{ .Integer = value };
        try frame.environment.set(var_name, val);

        std.debug.print("Set {s} = {d}\n", .{ var_name, value });

        // In a full implementation, this would:
        // 1. Parse the value string into appropriate Value type
        // 2. Support all value types (strings, bools, floats, etc.)
        // 3. Validate type compatibility with existing variable
    }

    /// Wait for debugger command (blocking)
    pub fn waitForCommand(self: *Debugger) !DebugCommand {
        // In real implementation, this would read from stdin
        // For now, automatically continue
        _ = self;
        return .Continue;
    }

    /// Send debug event to client
    pub fn sendEvent(self: *Debugger, event: DebugEvent) !void {
        try self.event_queue.append(event);
        // In real implementation, this would write JSON to stdout
        try self.flushEvents();
    }

    /// Flush pending events
    fn flushEvents(self: *Debugger) !void {
        const stdout = std.io.getStdOut().writer();

        for (self.event_queue.items) |event| {
            switch (event) {
                .Breakpoint => |bp| {
                    try stdout.print("[DEBUG] Breakpoint hit at {s}:{d}\n", .{ bp.file, bp.line });
                },
                .Entry => {
                    try stdout.print("[DEBUG] Stopped on entry\n", .{});
                },
                .Step => {
                    try stdout.print("[DEBUG] Step completed\n", .{});
                },
                .Exception => |msg| {
                    try stdout.print("[DEBUG] Exception: {s}\n", .{msg});
                },
                .Terminated => |code| {
                    if (code) |c| {
                        try stdout.print("[DEBUG] Program terminated with code {d}\n", .{c});
                    } else {
                        try stdout.print("[DEBUG] Program terminated\n", .{});
                    }
                },
            }
        }

        self.event_queue.clearRetainingCapacity();
    }
};

/// Variable information for debugging
pub const Variable = struct {
    name: []const u8,
    value: Value,
    scope: enum { Local, Global },
};
