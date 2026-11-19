//! The `FlatArray` alias from TypeScript 5.7.3's lib.es2019.array.d.ts.
//! Keep the recursive declaration as a type graph: a variable `depth` must
//! retain the deferred alias rather than collapse to the default depth.
const schema = @import("program_schema.zig");
const types = @import("types.zig");

const number_type: schema.Expression = .{ .primitive = types.Primitive.number_t };
const minus_one: schema.Expression = .{ .number = -1 };
const depth_values = [_]schema.Expression{
    .{ .number = -1 }, .{ .number = 0 },  .{ .number = 1 },  .{ .number = 2 },
    .{ .number = 3 },  .{ .number = 4 },  .{ .number = 5 },  .{ .number = 6 },
    .{ .number = 7 },  .{ .number = 8 },  .{ .number = 9 },  .{ .number = 10 },
    .{ .number = 11 }, .{ .number = 12 }, .{ .number = 13 }, .{ .number = 14 },
    .{ .number = 15 }, .{ .number = 16 }, .{ .number = 17 }, .{ .number = 18 },
    .{ .number = 19 }, .{ .number = 20 },
};
const depth_elements = blk: {
    var elements: [depth_values.len]schema.Element = undefined;
    for (&elements, 0..) |*element, index| element.* = .{ .type = &depth_values[index] };
    break :blk elements;
};
pub const decrement_tuple: schema.Expression = .{ .tuple = &depth_elements };
const parameters = [_]schema.Parameter{
    .{ .name = "Arr" },
    .{ .name = "Depth", .constraint = &number_type },
};
const inner_parameter: schema.Parameter = .{ .name = "InnerArr" };
const arr: schema.Expression = .{ .parameter = &parameters[0] };
const depth: schema.Expression = .{ .parameter = &parameters[1] };
const inner: schema.Expression = .{ .parameter = &inner_parameter };
const inferred_inner: schema.Expression = .{ .infer = &inner_parameter };
const readonly_inner_array: schema.Expression = .{ .readonly_array = &inferred_inner };
const decremented_depth: schema.Expression = .{ .indexed_access = .{
    .object = &decrement_tuple,
    .index = &depth,
} };
const recur: schema.Expression = .{ .reference = .{
    .declaration = &declaration,
    .arguments = &.{ &inner, &decremented_depth },
} };
pub const unwrap: schema.Expression = .{ .conditional = .{
    .check = &arr,
    .extends_type = &readonly_inner_array,
    .true_branch = &recur,
    .false_branch = &arr,
} };
const variants: schema.Expression = .{ .object = &.{
    .{ .name = "done", .type = &arr },
    .{ .name = "recur", .type = &unwrap },
} };
const done_key: schema.Expression = .{ .string = "done" };
const recur_key: schema.Expression = .{ .string = "recur" };
const branch: schema.Expression = .{ .conditional = .{
    .check = &depth,
    .extends_type = &minus_one,
    .true_branch = &done_key,
    .false_branch = &recur_key,
} };
const body: schema.Expression = .{ .indexed_access = .{
    .object = &variants,
    .index = &branch,
} };

pub const declaration: schema.Declaration = .{
    .path = "lib.es2019.array.d.ts",
    .position = 19,
    .name = "FlatArray",
    .parameters = @constCast(parameters[0..]),
    .body = &body,
    .is_type_alias = true,
};
