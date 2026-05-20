const std = @import("std");

pub const bun = struct {
    pub const JSError = error{ JSException, OutOfMemory };

    pub const Environment = struct {
        pub const ci_assert = false;
    };

    pub const assert = std.debug.assert;

    pub fn debugAssert(ok: bool) void {
        std.debug.assert(ok);
    }

    pub const safety = struct {
        pub const CheckedAllocator = struct {
            allocator: std.mem.Allocator,

            pub fn init(allocator: std.mem.Allocator) CheckedAllocator {
                return .{ .allocator = allocator };
            }

            pub fn assertEq(this: CheckedAllocator, other: std.mem.Allocator) void {
                _ = this;
                _ = other;
            }
        };
    };

    pub const timespec = struct {
        ns: i128 = 0,

        pub const epoch = timespec{ .ns = 0 };

        pub fn now(_: enum { force_real_time }) timespec {
            return .{ .ns = 1 };
        }

        pub fn msFromNow(_: enum { force_real_time }, ms: u32) timespec {
            return .{ .ns = @as(i128, ms) * std.time.ns_per_ms };
        }

        pub fn order(this: timespec, other: *const timespec) std.math.Order {
            return std.math.order(this.ns, other.ns);
        }

        pub fn minIgnoreEpoch(this: timespec, other: timespec) timespec {
            if (this.eql(&epoch)) return other;
            if (other.eql(&epoch)) return this;
            return if (this.ns <= other.ns) this else other;
        }

        pub fn eql(this: timespec, other: *const timespec) bool {
            return this.ns == other.ns;
        }

        pub fn sinceNow(this: timespec, _: enum { force_real_time }) u64 {
            _ = this;
            return 0;
        }
    };

    pub const Output = struct {
        pub fn scoped(_: enum { jest }, _: enum { visible }) fn (comptime []const u8, anytype) void {
            return scopedLog;
        }

        fn scopedLog(comptime _: []const u8, _: anytype) void {}

        pub fn prettyErrorln(comptime _: []const u8, _: anytype) void {}

        pub fn flush() void {}
    };
};

pub const jsc = struct {
    pub const JSValue = usize;

    pub const JSGlobalObject = struct {
        vm: BunVM = .{},

        pub fn bunVM(this: *JSGlobalObject) *BunVM {
            return &this.vm;
        }
    };

    pub const BunVM = struct {
        auto_killer: AutoKiller = .{},
    };

    pub const AutoKiller = struct {
        pub const KillCount = struct { processes: usize = 0 };

        pub fn enable(_: *AutoKiller) void {}
        pub fn disable(_: *AutoKiller) void {}
        pub fn kill(_: *AutoKiller) KillCount {
            return .{};
        }
    };

    pub const VirtualMachine = struct {
        debugger: ?Debugger = null,

        pub fn get() *VirtualMachine {
            return &State.current;
        }

        const State = struct {
            var current: VirtualMachine = .{};
        };
    };

    pub const Debugger = struct {
        test_reporter_agent: TestReporterAgent = .{},
    };

    pub const TestReporterAgent = struct {
        pub fn isEnabled(_: *TestReporterAgent) bool {
            return false;
        }

        pub fn reportTestStart(_: *TestReporterAgent, _: i32) void {}

        pub fn reportTestEnd(_: *TestReporterAgent, _: i32, _: TestStatus, _: f64) void {}
    };

    pub const TestStatus = enum {
        pass,
        fail,
        skip,
        timeout,
        todo,
        skipped_because_label,
    };

    pub const Jest = struct {
        pub const Jest = struct {
            pub const Runner = struct {
                snapshots: Snapshots = .{},
            };

            pub var runner: ?Runner = null;
        };
    };
};

pub const ScopeMode = enum {
    normal,
    skip,
    todo,
    failing,
    filtered_out,
};

pub const BaseScope = struct {
    name: ?[]const u8 = null,
    mode: ScopeMode = .normal,
    test_id_for_debugger: i32 = 0,
};

pub const Callback = struct {
    pub fn get(_: Callback) jsc.JSValue {
        return 1;
    }
};

pub const ExecutionEntry = struct {
    base: BaseScope = .{},
    callback: ?Callback = null,
    timeout: u32 = 0,
    timespec: bun.timespec = .epoch,
    has_done_parameter: bool = false,
    added_in_phase: AddedInPhase = .preload,
    next: ?*ExecutionEntry = null,
    failure_skip_past: ?*ExecutionEntry = null,

    pub const AddedInPhase = enum { preload, collection, execution };

    pub fn evaluateTimeout(this: *ExecutionEntry, _: *Execution.ExecutionSequence, now: *const bun.timespec) bool {
        if (this.timespec.eql(&bun.timespec.epoch)) return false;
        return this.timespec.order(now) == .lt;
    }
};

pub const Execution = @import("Execution.zig");
pub const ConcurrentGroup = Execution.ConcurrentGroup;
pub const ExecutionSequence = Execution.ExecutionSequence;

pub const Order = struct {
    groups: std.array_list.Managed(ConcurrentGroup),
    sequences: std.array_list.Managed(ExecutionSequence),
};

pub const StepResult = union(enum) {
    complete,
    waiting: struct { timeout: bun.timespec = .epoch },
};

pub const HandleUncaughtExceptionResult = enum {
    show_unhandled_error_between_tests,
    show_handled_error,
    hide_error,
};

pub const BunTestPtr = struct {
    ptr: *BunTest,

    pub fn get(this: BunTestPtr) *BunTest {
        return this.ptr;
    }
};

pub const BunTest = struct {
    gpa: std.mem.Allocator,
    execution: Execution,
    reporter: ?*Reporter = null,

    pub const RefDataValue = union(enum) {
        start,
        collection: void,
        execution: ExecutionData,

        pub const ExecutionData = struct {
            group_index: usize,
            entry_data: ?EntryData = null,

            pub const EntryData = struct {
                sequence_index: usize,
                entry: ?*anyopaque,
                remaining_repeat_count: u32,
            };
        };

        pub fn group(this: *const RefDataValue, buntest: *BunTest) ?*ConcurrentGroup {
            if (this.* != .execution) return null;
            if (this.execution.group_index >= buntest.execution.groups.len) return null;
            return &buntest.execution.groups[this.execution.group_index];
        }

        pub fn sequence(this: *const RefDataValue, buntest: *BunTest) ?*ExecutionSequence {
            if (this.* != .execution or this.execution.entry_data == null) return null;
            const group_ptr = this.group(buntest) orelse return null;
            const sequence_index = this.execution.entry_data.?.sequence_index;
            const group_sequences = group_ptr.sequences(&buntest.execution);
            if (sequence_index >= group_sequences.len) return null;
            return &group_sequences[sequence_index];
        }

        pub fn entry(this: *const RefDataValue, buntest: *BunTest) ?*ExecutionEntry {
            return this.sequence(buntest).?.active_entry;
        }

        pub fn format(_: RefDataValue, writer: *std.Io.Writer) !void {
            try writer.writeAll("RefDataValue");
        }
    };

    pub fn addResult(_: *BunTest, _: RefDataValue) void {}

    pub fn runTestCallback(_: BunTestPtr, _: *jsc.JSGlobalObject, _: jsc.JSValue, _: bool, _: RefDataValue, _: *bun.timespec) ?RefDataValue {
        return null;
    }
};

pub const Reporter = struct {
    jest: JestReporter = .{},
};

pub const JestReporter = struct {
    max_concurrency: usize = 20,
};

pub const Snapshots = struct {
    pub fn resetCounts(_: *const Snapshots) void {}
};

pub const debug = struct {
    pub const group = struct {
        pub fn begin(_: std.builtin.SourceLocation) void {}
        pub fn end() void {}
        pub fn log(comptime _: []const u8, _: anytype) void {}
    };
};

pub const test_command = struct {
    pub const CommandLineReporter = struct {
        pub fn handleTestCompleted(_: *BunTest, _: *ExecutionSequence, _: *ExecutionEntry, _: u64) void {}
    };
};
