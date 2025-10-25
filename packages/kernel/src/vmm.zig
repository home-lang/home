// Home Programming Language - Virtual Memory Manager
// Advanced memory management with COW, mmap, and shared memory

const Basics = @import("basics");
const memory = @import("memory.zig");
const paging = @import("paging.zig");
const atomic = @import("atomic.zig");
const sync = @import("sync.zig");

// ============================================================================
// Virtual Memory Area (VMA) - Memory Region
// ============================================================================

pub const VmaFlags = packed struct(u32) {
    read: bool = false,
    write: bool = false,
    execute: bool = false,
    shared: bool = false,
    stack: bool = false,
    heap: bool = false,
    mmap: bool = false,
    cow: bool = false, // Copy-On-Write
    locked: bool = false,
    _padding: u23 = 0,
};

pub const Vma = struct {
    start: u64,
    end: u64,
    flags: VmaFlags,
    file_offset: u64,
    refcount: atomic.AtomicU32,
    next: ?*Vma,
    prev: ?*Vma,

    pub fn init(start: u64, end: u64, flags: VmaFlags) Vma {
        return .{
            .start = start,
            .end = end,
            .flags = flags,
            .file_offset = 0,
            .refcount = atomic.AtomicU32.init(1),
            .next = null,
            .prev = null,
        };
    }

    pub fn size(self: *const Vma) u64 {
        return self.end - self.start;
    }

    pub fn contains(self: *const Vma, addr: u64) bool {
        return addr >= self.start and addr < self.end;
    }
};

// ============================================================================
// Virtual Memory Manager
// ============================================================================

pub const Vmm = struct {
    page_mapper: *paging.PageMapper,
    vma_list: ?*Vma,
    lock: sync.Spinlock,
    allocator: Basics.Allocator,

    pub fn init(allocator: Basics.Allocator) !*Vmm {
        const vmm = try allocator.create(Vmm);
        vmm.* = .{
            .page_mapper = try paging.PageMapper.init(allocator),
            .vma_list = null,
            .lock = sync.Spinlock.init(),
            .allocator = allocator,
        };
        return vmm;
    }

    pub fn deinit(self: *Vmm) void {
        // Free all VMAs
        var vma = self.vma_list;
        while (vma) |v| {
            const next = v.next;
            self.allocator.destroy(v);
            vma = next;
        }
        self.page_mapper.deinit();
        self.allocator.destroy(self);
    }

    pub fn mapRegion(self: *Vmm, vaddr: u64, size: u64, flags: VmaFlags) !void {
        self.lock.acquire();
        defer self.lock.release();

        const vma = try self.allocator.create(Vma);
        vma.* = Vma.init(vaddr, vaddr + size, flags);

        // Insert into list
        vma.next = self.vma_list;
        if (self.vma_list) |head| {
            head.prev = vma;
        }
        self.vma_list = vma;

        // Map pages
        try self.mapVmaPages(vma);
    }

    fn mapVmaPages(self: *Vmm, vma: *Vma) !void {
        var page_flags = paging.PageFlags{
            .present = true,
            .writable = vma.flags.write,
            .user = true,
            .no_execute = !vma.flags.execute,
        };

        var addr = vma.start;
        while (addr < vma.end) : (addr += memory.PAGE_SIZE) {
            const phys_frame = try memory.allocateFrame();
            try self.page_mapper.mapPage(addr, phys_frame, page_flags);
        }
    }

    pub fn handlePageFault(self: *Vmm, fault_addr: u64, write: bool) !void {
        self.lock.acquire();
        defer self.lock.release();

        const vma = self.findVma(fault_addr) orelse return error.AccessViolation;

        if (vma.flags.cow and write) {
            try self.handleCow(vma, fault_addr);
        } else {
            return error.AccessViolation;
        }
    }

    fn handleCow(self: *Vmm, vma: *Vma, fault_addr: u64) !void {
        _ = vma;
        const page_addr = memory.alignDown(fault_addr);

        // Allocate new frame
        const new_frame = try memory.allocateFrame();

        // Copy old page data to new frame
        const old_frame = try self.page_mapper.getPhysicalAddress(page_addr);
        const src: [*]const u8 = @ptrFromInt(old_frame);
        const dst: [*]u8 = @ptrFromInt(new_frame);
        @memcpy(dst[0..memory.PAGE_SIZE], src[0..memory.PAGE_SIZE]);

        // Remap page as writable
        const flags = paging.PageFlags{
            .present = true,
            .writable = true,
            .user = true,
            .no_execute = false,
        };
        try self.page_mapper.mapPage(page_addr, new_frame, flags);
    }

    fn findVma(self: *Vmm, addr: u64) ?*Vma {
        var vma = self.vma_list;
        while (vma) |v| {
            if (v.contains(addr)) return v;
            vma = v.next;
        }
        return null;
    }
};

// ============================================================================
// Security - User Pointer Validation
// ============================================================================

/// User space address range for x86-64
const USER_SPACE_START: u64 = 0x0000_0000_0000_0000;
const USER_SPACE_END: u64 = 0x0000_7FFF_FFFF_FFFF;

/// Maximum sizes for syscall buffers
pub const MAX_READ_SIZE: usize = 0x7FFFF000; // 2GB - 4KB
pub const MAX_WRITE_SIZE: usize = 0x7FFFF000;
pub const MAX_PATH_LEN: usize = 4096;
pub const MAX_ARG_LEN: usize = 131072; // 128KB for execve args

/// Validate that a user pointer is safe to access
pub fn validateUserPointer(addr: usize, len: usize, write: bool) !void {
    const process = @import("process.zig");

    // Check for null pointer
    if (addr == 0) return error.InvalidAddress;

    // Check if in user space
    if (addr < USER_SPACE_START or addr >= USER_SPACE_END) {
        return error.InvalidAddress;
    }

    // Check for overflow
    if (addr > USER_SPACE_END - len) {
        return error.InvalidAddress;
    }

    // Get current process
    const current = process.getCurrentProcess() orelse return error.NoProcess;

    // Check if address range is mapped in process VMA
    current.address_space.lock.acquire();
    defer current.address_space.lock.release();

    // Find VMA that contains this address range
    const start_addr = addr;
    const end_addr = addr + len;

    var current_addr = start_addr;
    while (current_addr < end_addr) {
        const vma = current.address_space.findVma(current_addr) orelse {
            return error.NotMapped;
        };

        // Check permissions
        if (write and !vma.flags.write) {
            return error.AccessDenied;
        }
        if (!write and !vma.flags.read) {
            return error.AccessDenied;
        }

        // Move to next VMA if needed
        if (vma.end >= end_addr) {
            break; // Entire range covered
        }
        current_addr = vma.end;
    }
}

/// Copy data from user space to kernel space safely
pub fn copyFromUser(dst: []u8, src_addr: usize, len: usize) !void {
    try validateUserPointer(src_addr, len, false);
    const src: [*]const u8 = @ptrFromInt(src_addr);
    @memcpy(dst[0..len], src[0..len]);
}

/// Copy data from kernel space to user space safely
pub fn copyToUser(dst_addr: usize, src: []const u8) !void {
    try validateUserPointer(dst_addr, src.len, true);
    const dst: [*]u8 = @ptrFromInt(dst_addr);
    @memcpy(dst[0..src.len], src);
}

/// Safely read a null-terminated string from user space
pub fn copyStringFromUser(allocator: Basics.Allocator, src_addr: usize, max_len: usize) ![]u8 {
    try validateUserPointer(src_addr, max_len, false);

    const src: [*:0]const u8 = @ptrFromInt(src_addr);
    const len = Basics.mem.len(src);

    if (len > max_len) return error.StringTooLong;

    const result = try allocator.alloc(u8, len);
    @memcpy(result, src[0..len]);
    return result;
}

// ============================================================================
// Path Sanitization
// ============================================================================

/// Sanitize and validate a file path to prevent directory traversal attacks
pub fn sanitizePath(path: []const u8) !void {
    const process_mod = @import("process.zig");

    if (path.len == 0) return error.InvalidPath;
    if (path.len > MAX_PATH_LEN) return error.PathTooLong;

    const current = process_mod.getCurrentProcess() orelse return error.NoProcess;

    // Absolute paths only allowed for root
    if (path.len > 0 and path[0] == '/' and current.euid != 0) {
        return error.AccessDenied;
    }

    // Check for null bytes in path
    if (Basics.mem.indexOfScalar(u8, path, 0)) |_| {
        return error.InvalidPath;
    }

    // Check each component for path traversal attempts
    var start: usize = 0;
    for (path, 0..) |c, i| {
        if (c == '/' or i == path.len - 1) {
            const end = if (c == '/') i else i + 1;
            if (end > start) {
                const component = path[start..end];

                // Reject ".." components (path traversal)
                if (Basics.mem.eql(u8, component, "..")) {
                    return error.InvalidPath;
                }

                // Check for double slashes
                if (component.len == 0 and c == '/') {
                    return error.InvalidPath;
                }
            }

            start = if (c == '/') i + 1 else i + 1;
        }
    }
}
