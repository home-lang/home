// Copied from bun/src/crash_handler/crash_handler.zig at upstream SHA
// fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT - see ../cli/LICENSE.bun.md.

/// A variant of `std.builtin.StackTrace` that stores its data within itself
/// instead of being a pointer. This allows storing captured stack traces
/// for later printing.
pub const StoredTrace = struct {
    data: [31]usize,
    index: usize,

    pub const empty: StoredTrace = .{
        .data = @splat(0),
        .index = 0,
    };

    pub fn trace(stored: *StoredTrace) std.builtin.StackTrace {
        return .{
            .index = stored.index,
            .instruction_addresses = &stored.data,
        };
    }

    pub fn capture(begin: ?usize) StoredTrace {
        var stored: StoredTrace = StoredTrace.empty;
        var frame = stored.trace();
        std.debug.captureStackTrace(begin orelse @returnAddress(), &frame);
        stored.index = frame.index;
        for (frame.instruction_addresses[0..frame.index], 0..) |addr, i| {
            if (addr == 0) {
                stored.index = i;
                break;
            }
        }
        return stored;
    }

    pub fn from(stack_trace: ?*std.builtin.StackTrace) StoredTrace {
        if (stack_trace) |stack| {
            var data: [31]usize = undefined;
            @memset(&data, 0);
            const items = @min(stack.instruction_addresses.len, 31);
            @memcpy(data[0..items], stack.instruction_addresses[0..items]);
            return .{
                .data = data,
                .index = @min(items, stack.index),
            };
        } else {
            return empty;
        }
    }
};

const std = @import("std");
