const std = @import("std");
const c = @cImport({
    @cInclude("libpq-fe.h");
});

const print = std.debug.print;

pub const WalReaderError = error{
    ConnectionFailed,
    SlotCreationFailed,
    ReplicationFailed,
    OutOfMemory,
    InvalidData,
};

pub const WalEvent = struct {
    lsn: []const u8,
    data: []const u8,

    pub fn deinit(self: *WalEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.lsn);
        allocator.free(self.data);
    }
};

pub const WalReader = struct {
    allocator: std.mem.Allocator,
    connection: ?*c.PGconn,
    slot_name: []const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, slot_name: []const u8) Self {
        return Self{
            .allocator = allocator,
            .connection = null,
            .slot_name = slot_name,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.connection) |conn| {
            c.PQfinish(conn);
            self.connection = null;
        }
    }

    pub fn connect(self: *Self, connection_string: []const u8) WalReaderError!void {
        // Create null-terminated connection string for C
        const conn_str = self.allocator.dupeZ(u8, connection_string) catch return WalReaderError.OutOfMemory;
        defer self.allocator.free(conn_str);

        print("Connecting to PostgreSQL: {s}\n", .{connection_string});

        self.connection = c.PQconnectdb(conn_str.ptr);

        if (self.connection == null) {
            print("Failed to allocate connection\n", .{});
            return WalReaderError.ConnectionFailed;
        }

        const status = c.PQstatus(self.connection);
        if (status != c.CONNECTION_OK) {
            const error_msg = c.PQerrorMessage(self.connection);
            print("Connection failed: {s}\n", .{error_msg});
            c.PQfinish(self.connection);
            self.connection = null;
            return WalReaderError.ConnectionFailed;
        }

        print("Connected to PostgreSQL successfully\n", .{});
    }

    pub fn createSlot(self: *Self) WalReaderError!void {
        if (self.connection == null) return WalReaderError.ConnectionFailed;

        // Create SQL command for creating replication slot
        const sql = std.fmt.allocPrintSentinel(self.allocator, "SELECT pg_create_logical_replication_slot('{s}', 'test_decoding');", .{self.slot_name}, 0) catch return WalReaderError.OutOfMemory;
        defer self.allocator.free(sql);

        print("Creating replication slot: {s}\n", .{self.slot_name});

        const result = c.PQexec(self.connection, sql.ptr);
        defer c.PQclear(result);

        const status = c.PQresultStatus(result);
        if (status != c.PGRES_TUPLES_OK) {
            const error_msg = c.PQresultErrorMessage(result);
            print("Failed to create slot: {s}\n", .{error_msg});
            return WalReaderError.SlotCreationFailed;
        }

        print("Replication slot '{s}' created successfully\n", .{self.slot_name});
    }

    pub fn dropSlot(self: *Self) WalReaderError!void {
        if (self.connection == null) return WalReaderError.ConnectionFailed;

        const sql = std.fmt.allocPrintSentinel(self.allocator, "SELECT pg_drop_replication_slot('{s}');", .{self.slot_name}, 0) catch return WalReaderError.OutOfMemory;
        defer self.allocator.free(sql);

        print("Dropping replication slot: {s}\n", .{self.slot_name});

        const result = c.PQexec(self.connection, sql.ptr);
        defer c.PQclear(result);

        const status = c.PQresultStatus(result);
        if (status != c.PGRES_TUPLES_OK) {
            const error_msg = c.PQresultErrorMessage(result);
            print("Warning: Failed to drop slot: {s}\n", .{error_msg});
            // Don't return error - slot might not exist
        } else {
            print("Replication slot '{s}' dropped successfully\n", .{self.slot_name});
        }
    }

    pub fn readChanges(self: *Self, limit: u32) WalReaderError!std.ArrayList(WalEvent) {
        if (self.connection == null) return WalReaderError.ConnectionFailed;

        const sql = std.fmt.allocPrintSentinel(self.allocator, "SELECT lsn, xid, data FROM pg_logical_slot_get_changes('{s}', NULL, NULL) LIMIT {d};", .{ self.slot_name, limit }, 0) catch return WalReaderError.OutOfMemory;
        defer self.allocator.free(sql);

        print("Reading WAL changes from slot: {s}\n", .{self.slot_name});

        const result = c.PQexec(self.connection, sql.ptr);
        defer c.PQclear(result);

        const status = c.PQresultStatus(result);
        if (status != c.PGRES_TUPLES_OK) {
            const error_msg = c.PQresultErrorMessage(result);
            print("Failed to read changes: {s}\n", .{error_msg});
            return WalReaderError.ReplicationFailed;
        }

        const num_rows = c.PQntuples(result);
        print("Found {d} WAL changes\n", .{num_rows});

        var events = std.ArrayList(WalEvent){};

        var i: c_int = 0;
        while (i < num_rows) : (i += 1) {
            const lsn_cstr = c.PQgetvalue(result, i, 0);
            const data_cstr = c.PQgetvalue(result, i, 2); // Skip xid column

            if (lsn_cstr == null or data_cstr == null) continue;

            const lsn = self.allocator.dupe(u8, std.mem.span(lsn_cstr)) catch continue;
            const data = self.allocator.dupe(u8, std.mem.span(data_cstr)) catch {
                self.allocator.free(lsn);
                continue;
            };

            const event = WalEvent{
                .lsn = lsn,
                .data = data,
            };

            events.append(self.allocator, event) catch {
                self.allocator.free(lsn);
                self.allocator.free(data);
                continue;
            };
        }

        return events;
    }
};
