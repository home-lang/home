const std = @import("std");

/// Command-line argument parsing for Ion
/// Provides ergonomic CLI argument and option handling

/// Argument type
pub const ArgType = enum {
    String,
    Int,
    Float,
    Bool,
    StringList,
};

/// Argument definition
pub const ArgDef = struct {
    name: []const u8,
    short: ?u8, // Short flag (single character)
    long: ?[]const u8, // Long flag
    arg_type: ArgType,
    required: bool,
    default: ?[]const u8,
    help: []const u8,
};

/// Parsed argument value
pub const ArgValue = union(ArgType) {
    String: []const u8,
    Int: i64,
    Float: f64,
    Bool: bool,
    StringList: [][]const u8,
};

/// Command-line argument parser
pub const ArgParser = struct {
    allocator: std.mem.Allocator,
    program_name: []const u8,
    description: []const u8,
    args: std.ArrayList(ArgDef),
    parsed: std.StringHashMap(ArgValue),
    positional: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator, program_name: []const u8, description: []const u8) ArgParser {
        return .{
            .allocator = allocator,
            .program_name = program_name,
            .description = description,
            .args = std.ArrayList(ArgDef).init(allocator),
            .parsed = std.StringHashMap(ArgValue).init(allocator),
            .positional = std.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *ArgParser) void {
        self.args.deinit();
        self.parsed.deinit();
        self.positional.deinit();
    }

    /// Add a string argument
    pub fn addString(self: *ArgParser, name: []const u8, short: ?u8, long: ?[]const u8, required: bool, default: ?[]const u8, help: []const u8) !void {
        try self.args.append(.{
            .name = name,
            .short = short,
            .long = long,
            .arg_type = .String,
            .required = required,
            .default = default,
            .help = help,
        });
    }

    /// Add an integer argument
    pub fn addInt(self: *ArgParser, name: []const u8, short: ?u8, long: ?[]const u8, required: bool, default: ?[]const u8, help: []const u8) !void {
        try self.args.append(.{
            .name = name,
            .short = short,
            .long = long,
            .arg_type = .Int,
            .required = required,
            .default = default,
            .help = help,
        });
    }

    /// Add a float argument
    pub fn addFloat(self: *ArgParser, name: []const u8, short: ?u8, long: ?[]const u8, required: bool, default: ?[]const u8, help: []const u8) !void {
        try self.args.append(.{
            .name = name,
            .short = short,
            .long = long,
            .arg_type = .Float,
            .required = required,
            .default = default,
            .help = help,
        });
    }

    /// Add a boolean flag
    pub fn addBool(self: *ArgParser, name: []const u8, short: ?u8, long: ?[]const u8, help: []const u8) !void {
        try self.args.append(.{
            .name = name,
            .short = short,
            .long = long,
            .arg_type = .Bool,
            .required = false,
            .default = "false",
            .help = help,
        });
    }

    /// Parse command-line arguments
    pub fn parse(self: *ArgParser, argv: []const []const u8) !void {
        var i: usize = 0;

        while (i < argv.len) {
            const arg = argv[i];

            if (std.mem.startsWith(u8, arg, "--")) {
                // Long option
                const flag_name = arg[2..];

                if (std.mem.eql(u8, flag_name, "help")) {
                    try self.printHelp();
                    std.process.exit(0);
                }

                const def = self.findArgByLong(flag_name) orelse {
                    std.debug.print("Unknown option: --{s}\n", .{flag_name});
                    return error.UnknownOption;
                };

                if (def.arg_type == .Bool) {
                    try self.parsed.put(def.name, .{ .Bool = true });
                } else {
                    // Next arg is the value
                    i += 1;
                    if (i >= argv.len) {
                        std.debug.print("Missing value for --{s}\n", .{flag_name});
                        return error.MissingValue;
                    }

                    try self.parseValue(def, argv[i]);
                }
            } else if (std.mem.startsWith(u8, arg, "-") and arg.len == 2) {
                // Short option
                const flag_char = arg[1];

                if (flag_char == 'h') {
                    try self.printHelp();
                    std.process.exit(0);
                }

                const def = self.findArgByShort(flag_char) orelse {
                    std.debug.print("Unknown option: -{c}\n", .{flag_char});
                    return error.UnknownOption;
                };

                if (def.arg_type == .Bool) {
                    try self.parsed.put(def.name, .{ .Bool = true });
                } else {
                    // Next arg is the value
                    i += 1;
                    if (i >= argv.len) {
                        std.debug.print("Missing value for -{c}\n", .{flag_char});
                        return error.MissingValue;
                    }

                    try self.parseValue(def, argv[i]);
                }
            } else {
                // Positional argument
                try self.positional.append(arg);
            }

            i += 1;
        }

        // Apply defaults and check required
        for (self.args.items) |def| {
            if (!self.parsed.contains(def.name)) {
                if (def.required) {
                    std.debug.print("Missing required argument: {s}\n", .{def.name});
                    return error.MissingRequired;
                }

                if (def.default) |default| {
                    try self.parseValue(&def, default);
                }
            }
        }
    }

    /// Parse value based on type
    fn parseValue(self: *ArgParser, def: *const ArgDef, value: []const u8) !void {
        switch (def.arg_type) {
            .String => try self.parsed.put(def.name, .{ .String = value }),
            .Int => {
                const int_val = std.fmt.parseInt(i64, value, 10) catch {
                    std.debug.print("Invalid integer for {s}: {s}\n", .{ def.name, value });
                    return error.InvalidInteger;
                };
                try self.parsed.put(def.name, .{ .Int = int_val });
            },
            .Float => {
                const float_val = std.fmt.parseFloat(f64, value) catch {
                    std.debug.print("Invalid float for {s}: {s}\n", .{ def.name, value });
                    return error.InvalidFloat;
                };
                try self.parsed.put(def.name, .{ .Float = float_val });
            },
            .Bool => try self.parsed.put(def.name, .{ .Bool = std.mem.eql(u8, value, "true") }),
            .StringList => {
                // For lists, split by comma
                var list = std.ArrayList([]const u8).init(self.allocator);
                var iter = std.mem.split(u8, value, ",");
                while (iter.next()) |item| {
                    try list.append(std.mem.trim(u8, item, " "));
                }
                try self.parsed.put(def.name, .{ .StringList = try list.toOwnedSlice() });
            },
        }
    }

    /// Find argument definition by long flag
    fn findArgByLong(self: *ArgParser, long: []const u8) ?*const ArgDef {
        for (self.args.items) |*def| {
            if (def.long) |l| {
                if (std.mem.eql(u8, l, long)) {
                    return def;
                }
            }
        }
        return null;
    }

    /// Find argument definition by short flag
    fn findArgByShort(self: *ArgParser, short: u8) ?*const ArgDef {
        for (self.args.items) |*def| {
            if (def.short) |s| {
                if (s == short) {
                    return def;
                }
            }
        }
        return null;
    }

    /// Get string value
    pub fn getString(self: *ArgParser, name: []const u8) ?[]const u8 {
        const value = self.parsed.get(name) orelse return null;
        return switch (value) {
            .String => |s| s,
            else => null,
        };
    }

    /// Get integer value
    pub fn getInt(self: *ArgParser, name: []const u8) ?i64 {
        const value = self.parsed.get(name) orelse return null;
        return switch (value) {
            .Int => |i| i,
            else => null,
        };
    }

    /// Get float value
    pub fn getFloat(self: *ArgParser, name: []const u8) ?f64 {
        const value = self.parsed.get(name) orelse return null;
        return switch (value) {
            .Float => |f| f,
            else => null,
        };
    }

    /// Get boolean value
    pub fn getBool(self: *ArgParser, name: []const u8) bool {
        const value = self.parsed.get(name) orelse return false;
        return switch (value) {
            .Bool => |b| b,
            else => false,
        };
    }

    /// Get string list value
    pub fn getStringList(self: *ArgParser, name: []const u8) ?[][]const u8 {
        const value = self.parsed.get(name) orelse return null;
        return switch (value) {
            .StringList => |list| list,
            else => null,
        };
    }

    /// Get positional arguments
    pub fn getPositional(self: *ArgParser) [][]const u8 {
        return self.positional.items;
    }

    /// Print help message
    pub fn printHelp(self: *ArgParser) !void {
        const stdout = std.io.getStdOut().writer();

        try stdout.print("{s}\n\n", .{self.description});
        try stdout.print("USAGE:\n", .{});
        try stdout.print("  {s} [OPTIONS]\n\n", .{self.program_name});
        try stdout.print("OPTIONS:\n", .{});

        // Print standard help
        try stdout.print("  -h, --help              Show this help message\n", .{});

        // Print defined arguments
        for (self.args.items) |def| {
            const short_str = if (def.short) |s| try std.fmt.allocPrint(self.allocator, "-{c}", .{s}) else try self.allocator.dupe(u8, "  ");
            defer self.allocator.free(short_str);

            const long_str = if (def.long) |l| try std.fmt.allocPrint(self.allocator, "--{s}", .{l}) else try self.allocator.dupe(u8, "");
            defer self.allocator.free(long_str);

            const required_str = if (def.required) "(required)" else "";
            const default_str = if (def.default) |d| try std.fmt.allocPrint(self.allocator, " [default: {s}]", .{d}) else try self.allocator.dupe(u8, "");
            defer self.allocator.free(default_str);

            try stdout.print("  {s}, {s: <20} {s} {s}{s}\n", .{ short_str, long_str, def.help, required_str, default_str });
        }

        try stdout.print("\n", .{});
    }
};

/// Simple argument parser for common patterns
pub const SimpleArgs = struct {
    allocator: std.mem.Allocator,
    args: std.StringHashMap([]const u8),
    flags: std.StringHashMap(bool),
    positional: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator) SimpleArgs {
        return .{
            .allocator = allocator,
            .args = std.StringHashMap([]const u8).init(allocator),
            .flags = std.StringHashMap(bool).init(allocator),
            .positional = std.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *SimpleArgs) void {
        self.args.deinit();
        self.flags.deinit();
        self.positional.deinit();
    }

    /// Parse argv simply
    pub fn parse(self: *SimpleArgs, argv: []const []const u8) !void {
        var i: usize = 0;

        while (i < argv.len) {
            const arg = argv[i];

            if (std.mem.startsWith(u8, arg, "--")) {
                const key = arg[2..];

                if (i + 1 < argv.len and !std.mem.startsWith(u8, argv[i + 1], "-")) {
                    // Has value
                    i += 1;
                    try self.args.put(key, argv[i]);
                } else {
                    // Boolean flag
                    try self.flags.put(key, true);
                }
            } else if (std.mem.startsWith(u8, arg, "-")) {
                const key = arg[1..];

                if (i + 1 < argv.len and !std.mem.startsWith(u8, argv[i + 1], "-")) {
                    // Has value
                    i += 1;
                    try self.args.put(key, argv[i]);
                } else {
                    // Boolean flag
                    try self.flags.put(key, true);
                }
            } else {
                // Positional
                try self.positional.append(arg);
            }

            i += 1;
        }
    }

    pub fn get(self: *SimpleArgs, key: []const u8) ?[]const u8 {
        return self.args.get(key);
    }

    pub fn has(self: *SimpleArgs, key: []const u8) bool {
        return self.flags.get(key) orelse false;
    }

    pub fn getPositional(self: *SimpleArgs) [][]const u8 {
        return self.positional.items;
    }
};

/// Environment variable helpers
pub const Env = struct {
    /// Get environment variable
    pub fn get(allocator: std.mem.Allocator, key: []const u8) !?[]const u8 {
        return std.process.getEnvVarOwned(allocator, key) catch |err| {
            if (err == error.EnvironmentVariableNotFound) return null;
            return err;
        };
    }

    /// Get with default
    pub fn getOrDefault(allocator: std.mem.Allocator, key: []const u8, default: []const u8) ![]const u8 {
        return (try get(allocator, key)) orelse default;
    }

    /// Set environment variable
    pub fn set(key: []const u8, value: []const u8) !void {
        try std.process.setEnvVar(key, value);
    }
};
