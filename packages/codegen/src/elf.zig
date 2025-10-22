const std = @import("std");

/// ELF64 file format writer
pub const ElfWriter = struct {
    allocator: std.mem.Allocator,
    code: []const u8,
    entry_point: u64,

    pub fn init(allocator: std.mem.Allocator, code: []const u8) ElfWriter {
        return .{
            .allocator = allocator,
            .code = code,
            .entry_point = 0x401000, // Standard Linux load address + offset
        };
    }

    pub fn write(self: *ElfWriter, path: []const u8) !void {
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        // Write ELF header
        try self.writeElfHeader(file);

        // Write program header
        try self.writeProgramHeader(file);

        // Write code
        try file.seekTo(0x1000); // Align to page boundary
        try file.writeAll(self.code);

        // Make executable - use chmod on the file directly
        try file.chmod(0o755);
    }

    fn writeElfHeader(self: *ElfWriter, file: std.fs.File) !void {
        var header: [64]u8 = undefined;
        @memset(&header, 0);

        // ELF magic number
        header[0] = 0x7F;
        header[1] = 'E';
        header[2] = 'L';
        header[3] = 'F';

        // 64-bit, little-endian, current version
        header[4] = 2; // 64-bit
        header[5] = 1; // Little endian
        header[6] = 1; // Current ELF version
        header[7] = 0; // System V ABI

        // e_type: ET_EXEC (executable file)
        std.mem.writeInt(u16, header[16..18], 2, .little);

        // e_machine: x86-64
        std.mem.writeInt(u16, header[18..20], 0x3E, .little);

        // e_version: EV_CURRENT
        std.mem.writeInt(u32, header[20..24], 1, .little);

        // e_entry: entry point address
        std.mem.writeInt(u64, header[24..32], self.entry_point, .little);

        // e_phoff: program header offset
        std.mem.writeInt(u64, header[32..40], 64, .little); // Right after ELF header

        // e_shoff: section header offset (0 = none)
        std.mem.writeInt(u64, header[40..48], 0, .little);

        // e_flags: processor-specific flags
        std.mem.writeInt(u32, header[48..52], 0, .little);

        // e_ehsize: ELF header size
        std.mem.writeInt(u16, header[52..54], 64, .little);

        // e_phentsize: program header entry size
        std.mem.writeInt(u16, header[54..56], 56, .little);

        // e_phnum: number of program header entries
        std.mem.writeInt(u16, header[56..58], 1, .little);

        // e_shentsize: section header entry size
        std.mem.writeInt(u16, header[58..60], 0, .little);

        // e_shnum: number of section header entries
        std.mem.writeInt(u16, header[60..62], 0, .little);

        // e_shstrndx: section header string table index
        std.mem.writeInt(u16, header[62..64], 0, .little);

        try file.writeAll(&header);
    }

    fn writeProgramHeader(self: *ElfWriter, file: std.fs.File) !void {
        _ = self;
        var header: [56]u8 = undefined;
        @memset(&header, 0);

        // p_type: PT_LOAD (loadable segment)
        std.mem.writeInt(u32, header[0..4], 1, .little);

        // p_flags: PF_X | PF_R (executable + readable)
        std.mem.writeInt(u32, header[4..8], 5, .little);

        // p_offset: segment file offset
        std.mem.writeInt(u64, header[8..16], 0x1000, .little); // Page-aligned

        // p_vaddr: virtual address
        std.mem.writeInt(u64, header[16..24], 0x401000, .little);

        // p_paddr: physical address (same as virtual for most cases)
        std.mem.writeInt(u64, header[24..32], 0x401000, .little);

        // p_filesz: segment size in file
        std.mem.writeInt(u64, header[32..40], 0x1000, .little); // One page

        // p_memsz: segment size in memory
        std.mem.writeInt(u64, header[40..48], 0x1000, .little);

        // p_align: segment alignment
        std.mem.writeInt(u64, header[48..56], 0x1000, .little); // Page alignment

        try file.writeAll(&header);
    }
};
