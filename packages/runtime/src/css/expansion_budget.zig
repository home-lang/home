const std = @import("std");

pub const MAX_SELECTOR_EXPANSION: u32 = 65_536;
pub const MAX_NESTING_EXPANSIONS: u32 = 65_536;

/// Charge the selector fan-out of one nested rule. Returns false once the
/// stylesheet-wide limit has been exceeded.
pub fn chargeSelector(total: *u32, multiplier: u32, selector_count: u32) bool {
    if (multiplier <= 1) return true;
    total.* +|= multiplier *| @max(selector_count, 1);
    return total.* <= MAX_SELECTOR_EXPANSION;
}

/// Compute the fan-out inherited by a nested rule. Saturation ensures an
/// overflow remains over budget instead of wrapping to a small value.
pub fn multiplySelectorFanout(multiplier: u32, selector_count: u32) u32 {
    return multiplier *| @max(selector_count, 1);
}

/// Charge one recursive parent-selector substitution in a rule prelude.
pub fn chargeNesting(expansions: *u32) bool {
    expansions.* += 1;
    return expansions.* <= MAX_NESTING_EXPANSIONS;
}

test "selector expansion permits the limit and rejects the next charge" {
    var total: u32 = MAX_SELECTOR_EXPANSION - 2;
    try std.testing.expect(chargeSelector(&total, 2, 1));
    try std.testing.expectEqual(MAX_SELECTOR_EXPANSION, total);
    try std.testing.expect(!chargeSelector(&total, 2, 1));
    try std.testing.expectEqual(MAX_SELECTOR_EXPANSION + 2, total);
}

test "selector expansion arithmetic saturates instead of wrapping" {
    var total: u32 = std.math.maxInt(u32) - 1;
    try std.testing.expect(!chargeSelector(&total, std.math.maxInt(u32), 2));
    try std.testing.expectEqual(std.math.maxInt(u32), total);
    try std.testing.expectEqual(
        std.math.maxInt(u32),
        multiplySelectorFanout(std.math.maxInt(u32), 2),
    );
}

test "top-level selectors are not charged" {
    var total: u32 = 0;
    try std.testing.expect(chargeSelector(&total, 1, std.math.maxInt(u32)));
    try std.testing.expectEqual(@as(u32, 0), total);
}

test "nesting substitutions permit the limit and reject the next one" {
    var expansions: u32 = MAX_NESTING_EXPANSIONS - 1;
    try std.testing.expect(chargeNesting(&expansions));
    try std.testing.expect(!chargeNesting(&expansions));
}
