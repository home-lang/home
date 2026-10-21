//! Merge checked interface surfaces without losing declaration-group order.
//! Declaration nodes are opaque identities, including relocated owner handles.
const std = @import("std");
const hir = @import("hir");
const types = @import("types.zig");
const Interner = @import("interner.zig").Interner;
pub const OwnSurfaces = std.AutoHashMapUnmanaged(types.TypeId, types.TypeId);

pub fn sameDeclaration(a: types.ObjectMember, b: types.ObjectMember) bool {
    if (a.name != b.name) return false;
    if (a.decl_node != hir.none_node_id or b.decl_node != hir.none_node_id)
        return a.decl_node == b.decl_node;
    // Schema-created signatures have no HIR handle. An exact member/type
    // identity still identifies a repeated copy, without collapsing distinct
    // declaration signatures (which have distinct TypeIds).
    return std.meta.eql(a, b);
}

fn containsDeclaration(members: []const types.ObjectMember, candidate: types.ObjectMember) bool {
    for (members) |member| {
        if (sameDeclaration(member, candidate)) return true;
    }
    return false;
}

fn containsName(members: []const types.ObjectMember, name: hir.StringId) bool {
    for (members) |member| {
        if (member.name == name) return true;
    }
    return false;
}

pub fn merge(
    gpa: std.mem.Allocator,
    interner: *Interner,
    surfaces: *OwnSurfaces,
    first: types.TypeId,
    second: types.TypeId,
    call_name: hir.StringId,
    construct_name: hir.StringId,
) error{OutOfMemory}!types.TypeId {
    if (first == second) return first;
    const first_own = surfaces.get(first) orelse first;
    const second_own = surfaces.get(second) orelse second;
    const earlier = interner.objectMembers(first_own);
    const later = interner.objectMembers(second_own);
    var own: std.ArrayListUnmanaged(types.ObjectMember) = .empty;
    defer own.deinit(gpa);
    // Later declaration groups precede earlier groups. A surface imported
    // through another owner may already include the earlier declarations;
    // refreshing those declarations must not promote or duplicate them.
    for (later) |member| {
        if (containsDeclaration(earlier, member)) continue;
        const signature = member.is_method or member.name == call_name or member.name == construct_name;
        if (!signature and containsName(earlier, member.name)) continue;
        try own.append(gpa, member);
    }
    for (earlier) |member| {
        const refreshed = for (later) |candidate| {
            if (sameDeclaration(member, candidate)) break candidate;
        } else member;
        try own.append(gpa, refreshed);
    }
    var full: std.ArrayListUnmanaged(types.ObjectMember) = .empty;
    defer full.deinit(gpa);
    try full.appendSlice(gpa, own.items);
    // Own methods replace inherited overloads; call/construct signatures
    // instead retain the base signatures after the own group.
    for ([_][2]types.TypeId{ .{ first, first_own }, .{ second, second_own } }) |pair| {
        if (pair[0] == pair[1]) continue;
        const own_members = interner.objectMembers(pair[1]);
        for (interner.objectMembers(pair[0])) |member| {
            if (containsDeclaration(own_members, member)) continue;
            if (member.name != call_name and member.name != construct_name and containsName(own.items, member.name)) continue;
            if (containsDeclaration(full.items, member)) continue;
            try full.append(gpa, member);
        }
    }
    const string_index = if (interner.objectStringIndex(first) != types.Primitive.none) interner.objectStringIndex(first) else interner.objectStringIndex(second);
    const number_index = if (interner.objectNumberIndex(first) != types.Primitive.none) interner.objectNumberIndex(first) else interner.objectNumberIndex(second);
    const symbol_index = if (interner.objectSymbolIndex(first) != types.Primitive.none) interner.objectSymbolIndex(first) else interner.objectSymbolIndex(second);
    const own_type = try interner.internObjectType(own.items);
    const result = try interner.internObjectTypeWithIndexAndSymbol(full.items, string_index, number_index, symbol_index);
    try surfaces.put(gpa, own_type, own_type);
    try surfaces.put(gpa, result, own_type);
    return result;
}

test "interface merge: repeated owner surfaces retain each overload once" {
    const T = std.testing;
    var interner = try Interner.init(T.allocator);
    defer interner.deinit();
    var surfaces: OwnSurfaces = .empty;
    defer surfaces.deinit(T.allocator);
    const a: types.ObjectMember = .{ .name = 1, .type = types.Primitive.string_t, .is_optional = false, .is_readonly = false, .is_method = true, .decl_node = 0x80000001 };
    var b = a;
    b.decl_node = 0x80000002;
    var c = a;
    c.decl_node = 0x80000003;
    var data = a;
    data.name = 2;
    data.is_method = false;
    data.decl_node = 0x80000004;
    var conflicting = data;
    conflicting.decl_node = 0x80000005;
    conflicting.type = types.Primitive.number_t;
    const first = try interner.internObjectType(&.{ a, data });
    const second = try interner.internObjectType(&.{ b, a, conflicting });
    const third = try interner.internObjectType(&.{ c, b, a });
    const ab = try merge(T.allocator, &interner, &surfaces, first, second, 3, 4);
    const abc = try merge(T.allocator, &interner, &surfaces, ab, third, 3, 4);
    const repeated = try merge(T.allocator, &interner, &surfaces, abc, second, 3, 4);
    for ([_]types.TypeId{ abc, repeated }) |object| {
        const members = interner.objectMembers(object);
        try T.expectEqual(@as(usize, 4), members.len);
        try T.expectEqual(c.decl_node, members[0].decl_node);
        try T.expectEqual(b.decl_node, members[1].decl_node);
        try T.expectEqual(a.decl_node, members[2].decl_node);
        try T.expectEqual(data.type, members[3].type);
    }
}
