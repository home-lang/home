// Home Programming Language - Kernel Debugger
// Stack unwinding, symbol resolution, breakpoints, GDB stub

const Basics = @import("basics");
const sync = @import("sync.zig");
const serial = @import("serial.zig");

// ============================================================================
// Stack Frame
// ============================================================================

pub const StackFrame = struct {
    rip: u64,
    rsp: u64,
    rbp: u64,
    function_name: ?[]const u8,
    file_name: ?[]const u8,
    line_number: ?u32,

    pub fn format(
        self: StackFrame,
        comptime fmt: []const u8,
        options: Basics.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = fmt;
        _ = options;

        try writer.print("0x{x:0>16} in ", .{self.rip});

        if (self.function_name) |name| {
            try writer.print("{s}", .{name});
        } else {
            try writer.print("???", .{});
        }

        if (self.file_name) |file| {
            try writer.print(" at {s}", .{file});
            if (self.line_number) |line| {
                try writer.print(":{d}", .{line});
            }
        }
    }
};

// ============================================================================
// Stack Unwinding
// ============================================================================

pub const MAX_STACK_DEPTH = 64;

pub fn captureStackTrace(frames: []StackFrame) usize {
    var count: usize = 0;
    var rbp: u64 = undefined;
    var rip: u64 = undefined;

    // Get current RBP
    asm volatile ("movq %%rbp, %[rbp]"
        : [rbp] "=r" (rbp),
    );

    while (count < frames.len) {
        // Validate frame pointer
        if (rbp == 0 or rbp < 0x1000 or !isKernelAddress(rbp)) {
            break;
        }

        // Read return address
        rip = @as(*u64, @ptrFromInt(rbp + 8)).*;
        if (rip == 0 or !isKernelAddress(rip)) {
            break;
        }

        // Resolve symbol
        const symbol = resolveSymbol(rip);

        frames[count] = .{
            .rip = rip,
            .rsp = rbp + 16,
            .rbp = rbp,
            .function_name = symbol.name,
            .file_name = symbol.file,
            .line_number = symbol.line,
        };

        count += 1;

        // Move to previous frame
        const next_rbp = @as(*u64, @ptrFromInt(rbp)).*;
        if (next_rbp <= rbp) {
            break;
        }
        rbp = next_rbp;
    }

    return count;
}

pub fn printStackTrace() void {
    var frames: [MAX_STACK_DEPTH]StackFrame = undefined;
    const count = captureStackTrace(&frames);

    Basics.debug.print("Stack trace:\n", .{});
    for (frames[0..count], 0..) |frame, i| {
        Basics.debug.print("  #{d}: {}\n", .{ i, frame });
    }
}

fn isKernelAddress(addr: u64) bool {
    // Check if address is in kernel space (high half)
    return addr >= 0xFFFF800000000000;
}

// ============================================================================
// Symbol Resolution
// ============================================================================

pub const Symbol = struct {
    address: u64,
    name: ?[]const u8,
    file: ?[]const u8,
    line: ?u32,

    pub fn init(address: u64) Symbol {
        return .{
            .address = address,
            .name = null,
            .file = null,
            .line = null,
        };
    }
};

pub const SymbolTable = struct {
    symbols: Basics.ArrayList(Symbol),
    lock: sync.RwLock,
    allocator: Basics.Allocator,

    pub fn init(allocator: Basics.Allocator) SymbolTable {
        return .{
            .symbols = Basics.ArrayList(Symbol).init(allocator),
            .lock = sync.RwLock.init(),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SymbolTable) void {
        self.symbols.deinit();
    }

    pub fn addSymbol(self: *SymbolTable, address: u64, name: []const u8) !void {
        self.lock.acquireWrite();
        defer self.lock.releaseWrite();

        var symbol = Symbol.init(address);
        symbol.name = try self.allocator.dupe(u8, name);

        try self.symbols.append(symbol);
    }

    pub fn lookup(self: *SymbolTable, address: u64) ?Symbol {
        self.lock.acquireRead();
        defer self.lock.releaseRead();

        var best_match: ?Symbol = null;
        var best_distance: u64 = Basics.math.maxInt(u64);

        for (self.symbols.items) |symbol| {
            if (symbol.address <= address) {
                const distance = address - symbol.address;
                if (distance < best_distance) {
                    best_distance = distance;
                    best_match = symbol;
                }
            }
        }

        return best_match;
    }
};

var global_symbol_table: ?SymbolTable = null;
var symbol_lock = sync.Spinlock.init();

fn getSymbolTable() *SymbolTable {
    symbol_lock.acquire();
    defer symbol_lock.release();

    if (global_symbol_table == null) {
        global_symbol_table = SymbolTable.init(Basics.heap.page_allocator);
    }

    return &global_symbol_table.?;
}

pub fn resolveSymbol(address: u64) Symbol {
    const table = getSymbolTable();
    return table.lookup(address) orelse Symbol.init(address);
}

pub fn registerSymbol(address: u64, name: []const u8) !void {
    const table = getSymbolTable();
    try table.addSymbol(address, name);
}

// ============================================================================
// Breakpoints
// ============================================================================

pub const Breakpoint = struct {
    address: u64,
    original_byte: u8,
    enabled: bool,

    pub fn init(address: u64) Breakpoint {
        return .{
            .address = address,
            .original_byte = 0,
            .enabled = false,
        };
    }
};

pub const BreakpointManager = struct {
    breakpoints: Basics.ArrayList(Breakpoint),
    lock: sync.Spinlock,
    allocator: Basics.Allocator,

    pub fn init(allocator: Basics.Allocator) BreakpointManager {
        return .{
            .breakpoints = Basics.ArrayList(Breakpoint).init(allocator),
            .lock = sync.Spinlock.init(),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *BreakpointManager) void {
        // Disable all breakpoints before cleanup
        for (self.breakpoints.items) |*bp| {
            if (bp.enabled) {
                self.disableBreakpoint(bp);
            }
        }
        self.breakpoints.deinit();
    }

    pub fn setBreakpoint(self: *BreakpointManager, address: u64) !void {
        self.lock.acquire();
        defer self.lock.release();

        // Check if breakpoint already exists
        for (self.breakpoints.items) |bp| {
            if (bp.address == address) {
                return error.BreakpointExists;
            }
        }

        var bp = Breakpoint.init(address);

        // Save original byte
        const ptr = @as(*u8, @ptrFromInt(address));
        bp.original_byte = ptr.*;

        // Write INT3 instruction (0xCC)
        ptr.* = 0xCC;
        bp.enabled = true;

        try self.breakpoints.append(bp);
    }

    pub fn removeBreakpoint(self: *BreakpointManager, address: u64) !void {
        self.lock.acquire();
        defer self.lock.release();

        for (self.breakpoints.items, 0..) |*bp, i| {
            if (bp.address == address) {
                if (bp.enabled) {
                    self.disableBreakpoint(bp);
                }
                _ = self.breakpoints.orderedRemove(i);
                return;
            }
        }

        return error.BreakpointNotFound;
    }

    fn disableBreakpoint(self: *BreakpointManager, bp: *Breakpoint) void {
        _ = self;
        if (bp.enabled) {
            const ptr = @as(*u8, @ptrFromInt(bp.address));
            ptr.* = bp.original_byte;
            bp.enabled = false;
        }
    }

    pub fn handleBreakpoint(self: *BreakpointManager, address: u64) bool {
        self.lock.acquire();
        defer self.lock.release();

        for (self.breakpoints.items) |bp| {
            if (bp.address == address and bp.enabled) {
                return true;
            }
        }

        return false;
    }
};

var global_breakpoints: ?BreakpointManager = null;
var breakpoint_lock = sync.Spinlock.init();

fn getBreakpointManager() *BreakpointManager {
    breakpoint_lock.acquire();
    defer breakpoint_lock.release();

    if (global_breakpoints == null) {
        global_breakpoints = BreakpointManager.init(Basics.heap.page_allocator);
    }

    return &global_breakpoints.?;
}

pub fn setBreakpoint(address: u64) !void {
    const manager = getBreakpointManager();
    try manager.setBreakpoint(address);
}

pub fn removeBreakpoint(address: u64) !void {
    const manager = getBreakpointManager();
    try manager.removeBreakpoint(address);
}

// ============================================================================
// Memory Inspection
// ============================================================================

pub fn dumpMemory(address: u64, length: usize) void {
    Basics.debug.print("Memory dump at 0x{x:0>16}:\n", .{address});

    var offset: usize = 0;
    while (offset < length) {
        const addr = address + offset;
        const ptr = @as([*]const u8, @ptrFromInt(addr));

        // Print address
        Basics.debug.print("{x:0>16}: ", .{addr});

        // Print hex bytes
        var i: usize = 0;
        while (i < 16 and offset + i < length) : (i += 1) {
            Basics.debug.print("{x:0>2} ", .{ptr[i]});
        }

        // Pad if necessary
        while (i < 16) : (i += 1) {
            Basics.debug.print("   ", .{});
        }

        // Print ASCII representation
        Basics.debug.print(" |", .{});
        i = 0;
        while (i < 16 and offset + i < length) : (i += 1) {
            const byte = ptr[i];
            if (byte >= 32 and byte <= 126) {
                Basics.debug.print("{c}", .{byte});
            } else {
                Basics.debug.print(".", .{});
            }
        }
        Basics.debug.print("|\n", .{});

        offset += 16;
    }
}

// ============================================================================
// GDB Remote Serial Protocol Stub
// ============================================================================

pub const GdbStub = struct {
    port: *serial.SerialPort,
    enabled: bool,

    pub fn init(port: *serial.SerialPort) GdbStub {
        return .{
            .port = port,
            .enabled = false,
        };
    }

    pub fn enable(self: *GdbStub) void {
        self.enabled = true;
        self.sendPacket("S05"); // Send SIGTRAP signal
    }

    pub fn disable(self: *GdbStub) void {
        self.enabled = false;
    }

    fn sendPacket(self: *GdbStub, data: []const u8) void {
        // Calculate checksum
        var checksum: u8 = 0;
        for (data) |byte| {
            checksum +%= byte;
        }

        // Send packet: $<data>#<checksum>
        self.port.write("$");
        self.port.write(data);
        var buf: [3]u8 = undefined;
        _ = Basics.fmt.bufPrint(&buf, "#{x:0>2}", .{checksum}) catch unreachable;
        self.port.write(&buf);
    }

    fn receivePacket(self: *GdbStub, buffer: []u8) !usize {
        var index: usize = 0;

        // Wait for start character
        while (true) {
            const byte = try self.port.read();
            if (byte == '$') break;
        }

        // Read until '#'
        while (index < buffer.len) {
            const byte = try self.port.read();
            if (byte == '#') break;
            buffer[index] = byte;
            index += 1;
        }

        // Read checksum (2 hex digits)
        _ = try self.port.read();
        _ = try self.port.read();

        // Send acknowledgment
        self.port.write("+");

        return index;
    }

    pub fn handleException(self: *GdbStub, exception: u64, context: *anyopaque) void {
        _ = context;

        if (!self.enabled) return;

        // Send stop reply
        var buf: [32]u8 = undefined;
        const msg = Basics.fmt.bufPrint(&buf, "S{x:0>2}", .{exception}) catch return;
        self.sendPacket(msg);

        // Enter command loop
        var cmd_buf: [1024]u8 = undefined;
        while (true) {
            const len = self.receivePacket(&cmd_buf) catch continue;
            const cmd = cmd_buf[0..len];

            if (cmd.len == 0) continue;

            switch (cmd[0]) {
                'g' => self.sendRegisters(),
                'G' => self.setRegisters(cmd[1..]),
                'm' => self.readMemory(cmd[1..]),
                'M' => self.writeMemory(cmd[1..]),
                'c' => break, // Continue execution
                's' => break, // Single step
                'k' => break, // Kill
                else => self.sendPacket(""),
            }
        }
    }

    fn sendRegisters(self: *GdbStub) void {
        // TODO: Send all register values
        self.sendPacket("");
    }

    fn setRegisters(self: *GdbStub, data: []const u8) void {
        _ = data;
        // TODO: Set register values
        self.sendPacket("OK");
    }

    fn readMemory(self: *GdbStub, data: []const u8) void {
        _ = data;
        // TODO: Parse address and length, send memory contents
        self.sendPacket("");
    }

    fn writeMemory(self: *GdbStub, data: []const u8) void {
        _ = data;
        // TODO: Parse address, length, and data, write to memory
        self.sendPacket("OK");
    }
};

// ============================================================================
// Panic Handler
// ============================================================================

pub fn panic(msg: []const u8, stack_trace: ?*Basics.StackTrace, return_address: ?usize) noreturn {
    _ = stack_trace;
    _ = return_address;

    Basics.debug.print("\n!!! KERNEL PANIC !!!\n", .{});
    Basics.debug.print("Message: {s}\n\n", .{msg});

    printStackTrace();

    // Halt all CPUs
    while (true) {
        asm volatile ("cli; hlt");
    }
}

// ============================================================================
// Tests
// ============================================================================

test "stack trace capture" {
    var frames: [10]StackFrame = undefined;
    const count = captureStackTrace(&frames);

    try Basics.testing.expect(count > 0);
    try Basics.testing.expect(frames[0].rip != 0);
}

test "symbol table" {
    const allocator = Basics.testing.allocator;
    var table = SymbolTable.init(allocator);
    defer table.deinit();

    try table.addSymbol(0x1000, "function1");
    try table.addSymbol(0x2000, "function2");

    const sym1 = table.lookup(0x1050);
    try Basics.testing.expect(sym1 != null);
    try Basics.testing.expectEqualSlices(u8, "function1", sym1.?.name.?);

    const sym2 = table.lookup(0x2100);
    try Basics.testing.expect(sym2 != null);
    try Basics.testing.expectEqualSlices(u8, "function2", sym2.?.name.?);
}
