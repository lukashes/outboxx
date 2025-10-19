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
