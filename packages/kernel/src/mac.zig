// Home OS Kernel - Mandatory Access Control (MAC)
// SELinux/AppArmor-style security policies

const Basics = @import("basics");
const sync = @import("sync.zig");
const atomic = @import("atomic.zig");
const audit = @import("audit.zig");
const capabilities = @import("capabilities.zig");

// ============================================================================
// MAC Framework
// ============================================================================

pub const MacMode = enum(u8) {
    /// Disabled - no MAC enforcement
    DISABLED = 0,
    /// Permissive - log violations but don't enforce
    PERMISSIVE = 1,
    /// Enforcing - enforce all policies
    ENFORCING = 2,
};

pub const MacFramework = struct {
    /// Current mode
    mode: atomic.AtomicU8,
    /// Violation count
    violation_count: atomic.AtomicU64,
    /// Denial count
    denial_count: atomic.AtomicU64,
    /// Allow count
    allow_count: atomic.AtomicU64,

    pub fn init(mode: MacMode) MacFramework {
        return .{
            .mode = atomic.AtomicU8.init(@intFromEnum(mode)),
            .violation_count = atomic.AtomicU64.init(0),
            .denial_count = atomic.AtomicU64.init(0),
            .allow_count = atomic.AtomicU64.init(0),
        };
    }

    /// Get current mode
    pub fn getMode(self: *const MacFramework) MacMode {
        return @enumFromInt(self.mode.load(.Acquire));
    }

    /// Set mode (requires CAP_MAC_ADMIN)
    pub fn setMode(self: *MacFramework, mode: MacMode) !void {
        if (!capabilities.hasCapability(.CAP_MAC_ADMIN)) {
            return error.PermissionDenied;
        }

        self.mode.store(@intFromEnum(mode), .Release);

        var buf: [128]u8 = undefined;
        const msg = Basics.fmt.bufPrint(&buf, "MAC mode changed to {s}", .{@tagName(mode)}) catch "mac_mode_change";
        audit.logSecurityViolation(msg);
    }

    /// Record violation
    fn recordViolation(self: *MacFramework, allowed: bool) void {
        _ = self.violation_count.fetchAdd(1, .Release);

        if (allowed) {
            _ = self.allow_count.fetchAdd(1, .Release);
        } else {
            _ = self.denial_count.fetchAdd(1, .Release);
        }
    }

    /// Get statistics
    pub fn getStats(self: *const MacFramework) MacStats {
        return .{
            .violations = self.violation_count.load(.Acquire),
            .denials = self.denial_count.load(.Acquire),
            .allows = self.allow_count.load(.Acquire),
        };
    }
};

pub const MacStats = struct {
    violations: u64,
    denials: u64,
    allows: u64,
};

// ============================================================================
// Security Contexts (SELinux-style)
// ============================================================================

pub const SecurityContext = struct {
    /// User component
    user: [32]u8,
    /// Role component
    role: [32]u8,
    /// Type/domain component
    domain: [32]u8,
    /// Sensitivity level (MLS)
    level: u8,
    /// Category set (MCS)
    categories: u32,

    const DEFAULT_USER = "system_u";
    const DEFAULT_ROLE = "system_r";
    const DEFAULT_DOMAIN = "unconfined_t";

    pub fn init() SecurityContext {
        var ctx: SecurityContext = undefined;
        ctx.user = [_]u8{0} ** 32;
        ctx.role = [_]u8{0} ** 32;
        ctx.domain = [_]u8{0} ** 32;
        ctx.level = 0;
        ctx.categories = 0;

        // Set defaults
        @memcpy(ctx.user[0..DEFAULT_USER.len], DEFAULT_USER);
        @memcpy(ctx.role[0..DEFAULT_ROLE.len], DEFAULT_ROLE);
        @memcpy(ctx.domain[0..DEFAULT_DOMAIN.len], DEFAULT_DOMAIN);

        return ctx;
    }

    /// Parse context from string (user:role:domain:level)
    pub fn parse(str: []const u8) !SecurityContext {
        var ctx = init();

        var parts = Basics.mem.split(u8, str, ":");
        var i: usize = 0;

        while (parts.next()) |part| : (i += 1) {
            switch (i) {
                0 => {
                    const len = Basics.math.min(part.len, 31);
                    @memcpy(ctx.user[0..len], part[0..len]);
                },
                1 => {
                    const len = Basics.math.min(part.len, 31);
                    @memcpy(ctx.role[0..len], part[0..len]);
                },
                2 => {
                    const len = Basics.math.min(part.len, 31);
                    @memcpy(ctx.domain[0..len], part[0..len]);
                },
                3 => {
                    // Parse level (simplified)
                    ctx.level = 0;
                },
                else => break,
            }
        }

        return ctx;
    }

    /// Check if contexts match
    pub fn matches(self: *const SecurityContext, other: *const SecurityContext) bool {
        return Basics.mem.eql(u8, &self.domain, &other.domain);
    }
};

// ============================================================================
// Access Vector Cache (AVC)
// ============================================================================

pub const AccessVector = packed struct(u32) {
    read: bool = false,
    write: bool = false,
    execute: bool = false,
    append: bool = false,
    create: bool = false,
    delete: bool = false,
    getattr: bool = false,
    setattr: bool = false,
    lock: bool = false,
    relabelfrom: bool = false,
    relabelto: bool = false,
    transition: bool = false,

    _padding: u20 = 0,

    pub fn fromBits(bits: u32) AccessVector {
        return @bitCast(bits);
    }

    pub fn toBits(self: AccessVector) u32 {
        return @bitCast(self);
    }
};

pub const AvcEntry = struct {
    /// Source security context
    source: SecurityContext,
    /// Target security context
    target: SecurityContext,
    /// Object class
    class: ObjectClass,
    /// Allowed permissions
    allowed: AccessVector,
    /// Timestamp
    timestamp: u64,

    pub fn init(source: SecurityContext, target: SecurityContext, class: ObjectClass, allowed: AccessVector) AvcEntry {
        return .{
            .source = source,
            .target = target,
            .class = class,
            .allowed = allowed,
            .timestamp = @as(u64, @intCast(@as(u128, @bitCast(Basics.time.nanoTimestamp())))),
        };
    }
};

pub const ObjectClass = enum(u8) {
    FILE = 0,
    DIR = 1,
    PROCESS = 2,
    SOCKET = 3,
    CAPABILITY = 4,
};

pub const Avc = struct {
    /// Cache entries
    cache: [256]?AvcEntry,
    /// Cache size
    cache_size: atomic.AtomicU32,
    /// Hit count
    hit_count: atomic.AtomicU64,
    /// Miss count
    miss_count: atomic.AtomicU64,
    /// Lock
    lock: sync.RwLock,

    pub fn init() Avc {
        return .{
            .cache = [_]?AvcEntry{null} ** 256,
            .cache_size = atomic.AtomicU32.init(0),
            .hit_count = atomic.AtomicU64.init(0),
            .miss_count = atomic.AtomicU64.init(0),
            .lock = sync.RwLock.init(),
        };
    }

    /// Lookup in cache
    pub fn lookup(self: *Avc, source: *const SecurityContext, target: *const SecurityContext, class: ObjectClass) ?AccessVector {
        self.lock.acquireRead();
        defer self.lock.releaseRead();

        for (self.cache) |maybe_entry| {
            if (maybe_entry) |entry| {
                if (entry.source.matches(source) and entry.target.matches(target) and entry.class == class) {
                    _ = self.hit_count.fetchAdd(1, .Release);
                    return entry.allowed;
                }
            }
        }

        _ = self.miss_count.fetchAdd(1, .Release);
        return null;
    }

    /// Insert into cache
    pub fn insert(self: *Avc, entry: AvcEntry) void {
        self.lock.acquireWrite();
        defer self.lock.releaseWrite();

        const size = self.cache_size.load(.Acquire);
        const idx = size % 256;

        self.cache[idx] = entry;
        _ = self.cache_size.fetchAdd(1, .Release);
    }

    /// Flush cache
    pub fn flush(self: *Avc) void {
        self.lock.acquireWrite();
        defer self.lock.releaseWrite();

        for (&self.cache) |*entry| {
            entry.* = null;
        }

        self.cache_size.store(0, .Release);
    }
};

// ============================================================================
// Type Enforcement (TE)
// ============================================================================

pub const TeRule = struct {
    /// Source type/domain
    source_type: [32]u8,
    /// Target type
    target_type: [32]u8,
    /// Object class
    class: ObjectClass,
    /// Allowed permissions
    allowed: AccessVector,

    pub fn init(source: []const u8, target: []const u8, class: ObjectClass, allowed: AccessVector) TeRule {
        var rule: TeRule = undefined;
        rule.source_type = [_]u8{0} ** 32;
        rule.target_type = [_]u8{0} ** 32;
        rule.class = class;
        rule.allowed = allowed;

        const src_len = Basics.math.min(source.len, 31);
        const tgt_len = Basics.math.min(target.len, 31);

        @memcpy(rule.source_type[0..src_len], source[0..src_len]);
        @memcpy(rule.target_type[0..tgt_len], target[0..tgt_len]);

        return rule;
    }

    /// Check if rule applies
    pub fn applies(self: *const TeRule, source_ctx: *const SecurityContext, target_ctx: *const SecurityContext, class: ObjectClass) bool {
        if (self.class != class) return false;

        return Basics.mem.eql(u8, &self.source_type, &source_ctx.domain) and
            Basics.mem.eql(u8, &self.target_type, &target_ctx.domain);
    }
};

pub const TypeEnforcement = struct {
    /// TE rules
    rules: [1024]?TeRule,
    /// Rule count
    rule_count: atomic.AtomicU32,
    /// Lock
    lock: sync.RwLock,

    pub fn init() TypeEnforcement {
        return .{
            .rules = [_]?TeRule{null} ** 1024,
            .rule_count = atomic.AtomicU32.init(0),
            .lock = sync.RwLock.init(),
        };
    }

    /// Add rule
    pub fn addRule(self: *TypeEnforcement, rule: TeRule) !void {
        self.lock.acquireWrite();
        defer self.lock.releaseWrite();

        const count = self.rule_count.load(.Acquire);
        if (count >= 1024) {
            return error.TooManyRules;
        }

        self.rules[count] = rule;
        _ = self.rule_count.fetchAdd(1, .Release);
    }

    /// Check access
    pub fn checkAccess(self: *TypeEnforcement, source_ctx: *const SecurityContext, target_ctx: *const SecurityContext, class: ObjectClass, requested: AccessVector) bool {
        self.lock.acquireRead();
        defer self.lock.releaseRead();

        // Find matching rule
        for (self.rules) |maybe_rule| {
            if (maybe_rule) |rule| {
                if (rule.applies(source_ctx, target_ctx, class)) {
                    // Check if requested permissions are allowed
                    const requested_bits = requested.toBits();
                    const allowed_bits = rule.allowed.toBits();

                    return (requested_bits & allowed_bits) == requested_bits;
                }
            }
        }

        // No rule found - default deny
        return false;
    }
};

// ============================================================================
// Profile-based MAC (AppArmor-style)
// ============================================================================

pub const ProfileMode = enum(u8) {
    /// Enforce policy
    ENFORCE = 0,
    /// Complain (log but don't deny)
    COMPLAIN = 1,
    /// Disabled
    DISABLED = 2,
};

pub const PathRule = struct {
    /// Path pattern (simplified - would use full glob in production)
    path: [256]u8,
    /// Path length
    path_len: usize,
    /// Access permissions
    access: AccessVector,

    pub fn init(path: []const u8, access: AccessVector) !PathRule {
        if (path.len > 255) {
            return error.PathTooLong;
        }

        var rule: PathRule = undefined;
        rule.path = [_]u8{0} ** 256;
        rule.path_len = path.len;
        rule.access = access;

        @memcpy(rule.path[0..path.len], path);

        return rule;
    }

    /// Check if path matches rule
    pub fn matches(self: *const PathRule, check_path: []const u8) bool {
        // Simplified matching - production would use glob patterns
        return Basics.mem.eql(u8, self.path[0..self.path_len], check_path);
    }
};

pub const Profile = struct {
    /// Profile name
    name: [64]u8,
    /// Name length
    name_len: usize,
    /// Mode
    mode: ProfileMode,
    /// Path rules
    path_rules: [128]?PathRule,
    /// Rule count
    rule_count: usize,
    /// Lock
    lock: sync.RwLock,

    pub fn init(name: []const u8, mode: ProfileMode) !Profile {
        if (name.len > 63) {
            return error.NameTooLong;
        }

        var profile: Profile = undefined;
        profile.name = [_]u8{0} ** 64;
        profile.name_len = name.len;
        profile.mode = mode;
        profile.path_rules = [_]?PathRule{null} ** 128;
        profile.rule_count = 0;
        profile.lock = sync.RwLock.init();

        @memcpy(profile.name[0..name.len], name);

        return profile;
    }

    /// Add path rule
    pub fn addPathRule(self: *Profile, rule: PathRule) !void {
        self.lock.acquireWrite();
        defer self.lock.releaseWrite();

        if (self.rule_count >= 128) {
            return error.TooManyRules;
        }

        self.path_rules[self.rule_count] = rule;
        self.rule_count += 1;
    }

    /// Check path access
    pub fn checkPathAccess(self: *Profile, path: []const u8, requested: AccessVector) bool {
        self.lock.acquireRead();
        defer self.lock.releaseRead();

        for (self.path_rules) |maybe_rule| {
            if (maybe_rule) |rule| {
                if (rule.matches(path)) {
                    const requested_bits = requested.toBits();
                    const allowed_bits = rule.access.toBits();

                    const allowed = (requested_bits & allowed_bits) == requested_bits;

                    if (!allowed and self.mode == .COMPLAIN) {
                        // Log but allow
                        audit.logSecurityViolation("AppArmor COMPLAIN: access denied");
                        return true;
                    }

                    return allowed;
                }
            }
        }

        // No matching rule - deny unless in complain mode
        if (self.mode == .COMPLAIN) {
            audit.logSecurityViolation("AppArmor COMPLAIN: no matching rule");
            return true;
        }

        return false;
    }
};

// ============================================================================
// Global MAC System
// ============================================================================

var global_framework: MacFramework = undefined;
var global_avc: Avc = undefined;
var global_te: TypeEnforcement = undefined;
var mac_initialized = false;

pub fn init(mode: MacMode) void {
    if (mac_initialized) return;

    global_framework = MacFramework.init(mode);
    global_avc = Avc.init();
    global_te = TypeEnforcement.init();

    mac_initialized = true;

    audit.logSecurityViolation("MAC framework initialized");
}

pub fn getFramework() *MacFramework {
    if (!mac_initialized) init(.PERMISSIVE);
    return &global_framework;
}

pub fn getAvc() *Avc {
    if (!mac_initialized) init(.PERMISSIVE);
    return &global_avc;
}

pub fn getTe() *TypeEnforcement {
    if (!mac_initialized) init(.PERMISSIVE);
    return &global_te;
}

// ============================================================================
// Tests
// ============================================================================

test "security context" {
    const ctx = SecurityContext.init();

    try Basics.testing.expect(Basics.mem.startsWith(u8, &ctx.user, "system_u"));
}

test "security context parse" {
    const ctx = try SecurityContext.parse("user_u:user_r:user_t:s0");

    try Basics.testing.expect(Basics.mem.startsWith(u8, &ctx.user, "user_u"));
    try Basics.testing.expect(Basics.mem.startsWith(u8, &ctx.role, "user_r"));
}

test "access vector" {
    var av = AccessVector{};
    av.read = true;
    av.write = true;

    const bits = av.toBits();
    const av2 = AccessVector.fromBits(bits);

    try Basics.testing.expect(av2.read);
    try Basics.testing.expect(av2.write);
    try Basics.testing.expect(!av2.execute);
}

test "avc cache" {
    var avc = Avc.init();

    const source = SecurityContext.init();
    const target = SecurityContext.init();

    var av = AccessVector{};
    av.read = true;

    const entry = AvcEntry.init(source, target, .FILE, av);
    avc.insert(entry);

    const result = avc.lookup(&source, &target, .FILE);
    try Basics.testing.expect(result != null);
    try Basics.testing.expect(result.?.read);
}

test "type enforcement" {
    var te = TypeEnforcement.init();

    var av = AccessVector{};
    av.read = true;

    const rule = TeRule.init("user_t", "file_t", .FILE, av);
    try te.addRule(rule);

    var source = SecurityContext.init();
    @memcpy(source.domain[0.."user_t".len], "user_t");

    var target = SecurityContext.init();
    @memcpy(target.domain[0.."file_t".len], "file_t");

    var req = AccessVector{};
    req.read = true;

    try Basics.testing.expect(te.checkAccess(&source, &target, .FILE, req));

    req.write = true;
    try Basics.testing.expect(!te.checkAccess(&source, &target, .FILE, req));
}

test "profile path rules" {
    var profile = try Profile.init("test_profile", .ENFORCE);

    var av = AccessVector{};
    av.read = true;

    const rule = try PathRule.init("/home/user/file.txt", av);
    try profile.addPathRule(rule);

    var req = AccessVector{};
    req.read = true;

    try Basics.testing.expect(profile.checkPathAccess("/home/user/file.txt", req));

    req.write = true;
    try Basics.testing.expect(!profile.checkPathAccess("/home/user/file.txt", req));
}

test "profile complain mode" {
    var profile = try Profile.init("complain_profile", .COMPLAIN);

    var av = AccessVector{};
    av.read = true;

    const rule = try PathRule.init("/test", av);
    try profile.addPathRule(rule);

    var req = AccessVector{};
    req.write = true; // Not allowed, but complain mode

    // Should allow anyway (complain mode)
    try Basics.testing.expect(profile.checkPathAccess("/test", req));
}

test "mac framework mode" {
    var framework = MacFramework.init(.PERMISSIVE);

    try Basics.testing.expect(framework.getMode() == .PERMISSIVE);

    try framework.setMode(.ENFORCING);
    try Basics.testing.expect(framework.getMode() == .ENFORCING);
}
