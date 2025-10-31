# USB Security Package

Enterprise-grade USB security with device authentication, port control, activity monitoring, and BadUSB protection for Home OS.

## Overview

The `usb` package provides comprehensive USB security features:

- **Device Authentication**: Whitelist/blacklist management for USB devices
- **Port Control**: Enable/disable USB ports and enforce device class policies
- **Activity Monitoring**: Track connections, disconnections, and data transfers
- **BadUSB Protection**: Detect and prevent USB-based attacks
- **Policy Engine**: Class-based restrictions and security policies
- **Transfer Statistics**: Monitor data transfer rates and detect anomalies

## Quick Start

### Basic Device Authentication

```zig
const std = @import("std");
const usb = @import("usb");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create authenticator in whitelist mode
    var auth = usb.auth.Authenticator.init(allocator, .whitelist);
    defer auth.deinit();

    // Define trusted device
    const mouse = usb.DeviceID.init(
        0x046D,     // Logitech vendor ID
        0xC52B,     // Product ID
        "12345",    // Serial number
        .hid,       // Device class
        "Logitech",
        "USB Receiver",
    );

    // Add to whitelist
    try auth.addToWhitelist(mouse);

    // Check if device is authorized
    if (auth.isAuthorized(&mouse)) {
        std.debug.print("Device authorized: {}\n", .{mouse});
    } else {
        std.debug.print("Device denied\n", .{});
    }
}
```

### Port Control and Policies

```zig
const std = @import("std");
const usb = @import("usb");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create policy engine
    var engine = usb.policy.PolicyEngine.init(allocator, .enforcing);
    defer engine.deinit();

    // Add USB ports
    try engine.addPort(usb.policy.Port.init(1));
    try engine.addPort(usb.policy.Port.init(2));

    // Disable port 2 (e.g., external port)
    try engine.disablePort(2);

    // Create policy: deny all mass storage devices
    const no_usb_drives = usb.policy.ClassPolicy.init(.mass_storage, .deny);
    try engine.addClassPolicy(no_usb_drives);

    // Create policy: max 2 HID devices
    const hid_limit = usb.policy.ClassPolicy.init(.hid, .allow).withMaxDevices(2);
    try engine.addClassPolicy(hid_limit);

    // Check if device would be allowed
    const usb_drive = usb.DeviceID.init(
        0x0781,
        0x5567,
        "ABC123",
        .mass_storage,
        "SanDisk",
        "Cruzer Blade",
    );

    const action = try engine.checkDevicePolicy(&usb_drive);
    std.debug.print("USB drive policy action: {}\n", .{action});
}
```

### Activity Monitoring

```zig
const std = @import("std");
const usb = @import("usb");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create monitor (store last 1000 events)
    var monitor = usb.monitor.Monitor.init(allocator, 1000);
    defer monitor.deinit();

    const device = usb.DeviceID.init(
        0x0781,
        0x5567,
        "ABC123",
        .mass_storage,
        "SanDisk",
        "USB Drive",
    );

    // Start monitoring session
    try monitor.startSession(device);

    // Simulate data transfers
    try monitor.recordTransfer(&device, true, 1024 * 1024);  // 1 MB read
    try monitor.recordTransfer(&device, false, 2048 * 1024); // 2 MB write

    // Log custom event
    const event = usb.monitor.Event.init(
        .data_transfer_completed,
        device,
        1,
        "Transferred 3 MB",
    );
    try monitor.logEvent(event);

    // Check statistics
    std.debug.print("Total events: {}\n", .{monitor.getEventCount()});
    std.debug.print("Active sessions: {}\n", .{monitor.getActiveSessionCount()});

    // End session
    try monitor.endSession(&device);
}
```

### BadUSB Protection

```zig
const std = @import("std");
const usb = @import("usb");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create protection system
    var protection = usb.badusb.Protection.init(allocator);
    defer protection.deinit();

    // Suspicious device (appears to be keyboard)
    const device = usb.DeviceID.init(
        0x1234,
        0x5678,
        "BADUSB",
        .hid,
        "Unknown",
        "Keyboard",
    );

    // Analyze device for attacks
    const result = try protection.checkDevice(&device);

    if (result.is_attack) {
        std.debug.print("⚠️  Attack detected: {}\n", .{result.attack_type});
        std.debug.print("   Confidence: {d:.1}%\n", .{result.confidence * 100});
        std.debug.print("   Reason: {s}\n", .{result.getReason()});

        // Should we block?
        if (protection.shouldBlock(&result)) {
            std.debug.print("   Action: BLOCKED\n", .{});
        }

        // Get mitigation action
        const mitigation = protection.getMitigation(&result);
        std.debug.print("   Mitigation: {}\n", .{mitigation});
    } else {
        std.debug.print("✓ Device appears safe\n", .{});
    }
}
```

## Features

### Device Authentication

Control which USB devices can connect to your system:

```zig
var auth = usb.auth.Authenticator.init(allocator, .whitelist);
defer auth.deinit();

// Add trusted devices
try auth.addToWhitelist(mouse);
try auth.addToWhitelist(keyboard);

// Block specific devices
try auth.addToBlacklist(suspicious_device);

// Check authorization
if (auth.isAuthorized(&device)) {
    // Allow device
} else {
    // Block device
}

// Switch modes dynamically
auth.setMode(.deny_all); // Maximum security
```

**Authorization Modes:**

- `allow_all`: Allow all devices (insecure, for testing)
- `deny_all`: Deny all devices (maximum security)
- `whitelist`: Only allow explicitly whitelisted devices
- `blacklist`: Allow all except blacklisted devices

### Port Control

Manage USB ports and enforce device class policies:

```zig
var engine = usb.policy.PolicyEngine.init(allocator, .enforcing);
defer engine.deinit();

// Port management
try engine.addPort(usb.policy.Port.init(1));
try engine.disablePort(1);  // Disable external ports
try engine.enablePort(1);   // Re-enable when needed

// Class-based policies
const deny_storage = usb.policy.ClassPolicy.init(.mass_storage, .deny);
try engine.addClassPolicy(deny_storage);

// Limit number of devices
const max_keyboards = usb.policy.ClassPolicy.init(.hid, .allow)
    .withMaxDevices(2)
    .withAuthRequired();
try engine.addClassPolicy(max_keyboards);

// Check device against policies
const action = try engine.checkDevicePolicy(&device);
```

**Policy Actions:**

- `allow`: Device is permitted
- `deny`: Device is blocked
- `prompt`: Ask user for authorization
- `quarantine`: Allow but monitor closely

**Enforcement Levels:**

- `permissive`: Log violations but allow
- `enforcing`: Block violations
- `paranoid`: Strict enforcement with auditing

### Activity Monitoring

Track USB activity and detect anomalies:

```zig
var monitor = usb.monitor.Monitor.init(allocator, 1000);
defer monitor.deinit();

// Monitor device sessions
try monitor.startSession(device);
try monitor.recordTransfer(&device, true, bytes_read);
try monitor.recordTransfer(&device, false, bytes_written);
try monitor.endSession(&device);

// Log events
const event = usb.monitor.Event.init(
    .device_connected,
    device,
    port_number,
    "User plugged in USB drive",
);
try monitor.logEvent(event);

// Get statistics
const event_count = monitor.getEventCount();
const active_sessions = monitor.getActiveSessionCount();
const suspicious_count = monitor.getSuspiciousDeviceCount();
```

**Event Types:**

- `device_connected`: Device plugged in
- `device_disconnected`: Device removed
- `device_authorized`: Device passed authentication
- `device_denied`: Device blocked
- `data_transfer_started`: Transfer initiated
- `data_transfer_completed`: Transfer finished
- `suspicious_activity`: Anomaly detected
- `policy_violation`: Policy rule broken

**Transfer Statistics:**

```zig
// Access session statistics
if (monitor.sessions.get(device)) |session| {
    const total_bytes = session.stats.getTotalBytes();
    const total_ops = session.stats.getTotalOperations();
    const throughput = session.stats.getReadThroughput();
    const duration = session.getDuration();
}
```

### BadUSB Protection

Detect and prevent USB-based attacks:

```zig
var protection = usb.badusb.Protection.init(allocator);
defer protection.deinit();

// Analyze device
const result = try protection.checkDevice(&device);

if (result.is_attack) {
    // Attack detected
    const should_block = protection.shouldBlock(&result);
    const mitigation = protection.getMitigation(&result);

    // Take action based on mitigation strategy
    switch (mitigation) {
        .block_device => // Disconnect device
        .disable_autorun => // Mount with noexec
        .rate_limit_input => // Throttle input
        .alert_user => // Show warning
        .quarantine => // Sandbox device
    }
}
```

**Attack Types Detected:**

- `keystroke_injection`: Rubber Ducky, Bash Bunny attacks
- `firmware_exploit`: Malicious firmware
- `class_switching`: Device changes class after connection
- `descriptor_mismatch`: Descriptor doesn't match behavior
- `rapid_enumeration`: Repeated connection/disconnection
- `mass_storage_autorun`: Autorun/autoexec exploits

**Detection Heuristics:**

1. **Rapid Enumeration**: Device connecting > 0.1 times/sec
2. **Class Switching**: Device changes device class
3. **Keystroke Injection**: HID device typing within 2 sec of connection
4. **Suspicious Timing**: Immediate activity after connection

## Complete Example

Integrated USB security system:

```zig
const std = @import("std");
const usb = @import("usb");

pub const SecureUSB = struct {
    allocator: std.mem.Allocator,
    auth: usb.auth.Authenticator,
    policy: usb.policy.PolicyEngine,
    monitor: usb.monitor.Monitor,
    protection: usb.badusb.Protection,

    pub fn init(allocator: std.mem.Allocator) !SecureUSB {
        var secure: SecureUSB = undefined;
        secure.allocator = allocator;
        secure.auth = usb.auth.Authenticator.init(allocator, .whitelist);
        secure.policy = usb.policy.PolicyEngine.init(allocator, .enforcing);
        secure.monitor = usb.monitor.Monitor.init(allocator, 10000);
        secure.protection = usb.badusb.Protection.init(allocator);

        // Setup default policies
        const deny_storage = usb.policy.ClassPolicy.init(.mass_storage, .deny);
        try secure.policy.addClassPolicy(deny_storage);

        const limit_hid = usb.policy.ClassPolicy.init(.hid, .allow).withMaxDevices(3);
        try secure.policy.addClassPolicy(limit_hid);

        return secure;
    }

    pub fn deinit(self: *SecureUSB) void {
        self.auth.deinit();
        self.policy.deinit();
        self.monitor.deinit();
        self.protection.deinit();
    }

    pub fn handleDeviceConnection(
        self: *SecureUSB,
        device: *const usb.DeviceID,
        port_number: u8,
    ) !bool {
        // 1. Check for BadUSB attacks
        const attack_result = try self.protection.checkDevice(device);
        if (self.protection.shouldBlock(&attack_result)) {
            std.debug.print("⚠️  BadUSB attack blocked: {s}\n", .{attack_result.getReason()});
            return false;
        }

        // 2. Check device authentication
        if (!self.auth.isAuthorized(device)) {
            std.debug.print("⚠️  Device not authorized\n", .{});
            return false;
        }

        // 3. Check policy
        const policy_action = try self.policy.checkDevicePolicy(device);
        if (policy_action == .deny) {
            std.debug.print("⚠️  Device denied by policy\n", .{});
            return false;
        }

        // 4. Check port status
        if (self.policy.getPortByNumber(port_number)) |port| {
            if (port.status == .disabled) {
                std.debug.print("⚠️  Port is disabled\n", .{});
                return false;
            }
        }

        // 5. Start monitoring
        try self.monitor.startSession(device.*);
        try self.policy.registerDevice(device, port_number);

        // 6. Log event
        const event = usb.monitor.Event.init(
            .device_authorized,
            device.*,
            port_number,
            "Device connected and authorized",
        );
        try self.monitor.logEvent(event);

        std.debug.print("✓ Device authorized: {}\n", .{device.*});
        return true;
    }

    pub fn handleDeviceDisconnection(
        self: *SecureUSB,
        device: *const usb.DeviceID,
        port_number: u8,
    ) !void {
        try self.monitor.endSession(device);
        try self.policy.unregisterDevice(device, port_number);

        const event = usb.monitor.Event.init(
            .device_disconnected,
            device.*,
            port_number,
            "Device disconnected",
        );
        try self.monitor.logEvent(event);
    }
};

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var secure_usb = try SecureUSB.init(allocator);
    defer secure_usb.deinit();

    // Add trusted devices
    const mouse = usb.DeviceID.init(0x046D, 0xC52B, "12345", .hid, "Logitech", "Mouse");
    try secure_usb.auth.addToWhitelist(mouse);

    // Simulate device connection
    const authorized = try secure_usb.handleDeviceConnection(&mouse, 1);

    if (authorized) {
        std.debug.print("Device is now active\n", .{});

        // Simulate disconnection
        try secure_usb.handleDeviceDisconnection(&mouse, 1);
    }
}
```

## Device Classes

USB device classes supported:

| Class | Code | Description | Typical Use |
|-------|------|-------------|-------------|
| HID | 0x03 | Human Interface Device | Keyboard, mouse, gamepad |
| Mass Storage | 0x08 | Storage devices | USB drives, external HDDs |
| Hub | 0x09 | USB hub | Port expansion |
| Smart Card | 0x0B | Smart card reader | Authentication tokens |
| Video | 0x0E | Video devices | Webcams |
| Audio | 0x01 | Audio devices | Headsets, speakers |
| Printer | 0x07 | Printers | USB printers |
| Wireless | 0xE0 | Wireless controllers | Bluetooth, Wi-Fi |

## Best Practices

### Security

1. **Use whitelist mode**: Only allow known, trusted devices
2. **Disable unused ports**: Reduce attack surface
3. **Enable BadUSB protection**: Detect keystroke injection and firmware attacks
4. **Monitor activity**: Review logs regularly for suspicious patterns
5. **Limit device classes**: Block mass storage if not needed
6. **Require authentication**: Use `.withAuthRequired()` for sensitive device classes
7. **Set device limits**: Prevent USB hub attacks with `.withMaxDevices()`

### Performance

1. **Limit event history**: Use reasonable `max_events` (1000-10000)
2. **Clean up sessions**: Call `endSession()` when devices disconnect
3. **Batch policy checks**: Check policies before enumeration
4. **Use appropriate enforcement**: `permissive` for dev, `enforcing` for production

### Deployment

1. **Start permissive**: Use `.permissive` mode initially, monitor violations
2. **Build whitelist**: Collect trusted device IDs over time
3. **Gradual enforcement**: Switch to `.enforcing` after whitelist is complete
4. **User education**: Explain why devices are blocked
5. **Audit regularly**: Review monitoring logs and statistics
6. **Update policies**: Adjust as new devices are approved

## Security Considerations

### BadUSB Attacks

BadUSB attacks exploit the trust placed in USB devices by modifying firmware or impersonating device classes:

- **Rubber Ducky**: Appears as keyboard, types malicious commands
- **Bash Bunny**: Multi-stage attacks with class switching
- **USBKill**: Hardware attack that fries USB controllers
- **Firmware exploits**: Malicious firmware in legitimate devices

**Protection Mechanisms:**

1. Class switching detection
2. Rapid enumeration detection
3. Keystroke rate analysis
4. Descriptor verification
5. Behavioral analysis

### Data Exfiltration

Mass storage devices can be used to exfiltrate sensitive data:

**Mitigation:**

1. Block mass storage class entirely (if possible)
2. Monitor transfer rates and volumes
3. Require authentication for storage devices
4. Use quarantine mode for untrusted devices
5. Integrate with DLP (Data Loss Prevention) systems

### Physical Security

USB security is part of a defense-in-depth strategy:

1. **Physical access controls**: Lock server rooms
2. **Port sealing**: Physically disable external ports
3. **Visual inspection**: Check for suspicious devices
4. **Endpoint detection**: Combine with antivirus/EDR
5. **Network segmentation**: Isolate systems with USB access

## License

Part of the Home programming language project.
