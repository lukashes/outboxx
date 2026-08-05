const std = @import("std");
const c = @import("c"); // C bindings (build-system translate-c)

const domain = @import("../../domain/change_event.zig");
const ChangeEvent = domain.ChangeEvent;
const ChangeOperation = domain.ChangeOperation;
const FieldValue = domain.FieldValue;
const RowDataHelpers = domain.RowDataHelpers;
const FieldValueHelpers = domain.FieldValueHelpers;

const converter = @import("converter.zig");
const mapValue = converter.mapValue;

pub const SnapshotError = error{
    ConnectionFailed,
    QueryFailed,
    OutOfMemory,
};

// One cursor is open at a time, so a fixed name is enough.
const cursor_name = "outboxx_snapshot_cursor";

/// Reads a table's existing rows as of an exported snapshot and emits them as READ
/// events, so a consumer can bootstrap current state before the stream begins (#49).
///
/// Runs on a regular (non-replication) connection. The caller opens a cursor per
/// resource and pulls batches with `fetch` until it returns null; the events live in
/// the batch allocator, so a large table is bounded by fetching in chunks and freeing
/// each batch.
pub const SnapshotReader = struct {
    allocator: std.mem.Allocator,
    // Snapshot exported by CREATE_REPLICATION_SLOT. Reading under it sees the database
    // exactly at the slot's start; the session that exported it must stay open until
    // `connect` binds this transaction to it.
    snapshot_name: []const u8,
    // The slot's consistent point (pg_lsn text form), stamped as meta.lsn on every READ
    // row so a snapshot row and the first stream change share the same dedup boundary.
    lsn: []const u8,
    // Wall-clock start of the snapshot, stamped as meta.timestamp on every READ row.
    timestamp: i64,
    connection: ?*c.PGconn = null,
    // Resource of the open cursor; borrowed for the openCursor..closeCursor span and
    // duped into each event's metadata.
    resource: ?[]const u8 = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, snapshot_name: []const u8, lsn: []const u8, timestamp: i64) Self {
        return .{
            .allocator = allocator,
            .snapshot_name = snapshot_name,
            .lsn = lsn,
            .timestamp = timestamp,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.connection) |conn| {
            // Read-only snapshot transaction: nothing to persist, so end it best-effort.
            _ = c.PQexec(conn, "COMMIT");
            c.PQfinish(conn);
            self.connection = null;
        }
        self.resource = null;
    }

    /// Connect and enter the snapshot transaction. Must run while the session that
    /// exported `snapshot_name` is still open, or SET TRANSACTION SNAPSHOT fails.
    pub fn connect(self: *Self, connection_string: []const u8) SnapshotError!void {
        const conn_str = self.allocator.dupeZ(u8, connection_string) catch return error.OutOfMemory;
        defer self.allocator.free(conn_str);

        const conn = c.PQconnectdb(conn_str.ptr);
        if (conn == null) {
            std.log.warn("Snapshot: failed to allocate connection", .{});
            return error.ConnectionFailed;
        }
        if (c.PQstatus(conn) != c.CONNECTION_OK) {
            std.log.warn("Snapshot: connection failed: {s}", .{c.PQerrorMessage(conn)});
            c.PQfinish(conn);
            return error.ConnectionFailed;
        }
        self.connection = conn;
        errdefer self.deinit();

        // REPEATABLE READ plus SET TRANSACTION SNAPSHOT bind this read to the exact
        // snapshot exported at slot creation, so it sees the database as of the slot's
        // start LSN. SET must be the first statement of the transaction.
        try self.execCommand("BEGIN ISOLATION LEVEL REPEATABLE READ");

        const set_snapshot = std.fmt.allocPrintSentinel(self.allocator, "SET TRANSACTION SNAPSHOT '{s}'", .{self.snapshot_name}, 0) catch return error.OutOfMemory;
        defer self.allocator.free(set_snapshot);
        try self.execCommand(set_snapshot.ptr);
    }

    /// Open a cursor over one resource. `resource` is borrowed until closeCursor.
    pub fn openCursor(self: *Self, resource: []const u8) SnapshotError!void {
        // resource is the operator-controlled, config-validated schema.table (the same
        // trust as validator.zig's to_regclass interpolation). DECLARE needs a real
        // identifier, not a string literal, so it goes straight into the FROM clause.
        const sql = std.fmt.allocPrintSentinel(self.allocator, "DECLARE " ++ cursor_name ++ " CURSOR FOR SELECT * FROM {s}", .{resource}, 0) catch return error.OutOfMemory;
        defer self.allocator.free(sql);

        try self.execCommand(sql.ptr);
        self.resource = resource;
    }

    pub fn closeCursor(self: *Self) SnapshotError!void {
        try self.execCommand("CLOSE " ++ cursor_name);
        self.resource = null;
    }

    /// Fetch up to `limit` more rows from the open cursor as READ events allocated in
    /// `batch_allocator`; returns null once the cursor is exhausted. The caller owns the
    /// batch and frees `batch_allocator` before the next fetch.
    pub fn fetch(self: *Self, batch_allocator: std.mem.Allocator, limit: usize) SnapshotError!?[]ChangeEvent {
        const conn = self.connection orelse return error.ConnectionFailed;
        const resource = self.resource orelse return error.QueryFailed;

        const sql = std.fmt.allocPrintSentinel(self.allocator, "FETCH FORWARD {d} FROM " ++ cursor_name, .{limit}, 0) catch return error.OutOfMemory;
        defer self.allocator.free(sql);

        const result = c.PQexec(conn, sql.ptr) orelse return error.OutOfMemory;
        defer c.PQclear(result);
        if (c.PQresultStatus(result) != c.PGRES_TUPLES_OK) {
            std.log.warn("Snapshot fetch failed: {s}", .{c.PQresultErrorMessage(result)});
            return error.QueryFailed;
        }

        const n_rows: usize = @intCast(c.PQntuples(result));
        if (n_rows == 0) return null; // cursor drained

        const n_cols: usize = @intCast(c.PQnfields(result));

        const events = batch_allocator.alloc(ChangeEvent, n_rows) catch return error.OutOfMemory;
        for (0..n_rows) |row| {
            events[row] = try self.buildEvent(batch_allocator, result, resource, row, n_cols);
        }
        return events;
    }

    // Build one READ event from a result row. Columns come back in text format, the
    // same shape mapValue promotes for streamed changes, so a READ row and an INSERT
    // of the same row serialize identically.
    fn buildEvent(self: *Self, batch_allocator: std.mem.Allocator, result: *c.PGresult, resource: []const u8, row: usize, n_cols: usize) SnapshotError!ChangeEvent {
        const row_c: c_int = @intCast(row);

        // Arena-backed batch: the caller frees the whole batch at once, so no
        // per-field cleanup on the error path here.
        var builder = RowDataHelpers.createBuilder(batch_allocator);
        for (0..n_cols) |col| {
            const col_c: c_int = @intCast(col);
            const name = std.mem.span(c.PQfname(result, col_c));

            const value: FieldValue = if (c.PQgetisnull(result, row_c, col_c) != 0)
                FieldValueHelpers.null_value()
            else blk: {
                const oid: u32 = @intCast(c.PQftype(result, col_c));
                const text = std.mem.span(c.PQgetvalue(result, row_c, col_c));
                break :blk try mapValue(batch_allocator, oid, text);
            };

            try RowDataHelpers.put(&builder, batch_allocator, name, value);
        }
        const row_data = try RowDataHelpers.finalize(&builder, batch_allocator);

        var event = ChangeEvent.init(ChangeOperation.READ, .{
            .source = try batch_allocator.dupe(u8, "postgres"),
            .resource = try batch_allocator.dupe(u8, resource),
            .timestamp = self.timestamp,
            .lsn = try batch_allocator.dupe(u8, self.lsn),
        });
        event.setInsertData(row_data);
        return event;
    }

    // Run a command (or a query whose rows we ignore), failing on a non-OK status.
    fn execCommand(self: *Self, sql: [*:0]const u8) SnapshotError!void {
        const conn = self.connection orelse return error.ConnectionFailed;

        const result = c.PQexec(conn, sql) orelse return error.OutOfMemory;
        defer c.PQclear(result);

        const status = c.PQresultStatus(result);
        if (status != c.PGRES_COMMAND_OK and status != c.PGRES_TUPLES_OK) {
            std.log.warn("Snapshot command failed: {s}", .{c.PQresultErrorMessage(result)});
            return error.QueryFailed;
        }
    }
};
