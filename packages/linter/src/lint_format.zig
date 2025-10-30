const std = @import("std");
const linter_mod = @import("linter.zig");
const Linter = linter_mod.Linter;
const LinterConfig = linter_mod.LinterConfig;
const LintDiagnostic = linter_mod.LintDiagnostic;
const Severity = linter_mod.Severity;

/// Unified lint and format tool for Home language
/// Combines linting with auto-fixing and formatting in one pass
pub const LintFormat = struct {
    allocator: std.mem.Allocator,
    linter: Linter,
    
    pub const Options = struct {
        check_only: bool = false,
        fix: bool = true,
        format: bool = true,
        show_diagnostics: bool = true,
    };

    pub fn init(allocator: std.mem.Allocator, config: LinterConfig) LintFormat {
        return .{
            .allocator = allocator,
            .linter = Linter.init(allocator, config),
        };
    }

    pub fn deinit(self: *LintFormat) void {
        self.linter.deinit();
    }

    /// Run linter and optionally apply fixes and formatting
    pub fn run(self: *LintFormat, source: []const u8, options: Options) !Result {
        // First pass: lint the code
        const diagnostics = try self.linter.lint(source);

        if (options.check_only) {
            return Result{
                .diagnostics = diagnostics,
                .formatted_source = null,
                .fixed = false,
            };
        }

        var fixed_source = source;
        var needs_free = false;

        // Second pass: apply auto-fixes if requested
        if (options.fix and diagnostics.len > 0) {
            const auto_fixed = try self.linter.autoFix();
            if (auto_fixed.len > 0) {
                fixed_source = auto_fixed;
                needs_free = true;
            }
        }

        // Third pass: format if requested
        if (options.format) {
            // The formatter will be called separately via the formatter package
            // This is just the coordination layer
        }

        return Result{
            .diagnostics = diagnostics,
            .formatted_source = if (needs_free) fixed_source else null,
            .fixed = needs_free,
        };
    }

    pub const Result = struct {
        diagnostics: []LintDiagnostic,
        formatted_source: ?[]const u8,
        fixed: bool,
    };
};

/// Print diagnostics in a human-readable format
pub fn printDiagnostics(
    writer: anytype,
    diagnostics: []const LintDiagnostic,
    source_path: []const u8,
) !void {
    for (diagnostics) |diag| {
        const severity_color = switch (diag.severity) {
            .error_ => "\x1b[31m", // Red
            .warning => "\x1b[33m", // Yellow
            .info => "\x1b[36m", // Cyan
            .hint => "\x1b[90m", // Gray
        };
        const reset = "\x1b[0m";

        try writer.print(
            "{s}:{d}:{d} {s}{s}{s}: {s} [{s}]\n",
            .{
                source_path,
                diag.line,
                diag.column,
                severity_color,
                diag.severity.toString(),
                reset,
                diag.message,
                diag.rule_id,
            },
        );

        if (diag.fix) |fix| {
            try writer.print("  💡 {s}\n", .{fix.message});
        }
    }
}

/// Count diagnostics by severity
pub fn countBySeverity(diagnostics: []const LintDiagnostic) struct {
    errors: usize,
    warnings: usize,
    info: usize,
    hints: usize,
} {
    var result = .{ .errors = 0, .warnings = 0, .info = 0, .hints = 0 };
    
    for (diagnostics) |diag| {
        switch (diag.severity) {
            .error_ => result.errors += 1,
            .warning => result.warnings += 1,
            .info => result.info += 1,
            .hint => result.hints += 1,
        }
    }
    
    return result;
}
