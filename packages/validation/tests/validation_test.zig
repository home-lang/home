const std = @import("std");
const validation = @import("validation");
const messages = @import("validation_messages");
const rules = @import("validation_rules");

test "validation: public modules are reachable" {
    std.testing.refAllDecls(validation);
    std.testing.refAllDecls(messages);
    std.testing.refAllDecls(rules);
}

test "validation: context obtains time through injected Io" {
    var config = validation.ValidationConfig{};
    config.parse_timeout_ms = 1;

    var context = validation.ValidationContext.init(std.testing.io, config);
    try std.testing.expect(context.start_time > 0);

    context.start_time -= 2;
    try std.testing.expectError(validation.ValidationError.Timeout, context.checkTimeout());

    context.setPhase(.type_checking);
    try std.testing.expectEqual(validation.ValidationContext.Phase.type_checking, context.phase);
    try std.testing.expect(context.start_time > 0);
}

test "validation: zero timeout remains disabled" {
    var config = validation.ValidationConfig{};
    config.parse_timeout_ms = 0;

    var context = validation.ValidationContext.init(std.testing.io, config);
    context.start_time = std.math.minInt(i64);
    try context.checkTimeout();
}

test "validation: input checks reject malformed input" {
    const validator = validation.InputValidator.init(.{});
    try std.testing.expectError(validation.ValidationError.InvalidUtf8, validator.validateInput("\xff"));
    try std.testing.expectError(validation.ValidationError.NullByteInInput, validator.validateInput("a\x00b"));
    try std.testing.expect(rules.isEmail("user@example.com"));
}
