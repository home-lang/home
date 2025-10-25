const std = @import("std");
const Type = @import("type_system.zig").Type;
const ast = @import("ast");

/// Capabilities mirror the 32 kernel capabilities
pub const Capability = enum(u5) {
    // File capabilities
    CAP_READ_FILE = 0,
    CAP_WRITE_FILE = 1,
    CAP_EXEC_FILE = 2,
    CAP_CHOWN = 3,
    CAP_FOWNER = 4,

    // Network capabilities
    CAP_NET_BIND_SERVICE = 5,
    CAP_NET_ADMIN = 6,
    CAP_NET_RAW = 7,

    // System capabilities
    CAP_SYS_ADMIN = 8,
    CAP_SYS_BOOT = 9,
    CAP_SYS_TIME = 10,
    CAP_SYS_MODULE = 11,
    CAP_SYS_RAWIO = 12,

    // Process capabilities
    CAP_KILL = 13,
    CAP_SETUID = 14,
    CAP_SETGID = 15,
    CAP_SETPCAP = 16,

    // IPC capabilities
    CAP_IPC_LOCK = 17,
    CAP_IPC_OWNER = 18,

    // Security capabilities
    CAP_MAC_ADMIN = 19,
    CAP_MAC_OVERRIDE = 20,
    CAP_SYSLOG = 21,
    CAP_AUDIT_WRITE = 22,
    CAP_AUDIT_CONTROL = 23,

    // Additional capabilities
    CAP_LEASE = 24,
    CAP_SETFCAP = 25,
    CAP_WAKE_ALARM = 26,
    CAP_BLOCK_SUSPEND = 27,
    CAP_BPF = 28,
    CAP_PERFMON = 29,
    CAP_CHECKPOINT_RESTORE = 30,
    CAP_DAC_OVERRIDE = 31,

    pub fn toString(self: Capability) []const u8 {
        return @tagName(self);
    }

    pub fn fromString(name: []const u8) ?Capability {
        inline for (std.meta.fields(Capability)) |field| {
            if (std.mem.eql(u8, name, field.name)) {
                return @enumFromInt(field.value);
            }
        }
        return null;
    }
};

/// Set of capabilities
pub const CapabilitySet = std.EnumSet(Capability);

/// Type with capability requirements
pub const CapableType = struct {
    base_type: Type,
    required_caps: CapabilitySet,
    location: ?ast.SourceLocation,

    pub fn init(base: Type, caps: CapabilitySet) CapableType {
        return .{
            .base_type = base,
            .required_caps = caps,
            .location = null,
        };
    }

    pub fn initSingle(base: Type, cap: Capability) CapableType {
        var caps = CapabilitySet.initEmpty();
        caps.insert(cap);
        return init(base, caps);
    }

    pub fn initWithLocation(base: Type, caps: CapabilitySet, loc: ast.SourceLocation) CapableType {
        return .{
            .base_type = base,
            .required_caps = caps,
            .location = loc,
        };
    }

    /// Check if available capabilities satisfy requirements
    pub fn check(self: CapableType, available: CapabilitySet) bool {
        return available.containsAll(self.required_caps);
    }

    /// Merge two capable types (union of capabilities)
    pub fn merge(self: CapableType, other: CapableType) CapableType {
        var merged_caps = self.required_caps;
        var iter = other.required_caps.iterator();
        while (iter.next()) |cap| {
            merged_caps.insert(cap);
        }
        return CapableType.init(self.base_type, merged_caps);
    }
};

/// Function signature with capability requirements
pub const CapableFunction = struct {
    name: []const u8,
    param_types: []const CapableType,
    return_type: CapableType,
    required_caps: CapabilitySet,

    pub fn init(
        name: []const u8,
        params: []const CapableType,
        ret: CapableType,
        caps: CapabilitySet,
    ) CapableFunction {
        return .{
            .name = name,
            .param_types = params,
            .return_type = ret,
            .required_caps = caps,
        };
    }

    /// Get all capabilities needed to call this function
    pub fn getAllRequiredCaps(self: CapableFunction) CapabilitySet {
        var all_caps = self.required_caps;

        // Add parameter capabilities
        for (self.param_types) |param| {
            var iter = param.required_caps.iterator();
            while (iter.next()) |cap| {
                all_caps.insert(cap);
            }
        }

        // Add return type capabilities
        var iter = self.return_type.required_caps.iterator();
        while (iter.next()) |cap| {
            all_caps.insert(cap);
        }

        return all_caps;
    }
};

/// Capability tracker for program analysis
pub const CapabilityTracker = struct {
    allocator: std.mem.Allocator,
    /// Currently available capabilities
    available_caps: CapabilitySet,
    /// Functions and their capability requirements
    functions: std.StringHashMap(CapableFunction),
    /// Errors found
    errors: std.ArrayList(CapabilityError),
    /// Stack of capability scopes
    scope_stack: std.ArrayList(CapabilityScope),

    pub fn init(allocator: std.mem.Allocator) CapabilityTracker {
        return .{
            .allocator = allocator,
            .available_caps = CapabilitySet.initEmpty(),
            .functions = std.StringHashMap(CapableFunction).init(allocator),
            .errors = std.ArrayList(CapabilityError).init(allocator),
            .scope_stack = std.ArrayList(CapabilityScope).init(allocator),
        };
    }

    pub fn deinit(self: *CapabilityTracker) void {
        self.functions.deinit();
        self.errors.deinit();
        self.scope_stack.deinit();
    }

    /// Set available capabilities (usually from kernel/runtime)
    pub fn setAvailable(self: *CapabilityTracker, caps: CapabilitySet) void {
        self.available_caps = caps;
    }

    /// Grant a capability
    pub fn grantCapability(self: *CapabilityTracker, cap: Capability) void {
        self.available_caps.insert(cap);
    }

    /// Revoke a capability
    pub fn revokeCapability(self: *CapabilityTracker, cap: Capability) void {
        self.available_caps.remove(cap);
    }

    /// Register a function with its capability requirements
    pub fn registerFunction(self: *CapabilityTracker, func: CapableFunction) !void {
        try self.functions.put(func.name, func);
    }

    /// Check if operation is allowed with current capabilities
    pub fn checkOperation(
        self: *CapabilityTracker,
        required: CapabilitySet,
        operation: []const u8,
        loc: ast.SourceLocation,
    ) !void {
        if (!self.available_caps.containsAll(required)) {
            var missing = CapabilitySet.initEmpty();
            var iter = required.iterator();
            while (iter.next()) |cap| {
                if (!self.available_caps.contains(cap)) {
                    missing.insert(cap);
                }
            }

            try self.addError(.{
                .kind = .MissingCapability,
                .message = try self.formatMissingCaps(operation, missing),
                .location = loc,
                .required = required,
                .available = self.available_caps,
            });
        }
    }

    /// Check function call
    pub fn checkFunctionCall(
        self: *CapabilityTracker,
        func_name: []const u8,
        loc: ast.SourceLocation,
    ) !void {
        const func = self.functions.get(func_name) orelse return;

        const required = func.getAllRequiredCaps();
        try self.checkOperation(required, func_name, loc);
    }

    /// Enter a new capability scope (for unsafe blocks, etc.)
    pub fn enterScope(self: *CapabilityTracker, caps: CapabilitySet) !void {
        try self.scope_stack.append(.{
            .capabilities = caps,
            .previous_caps = self.available_caps,
        });
        self.available_caps = caps;
    }

    /// Exit current capability scope
    pub fn exitScope(self: *CapabilityTracker) !void {
        if (self.scope_stack.items.len == 0) {
            return error.NoScopeToExit;
        }

        const scope = self.scope_stack.pop();
        self.available_caps = scope.previous_caps;
    }

    fn formatMissingCaps(self: *CapabilityTracker, operation: []const u8, missing: CapabilitySet) ![]const u8 {
        var buf = std.ArrayList(u8).init(self.allocator);
        errdefer buf.deinit();

        try buf.writer().print("Operation '{s}' requires capabilities: ", .{operation});

        var first = true;
        var iter = missing.iterator();
        while (iter.next()) |cap| {
            if (!first) {
                try buf.appendSlice(", ");
            }
            try buf.appendSlice(cap.toString());
            first = false;
        }

        return buf.toOwnedSlice();
    }

    fn addError(self: *CapabilityTracker, err: CapabilityError) !void {
        try self.errors.append(err);
    }

    pub fn hasErrors(self: *CapabilityTracker) bool {
        return self.errors.items.len > 0;
    }
};

/// Capability scope
const CapabilityScope = struct {
    capabilities: CapabilitySet,
    previous_caps: CapabilitySet,
};

/// Capability error
pub const CapabilityError = struct {
    kind: ErrorKind,
    message: []const u8,
    location: ast.SourceLocation,
    required: CapabilitySet,
    available: CapabilitySet,

    pub const ErrorKind = enum {
        MissingCapability,
        ExcessiveCapability,
        InvalidScope,
    };
};

// ============================================================================
// Built-in Capability Requirements
// ============================================================================

pub const BuiltinCapabilities = struct {
    pub fn register(tracker: *CapabilityTracker) !void {
        const allocator = tracker.allocator;

        // File operations
        {
            var caps = CapabilitySet.initEmpty();
            caps.insert(.CAP_READ_FILE);

            const params = try allocator.alloc(CapableType, 1);
            params[0] = CapableType.init(Type.String, CapabilitySet.initEmpty());

            try tracker.registerFunction(CapableFunction.init(
                "open_file",
                params,
                CapableType.init(Type.Int, CapabilitySet.initEmpty()),
                caps,
            ));
        }

        {
            var caps = CapabilitySet.initEmpty();
            caps.insert(.CAP_WRITE_FILE);

            const params = try allocator.alloc(CapableType, 2);
            params[0] = CapableType.init(Type.Int, CapabilitySet.initEmpty());
            params[1] = CapableType.init(Type.String, CapabilitySet.initEmpty());

            try tracker.registerFunction(CapableFunction.init(
                "write_file",
                params,
                CapableType.init(Type.Int, CapabilitySet.initEmpty()),
                caps,
            ));
        }

        // Network operations
        {
            var caps = CapabilitySet.initEmpty();
            caps.insert(.CAP_NET_BIND_SERVICE);

            const params = try allocator.alloc(CapableType, 1);
            params[0] = CapableType.init(Type.Int, CapabilitySet.initEmpty());

            try tracker.registerFunction(CapableFunction.init(
                "bind_port",
                params,
                CapableType.init(Type.Int, CapabilitySet.initEmpty()),
                caps,
            ));
        }

        // System operations
        {
            var caps = CapabilitySet.initEmpty();
            caps.insert(.CAP_SYS_TIME);

            const params = try allocator.alloc(CapableType, 1);
            params[0] = CapableType.init(Type.Int, CapabilitySet.initEmpty());

            try tracker.registerFunction(CapableFunction.init(
                "set_system_time",
                params,
                CapableType.init(Type.Int, CapabilitySet.initEmpty()),
                caps,
            ));
        }

        // Process operations
        {
            var caps = CapabilitySet.initEmpty();
            caps.insert(.CAP_KILL);

            const params = try allocator.alloc(CapableType, 1);
            params[0] = CapableType.init(Type.Int, CapabilitySet.initEmpty());

            try tracker.registerFunction(CapableFunction.init(
                "kill_process",
                params,
                CapableType.init(Type.Int, CapabilitySet.initEmpty()),
                caps,
            ));
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

test "capability set operations" {
    var caps = CapabilitySet.initEmpty();

    caps.insert(.CAP_READ_FILE);
    caps.insert(.CAP_WRITE_FILE);

    try std.testing.expect(caps.contains(.CAP_READ_FILE));
    try std.testing.expect(caps.contains(.CAP_WRITE_FILE));
    try std.testing.expect(!caps.contains(.CAP_NET_ADMIN));
}

test "capable type check" {
    var required = CapabilitySet.initEmpty();
    required.insert(.CAP_READ_FILE);

    const capable = CapableType.init(Type.String, required);

    var available = CapabilitySet.initEmpty();
    available.insert(.CAP_READ_FILE);
    available.insert(.CAP_WRITE_FILE);

    try std.testing.expect(capable.check(available));

    var insufficient = CapabilitySet.initEmpty();
    insufficient.insert(.CAP_WRITE_FILE);

    try std.testing.expect(!capable.check(insufficient));
}

test "capability tracker basic" {
    var tracker = CapabilityTracker.init(std.testing.allocator);
    defer tracker.deinit();

    tracker.grantCapability(.CAP_READ_FILE);

    try std.testing.expect(tracker.available_caps.contains(.CAP_READ_FILE));

    tracker.revokeCapability(.CAP_READ_FILE);

    try std.testing.expect(!tracker.available_caps.contains(.CAP_READ_FILE));
}

test "capability requirement check" {
    var tracker = CapabilityTracker.init(std.testing.allocator);
    defer tracker.deinit();

    tracker.grantCapability(.CAP_READ_FILE);

    var required = CapabilitySet.initEmpty();
    required.insert(.CAP_WRITE_FILE);

    const loc = ast.SourceLocation{ .line = 1, .column = 1, .file = "test.ion" };

    try tracker.checkOperation(required, "write_operation", loc);

    try std.testing.expect(tracker.hasErrors());
}

test "capability scope" {
    var tracker = CapabilityTracker.init(std.testing.allocator);
    defer tracker.deinit();

    tracker.grantCapability(.CAP_READ_FILE);

    var elevated_caps = CapabilitySet.initEmpty();
    elevated_caps.insert(.CAP_SYS_ADMIN);

    try tracker.enterScope(elevated_caps);

    try std.testing.expect(tracker.available_caps.contains(.CAP_SYS_ADMIN));
    try std.testing.expect(!tracker.available_caps.contains(.CAP_READ_FILE));

    try tracker.exitScope();

    try std.testing.expect(tracker.available_caps.contains(.CAP_READ_FILE));
    try std.testing.expect(!tracker.available_caps.contains(.CAP_SYS_ADMIN));
}

test "capable type merge" {
    var caps1 = CapabilitySet.initEmpty();
    caps1.insert(.CAP_READ_FILE);

    var caps2 = CapabilitySet.initEmpty();
    caps2.insert(.CAP_WRITE_FILE);

    const type1 = CapableType.init(Type.String, caps1);
    const type2 = CapableType.init(Type.String, caps2);

    const merged = type1.merge(type2);

    try std.testing.expect(merged.required_caps.contains(.CAP_READ_FILE));
    try std.testing.expect(merged.required_caps.contains(.CAP_WRITE_FILE));
}
