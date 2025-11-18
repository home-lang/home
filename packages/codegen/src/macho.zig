const std = @import("std");

/// Mach-O 64-bit file format writer for macOS
pub const MachOWriter = struct {
    allocator: std.mem.Allocator,
    code: []const u8,
    entry_point: u64,

    // Mach-O constants
    const MH_MAGIC_64: u32 = 0xfeedfacf;
    const CPU_TYPE_X86_64: i32 = 0x01000007;
    const CPU_SUBTYPE_X86_64_ALL: i32 = 3;
    const MH_EXECUTE: u32 = 2;
    const MH_NOUNDEFS: u32 = 1;
    const LC_SEGMENT_64: u32 = 0x19;
    const LC_MAIN: u32 = 0x80000028;
    const VM_PROT_READ: u32 = 1;
    const VM_PROT_WRITE: u32 = 2;
    const VM_PROT_EXECUTE: u32 = 4;

    pub fn init(allocator: std.mem.Allocator, code: []const u8) MachOWriter {
        return .{
            .allocator = allocator,
            .code = code,
            .entry_point = 0x100000000 + 0x1000, // Standard macOS load address + offset
        };
    }

    pub fn write(self: *MachOWriter, path: []const u8) !void {
        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        // Calculate sizes
        const page_size: u64 = 0x1000;
        const code_size_aligned = std.mem.alignForward(u64, self.code.len, page_size);

        // Write Mach-O header
        try self.writeMachHeader(file);

        // Write segment command for __TEXT segment
        try self.writeSegmentCommand(file, code_size_aligned);

        // Write LC_MAIN command (entry point)
        try self.writeMainCommand(file);

        // Write code at page boundary
        try file.seekTo(0x1000);
        try file.writeAll(self.code);

        // Pad to page boundary
        const padding_size = code_size_aligned - self.code.len;
        if (padding_size > 0) {
            const padding = try self.allocator.alloc(u8, padding_size);
            defer self.allocator.free(padding);
            @memset(padding, 0);
            try file.writeAll(padding);
        }

        // Make executable
        try file.chmod(0o755);
    }

    fn writeMachHeader(self: *MachOWriter, file: std.fs.File) !void {
        _ = self;
        var header: [32]u8 = undefined;
        @memset(&header, 0);

        // magic
        std.mem.writeInt(u32, header[0..4], MH_MAGIC_64, .little);

        // cputype
        std.mem.writeInt(i32, header[4..8], CPU_TYPE_X86_64, .little);

        // cpusubtype
        std.mem.writeInt(i32, header[8..12], CPU_SUBTYPE_X86_64_ALL, .little);

        // filetype
        std.mem.writeInt(u32, header[12..16], MH_EXECUTE, .little);

        // ncmds - number of load commands (2: segment + thread)
        std.mem.writeInt(u32, header[16..20], 2, .little);

        // sizeofcmds - total size of load commands
        const segment_cmd_size: u32 = 72; // LC_SEGMENT_64 size
        const main_cmd_size: u32 = 24; // LC_MAIN size
        std.mem.writeInt(u32, header[20..24], segment_cmd_size + main_cmd_size, .little);

        // flags
        std.mem.writeInt(u32, header[24..28], MH_NOUNDEFS, .little);

        // reserved
        std.mem.writeInt(u32, header[28..32], 0, .little);

        try file.writeAll(&header);
    }

    fn writeSegmentCommand(self: *MachOWriter, file: std.fs.File, code_size: u64) !void {
        _ = self;
        var cmd: [72]u8 = undefined;
        @memset(&cmd, 0);

        // cmd
        std.mem.writeInt(u32, cmd[0..4], LC_SEGMENT_64, .little);

        // cmdsize
        std.mem.writeInt(u32, cmd[4..8], 72, .little);

        // segname - "__TEXT" (16 bytes, null-padded)
        @memcpy(cmd[8..14], "__TEXT");

        // vmaddr
        std.mem.writeInt(u64, cmd[24..32], 0x100000000, .little);

        // vmsize
        std.mem.writeInt(u64, cmd[32..40], code_size + 0x1000, .little);

        // fileoff
        std.mem.writeInt(u64, cmd[40..48], 0, .little);

        // filesize
        std.mem.writeInt(u64, cmd[48..56], code_size + 0x1000, .little);

        // maxprot
        std.mem.writeInt(i32, cmd[56..60], @as(i32, @intCast(VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE)), .little);

        // initprot
        std.mem.writeInt(i32, cmd[60..64], @as(i32, @intCast(VM_PROT_READ | VM_PROT_EXECUTE)), .little);

        // nsects - number of sections
        std.mem.writeInt(u32, cmd[64..68], 0, .little);

        // flags
        std.mem.writeInt(u32, cmd[68..72], 0, .little);

        try file.writeAll(&cmd);
    }

    fn writeMainCommand(self: *MachOWriter, file: std.fs.File) !void {
        var cmd: [24]u8 = undefined;
        @memset(&cmd, 0);

        // cmd
        std.mem.writeInt(u32, cmd[0..4], LC_MAIN, .little);

        // cmdsize
        std.mem.writeInt(u32, cmd[4..8], 24, .little);

        // entryoff - offset of main() from start of __TEXT segment
        std.mem.writeInt(u64, cmd[8..16], 0x1000, .little); // Code starts at offset 0x1000

        // stacksize - initial stack size (0 = use default)
        std.mem.writeInt(u64, cmd[16..24], 0, .little);

        try file.writeAll(&cmd);
    }
};
