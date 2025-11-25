// Home OS Kernel - Procfs (Process Filesystem)
// Virtual filesystem providing process and system information

const Basics = @import("basics");
const vfs = @import("vfs.zig");
const process = @import("process.zig");
const sync = @import("sync.zig");
const atomic = @import("atomic.zig");
const vfs_sync = @import("vfs_sync.zig");

// ============================================================================
// Procfs File Types
// ============================================================================

/// Types of procfs entries
const ProcfsEntryType = enum {
    /// Root /proc directory
    Root,
    /// Per-process directory /proc/[pid]
    ProcessDir,
    /// /proc/self symlink
    SelfLink,
    /// /proc/[pid]/status
    ProcStatus,
    /// /proc/[pid]/cmdline
    ProcCmdline,
    /// /proc/[pid]/stat
    ProcStat,
    /// /proc/[pid]/statm
    ProcStatm,
    /// /proc/[pid]/maps
    ProcMaps,
    /// /proc/[pid]/fd directory
    ProcFd,
    /// /proc/[pid]/cwd symlink
    ProcCwd,
    /// /proc/[pid]/exe symlink
    ProcExe,
    /// /proc/[pid]/environ
    ProcEnviron,
    /// /proc/cpuinfo
    CpuInfo,
    /// /proc/meminfo
    MemInfo,
    /// /proc/uptime
    Uptime,
    /// /proc/version
    Version,
    /// /proc/loadavg
    LoadAvg,
    /// /proc/stat (system stats)
    SysStat,
    /// /proc/filesystems
    Filesystems,
    /// /proc/mounts
    Mounts,
    /// /proc/interrupts
    Interrupts,
    /// /proc/net directory
    NetDir,
};

/// Procfs-specific inode data
const ProcfsInodeData = struct {
    entry_type: ProcfsEntryType,
    /// PID for process-specific entries (0 for global)
    pid: u32,
    /// Cached content (for generated files)
    cached_content: ?[]const u8,
    /// Cache timestamp
    cache_time: u64,
    /// Allocator for dynamic content
    allocator: Basics.Allocator,

    pub fn init(allocator: Basics.Allocator, entry_type: ProcfsEntryType, pid: u32) ProcfsInodeData {
        return .{
            .entry_type = entry_type,
            .pid = pid,
            .cached_content = null,
            .cache_time = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ProcfsInodeData) void {
        if (self.cached_content) |content| {
            self.allocator.free(content);
        }
    }
};

// ============================================================================
// Procfs Directory Entries
// ============================================================================

/// Static entries in /proc root
const RootDirEntry = struct {
    name: []const u8,
    entry_type: ProcfsEntryType,
    inode_type: vfs.InodeType,
};

const root_static_entries = [_]RootDirEntry{
    .{ .name = "self", .entry_type = .SelfLink, .inode_type = .Symlink },
    .{ .name = "cpuinfo", .entry_type = .CpuInfo, .inode_type = .Regular },
    .{ .name = "meminfo", .entry_type = .MemInfo, .inode_type = .Regular },
    .{ .name = "uptime", .entry_type = .Uptime, .inode_type = .Regular },
    .{ .name = "version", .entry_type = .Version, .inode_type = .Regular },
    .{ .name = "loadavg", .entry_type = .LoadAvg, .inode_type = .Regular },
    .{ .name = "stat", .entry_type = .SysStat, .inode_type = .Regular },
    .{ .name = "filesystems", .entry_type = .Filesystems, .inode_type = .Regular },
    .{ .name = "mounts", .entry_type = .Mounts, .inode_type = .Regular },
    .{ .name = "interrupts", .entry_type = .Interrupts, .inode_type = .Regular },
    .{ .name = "net", .entry_type = .NetDir, .inode_type = .Directory },
};

/// Entries in /proc/[pid] directory
const ProcessDirEntry = struct {
    name: []const u8,
    entry_type: ProcfsEntryType,
    inode_type: vfs.InodeType,
};

const process_dir_entries = [_]ProcessDirEntry{
    .{ .name = "status", .entry_type = .ProcStatus, .inode_type = .Regular },
    .{ .name = "cmdline", .entry_type = .ProcCmdline, .inode_type = .Regular },
    .{ .name = "stat", .entry_type = .ProcStat, .inode_type = .Regular },
    .{ .name = "statm", .entry_type = .ProcStatm, .inode_type = .Regular },
    .{ .name = "maps", .entry_type = .ProcMaps, .inode_type = .Regular },
    .{ .name = "fd", .entry_type = .ProcFd, .inode_type = .Directory },
    .{ .name = "cwd", .entry_type = .ProcCwd, .inode_type = .Symlink },
    .{ .name = "exe", .entry_type = .ProcExe, .inode_type = .Symlink },
    .{ .name = "environ", .entry_type = .ProcEnviron, .inode_type = .Regular },
};

// ============================================================================
// Procfs Superblock
// ============================================================================

var procfs_superblock: ?*vfs.Superblock = null;
var procfs_root_inode: ?*vfs.Inode = null;
var next_inode_num: atomic.AtomicU64 = atomic.AtomicU64.init(1);
var procfs_lock: sync.Spinlock = sync.Spinlock.init();

/// Get next inode number
fn allocInodeNum() u64 {
    return next_inode_num.fetchAdd(1, .SeqCst);
}

// ============================================================================
// Content Generators
// ============================================================================

/// Generate /proc/cpuinfo content
fn generateCpuInfo(allocator: Basics.Allocator) ![]const u8 {
    var buffer = Basics.ArrayList(u8).init(allocator);
    const writer = buffer.writer();

    // Get CPU info from system
    const cpu_count = getCpuCount();

    for (0..cpu_count) |i| {
        try writer.print("processor\t: {d}\n", .{i});
        try writer.print("vendor_id\t: Home\n", .{});
        try writer.print("cpu family\t: 6\n", .{});
        try writer.print("model\t\t: 1\n", .{});
        try writer.print("model name\t: Home Virtual CPU\n", .{});
        try writer.print("stepping\t: 1\n", .{});
        try writer.print("cpu MHz\t\t: {d}.000\n", .{getCpuMhz()});
        try writer.print("cache size\t: 4096 KB\n", .{});
        try writer.print("physical id\t: 0\n", .{});
        try writer.print("siblings\t: {d}\n", .{cpu_count});
        try writer.print("core id\t\t: {d}\n", .{i});
        try writer.print("cpu cores\t: {d}\n", .{cpu_count});
        try writer.print("flags\t\t: fpu vme de pse tsc msr pae mce cx8 apic\n", .{});
        try writer.print("\n", .{});
    }

    return buffer.toOwnedSlice();
}

/// Generate /proc/meminfo content
fn generateMemInfo(allocator: Basics.Allocator) ![]const u8 {
    var buffer = Basics.ArrayList(u8).init(allocator);
    const writer = buffer.writer();

    const mem_stats = getMemoryStats();

    try writer.print("MemTotal:       {d:>8} kB\n", .{mem_stats.total / 1024});
    try writer.print("MemFree:        {d:>8} kB\n", .{mem_stats.free / 1024});
    try writer.print("MemAvailable:   {d:>8} kB\n", .{mem_stats.available / 1024});
    try writer.print("Buffers:        {d:>8} kB\n", .{mem_stats.buffers / 1024});
    try writer.print("Cached:         {d:>8} kB\n", .{mem_stats.cached / 1024});
    try writer.print("SwapCached:     {d:>8} kB\n", .{mem_stats.swap_cached / 1024});
    try writer.print("Active:         {d:>8} kB\n", .{mem_stats.active / 1024});
    try writer.print("Inactive:       {d:>8} kB\n", .{mem_stats.inactive / 1024});
    try writer.print("SwapTotal:      {d:>8} kB\n", .{mem_stats.swap_total / 1024});
    try writer.print("SwapFree:       {d:>8} kB\n", .{mem_stats.swap_free / 1024});
    try writer.print("Dirty:          {d:>8} kB\n", .{mem_stats.dirty / 1024});
    try writer.print("Writeback:      {d:>8} kB\n", .{mem_stats.writeback / 1024});
    try writer.print("Slab:           {d:>8} kB\n", .{mem_stats.slab / 1024});
    try writer.print("PageTables:     {d:>8} kB\n", .{mem_stats.page_tables / 1024});

    return buffer.toOwnedSlice();
}

/// Generate /proc/uptime content
fn generateUptime(allocator: Basics.Allocator) ![]const u8 {
    var buffer = Basics.ArrayList(u8).init(allocator);
    const writer = buffer.writer();

    const uptime_secs = getUptimeSeconds();
    const idle_secs = getIdleSeconds();

    // Format: uptime_secs idle_secs
    try writer.print("{d}.{d:0>2} {d}.{d:0>2}\n", .{
        uptime_secs / 100,
        uptime_secs % 100,
        idle_secs / 100,
        idle_secs % 100,
    });

    return buffer.toOwnedSlice();
}

/// Generate /proc/version content
fn generateVersion(allocator: Basics.Allocator) ![]const u8 {
    var buffer = Basics.ArrayList(u8).init(allocator);
    const writer = buffer.writer();

    try writer.print("Home OS version 0.1.0 (home@localhost) (zigc version 0.11.0) #1 SMP PREEMPT\n", .{});

    return buffer.toOwnedSlice();
}

/// Generate /proc/loadavg content
fn generateLoadAvg(allocator: Basics.Allocator) ![]const u8 {
    var buffer = Basics.ArrayList(u8).init(allocator);
    const writer = buffer.writer();

    const load = getLoadAverage();
    const running = getRunningProcesses();
    const total = getTotalProcesses();
    const last_pid = getLastPid();

    try writer.print("{d}.{d:0>2} {d}.{d:0>2} {d}.{d:0>2} {d}/{d} {d}\n", .{
        load.one_min / 100,
        load.one_min % 100,
        load.five_min / 100,
        load.five_min % 100,
        load.fifteen_min / 100,
        load.fifteen_min % 100,
        running,
        total,
        last_pid,
    });

    return buffer.toOwnedSlice();
}

/// Generate /proc/stat content (system statistics)
fn generateSysStat(allocator: Basics.Allocator) ![]const u8 {
    var buffer = Basics.ArrayList(u8).init(allocator);
    const writer = buffer.writer();

    const stats = getSystemStats();

    // CPU times (user, nice, system, idle, iowait, irq, softirq)
    try writer.print("cpu  {d} {d} {d} {d} {d} {d} {d} 0 0 0\n", .{
        stats.cpu_user,
        stats.cpu_nice,
        stats.cpu_system,
        stats.cpu_idle,
        stats.cpu_iowait,
        stats.cpu_irq,
        stats.cpu_softirq,
    });

    // Per-CPU stats
    for (0..getCpuCount()) |i| {
        try writer.print("cpu{d} {d} {d} {d} {d} {d} {d} {d} 0 0 0\n", .{
            i,
            stats.cpu_user / getCpuCount(),
            stats.cpu_nice / getCpuCount(),
            stats.cpu_system / getCpuCount(),
            stats.cpu_idle / getCpuCount(),
            stats.cpu_iowait / getCpuCount(),
            stats.cpu_irq / getCpuCount(),
            stats.cpu_softirq / getCpuCount(),
        });
    }

    try writer.print("intr {d}\n", .{stats.interrupts});
    try writer.print("ctxt {d}\n", .{stats.context_switches});
    try writer.print("btime {d}\n", .{stats.boot_time});
    try writer.print("processes {d}\n", .{stats.processes});
    try writer.print("procs_running {d}\n", .{stats.procs_running});
    try writer.print("procs_blocked {d}\n", .{stats.procs_blocked});

    return buffer.toOwnedSlice();
}

/// Generate /proc/[pid]/status content
fn generateProcessStatus(allocator: Basics.Allocator, pid: u32) ![]const u8 {
    const proc = process.findProcess(pid) orelse return error.NoSuchProcess;

    var buffer = Basics.ArrayList(u8).init(allocator);
    const writer = buffer.writer();

    try writer.print("Name:\t{s}\n", .{proc.name});
    try writer.print("State:\t{c}\n", .{processStateChar(proc.state)});
    try writer.print("Pid:\t{d}\n", .{proc.pid});
    try writer.print("PPid:\t{d}\n", .{proc.ppid});
    try writer.print("Uid:\t{d}\t{d}\t{d}\t{d}\n", .{ proc.uid, proc.euid, proc.suid, proc.fsuid });
    try writer.print("Gid:\t{d}\t{d}\t{d}\t{d}\n", .{ proc.gid, proc.egid, proc.sgid, proc.fsgid });
    try writer.print("VmPeak:\t{d} kB\n", .{proc.vm_peak / 1024});
    try writer.print("VmSize:\t{d} kB\n", .{proc.vm_size / 1024});
    try writer.print("VmRSS:\t{d} kB\n", .{proc.vm_rss / 1024});
    try writer.print("VmData:\t{d} kB\n", .{proc.vm_data / 1024});
    try writer.print("VmStk:\t{d} kB\n", .{proc.vm_stack / 1024});
    try writer.print("VmExe:\t{d} kB\n", .{proc.vm_exe / 1024});
    try writer.print("Threads:\t{d}\n", .{proc.thread_count});

    return buffer.toOwnedSlice();
}

/// Generate /proc/[pid]/stat content
fn generateProcessStat(allocator: Basics.Allocator, pid: u32) ![]const u8 {
    const proc = process.findProcess(pid) orelse return error.NoSuchProcess;

    var buffer = Basics.ArrayList(u8).init(allocator);
    const writer = buffer.writer();

    // Format: pid (comm) state ppid pgrp session tty_nr tpgid flags
    //         minflt cminflt majflt cmajflt utime stime cutime cstime
    //         priority nice num_threads itrealvalue starttime vsize rss
    try writer.print("{d} ({s}) {c} {d} {d} {d} 0 0 0 ", .{
        proc.pid,
        proc.name,
        processStateChar(proc.state),
        proc.ppid,
        proc.pgrp,
        proc.session,
    });

    try writer.print("{d} {d} {d} {d} ", .{
        proc.min_flt,
        proc.cmin_flt,
        proc.maj_flt,
        proc.cmaj_flt,
    });

    try writer.print("{d} {d} {d} {d} ", .{
        proc.utime,
        proc.stime,
        proc.cutime,
        proc.cstime,
    });

    try writer.print("{d} {d} {d} 0 {d} {d} {d}\n", .{
        proc.priority,
        proc.nice,
        proc.thread_count,
        proc.start_time,
        proc.vm_size,
        proc.vm_rss / getPageSize(),
    });

    return buffer.toOwnedSlice();
}

/// Generate /proc/[pid]/cmdline content
fn generateProcessCmdline(allocator: Basics.Allocator, pid: u32) ![]const u8 {
    const proc = process.findProcess(pid) orelse return error.NoSuchProcess;

    if (proc.cmdline) |cmdline| {
        const result = try allocator.alloc(u8, cmdline.len);
        @memcpy(result, cmdline);
        return result;
    }

    // No cmdline, return process name
    const result = try allocator.alloc(u8, proc.name.len + 1);
    @memcpy(result[0..proc.name.len], proc.name);
    result[proc.name.len] = 0;
    return result;
}

/// Convert process state to character
fn processStateChar(state: process.ProcessState) u8 {
    return switch (state) {
        .Running => 'R',
        .Interruptible => 'S',
        .Uninterruptible => 'D',
        .Stopped => 'T',
        .Zombie => 'Z',
        .Dead => 'X',
        else => '?',
    };
}

// ============================================================================
// Procfs Inode Operations
// ============================================================================

fn procfsLookup(dir: *vfs.Inode, name: []const u8) anyerror!?*vfs.Dentry {
    const data: *ProcfsInodeData = @ptrCast(@alignCast(dir.private_data));

    switch (data.entry_type) {
        .Root => return procfsLookupRoot(dir, name),
        .ProcessDir => return procfsLookupProcess(dir, name, data.pid),
        .ProcFd => return procfsLookupFd(dir, name, data.pid),
        .NetDir => return procfsLookupNet(dir, name),
        else => return null,
    }
}

fn procfsLookupRoot(dir: *vfs.Inode, name: []const u8) !?*vfs.Dentry {
    // Check static entries first
    for (root_static_entries) |entry| {
        if (std.mem.eql(u8, name, entry.name)) {
            return createProcfsDentry(dir, name, entry.entry_type, entry.inode_type, 0);
        }
    }

    // Check if it's a PID
    const pid = std.fmt.parseInt(u32, name, 10) catch return null;

    // Verify process exists
    if (process.findProcess(pid) == null) {
        return null;
    }

    return createProcfsDentry(dir, name, .ProcessDir, .Directory, pid);
}

fn procfsLookupProcess(_: *vfs.Inode, name: []const u8, pid: u32) !?*vfs.Dentry {
    for (process_dir_entries) |entry| {
        if (std.mem.eql(u8, name, entry.name)) {
            return createProcfsDentryForProcess(name, entry.entry_type, entry.inode_type, pid);
        }
    }
    return null;
}

fn procfsLookupFd(_: *vfs.Inode, name: []const u8, pid: u32) !?*vfs.Dentry {
    _ = name;
    _ = pid;
    // FD lookup - would list open file descriptors as symlinks
    return null;
}

fn procfsLookupNet(_: *vfs.Inode, name: []const u8) !?*vfs.Dentry {
    _ = name;
    // Network statistics files
    return null;
}

fn createProcfsDentry(parent: *vfs.Inode, name: []const u8, entry_type: ProcfsEntryType, inode_type: vfs.InodeType, pid: u32) !*vfs.Dentry {
    const allocator = parent.sb.allocator;

    // Create inode
    const inode = try allocator.create(vfs.Inode);
    inode.* = vfs.Inode.init(parent.sb, allocInodeNum(), inode_type, &procfs_inode_ops);

    // Set up inode data
    const inode_data = try allocator.create(ProcfsInodeData);
    inode_data.* = ProcfsInodeData.init(allocator, entry_type, pid);
    inode.private_data = inode_data;

    // Set permissions
    inode.mode = switch (inode_type) {
        .Directory => vfs.FileMode.fromU16(0o555),
        .Symlink => vfs.FileMode.fromU16(0o777),
        else => vfs.FileMode.fromU16(0o444),
    };

    // Create dentry
    const dentry = try allocator.create(vfs.Dentry);
    const name_copy = try allocator.alloc(u8, name.len);
    @memcpy(name_copy, name);

    dentry.* = vfs.Dentry.init(name_copy, inode, null);

    return dentry;
}

fn createProcfsDentryForProcess(name: []const u8, entry_type: ProcfsEntryType, inode_type: vfs.InodeType, pid: u32) !*vfs.Dentry {
    const sb = procfs_superblock orelse return error.NotMounted;
    const allocator = sb.allocator;

    // Create inode
    const inode = try allocator.create(vfs.Inode);
    inode.* = vfs.Inode.init(sb, allocInodeNum(), inode_type, &procfs_inode_ops);

    // Set up inode data
    const inode_data = try allocator.create(ProcfsInodeData);
    inode_data.* = ProcfsInodeData.init(allocator, entry_type, pid);
    inode.private_data = inode_data;

    // Set permissions based on process ownership
    const proc = process.findProcess(pid);
    if (proc) |p| {
        inode.uid = p.uid;
        inode.gid = p.gid;
    }

    inode.mode = switch (inode_type) {
        .Directory => vfs.FileMode.fromU16(0o555),
        .Symlink => vfs.FileMode.fromU16(0o777),
        else => vfs.FileMode.fromU16(0o444),
    };

    // Create dentry
    const dentry = try allocator.create(vfs.Dentry);
    const name_copy = try allocator.alloc(u8, name.len);
    @memcpy(name_copy, name);

    dentry.* = vfs.Dentry.init(name_copy, inode, null);

    return dentry;
}

fn procfsReadlink(inode: *vfs.Inode, buffer: []u8) anyerror!usize {
    const data: *ProcfsInodeData = @ptrCast(@alignCast(inode.private_data));

    const target = switch (data.entry_type) {
        .SelfLink => blk: {
            // /proc/self -> current PID
            const current = process.getCurrentProcess() orelse return error.NoSuchProcess;
            var pid_buf: [16]u8 = undefined;
            const pid_str = std.fmt.bufPrint(&pid_buf, "{d}", .{current.pid}) catch return error.InvalidFormat;
            break :blk pid_str;
        },
        .ProcCwd => blk: {
            const proc = process.findProcess(data.pid) orelse return error.NoSuchProcess;
            break :blk proc.cwd orelse "/";
        },
        .ProcExe => blk: {
            const proc = process.findProcess(data.pid) orelse return error.NoSuchProcess;
            break :blk proc.exe_path orelse "";
        },
        else => return error.NotASymlink,
    };

    const len = @min(target.len, buffer.len);
    @memcpy(buffer[0..len], target[0..len]);
    return len;
}

fn procfsDestroy(inode: *vfs.Inode) void {
    if (inode.private_data) |ptr| {
        const data: *ProcfsInodeData = @ptrCast(@alignCast(ptr));
        data.deinit();
        inode.sb.allocator.destroy(data);
    }
}

const procfs_inode_ops = vfs.InodeOperations{
    .lookup = procfsLookup,
    .readlink = procfsReadlink,
    .destroy = procfsDestroy,
};

// ============================================================================
// Procfs File Operations
// ============================================================================

fn procfsRead(file: *vfs.File, buffer: []u8, offset: u64) anyerror!usize {
    const inode = file.dentry.inode;
    const data: *ProcfsInodeData = @ptrCast(@alignCast(inode.private_data));

    // Generate content based on entry type
    const content = try generateContent(data.allocator, data.entry_type, data.pid);
    defer data.allocator.free(content);

    // Handle offset
    if (offset >= content.len) {
        return 0;
    }

    const remaining = content.len - offset;
    const to_read = @min(remaining, buffer.len);

    @memcpy(buffer[0..to_read], content[offset..][0..to_read]);

    return to_read;
}

fn generateContent(allocator: Basics.Allocator, entry_type: ProcfsEntryType, pid: u32) ![]const u8 {
    return switch (entry_type) {
        .CpuInfo => generateCpuInfo(allocator),
        .MemInfo => generateMemInfo(allocator),
        .Uptime => generateUptime(allocator),
        .Version => generateVersion(allocator),
        .LoadAvg => generateLoadAvg(allocator),
        .SysStat => generateSysStat(allocator),
        .ProcStatus => generateProcessStatus(allocator, pid),
        .ProcStat => generateProcessStat(allocator, pid),
        .ProcCmdline => generateProcessCmdline(allocator, pid),
        .Filesystems => generateFilesystems(allocator),
        .Mounts => generateMounts(allocator),
        else => error.NotSupported,
    };
}

fn generateFilesystems(allocator: Basics.Allocator) ![]const u8 {
    var buffer = Basics.ArrayList(u8).init(allocator);
    const writer = buffer.writer();

    // List registered filesystems
    try writer.print("nodev\tproc\n", .{});
    try writer.print("nodev\tramfs\n", .{});
    try writer.print("nodev\ttmpfs\n", .{});
    try writer.print("nodev\tdevfs\n", .{});
    try writer.print("nodev\tsysfs\n", .{});
    try writer.print("\text4\n", .{});

    return buffer.toOwnedSlice();
}

fn generateMounts(allocator: Basics.Allocator) ![]const u8 {
    var buffer = Basics.ArrayList(u8).init(allocator);
    const writer = buffer.writer();

    // List mounted filesystems
    try writer.print("proc /proc proc rw 0 0\n", .{});
    try writer.print("rootfs / ramfs rw 0 0\n", .{});

    return buffer.toOwnedSlice();
}

const procfs_file_ops = vfs.FileOperations{
    .read = procfsRead,
    .write = null,
    .open = null,
    .release = null,
    .readdir = procfsReaddir,
    .llseek = null,
    .fsync = null,
    .poll = null,
    .ioctl = null,
    .mmap = null,
};

fn procfsReaddir(file: *vfs.File, callback: *const fn (name: []const u8, ino: u64, dtype: u8) bool) anyerror!void {
    const inode = file.dentry.inode;
    const data: *ProcfsInodeData = @ptrCast(@alignCast(inode.private_data));

    switch (data.entry_type) {
        .Root => {
            // List static entries
            for (root_static_entries) |entry| {
                const dtype: u8 = switch (entry.inode_type) {
                    .Directory => 4,
                    .Symlink => 10,
                    else => 8,
                };
                if (!callback(entry.name, 0, dtype)) return;
            }

            // List process directories
            var iter = process.iterateProcesses();
            while (iter.next()) |proc| {
                var pid_buf: [16]u8 = undefined;
                const pid_str = std.fmt.bufPrint(&pid_buf, "{d}", .{proc.pid}) catch continue;
                if (!callback(pid_str, proc.pid, 4)) return;
            }
        },
        .ProcessDir => {
            // List process directory entries
            for (process_dir_entries) |entry| {
                const dtype: u8 = switch (entry.inode_type) {
                    .Directory => 4,
                    .Symlink => 10,
                    else => 8,
                };
                if (!callback(entry.name, 0, dtype)) return;
            }
        },
        .ProcFd => {
            // List open file descriptors
            const proc = process.findProcess(data.pid) orelse return;
            for (proc.fd_table, 0..) |fd, i| {
                if (fd != null) {
                    var fd_buf: [16]u8 = undefined;
                    const fd_str = std.fmt.bufPrint(&fd_buf, "{d}", .{i}) catch continue;
                    if (!callback(fd_str, 0, 10)) return; // Symlinks
                }
            }
        },
        else => {},
    }
}

// ============================================================================
// Procfs Filesystem Type
// ============================================================================

fn procfsMount(sb: *vfs.Superblock, _: ?[]const u8, _: ?*anyopaque) anyerror!void {
    procfs_lock.acquire();
    defer procfs_lock.release();

    // Create root inode
    const root_inode = try sb.allocator.create(vfs.Inode);
    root_inode.* = vfs.Inode.init(sb, allocInodeNum(), .Directory, &procfs_inode_ops);
    root_inode.mode = vfs.FileMode.fromU16(0o555);

    // Create root inode data
    const root_data = try sb.allocator.create(ProcfsInodeData);
    root_data.* = ProcfsInodeData.init(sb.allocator, .Root, 0);
    root_inode.private_data = root_data;

    // Create root dentry
    const root_dentry = try sb.allocator.create(vfs.Dentry);
    const root_name = try sb.allocator.alloc(u8, 1);
    root_name[0] = '/';
    root_dentry.* = vfs.Dentry.init(root_name, root_inode, null);

    sb.root = root_dentry;
    procfs_superblock = sb;
    procfs_root_inode = root_inode;
}

fn procfsUmount(sb: *vfs.Superblock) void {
    procfs_lock.acquire();
    defer procfs_lock.release();

    _ = sb;
    procfs_superblock = null;
    procfs_root_inode = null;
}

const procfs_type = vfs.FilesystemType{
    .name = "proc",
    .flags = .{ .no_device = true, .pseudo = true },
    .mount = procfsMount,
    .umount = procfsUmount,
};

// ============================================================================
// System Information Helpers (stubs - would be implemented in other modules)
// ============================================================================

fn getCpuCount() usize {
    // Would get from CPU subsystem
    return 1;
}

fn getCpuMhz() u64 {
    // Would get from CPU subsystem
    return 3000;
}

const MemoryStats = struct {
    total: u64 = 0,
    free: u64 = 0,
    available: u64 = 0,
    buffers: u64 = 0,
    cached: u64 = 0,
    swap_cached: u64 = 0,
    active: u64 = 0,
    inactive: u64 = 0,
    swap_total: u64 = 0,
    swap_free: u64 = 0,
    dirty: u64 = 0,
    writeback: u64 = 0,
    slab: u64 = 0,
    page_tables: u64 = 0,
};

fn getMemoryStats() MemoryStats {
    // Would get from memory subsystem
    return .{
        .total = 1024 * 1024 * 1024, // 1GB
        .free = 512 * 1024 * 1024,
        .available = 768 * 1024 * 1024,
        .buffers = 64 * 1024 * 1024,
        .cached = 128 * 1024 * 1024,
    };
}

fn getUptimeSeconds() u64 {
    // Would get from timer subsystem
    return 12345;
}

fn getIdleSeconds() u64 {
    return 10000;
}

const LoadAverage = struct {
    one_min: u64 = 0,
    five_min: u64 = 0,
    fifteen_min: u64 = 0,
};

fn getLoadAverage() LoadAverage {
    return .{ .one_min = 50, .five_min = 45, .fifteen_min = 40 };
}

fn getRunningProcesses() u32 {
    return 1;
}

fn getTotalProcesses() u32 {
    return process.getProcessCount();
}

fn getLastPid() u32 {
    return process.getLastPid();
}

const SystemStats = struct {
    cpu_user: u64 = 0,
    cpu_nice: u64 = 0,
    cpu_system: u64 = 0,
    cpu_idle: u64 = 0,
    cpu_iowait: u64 = 0,
    cpu_irq: u64 = 0,
    cpu_softirq: u64 = 0,
    interrupts: u64 = 0,
    context_switches: u64 = 0,
    boot_time: u64 = 0,
    processes: u64 = 0,
    procs_running: u64 = 0,
    procs_blocked: u64 = 0,
};

fn getSystemStats() SystemStats {
    return .{
        .cpu_user = 1000,
        .cpu_system = 500,
        .cpu_idle = 10000,
        .interrupts = 50000,
        .context_switches = 100000,
        .boot_time = 1700000000,
        .processes = 100,
        .procs_running = 1,
    };
}

fn getPageSize() u64 {
    return 4096;
}

// ============================================================================
// Public API
// ============================================================================

/// Initialize procfs
pub fn init() void {
    vfs.registerFilesystem(&procfs_type);
}

/// Get procfs superblock
pub fn getSuperblock() ?*vfs.Superblock {
    return procfs_superblock;
}

// Import std for string comparison
const std = @import("std");

// ============================================================================
// Tests
// ============================================================================

test "procfs entry types" {
    const data = ProcfsInodeData.init(std.testing.allocator, .Root, 0);
    try std.testing.expectEqual(ProcfsEntryType.Root, data.entry_type);
    try std.testing.expectEqual(@as(u32, 0), data.pid);
}
