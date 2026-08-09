fn decode(bytes: []const u8) struct { codepoint: u21, width: usize } {
    if (bytes.len == 0) return .{ .codepoint = 0, .width = 0 };
    const lead = bytes[0];
    const width: usize = if (lead < 0x80) 1 else if (lead & 0xe0 == 0xc0) 2 else if (lead & 0xf0 == 0xe0) 3 else if (lead & 0xf8 == 0xf0) 4 else 1;
    if (width > bytes.len) return .{ .codepoint = lead, .width = 1 };
    var value: u21 = switch (width) {
        1 => lead,
        2 => lead & 0x1f,
        3 => lead & 0x0f,
        4 => lead & 0x07,
        else => unreachable,
    };
    for (bytes[1..width]) |byte| {
        if (byte & 0xc0 != 0x80) return .{ .codepoint = lead, .width = 1 };
        value = (value << 6) | @as(u21, byte & 0x3f);
    }
    return .{ .codepoint = value, .width = width };
}

fn mappingFor(codepoint: u21) ?Mapping {
    var lo: usize = 0;
    var hi: usize = mappings.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (mappings[mid].codepoint < codepoint) lo = mid + 1 else hi = mid;
    }
    return if (lo < mappings.len and mappings[lo].codepoint == codepoint) mappings[lo] else null;
}

fn inRanges(codepoint: u21, ranges: []const Range) bool {
    for (ranges) |range| {
        if (codepoint < range.lo) return false;
        if (codepoint <= range.hi and (codepoint - range.lo) % range.stride == 0) return true;
    }
    return false;
}

fn hasCasedAfter(input: []const u8, start: usize) bool {
    var offset = start;
    while (offset < input.len) {
        const decoded = decode(input[offset..]);
        offset += decoded.width;
        if (inRanges(decoded.codepoint, &case_ignorable_ranges)) continue;
        return inRanges(decoded.codepoint, &cased_ranges);
    }
    return false;
}

fn appendMapped(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, input: []const u8, uppercase: bool) !void {
    var offset: usize = 0;
    var cased_before = false;
    while (offset < input.len) {
        const start = offset;
        const decoded = decode(input[offset..]);
        offset += decoded.width;
        if (mappingFor(decoded.codepoint)) |mapping| {
            const replacement = if (uppercase)
                mapping.upper
            else if (mapping.final_sigma and cased_before and !hasCasedAfter(input, offset))
                mapping.conditional_lower
            else
                mapping.lower;
            try out.appendSlice(allocator, replacement);
        } else {
            try out.appendSlice(allocator, input[start..offset]);
        }
        if (!inRanges(decoded.codepoint, &case_ignorable_ranges)) {
            cased_before = inRanges(decoded.codepoint, &cased_ranges);
        }
    }
}

pub fn map(allocator: std.mem.Allocator, kind: Kind, input: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    switch (kind) {
        .lowercase => try appendMapped(&out, allocator, input, false),
        .uppercase => try appendMapped(&out, allocator, input, true),
        .capitalize, .uncapitalize => {
            if (input.len == 0) return out.toOwnedSlice(allocator);
            const first = decode(input);
            try appendMapped(&out, allocator, input[0..first.width], kind == .capitalize);
            try out.appendSlice(allocator, input[first.width..]);
        },
    }
    return out.toOwnedSlice(allocator);
}

test "ECMAScript Unicode default casing and final sigma" {
    const allocator = std.testing.allocator;
    const lower = try map(allocator, .lowercase, "\xc4\xb0SPANYOL \xce\x9f\xce\xa3");
    defer allocator.free(lower);
    try std.testing.expectEqualStrings("i\xcc\x87spanyol \xce\xbf\xcf\x82", lower);

    const upper = try map(allocator, .uppercase, "\xc3\x9ffoo \xef\xac\x81oo");
    defer allocator.free(upper);
    try std.testing.expectEqualStrings("SSFOO FIOO", upper);

    const capitalized = try map(allocator, .capitalize, "\xc3\x9ffoo");
    defer allocator.free(capitalized);
    try std.testing.expectEqualStrings("SSfoo", capitalized);
}
