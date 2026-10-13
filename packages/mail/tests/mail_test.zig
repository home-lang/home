const std = @import("std");
const mail = @import("mail");

test "public mail declarations compile" {
    std.testing.refAllDecls(mail);
    std.testing.refAllDecls(mail.Message);
    std.testing.refAllDecls(mail.MemoryTransport);
    std.testing.refAllDecls(mail.SmtpTransport);
}

test "public memory transport records a message" {
    const transport = try mail.MemoryTransport.init(std.testing.allocator, std.testing.io);
    defer transport.deinit();

    var message = mail.Message.init(std.testing.allocator);
    defer message.deinit();
    _ = message.setFrom("sender@example.com", null);
    _ = try message.addTo("recipient@example.com", null);
    _ = message.setSubject("subject");
    _ = message.setText("body");

    try transport.transport().send(&message);
    const sent = transport.getSentMessages();
    try std.testing.expectEqual(@as(usize, 1), sent.len);
    try std.testing.expectEqualStrings("sender@example.com", sent[0].from);
    try std.testing.expectEqualStrings("recipient@example.com", sent[0].to[0]);
    try std.testing.expectEqualStrings("subject", sent[0].subject);
    try std.testing.expectEqualStrings("body", sent[0].body);
}
