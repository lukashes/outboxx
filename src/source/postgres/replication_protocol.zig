const std = @import("std");
const c = @import("c"); // C bindings (build-system translate-c)

pub const ReplicationError = error{
    ConnectionFailed,
    StartReplicationFailed,
    ReceiveFailed,
    SendFeedbackFailed,
    InvalidMessage,
    OutOfMemory,
};

/// Message type identifiers from the PostgreSQL replication protocol.
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

/// Low-level libpq streaming replication protocol (CopyBoth mode).
pub const ReplicationProtocol = struct {
    allocator: std.mem.Allocator,
    connection: ?*c.PGconn,
    slot_name: []const u8,
    publication_name: []const u8,
    // Serializes libpq access: the flush worker sends feedback on the same
    // connection the receive loop reads from, and libpq forbids using one
    // PGconn from two threads. Held only for short non-blocking calls; the
    // poll() wait runs unlocked.
    mutex: std.Io.Mutex = .init,
    // consistent_point from CREATE_REPLICATION_SLOT: the LSN where this slot
    // begins. Set only when we create the slot in this run; an existing slot
    // returns nothing, so it stays null. Streaming from it starts exactly at the
    // slot's start point (and, later, aligns with the slot's exported snapshot)
    // instead of relying on "0/0" resolving to the same place.
    consistent_point: ?[]const u8 = null,
    // snapshot_name from CREATE_REPLICATION_SLOT: the exported snapshot valid as
    // of consistent_point, importable with SET TRANSACTION SNAPSHOT while this
    // connection stays open. Set only on a freshly created slot, so its presence
    // is also the "was the slot created this run" signal for the initial snapshot.
    snapshot_name: ?[]const u8 = null,

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
        if (self.consistent_point) |cp| self.allocator.free(cp);
        if (self.snapshot_name) |sn| self.allocator.free(sn);
        if (self.connection) |conn| {
            c.PQfinish(conn);
            self.connection = null;
        }
    }

    /// The slot's start LSN, captured when the slot was created in this run;
    /// null if the slot already existed.
    pub fn startLsn(self: *const Self) ?[]const u8 {
        return self.consistent_point;
    }

    /// The slot's exported snapshot name, captured when the slot was created in
    /// this run; null if the slot already existed (no snapshot to import). Valid
    /// only while this connection stays open and idle.
    pub fn snapshotName(self: *const Self) ?[]const u8 {
        return self.snapshot_name;
    }

    pub fn connect(self: *Self, connection_string: []const u8) ReplicationError!void {
        // connection_string is a user-supplied libpq conninfo (URL or DSN). Pass it as the
        // dbname keyword with expand_dbname=1 so libpq parses it, and add replication=database
        // as a separate parameter; appending it to the string would break the URL form.
        const conninfo_z = self.allocator.dupeZ(u8, connection_string) catch return ReplicationError.OutOfMemory;
        defer self.allocator.free(conninfo_z);

        const keywords = [_][*c]const u8{ "dbname", "replication", null };
        const values = [_][*c]const u8{ conninfo_z.ptr, "database", null };

        std.log.debug("Connecting to PostgreSQL with replication mode", .{});

        self.connection = c.PQconnectdbParams(&keywords, &values, 1);

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

        if (c.PQsslInUse(self.connection) == 0) {
            std.log.info("PostgreSQL connection is not encrypted; set sslmode=require or higher in the connection string to enforce TLS", .{});
        }

        std.log.debug("Replication connection established", .{});
    }

    /// Create the streaming publication (FOR ALL TABLES) if absent. Must run before
    /// the slot is created: pgoutput resolves the publication by name in the
    /// historical catalog for each change, so a change whose LSN predates the
    /// publication cannot be decoded (a change before the slot's start would fail
    /// with "publication does not exist"). Creating the publication first keeps the
    /// slot's consistent point after it, so every streamed change decodes.
    pub fn createPublicationIfNotExists(self: *Self) ReplicationError!void {
        if (self.connection == null) return ReplicationError.ConnectionFailed;

        const pub_name = try self.lowerName(self.publication_name);
        defer self.allocator.free(pub_name);

        if (try self.objectExists("pg_publication", "pubname", pub_name)) {
            std.log.info("Publication '{s}' already exists", .{pub_name});
            return;
        }

        const sql = std.fmt.allocPrintSentinel(self.allocator, "CREATE PUBLICATION {s} FOR ALL TABLES", .{pub_name}, 0) catch return ReplicationError.OutOfMemory;
        defer self.allocator.free(sql);

        std.log.info("Creating publication: {s}", .{pub_name});
        try self.execSimple(sql.ptr, "CREATE PUBLICATION");
        std.log.info("Publication '{s}' created successfully", .{pub_name});
    }

    /// Whether the snapshot marker publication exists, i.e. a prior initial snapshot
    /// was interrupted before it finished. See createSnapshotMarker.
    pub fn snapshotMarkerExists(self: *Self) ReplicationError!bool {
        if (self.connection == null) return ReplicationError.ConnectionFailed;
        const name = try self.markerName();
        defer self.allocator.free(name);
        return self.objectExists("pg_publication", "pubname", name);
    }

    /// Create the snapshot marker publication if absent (idempotent). It is an empty
    /// publication used only as a durable "snapshot in progress" flag: created before
    /// the slot at bootstrap and dropped once the snapshot is flushed, so its presence
    /// on startup means the snapshot did not finish. It is never passed to
    /// START_REPLICATION, so it takes no part in decoding.
    pub fn createSnapshotMarker(self: *Self) ReplicationError!void {
        if (self.connection == null) return ReplicationError.ConnectionFailed;
        const name = try self.markerName();
        defer self.allocator.free(name);

        if (try self.objectExists("pg_publication", "pubname", name)) return;

        const sql = std.fmt.allocPrintSentinel(self.allocator, "CREATE PUBLICATION {s}", .{name}, 0) catch return ReplicationError.OutOfMemory;
        defer self.allocator.free(sql);

        std.log.info("Creating snapshot marker: {s}", .{name});
        try self.execSimple(sql.ptr, "CREATE PUBLICATION (snapshot marker)");
    }

    /// Drop the snapshot marker publication if present (idempotent). Called once the
    /// snapshot is flushed, returning steady state to a single publication.
    pub fn dropSnapshotMarker(self: *Self) ReplicationError!void {
        if (self.connection == null) return ReplicationError.ConnectionFailed;
        const name = try self.markerName();
        defer self.allocator.free(name);

        const sql = std.fmt.allocPrintSentinel(self.allocator, "DROP PUBLICATION IF EXISTS {s}", .{name}, 0) catch return ReplicationError.OutOfMemory;
        defer self.allocator.free(sql);

        std.log.info("Dropping snapshot marker: {s}", .{name});
        try self.execSimple(sql.ptr, "DROP PUBLICATION (snapshot marker)");
    }

    /// Whether the replication slot already exists.
    pub fn slotExists(self: *Self) ReplicationError!bool {
        if (self.connection == null) return ReplicationError.ConnectionFailed;
        const slot_name = try self.lowerName(self.slot_name);
        defer self.allocator.free(slot_name);
        return self.objectExists("pg_replication_slots", "slot_name", slot_name);
    }

    /// Create the replication slot and capture its consistent point and exported
    /// snapshot. Assumes the slot does not exist (check slotExists first).
    pub fn createSlot(self: *Self) ReplicationError!void {
        if (self.connection == null) return ReplicationError.ConnectionFailed;

        const slot_name = try self.lowerName(self.slot_name);
        defer self.allocator.free(slot_name);

        // A re-create after dropSlot (interrupted snapshot) must not leak the values
        // captured for the discarded slot.
        if (self.consistent_point) |cp| {
            self.allocator.free(cp);
            self.consistent_point = null;
        }
        if (self.snapshot_name) |sn| {
            self.allocator.free(sn);
            self.snapshot_name = null;
        }

        const sql = std.fmt.allocPrintSentinel(self.allocator, "CREATE_REPLICATION_SLOT {s} LOGICAL pgoutput", .{slot_name}, 0) catch return ReplicationError.OutOfMemory;
        defer self.allocator.free(sql);

        std.log.info("Creating replication slot: {s}", .{slot_name});

        const result = c.PQexec(self.connection, sql.ptr);
        defer c.PQclear(result);
        if (c.PQresultStatus(result) != c.PGRES_TUPLES_OK) {
            std.log.warn("Failed to create replication slot: {s}", .{c.PQresultErrorMessage(result)});
            return ReplicationError.ConnectionFailed;
        }
        std.log.info("Replication slot '{s}' created successfully", .{slot_name});

        // CREATE_REPLICATION_SLOT returns one row: slot_name, consistent_point,
        // snapshot_name, output_plugin. Capture consistent_point (the slot's start
        // LSN) so streaming can begin exactly there. Best-effort: if it is ever
        // absent we leave it null and fall back to "0/0", which resolves to the same
        // freshly created position.
        const cp_col = c.PQfnumber(result, "consistent_point");
        if (cp_col >= 0 and c.PQntuples(result) > 0 and c.PQgetisnull(result, 0, cp_col) == 0) {
            const cp = std.mem.span(c.PQgetvalue(result, 0, cp_col));
            self.consistent_point = self.allocator.dupe(u8, cp) catch return ReplicationError.OutOfMemory;
            std.log.debug("Slot consistent point: {s}", .{self.consistent_point.?});
        } else {
            std.log.warn("CREATE_REPLICATION_SLOT returned no consistent_point; starting from 0/0", .{});
        }

        // snapshot_name from the same row: the exported snapshot the initial snapshot
        // reads under. Best-effort like consistent_point; without it the caller runs
        // no snapshot.
        const sn_col = c.PQfnumber(result, "snapshot_name");
        if (sn_col >= 0 and c.PQntuples(result) > 0 and c.PQgetisnull(result, 0, sn_col) == 0) {
            const sn = std.mem.span(c.PQgetvalue(result, 0, sn_col));
            self.snapshot_name = self.allocator.dupe(u8, sn) catch return ReplicationError.OutOfMemory;
            std.log.debug("Slot exported snapshot: {s}", .{self.snapshot_name.?});
        }
    }

    /// Drop the replication slot. Used to discard an orphaned slot left by an
    /// interrupted snapshot. Fails fast if the slot is still active (e.g. another
    /// reader), rather than waiting.
    pub fn dropSlot(self: *Self) ReplicationError!void {
        if (self.connection == null) return ReplicationError.ConnectionFailed;
        const slot_name = try self.lowerName(self.slot_name);
        defer self.allocator.free(slot_name);

        const sql = std.fmt.allocPrintSentinel(self.allocator, "DROP_REPLICATION_SLOT {s}", .{slot_name}, 0) catch return ReplicationError.OutOfMemory;
        defer self.allocator.free(sql);

        std.log.info("Dropping replication slot: {s}", .{slot_name});
        try self.execSimple(sql.ptr, "DROP_REPLICATION_SLOT");
    }

    // Postgres folds unquoted identifiers to lowercase. We fold slot and publication
    // names the same way so the existence check, CREATE, and START_REPLICATION all
    // reference one name; a mixed-case name would be created folded but never
    // re-found, so CREATE would fail "already exists" on every restart (a crash loop).
    fn lowerName(self: *Self, name: []const u8) ReplicationError![]u8 {
        return std.ascii.allocLowerString(self.allocator, name) catch return ReplicationError.OutOfMemory;
    }

    // The snapshot marker publication name, derived from the streaming publication.
    fn markerName(self: *Self) ReplicationError![]u8 {
        const pub_name = try self.lowerName(self.publication_name);
        defer self.allocator.free(pub_name);
        return std.fmt.allocPrint(self.allocator, "{s}_snapshotting", .{pub_name}) catch return ReplicationError.OutOfMemory;
    }

    // Existence probe: true if any row matches `column = 'name'` in `relation`.
    fn objectExists(self: *Self, relation: []const u8, column: []const u8, name: []const u8) ReplicationError!bool {
        const sql = std.fmt.allocPrintSentinel(self.allocator, "SELECT 1 FROM {s} WHERE {s} = '{s}'", .{ relation, column, name }, 0) catch return ReplicationError.OutOfMemory;
        defer self.allocator.free(sql);

        const result = c.PQexec(self.connection, sql.ptr);
        defer c.PQclear(result);
        if (c.PQresultStatus(result) != c.PGRES_TUPLES_OK) {
            std.log.warn("Existence check failed: {s}", .{c.PQresultErrorMessage(result)});
            return ReplicationError.ConnectionFailed;
        }
        return c.PQntuples(result) > 0;
    }

    // Run a command that returns no rows (CREATE/DROP), failing on a non-OK status.
    // Accepts TUPLES_OK too, since some replication commands report a result set.
    fn execSimple(self: *Self, sql: [*:0]const u8, ctx: []const u8) ReplicationError!void {
        const result = c.PQexec(self.connection, sql);
        defer c.PQclear(result);
        const status = c.PQresultStatus(result);
        if (status != c.PGRES_COMMAND_OK and status != c.PGRES_TUPLES_OK) {
            std.log.warn("{s} failed: {s}", .{ ctx, c.PQresultErrorMessage(result) });
            return ReplicationError.ConnectionFailed;
        }
    }

    pub fn startReplication(self: *Self, start_lsn: []const u8) ReplicationError!void {
        if (self.connection == null) return ReplicationError.ConnectionFailed;

        // Fold to lowercase like Postgres does for unquoted identifiers (see
        // createPublicationIfNotExists).
        const slot_name = try std.ascii.allocLowerString(self.allocator, self.slot_name);
        defer self.allocator.free(slot_name);
        const pub_name = try std.ascii.allocLowerString(self.allocator, self.publication_name);
        defer self.allocator.free(pub_name);

        // START_REPLICATION SLOT slot_name LOGICAL lsn (proto_version '1', publication_names 'pub_name')
        const sql_tmp = std.fmt.allocPrint(
            self.allocator,
            "START_REPLICATION SLOT {s} LOGICAL {s} (proto_version '1', publication_names '{s}')",
            .{ slot_name, start_lsn, pub_name },
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

    pub fn receiveMessage(self: *Self, io: std.Io, timeout_ms: i32) ReplicationError!?ReplicationMessage {
        if (self.connection == null) return ReplicationError.ConnectionFailed;

        // Step 1: Try non-blocking read first
        var buffer: [*c]u8 = undefined;
        var len = blk: {
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            break :blk c.PQgetCopyData(self.connection, &buffer, 1); // async=1 (non-blocking)
        };

        if (len == 0) {
            // Step 2: No data available - wait for socket to become readable
            const socket = c.PQsocket(self.connection);
            if (socket < 0) {
                std.log.warn("Invalid socket from PQsocket", .{});
                return ReplicationError.ConnectionFailed;
            }

            var pollfds = [_]std.posix.pollfd{
                .{
                    .fd = socket,
                    .events = std.posix.POLL.IN, // Wait for readable
                    .revents = 0,
                },
            };

            // Step 3: Block until data arrives or timeout
            const ready = std.posix.poll(&pollfds, timeout_ms) catch |err| {
                std.log.warn("poll() failed: {}", .{err});
                return ReplicationError.ReceiveFailed;
            };

            if (ready == 0) {
                // Timeout - no data
                return null;
            }

            // Step 4: Socket is readable - consume input
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            if (c.PQconsumeInput(self.connection) == 0) {
                const error_msg = c.PQerrorMessage(self.connection);
                std.log.warn("Failed to consume input: {s}", .{error_msg});
                return ReplicationError.ReceiveFailed;
            }

            // Step 5: Try to get data again after consuming input
            len = c.PQgetCopyData(self.connection, &buffer, 1);
        }

        // Step 6: Process received data
        if (len == -1) {
            // No more data (clean end of COPY stream)
            return null;
        }

        if (len == -2) {
            // PQerrorMessage reads connection state, so it needs the lock too.
            self.mutex.lockUncancelable(io);
            defer self.mutex.unlock(io);
            const error_msg = c.PQerrorMessage(self.connection);
            std.log.warn("Error reading copy data: {s}", .{error_msg});
            return ReplicationError.ReceiveFailed;
        }

        if (len <= 0) {
            // Unexpected: after poll() indicated data, we got nothing
            return null;
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

    pub fn sendStatusUpdate(self: *Self, io: std.Io, update: StandbyStatusUpdate) ReplicationError!void {
        if (self.connection == null) return ReplicationError.ConnectionFailed;

        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);

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
