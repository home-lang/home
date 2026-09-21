//! Owned preparation for Bun's production CI phase ordering.
//!
//! This module prepares primary selection and vendor specifications. It does
//! not run setup, services, or tests; later coordinator phases consume this
//! exact plan so they cannot reinterpret CLI or environment state.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const platform = @import("corpus_platform.zig");
const docker_module = @import("corpus_docker.zig");
const journal_module = @import("corpus_journal.zig");
const launch = @import("corpus_launch.zig");
const remap_module = @import("corpus_remap.zig");
const runner = @import("corpus_runner.zig");
const selection = @import("corpus_selection.zig");
const setup_module = @import("corpus_setup.zig");
const vendor_module = @import("corpus_vendor.zig");
const vendor_prepare = @import("corpus_vendor_prepare.zig");

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

pub const RunOptions = struct {
    report_directory: ?[]const u8 = null,
    on_file: ?*const fn (runner.FileExecution) anyerror!void = null,
};

pub const Summary = struct {
    journal: journal_module.Journal,
    setup_succeeded: bool = false,
    primary_started: bool = false,
    primary_expected: usize = 0,
    primary_files: usize = 0,
    primary_passed: usize = 0,
    primary_failed: usize = 0,
    primary_skipped: usize = 0,
    primary_todo: usize = 0,
    primary_unsupported: usize = 0,
    primary_failed_files: usize = 0,
    vendor_expected: usize = 0,
    vendor_files: usize = 0,
    vendor_passed: usize = 0,
    vendor_failed: usize = 0,
    vendor_skipped: usize = 0,
    vendor_todo: usize = 0,
    vendor_unsupported: usize = 0,
    vendor_failed_files: usize = 0,
    vendor_checkouts_failed: usize = 0,
    vendor_discoveries_failed: usize = 0,
    vendor_preparations_failed: usize = 0,
    phase_errors: usize = 0,
    remap_ready: bool = false,
    docker_ready: bool = false,

    pub fn successful(self: Summary) bool {
        return self.setup_succeeded and self.primary_started and self.primary_files == self.primary_expected and self.primary_failed == 0 and self.primary_unsupported == 0 and self.primary_failed_files == 0 and self.vendor_files == self.vendor_expected and self.vendor_checkouts_failed == 0 and self.vendor_discoveries_failed == 0 and self.vendor_preparations_failed == 0 and self.vendor_failed == 0 and self.vendor_unsupported == 0 and self.vendor_failed_files == 0 and self.phase_errors == 0;
    }

    pub fn deinit(self: *Summary) void {
        self.journal.deinit();
        self.* = undefined;
    }
};

const PreparedVendor = struct {
    allocator: Allocator,
    plan: *runner.VendorPlan,
    fn deinit(self: *PreparedVendor) void {
        self.plan.deinit();
        self.allocator.destroy(self.plan);
    }
};

fn childReportPath(allocator: Allocator, parent: []const u8, label: []const u8, package: ?[]const u8) ![]u8 {
    return if (package) |name|
        std.fmt.allocPrint(allocator, "{s}{c}{s}-{s}", .{ parent, std.fs.path.sep, label, name })
    else
        std.fmt.allocPrint(allocator, "{s}{c}{s}", .{ parent, std.fs.path.sep, label });
}

fn servicesFor(docker: ?*docker_module.Coordinator, remap: ?*remap_module.Remap) launch.Services {
    return .{
        .remap_port = if (remap) |service| service.port() else null,
        .docker_socket = if (docker) |service| service.services().docker_socket else null,
    };
}

fn finishCoordinator(summary: *Summary) !void {
    try summary.journal.finish(.{
        .files = summary.primary_files + summary.vendor_files,
        .passed = summary.primary_passed + summary.vendor_passed,
        .failed = summary.primary_failed + summary.vendor_failed,
        .skipped = summary.primary_skipped + summary.vendor_skipped,
        .todo = summary.primary_todo + summary.vendor_todo,
        .unsupported = summary.primary_unsupported + summary.vendor_unsupported,
        .failed_files = summary.primary_failed_files + summary.vendor_failed_files,
        .setup_succeeded = summary.setup_succeeded,
        .primary_started = summary.primary_started,
        .primary_expected = summary.primary_expected,
        .vendor_expected = summary.vendor_expected,
        .vendor_checkouts_failed = summary.vendor_checkouts_failed,
        .vendor_discoveries_failed = summary.vendor_discoveries_failed,
        .vendor_preparations_failed = summary.vendor_preparations_failed,
        .phase_errors = summary.phase_errors,
        .remap_ready = summary.remap_ready,
        .docker_ready = summary.docker_ready,
        .successful = summary.successful(),
    });
}

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

/// Execute the pinned CI ordering from an immutable plan. Docker starts before
/// vendor checkout/discovery. Root/test install success gates remap and primary
/// execution, while prepared vendors still install/build and run afterward.
pub fn run(allocator: Allocator, io: Io, plan: *Plan, options: RunOptions) !Summary {
    const policy = plan.primary.policy orelse return error.CoordinatorSelectionRequired;
    const report = options.report_directory;
    var summary = Summary{ .journal = try journal_module.Journal.createForPurpose(allocator, io, report, plan.project_root, .coordinator) };
    errdefer summary.deinit();
    summary.primary_expected = plan.primary.range_end - plan.primary.range_start;
    std.debug.print("[home-bun-coordinator] results: {s}\n", .{summary.journal.directory});
    try summary.journal.append(.{
        .event = "coordinator_plan",
        .contract = "bun-4982b91e-run-tests",
        .project_root = plan.project_root,
        .primary_inventory = plan.primary.inventory,
        .primary_selected_indices = plan.primary.selected_indices,
        .primary_range_start = plan.primary.range_start,
        .primary_range_end = plan.primary.range_end,
        .vendors = plan.vendors,
        .vendor_filters = plan.vendor_filters,
        .context = policy.context,
        .expected_platform = policy.expected_platform,
    });

    const host = platform.Host{
        .os = policy.context.os,
        .arch = policy.context.arch,
        .distro = policy.context.distro,
        .distro_version = policy.context.distro_version,
        .abi = policy.context.abi,
        .abi_version = policy.context.abi_version,
    };
    var docker: ?docker_module.Coordinator = null;
    defer if (docker) |*service| service.deinit();
    if (docker_module.applicable(host, policy.context.is_ci)) {
        var docker_tests: std.ArrayList([]const u8) = .empty;
        defer docker_tests.deinit(allocator);
        for (plan.primary.selected_indices[plan.primary.range_start..plan.primary.range_end]) |index| try docker_tests.append(allocator, plan.primary.inventory[index]);
        const docker_report = try childReportPath(allocator, summary.journal.directory, "docker", null);
        defer allocator.free(docker_report);
        docker = try docker_module.Coordinator.start(allocator, io, plan.project_root, docker_tests.items, docker_report);
        summary.docker_ready = docker.?.services().docker_socket != null;
        try summary.journal.append(.{ .event = "coordinator_phase", .phase = "docker", .journal = docker.?.journal.directory, .available = docker.?.docker_available, .ready = summary.docker_ready, .fallback = if (summary.docker_ready) "coordinator" else "direct-compose" });
    } else try summary.journal.append(.{ .event = "coordinator_phase", .phase = "docker", .applicable = false, .ready = false });

    var prepared: std.ArrayList(PreparedVendor) = .empty;
    defer {
        for (prepared.items) |*vendor| vendor.deinit();
        prepared.deinit(allocator);
    }
    for (plan.vendors) |vendor| {
        const checkout_report = try childReportPath(allocator, summary.journal.directory, "vendor-checkout", vendor.package);
        defer allocator.free(checkout_report);
        var checkout: ?vendor_prepare.Summary = vendor_prepare.prepareWithOptions(allocator, io, plan.project_root, vendor, .{
            .phase = .checkout,
            .services = servicesFor(if (docker) |*value| value else null, null),
            .report_directory = checkout_report,
        }) catch |err| blk: {
            summary.phase_errors += 1;
            summary.vendor_checkouts_failed += 1;
            try summary.journal.append(.{ .event = "coordinator_phase", .phase = "vendor_checkout", .vendor = vendor.package, .journal = checkout_report, .error_name = @errorName(err), .successful = false });
            break :blk null;
        };
        defer if (checkout) |*result| result.deinit();
        if (checkout == null) continue;
        try summary.journal.append(.{
            .event = "coordinator_phase",
            .phase = "vendor_checkout",
            .vendor = vendor.package,
            .journal = checkout.?.journal.directory,
            .successful = checkout.?.successful(),
            .revision = checkout.?.revision,
            .completed = checkout.?.completed,
            .failed = checkout.?.failed,
        });
        if (!checkout.?.successful()) {
            summary.vendor_checkouts_failed += 1;
            continue;
        }
        const vendor_plan = try allocator.create(runner.VendorPlan);
        errdefer allocator.destroy(vendor_plan);
        vendor_plan.* = runner.prepareVendorPlan(io, allocator, plan.project_root, vendor, .{
            .filters = plan.vendor_filters,
            .checkout_revision = checkout.?.revision,
        }) catch |err| {
            summary.phase_errors += 1;
            summary.vendor_discoveries_failed += 1;
            try summary.journal.append(.{ .event = "coordinator_phase", .phase = "vendor_discovery", .vendor = vendor.package, .revision = checkout.?.revision, .error_name = @errorName(err), .successful = false });
            allocator.destroy(vendor_plan);
            continue;
        };
        errdefer vendor_plan.deinit();
        try prepared.append(allocator, .{ .allocator = allocator, .plan = vendor_plan });
        summary.vendor_expected += vendor_plan.range_end - vendor_plan.range_start;
        try summary.journal.append(.{
            .event = "coordinator_phase",
            .phase = "vendor_discovery",
            .vendor = vendor.package,
            .revision = checkout.?.revision,
            .inventory = vendor_plan.inventory,
            .selected_indices = vendor_plan.selected_indices,
            .excluded = vendor_plan.excluded,
            .range_start = vendor_plan.range_start,
            .range_end = vendor_plan.range_end,
        });
    }
    if (summary.vendor_checkouts_failed != 0 or summary.vendor_discoveries_failed != 0) {
        if (docker) |*service| try service.finish();
        try finishCoordinator(&summary);
        return summary;
    }

    const setup_report = try childReportPath(allocator, summary.journal.directory, "setup", null);
    defer allocator.free(setup_report);
    var setup: ?setup_module.Summary = setup_module.runRootInstalls(allocator, io, plan.project_root, .{
        .report_directory = setup_report,
        .services = servicesFor(if (docker) |*value| value else null, null),
        .expected_platform = policy.expected_platform,
    }) catch |err| blk: {
        summary.phase_errors += 1;
        try summary.journal.append(.{ .event = "coordinator_phase", .phase = "setup", .journal = setup_report, .error_name = @errorName(err), .successful = false });
        break :blk null;
    };
    defer if (setup) |*result| result.deinit();
    summary.setup_succeeded = if (setup) |result| result.successful() else false;
    if (setup) |*result| try summary.journal.append(.{ .event = "coordinator_phase", .phase = "setup", .journal = result.journal.directory, .successful = summary.setup_succeeded, .steps = result.steps, .succeeded = result.succeeded, .failed = result.failed, .inputs_unchanged = result.inputs_unchanged });

    var remap: ?remap_module.Remap = null;
    defer if (remap) |*service| service.deinit();
    if (summary.setup_succeeded and remap_module.applicable(host, policy.context.is_ci)) {
        const pin_path = try std.fs.path.join(allocator, &.{ plan.primary.corpus_path, "UPSTREAM_SHA.txt" });
        defer allocator.free(pin_path);
        const pin_source = try Io.Dir.cwd().readFileAlloc(io, pin_path, allocator, .limited(1024));
        defer allocator.free(pin_source);
        const remap_report = try childReportPath(allocator, summary.journal.directory, "remap", null);
        defer allocator.free(remap_report);
        remap = remap_module.Remap.start(allocator, io, plan.project_root, std.mem.trim(u8, pin_source, " \t\r\n"), remap_report) catch |err| blk: {
            try summary.journal.append(.{ .event = "coordinator_phase", .phase = "remap", .ready = false, .error_name = @errorName(err), .fallback = "crash-reporting-disabled" });
            break :blk null;
        };
        summary.remap_ready = if (remap) |*service| service.port() != null else false;
        if (remap) |*service| try summary.journal.append(.{ .event = "coordinator_phase", .phase = "remap", .journal = service.journal.directory, .ready = summary.remap_ready, .port = service.port() });
    } else try summary.journal.append(.{ .event = "coordinator_phase", .phase = "remap", .applicable = remap_module.applicable(host, policy.context.is_ci), .setup_succeeded = summary.setup_succeeded, .ready = false });

    if (summary.setup_succeeded) {
        const primary_report = try childReportPath(allocator, summary.journal.directory, "primary", null);
        defer allocator.free(primary_report);
        var primary: ?runner.Summary = runner.runPreparedGatePlanWithOptions(io, allocator, &plan.primary, .{
            .on_file = options.on_file,
            .report_directory = primary_report,
            .services = servicesFor(if (docker) |*value| value else null, if (remap) |*value| value else null),
        }) catch |err| blk: {
            summary.phase_errors += 1;
            summary.primary_started = true;
            try summary.journal.append(.{ .event = "coordinator_phase", .phase = "primary", .journal = primary_report, .started = true, .error_name = @errorName(err) });
            break :blk null;
        };
        defer if (primary) |*result| result.deinit(allocator);
        summary.primary_started = true;
        if (primary) |*result| {
            summary.primary_files = result.files;
            summary.primary_passed = result.passed;
            summary.primary_failed = result.failed;
            summary.primary_skipped = result.skipped;
            summary.primary_todo = result.todo;
            summary.primary_unsupported = result.unsupported;
            summary.primary_failed_files = result.failed_files;
            try summary.journal.append(.{ .event = "coordinator_phase", .phase = "primary", .journal = result.journal.?.directory, .files = result.files, .passed = result.passed, .failed = result.failed, .skipped = result.skipped, .todo = result.todo, .unsupported = result.unsupported, .failed_files = result.failed_files });
        }
    } else try summary.journal.append(.{ .event = "coordinator_phase", .phase = "primary", .started = false, .reason = "setup-failed" });

    for (prepared.items) |*prepared_vendor| {
        const vendor_plan = prepared_vendor.plan;
        if (vendor_plan.range_start == vendor_plan.range_end) {
            try summary.journal.append(.{ .event = "coordinator_phase", .phase = "vendor", .vendor = vendor_plan.vendor.package, .started = false, .reason = "no-selected-tests" });
            continue;
        }
        const install_report = try childReportPath(allocator, summary.journal.directory, "vendor-install", vendor_plan.vendor.package);
        defer allocator.free(install_report);
        var install: ?vendor_prepare.Summary = vendor_prepare.prepareWithOptions(allocator, io, plan.project_root, vendor_plan.vendor, .{
            .phase = .install_build,
            .expected_revision = vendor_plan.checkout_revision,
            .services = servicesFor(if (docker) |*value| value else null, if (remap) |*value| value else null),
            .report_directory = install_report,
        }) catch |err| blk: {
            summary.phase_errors += 1;
            summary.vendor_preparations_failed += 1;
            try summary.journal.append(.{ .event = "coordinator_phase", .phase = "vendor_install_build", .vendor = vendor_plan.vendor.package, .journal = install_report, .error_name = @errorName(err), .successful = false });
            break :blk null;
        };
        defer if (install) |*result| result.deinit();
        if (install == null) continue;
        try summary.journal.append(.{ .event = "coordinator_phase", .phase = "vendor_install_build", .vendor = vendor_plan.vendor.package, .journal = install.?.journal.directory, .successful = install.?.successful(), .completed = install.?.completed, .failed = install.?.failed, .revision = install.?.revision });
        if (!install.?.successful()) {
            summary.vendor_preparations_failed += 1;
            continue;
        }
        const vendor_report = try childReportPath(allocator, summary.journal.directory, "vendor", vendor_plan.vendor.package);
        defer allocator.free(vendor_report);
        var vendor_result: ?runner.Summary = runner.runPreparedVendorPlanWithOptions(io, allocator, vendor_plan, .{
            .on_file = options.on_file,
            .report_directory = vendor_report,
            .services = servicesFor(if (docker) |*value| value else null, if (remap) |*value| value else null),
        }) catch |err| blk: {
            summary.phase_errors += 1;
            try summary.journal.append(.{ .event = "coordinator_phase", .phase = "vendor", .vendor = vendor_plan.vendor.package, .journal = vendor_report, .started = true, .error_name = @errorName(err) });
            break :blk null;
        };
        defer if (vendor_result) |*result| result.deinit(allocator);
        if (vendor_result) |*result| {
            summary.vendor_files += result.files;
            summary.vendor_passed += result.passed;
            summary.vendor_failed += result.failed;
            summary.vendor_skipped += result.skipped;
            summary.vendor_todo += result.todo;
            summary.vendor_unsupported += result.unsupported;
            summary.vendor_failed_files += result.failed_files;
            try summary.journal.append(.{ .event = "coordinator_phase", .phase = "vendor", .vendor = vendor_plan.vendor.package, .journal = result.journal.?.directory, .files = result.files, .passed = result.passed, .failed = result.failed, .skipped = result.skipped, .todo = result.todo, .unsupported = result.unsupported, .failed_files = result.failed_files });
        }
    }

    if (remap) |*service| {
        const successful = try service.finish();
        if (summary.remap_ready and !successful) summary.phase_errors += 1;
        try summary.journal.append(.{ .event = "coordinator_phase", .phase = "remap_shutdown", .successful = successful });
    }
    if (docker) |*service| {
        try service.finish();
        if (summary.docker_ready and !service.service_successful) summary.phase_errors += 1;
        try summary.journal.append(.{ .event = "coordinator_phase", .phase = "docker_shutdown", .ready = summary.docker_ready, .service_successful = service.service_successful });
    }
    try finishCoordinator(&summary);
    return summary;
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

test "native corpus coordinator runs setup remap primary and guarded vendor phases" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "project/test");
    try tmp.dir.createDirPath(io, "project/fixtures/bun-tracestrings/bin");
    try tmp.dir.createDirPath(io, "vendor-source/test");

    const root_package =
        \\{"name":"coordinator-root","private":true,"scripts":{"ci-remap-server":"bun node_modules/bun-tracestrings/bin/ci-remap-server.ts"},"dependencies":{"bun-tracestrings":"file:./fixtures/bun-tracestrings"}}
    ;
    const test_package = "{\"name\":\"coordinator-tests\",\"private\":true}";
    const trace_package = "{\"name\":\"bun-tracestrings\",\"version\":\"1.0.0\"}";
    const remap_source =
        \\const server = Bun.serve({ port: 0, fetch() { return new Response('coordinator-ready'); } });
        \\console.log(server.port);
    ;
    const bunfig = "[test]\n";
    const primary_source =
        \\import { test, expect } from 'bun:test';
        \\test('coordinator primary receives live remap', async () => {
        \\  expect(process.env.BUN_CRASH_REPORT_URL).toMatch(/^http:\/\/localhost:/);
        \\  expect(await (await fetch(process.env.BUN_CRASH_REPORT_URL)).text()).toBe('coordinator-ready');
        \\});
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "project/package.json", .data = root_package });
    try tmp.dir.writeFile(io, .{ .sub_path = "project/test/package.json", .data = test_package });
    try tmp.dir.writeFile(io, .{ .sub_path = "project/fixtures/bun-tracestrings/package.json", .data = trace_package });
    try tmp.dir.writeFile(io, .{ .sub_path = "project/fixtures/bun-tracestrings/bin/ci-remap-server.ts", .data = remap_source });
    try tmp.dir.writeFile(io, .{ .sub_path = "project/bunfig.toml", .data = bunfig });
    try tmp.dir.writeFile(io, .{ .sub_path = "project/test/BUN_TRACKED_FILES.txt", .data = "coordinator.test.ts\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "project/test/UPSTREAM_EXPECTATIONS.txt", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "project/test/expectations.txt", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "project/test/coordinator.test.ts", .data = primary_source });
    const pin = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    try tmp.dir.writeFile(io, .{ .sub_path = "project/test/UPSTREAM_SHA.txt", .data = pin });
    const setup_manifest = try std.json.Stringify.valueAlloc(allocator, .{
        .bun_pin = pin,
        .files = .{
            .{ .path = "package.json", .sha256 = @as([]const u8, &journal_module.hashBytes(root_package)) },
            .{ .path = "test/package.json", .sha256 = @as([]const u8, &journal_module.hashBytes(test_package)) },
            .{ .path = "fixtures/bun-tracestrings/package.json", .sha256 = @as([]const u8, &journal_module.hashBytes(trace_package)) },
            .{ .path = "fixtures/bun-tracestrings/bin/ci-remap-server.ts", .sha256 = @as([]const u8, &journal_module.hashBytes(remap_source)) },
            .{ .path = "bunfig.toml", .sha256 = @as([]const u8, &journal_module.hashBytes(bunfig)) },
        },
    }, .{});
    defer allocator.free(setup_manifest);
    try tmp.dir.writeFile(io, .{ .sub_path = "project/BUN_SETUP_FILES.json", .data = setup_manifest });

    const vendor_package = "{\"name\":\"private-coordinator-vendor\",\"private\":true,\"scripts\":{\"build\":\"bun build.js\"}}";
    const vendor_build = "console.log('coordinator vendor built');";
    const vendor_test =
        \\import { test, expect } from 'bun:test';
        \\test('coordinator vendor receives live remap', async () => {
        \\  expect(process.env.BUN_CRASH_REPORT_URL).toMatch(/^http:\/\/localhost:/);
        \\  expect(await (await fetch(process.env.BUN_CRASH_REPORT_URL)).text()).toBe('coordinator-ready');
        \\});
    ;
    try tmp.dir.writeFile(io, .{ .sub_path = "vendor-source/package.json", .data = vendor_package });
    try tmp.dir.writeFile(io, .{ .sub_path = "vendor-source/build.js", .data = vendor_build });
    try tmp.dir.writeFile(io, .{ .sub_path = "vendor-source/bunfig.toml", .data = bunfig });
    try tmp.dir.writeFile(io, .{ .sub_path = "vendor-source/test/vendor.test.ts", .data = vendor_test });
    const root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(root);
    const vendor_source_path = try std.fs.path.join(allocator, &.{ root, "vendor-source" });
    defer allocator.free(vendor_source_path);
    const commands: []const []const []const u8 = &.{
        &.{ "git", "init" },
        &.{ "git", "add", "." },
        &.{ "git", "-c", "user.name=Home Test Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "test: coordinator vendor fixture" },
        &.{ "git", "tag", "v1" },
    };
    for (commands) |argv| {
        var result = try @import("adapters/jsc_bootstrap.zig").runToolCaptured(allocator, io, argv, vendor_source_path, 180_000);
        defer result.deinit(allocator);
        try std.testing.expect(result.term.success() and !result.timed_out and result.output_complete);
    }
    const repository = try std.fmt.allocPrint(allocator, "file://{s}", .{vendor_source_path});
    defer allocator.free(repository);
    const manifest = try std.json.Stringify.valueAlloc(allocator, &.{vendor_module.Vendor{
        .package = "private-coordinator-vendor",
        .repository = repository,
        .tag = "v1",
    }}, .{});
    defer allocator.free(manifest);
    try tmp.dir.writeFile(io, .{ .sub_path = "project/test/vendor.json", .data = manifest });

    const project_root = try tmp.dir.realPathFileAlloc(io, "project", allocator);
    defer allocator.free(project_root);
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    try env.put("CI", "true");
    var plan = try prepare(allocator, io, project_root, "home", &env, .{});
    defer plan.deinit();
    const report = try std.fs.path.join(allocator, &.{ root, "coordinator-reports" });
    defer allocator.free(report);
    var summary = run(allocator, io, &plan, .{ .report_directory = report }) catch |err| {
        std.debug.print("coordinator control failed with {s}\n", .{@errorName(err)});
        return err;
    };
    defer summary.deinit();
    if (!summary.successful()) {
        const events_path = try std.fs.path.join(allocator, &.{ summary.journal.directory, "events.jsonl" });
        defer allocator.free(events_path);
        const events = try Io.Dir.cwd().readFileAlloc(io, events_path, allocator, .limited(4 * 1024 * 1024));
        defer allocator.free(events);
        std.debug.print("coordinator control journal:\n{s}\n", .{events});
    }
    try std.testing.expect(summary.successful());
    try std.testing.expect(summary.setup_succeeded and summary.primary_started and summary.remap_ready);
    try std.testing.expect(!summary.docker_ready);
    try std.testing.expectEqual(@as(usize, 1), summary.primary_files);
    try std.testing.expectEqual(@as(usize, 1), summary.primary_passed);
    try std.testing.expectEqual(@as(usize, 1), summary.vendor_files);
    try std.testing.expectEqual(@as(usize, 1), summary.vendor_passed);
    try std.testing.expectEqual(@as(usize, 0), summary.primary_failed + summary.vendor_failed + summary.primary_failed_files + summary.vendor_failed_files);
}
