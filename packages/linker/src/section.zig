// Home Programming Language - Linker Section Placement
// Defines sections for linker scripts

const std = @import("std");
const linker = @import("linker.zig");
const memory = @import("memory.zig");

pub const Section = struct {
    name: []const u8,
    section_type: linker.SectionType,
    flags: linker.SectionFlags,
    alignment: linker.Alignment,
    vma: ?u64, // Virtual memory address
    lma: ?u64, // Load memory address
    region: ?[]const u8, // Memory region name

    pub fn init(
        name: []const u8,
        section_type: linker.SectionType,
        flags: linker.SectionFlags,
    ) Section {
        return .{
            .name = name,
            .section_type = section_type,
            .flags = flags,
            .alignment = .Page,
            .vma = null,
            .lma = null,
            .region = null,
        };
    }

    pub fn withAlignment(self: Section, alignment: linker.Alignment) Section {
        var result = self;
        result.alignment = alignment;
        return result;
    }

    pub fn withVma(self: Section, vma: u64) Section {
        var result = self;
        result.vma = vma;
        return result;
    }

    pub fn withLma(self: Section, lma: u64) Section {
        var result = self;
        result.lma = lma;
        return result;
    }

    pub fn withRegion(self: Section, region: []const u8) Section {
        var result = self;
        result.region = region;
        return result;
    }

    pub fn isExecutable(self: Section) bool {
        return self.flags.executable or self.section_type == .Text;
    }

    pub fn isWritable(self: Section) bool {
        return self.flags.writable or self.section_type == .Data or self.section_type == .Bss;
    }

    pub fn isAllocated(self: Section) bool {
        return self.flags.alloc;
    }

    pub fn isLoaded(self: Section) bool {
        return self.flags.load;
    }

    pub fn format(
        self: Section,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try writer.print("  {s} ", .{self.name});

        if (self.vma) |vma| {
            try writer.print("0x{x:0>16} ", .{vma});
        }

        try writer.print(": ALIGN({d})", .{self.alignment.toBytes()});

        if (self.region) |region| {
            try writer.print(" > {s}", .{region});
        }

        if (self.lma) |lma| {
            try writer.print(" AT(0x{x:0>16})", .{lma});
        }
    }
};

// Standard section templates
pub const StandardSections = struct {
    // Text section (executable code)
    pub fn text() Section {
        return Section.init(
            ".text",
            .Text,
            .{
                .alloc = true,
                .load = true,
                .readonly = true,
                .code = true,
                .executable = true,
            },
        ).withAlignment(.Page);
    }

    // Read-only data section
    pub fn rodata() Section {
        return Section.init(
            ".rodata",
            .Rodata,
            .{
                .alloc = true,
                .load = true,
                .readonly = true,
                .data = true,
            },
        ).withAlignment(.Page);
    }

    // Initialized data section
    pub fn data() Section {
        return Section.init(
            ".data",
            .Data,
            .{
                .alloc = true,
                .load = true,
                .writable = true,
                .data = true,
            },
        ).withAlignment(.Page);
    }

    // Uninitialized data section
    pub fn bss() Section {
        return Section.init(
            ".bss",
            .Bss,
            .{
                .alloc = true,
                .writable = true,
                .data = true,
            },
        ).withAlignment(.Page);
    }

    // Thread-local initialized data
    pub fn tdata() Section {
        return Section.init(
            ".tdata",
            .TData,
            .{
                .alloc = true,
                .load = true,
                .writable = true,
                .data = true,
                .tls = true,
            },
        ).withAlignment(.DWord);
    }

    // Thread-local uninitialized data
    pub fn tbss() Section {
        return Section.init(
            ".tbss",
            .Tbss,
            .{
                .alloc = true,
                .writable = true,
                .data = true,
                .tls = true,
            },
        ).withAlignment(.DWord);
    }

    // Initialization code
    pub fn init_section() Section {
        return Section.init(
            ".init",
            .Init,
            .{
                .alloc = true,
                .load = true,
                .readonly = true,
                .code = true,
                .executable = true,
            },
        ).withAlignment(.Word);
    }

    // Finalization code
    pub fn fini() Section {
        return Section.init(
            ".fini",
            .Fini,
            .{
                .alloc = true,
                .load = true,
                .readonly = true,
                .code = true,
                .executable = true,
            },
        ).withAlignment(.Word);
    }

    // Debug information (not loaded)
    pub fn debug() Section {
        return Section.init(
            ".debug",
            .Debug,
            .{},
        ).withAlignment(.Byte);
    }

    // All standard sections for a typical kernel
    pub fn kernel_sections() [4]Section {
        return .{
            text(),
            rodata(),
            data(),
            bss(),
        };
    }

    // All standard sections including TLS
    pub fn full_sections() [6]Section {
        return .{
            text(),
            rodata(),
            data(),
            bss(),
            tdata(),
            tbss(),
        };
    }
};

// Section group for organizing related sections
pub const SectionGroup = struct {
    name: []const u8,
    sections: std.ArrayList(Section),
    base_vma: ?u64,
    region: ?[]const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, name: []const u8) SectionGroup {
        return .{
            .name = name,
            .sections = std.ArrayList(Section){},
            .base_vma = null,
            .region = null,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SectionGroup) void {
        self.sections.deinit(self.allocator);
    }

    pub fn add(self: *SectionGroup, section: Section) !void {
        try self.sections.append(self.allocator, section);
    }

    pub fn withBaseVma(self: *SectionGroup, vma: u64) *SectionGroup {
        self.base_vma = vma;
        return self;
    }

    pub fn withRegion(self: *SectionGroup, region: []const u8) *SectionGroup {
        self.region = region;
        return self;
    }

    pub fn build(self: *SectionGroup) ![]Section {
        var current_vma = self.base_vma orelse 0;

        for (self.sections.items) |*section| {
            if (section.vma == null and self.base_vma != null) {
                // Align current VMA
                current_vma = section.alignment.alignAddress(current_vma);
                section.vma = current_vma;
                // Move to next section (assume 4KB minimum)
                current_vma += 4096;
            }

            if (section.region == null and self.region != null) {
                section.region = self.region;
            }
        }

        return self.sections.toOwnedSlice(self.allocator);
    }
};

// Section layout builder
pub const SectionLayoutBuilder = struct {
    groups: std.ArrayList(SectionGroup),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) SectionLayoutBuilder {
        return .{
            .groups = std.ArrayList(SectionGroup){},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SectionLayoutBuilder) void {
        for (self.groups.items) |*group| {
            group.deinit();
        }
        self.groups.deinit(self.allocator);
    }

    pub fn addGroup(self: *SectionLayoutBuilder, group: SectionGroup) !void {
        try self.groups.append(self.allocator, group);
    }

    pub fn addStandardKernel(self: *SectionLayoutBuilder, base_vma: u64, region: []const u8) !void {
        var group = SectionGroup.init(self.allocator, "kernel");
        _ = group.withBaseVma(base_vma);
        _ = group.withRegion(region);

        const sections = StandardSections.kernel_sections();
        for (sections) |section| {
            try group.add(section);
        }

        try self.addGroup(group);
    }
};

// Tests
test "section basic operations" {
    const testing = std.testing;

    const section = StandardSections.text();

    try testing.expect(std.mem.eql(u8, section.name, ".text"));
    try testing.expectEqual(linker.SectionType.Text, section.section_type);
    try testing.expect(section.isExecutable());
    try testing.expect(!section.isWritable());
    try testing.expect(section.isAllocated());
    try testing.expect(section.isLoaded());
}

test "section with custom properties" {
    const testing = std.testing;

    const section = StandardSections.data()
        .withAlignment(.Page)
        .withVma(0x1000)
        .withRegion("kernel");

    try testing.expectEqual(linker.Alignment.Page, section.alignment);
    try testing.expectEqual(@as(u64, 0x1000), section.vma.?);
    try testing.expect(std.mem.eql(u8, section.region.?, "kernel"));
}

test "standard kernel sections" {
    const testing = std.testing;

    const sections = StandardSections.kernel_sections();

    try testing.expectEqual(@as(usize, 4), sections.len);
    try testing.expect(std.mem.eql(u8, sections[0].name, ".text"));
    try testing.expect(std.mem.eql(u8, sections[1].name, ".rodata"));
    try testing.expect(std.mem.eql(u8, sections[2].name, ".data"));
    try testing.expect(std.mem.eql(u8, sections[3].name, ".bss"));
}

test "section group" {
    const testing = std.testing;

    var group = SectionGroup.init(testing.allocator, "kernel");
    defer group.deinit();

    _ = group.withBaseVma(0x1000);
    _ = group.withRegion("kernel");

    try group.add(StandardSections.text());
    try group.add(StandardSections.rodata());

    const sections = try group.build();
    defer testing.allocator.free(sections);

    try testing.expectEqual(@as(usize, 2), sections.len);

    // Check that VMAs were assigned
    try testing.expect(sections[0].vma != null);
    try testing.expect(sections[1].vma != null);

    // Check that regions were assigned
    try testing.expect(std.mem.eql(u8, sections[0].region.?, "kernel"));
    try testing.expect(std.mem.eql(u8, sections[1].region.?, "kernel"));
}

test "section alignment" {
    const testing = std.testing;

    var group = SectionGroup.init(testing.allocator, "test");
    defer group.deinit();

    _ = group.withBaseVma(0x1000);

    try group.add(StandardSections.text().withAlignment(.Page));
    try group.add(StandardSections.data().withAlignment(.Page));

    const sections = try group.build();
    defer testing.allocator.free(sections);

    // Check alignment
    try testing.expect(linker.isAligned(sections[0].vma.?, sections[0].alignment));
    try testing.expect(linker.isAligned(sections[1].vma.?, sections[1].alignment));
}

test "TLS sections" {
    const testing = std.testing;

    const tdata = StandardSections.tdata();
    const tbss = StandardSections.tbss();

    try testing.expect(tdata.flags.tls);
    try testing.expect(tbss.flags.tls);
    try testing.expectEqual(linker.SectionType.TData, tdata.section_type);
    try testing.expectEqual(linker.SectionType.Tbss, tbss.section_type);
}
