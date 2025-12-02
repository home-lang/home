// Home Programming Language - Integrity Measurement Architecture (IMA)
// File integrity checking and measurement for secure boot

const Basics = @import("basics");
const crypto = @import("crypto.zig");

/// IMA measurement list entry
pub const ImaEntry = struct {
    /// Template name (e.g., "ima-ng")
    template: []const u8,
    /// File path
    path: []const u8,
    /// File hash (SHA256)
    hash: [32]u8,
    /// Template hash
    template_hash: [20]u8,
};

/// Global measurement list
var measurement_list: Basics.ArrayList(ImaEntry) = undefined;
var measurement_list_initialized: bool = false;
var measurement_lock: Basics.SpinLock = .{};

/// Initialize IMA subsystem
pub fn init(allocator: Basics.Allocator) !void {
    measurement_lock.lock();
    defer measurement_lock.unlock();

    if (!measurement_list_initialized) {
        measurement_list = Basics.ArrayList(ImaEntry).init(allocator);
        measurement_list_initialized = true;
    }
}

/// Measure a file and add to IMA log
pub fn measureFile(path: []const u8, data: []const u8) !void {
    if (!measurement_list_initialized) {
        return error.ImaNotInitialized;
    }

    // Calculate file hash (SHA-256)
    const file_hash = crypto.sha256(data);

    // Create template data (ima-ng format: path + hash)
    var template_data: [256]u8 = undefined;
    var template_len: usize = 0;

    // Add path to template
    if (path.len > 200) return error.PathTooLong;
    @memcpy(template_data[template_len .. template_len + path.len], path);
    template_len += path.len;

    // Add hash to template
    @memcpy(template_data[template_len .. template_len + 32], &file_hash);
    template_len += 32;

    // Calculate template hash (SHA-1 for compatibility with Linux IMA)
    const template_hash = crypto.sha1(template_data[0..template_len]);

    // Create entry
    const entry = ImaEntry{
        .template = "ima-ng",
        .path = path,
        .hash = file_hash,
        .template_hash = template_hash,
    };

    // Add to measurement list
    measurement_lock.lock();
    defer measurement_lock.unlock();

    try measurement_list.append(entry);

    Basics.debug.print("IMA: Measured {} (hash: {x:0>2}...)\n", .{ path, file_hash[0..4] });
}

/// Get measurement count
pub fn getMeasurementCount() usize {
    if (!measurement_list_initialized) return 0;

    measurement_lock.lock();
    defer measurement_lock.unlock();

    return measurement_list.items.len;
}

/// Verify IMA measurements against policy
pub fn verifyMeasurements() !bool {
    if (!measurement_list_initialized) {
        return error.ImaNotInitialized;
    }

    measurement_lock.lock();
    defer measurement_lock.unlock();

    // Basic verification: ensure all measurements have valid hashes
    for (measurement_list.items) |entry| {
        // Check that hash is not all zeros
        var all_zero = true;
        for (entry.hash) |byte| {
            if (byte != 0) {
                all_zero = false;
                break;
            }
        }

        if (all_zero) {
            Basics.debug.print("IMA: Invalid measurement for {}\n", .{entry.path});
            return false;
        }
    }

    Basics.debug.print("IMA: Verified {} measurements\n", .{measurement_list.items.len});
    return true;
}

test "ima - basic test" {
    const testing = Basics.testing;
    const allocator = testing.allocator;

    // Initialize IMA
    try init(allocator);

    // Measure a test file
    const test_data = "Hello, IMA!";
    try measureFile("/test/file.txt", test_data);

    // Verify measurements
    try testing.expect(try verifyMeasurements());

    // Check measurement count
    try testing.expectEqual(@as(usize, 1), getMeasurementCount());
}

test "ima - multiple measurements" {
    const testing = Basics.testing;
    const allocator = testing.allocator;

    // Initialize IMA
    try init(allocator);

    // Measure multiple files
    try measureFile("/bin/init", "init binary");
    try measureFile("/bin/sh", "shell binary");
    try measureFile("/etc/config", "config file");

    // Verify all measurements
    try testing.expect(try verifyMeasurements());

    // Check we have at least 3 measurements (could have more from previous test)
    try testing.expect(getMeasurementCount() >= 3);
}
