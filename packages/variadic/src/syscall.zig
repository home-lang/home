// Home Programming Language - System Call Wrappers with Variadic Support
// Type-safe variadic syscall wrappers for Home OS

const std = @import("std");
const builtin = @import("builtin");

// ============================================================================
// System Call Numbers
// ============================================================================

pub const SyscallNumber = enum(usize) {
    read = 0,
    write = 1,
    open = 2,
    close = 3,
    stat = 4,
    fstat = 5,
    lstat = 6,
    poll = 7,
    lseek = 8,
    mmap = 9,
    mprotect = 10,
    munmap = 11,
    ioctl = 16,
    fcntl = 72,

    // Custom Home OS syscalls
    home_log = 1000,
    home_debug = 1001,
};

// ============================================================================
// Syscall Invocation (Platform-specific)
// ============================================================================

/// Invoke syscall with 0 arguments
pub fn syscall0(number: SyscallNumber) usize {
    return switch (builtin.cpu.arch) {
        .x86_64 => asm volatile ("syscall"
            : [ret] "={rax}" (-> usize),
            : [number] "{rax}" (@intFromEnum(number)),
            : .{ .rcx = true, .r11 = true, .memory = true }
        ),
        .aarch64 => asm volatile ("svc #0"
            : [ret] "={x0}" (-> usize),
            : [number] "{x8}" (@intFromEnum(number)),
            : .{ .memory = true }
        ),
        .riscv64 => asm volatile ("ecall"
            : [ret] "={a0}" (-> usize),
            : [number] "{a7}" (@intFromEnum(number)),
            : .{ .memory = true }
        ),
        else => @compileError("Unsupported architecture for syscalls"),
    };
}

/// Invoke syscall with 1 argument
pub fn syscall1(number: SyscallNumber, arg1: usize) usize {
    return switch (builtin.cpu.arch) {
        .x86_64 => asm volatile ("syscall"
            : [ret] "={rax}" (-> usize),
            : [number] "{rax}" (@intFromEnum(number)),
              [arg1] "{rdi}" (arg1),
            : .{ .rcx = true, .r11 = true, .memory = true }
        ),
        .aarch64 => asm volatile ("svc #0"
            : [ret] "={x0}" (-> usize),
            : [number] "{x8}" (@intFromEnum(number)),
              [arg1] "{x0}" (arg1),
            : .{ .memory = true }
        ),
        .riscv64 => asm volatile ("ecall"
            : [ret] "={a0}" (-> usize),
            : [number] "{a7}" (@intFromEnum(number)),
              [arg1] "{a0}" (arg1),
            : .{ .memory = true }
        ),
        else => @compileError("Unsupported architecture for syscalls"),
    };
}

/// Invoke syscall with 2 arguments
pub fn syscall2(number: SyscallNumber, arg1: usize, arg2: usize) usize {
    return switch (builtin.cpu.arch) {
        .x86_64 => asm volatile ("syscall"
            : [ret] "={rax}" (-> usize),
            : [number] "{rax}" (@intFromEnum(number)),
              [arg1] "{rdi}" (arg1),
              [arg2] "{rsi}" (arg2),
            : .{ .rcx = true, .r11 = true, .memory = true }
        ),
        .aarch64 => asm volatile ("svc #0"
            : [ret] "={x0}" (-> usize),
            : [number] "{x8}" (@intFromEnum(number)),
              [arg1] "{x0}" (arg1),
              [arg2] "{x1}" (arg2),
            : .{ .memory = true }
        ),
        .riscv64 => asm volatile ("ecall"
            : [ret] "={a0}" (-> usize),
            : [number] "{a7}" (@intFromEnum(number)),
              [arg1] "{a0}" (arg1),
              [arg2] "{a1}" (arg2),
            : .{ .memory = true }
        ),
        else => @compileError("Unsupported architecture for syscalls"),
    };
}

/// Invoke syscall with 3 arguments
pub fn syscall3(number: SyscallNumber, arg1: usize, arg2: usize, arg3: usize) usize {
    return switch (builtin.cpu.arch) {
        .x86_64 => asm volatile ("syscall"
            : [ret] "={rax}" (-> usize),
            : [number] "{rax}" (@intFromEnum(number)),
              [arg1] "{rdi}" (arg1),
              [arg2] "{rsi}" (arg2),
              [arg3] "{rdx}" (arg3),
            : .{ .rcx = true, .r11 = true, .memory = true }
        ),
        .aarch64 => asm volatile ("svc #0"
            : [ret] "={x0}" (-> usize),
            : [number] "{x8}" (@intFromEnum(number)),
              [arg1] "{x0}" (arg1),
              [arg2] "{x1}" (arg2),
              [arg3] "{x2}" (arg3),
            : .{ .memory = true }
        ),
        .riscv64 => asm volatile ("ecall"
            : [ret] "={a0}" (-> usize),
            : [number] "{a7}" (@intFromEnum(number)),
              [arg1] "{a0}" (arg1),
              [arg2] "{a1}" (arg2),
              [arg3] "{a2}" (arg3),
            : .{ .memory = true }
        ),
        else => @compileError("Unsupported architecture for syscalls"),
    };
}

/// Invoke syscall with 4 arguments
pub fn syscall4(number: SyscallNumber, arg1: usize, arg2: usize, arg3: usize, arg4: usize) usize {
    return switch (builtin.cpu.arch) {
        .x86_64 => asm volatile ("syscall"
            : [ret] "={rax}" (-> usize),
            : [number] "{rax}" (@intFromEnum(number)),
              [arg1] "{rdi}" (arg1),
              [arg2] "{rsi}" (arg2),
              [arg3] "{rdx}" (arg3),
              [arg4] "{r10}" (arg4),
            : .{ .rcx = true, .r11 = true, .memory = true }
        ),
        .aarch64 => asm volatile ("svc #0"
            : [ret] "={x0}" (-> usize),
            : [number] "{x8}" (@intFromEnum(number)),
              [arg1] "{x0}" (arg1),
              [arg2] "{x1}" (arg2),
              [arg3] "{x2}" (arg3),
              [arg4] "{x3}" (arg4),
            : .{ .memory = true }
        ),
        .riscv64 => asm volatile ("ecall"
            : [ret] "={a0}" (-> usize),
            : [number] "{a7}" (@intFromEnum(number)),
              [arg1] "{a0}" (arg1),
              [arg2] "{a1}" (arg2),
              [arg3] "{a2}" (arg3),
              [arg4] "{a3}" (arg4),
            : .{ .memory = true }
        ),
        else => @compileError("Unsupported architecture for syscalls"),
    };
}

/// Invoke syscall with 5 arguments
pub fn syscall5(number: SyscallNumber, arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize) usize {
    return switch (builtin.cpu.arch) {
        .x86_64 => asm volatile ("syscall"
            : [ret] "={rax}" (-> usize),
            : [number] "{rax}" (@intFromEnum(number)),
              [arg1] "{rdi}" (arg1),
              [arg2] "{rsi}" (arg2),
              [arg3] "{rdx}" (arg3),
              [arg4] "{r10}" (arg4),
              [arg5] "{r8}" (arg5),
            : .{ .rcx = true, .r11 = true, .memory = true }
        ),
        .aarch64 => asm volatile ("svc #0"
            : [ret] "={x0}" (-> usize),
            : [number] "{x8}" (@intFromEnum(number)),
              [arg1] "{x0}" (arg1),
              [arg2] "{x1}" (arg2),
              [arg3] "{x2}" (arg3),
              [arg4] "{x3}" (arg4),
              [arg5] "{x4}" (arg5),
            : .{ .memory = true }
        ),
        .riscv64 => asm volatile ("ecall"
            : [ret] "={a0}" (-> usize),
            : [number] "{a7}" (@intFromEnum(number)),
              [arg1] "{a0}" (arg1),
              [arg2] "{a1}" (arg2),
              [arg3] "{a2}" (arg3),
              [arg4] "{a3}" (arg4),
              [arg5] "{a4}" (arg5),
            : .{ .memory = true }
        ),
        else => @compileError("Unsupported architecture for syscalls"),
    };
}

/// Invoke syscall with 6 arguments
pub fn syscall6(number: SyscallNumber, arg1: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize, arg6: usize) usize {
    return switch (builtin.cpu.arch) {
        .x86_64 => asm volatile ("syscall"
            : [ret] "={rax}" (-> usize),
            : [number] "{rax}" (@intFromEnum(number)),
              [arg1] "{rdi}" (arg1),
              [arg2] "{rsi}" (arg2),
              [arg3] "{rdx}" (arg3),
              [arg4] "{r10}" (arg4),
              [arg5] "{r8}" (arg5),
              [arg6] "{r9}" (arg6),
            : .{ .rcx = true, .r11 = true, .memory = true }
        ),
        .aarch64 => asm volatile ("svc #0"
            : [ret] "={x0}" (-> usize),
            : [number] "{x8}" (@intFromEnum(number)),
              [arg1] "{x0}" (arg1),
              [arg2] "{x1}" (arg2),
              [arg3] "{x2}" (arg3),
              [arg4] "{x3}" (arg4),
              [arg5] "{x4}" (arg5),
              [arg6] "{x5}" (arg6),
            : .{ .memory = true }
        ),
        .riscv64 => asm volatile ("ecall"
            : [ret] "={a0}" (-> usize),
            : [number] "{a7}" (@intFromEnum(number)),
              [arg1] "{a0}" (arg1),
              [arg2] "{a1}" (arg2),
              [arg3] "{a2}" (arg3),
              [arg4] "{a3}" (arg4),
              [arg5] "{a4}" (arg5),
              [arg6] "{a5}" (arg6),
            : .{ .memory = true }
        ),
        else => @compileError("Unsupported architecture for syscalls"),
    };
}

// ============================================================================
// Generic Variadic Syscall Wrapper
// ============================================================================

/// Invoke syscall with variable arguments (type-safe)
pub fn syscall(number: SyscallNumber, args: anytype) usize {
    const fields = @typeInfo(@TypeOf(args)).@"struct".fields;

    return switch (fields.len) {
        0 => syscall0(number),
        1 => syscall1(number, @intCast(@field(args, fields[0].name))),
        2 => syscall2(
            number,
            @intCast(@field(args, fields[0].name)),
            @intCast(@field(args, fields[1].name)),
        ),
        3 => syscall3(
            number,
            @intCast(@field(args, fields[0].name)),
            @intCast(@field(args, fields[1].name)),
            @intCast(@field(args, fields[2].name)),
        ),
        4 => syscall4(
            number,
            @intCast(@field(args, fields[0].name)),
            @intCast(@field(args, fields[1].name)),
            @intCast(@field(args, fields[2].name)),
            @intCast(@field(args, fields[3].name)),
        ),
        5 => syscall5(
            number,
            @intCast(@field(args, fields[0].name)),
            @intCast(@field(args, fields[1].name)),
            @intCast(@field(args, fields[2].name)),
            @intCast(@field(args, fields[3].name)),
            @intCast(@field(args, fields[4].name)),
        ),
        6 => syscall6(
            number,
            @intCast(@field(args, fields[0].name)),
            @intCast(@field(args, fields[1].name)),
            @intCast(@field(args, fields[2].name)),
            @intCast(@field(args, fields[3].name)),
            @intCast(@field(args, fields[4].name)),
            @intCast(@field(args, fields[5].name)),
        ),
        else => @compileError("Too many syscall arguments (max 6)"),
    };
}

// ============================================================================
// High-Level Syscall Wrappers
// ============================================================================

pub fn read(fd: i32, buf: []u8) isize {
    const result = syscall(.read, .{ fd, @intFromPtr(buf.ptr), buf.len });
    return @bitCast(result);
}

pub fn write(fd: i32, buf: []const u8) isize {
    const result = syscall(.write, .{ fd, @intFromPtr(buf.ptr), buf.len });
    return @bitCast(result);
}

pub fn open(path: [*:0]const u8, flags: u32, mode: u32) isize {
    const result = syscall(.open, .{ @intFromPtr(path), flags, mode });
    return @bitCast(result);
}

pub fn close(fd: i32) isize {
    const result = syscall(.close, .{fd});
    return @bitCast(result);
}

// Home OS custom syscalls
pub fn home_log(level: u32, message: []const u8) isize {
    const result = syscall(.home_log, .{ level, @intFromPtr(message.ptr), message.len });
    return @bitCast(result);
}

pub fn home_debug(code: u32, arg1: usize, arg2: usize) isize {
    const result = syscall(.home_debug, .{ code, arg1, arg2 });
    return @bitCast(result);
}

// ============================================================================
// Tests
// ============================================================================

test "syscall number enum" {
    const testing = std.testing;

    try testing.expectEqual(@as(usize, 0), @intFromEnum(SyscallNumber.read));
    try testing.expectEqual(@as(usize, 1), @intFromEnum(SyscallNumber.write));
    try testing.expectEqual(@as(usize, 2), @intFromEnum(SyscallNumber.open));
    try testing.expectEqual(@as(usize, 3), @intFromEnum(SyscallNumber.close));
}

test "syscall with different arg counts" {
    // These tests just ensure the code compiles
    // Actual syscalls would fail without a kernel
    _ = syscall0;
    _ = syscall1;
    _ = syscall2;
    _ = syscall3;
    _ = syscall4;
    _ = syscall5;
    _ = syscall6;
}

test "variadic syscall wrapper" {
    // Test that the variadic wrapper compiles correctly
    _ = syscall;
}
