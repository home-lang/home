// Home Programming Language - DMA (Direct Memory Access)
// DMA operations for efficient data transfer

const std = @import("std");
const atomic = @import("atomic.zig");

/// DMA transfer direction
pub const Direction = enum {
    MemoryToMemory,
    MemoryToDevice,
    DeviceToMemory,
    DeviceToDevice,
};

/// DMA transfer status
pub const Status = enum {
    Idle,
    InProgress,
    Complete,
    Error,
};

/// DMA buffer descriptor
pub const Buffer = struct {
    physical_addr: u64,
    virtual_addr: ?[*]u8,
    size: usize,
    flags: u32,

    pub fn init(phys_addr: u64, virt_addr: ?[*]u8, size: usize) Buffer {
        return .{
            .physical_addr = phys_addr,
            .virtual_addr = virt_addr,
            .size = size,
            .flags = 0,
        };
    }
};

/// DMA channel for managing transfers
pub const Channel = struct {
    id: u32,
    status: atomic.AtomicFlag,
    current_transfer: ?*Transfer,

    pub fn init(id: u32) Channel {
        return .{
            .id = id,
            .status = atomic.AtomicFlag.init(false),
            .current_transfer = null,
        };
    }

    pub fn isAvailable(self: *const Channel) bool {
        return !self.status.load(.acquire);
    }

    pub fn acquire(self: *Channel) bool {
        return !self.status.testAndSet(.acquire);
    }

    pub fn release(self: *Channel) void {
        self.current_transfer = null;
        self.status.clear(.release);
    }
};

/// DMA transfer descriptor
pub const Transfer = struct {
    source: Buffer,
    destination: Buffer,
    direction: Direction,
    status: Status,
    bytes_transferred: usize,

    pub fn init(src: Buffer, dst: Buffer, dir: Direction) Transfer {
        return .{
            .source = src,
            .destination = dst,
            .direction = dir,
            .status = .Idle,
            .bytes_transferred = 0,
        };
    }

    pub fn getProgress(self: *const Transfer) f32 {
        const total = @min(self.source.size, self.destination.size);
        if (total == 0) return 0.0;
        return @as(f32, @floatFromInt(self.bytes_transferred)) / @as(f32, @floatFromInt(total));
    }
};

/// DMA controller for managing channels
pub const Controller = struct {
    channels: []Channel,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, num_channels: u32) !Controller {
        const channels = try allocator.alloc(Channel, num_channels);
        for (channels, 0..) |*channel, i| {
            channel.* = Channel.init(@intCast(i));
        }

        return .{
            .channels = channels,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Controller) void {
        self.allocator.free(self.channels);
    }

    pub fn allocateChannel(self: *Controller) ?*Channel {
        for (self.channels) |*channel| {
            if (channel.acquire()) {
                return channel;
            }
        }
        return null;
    }

    pub fn freeChannel(self: *Controller, channel: *Channel) void {
        _ = self;
        channel.release();
    }

    pub fn submitTransfer(self: *Controller, channel: *Channel, transfer: *Transfer) !void {
        _ = self;
        if (channel.current_transfer != null) {
            return error.ChannelBusy;
        }
        channel.current_transfer = transfer;
        transfer.status = .InProgress;
    }

    pub fn waitForCompletion(self: *Controller, channel: *Channel) !void {
        _ = self;
        if (channel.current_transfer) |transfer| {
            // Simulate waiting for completion
            while (transfer.status == .InProgress) {
                std.atomic.spinLoopHint();
                // In a real implementation, would wait for interrupt
                // For now, just mark as complete
                transfer.status = .Complete;
            }
        }
    }
};

/// Allocate DMA-capable memory
pub fn allocateBuffer(allocator: std.mem.Allocator, size: usize) !Buffer {
    // In a real implementation, this would allocate physically contiguous memory
    const memory = try allocator.alloc(u8, size);
    return Buffer.init(
        @intFromPtr(memory.ptr), // Physical address (would be different in real impl)
        memory.ptr,
        size,
    );
}

/// Free DMA buffer
pub fn freeBuffer(allocator: std.mem.Allocator, buffer: Buffer) void {
    if (buffer.virtual_addr) |addr| {
        const slice = addr[0..buffer.size];
        allocator.free(slice);
    }
}

test "DMA channel allocation" {
    const allocator = std.testing.allocator;
    var controller = try Controller.init(allocator, 4);
    defer controller.deinit();

    const channel1 = controller.allocateChannel();
    try std.testing.expect(channel1 != null);

    const channel2 = controller.allocateChannel();
    try std.testing.expect(channel2 != null);
    try std.testing.expect(channel1.?.id != channel2.?.id);

    controller.freeChannel(channel1.?);
    controller.freeChannel(channel2.?);
}

test "DMA transfer progress" {
    const src = Buffer.init(0x1000, null, 1024);
    const dst = Buffer.init(0x2000, null, 1024);
    var transfer = Transfer.init(src, dst, .MemoryToMemory);

    try std.testing.expectEqual(@as(f32, 0.0), transfer.getProgress());

    transfer.bytes_transferred = 512;
    try std.testing.expectEqual(@as(f32, 0.5), transfer.getProgress());
}
