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
            },
            .StepOver => {
                // TODO: Implement step over logic
                self.state = .Running;
            },
            .StepIn => {
                // TODO: Implement step in logic
                self.state = .Running;
            },
            .StepOut => {
                // TODO: Implement step out logic
                self.state = .Running;
            },
            .Pause => {
                self.state = .Paused;
            },
            .Evaluate => {
                // TODO: Implement expression evaluation
            },
            .GetVariable => {
                // TODO: Implement variable retrieval
            },
            .SetVariable => {
                // TODO: Implement variable modification
            },
        }
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
