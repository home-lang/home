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
    const LC_LOAD_DYLIB: u32 = 0xC;
    const LC_LOAD_DYLINKER: u32 = 0xE;
    const LC_SYMTAB: u32 = 0x2;
    const LC_DYSYMTAB: u32 = 0xB;
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
        try self.writeWithEntryPoint(path, 0);
    }

    pub fn writeWithEntryPoint(self: *MachOWriter, path: []const u8, entry_offset: u64) !void {
        self.entry_point = 0x100000000 + 0x1000 + entry_offset;

        const file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        // Calculate sizes
        const page_size: u64 = 0x1000;
        const code_size_aligned = std.mem.alignForward(u64, self.code.len, page_size);

        // Write Mach-O header
        try self.writeMachHeader(file);

        // Write __PAGEZERO segment (required by modern macOS)
        try self.writePageZeroSegment(file);

        // Write segment command for __TEXT segment
        try self.writeTextSegment(file, code_size_aligned);

        // Write __LINKEDIT segment (for symbol tables)
        try self.writeLinkedItSegment(file, code_size_aligned);

        // Write LC_LOAD_DYLINKER command (required to specify dyld)
        try self.writeLoadDylinker(file);

        // Write LC_MAIN command (entry point)
        try self.writeMainCommand(file, entry_offset);

        // Write LC_LOAD_DYLIB for libSystem
        try self.writeLoadDylib(file);

        // Write symbol table command
        try self.writeSymtabCommand(file, code_size_aligned);

        // Write dynamic symbol table command
        try self.writeDysymtabCommand(file);

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

        // Write LINKEDIT data (minimal symbol table)
        const linkedit_offset = code_size_aligned + 0x1000;
        try file.seekTo(linkedit_offset);
        const null_byte: [1]u8 = .{0};
        try file.writeAll(&null_byte);

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

        // ncmds - number of load commands
        // PAGEZERO + TEXT + LINKEDIT + LOAD_DYLINKER + MAIN + LOAD_DYLIB + SYMTAB + DYSYMTAB = 8
        std.mem.writeInt(u32, header[16..20], 8, .little);

        // sizeofcmds - total size of load commands
        const pagezero_size: u32 = 72;
        const text_segment_size: u32 = 152; // Includes __text section (72 + 80)
        const linkedit_size: u32 = 72;
        const dylinker_cmd_size: u32 = 32; // LC_LOAD_DYLINKER for /usr/lib/dyld
        const main_cmd_size: u32 = 24;
        const dylib_cmd_size: u32 = 56; // Includes path string
        const symtab_size: u32 = 24;
        const dysymtab_size: u32 = 80;
        const total_cmd_size = pagezero_size + text_segment_size + linkedit_size +
                               dylinker_cmd_size + main_cmd_size + dylib_cmd_size + symtab_size + dysymtab_size;
        std.mem.writeInt(u32, header[20..24], total_cmd_size, .little);

        // flags
        std.mem.writeInt(u32, header[24..28], MH_NOUNDEFS, .little);

        // reserved
        std.mem.writeInt(u32, header[28..32], 0, .little);

        try file.writeAll(&header);
    }

    fn writePageZeroSegment(self: *MachOWriter, file: std.fs.File) !void {
        _ = self;
        var cmd: [72]u8 = undefined;
        @memset(&cmd, 0);

        std.mem.writeInt(u32, cmd[0..4], LC_SEGMENT_64, .little);
        std.mem.writeInt(u32, cmd[4..8], 72, .little);
        @memcpy(cmd[8..18], "__PAGEZERO");
        std.mem.writeInt(u64, cmd[24..32], 0, .little); // vmaddr
        std.mem.writeInt(u64, cmd[32..40], 0x100000000, .little); // vmsize - 4GB
        std.mem.writeInt(u64, cmd[40..48], 0, .little); // fileoff
        std.mem.writeInt(u64, cmd[48..56], 0, .little); // filesize
        std.mem.writeInt(i32, cmd[56..60], 0, .little); // maxprot
        std.mem.writeInt(i32, cmd[60..64], 0, .little); // initprot

        try file.writeAll(&cmd);
    }

    fn writeTextSegment(self: *MachOWriter, file: std.fs.File, code_size: u64) !void {
        _ = self;
        // Segment command (72 bytes) + section header (80 bytes) = 152 bytes
        var cmd: [152]u8 = undefined;
        @memset(&cmd, 0);

        // Segment command
        std.mem.writeInt(u32, cmd[0..4], LC_SEGMENT_64, .little);
        std.mem.writeInt(u32, cmd[4..8], 152, .little); // cmdsize includes section
        @memcpy(cmd[8..14], "__TEXT");
        std.mem.writeInt(u64, cmd[24..32], 0x100000000, .little); // vmaddr
        std.mem.writeInt(u64, cmd[32..40], code_size + 0x1000, .little); // vmsize
        std.mem.writeInt(u64, cmd[40..48], 0, .little); // fileoff
        std.mem.writeInt(u64, cmd[48..56], code_size + 0x1000, .little); // filesize
        std.mem.writeInt(i32, cmd[56..60], @as(i32, @intCast(VM_PROT_READ | VM_PROT_EXECUTE)), .little); // maxprot (no write)
        std.mem.writeInt(i32, cmd[60..64], @as(i32, @intCast(VM_PROT_READ | VM_PROT_EXECUTE)), .little); // initprot
        std.mem.writeInt(u32, cmd[64..68], 1, .little); // nsects - 1 section (__text)
        std.mem.writeInt(u32, cmd[68..72], 0, .little); // flags

        // __text section header (80 bytes starting at offset 72)
        @memcpy(cmd[72..78], "__text"); // sectname (0-15, using 0-5)
        @memcpy(cmd[88..94], "__TEXT"); // segname (16-31, using 16-21)
        std.mem.writeInt(u64, cmd[104..112], 0x100000000 + 0x1000, .little); // addr (32-39)
        std.mem.writeInt(u64, cmd[112..120], code_size, .little); // size (40-47)
        std.mem.writeInt(u32, cmd[120..124], 0x1000, .little); // offset in file (48-51)
        std.mem.writeInt(u32, cmd[124..128], 2, .little); // align (52-55) - 2^2 = 4 bytes
        std.mem.writeInt(u32, cmd[128..132], 0, .little); // reloff (56-59)
        std.mem.writeInt(u32, cmd[132..136], 0, .little); // nreloc (60-63)
        std.mem.writeInt(u32, cmd[136..140], 0x80000400, .little); // flags (64-67)
        std.mem.writeInt(u32, cmd[140..144], 0, .little); // reserved1 (68-71)
        std.mem.writeInt(u32, cmd[144..148], 0, .little); // reserved2 (72-75)
        std.mem.writeInt(u32, cmd[148..152], 0, .little); // reserved3 (76-79)

        try file.writeAll(&cmd);
    }

    fn writeLinkedItSegment(self: *MachOWriter, file: std.fs.File, code_size: u64) !void {
        _ = self;
        var cmd: [72]u8 = undefined;
        @memset(&cmd, 0);

        const linkedit_offset = code_size + 0x1000;
        std.mem.writeInt(u32, cmd[0..4], LC_SEGMENT_64, .little);
        std.mem.writeInt(u32, cmd[4..8], 72, .little);
        @memcpy(cmd[8..18], "__LINKEDIT");
        std.mem.writeInt(u64, cmd[24..32], 0x100000000 + linkedit_offset, .little); // vmaddr
        std.mem.writeInt(u64, cmd[32..40], 0x1000, .little); // vmsize - 4KB for symbols
        std.mem.writeInt(u64, cmd[40..48], linkedit_offset, .little); // fileoff
        std.mem.writeInt(u64, cmd[48..56], 1, .little); // filesize - just 1 null byte
        std.mem.writeInt(i32, cmd[56..60], @as(i32, @intCast(VM_PROT_READ)), .little); // maxprot
        std.mem.writeInt(i32, cmd[60..64], @as(i32, @intCast(VM_PROT_READ)), .little); // initprot

        try file.writeAll(&cmd);
    }

    fn writeLoadDylinker(self: *MachOWriter, file: std.fs.File) !void {
        _ = self;
        var cmd: [32]u8 = undefined;
        @memset(&cmd, 0);

        // LC_LOAD_DYLINKER command
        std.mem.writeInt(u32, cmd[0..4], LC_LOAD_DYLINKER, .little);
        std.mem.writeInt(u32, cmd[4..8], 32, .little); // cmdsize

        // name offset (after the command header, at byte 12)
        std.mem.writeInt(u32, cmd[8..12], 12, .little);

        // dylinker path: "/usr/lib/dyld" (14 bytes including null terminator)
        const dylinker_path = "/usr/lib/dyld";
        @memcpy(cmd[12..12 + dylinker_path.len], dylinker_path);
        // Null terminator and padding already set by @memset

        try file.writeAll(&cmd);
    }

    fn writeMainCommand(self: *MachOWriter, file: std.fs.File, entry_offset: u64) !void {
        _ = self;
        var cmd: [24]u8 = undefined;
        @memset(&cmd, 0);

        // cmd
        std.mem.writeInt(u32, cmd[0..4], LC_MAIN, .little);

        // cmdsize
        std.mem.writeInt(u32, cmd[4..8], 24, .little);

        // entryoff - offset of main() from start of __TEXT segment
        std.mem.writeInt(u64, cmd[8..16], 0x1000 + entry_offset, .little);

        // stacksize - initial stack size (0 = use default)
        std.mem.writeInt(u64, cmd[16..24], 0, .little);

        try file.writeAll(&cmd);
    }

    fn writeLoadDylib(self: *MachOWriter, file: std.fs.File) !void {
        _ = self;
        var cmd: [56]u8 = undefined;
        @memset(&cmd, 0);

        // LC_LOAD_DYLIB command
        std.mem.writeInt(u32, cmd[0..4], LC_LOAD_DYLIB, .little);
        std.mem.writeInt(u32, cmd[4..8], 56, .little); // cmdsize

        // dylib structure
        std.mem.writeInt(u32, cmd[8..12], 24, .little); // name offset (after dylib struct)
        std.mem.writeInt(u32, cmd[12..16], 0x00010000, .little); // timestamp (ignored)
        std.mem.writeInt(u32, cmd[16..20], 0x00010000, .little); // current_version
        std.mem.writeInt(u32, cmd[20..24], 0x00010000, .little); // compatibility_version

        // dylib path: "/usr/lib/libSystem.B.dylib"
        const dylib_path = "/usr/lib/libSystem.B.dylib";
        @memcpy(cmd[24..24 + dylib_path.len], dylib_path);

        try file.writeAll(&cmd);
    }

    fn writeSymtabCommand(self: *MachOWriter, file: std.fs.File, code_size: u64) !void {
        _ = self;
        var cmd: [24]u8 = undefined;
        @memset(&cmd, 0);

        const linkedit_offset = code_size + 0x1000;
        std.mem.writeInt(u32, cmd[0..4], LC_SYMTAB, .little);
        std.mem.writeInt(u32, cmd[4..8], 24, .little); // cmdsize
        std.mem.writeInt(u32, cmd[8..12], @intCast(linkedit_offset), .little); // symoff
        std.mem.writeInt(u32, cmd[12..16], 0, .little); // nsyms - no symbols for now
        std.mem.writeInt(u32, cmd[16..20], @intCast(linkedit_offset), .little); // stroff
        std.mem.writeInt(u32, cmd[20..24], 1, .little); // strsize - just null byte

        try file.writeAll(&cmd);
    }

    fn writeDysymtabCommand(self: *MachOWriter, file: std.fs.File) !void {
        _ = self;
        var cmd: [80]u8 = undefined;
        @memset(&cmd, 0);

        std.mem.writeInt(u32, cmd[0..4], LC_DYSYMTAB, .little);
        std.mem.writeInt(u32, cmd[4..8], 80, .little); // cmdsize
        // Rest of fields are 0 for minimal binary

        try file.writeAll(&cmd);
    }
};
