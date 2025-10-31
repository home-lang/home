# MAC - Mandatory Access Control

A comprehensive Mandatory Access Control (MAC) system inspired by SELinux and AppArmor, providing fine-grained access control for the Home programming language.

## Features

- **Security Contexts**: SELinux-style user:role:type:level labels
- **Policy Engine**: Flexible rule-based access control with priorities
- **Enforcement Modes**: Enforcing, permissive, and disabled modes
- **Capabilities**: Linux-style capability management (CAP_CHOWN, CAP_NET_BIND_SERVICE, etc.)
- **Audit Logging**: Comprehensive security event logging
- **Type Enforcement**: Domain transitions and type checking
- **MLS Support**: Multi-Level Security with Bell-LaPadula model

## Quick Start

```zig
const std = @import("std");
const mac = @import("mac");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create MAC system
    var system = try mac.createDefault(allocator);
    defer system.deinit();

    // Create security contexts
    const user_ctx = try mac.context.Contexts.user(allocator);
    defer user_ctx.deinit(allocator);

    const file_ctx = try mac.context.SecurityContext.create(
        allocator,
        "system_u",
        "object_r",
        "file_t",
        "s0"
    );
    defer file_ctx.deinit(allocator);

    // Check access
    const decision = try system.checkAccess(
        user_ctx,
        file_ctx,
        .read
    );

    if (decision.allowed) {
        std.debug.print("Access granted: {s}\n", .{decision.reason});
    } else {
        std.debug.print("Access denied: {s}\n", .{decision.reason});
    }
}
```

## Security Contexts

Security contexts follow the SELinux format: `user:role:type:level`

### Creating Contexts

```zig
const mac = @import("mac");

// Parse from string
const ctx = try mac.context.SecurityContext.parse(
    allocator,
    "user_u:user_r:httpd_t:s0"
);
defer ctx.deinit(allocator);

// Create directly
const ctx2 = try mac.context.SecurityContext.create(
    allocator,
    "system_u",
    "system_r",
    "sshd_t",
    "s0"
);
defer ctx2.deinit(allocator);

// Use pre-defined contexts
const system_ctx = try mac.context.Contexts.system(allocator);
const user_ctx = try mac.context.Contexts.user(allocator);
const guest_ctx = try mac.context.Contexts.guest(allocator);
```

### Context Components

- **User**: Security user identity (e.g., `system_u`, `user_u`, `guest_u`)
- **Role**: Security role (e.g., `system_r`, `user_r`, `object_r`)
- **Type**: Domain/type label (e.g., `httpd_t`, `user_t`, `file_t`)
- **Level**: MLS/MCS level (e.g., `s0`, `s0-s1:c0.c1023`)

## Policy Management

### Creating Policies

```zig
const mac = @import("mac");

// Using policy builder
var builder = try mac.policy.PolicyBuilder.init(allocator);
_ = try builder.allow("user_u:user_r:user_t:s0", "*:object_r:file_t:*", .read);
_ = try builder.deny("guest_u:*:*:*", "*:*:sensitive_t:*", .read);

const policy = builder.build();
defer policy.deinit();

// Add rules manually
try policy.addRule(.{
    .subject = subject_ctx,
    .object = object_ctx,
    .operation = .write,
    .decision = .allow,
    .priority = 100,
});
```

### Operations

MAC supports a comprehensive set of operations:

**File Operations:**
- `read`, `write`, `execute`, `append`, `create`, `delete`, `rename`, `chmod`, `chown`

**Network Operations:**
- `connect`, `bind`, `listen`, `accept`, `send`, `recv`

**Process Operations:**
- `fork`, `exec`, `kill`, `ptrace`, `setuid`, `setgid`

**IPC Operations:**
- `signal`, `mmap`, `shm_create`, `shm_attach`

**System Operations:**
- `mount`, `umount`, `syslog`, `reboot`

### Policy Files

Policies can be saved and loaded from files:

```zig
// Save policy
try system.policy.saveToFile("security.policy");

// Load policy
try system.loadPolicy("security.policy");
```

Policy file format:
```
# Comment
decision subject_context object_context operation [priority]

allow user_u:user_r:user_t:s0 system_u:object_r:file_t:s0 read 50
deny guest_u:guest_r:guest_t:s0 *:*:sensitive_t:* write 100
audit_allow system_u:system_r:httpd_t:s0 *:object_r:log_t:* write 75
```

## Enforcement

### Enforcement Modes

```zig
// Enforcing: Deny access and log violations
system.setMode(.enforcing);

// Permissive: Allow access but log violations
system.setMode(.permissive);

// Disabled: No enforcement
system.setMode(.disabled);
```

### Specialized Checks

```zig
const mac = @import("mac");

// File access check
const file_decision = try mac.enforcement.checkFileAccess(
    policy,
    process_ctx,
    file_ctx,
    .read
);

// Network access check
const net_decision = try mac.enforcement.checkNetworkAccess(
    policy,
    process_ctx,
    network_ctx,
    .connect
);

// Process access check
const proc_decision = try mac.enforcement.checkProcessAccess(
    policy,
    source_ctx,
    target_ctx,
    .kill
);
```

### Domain Transitions

```zig
const transition = mac.enforcement.Transition{
    .from = user_ctx,
    .to = httpd_ctx,
    .entrypoint = "/usr/bin/httpd",
};

if (try transition.isAllowed(policy)) {
    // Transition allowed
}
```

## Capabilities

MAC includes Linux-style capability management:

```zig
const mac = @import("mac");

// Create capability set
var caps = mac.capabilities.CapabilitySet.init(allocator);
defer caps.deinit();

// Add capabilities
try caps.add(.CAP_NET_BIND_SERVICE);
try caps.add(.CAP_CHOWN);

// Check capability
if (caps.has(.CAP_NET_BIND_SERVICE)) {
    // Can bind to privileged ports
}

// Process capabilities
var proc_caps = mac.capabilities.ProcessCapabilities.init(allocator);
defer proc_caps.deinit();

// Grant and use capabilities
try proc_caps.permitted.add(.CAP_CHOWN);
try proc_caps.makeEffective(.CAP_CHOWN);

// Pre-defined capability sets
var root_caps = try mac.capabilities.CapabilitySets.root(allocator);
var net_caps = try mac.capabilities.CapabilitySets.networkService(allocator);
var file_caps = try mac.capabilities.CapabilitySets.fileManager(allocator);
```

### Available Capabilities

- `CAP_CHOWN`: Change file ownership
- `CAP_DAC_OVERRIDE`: Bypass file permission checks
- `CAP_KILL`: Send signals to any process
- `CAP_SETUID`/`CAP_SETGID`: Change process UID/GID
- `CAP_NET_BIND_SERVICE`: Bind to privileged ports (<1024)
- `CAP_NET_ADMIN`: Network administration
- `CAP_SYS_ADMIN`: System administration
- `CAP_SYS_BOOT`: Reboot system
- `CAP_SYS_PTRACE`: Trace any process
- And many more...

## Audit Logging

### Basic Logging

```zig
const mac = @import("mac");

// Create audit log
var log = try mac.audit.AuditLog.init(allocator);
defer log.deinit();

// Set output file
try log.setOutputFile("/var/log/mac-audit.log");

// Automatic logging via MAC system
var system = try mac.createDefault(allocator);
// Audit automatically logs all access decisions

// Manual logging
try log.logEvent(.policy_loaded, "Custom policy loaded");
try log.logViolation("user_u:user_r:malware_t:s0", "Attempted privilege escalation");
```

### Querying Audit Logs

```zig
// Get recent entries
const recent = log.getRecent(10);
for (recent) |entry| {
    std.debug.print("{any}\n", .{entry});
}

// Get by event type
const denials = try log.getByType(allocator, .access_denied);
defer allocator.free(denials);

// Get by severity
const critical = try log.getBySeverity(allocator, .critical);
defer allocator.free(critical);
```

### Audit Entry Format

```
[timestamp] severity event_type: message subject=ctx object=ctx operation=op result=allow/deny pid=1234
```

## Advanced Features

### Multi-Level Security (MLS)

```zig
const mac = @import("mac");

// Check Bell-LaPadula model compliance
const subject_level = try mac.context.Level.parse(allocator, "s1:c0.c3");
const object_level = try mac.context.Level.parse(allocator, "s0");

// Read-down: can read objects at lower or equal level
const can_read = mac.enforcement.MLSEnforcement.checkReadDown(subject_level, object_level);

// Write-up: can write to objects at higher or equal level
const can_write = mac.enforcement.MLSEnforcement.checkWriteUp(subject_level, object_level);
```

### Wildcard Matching

Contexts support wildcard matching with `*`:

```zig
// Matches any user/role/level with user_t type
const wildcard_ctx = try mac.context.SecurityContext.create(
    allocator,
    "*",
    "*",
    "user_t",
    "*"
);
```

### Priority-based Rules

Rules with higher priority take precedence:

```zig
// High priority rule (evaluated first)
try policy.addRule(.{
    .subject = admin_ctx,
    .object = file_ctx,
    .operation = .read,
    .decision = .allow,
    .priority = 100,
});

// Lower priority default deny
try policy.addRule(.{
    .subject = guest_ctx,
    .object = file_ctx,
    .operation = .read,
    .decision = .deny,
    .priority = 50,
});
```

## Best Practices

1. **Start Permissive**: Begin with permissive mode to identify issues before enforcing
2. **Principle of Least Privilege**: Grant only necessary capabilities and permissions
3. **Use Type Enforcement**: Create distinct types for different security domains
4. **Monitor Audit Logs**: Regularly review logs for security violations
5. **Test Policies**: Thoroughly test policies before production deployment
6. **Document Contexts**: Maintain clear documentation of security contexts
7. **Version Control Policies**: Keep policy files under version control
8. **Layered Defense**: Combine MAC with other security mechanisms

## Integration Example

```zig
const std = @import("std");
const mac = @import("mac");

const WebServer = struct {
    mac_system: *mac.System,
    process_ctx: mac.SecurityContext,

    pub fn init(allocator: std.mem.Allocator) !WebServer {
        var system = try mac.createDefault(allocator);

        // Load security policy
        try system.loadPolicy("webserver.policy");

        // Create process context
        const ctx = try mac.context.Contexts.service(allocator, "httpd");

        return .{
            .mac_system = system,
            .process_ctx = ctx,
        };
    }

    pub fn handleRequest(self: *WebServer, file_path: []const u8) !void {
        // Create file context
        const file_ctx = try mac.context.SecurityContext.create(
            self.mac_system.allocator,
            "system_u",
            "object_r",
            "httpd_content_t",
            "s0"
        );
        defer file_ctx.deinit(self.mac_system.allocator);

        // Check if access is allowed
        const decision = try self.mac_system.checkAccess(
            self.process_ctx,
            file_ctx,
            .read
        );

        if (!decision.allowed) {
            return error.AccessDenied;
        }

        // Proceed with file access
        // ...
    }
};
```

## Performance Considerations

- **Policy Caching**: Rules are sorted by priority for fast lookup
- **Lock-free Reads**: Consider read-copy-update patterns for high-throughput scenarios
- **Audit Buffering**: Audit log uses ring buffer for memory efficiency
- **Context Pooling**: Reuse context objects when possible

## Platform Support

- **Unix/Linux/macOS**: Full support
- **Windows**: Limited support (no capability management)

## Error Handling

All MAC operations return error types:

```zig
const decision = try system.checkAccess(subject, object, .read) catch |err| {
    switch (err) {
        error.OutOfMemory => {
            // Handle OOM
        },
        else => {
            // Handle other errors
        },
    }
};
```

## Testing

```bash
# Run MAC tests
zig test packages/mac/src/mac.zig

# Run specific module tests
zig test packages/mac/src/context.zig
zig test packages/mac/src/policy.zig
zig test packages/mac/src/capabilities.zig
```

## References

- [SELinux Documentation](https://selinuxproject.org/)
- [AppArmor Wiki](https://gitlab.com/apparmor/apparmor/-/wikis/home)
- [Linux Capabilities](https://man7.org/linux/man-pages/man7/capabilities.7.html)
- [Bell-LaPadula Model](https://en.wikipedia.org/wiki/Bell%E2%80%93LaPadula_model)
