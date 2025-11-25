// Home Programming Language - Complete ELF Loader
// Full ELF64 loading with memory mapping and segment loading

const Basics = @import("basics");
const process = @import("process.zig");
const memory = @import("memory.zig");
const paging = @import("paging.zig");
const exec = @import("exec.zig");

// ============================================================================
// Physical Page Allocator
// ============================================================================

/// Global physical page allocator (initialized by kernel)
var global_page_allocator: ?*memory.PageAllocator = null;

pub fn initPageAllocator(allocator: *memory.PageAllocator) void {
    global_page_allocator = allocator;
}

fn allocPhysicalPage() !memory.PhysicalAddress {
    if (global_page_allocator) |alloc| {
        return try alloc.allocPage();
    }
    return error.NoPageAllocator;
}

fn freePhysicalPage(addr: memory.PhysicalAddress) void {
    if (global_page_allocator) |alloc| {
        alloc.freePage(addr);
    }
}

// ============================================================================
// Page Mapping Operations
// ============================================================================

/// Map a physical page to a virtual address
pub fn mapPage(
    page_mapper: *paging.PageMapper,
    virt_addr: memory.VirtualAddress,
    phys_addr: memory.PhysicalAddress,
    flags: struct {
        writable: bool = false,
        user: bool = false,
        no_execute: bool = false,
    },
) !void {
    const aligned_virt = memory.alignDown(virt_addr);
    const aligned_phys = memory.alignDown(phys_addr);

    const page_flags = paging.PageFlags.new(aligned_phys, .{
        .writable = flags.writable,
        .user = flags.user,
        .no_execute = flags.no_execute,
    });

    try page_mapper.mapPage(aligned_virt, page_flags);
}

/// Unmap a page and optionally free it
pub fn unmapPage(
    page_mapper: *paging.PageMapper,
    virt_addr: memory.VirtualAddress,
    free_physical: bool,
) !void {
    const aligned_virt = memory.alignDown(virt_addr);

    if (free_physical) {
        const flags = try page_mapper.getPageFlags(aligned_virt);
        if (flags.present) {
            const phys_addr = flags.getAddress();
            freePhysicalPage(phys_addr);
        }
    }

    try page_mapper.unmapPage(aligned_virt);
}

/// Copy data to mapped physical page
fn copyToPage(phys_addr: memory.PhysicalAddress, offset: usize, data: []const u8) void {
    const page_ptr: [*]u8 = @ptrFromInt(phys_addr);
    const dest = page_ptr[offset..offset + data.len];
    @memcpy(dest, data);
}

/// Zero-fill a range in physical memory
fn zeroPage(phys_addr: memory.PhysicalAddress, offset: usize, size: usize) void {
    const page_ptr: [*]u8 = @ptrFromInt(phys_addr);
    const dest = page_ptr[offset..offset + size];
    @memset(dest, 0);
}

// ============================================================================
// Complete ELF Segment Loader
// ============================================================================

pub const SegmentLoader = struct {
    /// Load an ELF segment with full memory allocation and mapping
    pub fn loadSegment(
        page_mapper: *paging.PageMapper,
        allocator: Basics.Allocator,
        phdr: *const exec.Elf64_Phdr,
        elf_data: []const u8,
    ) !void {
        const vaddr = phdr.p_vaddr;
        const memsz = phdr.p_memsz;
        const filesz = phdr.p_filesz;
        const offset = phdr.p_offset;
        const flags = phdr.p_flags;

        // Validate segment
        if (offset + filesz > elf_data.len) {
            return error.InvalidElfSegment;
        }

        // Determine page permissions
        const writable = (flags & exec.PF_W) != 0;
        const executable = (flags & exec.PF_X) != 0;
        const user = true; // User-space segments

        // W^X enforcement
        if (writable and executable) {
            return error.WriteAndExecuteNotAllowed;
        }

        // Calculate page-aligned range
        const page_size: u64 = memory.PAGE_SIZE;
        const start_page = memory.alignDown(vaddr);
        const end_addr = vaddr + memsz;
        const end_page = memory.alignUp(end_addr);
        const num_pages = (end_page - start_page) / page_size;

        // Allocate and map pages
        var page_addr = start_page;
        var file_offset = offset;
        var bytes_remaining = filesz;
        var mem_remaining = memsz;
        var page_idx: usize = 0;

        while (page_idx < num_pages) : (page_idx += 1) {
            // Allocate physical page
            const phys_page = try allocPhysicalPage();
            errdefer freePhysicalPage(phys_page);

            // Map page with appropriate permissions
            try mapPage(page_mapper, page_addr, phys_page, .{
                .writable = writable,
                .user = user,
                .no_execute = !executable,
            });

            // Calculate how much to copy to this page
            const page_start_offset = if (page_addr == start_page)
                vaddr - start_page
            else
                0;

            const page_available_size = page_size - page_start_offset;
            const copy_size = Basics.math.min(bytes_remaining, page_available_size);
            const zero_size = Basics.math.min(mem_remaining, page_available_size) - copy_size;

            // Copy file data to page
            if (copy_size > 0) {
                const segment_data = elf_data[file_offset..file_offset + copy_size];
                copyToPage(phys_page, page_start_offset, segment_data);

                file_offset += copy_size;
                bytes_remaining -= copy_size;
            }

            // Zero-fill remaining portion (BSS)
            if (zero_size > 0) {
                zeroPage(phys_page, page_start_offset + copy_size, zero_size);
            }

            mem_remaining -= (copy_size + zero_size);
            page_addr += page_size;
        }

        _ = allocator; // For future use with VMA tracking
    }

    /// Load all PT_LOAD segments from ELF
    pub fn loadAllSegments(
        page_mapper: *paging.PageMapper,
        allocator: Basics.Allocator,
        elf_data: []const u8,
    ) !u64 {
        // Parse ELF header
        if (elf_data.len < @sizeOf(exec.Elf64_Ehdr)) {
            return error.InvalidElf;
        }

        const ehdr = @as(*const exec.Elf64_Ehdr, @ptrCast(@alignCast(elf_data.ptr)));

        // Verify ELF magic
        if (!Basics.mem.eql(u8, ehdr.e_ident[0..4], &exec.ELF_MAGIC)) {
            return error.InvalidElfMagic;
        }

        // Verify 64-bit
        if (ehdr.e_ident[4] != 2) {
            return error.Not64BitElf;
        }

        // Get program headers
        const ph_offset = ehdr.e_phoff;
        const ph_num = ehdr.e_phnum;
        const ph_size = ehdr.e_phentsize;

        if (ph_offset + (ph_num * ph_size) > elf_data.len) {
            return error.InvalidProgramHeader;
        }

        // Load each PT_LOAD segment
        var i: usize = 0;
        while (i < ph_num) : (i += 1) {
            const ph_ptr = elf_data.ptr + ph_offset + (i * ph_size);
            const phdr = @as(*const exec.Elf64_Phdr, @ptrCast(@alignCast(ph_ptr)));

            if (phdr.p_type == exec.PT_LOAD) {
                try loadSegment(page_mapper, allocator, phdr, elf_data);
            }
        }

        return ehdr.e_entry;
    }
};

// ============================================================================
// Stack Setup with Actual Memory Allocation
// ============================================================================

pub const StackSetup = struct {
    /// Setup program stack with arguments and environment
    pub fn setupStack(
        page_mapper: *paging.PageMapper,
        allocator: Basics.Allocator,
        stack_base: u64,
        args: []const []const u8,
        envp: []const []const u8,
    ) !u64 {
        // Calculate required size
        const arg_size = calculateArgSize(args, envp);
        const stack_size = 2 * 1024 * 1024; // 2MB default stack
        const total_pages = (stack_size + memory.PAGE_SIZE - 1) / memory.PAGE_SIZE;

        // Allocate stack pages (from high to low address)
        var page_addr = stack_base - memory.PAGE_SIZE;
        var i: usize = 0;
        while (i < total_pages) : (i += 1) {
            const phys_page = try allocPhysicalPage();
            errdefer freePhysicalPage(phys_page);

            try mapPage(page_mapper, page_addr, phys_page, .{
                .writable = true,
                .user = true,
                .no_execute = true, // Stack is not executable (NX)
            });

            // Zero the page
            zeroPage(phys_page, 0, memory.PAGE_SIZE);

            page_addr -= memory.PAGE_SIZE;
        }

        // Setup argv/envp on stack following System V AMD64 ABI layout:
        // Stack layout (high to low):
        //   - environment strings
        //   - argument strings
        //   - NULL (envp terminator)
        //   - envp[n-1] ... envp[0] pointers
        //   - NULL (argv terminator)
        //   - argv[argc-1] ... argv[0] pointers
        //   - argc
        //   <- RSP points here

        _ = allocator;

        // Calculate positions for strings (write from top down)
        var string_ptr = stack_base;

        // First pass: write all strings and record their positions
        var arg_positions: [256]u64 = undefined;
        var env_positions: [256]u64 = undefined;

        // Write environment strings (backwards to preserve order)
        var env_idx: usize = envp.len;
        while (env_idx > 0) {
            env_idx -= 1;
            string_ptr -= envp[env_idx].len + 1; // +1 for null terminator
            const dest: [*]u8 = @ptrFromInt(string_ptr);
            @memcpy(dest[0..envp[env_idx].len], envp[env_idx]);
            dest[envp[env_idx].len] = 0; // null terminator
            env_positions[env_idx] = string_ptr;
        }

        // Write argument strings (backwards to preserve order)
        var arg_idx: usize = args.len;
        while (arg_idx > 0) {
            arg_idx -= 1;
            string_ptr -= args[arg_idx].len + 1;
            const dest: [*]u8 = @ptrFromInt(string_ptr);
            @memcpy(dest[0..args[arg_idx].len], args[arg_idx]);
            dest[args[arg_idx].len] = 0;
            arg_positions[arg_idx] = string_ptr;
        }

        // Align to 16 bytes for pointers
        string_ptr = string_ptr & ~@as(u64, 0xF);

        // Calculate pointer table position
        const total_ptrs = 1 + args.len + 1 + envp.len + 1; // argc + argv + NULL + envp + NULL
        var ptr_pos = string_ptr - (total_ptrs * @sizeOf(u64));
        ptr_pos = ptr_pos & ~@as(u64, 0xF); // Align to 16 bytes

        const stack_ptr = ptr_pos;

        // Write argc
        const argc_ptr: *u64 = @ptrFromInt(ptr_pos);
        argc_ptr.* = args.len;
        ptr_pos += @sizeOf(u64);

        // Write argv pointers
        for (0..args.len) |i| {
            const argv_ptr: *u64 = @ptrFromInt(ptr_pos);
            argv_ptr.* = arg_positions[i];
            ptr_pos += @sizeOf(u64);
        }
        // NULL terminator for argv
        const argv_null: *u64 = @ptrFromInt(ptr_pos);
        argv_null.* = 0;
        ptr_pos += @sizeOf(u64);

        // Write envp pointers
        for (0..envp.len) |i| {
            const envp_ptr: *u64 = @ptrFromInt(ptr_pos);
            envp_ptr.* = env_positions[i];
            ptr_pos += @sizeOf(u64);
        }
        // NULL terminator for envp
        const envp_null: *u64 = @ptrFromInt(ptr_pos);
        envp_null.* = 0;

        return stack_ptr;
    }

    fn calculateArgSize(args: []const []const u8, envp: []const []const u8) usize {
        var size: usize = 0;

        // Space for argv pointers (including NULL terminator)
        size += (args.len + 1) * @sizeOf(usize);

        // Space for envp pointers (including NULL terminator)
        size += (envp.len + 1) * @sizeOf(usize);

        // Space for arg strings
        for (args) |arg| {
            size += arg.len + 1;
        }

        // Space for env strings
        for (envp) |env| {
            size += env.len + 1;
        }

        // Align to 16 bytes
        return Basics.mem.alignForward(usize, size, 16);
    }
};

// ============================================================================
// Complete Process Loading
// ============================================================================

pub const ProcessLoader = struct {
    /// Load ELF executable into process with full memory setup
    pub fn loadProcess(
        proc: *process.Process,
        allocator: Basics.Allocator,
        elf_data: []const u8,
        args: []const []const u8,
        envp: []const []const u8,
    ) !u64 {
        // Load all ELF segments
        const entry_point = try SegmentLoader.loadAllSegments(
            &proc.address_space.page_mapper,
            allocator,
            elf_data,
        );

        // Setup stack with args/env
        const stack_ptr = try StackSetup.setupStack(
            &proc.address_space.page_mapper,
            allocator,
            proc.address_space.stack_base,
            args,
            envp,
        );

        _ = stack_ptr;

        return entry_point;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "map and unmap page" {
    const testing = Basics.testing;

    // Create a mock page mapper
    var page_mapper = paging.PageMapper.init(testing.allocator) catch return;
    defer page_mapper.deinit();

    const virt_addr: u64 = 0x400000;
    const phys_addr: u64 = 0x10000;

    try mapPage(&page_mapper, virt_addr, phys_addr, .{
        .writable = false,
        .user = true,
        .no_execute = false,
    });

    // Verify mapping exists
    const flags = try page_mapper.getPageFlags(virt_addr);
    try testing.expect(flags.present);
    try testing.expectEqual(phys_addr, flags.getAddress());
}

test "calculate arg size" {
    const args = [_][]const u8{ "program", "arg1" };
    const envp = [_][]const u8{ "PATH=/bin" };

    const size = StackSetup.calculateArgSize(&args, &envp);
    try Basics.testing.expect(size > 0);
    try Basics.testing.expect(size % 16 == 0);
}

test "W^X enforcement in segment loading" {
    const testing = Basics.testing;

    // Create ELF program header with both write and execute
    const bad_phdr = exec.Elf64_Phdr{
        .p_type = exec.PT_LOAD,
        .p_flags = exec.PF_R | exec.PF_W | exec.PF_X, // W+X violation
        .p_offset = 0,
        .p_vaddr = 0x400000,
        .p_paddr = 0,
        .p_filesz = 0x1000,
        .p_memsz = 0x1000,
        .p_align = 0x1000,
    };

    var page_mapper = paging.PageMapper.init(testing.allocator) catch return;
    defer page_mapper.deinit();

    const dummy_data = [_]u8{0} ** 0x1000;

    const result = SegmentLoader.loadSegment(
        &page_mapper,
        testing.allocator,
        &bad_phdr,
        &dummy_data,
    );

    try testing.expectError(error.WriteAndExecuteNotAllowed, result);
}
