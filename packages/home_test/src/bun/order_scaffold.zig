const std = @import("std");

pub const ScopeMode = enum {
    normal,
    skip,
    todo,
    failing,
    filtered_out,
};

pub const BaseScope = struct {
    parent: ?*DescribeScope = null,
    name: ?[]const u8 = null,
    concurrent: bool = false,
    mode: ScopeMode = .normal,
    only: enum { no, contains, yes } = .no,
    has_callback: bool = false,
    test_id_for_debugger: i32 = 0,
    line_no: u32 = 0,
};

pub const DescribeScope = struct {
    base: BaseScope,
    entries: std.array_list.Managed(TestScheduleEntry),
    beforeAll: std.array_list.Managed(*ExecutionEntry),
    beforeEach: std.array_list.Managed(*ExecutionEntry),
    afterEach: std.array_list.Managed(*ExecutionEntry),
    afterAll: std.array_list.Managed(*ExecutionEntry),
    failed: bool = false,

    pub fn init(gpa: std.mem.Allocator, base: BaseScope) DescribeScope {
        return .{
            .base = base,
            .entries = .init(gpa),
            .beforeAll = .init(gpa),
            .beforeEach = .init(gpa),
            .afterEach = .init(gpa),
            .afterAll = .init(gpa),
        };
    }

    pub fn deinit(this: *DescribeScope) void {
        this.entries.deinit();
        this.beforeAll.deinit();
        this.beforeEach.deinit();
        this.afterEach.deinit();
        this.afterAll.deinit();
    }
};

pub const ExecutionEntry = struct {
    base: BaseScope,
    callback: ?*anyopaque = null,
    timeout: u32 = 0,
    has_done_parameter: bool = false,
    added_in_phase: AddedInPhase = .preload,
    retry_count: u32 = 0,
    repeat_count: u32 = 0,
    next: ?*ExecutionEntry = null,
    failure_skip_past: ?*ExecutionEntry = null,

    pub const AddedInPhase = enum { preload, collection, execution };
};

pub const TestScheduleEntry = union(enum) {
    describe: *DescribeScope,
    test_callback: *ExecutionEntry,

    pub fn base(this: TestScheduleEntry) *BaseScope {
        return switch (this) {
            .describe => |describe| &describe.base,
            .test_callback => |test_callback| &test_callback.base,
        };
    }
};

pub const Execution = struct {
    pub const ConcurrentGroup = struct {
        sequence_start: usize,
        sequence_end: usize,
        next_sequence_index: usize,
        executing: bool,
        remaining_incomplete_entries: usize,
        failure_skip_to: usize,

        pub fn init(sequence_start: usize, sequence_end: usize, next_index: usize) ConcurrentGroup {
            return .{
                .sequence_start = sequence_start,
                .sequence_end = sequence_end,
                .next_sequence_index = 0,
                .executing = false,
                .remaining_incomplete_entries = sequence_end - sequence_start,
                .failure_skip_to = next_index,
            };
        }

        pub fn tryExtend(this: *ConcurrentGroup, next_sequence_start: usize, next_sequence_end: usize) bool {
            if (this.sequence_end != next_sequence_start) return false;
            this.sequence_end = next_sequence_end;
            this.remaining_incomplete_entries = this.sequence_end - this.sequence_start;
            return true;
        }
    };

    pub const ExecutionSequence = struct {
        first_entry: ?*ExecutionEntry,
        active_entry: ?*ExecutionEntry,
        test_entry: ?*ExecutionEntry,
        remaining_repeat_count: u32,
        remaining_retry_count: u32,

        pub fn init(cfg: struct {
            first_entry: ?*ExecutionEntry,
            test_entry: ?*ExecutionEntry,
            retry_count: u32 = 0,
            repeat_count: u32 = 0,
        }) ExecutionSequence {
            return .{
                .first_entry = cfg.first_entry,
                .active_entry = cfg.first_entry,
                .test_entry = cfg.test_entry,
                .remaining_repeat_count = cfg.repeat_count,
                .remaining_retry_count = cfg.retry_count,
            };
        }
    };
};
