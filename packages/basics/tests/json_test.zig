const std = @import("std");
const json_module = @import("basics_json");
const testing = std.testing;

test "JSON parse, compact and pretty serialization round trip nested values" {
    var json = json_module.Json.init(testing.allocator);
    var value = try json.parse("{\"enabled\":true,\"items\":[null,2.5,\"line\\nquote\\\"\"]}");
    defer value.deinit(testing.allocator);

    try testing.expectEqual(true, value.get("enabled").?.asBool().?);
    const items = value.get("items").?.asArray().?;
    try testing.expectEqual(@as(usize, 3), items.len);
    try testing.expectEqual(@as(f64, 2.5), items[1].asNumber().?);
    try testing.expectEqualStrings("line\nquote\"", items[2].asString().?);

    const compact = try json.stringify(value);
    defer testing.allocator.free(compact);
    var compact_value = try json.parse(compact);
    defer compact_value.deinit(testing.allocator);
    try testing.expectEqualStrings("line\nquote\"", compact_value.get("items").?.at(2).?.asString().?);

    const pretty = try json.stringifyPretty(value);
    defer testing.allocator.free(pretty);
    try testing.expect(std.mem.indexOfScalar(u8, pretty, '\n') != null);
    var pretty_value = try json.parse(pretty);
    defer pretty_value.deinit(testing.allocator);
    try testing.expect(pretty_value.get("enabled").?.asBool().?);
}

test "JSON builder values own their arrays and object fields" {
    var builder = json_module.Builder.init(testing.allocator);
    var array = try builder.array();
    try array.push(builder.number(1));
    try array.push(try builder.string("two"));

    var object = try builder.object();
    try object.put("items", try array.build());
    try object.put("enabled", builder.bool_(false));
    var value = object.build();
    defer value.deinit(testing.allocator);

    try testing.expectEqual(@as(f64, 1), value.get("items").?.at(0).?.asNumber().?);
    try testing.expectEqualStrings("two", value.get("items").?.at(1).?.asString().?);
    try testing.expect(!value.get("enabled").?.asBool().?);
}

test "JSON serializers escape object keys as JSON strings" {
    var builder = json_module.Builder.init(testing.allocator);
    var object = try builder.object();
    const key = "line\n\"slash\\";
    try object.put(key, builder.number(7));
    var value = object.build();
    defer value.deinit(testing.allocator);

    var json = json_module.Json.init(testing.allocator);
    const compact = try json.stringify(value);
    defer testing.allocator.free(compact);
    const pretty = try json.stringifyPretty(value);
    defer testing.allocator.free(pretty);
    for ([_][]const u8{ compact, pretty }) |encoded| {
        var parsed = try json.parse(encoded);
        defer parsed.deinit(testing.allocator);
        try testing.expectEqual(@as(f64, 7), parsed.get(key).?.asNumber().?);
    }
}

test "JSON builder replaces a key without retaining its previous value" {
    var builder = json_module.Builder.init(testing.allocator);
    var object = try builder.object();
    try object.put("key", try builder.string("old"));
    try object.put("key", try builder.string("new"));
    var value = object.build();
    defer value.deinit(testing.allocator);
    try testing.expectEqualStrings("new", value.get("key").?.asString().?);
}
