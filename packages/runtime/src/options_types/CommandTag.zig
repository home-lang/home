// Copied from bun/src/options_types/CommandTag.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../cli/LICENSE.bun.md.
// Imports rewritten: @import("bun") → @import("home"). The `params()` /
// `printHelp()` aliases at the bottom of upstream point at `runtime/cli/cli.zig`
// (`Command.tagParams` / `Command.tagPrintHelp`) and are intentionally omitted
// — they re-land alongside the broader CLI command surface in Phase 12.10.

//! `bun.cli.Command.Tag` — the top-level CLI subcommand discriminant.
//! Extracted to `options_types/` so lower tiers (install/, bundler/) can
//! switch on which command is running without importing `cli/`.
//!
//! Heavy methods that reference `Arguments`/`HelpCommand`/`clap` (`params()`,
//! `printHelp()`) live in `src/cli/cli.zig` as free fns; only the pure enum,
//! `char()`, classifier predicates, and the `EnumArray` flag tables are here.

pub const Tag = enum {
    AddCommand,
    AutoCommand,
    BuildCommand,
    BunxCommand,
    CreateCommand,
    DiscordCommand,
    GetCompletionsCommand,
    HelpCommand,
    InitCommand,
    InfoCommand,
    InstallCommand,
    InstallCompletionsCommand,
    LinkCommand,
    PackageManagerCommand,
    RemoveCommand,
    RunCommand,
    RunAsNodeCommand, // arg0 == 'node'
    TestCommand,
    UnlinkCommand,
    UpdateCommand,
    UpgradeCommand,
    ReplCommand,
    ReservedCommand,
    ExecCommand,
    PatchCommand,
    PatchCommitCommand,
    OutdatedCommand,
    UpdateInteractiveCommand,
    PublishCommand,
    AuditCommand,
    WhyCommand,
    FuzzilliCommand,

    /// Used by crash reports.
    ///
    /// This must be kept in sync with https://github.com/oven-sh/bun.report/blob/62601d8aafb9c0d29554dfc3f8854044ec04d367/backend/remap.ts#L10
    pub fn char(this: Tag) u8 {
        return switch (this) {
            .AddCommand => 'I',
            .AutoCommand => 'a',
            .BuildCommand => 'b',
            .BunxCommand => 'B',
            .CreateCommand => 'c',
            .DiscordCommand => 'D',
            .GetCompletionsCommand => 'g',
            .HelpCommand => 'h',
            .InitCommand => 'j',
            .InfoCommand => 'v',
            .InstallCommand => 'i',
            .InstallCompletionsCommand => 'C',
            .LinkCommand => 'l',
            .PackageManagerCommand => 'P',
            .RemoveCommand => 'R',
            .RunCommand => 'r',
            .RunAsNodeCommand => 'n',
            .TestCommand => 't',
            .UnlinkCommand => 'U',
            .UpdateCommand => 'u',
            .UpgradeCommand => 'p',
            .ReplCommand => 'G',
            .ReservedCommand => 'w',
            .ExecCommand => 'e',
            .PatchCommand => 'x',
            .PatchCommitCommand => 'z',
            .OutdatedCommand => 'o',
            .UpdateInteractiveCommand => 'U',
            .PublishCommand => 'k',
            .AuditCommand => 'A',
            .WhyCommand => 'W',
            .FuzzilliCommand => 'F',
        };
    }

    pub fn readGlobalConfig(this: Tag) bool {
        return switch (this) {
            .BunxCommand,
            .PackageManagerCommand,
            .InstallCommand,
            .AddCommand,
            .RemoveCommand,
            .UpdateCommand,
            .PatchCommand,
            .PatchCommitCommand,
            .OutdatedCommand,
            .PublishCommand,
            .AuditCommand,
            => true,
            else => false,
        };
    }

    pub fn isNPMRelated(this: Tag) bool {
        return switch (this) {
            .BunxCommand,
            .LinkCommand,
            .UnlinkCommand,
            .PackageManagerCommand,
            .InstallCommand,
            .AddCommand,
            .RemoveCommand,
            .UpdateCommand,
            .PatchCommand,
            .PatchCommitCommand,
            .OutdatedCommand,
            .PublishCommand,
            .AuditCommand,
            => true,
            else => false,
        };
    }

    pub const loads_config: std.EnumArray(Tag, bool) = std.EnumArray(Tag, bool).initDefault(false, .{
        .BuildCommand = true,
        .TestCommand = true,
        .InstallCommand = true,
        .AddCommand = true,
        .RemoveCommand = true,
        .UpdateCommand = true,
        .PatchCommand = true,
        .PatchCommitCommand = true,
        .PackageManagerCommand = true,
        .BunxCommand = true,
        .AutoCommand = true,
        .RunCommand = true,
        .RunAsNodeCommand = true,
        .OutdatedCommand = true,
        .UpdateInteractiveCommand = true,
        .PublishCommand = true,
        .AuditCommand = true,
    });

    pub const always_loads_config: std.EnumArray(Tag, bool) = std.EnumArray(Tag, bool).initDefault(false, .{
        .BuildCommand = true,
        .TestCommand = true,
        .InstallCommand = true,
        .AddCommand = true,
        .RemoveCommand = true,
        .UpdateCommand = true,
        .PatchCommand = true,
        .PatchCommitCommand = true,
        .PackageManagerCommand = true,
        .BunxCommand = true,
        .OutdatedCommand = true,
        .UpdateInteractiveCommand = true,
        .PublishCommand = true,
        .AuditCommand = true,
    });

    pub const uses_global_options: std.EnumArray(Tag, bool) = std.EnumArray(Tag, bool).initDefault(true, .{
        .AddCommand = false,
        .AuditCommand = false,
        .BunxCommand = false,
        .CreateCommand = false,
        .InfoCommand = false,
        .InstallCommand = false,
        .LinkCommand = false,
        .OutdatedCommand = false,
        .UpdateInteractiveCommand = false,
        .PackageManagerCommand = false,
        .PatchCommand = false,
        .PatchCommitCommand = false,
        .PublishCommand = false,
        .RemoveCommand = false,
        .UnlinkCommand = false,
        .UpdateCommand = false,
    });

    // JSC-bridge / CLI cross-cuts omitted — re-land in Phase 12.10:
    //   pub const params = @import("../runtime/cli/cli.zig").Command.tagParams;
    //   pub const printHelp = @import("../runtime/cli/cli.zig").Command.tagPrintHelp;
};

test "Tag.char round-trips a sampling of commands" {
    try std.testing.expectEqual(@as(u8, 'b'), Tag.BuildCommand.char());
    try std.testing.expectEqual(@as(u8, 't'), Tag.TestCommand.char());
    try std.testing.expectEqual(@as(u8, 'r'), Tag.RunCommand.char());
    try std.testing.expectEqual(@as(u8, 'i'), Tag.InstallCommand.char());
    try std.testing.expectEqual(@as(u8, 'B'), Tag.BunxCommand.char());
}

test "Tag.char values are unique modulo the documented duplicates" {
    // `RunAsNodeCommand` shares 'n', `UnlinkCommand` and
    // `UpdateInteractiveCommand` both map to 'U' upstream — kept verbatim so
    // crash-report decoders stay compatible.
    var seen = std.AutoHashMap(u8, void).init(std.testing.allocator);
    defer seen.deinit();
    var duplicates: usize = 0;
    inline for (std.meta.tags(Tag)) |t| {
        const c = t.char();
        if (seen.contains(c)) {
            duplicates += 1;
        } else {
            try seen.put(c, {});
        }
    }
    // 'U' is reused by UnlinkCommand + UpdateInteractiveCommand. Anything
    // beyond that single duplicate signals an upstream sync drift.
    try std.testing.expect(duplicates <= 1);
}

test "Tag.readGlobalConfig flags package-manager subcommands" {
    try std.testing.expect(Tag.InstallCommand.readGlobalConfig());
    try std.testing.expect(Tag.AddCommand.readGlobalConfig());
    try std.testing.expect(Tag.AuditCommand.readGlobalConfig());
    try std.testing.expect(!Tag.BuildCommand.readGlobalConfig());
    try std.testing.expect(!Tag.RunCommand.readGlobalConfig());
}

test "Tag.isNPMRelated covers install + helper verbs" {
    try std.testing.expect(Tag.InstallCommand.isNPMRelated());
    try std.testing.expect(Tag.LinkCommand.isNPMRelated());
    try std.testing.expect(Tag.UnlinkCommand.isNPMRelated());
    try std.testing.expect(Tag.AuditCommand.isNPMRelated());
    try std.testing.expect(!Tag.BuildCommand.isNPMRelated());
    try std.testing.expect(!Tag.HelpCommand.isNPMRelated());
}

test "Tag flag tables flip the expected defaults" {
    try std.testing.expect(Tag.loads_config.get(.BuildCommand));
    try std.testing.expect(Tag.loads_config.get(.InstallCommand));
    try std.testing.expect(!Tag.loads_config.get(.HelpCommand));

    try std.testing.expect(Tag.always_loads_config.get(.InstallCommand));
    try std.testing.expect(!Tag.always_loads_config.get(.RunCommand));

    try std.testing.expect(Tag.uses_global_options.get(.BuildCommand));
    try std.testing.expect(!Tag.uses_global_options.get(.InstallCommand));
    try std.testing.expect(!Tag.uses_global_options.get(.PublishCommand));
}

const std = @import("std");
