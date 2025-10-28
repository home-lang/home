// Example: System call wrappers with variadic arguments

const std = @import("std");
const variadic = @import("variadic");

pub fn main() !void {
    std.debug.print("=== Syscall Example ===\n\n", .{});

    std.debug.print("System Call Numbers:\n", .{});
    std.debug.print("  read:  {d}\n", .{@intFromEnum(variadic.syscall.SyscallNumber.read)});
    std.debug.print("  write: {d}\n", .{@intFromEnum(variadic.syscall.SyscallNumber.write)});
    std.debug.print("  open:  {d}\n", .{@intFromEnum(variadic.syscall.SyscallNumber.open)});
    std.debug.print("  close: {d}\n", .{@intFromEnum(variadic.syscall.SyscallNumber.close)});

    std.debug.print("\nVariadic Syscall Wrapper:\n", .{});
    std.debug.print("The variadic syscall wrapper allows type-safe syscalls:\n", .{});
    std.debug.print("  syscall(.write, .{{fd, ptr, len}})\n", .{});
    std.debug.print("  syscall(.read, .{{fd, ptr, len}})\n", .{});
    std.debug.print("  syscall(.open, .{{path, flags, mode}})\n", .{});

    std.debug.print("\nExample syscall formatting:\n", .{});

    // Format syscall traces
    var buf: [256]u8 = undefined;

    const n1 = try variadic.printf.sprintf(
        &buf,
        "write(%d, %p, %d) = %d",
        .{ @as(i32, 1), @as(usize, 0x1000), @as(usize, 13), @as(isize, 13) },
    );
    std.debug.print("  {s}\n", .{buf[0..n1]});

    const n2 = try variadic.printf.sprintf(
        &buf,
        "read(%d, %p, %d) = %d",
        .{ @as(i32, 3), @as(usize, 0x2000), @as(usize, 4096), @as(isize, 4096) },
    );
    std.debug.print("  {s}\n", .{buf[0..n2]});

    const n3 = try variadic.printf.sprintf(
        &buf,
        "open(\"%s\", %#x, %#o) = %d",
        .{ "/dev/null", @as(u32, 0x02), @as(u32, 0o666), @as(isize, 4) },
    );
    std.debug.print("  {s}\n", .{buf[0..n3]});

    // Demonstrate argument counting
    std.debug.print("\nSyscall Argument Counts:\n", .{});
    const args0 = .{};
    const args1 = .{@as(i32, 1)};
    const args3 = .{ @as(i32, 1), @as(usize, 0x1000), @as(usize, 100) };
    const args6 = .{ @as(i32, 1), @as(usize, 2), @as(usize, 3), @as(usize, 4), @as(usize, 5), @as(usize, 6) };

    std.debug.print("  0 args: {d}\n", .{variadic.countArgs(args0)});
    std.debug.print("  1 arg:  {d}\n", .{variadic.countArgs(args1)});
    std.debug.print("  3 args: {d}\n", .{variadic.countArgs(args3)});
    std.debug.print("  6 args: {d}\n", .{variadic.countArgs(args6)});

    // Type information
    std.debug.print("\nArgument Type Detection:\n", .{});
    std.debug.print("  i32:         {s}\n", .{@tagName(variadic.ArgInfo.fromType(i32).arg_type)});
    std.debug.print("  u64:         {s}\n", .{@tagName(variadic.ArgInfo.fromType(u64).arg_type)});
    std.debug.print("  f64:         {s}\n", .{@tagName(variadic.ArgInfo.fromType(f64).arg_type)});
    std.debug.print("  []const u8:  {s}\n", .{@tagName(variadic.ArgInfo.fromType([]const u8).arg_type)});
    std.debug.print("  *const i32:  {s}\n", .{@tagName(variadic.ArgInfo.fromType(*const i32).arg_type)});

    std.debug.print("\nHome OS Custom Syscalls:\n", .{});
    std.debug.print("  home_log:   {d}\n", .{@intFromEnum(variadic.syscall.SyscallNumber.home_log)});
    std.debug.print("  home_debug: {d}\n", .{@intFromEnum(variadic.syscall.SyscallNumber.home_debug)});

    std.debug.print("\nNote: Actual syscall execution requires a kernel.\n", .{});
    std.debug.print("This example demonstrates the API and formatting.\n", .{});
}
