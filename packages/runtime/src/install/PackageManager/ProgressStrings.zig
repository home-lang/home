// Copied from bun/src/install/PackageManager/ProgressStrings.zig at upstream
// SHA fd0b6f1a271fca0b8124b69f230b100f4d636af6. MIT — see ../../cli/LICENSE.bun.md.
//
// Home keeps only the pure progress-label descriptors here. Upstream also
// mutates `PackageManager` progress nodes through `bun.Output`/`bun.Progress`;
// that behavior remains intentionally unwired so Pantry can own package-manager
// UI/tooling policy.

const string = []const u8;

pub const RenderMode = enum {
    plain,
    emoji,
};

pub const ProgressStrings = struct {
    pub const download_no_emoji_ = "Resolving";
    pub const download_no_emoji: string = download_no_emoji_ ++ "\n";
    pub const download_with_emoji: string = download_emoji ++ download_no_emoji_;
    pub const download_emoji: string = "  🔍 ";

    pub const extract_no_emoji_ = "Resolving & extracting";
    pub const extract_no_emoji: string = extract_no_emoji_ ++ "\n";
    pub const extract_with_emoji: string = extract_emoji ++ extract_no_emoji_;
    pub const extract_emoji: string = "  🚚 ";

    pub const install_no_emoji_ = "Installing";
    pub const install_no_emoji: string = install_no_emoji_ ++ "\n";
    pub const install_with_emoji: string = install_emoji ++ install_no_emoji_;
    pub const install_emoji: string = "  📦 ";

    pub const save_no_emoji_ = "Saving lockfile";
    pub const save_no_emoji: string = save_no_emoji_;
    pub const save_with_emoji: string = save_emoji ++ save_no_emoji_;
    pub const save_emoji: string = "  🔒 ";

    pub const script_no_emoji_ = "Running script";
    pub const script_no_emoji: string = script_no_emoji_ ++ "\n";
    pub const script_with_emoji: string = script_emoji ++ script_no_emoji_;
    pub const script_emoji: string = "  ⚙️  ";

    pub inline fn download(mode: RenderMode) string {
        return if (mode == .emoji) download_with_emoji else download_no_emoji;
    }

    pub inline fn save(mode: RenderMode) string {
        return if (mode == .emoji) save_with_emoji else save_no_emoji;
    }

    pub inline fn extract(mode: RenderMode) string {
        return if (mode == .emoji) extract_with_emoji else extract_no_emoji;
    }

    pub inline fn install(mode: RenderMode) string {
        return if (mode == .emoji) install_with_emoji else install_no_emoji;
    }

    pub inline fn script(mode: RenderMode) string {
        return if (mode == .emoji) script_with_emoji else script_no_emoji;
    }
};

test "ProgressStrings returns plain Bun labels" {
    const std = @import("std");
    try std.testing.expectEqualStrings("Resolving\n", ProgressStrings.download(.plain));
    try std.testing.expectEqualStrings("Resolving & extracting\n", ProgressStrings.extract(.plain));
    try std.testing.expectEqualStrings("Installing\n", ProgressStrings.install(.plain));
    try std.testing.expectEqualStrings("Saving lockfile", ProgressStrings.save(.plain));
    try std.testing.expectEqualStrings("Running script\n", ProgressStrings.script(.plain));
}

test "ProgressStrings returns upstream emoji-prefixed labels" {
    const std = @import("std");
    try std.testing.expectEqualStrings(ProgressStrings.download_emoji ++ ProgressStrings.download_no_emoji_, ProgressStrings.download(.emoji));
    try std.testing.expectEqualStrings(ProgressStrings.extract_emoji ++ ProgressStrings.extract_no_emoji_, ProgressStrings.extract(.emoji));
    try std.testing.expectEqualStrings(ProgressStrings.install_emoji ++ ProgressStrings.install_no_emoji_, ProgressStrings.install(.emoji));
    try std.testing.expectEqualStrings(ProgressStrings.save_emoji ++ ProgressStrings.save_no_emoji_, ProgressStrings.save(.emoji));
    try std.testing.expectEqualStrings(ProgressStrings.script_emoji ++ ProgressStrings.script_no_emoji_, ProgressStrings.script(.emoji));
}
