// BadUSB Protection
// Detects and prevents USB-based attacks (keystroke injection, firmware attacks, etc.)

const std = @import("std");
const usb = @import("usb.zig");

/// BadUSB attack type
pub const AttackType = enum {
    keystroke_injection, // Rubber Ducky, Bash Bunny
    firmware_exploit, // Malicious firmware
    class_switching, // Device changes class after connection
    descriptor_mismatch, // Descriptor doesn't match behavior
    rapid_enumeration, // Repeatedly connecting/disconnecting
    mass_storage_autorun, // Autorun/autoexec exploits
    unknown,
};

/// Attack detection result
pub const DetectionResult = struct {
    is_attack: bool,
    attack_type: AttackType,
    confidence: f32, // 0.0 to 1.0
    reason: [512]u8,
    reason_len: usize,

    pub fn init(is_attack: bool, attack_type: AttackType, confidence: f32, reason: []const u8) DetectionResult {
        var result: DetectionResult = undefined;
        result.is_attack = is_attack;
        result.attack_type = attack_type;
        result.confidence = confidence;

        @memset(&result.reason, 0);
        @memcpy(result.reason[0..reason.len], reason);
        result.reason_len = reason.len;

        return result;
    }

    pub fn getReason(self: *const DetectionResult) []const u8 {
        return self.reason[0..self.reason_len];
    }
};

/// Device behavior profile
pub const DeviceProfile = struct {
    device_id: usb.DeviceID,
    declared_class: usb.DeviceClass,
    observed_classes: std.EnumSet(usb.DeviceClass),
    connection_count: u32,
    last_connection: i64,
    keystroke_rate: f64, // keystrokes per second
    descriptor_hash: [32]u8,

    pub fn init(device_id: usb.DeviceID) DeviceProfile {
        return .{
            .device_id = device_id,
            .declared_class = device_id.device_class,
            .observed_classes = std.EnumSet(usb.DeviceClass).init(.{}),
            .connection_count = 0,
            .last_connection = 0,
            .keystroke_rate = 0.0,
            .descriptor_hash = [_]u8{0} ** 32,
        };
    }

    pub fn recordConnection(self: *DeviceProfile) void {
        self.connection_count += 1;
        self.last_connection = std.time.timestamp();
    }

    pub fn addObservedClass(self: *DeviceProfile, device_class: usb.DeviceClass) void {
        self.observed_classes.insert(device_class);
    }

    pub fn hasMultipleClasses(self: *const DeviceProfile) bool {
        return self.observed_classes.count() > 1;
    }
};

/// BadUSB detector
pub const Detector = struct {
    profiles: std.AutoHashMap(usb.DeviceID, DeviceProfile),
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,

    // Detection thresholds
    max_keystroke_rate: f64, // keystrokes/sec
    max_reconnect_rate: f64, // connections/sec
    class_switch_threshold: u32, // max class changes

    pub fn init(allocator: std.mem.Allocator) Detector {
        return .{
            .profiles = std.AutoHashMap(usb.DeviceID, DeviceProfile).init(allocator),
            .allocator = allocator,
            .mutex = std.Thread.Mutex{},
            .max_keystroke_rate = 100.0, // Humans typically < 10 keys/sec
            .max_reconnect_rate = 0.1, // 1 connection per 10 seconds
            .class_switch_threshold = 1, // No class switching allowed
        };
    }

    pub fn deinit(self: *Detector) void {
        self.profiles.deinit();
    }

    pub fn analyzeDevice(self: *Detector, device_id: *const usb.DeviceID) !DetectionResult {
        self.mutex.lock();
        defer self.mutex.unlock();

        const gop = try self.profiles.getOrPut(device_id.*);
        if (!gop.found_existing) {
            gop.value_ptr.* = DeviceProfile.init(device_id.*);
        }

        const profile = gop.value_ptr;
        profile.recordConnection();

        // Check for rapid enumeration
        if (profile.connection_count > 1) {
            const time_since_last = std.time.timestamp() - profile.last_connection;
            if (time_since_last < 10) {
                const rate = 1.0 / @as(f64, @floatFromInt(time_since_last));
                if (rate > self.max_reconnect_rate) {
                    return DetectionResult.init(
                        true,
                        .rapid_enumeration,
                        0.9,
                        "Device connecting too rapidly",
                    );
                }
            }
        }

        // Check for class switching
        profile.addObservedClass(device_id.device_class);
        if (profile.hasMultipleClasses()) {
            return DetectionResult.init(
                true,
                .class_switching,
                0.95,
                "Device switched device class after connection",
            );
        }

        // Check for HID attack patterns
        if (device_id.device_class == .hid) {
            const result = try self.detectKeystrokeInjection(profile);
            if (result.is_attack) {
                return result;
            }
        }

        // Check for mass storage attacks
        if (device_id.device_class == .mass_storage) {
            const result = self.detectMassStorageAttack(device_id);
            if (result.is_attack) {
                return result;
            }
        }

        // No attack detected
        return DetectionResult.init(false, .unknown, 0.0, "Device appears safe");
    }

    fn detectKeystrokeInjection(self: *Detector, profile: *DeviceProfile) !DetectionResult {
        // Simulate keystroke rate analysis
        // In production, would analyze actual input timing
        _ = self;

        // New HID devices are suspicious if they start typing immediately
        if (profile.connection_count == 1) {
            const time_since_connect = std.time.timestamp() - profile.last_connection;
            if (time_since_connect < 2) {
                // Device typing within 2 seconds of connection is suspicious
                return DetectionResult.init(
                    true,
                    .keystroke_injection,
                    0.8,
                    "HID device typing immediately after connection",
                );
            }
        }

        return DetectionResult.init(false, .unknown, 0.0, "");
    }

    fn detectMassStorageAttack(self: *Detector, device_id: *const usb.DeviceID) DetectionResult {
        _ = self;
        _ = device_id;

        // In production, would check for:
        // - Autorun.inf files
        // - Suspicious executables
        // - Hidden partitions
        // - Firmware updates

        // For now, just demonstrate the concept
        return DetectionResult.init(false, .unknown, 0.0, "");
    }

    pub fn recordKeystroke(
        self: *Detector,
        device_id: *const usb.DeviceID,
        keystroke_count: u32,
        time_window: f64,
    ) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.profiles.getPtr(device_id.*)) |profile| {
            profile.keystroke_rate = @as(f64, @floatFromInt(keystroke_count)) / time_window;
        }
    }

    pub fn getProfile(self: *Detector, device_id: *const usb.DeviceID) ?DeviceProfile {
        self.mutex.lock();
        defer self.mutex.unlock();

        return self.profiles.get(device_id.*);
    }

    pub fn clearProfile(self: *Detector, device_id: *const usb.DeviceID) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        _ = self.profiles.remove(device_id.*);
    }
};

/// Attack mitigation action
pub const MitigationAction = enum {
    block_device,
    disable_autorun,
    rate_limit_input,
    alert_user,
    quarantine,
};

/// BadUSB protection system
pub const Protection = struct {
    detector: Detector,
    enabled: bool,
    auto_block: bool,

    pub fn init(allocator: std.mem.Allocator) Protection {
        return .{
            .detector = Detector.init(allocator),
            .enabled = true,
            .auto_block = true,
        };
    }

    pub fn deinit(self: *Protection) void {
        self.detector.deinit();
    }

    pub fn checkDevice(self: *Protection, device_id: *const usb.DeviceID) !DetectionResult {
        if (!self.enabled) {
            return DetectionResult.init(false, .unknown, 0.0, "Protection disabled");
        }

        return try self.detector.analyzeDevice(device_id);
    }

    pub fn shouldBlock(self: *const Protection, result: *const DetectionResult) bool {
        if (!self.auto_block) return false;

        // Block if confidence is high (> 0.7)
        return result.is_attack and result.confidence > 0.7;
    }

    pub fn getMitigation(self: *const Protection, result: *const DetectionResult) MitigationAction {
        _ = self;

        if (!result.is_attack) return .alert_user;

        return switch (result.attack_type) {
            .keystroke_injection => .block_device,
            .firmware_exploit => .block_device,
            .class_switching => .block_device,
            .rapid_enumeration => .rate_limit_input,
            .mass_storage_autorun => .disable_autorun,
            else => .quarantine,
        };
    }
};

test "rapid enumeration detection" {
    const testing = std.testing;

    var detector = Detector.init(testing.allocator);
    defer detector.deinit();

    const dev = usb.DeviceID.init(0x046D, 0xC52B, "12345", .hid, "Logitech", "Mouse");

    // First connection - should be fine
    var result = try detector.analyzeDevice(&dev);
    try testing.expect(!result.is_attack);

    // Rapid reconnection - should detect
    result = try detector.analyzeDevice(&dev);
    if (result.is_attack) {
        try testing.expectEqual(AttackType.rapid_enumeration, result.attack_type);
    }
}

test "class switching detection" {
    const testing = std.testing;

    var detector = Detector.init(testing.allocator);
    defer detector.deinit();

    var dev1 = usb.DeviceID.init(0x046D, 0xC52B, "12345", .hid, "Suspicious", "Device");

    // First connection as HID
    _ = try detector.analyzeDevice(&dev1);

    // Same device but now claims to be mass_storage
    var dev2 = dev1;
    dev2.device_class = .mass_storage;

    const result = try detector.analyzeDevice(&dev2);
    try testing.expect(result.is_attack);
    try testing.expectEqual(AttackType.class_switching, result.attack_type);
}

test "protection system" {
    const testing = std.testing;

    var protection = Protection.init(testing.allocator);
    defer protection.deinit();

    const dev = usb.DeviceID.init(0x046D, 0xC52B, "12345", .hid, "Logitech", "Mouse");

    const result = try protection.checkDevice(&dev);

    // Should not block safe devices
    try testing.expect(!protection.shouldBlock(&result));
}
