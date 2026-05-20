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
};

pub const ExecutionEntry = struct {
    base: BaseScope,
    next: ?*ExecutionEntry = null,
};

pub const TestScheduleEntry = union(enum) {
    describe: *DescribeScope,
    test_callback: *ExecutionEntry,
};

pub const DescribeScope = struct {
    base: BaseScope,
    entries: std.array_list.Managed(TestScheduleEntry),
    beforeAll: std.array_list.Managed(*ExecutionEntry),
    beforeEach: std.array_list.Managed(*ExecutionEntry),
    afterEach: std.array_list.Managed(*ExecutionEntry),
    afterAll: std.array_list.Managed(*ExecutionEntry),

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

pub const Execution = struct {
    groups: []Execution.ConcurrentGroup,
    sequences: []Execution.ExecutionSequence,

    pub const ConcurrentGroup = struct {
        sequence_start: usize,
        sequence_end: usize,

        pub fn sequences(this: Execution.ConcurrentGroup, execution: *Execution) []Execution.ExecutionSequence {
            return execution.sequences[this.sequence_start..this.sequence_end];
        }
    };

    pub const ExecutionSequence = struct {
        first_entry: ?*ExecutionEntry,
        remaining_repeat_count: u32 = 0,
    };
};

pub const ConcurrentGroup = Execution.ConcurrentGroup;
pub const ExecutionSequence = Execution.ExecutionSequence;
