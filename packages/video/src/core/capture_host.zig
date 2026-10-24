//! Explicit Zig 0.15.2 native C-translation boundary, separate from portable
//! video.capture_backing because current Home Zig removed @cImport.
const backing = @import("capture_backing.zig");
pub const policy = backing.policy;
pub const Owner = backing.Owner;
pub const Ram = backing.Ram;
pub const LinuxHeap = @import("capture_dma_heap.zig").LinuxHeap;
