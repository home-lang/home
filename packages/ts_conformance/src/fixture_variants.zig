const std = @import("std");

const Allocator = std.mem.Allocator;

const boolean_values = [_][]const u8{ "true", "false" };
const jsx_values = [_][]const u8{ "preserve", "react", "react-native", "react-jsx", "react-jsxdev" };
const module_values = [_][]const u8{
    "none",   "commonjs", "amd",    "system", "umd",      "es6",      "es2020", "es2022",
    "esnext", "node16",   "node18", "node20", "nodenext", "preserve",
};
const module_resolution_values = [_][]const u8{ "node10", "classic", "node16", "nodenext", "bundler" };
const target_values = [_][]const u8{
    "es3",    "es5",    "es6",    "es2016", "es2017", "es2018", "es2019",
    "es2020", "es2021", "es2022", "es2023", "es2024", "es2025", "esnext",
};

const OptionSpec = struct {
    name: []const u8,
    star_values: []const []const u8,
};

/// The option names below are the boolean/custom-map members of the pinned
/// TypeScript runner's `CompilerTest.varyBy` that have multi-valued directives
/// in the pinned conformance corpus. List-valued options such as `lib` and
/// `customConditions` are intentionally absent: their commas belong to one
/// compiler setting and do not create harness variants.
const option_specs = [_]OptionSpec{
    .{ .name = "allowarbitraryextensions", .star_values = &boolean_values },
    .{ .name = "allowimportingtsextensions", .star_values = &boolean_values },
    .{ .name = "alwaysstrict", .star_values = &boolean_values },
    .{ .name = "checkjs", .star_values = &boolean_values },
    .{ .name = "esmoduleinterop", .star_values = &boolean_values },
    .{ .name = "isolatedmodules", .star_values = &boolean_values },
    .{ .name = "jsx", .star_values = &jsx_values },
    .{ .name = "module", .star_values = &module_values },
    .{ .name = "moduleresolution", .star_values = &module_resolution_values },
    .{ .name = "noemit", .star_values = &boolean_values },
    .{ .name = "noimplicitany", .star_values = &boolean_values },
    .{ .name = "noimplicitoverride", .star_values = &boolean_values },
    .{ .name = "nopropertyaccessfromindexsignature", .star_values = &boolean_values },
    .{ .name = "nouncheckedindexedaccess", .star_values = &boolean_values },
    .{ .name = "resolvejsonmodule", .star_values = &boolean_values },
    .{ .name = "resolvepackagejsonexports", .star_values = &boolean_values },
    .{ .name = "strict", .star_values = &boolean_values },
    .{ .name = "target", .star_values = &target_values },
    .{ .name = "usedefineforclassfields", .star_values = &boolean_values },
    .{ .name = "useunknownincatchvariables", .star_values = &boolean_values },
};

pub const Override = struct {
    name: []u8,
    value: []u8,
};

pub const Selection = struct {
    /// Upstream's configured-name suffix, including parentheses. Empty for a
    /// fixture without a varying setting.
    suffix: []u8,
    overrides: []Override,

    pub fn deinit(self: Selection, gpa: Allocator) void {
        gpa.free(self.suffix);
        for (self.overrides) |override| {
            gpa.free(override.name);
            gpa.free(override.value);
        }
        if (self.overrides.len != 0) gpa.free(self.overrides);
    }
};

const Axis = struct {
    name: []const u8,
    values: std.ArrayListUnmanaged([]u8) = .empty,

    fn deinit(self: *Axis, gpa: Allocator) void {
        for (self.values.items) |value| gpa.free(value);
        self.values.deinit(gpa);
    }
};

const BorrowedOverride = struct {
    name: []const u8,
    value: []const u8,
};

pub fn enumerate(gpa: Allocator, source: []const u8) ![]Selection {
    var axes: std.ArrayListUnmanaged(Axis) = .empty;
    defer {
        for (axes.items) |*axis| axis.deinit(gpa);
        axes.deinit(gpa);
    }

    var variation_count: usize = 1;
    for (option_specs) |spec| {
        const raw = lastDirectiveValue(source, spec.name) orelse continue;
        var axis = Axis{ .name = spec.name };
        errdefer axis.deinit(gpa);
        if (!try populateAxis(gpa, spec, raw, &axis)) continue;
        variation_count = std.math.mul(usize, variation_count, axis.values.items.len) catch
            return error.TooManyVariations;
        if (variation_count > 25) return error.TooManyVariations;
        try axes.append(gpa, axis);
    }

    var selections: std.ArrayListUnmanaged(Selection) = .empty;
    errdefer {
        for (selections.items) |selection| selection.deinit(gpa);
        selections.deinit(gpa);
    }
    var current: std.ArrayListUnmanaged(BorrowedOverride) = .empty;
    defer current.deinit(gpa);
    try appendSelections(gpa, axes.items, 0, &current, &selections);
    return selections.toOwnedSlice(gpa);
}

pub fn freeSelections(gpa: Allocator, selections: []Selection) void {
    for (selections) |selection| selection.deinit(gpa);
    gpa.free(selections);
}

/// Replace only the harness directive values selected by a variant. The
/// compiled source lines and their count are otherwise unchanged. This gives
/// every existing option reader the same effective scalar settings that the
/// upstream runner obtains by overlaying `configurationOverrides`.
pub fn materializeSource(gpa: Allocator, source: []const u8, selection: Selection) ![]u8 {
    if (selection.overrides.len == 0) return gpa.dupe(u8, source);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    var line_start: usize = 0;
    while (line_start < source.len) {
        const newline = std.mem.indexOfScalarPos(u8, source, line_start, '\n') orelse source.len;
        const line = source[line_start..newline];
        if (directiveParts(line)) |parts| {
            if (selectedValue(selection, parts.name)) |value| {
                try out.appendSlice(gpa, line[0..parts.value_start]);
                try out.appendSlice(gpa, value);
                try out.appendSlice(gpa, line[parts.value_end..]);
            } else {
                try out.appendSlice(gpa, line);
            }
        } else {
            try out.appendSlice(gpa, line);
        }
        if (newline < source.len) {
            try out.append(gpa, '\n');
            line_start = newline + 1;
        } else {
            line_start = source.len;
        }
    }
    return out.toOwnedSlice(gpa);
}

fn populateAxis(gpa: Allocator, spec: OptionSpec, raw: []const u8, axis: *Axis) !bool {
    var includes: std.ArrayListUnmanaged([]const u8) = .empty;
    defer includes.deinit(gpa);
    var excludes: std.ArrayListUnmanaged([]const u8) = .empty;
    defer excludes.deinit(gpa);
    var star = false;

    var parts = std.mem.splitScalar(u8, raw, ',');
    while (parts.next()) |part_raw| {
        const part = std.mem.trim(u8, part_raw, " \t\r");
        if (part.len == 0) continue;
        if (std.mem.eql(u8, part, "*")) {
            star = true;
        } else if (part[0] == '-' or part[0] == '!') {
            if (part.len > 1) try excludes.append(gpa, part[1..]);
        } else {
            try includes.append(gpa, part);
        }
    }
    if (includes.items.len <= 1 and !star and excludes.items.len == 0) return false;

    for (includes.items) |include| try appendUniqueValue(gpa, axis, include);
    if (star) {
        for (spec.star_values) |value| try appendUniqueValue(gpa, axis, value);
    }
    for (excludes.items) |exclude| {
        var index: usize = 0;
        while (index < axis.values.items.len) {
            if (equivalentOptionValue(spec.name, axis.values.items[index], exclude)) {
                gpa.free(axis.values.orderedRemove(index));
            } else {
                index += 1;
            }
        }
    }
    if (axis.values.items.len == 0) return error.EmptyVariationSet;
    return true;
}

fn appendUniqueValue(gpa: Allocator, axis: *Axis, raw: []const u8) !void {
    for (axis.values.items) |existing| {
        if (equivalentOptionValue(axis.name, existing, raw)) return;
    }
    const normalized = try lowerDupe(gpa, raw);
    errdefer gpa.free(normalized);
    try axis.values.append(gpa, normalized);
}

fn equivalentOptionValue(option: []const u8, a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(canonicalOptionValue(option, a), canonicalOptionValue(option, b));
}

fn canonicalOptionValue(option: []const u8, value: []const u8) []const u8 {
    if ((std.mem.eql(u8, option, "target") or std.mem.eql(u8, option, "module")) and
        (std.ascii.eqlIgnoreCase(value, "es6") or std.ascii.eqlIgnoreCase(value, "es2015"))) return "es2015";
    if (std.mem.eql(u8, option, "moduleresolution") and
        (std.ascii.eqlIgnoreCase(value, "node") or std.ascii.eqlIgnoreCase(value, "node10"))) return "node10";
    return value;
}

fn appendSelections(
    gpa: Allocator,
    axes: []const Axis,
    index: usize,
    current: *std.ArrayListUnmanaged(BorrowedOverride),
    out: *std.ArrayListUnmanaged(Selection),
) !void {
    if (index == axes.len) {
        var overrides = try gpa.alloc(Override, current.items.len);
        var initialized: usize = 0;
        errdefer {
            for (overrides[0..initialized]) |override| {
                gpa.free(override.name);
                gpa.free(override.value);
            }
            if (overrides.len != 0) gpa.free(overrides);
        }
        for (current.items, 0..) |item, override_index| {
            overrides[override_index] = .{
                .name = try gpa.dupe(u8, item.name),
                .value = try gpa.dupe(u8, item.value),
            };
            initialized += 1;
        }
        const suffix = try configuredNameSuffix(gpa, current.items);
        errdefer gpa.free(suffix);
        try out.append(gpa, .{ .suffix = suffix, .overrides = overrides });
        return;
    }

    const axis = axes[index];
    for (axis.values.items) |value| {
        try current.append(gpa, .{ .name = axis.name, .value = value });
        defer _ = current.pop();
        try appendSelections(gpa, axes, index + 1, current, out);
    }
}

fn configuredNameSuffix(
    gpa: Allocator,
    overrides: []const BorrowedOverride,
) ![]u8 {
    if (overrides.len == 0) return gpa.dupe(u8, "");
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.append(gpa, '(');
    for (overrides, 0..) |override, index| {
        if (index != 0) try out.append(gpa, ',');
        try out.appendSlice(gpa, override.name);
        try out.append(gpa, '=');
        try out.appendSlice(gpa, override.value);
    }
    try out.append(gpa, ')');
    return out.toOwnedSlice(gpa);
}

fn lowerDupe(gpa: Allocator, raw: []const u8) ![]u8 {
    const out = try gpa.alloc(u8, raw.len);
    for (raw, 0..) |char, index| out[index] = std.ascii.toLower(char);
    return out;
}

fn lastDirectiveValue(source: []const u8, option: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const parts = directiveParts(line) orelse continue;
        if (std.ascii.eqlIgnoreCase(parts.name, option)) found = line[parts.value_start..parts.value_end];
    }
    return found;
}

const DirectiveParts = struct {
    name: []const u8,
    value_start: usize,
    value_end: usize,
};

fn directiveParts(line: []const u8) ?DirectiveParts {
    var index: usize = 0;
    if (line.len >= 3 and line[0] == 0xEF and line[1] == 0xBB and line[2] == 0xBF) index = 3;
    if (index + 2 > line.len or !std.mem.eql(u8, line[index .. index + 2], "//")) return null;
    index += 2;
    while (index < line.len and (line[index] == ' ' or line[index] == '\t')) : (index += 1) {}
    if (index >= line.len or line[index] != '@') return null;
    index += 1;
    const name_start = index;
    while (index < line.len and (std.ascii.isAlphanumeric(line[index]) or line[index] == '_')) : (index += 1) {}
    if (index == name_start) return null;
    const name = line[name_start..index];
    while (index < line.len and (line[index] == ' ' or line[index] == '\t')) : (index += 1) {}
    if (index >= line.len or line[index] != ':') return null;
    index += 1;
    while (index < line.len and (line[index] == ' ' or line[index] == '\t')) : (index += 1) {}
    const value_end = if (line.len > index and line[line.len - 1] == '\r') line.len - 1 else line.len;
    return .{ .name = name, .value_start = index, .value_end = value_end };
}

fn selectedValue(selection: Selection, name: []const u8) ?[]const u8 {
    for (selection.overrides) |override| {
        if (std.ascii.eqlIgnoreCase(override.name, name)) return override.value;
    }
    return null;
}

test "fixture variants form the upstream Cartesian product and configured names" {
    const T = std.testing;
    const source =
        \\// @target: ES5, ES2015
        \\// @strict: true, false
        \\const value = 1;
    ;
    const selections = try enumerate(T.allocator, source);
    defer freeSelections(T.allocator, selections);

    try T.expectEqual(@as(usize, 4), selections.len);
    try T.expectEqualStrings("(strict=true,target=es5)", selections[0].suffix);
    try T.expectEqualStrings("(strict=true,target=es2015)", selections[1].suffix);
    try T.expectEqualStrings("(strict=false,target=es5)", selections[2].suffix);
    try T.expectEqualStrings("(strict=false,target=es2015)", selections[3].suffix);
}

test "fixture variants expand stars, deduplicate aliases, and apply exclusions" {
    const T = std.testing;
    const selections = try enumerate(T.allocator, "// @target: *,-es3,es2015\nconst value = 1;");
    defer freeSelections(T.allocator, selections);

    try T.expectEqual(@as(usize, 13), selections.len);
    try T.expectEqualStrings("(target=es2015)", selections[0].suffix);
    try T.expectEqualStrings("(target=es5)", selections[1].suffix);
    try T.expectEqualStrings("(target=esnext)", selections[12].suffix);
}

test "fixture variants do not split list-valued compiler settings" {
    const T = std.testing;
    const selections = try enumerate(
        T.allocator,
        "// @lib: es2020,dom\n// @customConditions: webpack,browser\nconst value = 1;",
    );
    defer freeSelections(T.allocator, selections);

    try T.expectEqual(@as(usize, 1), selections.len);
    try T.expectEqualStrings("", selections[0].suffix);
}

test "fixture variants materialize selected scalar directives without moving source lines" {
    const T = std.testing;
    const source = "\xEF\xBB\xBF// @target: ES5, ES2015\r\n// @strict: true, false\nconst value = 1;\n";
    const selections = try enumerate(T.allocator, source);
    defer freeSelections(T.allocator, selections);
    const materialized = try materializeSource(T.allocator, source, selections[3]);
    defer T.allocator.free(materialized);

    try T.expectEqualStrings(
        "\xEF\xBB\xBF// @target: es2015\r\n// @strict: false\nconst value = 1;\n",
        materialized,
    );
    try T.expectEqual(std.mem.count(u8, source, "\n"), std.mem.count(u8, materialized, "\n"));
}

test "fixture variants enforce the upstream 25-configuration limit" {
    const T = std.testing;
    try T.expectError(
        error.TooManyVariations,
        enumerate(
            T.allocator,
            "// @target: es5,es2015,es2016,es2017,es2018,es2019\n" ++
                "// @module: commonjs,es2022,esnext,node16,node18\n",
        ),
    );
}
