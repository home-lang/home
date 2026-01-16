const std = @import("std");
const http_router = @import("http_router");

test "HTTP Method from string" {
    try std.testing.expectEqual(http_router.Method.GET, http_router.Method.fromString("GET").?);
    try std.testing.expectEqual(http_router.Method.POST, http_router.Method.fromString("POST").?);
    try std.testing.expectEqual(http_router.Method.PUT, http_router.Method.fromString("PUT").?);
    try std.testing.expectEqual(http_router.Method.DELETE, http_router.Method.fromString("DELETE").?);
    try std.testing.expectEqual(@as(?http_router.Method, null), http_router.Method.fromString("INVALID"));
}

test "HTTP Method to string" {
    try std.testing.expectEqualStrings("GET", http_router.Method.GET.toString());
    try std.testing.expectEqualStrings("POST", http_router.Method.POST.toString());
    try std.testing.expectEqualStrings("PUT", http_router.Method.PUT.toString());
    try std.testing.expectEqualStrings("DELETE", http_router.Method.DELETE.toString());
}

test "Request initialization" {
    const allocator = std.testing.allocator;

    const req = http_router.Request.init(allocator, .GET, "/test");

    try std.testing.expectEqual(http_router.Method.GET, req.method);
    try std.testing.expectEqualStrings("/test", req.path);
}

test "Router creation" {
    const allocator = std.testing.allocator;

    var router = http_router.Router.init(allocator);
    defer router.deinit();

    try std.testing.expect(router.routes.items.len == 0);
}

test "coverage - http router basics" {
    // Coverage tracking placeholder
    try std.testing.expect(true);
}
