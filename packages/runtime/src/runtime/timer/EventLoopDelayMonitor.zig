const EventLoopDelayMonitor = @This();

histogram: jsc.Weak(EventLoopDelayMonitor) = .{},
event_loop_timer: jsc.API.Timer.EventLoopTimer = .{ .next = .epoch, .tag = .EventLoopDelayMonitor },
resolution_ms: i64 = 10,
last_fire_ns: u64 = 0,

pub const Registry = struct {
    monitors: std.ArrayListUnmanaged(*EventLoopDelayMonitor) = .empty,

    pub fn enable(this: *Registry, vm: *VirtualMachine, value: jsc.JSValue, resolution_ms: i64) void {
        this.sweepCollected(vm);
        for (this.monitors.items) |monitor| {
            if (monitor.histogram.get()) |existing| {
                if (existing == value) return;
            }
        }
        const monitor = bun.handleOom(bun.default_allocator.create(EventLoopDelayMonitor));
        monitor.* = .{ .resolution_ms = resolution_ms };
        monitor.histogram = jsc.Weak(EventLoopDelayMonitor).create(value, vm.global, .None, monitor);
        const now = bun.timespec.now(.force_real_time);
        monitor.last_fire_ns = now.ns();
        monitor.event_loop_timer.next = now.addMs(@intCast(resolution_ms));
        bun.handleOom(this.monitors.append(bun.default_allocator, monitor));
        vm.timer.insert(&monitor.event_loop_timer);
    }

    pub fn disable(this: *Registry, vm: *VirtualMachine, value: jsc.JSValue) void {
        for (this.monitors.items) |monitor| {
            if (monitor.histogram.get()) |existing| {
                if (existing == value) {
                    monitor.destroy(vm);
                    return;
                }
            }
        }
    }

    pub fn sweepCollected(this: *Registry, vm: *VirtualMachine) void {
        var index: usize = 0;
        while (index < this.monitors.items.len) {
            const monitor = this.monitors.items[index];
            if (!monitor.histogram.hasValue()) {
                monitor.destroy(vm);
            } else {
                index += 1;
            }
        }
    }

    pub fn shutdown(this: *Registry, vm: *VirtualMachine) void {
        while (this.monitors.items.len > 0) this.monitors.items[this.monitors.items.len - 1].destroy(vm);
        this.monitors.deinit(bun.default_allocator);
        this.monitors = .empty;
    }
};

fn destroy(this: *EventLoopDelayMonitor, vm: *VirtualMachine) void {
    if (this.event_loop_timer.in_heap != .none) vm.timer.remove(&this.event_loop_timer);
    const registry = &vm.timer.event_loop_delay;
    for (registry.monitors.items, 0..) |monitor, index| {
        if (monitor == this) {
            _ = registry.monitors.swapRemove(index);
            break;
        }
    }
    this.histogram.deinit();
    bun.default_allocator.destroy(this);
}

noinline fn recordSample(this: *EventLoopDelayMonitor, elapsed: u64) bool {
    const histogram = this.histogram.get() orelse return false;
    if (elapsed > 0) JSNodePerformanceHooksHistogram_recordDelay(histogram, @intCast(@min(elapsed, std.math.maxInt(i64))));
    return true;
}

pub fn onFire(this: *EventLoopDelayMonitor, vm: *VirtualMachine, now: *const bun.timespec) void {
    // Keep the weak cell off the persistent timer/event-loop stack frame.
    this.event_loop_timer.in_heap = .none;
    const now_ns = now.ns();
    const elapsed = now_ns -| this.last_fire_ns;
    if (!this.recordSample(elapsed)) {
        this.destroy(vm);
        return;
    }
    this.last_fire_ns = now_ns;
    this.event_loop_timer.next = now.addMs(@intCast(this.resolution_ms));
    vm.timer.insert(&this.event_loop_timer);
}

extern fn JSNodePerformanceHooksHistogram_recordDelay(histogram: jsc.JSValue, delay_ns: i64) void;

export fn Timer_enableEventLoopDelayMonitoring(vm: *VirtualMachine, histogram: jsc.JSValue, resolution_ms: i64) void {
    vm.timer.event_loop_delay.enable(vm, histogram, resolution_ms);
}

export fn Timer_disableEventLoopDelayMonitoring(vm: *VirtualMachine, histogram: jsc.JSValue) void {
    vm.timer.event_loop_delay.disable(vm, histogram);
}

const bun = @import("bun");
const std = @import("std");
const jsc = bun.jsc;
const VirtualMachine = jsc.VirtualMachine;
