const std = @import("std");
const testing = std.testing;
const traits = @import("traits");
const TraitSystem = traits.TraitSystem;
const BuiltinTraits = traits.BuiltinTraits;

test "trait system initialization" {
    var trait_system = TraitSystem.init(testing.allocator);
    defer trait_system.deinit();

    try testing.expect(trait_system.traits.count() == 0);
    try testing.expect(trait_system.impls.items.len == 0);
}

test "define simple trait" {
    var trait_system = TraitSystem.init(testing.allocator);
    defer trait_system.deinit();

    const methods = [_]TraitSystem.TraitDef.MethodSignature{
        .{
            .name = "draw",
            .params = &[_]TraitSystem.TraitDef.MethodSignature.Param{
                .{ .name = "self", .type_name = "&Self" },
            },
            .return_type = "void",
            .is_async = false,
            .is_required = true,
        },
    };

    try trait_system.defineTrait(
        "Drawable",
        &methods,
        &[_]TraitSystem.TraitDef.AssociatedType{},
        &[_][]const u8{},
        &[_][]const u8{},
    );

    try testing.expect(trait_system.traits.count() == 1);
    const drawable = trait_system.traits.get("Drawable");
    try testing.expect(drawable != null);
    try testing.expect(std.mem.eql(u8, drawable.?.name, "Drawable"));
}

test "implement trait for type" {
    var trait_system = TraitSystem.init(testing.allocator);
    defer trait_system.deinit();

    // Define trait
    const methods = [_]TraitSystem.TraitDef.MethodSignature{
        .{
            .name = "clone",
            .params = &[_]TraitSystem.TraitDef.MethodSignature.Param{
                .{ .name = "self", .type_name = "&Self" },
            },
            .return_type = "Self",
            .is_async = false,
            .is_required = true,
        },
    };

    try trait_system.defineTrait(
        "Clone",
        &methods,
        &[_]TraitSystem.TraitDef.AssociatedType{},
        &[_][]const u8{},
        &[_][]const u8{},
    );

    // Implement trait
    const impl_methods = [_]TraitSystem.TraitImpl.MethodImpl{};

    try trait_system.implementTrait(
        "Clone",
        "MyStruct",
        &impl_methods,
    );

    try testing.expect(trait_system.implementsTrait("MyStruct", "Clone"));
    try testing.expect(!trait_system.implementsTrait("OtherStruct", "Clone"));
}

test "check trait bounds" {
    var trait_system = TraitSystem.init(testing.allocator);
    defer trait_system.deinit();

    // Define traits
    const clone_methods = [_]TraitSystem.TraitDef.MethodSignature{
        .{
            .name = "clone",
            .params = &[_]TraitSystem.TraitDef.MethodSignature.Param{
                .{ .name = "self", .type_name = "&Self" },
            },
            .return_type = "Self",
            .is_async = false,
            .is_required = true,
        },
    };

    const debug_methods = [_]TraitSystem.TraitDef.MethodSignature{
        .{
            .name = "fmt",
            .params = &[_]TraitSystem.TraitDef.MethodSignature.Param{
                .{ .name = "self", .type_name = "&Self" },
                .{ .name = "f", .type_name = "&mut Formatter" },
            },
            .return_type = "Result<(), Error>",
            .is_async = false,
            .is_required = true,
        },
    };

    try trait_system.defineTrait("Clone", &clone_methods, &[_]TraitSystem.TraitDef.AssociatedType{}, &[_][]const u8{}, &[_][]const u8{});
    try trait_system.defineTrait("Debug", &debug_methods, &[_]TraitSystem.TraitDef.AssociatedType{}, &[_][]const u8{}, &[_][]const u8{});

    // Implement both traits for MyStruct
    try trait_system.implementTrait("Clone", "MyStruct", &[_]TraitSystem.TraitImpl.MethodImpl{});
    try trait_system.implementTrait("Debug", "MyStruct", &[_]TraitSystem.TraitImpl.MethodImpl{});

    // Check bounds
    const bounds = [_][]const u8{ "Clone", "Debug" };
    try testing.expect(trait_system.checkBounds("MyStruct", &bounds));

    const partial_bounds = [_][]const u8{"Clone"};
    try testing.expect(trait_system.checkBounds("MyStruct", &partial_bounds));

    const missing_bounds = [_][]const u8{ "Clone", "Display" };
    try testing.expect(!trait_system.checkBounds("MyStruct", &missing_bounds));
}

test "trait with associated types" {
    var trait_system = TraitSystem.init(testing.allocator);
    defer trait_system.deinit();

    const methods = [_]TraitSystem.TraitDef.MethodSignature{
        .{
            .name = "next",
            .params = &[_]TraitSystem.TraitDef.MethodSignature.Param{
                .{ .name = "self", .type_name = "&mut Self" },
            },
            .return_type = "Option<Self::Item>",
            .is_async = false,
            .is_required = true,
        },
    };

    const assoc_types = [_]TraitSystem.TraitDef.AssociatedType{
        .{
            .name = "Item",
            .bounds = &[_][]const u8{},
        },
    };

    try trait_system.defineTrait(
        "Iterator",
        &methods,
        &assoc_types,
        &[_][]const u8{},
        &[_][]const u8{},
    );

    const iterator_trait = trait_system.traits.get("Iterator").?;
    try testing.expect(iterator_trait.associated_types.len == 1);
    try testing.expect(std.mem.eql(u8, iterator_trait.associated_types[0].name, "Item"));
}

test "trait inheritance" {
    var trait_system = TraitSystem.init(testing.allocator);
    defer trait_system.deinit();

    // Define base trait
    const eq_methods = [_]TraitSystem.TraitDef.MethodSignature{
        .{
            .name = "eq",
            .params = &[_]TraitSystem.TraitDef.MethodSignature.Param{
                .{ .name = "self", .type_name = "&Self" },
                .{ .name = "other", .type_name = "&Self" },
            },
            .return_type = "bool",
            .is_async = false,
            .is_required = true,
        },
    };

    try trait_system.defineTrait(
        "PartialEq",
        &eq_methods,
        &[_]TraitSystem.TraitDef.AssociatedType{},
        &[_][]const u8{},
        &[_][]const u8{},
    );

    // Define derived trait with super trait
    const super_traits = [_][]const u8{"PartialEq"};

    try trait_system.defineTrait(
        "Eq",
        &[_]TraitSystem.TraitDef.MethodSignature{},
        &[_]TraitSystem.TraitDef.AssociatedType{},
        &super_traits,
        &[_][]const u8{},
    );

    const eq_trait = trait_system.traits.get("Eq").?;
    try testing.expect(eq_trait.super_traits.len == 1);
    try testing.expect(std.mem.eql(u8, eq_trait.super_traits[0], "PartialEq"));
}

test "vtable generation" {
    var trait_system = TraitSystem.init(testing.allocator);
    defer trait_system.deinit();

    // Define trait
    const methods = [_]TraitSystem.TraitDef.MethodSignature{
        .{
            .name = "draw",
            .params = &[_]TraitSystem.TraitDef.MethodSignature.Param{
                .{ .name = "self", .type_name = "&Self" },
            },
            .return_type = "void",
            .is_async = false,
            .is_required = true,
        },
    };

    try trait_system.defineTrait(
        "Drawable",
        &methods,
        &[_]TraitSystem.TraitDef.AssociatedType{},
        &[_][]const u8{},
        &[_][]const u8{},
    );

    // Implement trait
    try trait_system.implementTrait(
        "Drawable",
        "Circle",
        &[_]TraitSystem.TraitImpl.MethodImpl{},
    );

    // Check vtable was generated
    const vtable_key = "Circle::Drawable";
    const vtable = trait_system.vtables.get(vtable_key);
    try testing.expect(vtable != null);
}

test "builtin Clone trait" {
    try testing.expect(std.mem.eql(u8, BuiltinTraits.Clone.name, "Clone"));
    try testing.expect(BuiltinTraits.Clone.methods.len == 1);
    try testing.expect(std.mem.eql(u8, BuiltinTraits.Clone.methods[0].name, "clone"));
}

test "builtin Iterator trait" {
    try testing.expect(std.mem.eql(u8, BuiltinTraits.Iterator.name, "Iterator"));
    try testing.expect(BuiltinTraits.Iterator.associated_types.len == 1);
    try testing.expect(std.mem.eql(u8, BuiltinTraits.Iterator.associated_types[0].name, "Item"));
}
