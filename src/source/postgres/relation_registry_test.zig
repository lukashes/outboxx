const std = @import("std");
const testing = std.testing;

const relation_registry_mod = @import("relation_registry.zig");
const RelationRegistry = relation_registry_mod.RelationRegistry;
const pg_output_decoder = @import("pg_output_decoder.zig");
const RelationMessage = pg_output_decoder.RelationMessage;
const RelationMessageColumn = pg_output_decoder.RelationMessageColumn;

fn createTestRelation(allocator: std.mem.Allocator, relation_id: u32, namespace: []const u8, relation_name: []const u8) !RelationMessage {
    const namespace_owned = try allocator.dupe(u8, namespace);
    errdefer allocator.free(namespace_owned);
    const relation_name_owned = try allocator.dupe(u8, relation_name);
    errdefer allocator.free(relation_name_owned);

    const col1_name = try allocator.dupe(u8, "id");
    errdefer allocator.free(col1_name);
    const col2_name = try allocator.dupe(u8, "name");
    errdefer allocator.free(col2_name);

    const columns = try allocator.alloc(RelationMessageColumn, 2);
    columns[0] = RelationMessageColumn{
        .flags = 1,
        .name = col1_name,
        .data_type = 23,
        .type_modifier = -1,
    };
    columns[1] = RelationMessageColumn{
        .flags = 0,
        .name = col2_name,
        .data_type = 25,
        .type_modifier = -1,
    };

    return RelationMessage{
        .relation_id = relation_id,
        .namespace = namespace_owned,
        .relation_name = relation_name_owned,
        .replica_identity = 'd',
        .columns = columns,
    };
}

test "RelationRegistry: init and deinit" {
    const allocator = testing.allocator;
    var registry = RelationRegistry.init(allocator);
    defer registry.deinit();

    try testing.expectEqual(@as(usize, 0), registry.count());
}

test "RelationRegistry: register and get relation" {
    const allocator = testing.allocator;
    var registry = RelationRegistry.init(allocator);
    defer registry.deinit();

    var relation = try createTestRelation(allocator, 12345, "public", "users");
    defer relation.deinit(allocator);

    try registry.register(relation);

    try testing.expectEqual(@as(usize, 1), registry.count());
    try testing.expect(registry.contains(12345));

    const info = try registry.get(12345);
    try testing.expectEqualStrings("public", info.namespace);
    try testing.expectEqualStrings("users", info.relation_name);
    try testing.expectEqual(@as(u8, 'd'), info.replica_identity);
    try testing.expectEqual(@as(usize, 2), info.columns.len);

    try testing.expectEqualStrings("id", info.columns[0].name);
    try testing.expectEqual(@as(u32, 23), info.columns[0].data_type);

    try testing.expectEqualStrings("name", info.columns[1].name);
    try testing.expectEqual(@as(u32, 25), info.columns[1].data_type);
}

test "RelationRegistry: register multiple relations" {
    const allocator = testing.allocator;
    var registry = RelationRegistry.init(allocator);
    defer registry.deinit();

    var relation1 = try createTestRelation(allocator, 100, "public", "users");
    defer relation1.deinit(allocator);

    var relation2 = try createTestRelation(allocator, 200, "public", "orders");
    defer relation2.deinit(allocator);

    try registry.register(relation1);
    try registry.register(relation2);

    try testing.expectEqual(@as(usize, 2), registry.count());
    try testing.expect(registry.contains(100));
    try testing.expect(registry.contains(200));

    const info1 = try registry.get(100);
    try testing.expectEqualStrings("users", info1.relation_name);

    const info2 = try registry.get(200);
    try testing.expectEqualStrings("orders", info2.relation_name);
}

test "RelationRegistry: re-register same relation_id" {
    const allocator = testing.allocator;
    var registry = RelationRegistry.init(allocator);
    defer registry.deinit();

    var relation1 = try createTestRelation(allocator, 12345, "public", "users");
    defer relation1.deinit(allocator);

    var relation2 = try createTestRelation(allocator, 12345, "public", "users_v2");
    defer relation2.deinit(allocator);

    try registry.register(relation1);
    try testing.expectEqual(@as(usize, 1), registry.count());

    const info_before = try registry.get(12345);
    try testing.expectEqualStrings("users", info_before.relation_name);

    // Re-register with same relation_id but different name
    try registry.register(relation2);
    try testing.expectEqual(@as(usize, 1), registry.count());

    const info_after = try registry.get(12345);
    try testing.expectEqualStrings("users_v2", info_after.relation_name);
}

test "RelationRegistry: get non-existent relation" {
    const allocator = testing.allocator;
    var registry = RelationRegistry.init(allocator);
    defer registry.deinit();

    const result = registry.get(99999);
    try testing.expectError(relation_registry_mod.RelationRegistryError.RelationNotFound, result);
}

test "RelationRegistry: contains checks" {
    const allocator = testing.allocator;
    var registry = RelationRegistry.init(allocator);
    defer registry.deinit();

    try testing.expect(!registry.contains(12345));

    var relation = try createTestRelation(allocator, 12345, "public", "users");
    defer relation.deinit(allocator);

    try registry.register(relation);

    try testing.expect(registry.contains(12345));
    try testing.expect(!registry.contains(99999));
}
