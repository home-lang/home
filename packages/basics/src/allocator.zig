// Home Language - Allocator Module
// Provides memory allocation interfaces for Home programs

const std = @import("std");

pub const Allocator = std.mem.Allocator;

/// Create a general purpose allocator
pub fn createGeneralPurposeAllocator() std.heap.GeneralPurposeAllocator(.{}) {
    return std.heap.GeneralPurposeAllocator(.{}){};
}

/// Get the page allocator (direct from OS)
pub fn pageAllocator() Allocator {
    return std.heap.page_allocator;
}

/// Get a C allocator (uses malloc/free)
pub fn cAllocator() Allocator {
    return std.heap.c_allocator;
}

/// Get an arena allocator for temporary allocations
pub const ArenaAllocator = std.heap.ArenaAllocator;

/// Fixed buffer allocator for stack-based allocations
pub const FixedBufferAllocator = std.heap.FixedBufferAllocator;
