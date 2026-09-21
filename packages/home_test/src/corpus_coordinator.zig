//! Owned preparation for Bun's production CI phase ordering.
//!
//! This module prepares primary selection and vendor specifications. It does
//! not run setup, services, or tests; later coordinator phases consume this
//! exact plan so they cannot reinterpret CLI or environment state.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const platform = @import("corpus_platform.zig");
const runner = @import("corpus_runner.zig");
const selection = @import("corpus_selection.zig");
const vendor_module = @import("corpus_vendor.zig");

pub const Options = struct {
    selection: selection.Options = .{},
    expected_platform: platform.Expected = .{},
    asan_step: bool = false,
    include_vendors: bool = true,
};

pub const Plan = struct {
    arena: std.heap.ArenaAllocator,
    project_root: []const u8,
    primary: runner.PrimaryPlan,
    vendors: []const vendor_module.Vendor,
    vendor_filters: []const []const u8,

    pub fn deinit(self: *Plan) void {
        self.primary.deinit();
        self.arena.deinit();
        self.* = undefined;
    }
};

fn cloneStrings(allocator: Allocator, values: []const []const u8) ![]const []const u8 {
    const result = try allocator.alloc([]const u8, values.len);
    for (values, result) |value, *owned| owned.* = try allocator.dupe(u8, value);
    return result;
}

/// Prepare the host-checked primary selection and sorted/sharded vendor list.
/// `environment` is read only for Bun's exact CI spelling; all returned values
/// are owned by Plan and survive changes to the caller's environment or CLI.
pub fn prepare(
    allocator: Allocator,
    io: Io,
    project_root: []const u8,
    executable: []const u8,
    environment: *const std.process.Environ.Map,
    options: Options,
) !Plan {
    if (options.selection.max_shards == 0 or options.selection.shard >= options.selection.max_shards) return error.InvalidCorpusShard;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const owned = arena.allocator();
    const root = try Io.Dir.cwd().realPathFileAlloc(io, project_root, owned);
    const corpus_root = try std.fs.path.join(owned, &.{ root, "test" });
    const upstream_path = try std.fs.path.join(owned, &.{ corpus_root, "UPSTREAM_EXPECTATIONS.txt" });
    const home_path = try std.fs.path.join(owned, &.{ corpus_root, "expectations.txt" });
    const upstream = try Io.Dir.cwd().readFileAlloc(io, upstream_path, owned, .limited(2 * 1024 * 1024));
    const home = try Io.Dir.cwd().readFileAlloc(io, home_path, owned, .limited(2 * 1024 * 1024));
    var primary = try runner.prepareGatePlan(io, allocator, corpus_root, .{
        .context = .{
            .executable = executable,
            .os = "pending-native-detection",
            .arch = "pending-native-detection",
            .is_ci = platform.isCI(environment),
        },
        .upstream_expectations = upstream,
        .home_expectations = home,
        .options = options.selection,
        .detect_platform = true,
        .expected_platform = options.expected_platform,
        .asan_step = options.asan_step,
    });
    errdefer primary.deinit();

    var vendors: []const vendor_module.Vendor = &.{};
    if (options.include_vendors) {
        const manifest_path = try std.fs.path.join(owned, &.{ corpus_root, "vendor.json" });
        const source = try Io.Dir.cwd().readFileAlloc(io, manifest_path, owned, .limited(1024 * 1024));
        const parsed = try std.json.parseFromSliceLeaky([]vendor_module.Vendor, owned, source, .{});
        std.mem.sort(vendor_module.Vendor, parsed, {}, struct {
            fn less(_: void, a: vendor_module.Vendor, b: vendor_module.Vendor) bool {
                const package_order = std.mem.order(u8, a.package, b.package);
                return package_order == .lt or (package_order == .eq and std.mem.lessThan(u8, a.tag, b.tag));
            }
        }.less);
        var selected: std.ArrayList(vendor_module.Vendor) = .empty;
        for (parsed, 0..) |vendor, index| {
            if (options.selection.max_shards == 1 or index % options.selection.max_shards == options.selection.shard) try selected.append(owned, vendor);
        }
        vendors = try selected.toOwnedSlice(owned);
    }
    return .{
        .arena = arena,
        .project_root = root,
        .primary = primary,
        .vendors = vendors,
        .vendor_filters = try cloneStrings(owned, options.selection.filters),
    };
}

test "native corpus coordinator preparation owns primary selection and pinned vendor order" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "test");
    try tmp.dir.writeFile(io, .{ .sub_path = "test/BUN_TRACKED_FILES.txt", .data = "excluded.test.js\nfirst.test.js\nselected.test.js\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "test/UPSTREAM_EXPECTATIONS.txt", .data = "test/excluded.test.js [ FAIL ]\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "test/expectations.txt", .data = "test/excluded.test.js [ FAIL ]\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "test/vendor.json", .data =
        \\[
        \\  {"package":"zeta","repository":"z","tag":"2"},
        \\  {"package":"alpha","repository":"a","tag":"1"},
        \\  {"package":"middle","repository":"m","tag":"1"}
        \\]
    });
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("CI", "true");
    const executable = try allocator.dupe(u8, "home");
    var plan = try prepare(allocator, io, root, executable, &env, .{ .selection = .{ .shard = 1, .max_shards = 2 } });
    defer plan.deinit();
    allocator.free(executable);
    try env.put("CI", "false");
    try std.testing.expect(plan.primary.policy.?.context.is_ci);
    try std.testing.expectEqual(@as(usize, 3), plan.primary.inventory.len);
    try std.testing.expectEqualSlices(usize, &.{2}, plan.primary.selected_indices);
    try std.testing.expectEqual(@as(usize, 1), plan.vendors.len);
    try std.testing.expectEqualStrings("middle", plan.vendors[0].package);
}
