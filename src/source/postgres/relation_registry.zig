const std = @import("std");
const pg_output_decoder = @import("pg_output_decoder.zig");
const RelationMessage = pg_output_decoder.RelationMessage;
const RelationMessageColumn = pg_output_decoder.RelationMessageColumn;

pub const RelationRegistryError = error{
    RelationNotFound,
    OutOfMemory,
};

pub const RelationInfo = struct {
    namespace: []const u8,
    relation_name: []const u8,
    replica_identity: u8,
    columns: []RelationMessageColumn,

    pub fn deinit(self: *RelationInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.namespace);
        allocator.free(self.relation_name);
        for (self.columns) |*col| {
            col.deinit(allocator);
        }
        allocator.free(self.columns);
    }
};

/// Maps relation_id to table metadata, rebuilt in memory from RELATION messages.
pub const RelationRegistry = struct {
    allocator: std.mem.Allocator,
    relations: std.AutoHashMap(u32, RelationInfo),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .relations = std.AutoHashMap(u32, RelationInfo).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        var it = self.relations.valueIterator();
        while (it.next()) |relation_info| {
            var mut_info = relation_info.*;
            mut_info.deinit(self.allocator);
        }
        self.relations.deinit();
    }

    pub fn register(self: *Self, relation_msg: RelationMessage) RelationRegistryError!void {
        // Check if relation already exists - if so, clean it up first
        if (self.relations.getPtr(relation_msg.relation_id)) |existing| {
            existing.deinit(self.allocator);
            _ = self.relations.remove(relation_msg.relation_id);
        }

        // Duplicate all strings and columns for owned storage
        const namespace = self.allocator.dupe(u8, relation_msg.namespace) catch return RelationRegistryError.OutOfMemory;
        errdefer self.allocator.free(namespace);

        const relation_name = self.allocator.dupe(u8, relation_msg.relation_name) catch return RelationRegistryError.OutOfMemory;
        errdefer self.allocator.free(relation_name);

        const columns = self.allocator.alloc(RelationMessageColumn, relation_msg.columns.len) catch return RelationRegistryError.OutOfMemory;
        errdefer self.allocator.free(columns);

        for (relation_msg.columns, 0..) |col, i| {
            const col_name = self.allocator.dupe(u8, col.name) catch {
                // Clean up previously allocated columns
                for (columns[0..i]) |*prev_col| {
                    prev_col.deinit(self.allocator);
                }
                return RelationRegistryError.OutOfMemory;
            };

            columns[i] = RelationMessageColumn{
                .flags = col.flags,
                .name = col_name,
                .data_type = col.data_type,
                .type_modifier = col.type_modifier,
            };
        }

        const relation_info = RelationInfo{
            .namespace = namespace,
            .relation_name = relation_name,
            .replica_identity = relation_msg.replica_identity,
            .columns = columns,
        };

        self.relations.put(relation_msg.relation_id, relation_info) catch return RelationRegistryError.OutOfMemory;
    }

    pub fn get(self: *Self, relation_id: u32) RelationRegistryError!*const RelationInfo {
        return self.relations.getPtr(relation_id) orelse RelationRegistryError.RelationNotFound;
    }

    pub fn contains(self: *Self, relation_id: u32) bool {
        return self.relations.contains(relation_id);
    }

    pub fn count(self: *Self) usize {
        return self.relations.count();
    }
};

const testing = std.testing;

const relation_registry_mod = @This();

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
