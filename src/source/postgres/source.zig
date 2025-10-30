const std = @import("std");
const domain = @import("domain");
const ChangeEvent = domain.ChangeEvent;
const ChangeOperation = domain.ChangeOperation;
const Metadata = domain.Metadata;
const RowData = domain.RowData;
const RowDataHelpers = domain.RowDataHelpers;
const FieldValueHelpers = domain.FieldValueHelpers;
const constants = @import("constants");

const replication_protocol = @import("replication_protocol.zig");
const ReplicationProtocol = replication_protocol.ReplicationProtocol;
const ReplicationError = replication_protocol.ReplicationError;
const StandbyStatusUpdate = replication_protocol.StandbyStatusUpdate;

const pg_output_decoder = @import("pg_output_decoder.zig");
const PgOutputDecoder = pg_output_decoder.PgOutputDecoder;
const PgOutputMessage = pg_output_decoder.PgOutputMessage;
const DecoderError = pg_output_decoder.DecoderError;

const relation_registry = @import("relation_registry.zig");
const RelationRegistry = relation_registry.RelationRegistry;
const RelationRegistryError = relation_registry.RelationRegistryError;

/// Batch of changes from PostgreSQL (streaming source)
pub const Batch = struct {
    /// Change events (flat list)
    changes: []ChangeEvent,

    /// LSN for feedback (last change in batch)
    last_lsn: u64,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *Batch) void {
        for (self.changes) |*change| {
            change.deinit(self.allocator);
        }
        self.allocator.free(self.changes);
    }
};

pub const PostgresSourceError = error{
    ConnectionFailed,
    ReplicationFailed,
    DecodeFailed,
    ConversionFailed,
    OutOfMemory,
};

/// PostgreSQL streaming source adapter
/// Uses logical replication with pgoutput format
///
/// LSN Tracking Design:
/// - extractChangeFromMessage() returns LSN explicitly (or 0 on error)
/// - receiveBatchWithTimeout() tracks LSN locally and updates instance field
/// - last_lsn is used as starting point for next batch
pub const PostgresSource = struct {
    allocator: std.mem.Allocator,
    protocol: ReplicationProtocol,
    decoder: PgOutputDecoder,
    registry: RelationRegistry,
    last_lsn: u64, // Last confirmed LSN (starting point for next batch)

    const Self = @This();

    /// Initialize streaming source
    pub fn init(
        allocator: std.mem.Allocator,
        slot_name: []const u8,
        publication_name: []const u8,
    ) Self {
        return Self{
            .allocator = allocator,
            .protocol = ReplicationProtocol.init(allocator, slot_name, publication_name),
            .decoder = PgOutputDecoder.init(allocator),
            .registry = RelationRegistry.init(allocator),
            .last_lsn = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        self.protocol.deinit();
        self.registry.deinit();
    }

    /// Connect to PostgreSQL and start replication
    pub fn connect(self: *Self, connection_string: []const u8, start_lsn: []const u8) PostgresSourceError!void {
        self.protocol.connect(connection_string) catch |err| {
            std.log.warn("Failed to connect with replication protocol: {}", .{err});
            return PostgresSourceError.ConnectionFailed;
        };

        // Create publication if it doesn't exist
        self.protocol.createPublicationIfNotExists() catch |err| {
            std.log.warn("Failed to create publication: {}", .{err});
            return PostgresSourceError.ConnectionFailed;
        };

        // Create replication slot if it doesn't exist
        self.protocol.createSlotIfNotExists() catch |err| {
            std.log.warn("Failed to create replication slot: {}", .{err});
            return PostgresSourceError.ConnectionFailed;
        };

        self.protocol.startReplication(start_lsn) catch |err| {
            std.log.warn("Failed to start replication: {}", .{err});
            return PostgresSourceError.ReplicationFailed;
        };

        std.log.info("Streaming replication started from LSN: {s}", .{start_lsn});
    }

    /// Receive batch of changes from PostgreSQL (default wait time from constants)
    /// Wrapper for compatibility with polling source API
    pub fn receiveBatch(self: *Self, limit: usize) PostgresSourceError!Batch {
        return self.receiveBatchWithWaitTime(limit, constants.CDC.BATCH_WAIT_MS);
    }

    /// Receive batch of changes from PostgreSQL (with wait time)
    /// limit: desired batch size (soft limit)
    /// wait_time_ms: max time to wait for batch
    pub fn receiveBatchWithWaitTime(self: *Self, limit: usize, wait_time_ms: i32) PostgresSourceError!Batch {
        var changes = std.ArrayList(ChangeEvent).empty;
        errdefer {
            for (changes.items) |*change| {
                change.deinit(self.allocator);
            }
            changes.deinit(self.allocator);
        }

        var last_confirmed_lsn: u64 = self.last_lsn; // Track LSN locally

        const start_time = std.time.milliTimestamp();
        const deadline = start_time + wait_time_ms;

        while (changes.items.len < limit and std.time.milliTimestamp() < deadline) {
            const remaining_time = @max(deadline - std.time.milliTimestamp(), 0);
            const wait_time: i32 = @intCast(remaining_time);

            // Step 1: Blocking receive (poll() inside)
            const repl_msg = self.protocol.receiveMessage(wait_time) catch |err| {
                std.log.warn("Failed to receive replication message: {}", .{err});
                return PostgresSourceError.ReplicationFailed;
            };

            if (repl_msg == null) {
                // Wait time elapsed - no message available
                if (changes.items.len > 0) {
                    // Return what we have
                    break;
                }
                continue;
            }

            // Extract change from the first message
            var msg = repl_msg.?;
            defer msg.deinit(self.allocator);

            const msg_lsn = try self.extractChangeFromMessage(msg, &changes);
            last_confirmed_lsn = msg_lsn; // Update LSN (always > 0 on success)

            // Step 2: DRAIN all buffered messages (non-blocking)
            while (changes.items.len < limit) {
                const next_msg = self.protocol.receiveMessage(0) catch break; // 0ms wait time = non-blocking
                if (next_msg == null) break; // No more buffered data

                var buffered_msg = next_msg.?;
                defer buffered_msg.deinit(self.allocator);

                const buffered_lsn = try self.extractChangeFromMessage(buffered_msg, &changes);
                last_confirmed_lsn = buffered_lsn; // Update LSN (always > 0 on success)
            }
        }

        // Update instance LSN for next batch
        self.last_lsn = last_confirmed_lsn;

        return .{
            .changes = try changes.toOwnedSlice(self.allocator),
            .last_lsn = last_confirmed_lsn,
            .allocator = self.allocator,
        };
    }

    /// Extract change from replication message and return LSN for confirmation
    /// Returns LSN of the message if successfully processed
    /// Propagates errors (DecodeFailed, ConversionFailed) to caller
    ///
    /// LSN is returned even for messages that don't produce ChangeEvents
    /// (BEGIN/COMMIT/RELATION) - they are still considered "processed"
    ///
    /// Error handling strategy (Fail-stop):
    /// - Decode/convert errors propagate up to main()
    /// - Application exits with non-zero code
    /// - Supervisor (systemd/k8s) restarts application
    /// - PostgreSQL re-sends the same message (LSN not confirmed)
    /// - If error persists → crash loop → operator intervention required
    fn extractChangeFromMessage(self: *Self, msg: replication_protocol.ReplicationMessage, changes: *std.ArrayList(ChangeEvent)) !u64 {
        switch (msg) {
            .xlog_data => |xlog| {
                // Decode pgoutput message
                var pg_msg = self.decoder.decode(xlog.wal_data) catch |err| {
                    std.log.warn("Failed to decode pgoutput message at LSN {}: {}", .{ xlog.server_wal_end, err });
                    return PostgresSourceError.DecodeFailed; // Propagate error up
                };
                defer pg_msg.deinit(self.allocator);

                // Convert to ChangeEvent
                const change_opt = self.convertToChangeEvent(pg_msg) catch |err| {
                    std.log.warn("Failed to convert message to ChangeEvent at LSN {}: {}", .{ xlog.server_wal_end, err });
                    return PostgresSourceError.ConversionFailed; // Propagate error up
                };

                // Add ChangeEvent to batch if present
                if (change_opt) |change_event| {
                    try changes.append(self.allocator, change_event);
                    // If append fails (OOM), error propagates up
                    // → batch won't be returned → LSN won't be confirmed → no data loss
                }

                // Successfully processed - return LSN for confirmation
                return xlog.server_wal_end;
            },
            .keepalive => |keepalive| {
                // Do NOT send reply here (even if reply_requested=true)
                // Reason: We must maintain at-least-once guarantee
                // - Sending reply here would confirm LSN before Kafka flush
                // - If Kafka flush fails, data would be lost
                // - Processor will send feedback after successful Kafka flush
                //
                // Note: PostgreSQL may wait for reply, but our batch wait time (~6 sec)
                // is much shorter than wal_sender_timeout (default 60 sec)
                return keepalive.server_wal_end;
            },
        }
    }

    /// Send LSN feedback to PostgreSQL (confirm processing)
    pub fn sendFeedback(self: *Self, lsn: u64) PostgresSourceError!void {
        const status = StandbyStatusUpdate{
            .wal_write_position = lsn,
            .wal_flush_position = lsn,
            .wal_apply_position = lsn,
            .client_time = std.time.timestamp(),
            .reply_requested = false,
        };

        self.protocol.sendStatusUpdate(status) catch |err| {
            std.log.warn("Failed to send feedback: {}", .{err});
            return PostgresSourceError.ReplicationFailed;
        };
    }

    /// Convert PgOutputMessage to ChangeEvent
    /// Returns null for messages that don't produce ChangeEvents (BEGIN, COMMIT, RELATION)
    fn convertToChangeEvent(self: *Self, pg_msg: PgOutputMessage) PostgresSourceError!?ChangeEvent {
        switch (pg_msg) {
            .begin, .commit => {
                // Transaction markers - don't produce ChangeEvents yet
                return null;
            },
            .relation => |rel| {
                // Register relation metadata
                self.registry.register(rel) catch |err| {
                    std.log.warn("Failed to register relation: {}", .{err});
                    return PostgresSourceError.ConversionFailed;
                };
                return null;
            },
            .insert => |ins| {
                return self.convertInsert(ins) catch |err| {
                    std.log.warn("Failed to convert INSERT: {}", .{err});
                    return PostgresSourceError.ConversionFailed;
                };
            },
            .update => |upd| {
                return self.convertUpdate(upd) catch |err| {
                    std.log.warn("Failed to convert UPDATE: {}", .{err});
                    return PostgresSourceError.ConversionFailed;
                };
            },
            .delete => |del| {
                return self.convertDelete(del) catch |err| {
                    std.log.warn("Failed to convert DELETE: {}", .{err});
                    return PostgresSourceError.ConversionFailed;
                };
            },
        }
    }

    fn convertInsert(self: *Self, insert_msg: anytype) !ChangeEvent {
        const rel_info = try self.registry.get(insert_msg.relation_id);

        // Build metadata
        const metadata = Metadata{
            .source = try self.allocator.dupe(u8, "postgres"),
            .resource = try self.allocator.dupe(u8, rel_info.relation_name),
            .schema = try self.allocator.dupe(u8, rel_info.namespace),
            .timestamp = std.time.timestamp(),
            .lsn = null,
        };

        var event = ChangeEvent.init(ChangeOperation.INSERT, metadata);

        // Convert tuple to RowData
        const row_data = try self.tupleToRowData(insert_msg.new_tuple, rel_info);
        event.setInsertData(row_data);

        return event;
    }

    fn convertUpdate(self: *Self, update_msg: anytype) !ChangeEvent {
        const rel_info = try self.registry.get(update_msg.relation_id);

        const metadata = Metadata{
            .source = try self.allocator.dupe(u8, "postgres"),
            .resource = try self.allocator.dupe(u8, rel_info.relation_name),
            .schema = try self.allocator.dupe(u8, rel_info.namespace),
            .timestamp = std.time.timestamp(),
            .lsn = null,
        };

        var event = ChangeEvent.init(ChangeOperation.UPDATE, metadata);

        // Convert new and old tuples
        const new_row = try self.tupleToRowData(update_msg.new_tuple, rel_info);
        const old_row = if (update_msg.old_tuple) |old_tuple|
            try self.tupleToRowData(old_tuple, rel_info)
        else
            try self.allocator.alloc(domain.FieldData, 0); // Empty old data if not available

        event.setUpdateData(new_row, old_row);

        return event;
    }

    fn convertDelete(self: *Self, delete_msg: anytype) !ChangeEvent {
        const rel_info = try self.registry.get(delete_msg.relation_id);

        const metadata = Metadata{
            .source = try self.allocator.dupe(u8, "postgres"),
            .resource = try self.allocator.dupe(u8, rel_info.relation_name),
            .schema = try self.allocator.dupe(u8, rel_info.namespace),
            .timestamp = std.time.timestamp(),
            .lsn = null,
        };

        var event = ChangeEvent.init(ChangeOperation.DELETE, metadata);

        // Convert old tuple (key or full replica identity)
        const row_data = try self.tupleToRowData(delete_msg.old_tuple, rel_info);
        event.setDeleteData(row_data);

        return event;
    }

    /// Convert TupleData to RowData using relation metadata
    fn tupleToRowData(self: *Self, tuple: anytype, rel_info: anytype) !RowData {
        var builder = RowDataHelpers.createBuilder(self.allocator);
        errdefer {
            for (builder.items) |field| {
                self.allocator.free(field.name);
                if (field.value == .string) {
                    self.allocator.free(field.value.string);
                }
            }
            builder.deinit(self.allocator);
        }

        for (tuple.columns, 0..) |col, i| {
            const col_name = rel_info.columns[i].name;

            if (col.value) |val| {
                // Column has value - convert to FieldValue
                // For now, treat all values as text (pgoutput sends text format)
                const field_value = try FieldValueHelpers.text(self.allocator, val);
                try RowDataHelpers.put(&builder, self.allocator, col_name, field_value);
            } else {
                // Column is NULL
                try RowDataHelpers.put(&builder, self.allocator, col_name, FieldValueHelpers.null_value());
            }
        }

        return try RowDataHelpers.finalize(&builder, self.allocator);
    }
};

// Unit Tests
const testing = std.testing;

test "convertInsert: basic INSERT message to ChangeEvent" {
    const allocator = testing.allocator;

    // Setup: Create source with registry
    var source = PostgresSource.init(allocator, "test_slot", "test_pub");
    defer source.deinit();

    // Register test relation (id=100, public.users, columns: id, name)
    var rel_msg = pg_output_decoder.RelationMessage{
        .relation_id = 100,
        .namespace = try allocator.dupe(u8, "public"),
        .relation_name = try allocator.dupe(u8, "users"),
        .replica_identity = 'd',
        .columns = try allocator.alloc(pg_output_decoder.RelationMessageColumn, 2),
    };
    defer rel_msg.deinit(allocator);

    rel_msg.columns[0] = pg_output_decoder.RelationMessageColumn{
        .flags = 1,
        .name = try allocator.dupe(u8, "id"),
        .data_type = 23, // int4
        .type_modifier = -1,
    };
    rel_msg.columns[1] = pg_output_decoder.RelationMessageColumn{
        .flags = 0,
        .name = try allocator.dupe(u8, "name"),
        .data_type = 25, // text
        .type_modifier = -1,
    };

    try source.registry.register(rel_msg);

    // Create INSERT message
    var insert_msg = pg_output_decoder.InsertMessage{
        .relation_id = 100,
        .new_tuple = pg_output_decoder.TupleMessage{
            .columns = try allocator.alloc(pg_output_decoder.TupleData, 2),
        },
    };
    insert_msg.new_tuple.columns[0] = pg_output_decoder.TupleData{
        .column_type = .text,
        .value = try allocator.dupe(u8, "1"),
    };
    insert_msg.new_tuple.columns[1] = pg_output_decoder.TupleData{
        .column_type = .text,
        .value = try allocator.dupe(u8, "Alice"),
    };
    defer insert_msg.new_tuple.deinit(allocator);

    // Call convertInsert
    var event = try source.convertInsert(insert_msg);
    defer event.deinit(allocator);

    // Verify: operation type
    try testing.expectEqualStrings("INSERT", event.op);

    // Verify: metadata
    try testing.expectEqualStrings("postgres", event.meta.source);
    try testing.expectEqualStrings("users", event.meta.resource);
    try testing.expectEqualStrings("public", event.meta.schema);
    try testing.expect(event.meta.timestamp > 0);

    // Verify: insert_data present
    try testing.expect(event.data == .insert);
    const insert_data = event.data.insert;
    try testing.expectEqual(@as(usize, 2), insert_data.len);

    // Verify: field values
    try testing.expectEqualStrings("id", insert_data[0].name);
    try testing.expect(insert_data[0].value == .string);
    try testing.expectEqualStrings("1", insert_data[0].value.string);

    try testing.expectEqualStrings("name", insert_data[1].name);
    try testing.expect(insert_data[1].value == .string);
    try testing.expectEqualStrings("Alice", insert_data[1].value.string);
}

test "convertUpdate: UPDATE message with old and new tuples" {
    const allocator = testing.allocator;

    // Setup: Create source with registry
    var source = PostgresSource.init(allocator, "test_slot", "test_pub");
    defer source.deinit();

    // Register test relation (id=100, public.users, columns: id, name)
    var rel_msg = pg_output_decoder.RelationMessage{
        .relation_id = 100,
        .namespace = try allocator.dupe(u8, "public"),
        .relation_name = try allocator.dupe(u8, "users"),
        .replica_identity = 'd',
        .columns = try allocator.alloc(pg_output_decoder.RelationMessageColumn, 2),
    };
    defer rel_msg.deinit(allocator);

    rel_msg.columns[0] = pg_output_decoder.RelationMessageColumn{
        .flags = 1,
        .name = try allocator.dupe(u8, "id"),
        .data_type = 23, // int4
        .type_modifier = -1,
    };
    rel_msg.columns[1] = pg_output_decoder.RelationMessageColumn{
        .flags = 0,
        .name = try allocator.dupe(u8, "name"),
        .data_type = 25, // text
        .type_modifier = -1,
    };

    try source.registry.register(rel_msg);

    // Create UPDATE message with old and new tuples
    var update_msg = pg_output_decoder.UpdateMessage{
        .relation_id = 100,
        .old_tuple = pg_output_decoder.TupleMessage{
            .columns = try allocator.alloc(pg_output_decoder.TupleData, 2),
        },
        .new_tuple = pg_output_decoder.TupleMessage{
            .columns = try allocator.alloc(pg_output_decoder.TupleData, 2),
        },
    };
    defer update_msg.deinit(allocator);

    // Old tuple: id=1, name=Alice
    update_msg.old_tuple.?.columns[0] = pg_output_decoder.TupleData{
        .column_type = .text,
        .value = try allocator.dupe(u8, "1"),
    };
    update_msg.old_tuple.?.columns[1] = pg_output_decoder.TupleData{
        .column_type = .text,
        .value = try allocator.dupe(u8, "Alice"),
    };

    // New tuple: id=1, name=Bob
    update_msg.new_tuple.columns[0] = pg_output_decoder.TupleData{
        .column_type = .text,
        .value = try allocator.dupe(u8, "1"),
    };
    update_msg.new_tuple.columns[1] = pg_output_decoder.TupleData{
        .column_type = .text,
        .value = try allocator.dupe(u8, "Bob"),
    };

    // Call convertUpdate
    var event = try source.convertUpdate(update_msg);
    defer event.deinit(allocator);

    // Verify: operation type
    try testing.expectEqualStrings("UPDATE", event.op);

    // Verify: metadata
    try testing.expectEqualStrings("postgres", event.meta.source);
    try testing.expectEqualStrings("users", event.meta.resource);
    try testing.expectEqualStrings("public", event.meta.schema);
    try testing.expect(event.meta.timestamp > 0);

    // Verify: update data present
    try testing.expect(event.data == .update);
    const new_data = event.data.update.new;
    const old_data = event.data.update.old;

    // Verify: new_data
    try testing.expectEqual(@as(usize, 2), new_data.len);
    try testing.expectEqualStrings("id", new_data[0].name);
    try testing.expectEqualStrings("1", new_data[0].value.string);
    try testing.expectEqualStrings("name", new_data[1].name);
    try testing.expectEqualStrings("Bob", new_data[1].value.string);

    // Verify: old_data
    try testing.expectEqual(@as(usize, 2), old_data.len);
    try testing.expectEqualStrings("id", old_data[0].name);
    try testing.expectEqualStrings("1", old_data[0].value.string);
    try testing.expectEqualStrings("name", old_data[1].name);
    try testing.expectEqualStrings("Alice", old_data[1].value.string);
}

test "convertDelete: DELETE message to ChangeEvent" {
    const allocator = testing.allocator;

    // Setup: Create source with registry
    var source = PostgresSource.init(allocator, "test_slot", "test_pub");
    defer source.deinit();

    // Register test relation
    var rel_msg = pg_output_decoder.RelationMessage{
        .relation_id = 100,
        .namespace = try allocator.dupe(u8, "public"),
        .relation_name = try allocator.dupe(u8, "users"),
        .replica_identity = 'd',
        .columns = try allocator.alloc(pg_output_decoder.RelationMessageColumn, 2),
    };
    defer rel_msg.deinit(allocator);

    rel_msg.columns[0] = pg_output_decoder.RelationMessageColumn{
        .flags = 1,
        .name = try allocator.dupe(u8, "id"),
        .data_type = 23,
        .type_modifier = -1,
    };
    rel_msg.columns[1] = pg_output_decoder.RelationMessageColumn{
        .flags = 0,
        .name = try allocator.dupe(u8, "name"),
        .data_type = 25,
        .type_modifier = -1,
    };

    try source.registry.register(rel_msg);

    // Create DELETE message
    var delete_msg = pg_output_decoder.DeleteMessage{
        .relation_id = 100,
        .old_tuple = pg_output_decoder.TupleMessage{
            .columns = try allocator.alloc(pg_output_decoder.TupleData, 2),
        },
    };
    defer delete_msg.deinit(allocator);

    delete_msg.old_tuple.columns[0] = pg_output_decoder.TupleData{
        .column_type = .text,
        .value = try allocator.dupe(u8, "1"),
    };
    delete_msg.old_tuple.columns[1] = pg_output_decoder.TupleData{
        .column_type = .text,
        .value = try allocator.dupe(u8, "Alice"),
    };

    // Call convertDelete
    var event = try source.convertDelete(delete_msg);
    defer event.deinit(allocator);

    // Verify: operation type
    try testing.expectEqualStrings("DELETE", event.op);

    // Verify: metadata
    try testing.expectEqualStrings("postgres", event.meta.source);
    try testing.expectEqualStrings("users", event.meta.resource);
    try testing.expectEqualStrings("public", event.meta.schema);

    // Verify: delete_data present
    try testing.expect(event.data == .delete);
    const delete_data = event.data.delete;
    try testing.expectEqual(@as(usize, 2), delete_data.len);
    try testing.expectEqualStrings("id", delete_data[0].name);
    try testing.expectEqualStrings("1", delete_data[0].value.string);
    try testing.expectEqualStrings("name", delete_data[1].name);
    try testing.expectEqualStrings("Alice", delete_data[1].value.string);
}

test "tupleToRowData: convert tuple with text values to RowData" {
    const allocator = testing.allocator;

    // Setup: Create source with registry
    var source = PostgresSource.init(allocator, "test_slot", "test_pub");
    defer source.deinit();

    // Register relation with 3 columns: id, name, email
    var rel_msg = pg_output_decoder.RelationMessage{
        .relation_id = 200,
        .namespace = try allocator.dupe(u8, "public"),
        .relation_name = try allocator.dupe(u8, "users"),
        .replica_identity = 'd',
        .columns = try allocator.alloc(pg_output_decoder.RelationMessageColumn, 3),
    };
    defer rel_msg.deinit(allocator);

    rel_msg.columns[0] = pg_output_decoder.RelationMessageColumn{
        .flags = 1,
        .name = try allocator.dupe(u8, "id"),
        .data_type = 23,
        .type_modifier = -1,
    };
    rel_msg.columns[1] = pg_output_decoder.RelationMessageColumn{
        .flags = 0,
        .name = try allocator.dupe(u8, "name"),
        .data_type = 25,
        .type_modifier = -1,
    };
    rel_msg.columns[2] = pg_output_decoder.RelationMessageColumn{
        .flags = 0,
        .name = try allocator.dupe(u8, "email"),
        .data_type = 25,
        .type_modifier = -1,
    };

    try source.registry.register(rel_msg);

    // Create tuple with text values
    var tuple = pg_output_decoder.TupleMessage{
        .columns = try allocator.alloc(pg_output_decoder.TupleData, 3),
    };
    defer tuple.deinit(allocator);

    tuple.columns[0] = pg_output_decoder.TupleData{
        .column_type = .text,
        .value = try allocator.dupe(u8, "42"),
    };
    tuple.columns[1] = pg_output_decoder.TupleData{
        .column_type = .text,
        .value = try allocator.dupe(u8, "John"),
    };
    tuple.columns[2] = pg_output_decoder.TupleData{
        .column_type = .text,
        .value = try allocator.dupe(u8, "john@example.com"),
    };

    // Get relation info
    const rel_info = try source.registry.get(200);

    // Call tupleToRowData
    const row_data = try source.tupleToRowData(tuple, rel_info);
    defer {
        for (row_data) |field| {
            allocator.free(field.name);
            if (field.value == .string) {
                allocator.free(field.value.string);
            }
        }
        allocator.free(row_data);
    }

    // Verify: 3 fields
    try testing.expectEqual(@as(usize, 3), row_data.len);

    // Verify: field 0 (id)
    try testing.expectEqualStrings("id", row_data[0].name);
    try testing.expect(row_data[0].value == .string);
    try testing.expectEqualStrings("42", row_data[0].value.string);

    // Verify: field 1 (name)
    try testing.expectEqualStrings("name", row_data[1].name);
    try testing.expect(row_data[1].value == .string);
    try testing.expectEqualStrings("John", row_data[1].value.string);

    // Verify: field 2 (email)
    try testing.expectEqualStrings("email", row_data[2].name);
    try testing.expect(row_data[2].value == .string);
    try testing.expectEqualStrings("john@example.com", row_data[2].value.string);
}

test "tupleToRowData: handle NULL values in tuple" {
    const allocator = testing.allocator;

    // Setup: Create source with registry
    var source = PostgresSource.init(allocator, "test_slot", "test_pub");
    defer source.deinit();

    // Register relation with 3 columns
    var rel_msg = pg_output_decoder.RelationMessage{
        .relation_id = 300,
        .namespace = try allocator.dupe(u8, "public"),
        .relation_name = try allocator.dupe(u8, "users"),
        .replica_identity = 'd',
        .columns = try allocator.alloc(pg_output_decoder.RelationMessageColumn, 3),
    };
    defer rel_msg.deinit(allocator);

    rel_msg.columns[0] = pg_output_decoder.RelationMessageColumn{
        .flags = 1,
        .name = try allocator.dupe(u8, "id"),
        .data_type = 23,
        .type_modifier = -1,
    };
    rel_msg.columns[1] = pg_output_decoder.RelationMessageColumn{
        .flags = 0,
        .name = try allocator.dupe(u8, "name"),
        .data_type = 25,
        .type_modifier = -1,
    };
    rel_msg.columns[2] = pg_output_decoder.RelationMessageColumn{
        .flags = 0,
        .name = try allocator.dupe(u8, "email"),
        .data_type = 25,
        .type_modifier = -1,
    };

    try source.registry.register(rel_msg);

    // Create tuple with NULL values: id=1, name=NULL, email="test@example.com"
    var tuple = pg_output_decoder.TupleMessage{
        .columns = try allocator.alloc(pg_output_decoder.TupleData, 3),
    };
    defer tuple.deinit(allocator);

    tuple.columns[0] = pg_output_decoder.TupleData{
        .column_type = .text,
        .value = try allocator.dupe(u8, "1"),
    };
    tuple.columns[1] = pg_output_decoder.TupleData{
        .column_type = .null,
        .value = null, // NULL value
    };
    tuple.columns[2] = pg_output_decoder.TupleData{
        .column_type = .text,
        .value = try allocator.dupe(u8, "test@example.com"),
    };

    // Get relation info
    const rel_info = try source.registry.get(300);

    // Call tupleToRowData
    const row_data = try source.tupleToRowData(tuple, rel_info);
    defer {
        for (row_data) |field| {
            allocator.free(field.name);
            if (field.value == .string) {
                allocator.free(field.value.string);
            }
        }
        allocator.free(row_data);
    }

    // Verify: 3 fields
    try testing.expectEqual(@as(usize, 3), row_data.len);

    // Verify: field 0 (id) - has value
    try testing.expectEqualStrings("id", row_data[0].name);
    try testing.expect(row_data[0].value == .string);
    try testing.expectEqualStrings("1", row_data[0].value.string);

    // Verify: field 1 (name) - NULL
    try testing.expectEqualStrings("name", row_data[1].name);
    try testing.expect(row_data[1].value == .null);

    // Verify: field 2 (email) - has value
    try testing.expectEqualStrings("email", row_data[2].name);
    try testing.expect(row_data[2].value == .string);
    try testing.expectEqualStrings("test@example.com", row_data[2].value.string);
}

test "convertInsert: error when relation not found in registry" {
    const allocator = testing.allocator;

    // Setup: Create source with empty registry (no relations registered)
    var source = PostgresSource.init(allocator, "test_slot", "test_pub");
    defer source.deinit();

    // Create INSERT message for non-existent relation (id=999)
    var insert_msg = pg_output_decoder.InsertMessage{
        .relation_id = 999, // This relation is NOT registered
        .new_tuple = pg_output_decoder.TupleMessage{
            .columns = try allocator.alloc(pg_output_decoder.TupleData, 1),
        },
    };
    defer insert_msg.new_tuple.deinit(allocator);

    insert_msg.new_tuple.columns[0] = pg_output_decoder.TupleData{
        .column_type = .text,
        .value = try allocator.dupe(u8, "test"),
    };

    // Call convertInsert - should return RelationNotFound error
    const result = source.convertInsert(insert_msg);

    // Verify: error is RelationNotFound
    try testing.expectError(RelationRegistryError.RelationNotFound, result);
}
