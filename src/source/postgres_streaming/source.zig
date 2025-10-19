const std = @import("std");
const domain = @import("domain");
const ChangeEvent = domain.ChangeEvent;
const ChangeOperation = domain.ChangeOperation;
const Metadata = domain.Metadata;
const RowData = domain.RowData;
const RowDataHelpers = domain.RowDataHelpers;
const FieldValueHelpers = domain.FieldValueHelpers;

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

pub const StreamingSourceError = error{
    ConnectionFailed,
    ReplicationFailed,
    DecodeFailed,
    ConversionFailed,
    OutOfMemory,
};

/// PostgreSQL streaming source adapter
/// Uses logical replication with pgoutput format
pub const PostgresStreamingSource = struct {
    allocator: std.mem.Allocator,
    protocol: ReplicationProtocol,
    decoder: PgOutputDecoder,
    registry: RelationRegistry,
    last_lsn: u64,

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
    pub fn connect(self: *Self, connection_string: []const u8, start_lsn: []const u8) StreamingSourceError!void {
        self.protocol.connect(connection_string) catch |err| {
            std.log.warn("Failed to connect with replication protocol: {}", .{err});
            return StreamingSourceError.ConnectionFailed;
        };

        self.protocol.startReplication(start_lsn) catch |err| {
            std.log.warn("Failed to start replication: {}", .{err});
            return StreamingSourceError.ReplicationFailed;
        };

        std.log.debug("Streaming replication started from LSN: {s}", .{start_lsn});
    }

    /// Receive batch of changes from PostgreSQL (default timeout: 1 second)
    /// Wrapper for compatibility with polling source API
    pub fn receiveBatch(self: *Self, limit: usize) StreamingSourceError!Batch {
        const DEFAULT_TIMEOUT_MS = 1000; // 1 second timeout
        return self.receiveBatchWithTimeout(limit, DEFAULT_TIMEOUT_MS);
    }

    /// Receive batch of changes from PostgreSQL (with timeout)
    /// limit: desired batch size (soft limit)
    /// timeout_ms: max time to wait for batch (1000ms = 1 second)
    pub fn receiveBatchWithTimeout(self: *Self, limit: usize, timeout_ms: i32) StreamingSourceError!Batch {
        var changes = std.ArrayList(ChangeEvent).empty;
        errdefer {
            for (changes.items) |*change| {
                change.deinit(self.allocator);
            }
            changes.deinit(self.allocator);
        }

        const start_time = std.time.milliTimestamp();
        const deadline = start_time + timeout_ms;

        while (changes.items.len < limit and std.time.milliTimestamp() < deadline) {
            const remaining_time = @max(deadline - std.time.milliTimestamp(), 0);
            const timeout: i32 = @intCast(@min(remaining_time, 100)); // Poll every 100ms max

            const repl_msg = self.protocol.receiveMessage(timeout) catch |err| {
                std.log.warn("Failed to receive replication message: {}", .{err});
                return StreamingSourceError.ReplicationFailed;
            };

            if (repl_msg == null) {
                // Timeout - no message available
                if (changes.items.len > 0) {
                    // Return what we have
                    break;
                }
                continue;
            }

            var msg = repl_msg.?;
            defer msg.deinit(self.allocator);

            switch (msg) {
                .xlog_data => |xlog| {
                    // Update last_lsn from WAL position
                    self.last_lsn = xlog.server_wal_end;

                    // Decode pgoutput message
                    var pg_msg = self.decoder.decode(xlog.wal_data) catch |err| {
                        std.log.warn("Failed to decode pgoutput message: {}", .{err});
                        continue; // Skip invalid messages
                    };
                    defer pg_msg.deinit(self.allocator);

                    // Convert to ChangeEvent
                    const change_opt = self.convertToChangeEvent(pg_msg) catch |err| {
                        std.log.warn("Failed to convert message to ChangeEvent: {}", .{err});
                        continue;
                    };

                    if (change_opt) |change_event| {
                        try changes.append(self.allocator, change_event);
                    }
                },
                .keepalive => |keepalive| {
                    // Update last_lsn from keepalive
                    self.last_lsn = keepalive.server_wal_end;

                    // Reply if requested
                    if (keepalive.reply_requested) {
                        const status = StandbyStatusUpdate{
                            .wal_write_position = keepalive.server_wal_end,
                            .wal_flush_position = keepalive.server_wal_end,
                            .wal_apply_position = keepalive.server_wal_end,
                            .client_time = std.time.timestamp(),
                            .reply_requested = false,
                        };
                        self.protocol.sendStatusUpdate(status) catch |err| {
                            std.log.warn("Failed to send status update: {}", .{err});
                        };
                    }
                },
            }
        }

        return .{
            .changes = try changes.toOwnedSlice(self.allocator),
            .last_lsn = self.last_lsn,
            .allocator = self.allocator,
        };
    }

    /// Send LSN feedback to PostgreSQL (confirm processing)
    pub fn sendFeedback(self: *Self, lsn: u64) StreamingSourceError!void {
        const status = StandbyStatusUpdate{
            .wal_write_position = lsn,
            .wal_flush_position = lsn,
            .wal_apply_position = lsn,
            .client_time = std.time.timestamp(),
            .reply_requested = false,
        };

        self.protocol.sendStatusUpdate(status) catch |err| {
            std.log.warn("Failed to send feedback: {}", .{err});
            return StreamingSourceError.ReplicationFailed;
        };
    }

    /// Convert PgOutputMessage to ChangeEvent
    /// Returns null for messages that don't produce ChangeEvents (BEGIN, COMMIT, RELATION)
    fn convertToChangeEvent(self: *Self, pg_msg: PgOutputMessage) StreamingSourceError!?ChangeEvent {
        switch (pg_msg) {
            .begin, .commit => {
                // Transaction markers - don't produce ChangeEvents yet
                return null;
            },
            .relation => |rel| {
                // Register relation metadata
                self.registry.register(rel) catch |err| {
                    std.log.warn("Failed to register relation: {}", .{err});
                    return StreamingSourceError.ConversionFailed;
                };
                return null;
            },
            .insert => |ins| {
                return self.convertInsert(ins) catch |err| {
                    std.log.warn("Failed to convert INSERT: {}", .{err});
                    return StreamingSourceError.ConversionFailed;
                };
            },
            .update => |upd| {
                return self.convertUpdate(upd) catch |err| {
                    std.log.warn("Failed to convert UPDATE: {}", .{err});
                    return StreamingSourceError.ConversionFailed;
                };
            },
            .delete => |del| {
                return self.convertDelete(del) catch |err| {
                    std.log.warn("Failed to convert DELETE: {}", .{err});
                    return StreamingSourceError.ConversionFailed;
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
