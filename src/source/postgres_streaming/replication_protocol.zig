const std = @import("std");
const c = @cImport({
    @cInclude("libpq-fe.h");
});

pub const ReplicationError = error{
    ConnectionFailed,
    StartReplicationFailed,
    ReceiveFailed,
    SendFeedbackFailed,
    InvalidMessage,
    OutOfMemory,
};

// Message type identifiers from PostgreSQL replication protocol
pub const MessageType = enum(u8) {
    xlog_data = 'w',
    keepalive = 'k',
    status_update = 'r',
    _,
};

pub const XLogData = struct {
    wal_start: u64,
    server_wal_end: u64,
    server_time: i64,
    wal_data: []const u8,

    pub fn deinit(self: *XLogData, allocator: std.mem.Allocator) void {
        allocator.free(self.wal_data);
    }
};

pub const PrimaryKeepalive = struct {
    server_wal_end: u64,
    server_time: i64,
    reply_requested: bool,
};

pub const StandbyStatusUpdate = struct {
    wal_write_position: u64,
    wal_flush_position: u64,
    wal_apply_position: u64,
    client_time: i64,
    reply_requested: bool,
};

pub const ReplicationMessage = union(enum) {
    xlog_data: XLogData,
    keepalive: PrimaryKeepalive,

    pub fn deinit(self: *ReplicationMessage, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .xlog_data => |*data| data.deinit(allocator),
            .keepalive => {},
        }
    }
};

pub const ReplicationProtocol = struct {
    allocator: std.mem.Allocator,
    connection: ?*c.PGconn,
    slot_name: []const u8,
    publication_name: []const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, slot_name: []const u8, publication_name: []const u8) Self {
        return Self{
            .allocator = allocator,
            .connection = null,
            .slot_name = slot_name,
            .publication_name = publication_name,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.connection) |conn| {
            c.PQfinish(conn);
            self.connection = null;
        }
    }

    pub fn connect(self: *Self, connection_string: []const u8) ReplicationError!void {
        // Build connection string with replication=database parameter
        const repl_conn_str = std.fmt.allocPrint(
            self.allocator,
            "{s} replication=database",
            .{connection_string},
        ) catch return ReplicationError.OutOfMemory;
        defer self.allocator.free(repl_conn_str);

        const conn_str_z = self.allocator.dupeZ(u8, repl_conn_str) catch return ReplicationError.OutOfMemory;
        defer self.allocator.free(conn_str_z);

        std.log.debug("Connecting to PostgreSQL with replication mode", .{});

        self.connection = c.PQconnectdb(conn_str_z.ptr);

        if (self.connection == null) {
            std.log.warn("Failed to allocate replication connection", .{});
            return ReplicationError.ConnectionFailed;
        }

        const status = c.PQstatus(self.connection);
        if (status != c.CONNECTION_OK) {
            const error_msg = c.PQerrorMessage(self.connection);
            std.log.warn("Replication connection failed: {s}", .{error_msg});
            c.PQfinish(self.connection);
            self.connection = null;
            return ReplicationError.ConnectionFailed;
        }

        std.log.debug("Replication connection established", .{});
    }

    pub fn startReplication(self: *Self, start_lsn: []const u8) ReplicationError!void {
        if (self.connection == null) return ReplicationError.ConnectionFailed;

        // START_REPLICATION SLOT slot_name LOGICAL lsn (proto_version '1', publication_names 'pub_name')
        const sql_tmp = std.fmt.allocPrint(
            self.allocator,
            "START_REPLICATION SLOT {s} LOGICAL {s} (proto_version '1', publication_names '{s}')",
            .{ self.slot_name, start_lsn, self.publication_name },
        ) catch return ReplicationError.OutOfMemory;
        defer self.allocator.free(sql_tmp);

        const sql = self.allocator.dupeZ(u8, sql_tmp) catch return ReplicationError.OutOfMemory;
        defer self.allocator.free(sql);

        std.log.debug("Starting replication: {s}", .{sql});

        const result = c.PQexec(self.connection, sql.ptr);
        defer c.PQclear(result);

        const status = c.PQresultStatus(result);
        if (status != c.PGRES_COPY_BOTH) {
            const error_msg = c.PQresultErrorMessage(result);
            std.log.warn("START_REPLICATION failed: {s}", .{error_msg});
            return ReplicationError.StartReplicationFailed;
        }

        std.log.debug("Replication started successfully", .{});
    }

    pub fn receiveMessage(self: *Self, timeout_ms: i32) ReplicationError!?ReplicationMessage {
        if (self.connection == null) return ReplicationError.ConnectionFailed;

        // Simple polling approach: try to consume input and check if busy
        const start_time = std.time.milliTimestamp();
        const timeout_time = start_time + timeout_ms;

        while (std.time.milliTimestamp() < timeout_time) {
            // Consume input
            if (c.PQconsumeInput(self.connection) == 0) {
                const error_msg = c.PQerrorMessage(self.connection);
                std.log.warn("Failed to consume input: {s}", .{error_msg});
                return ReplicationError.ReceiveFailed;
            }

            // Check if data is available
            if (c.PQisBusy(self.connection) == 0) {
                // Data available, break out to process it
                break;
            }

            // Sleep a bit before retrying
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }

        // Final check after timeout
        if (c.PQisBusy(self.connection) != 0) {
            // Timeout - no complete message
            return null;
        }

        // Get CopyData message
        var buffer: [*c]u8 = undefined;
        const len = c.PQgetCopyData(self.connection, &buffer, 0);

        if (len == -1) {
            // No more data (shouldn't happen after select)
            return null;
        }

        if (len == -2) {
            const error_msg = c.PQerrorMessage(self.connection);
            std.log.warn("Error reading copy data: {s}", .{error_msg});
            return ReplicationError.ReceiveFailed;
        }

        defer c.PQfreemem(buffer);

        // Parse message type (first byte)
        if (len < 1) {
            return ReplicationError.InvalidMessage;
        }

        const msg_type: MessageType = @enumFromInt(buffer[0]);

        switch (msg_type) {
            .xlog_data => {
                if (len < 25) { // 1 + 8 + 8 + 8 = 25 bytes minimum
                    return ReplicationError.InvalidMessage;
                }

                // Parse XLogData message
                // Format: 'w' + WALStart(8) + ServerWALEnd(8) + ServerTime(8) + WALData
                const wal_start = readU64BigEndian(buffer[1..9]);
                const server_wal_end = readU64BigEndian(buffer[9..17]);
                const server_time = readI64BigEndian(buffer[17..25]);

                const wal_data = self.allocator.dupe(u8, buffer[25..@as(usize, @intCast(len))]) catch return ReplicationError.OutOfMemory;

                return ReplicationMessage{
                    .xlog_data = XLogData{
                        .wal_start = wal_start,
                        .server_wal_end = server_wal_end,
                        .server_time = server_time,
                        .wal_data = wal_data,
                    },
                };
            },
            .keepalive => {
                if (len < 18) { // 1 + 8 + 8 + 1 = 18 bytes
                    return ReplicationError.InvalidMessage;
                }

                // Parse PrimaryKeepalive message
                // Format: 'k' + ServerWALEnd(8) + ServerTime(8) + ReplyRequested(1)
                const server_wal_end = readU64BigEndian(buffer[1..9]);
                const server_time = readI64BigEndian(buffer[9..17]);
                const reply_requested = buffer[17] != 0;

                return ReplicationMessage{
                    .keepalive = PrimaryKeepalive{
                        .server_wal_end = server_wal_end,
                        .server_time = server_time,
                        .reply_requested = reply_requested,
                    },
                };
            },
            else => {
                std.log.debug("Unknown message type: {c}", .{@as(u8, @intFromEnum(msg_type))});
                return ReplicationError.InvalidMessage;
            },
        }
    }

    pub fn sendStatusUpdate(self: *Self, update: StandbyStatusUpdate) ReplicationError!void {
        if (self.connection == null) return ReplicationError.ConnectionFailed;

        // Build StandbyStatusUpdate message
        // Format: 'r' + WALWrite(8) + WALFlush(8) + WALApply(8) + ClientTime(8) + ReplyRequested(1)
        var buffer: [34]u8 = undefined;
        buffer[0] = 'r';
        writeU64BigEndian(buffer[1..9], update.wal_write_position);
        writeU64BigEndian(buffer[9..17], update.wal_flush_position);
        writeU64BigEndian(buffer[17..25], update.wal_apply_position);
        writeI64BigEndian(buffer[25..33], update.client_time);
        buffer[33] = if (update.reply_requested) 1 else 0;

        const result = c.PQputCopyData(self.connection, &buffer, buffer.len);
        if (result != 1) {
            const error_msg = c.PQerrorMessage(self.connection);
            std.log.warn("Failed to send status update: {s}", .{error_msg});
            return ReplicationError.SendFeedbackFailed;
        }

        // Flush the data
        if (c.PQflush(self.connection) != 0) {
            const error_msg = c.PQerrorMessage(self.connection);
            std.log.warn("Failed to flush status update: {s}", .{error_msg});
            return ReplicationError.SendFeedbackFailed;
        }

        std.log.debug("Status update sent: flush_lsn={}", .{update.wal_flush_position});
    }
};

// Helper functions for big-endian encoding (PostgreSQL uses network byte order)
pub fn readU64BigEndian(bytes: [*]const u8) u64 {
    return (@as(u64, bytes[0]) << 56) |
        (@as(u64, bytes[1]) << 48) |
        (@as(u64, bytes[2]) << 40) |
        (@as(u64, bytes[3]) << 32) |
        (@as(u64, bytes[4]) << 24) |
        (@as(u64, bytes[5]) << 16) |
        (@as(u64, bytes[6]) << 8) |
        (@as(u64, bytes[7]));
}

pub fn readI64BigEndian(bytes: [*]const u8) i64 {
    return @bitCast(readU64BigEndian(bytes));
}

pub fn writeU64BigEndian(buffer: []u8, value: u64) void {
    buffer[0] = @intCast((value >> 56) & 0xFF);
    buffer[1] = @intCast((value >> 48) & 0xFF);
    buffer[2] = @intCast((value >> 40) & 0xFF);
    buffer[3] = @intCast((value >> 32) & 0xFF);
    buffer[4] = @intCast((value >> 24) & 0xFF);
    buffer[5] = @intCast((value >> 16) & 0xFF);
    buffer[6] = @intCast((value >> 8) & 0xFF);
    buffer[7] = @intCast(value & 0xFF);
}

pub fn writeI64BigEndian(buffer: []u8, value: i64) void {
    writeU64BigEndian(buffer, @bitCast(value));
}
