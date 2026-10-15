// Home Programming Language - Secure Environment Variables CLI
// Command-line interface for managing encrypted environment variables

const std = @import("std");
const compat = @import("compat.zig");
const secure = @import("secure.zig");
const dotenv = @import("dotenv.zig");
const Io = std.Io;

pub const CliError = error{
    MissingArgument,
    InvalidCommand,
    FileNotFound,
} || secure.SecureEnvError;

pub const Command = enum {
    init, // Initialize and generate encryption key
    encrypt, // Encrypt .env file
    decrypt, // Decrypt .env.encrypted file
    add, // Add a new encrypted variable
    get, // Get and decrypt a variable
    list, // List all encrypted variables (keys only)
    rotate, // Rotate encryption key
    help,
};

pub const CliOptions = struct {
    command: Command,
    input_file: ?[]const u8 = null,
    output_file: ?[]const u8 = null,
    key_file: ?[]const u8 = null,
    var_name: ?[]const u8 = null,
    var_value: ?[]const u8 = null,
    password: ?[]const u8 = null,
};

pub fn parseArgs(allocator: std.mem.Allocator, args: []const []const u8) !CliOptions {
    if (args.len < 1) return error.MissingArgument;

    const cmd_str = args[0];
    const command = std.meta.stringToEnum(Command, cmd_str) orelse return error.InvalidCommand;

    var options = CliOptions{ .command = command };

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--input") or std.mem.eql(u8, arg, "-i")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            options.input_file = args[i];
        } else if (std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "-o")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            options.output_file = args[i];
        } else if (std.mem.eql(u8, arg, "--key") or std.mem.eql(u8, arg, "-k")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            options.key_file = args[i];
        } else if (std.mem.eql(u8, arg, "--name") or std.mem.eql(u8, arg, "-n")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            options.var_name = args[i];
        } else if (std.mem.eql(u8, arg, "--value") or std.mem.eql(u8, arg, "-v")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            options.var_value = args[i];
        } else if (std.mem.eql(u8, arg, "--password") or std.mem.eql(u8, arg, "-p")) {
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            options.password = args[i];
        }
    }

    _ = allocator;
    return options;
}

pub fn execute(allocator: std.mem.Allocator, options: CliOptions) !void {
    return executeWithIo(allocator, compat.io(), options);
}

pub fn executeWithIo(allocator: std.mem.Allocator, io: Io, options: CliOptions) !void {
    var buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(io, &buffer);
    try executeToWriterWithIo(allocator, io, options, &stdout.interface);
    try stdout.interface.flush();
}

pub fn executeToWriterWithIo(allocator: std.mem.Allocator, io: Io, options: CliOptions, writer: *Io.Writer) !void {
    switch (options.command) {
        .init => try cmdInit(allocator, io, options, writer),
        .encrypt => try cmdEncrypt(allocator, io, options, writer),
        .decrypt => try cmdDecrypt(allocator, io, options, writer),
        .add => try cmdAdd(allocator, io, options, writer),
        .get => try cmdGet(allocator, io, options, writer),
        .list => try cmdList(allocator, io, options, writer),
        .rotate => try cmdRotate(allocator, io, options, writer),
        .help => try cmdHelp(writer),
    }
}

fn cmdInit(allocator: std.mem.Allocator, io: Io, options: CliOptions, writer: *Io.Writer) !void {
    const key_file = options.key_file orelse ".env.key";

    try writer.print("Generating encryption key...\n", .{});

    var key = try secure.SecureKey.generateWithIo(io);
    defer key.destroy();

    try key.saveToFileWithIo(io, key_file);

    try writer.print("✓ Encryption key saved to: {s}\n", .{key_file});
    try writer.print("\n", .{});
    try writer.print("⚠️  IMPORTANT SECURITY NOTES:\n", .{});
    try writer.print("   1. Keep this key file secure and never commit it to version control\n", .{});
    try writer.print("   2. Add '{s}' to your .gitignore file\n", .{key_file});
    try writer.print("   3. Backup this key in a secure location\n", .{});
    try writer.print("   4. Share it securely with team members who need access\n", .{});
    try writer.print("\n", .{});

    _ = allocator;
}

fn cmdEncrypt(allocator: std.mem.Allocator, io: Io, options: CliOptions, writer: *Io.Writer) !void {
    const input_file = options.input_file orelse ".env";
    const output_file = options.output_file orelse ".env.encrypted";
    const key_file = options.key_file orelse ".env.key";

    try writer.print("Loading encryption key from: {s}\n", .{key_file});
    var key = try secure.SecureKey.fromFileWithIo(allocator, io, key_file);
    defer key.destroy();

    try writer.print("Loading environment variables from: {s}\n", .{input_file});
    var env = dotenv.DotEnv.init(allocator);
    defer env.deinit();

    try env.loadWithIo(io, input_file);

    try writer.print("Encrypting {d} variables...\n", .{env.count()});

    var secure_env = secure.SecureEnv.init(allocator, key);
    defer secure_env.deinit();

    var iter = env.getAll().iterator();
    while (iter.next()) |entry| {
        try secure_env.setWithIo(io, entry.key_ptr.*, entry.value_ptr.*);
    }

    try secure_env.saveToFileWithIo(io, output_file);

    try writer.print("✓ Encrypted variables saved to: {s}\n", .{output_file});
    try writer.print("\n", .{});
    try writer.print("You can now safely commit {s} to version control.\n", .{output_file});
}

fn cmdDecrypt(allocator: std.mem.Allocator, io: Io, options: CliOptions, writer: *Io.Writer) !void {
    const input_file = options.input_file orelse ".env.encrypted";
    const output_file = options.output_file orelse ".env";
    const key_file = options.key_file orelse ".env.key";

    try writer.print("Loading encryption key from: {s}\n", .{key_file});
    var key = try secure.SecureKey.fromFileWithIo(allocator, io, key_file);
    defer key.destroy();

    try writer.print("Loading encrypted variables from: {s}\n", .{input_file});

    var secure_env = secure.SecureEnv.init(allocator, key);
    defer secure_env.deinit();

    try secure_env.loadFromFileWithIo(io, input_file);

    try writer.print("Decrypting variables...\n", .{});

    var plain_env = dotenv.DotEnv.init(allocator);
    defer plain_env.deinit();

    var iter = secure_env.vars.iterator();
    var count: usize = 0;
    while (iter.next()) |entry| {
        const decrypted = try secure_env.get(entry.key_ptr.*);
        if (decrypted) |value| {
            defer allocator.free(value);
            try plain_env.set(entry.key_ptr.*, value);
            count += 1;
        }
    }

    try plain_env.saveWithIo(io, output_file);

    try writer.print("✓ Decrypted {d} variables to: {s}\n", .{ count, output_file });
    try writer.print("\n", .{});
    try writer.print("⚠️  WARNING: {s} contains plaintext secrets!\n", .{output_file});
    try writer.print("   Do NOT commit this file to version control.\n", .{});
}

fn cmdAdd(allocator: std.mem.Allocator, io: Io, options: CliOptions, writer: *Io.Writer) !void {
    const encrypted_file = options.output_file orelse ".env.encrypted";
    const key_file = options.key_file orelse ".env.key";
    const var_name = options.var_name orelse return error.MissingArgument;
    const var_value = options.var_value orelse return error.MissingArgument;

    try writer.print("Loading encryption key from: {s}\n", .{key_file});
    var key = try secure.SecureKey.fromFileWithIo(allocator, io, key_file);
    defer key.destroy();

    var secure_env = secure.SecureEnv.init(allocator, key);
    defer secure_env.deinit();

    // Load existing variables if file exists
    secure_env.loadFromFileWithIo(io, encrypted_file) catch |err| {
        if (err != error.FileNotFound) return err;
    };

    try writer.print("Adding encrypted variable: {s}\n", .{var_name});
    try secure_env.setWithIo(io, var_name, var_value);

    try secure_env.saveToFileWithIo(io, encrypted_file);

    try writer.print("✓ Variable added to: {s}\n", .{encrypted_file});
}

fn cmdGet(allocator: std.mem.Allocator, io: Io, options: CliOptions, writer: *Io.Writer) !void {
    const encrypted_file = options.input_file orelse ".env.encrypted";
    const key_file = options.key_file orelse ".env.key";
    const var_name = options.var_name orelse return error.MissingArgument;

    var key = try secure.SecureKey.fromFileWithIo(allocator, io, key_file);
    defer key.destroy();

    var secure_env = secure.SecureEnv.init(allocator, key);
    defer secure_env.deinit();

    try secure_env.loadFromFileWithIo(io, encrypted_file);

    const value = try secure_env.get(var_name);
    if (value) |v| {
        defer allocator.free(v);
        try writer.print("{s}\n", .{v});
    } else {
        try writer.print("Variable not found: {s}\n", .{var_name});
    }
}

fn cmdList(allocator: std.mem.Allocator, io: Io, options: CliOptions, writer: *Io.Writer) !void {
    const encrypted_file = options.input_file orelse ".env.encrypted";
    const key_file = options.key_file orelse ".env.key";

    var key = try secure.SecureKey.fromFileWithIo(allocator, io, key_file);
    defer key.destroy();

    var secure_env = secure.SecureEnv.init(allocator, key);
    defer secure_env.deinit();

    try secure_env.loadFromFileWithIo(io, encrypted_file);

    try writer.print("Encrypted variables in {s}:\n\n", .{encrypted_file});

    var iter = secure_env.vars.iterator();
    while (iter.next()) |entry| {
        try writer.print("  • {s}\n", .{entry.key_ptr.*});
    }

    try writer.print("\n", .{});
}

fn cmdRotate(allocator: std.mem.Allocator, io: Io, options: CliOptions, writer: *Io.Writer) !void {
    const encrypted_file = options.input_file orelse ".env.encrypted";
    const old_key_file = options.key_file orelse ".env.key";
    const new_key_file = ".env.key.new";

    try writer.print("Loading old encryption key from: {s}\n", .{old_key_file});
    var old_key = try secure.SecureKey.fromFileWithIo(allocator, io, old_key_file);
    defer old_key.destroy();

    try writer.print("Generating new encryption key...\n", .{});
    var new_key = try secure.SecureKey.generateWithIo(io);
    defer new_key.destroy();

    try writer.print("Decrypting with old key...\n", .{});
    var secure_env_old = secure.SecureEnv.init(allocator, old_key);
    defer secure_env_old.deinit();

    try secure_env_old.loadFromFileWithIo(io, encrypted_file);

    try writer.print("Re-encrypting with new key...\n", .{});
    var secure_env_new = secure.SecureEnv.init(allocator, new_key);
    defer secure_env_new.deinit();

    var iter = secure_env_old.vars.iterator();
    var count: usize = 0;
    while (iter.next()) |entry| {
        const decrypted = try secure_env_old.get(entry.key_ptr.*);
        if (decrypted) |value| {
            defer allocator.free(value);
            try secure_env_new.setWithIo(io, entry.key_ptr.*, value);
            count += 1;
        }
    }

    // Save backup of old file
    const backup_file = try std.fmt.allocPrint(allocator, "{s}.backup", .{encrypted_file});
    defer allocator.free(backup_file);

    try Io.Dir.cwd().copyFile(encrypted_file, .cwd(), backup_file, io, .{});

    // Save new encrypted file
    try secure_env_new.saveToFileWithIo(io, encrypted_file);

    // Save new key
    try new_key.saveToFileWithIo(io, new_key_file);

    try writer.print("✓ Rotated encryption for {d} variables\n", .{count});
    try writer.print("✓ New key saved to: {s}\n", .{new_key_file});
    try writer.print("✓ Backup saved to: {s}\n", .{backup_file});
    try writer.print("\n", .{});
    try writer.print("Next steps:\n", .{});
    try writer.print("  1. Test that decryption works with the new key\n", .{});
    try writer.print("  2. Replace {s} with {s}\n", .{ old_key_file, new_key_file });
    try writer.print("  3. Securely share the new key with your team\n", .{});
    try writer.print("  4. Delete {s} and {s}\n", .{ new_key_file, backup_file });
}

fn cmdHelp(writer: *Io.Writer) !void {
    try writer.writeAll(
        \\Home Secure Environment Variables
        \\
        \\Usage: home env-secure <command> [options]
        \\
        \\Commands:
        \\  init                   Generate a new encryption key
        \\  encrypt                Encrypt a .env file
        \\  decrypt                Decrypt an encrypted .env file
        \\  add                    Add an encrypted variable
        \\  get                    Get and decrypt a variable
        \\  list                   List all encrypted variable names
        \\  rotate                 Rotate the encryption key
        \\  help                   Show this help message
        \\
        \\Options:
        \\  -i, --input <file>     Input file path
        \\  -o, --output <file>    Output file path
        \\  -k, --key <file>       Encryption key file path (default: .env.key)
        \\  -n, --name <name>      Variable name
        \\  -v, --value <value>    Variable value
        \\  -p, --password <pass>  Password for key derivation
        \\
        \\Examples:
        \\  # Generate encryption key
        \\  home env-secure init
        \\
        \\  # Encrypt .env file
        \\  home env-secure encrypt
        \\
        \\  # Decrypt to .env
        \\  home env-secure decrypt
        \\
        \\  # Add a new encrypted variable
        \\  home env-secure add -n API_KEY -v "secret123"
        \\
        \\  # Get a decrypted variable
        \\  home env-secure get -n API_KEY
        \\
        \\  # List all encrypted variables
        \\  home env-secure list
        \\
        \\  # Rotate encryption key
        \\  home env-secure rotate
        \\
        \\Security Best Practices:
        \\  • Never commit .env.key to version control
        \\  • Use .env.encrypted for storing secrets in git
        \\  • Rotate keys periodically
        \\  • Use strong passwords for key derivation
        \\  • Backup encryption keys securely
        \\
    );
}

test "parse init command" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const args = [_][]const u8{"init"};
    const options = try parseArgs(allocator, &args);

    try testing.expectEqual(Command.init, options.command);
}

test "parse encrypt command with options" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const args = [_][]const u8{ "encrypt", "-i", ".env", "-o", ".env.encrypted", "-k", ".env.key" };
    const options = try parseArgs(allocator, &args);

    try testing.expectEqual(Command.encrypt, options.command);
    try testing.expect(options.input_file != null);
    try testing.expectEqualStrings(".env", options.input_file.?);
    try testing.expectEqualStrings(".env.encrypted", options.output_file.?);
    try testing.expectEqualStrings(".env.key", options.key_file.?);
}

test "parse add command" {
    const testing = std.testing;
    const allocator = testing.allocator;

    const args = [_][]const u8{ "add", "-n", "API_KEY", "-v", "secret123" };
    const options = try parseArgs(allocator, &args);

    try testing.expectEqual(Command.add, options.command);
    try testing.expectEqualStrings("API_KEY", options.var_name.?);
    try testing.expectEqualStrings("secret123", options.var_value.?);
}

test "CLI writes through explicit IO and creates a loadable key" {
    const testing = std.testing;
    const allocator = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", allocator);
    defer allocator.free(root);
    const key_path = try std.fs.path.join(allocator, &.{ root, "cli.key" });
    defer allocator.free(key_path);

    var output: Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try executeToWriterWithIo(
        allocator,
        testing.io,
        .{ .command = .init, .key_file = key_path },
        &output.writer,
    );
    try testing.expect(std.mem.indexOf(u8, output.written(), "encryption key") != null);

    var key = try secure.SecureKey.fromFileWithIo(allocator, testing.io, key_path);
    defer key.destroy();
    try testing.expect(!std.mem.allEqual(u8, &key.key, 0));

    output.clearRetainingCapacity();
    try executeToWriterWithIo(allocator, testing.io, .{ .command = .help }, &output.writer);
    try testing.expect(std.mem.indexOf(u8, output.written(), "Usage: home env-secure") != null);
}
