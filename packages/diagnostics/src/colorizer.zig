const std = @import("std");

/// Terminal color and styling utilities for diagnostic output
pub const Colorizer = struct {
    enabled: bool,

    pub fn init(enabled: bool) Colorizer {
        return .{ .enabled = enabled };
    }

    /// Detect if terminal supports colors
    pub fn detectColorSupport() bool {
        // Check common environment variables
        if (std.process.getEnvVarOwned(std.heap.page_allocator, "NO_COLOR")) |val| {
            std.heap.page_allocator.free(val);
            return false;
        } else |_| {}

        if (std.process.getEnvVarOwned(std.heap.page_allocator, "TERM")) |term| {
            defer std.heap.page_allocator.free(term);
            if (std.mem.eql(u8, term, "dumb")) {
                return false;
            }
            // Most modern terminals support color
            return true;
        } else |_| {}

        // Check if output is a TTY
        return std.io.getStdErr().isTty();
    }

    pub const Style = struct {
        fg_color: ?Color = null,
        bg_color: ?Color = null,
        bold: bool = false,
        dim: bool = false,
        italic: bool = false,
        underline: bool = false,

        pub const Color = enum {
            black,
            red,
            green,
            yellow,
            blue,
            magenta,
            cyan,
            white,
            bright_black,
            bright_red,
            bright_green,
            bright_yellow,
            bright_blue,
            bright_magenta,
            bright_cyan,
            bright_white,

            pub fn fgCode(self: Color) u8 {
                return switch (self) {
                    .black => 30,
                    .red => 31,
                    .green => 32,
                    .yellow => 33,
                    .blue => 34,
                    .magenta => 35,
                    .cyan => 36,
                    .white => 37,
                    .bright_black => 90,
                    .bright_red => 91,
                    .bright_green => 92,
                    .bright_yellow => 93,
                    .bright_blue => 94,
                    .bright_magenta => 95,
                    .bright_cyan => 96,
                    .bright_white => 97,
                };
            }

            pub fn bgCode(self: Color) u8 {
                return switch (self) {
                    .black => 40,
                    .red => 41,
                    .green => 42,
                    .yellow => 43,
                    .blue => 44,
                    .magenta => 45,
                    .cyan => 46,
                    .white => 47,
                    .bright_black => 100,
                    .bright_red => 101,
                    .bright_green => 102,
                    .bright_yellow => 103,
                    .bright_blue => 104,
                    .bright_magenta => 105,
                    .bright_cyan => 106,
                    .bright_white => 107,
                };
            }
        };

        pub fn toAnsiCode(self: Style, buf: []u8) ![]const u8 {
            var stream = std.io.fixedBufferStream(buf);
            const writer = stream.writer();

            try writer.writeAll("\x1b[");

            var need_semicolon = false;

            if (self.bold) {
                try writer.writeAll("1");
                need_semicolon = true;
            }

            if (self.dim) {
                if (need_semicolon) try writer.writeAll(";");
                try writer.writeAll("2");
                need_semicolon = true;
            }

            if (self.italic) {
                if (need_semicolon) try writer.writeAll(";");
                try writer.writeAll("3");
                need_semicolon = true;
            }

            if (self.underline) {
                if (need_semicolon) try writer.writeAll(";");
                try writer.writeAll("4");
                need_semicolon = true;
            }

            if (self.fg_color) |fg| {
                if (need_semicolon) try writer.writeAll(";");
                try writer.print("{d}", .{fg.fgCode()});
                need_semicolon = true;
            }

            if (self.bg_color) |bg| {
                if (need_semicolon) try writer.writeAll(";");
                try writer.print("{d}", .{bg.bgCode()});
            }

            try writer.writeAll("m");

            return stream.getWritten();
        }
    };

    /// Apply style to text
    pub fn styled(self: Colorizer, allocator: std.mem.Allocator, text: []const u8, style: Style) ![]u8 {
        if (!self.enabled) {
            return try allocator.dupe(u8, text);
        }

        var buf: [64]u8 = undefined;
        const code = try style.toAnsiCode(&buf);

        return try std.fmt.allocPrint(allocator, "{s}{s}\x1b[0m", .{ code, text });
    }

    /// Shorthand styling functions
    pub fn bold(self: Colorizer, allocator: std.mem.Allocator, text: []const u8) ![]u8 {
        return self.styled(allocator, text, .{ .bold = true });
    }

    pub fn dim(self: Colorizer, allocator: std.mem.Allocator, text: []const u8) ![]u8 {
        return self.styled(allocator, text, .{ .dim = true });
    }

    pub fn red(self: Colorizer, allocator: std.mem.Allocator, text: []const u8) ![]u8 {
        return self.styled(allocator, text, .{ .fg_color = .red });
    }

    pub fn green(self: Colorizer, allocator: std.mem.Allocator, text: []const u8) ![]u8 {
        return self.styled(allocator, text, .{ .fg_color = .green });
    }

    pub fn yellow(self: Colorizer, allocator: std.mem.Allocator, text: []const u8) ![]u8 {
        return self.styled(allocator, text, .{ .fg_color = .yellow });
    }

    pub fn blue(self: Colorizer, allocator: std.mem.Allocator, text: []const u8) ![]u8 {
        return self.styled(allocator, text, .{ .fg_color = .blue });
    }

    pub fn cyan(self: Colorizer, allocator: std.mem.Allocator, text: []const u8) ![]u8 {
        return self.styled(allocator, text, .{ .fg_color = .cyan });
    }

    pub fn magenta(self: Colorizer, allocator: std.mem.Allocator, text: []const u8) ![]u8 {
        return self.styled(allocator, text, .{ .fg_color = .magenta });
    }
};

/// Pre-defined color schemes for diagnostics
pub const ColorScheme = struct {
    error_color: Colorizer.Style.Color,
    warning_color: Colorizer.Style.Color,
    info_color: Colorizer.Style.Color,
    hint_color: Colorizer.Style.Color,
    line_number_color: Colorizer.Style.Color,
    gutter_color: Colorizer.Style.Color,
    caret_color: Colorizer.Style.Color,

    /// Default color scheme (similar to Rust's compiler)
    pub fn default() ColorScheme {
        return .{
            .error_color = .red,
            .warning_color = .yellow,
            .info_color = .blue,
            .hint_color = .cyan,
            .line_number_color = .blue,
            .gutter_color = .blue,
            .caret_color = .red,
        };
    }

    /// High contrast scheme for accessibility
    pub fn highContrast() ColorScheme {
        return .{
            .error_color = .bright_red,
            .warning_color = .bright_yellow,
            .info_color = .bright_blue,
            .hint_color = .bright_cyan,
            .line_number_color = .bright_blue,
            .gutter_color = .bright_blue,
            .caret_color = .bright_red,
        };
    }

    /// Monochrome scheme (for terminals with limited color support)
    pub fn monochrome() ColorScheme {
        return .{
            .error_color = .white,
            .warning_color = .white,
            .info_color = .white,
            .hint_color = .white,
            .line_number_color = .white,
            .gutter_color = .white,
            .caret_color = .white,
        };
    }
};

/// Unicode box-drawing characters for fancy output
pub const BoxDrawing = struct {
    pub const vertical = "│";
    pub const horizontal = "─";
    pub const top_left = "┌";
    pub const top_right = "┐";
    pub const bottom_left = "└";
    pub const bottom_right = "┘";
    pub const vertical_right = "├";
    pub const vertical_left = "┤";
    pub const horizontal_down = "┬";
    pub const horizontal_up = "┴";
    pub const cross = "┼";

    /// Check if terminal supports Unicode
    pub fn supportsUnicode() bool {
        if (std.process.getEnvVarOwned(std.heap.page_allocator, "LANG")) |lang| {
            defer std.heap.page_allocator.free(lang);
            return std.mem.indexOf(u8, lang, "UTF-8") != null or
                std.mem.indexOf(u8, lang, "utf8") != null;
        } else |_| {}

        return false;
    }
};

test "Colorizer.styled" {
    const testing = std.testing;
    const allocator = testing.allocator;

    var colorizer = Colorizer.init(true);

    const styled_text = try colorizer.red(allocator, "error");
    defer allocator.free(styled_text);

    try testing.expect(std.mem.startsWith(u8, styled_text, "\x1b["));
    try testing.expect(std.mem.endsWith(u8, styled_text, "\x1b[0m"));
}

test "Style.toAnsiCode" {
    const testing = std.testing;

    const style = Colorizer.Style{
        .fg_color = .red,
        .bold = true,
    };

    var buf: [64]u8 = undefined;
    const code = try style.toAnsiCode(&buf);

    try testing.expect(std.mem.indexOf(u8, code, "1") != null); // bold
    try testing.expect(std.mem.indexOf(u8, code, "31") != null); // red
}
