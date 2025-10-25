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

    pub fn contains(self: *const Vma) bool {
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
