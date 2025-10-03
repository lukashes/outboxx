const std = @import("std");
const c = @cImport({
    @cInclude("libpq-fe.h");
});

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
    publication_name: []const u8,
    monitored_tables: std.StringHashMap(void), // Fast lookup for table filtering

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, slot_name: []const u8, publication_name: []const u8, tables: []const []const u8) Self {
        // Build monitored tables set for fast filtering
        var monitored_tables = std.StringHashMap(void).init(allocator);
        for (tables) |table| {
            // Ignore errors - worst case we skip filtering optimization
            monitored_tables.put(table, {}) catch {};
        }

        return Self{
            .allocator = allocator,
            .connection = null,
            .slot_name = slot_name,
            .publication_name = publication_name,
            .monitored_tables = monitored_tables,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.connection) |conn| {
            c.PQfinish(conn);
            self.connection = null;
        }
        self.monitored_tables.deinit();
    }

    pub fn connect(self: *Self, connection_string: []const u8) WalReaderError!void {
        // Create null-terminated connection string for C
        const conn_str = self.allocator.dupeZ(u8, connection_string) catch return WalReaderError.OutOfMemory;
        defer self.allocator.free(conn_str);

        std.log.debug("Connecting to PostgreSQL: {s}", .{connection_string});

        self.connection = c.PQconnectdb(conn_str.ptr);

        if (self.connection == null) {
            std.log.warn("Failed to allocate connection", .{});
            return WalReaderError.ConnectionFailed;
        }

        const status = c.PQstatus(self.connection);
        if (status != c.CONNECTION_OK) {
            const error_msg = c.PQerrorMessage(self.connection);
            std.log.warn("Connection failed: {s}", .{error_msg});
            c.PQfinish(self.connection);
            self.connection = null;
            return WalReaderError.ConnectionFailed;
        }

        std.log.debug("Connected to PostgreSQL successfully", .{});
    }

    /// Initialize PostgreSQL connection, publication and replication slot
    pub fn initialize(self: *Self, connection_string: []const u8, tables: []const []const u8) WalReaderError!void {
        // Connect to PostgreSQL
        try self.connect(connection_string);

        // Create publication (will be idempotent - no error if exists)
        try self.createPublication(tables);

        // Create replication slot (will be idempotent in the future)
        try self.createSlot();

        std.log.debug("PostgreSQL WAL reader initialized successfully", .{});
    }

    pub fn createSlot(self: *Self) WalReaderError!void {
        if (self.connection == null) return WalReaderError.ConnectionFailed;

        // Create SQL command for creating replication slot
        const sql = std.fmt.allocPrintSentinel(self.allocator, "SELECT pg_create_logical_replication_slot('{s}', 'test_decoding');", .{self.slot_name}, 0) catch return WalReaderError.OutOfMemory;
        defer self.allocator.free(sql);

        std.log.info("Creating replication slot: {s}", .{self.slot_name});

        const result = c.PQexec(self.connection, sql.ptr);
        defer c.PQclear(result);

        const status = c.PQresultStatus(result);
        if (status != c.PGRES_TUPLES_OK) {
            const error_msg = c.PQresultErrorMessage(result);
            const error_str = std.mem.span(@as([*:0]const u8, @ptrCast(error_msg)));

            // Check if slot already exists (this is expected and OK)
            if (std.mem.indexOf(u8, error_str, "already exists") != null) {
                std.log.info("Replication slot '{s}' already exists, continuing...", .{self.slot_name});
                return;
            }

            std.log.warn("Failed to create slot: {s}", .{error_msg});
            return WalReaderError.SlotCreationFailed;
        }

        std.log.info("Replication slot '{s}' created successfully", .{self.slot_name});
    }

    pub fn createPublication(self: *Self, tables: []const []const u8) WalReaderError!void {
        if (self.connection == null) return WalReaderError.ConnectionFailed;
        if (tables.len == 0) return WalReaderError.InvalidData;

        // Build table list: "table1, table2, table3"
        const tables_str = std.mem.join(self.allocator, ", ", tables) catch return WalReaderError.OutOfMemory;
        defer self.allocator.free(tables_str);

        // Create SQL command for creating publication for multiple tables
        const sql = std.fmt.allocPrintSentinel(self.allocator, "CREATE PUBLICATION {s} FOR TABLE {s};", .{ self.publication_name, tables_str }, 0) catch return WalReaderError.OutOfMemory;
        defer self.allocator.free(sql);

        std.log.info("Creating publication: {s} for tables: {s}", .{ self.publication_name, tables_str });

        const result = c.PQexec(self.connection, sql.ptr);
        defer c.PQclear(result);

        const status = c.PQresultStatus(result);
        if (status != c.PGRES_COMMAND_OK) {
            const error_msg = c.PQresultErrorMessage(result);
            const error_str = std.mem.span(@as([*:0]const u8, @ptrCast(error_msg)));

            // Check if publication already exists (this is expected and OK)
            if (std.mem.indexOf(u8, error_str, "already exists") != null) {
                std.log.info("Publication '{s}' already exists, continuing...", .{self.publication_name});
                return;
            }

            std.log.warn("Failed to create publication: {s}", .{error_msg});
            return WalReaderError.SlotCreationFailed;
        }

        std.log.info("Publication '{s}' created successfully", .{self.publication_name});
    }

    pub fn dropSlot(self: *Self) WalReaderError!void {
        if (self.connection == null) return WalReaderError.ConnectionFailed;

        const sql = std.fmt.allocPrintSentinel(self.allocator, "SELECT pg_drop_replication_slot('{s}');", .{self.slot_name}, 0) catch return WalReaderError.OutOfMemory;
        defer self.allocator.free(sql);

        std.log.info("Dropping replication slot: {s}", .{self.slot_name});

        const result = c.PQexec(self.connection, sql.ptr);
        defer c.PQclear(result);

        const status = c.PQresultStatus(result);
        if (status != c.PGRES_TUPLES_OK) {
            const error_msg = c.PQresultErrorMessage(result);
            std.log.warn("Failed to drop slot: {s}", .{error_msg});
            // Don't return error - slot might not exist
        } else {
            std.log.info("Replication slot '{s}' dropped successfully", .{self.slot_name});
        }
    }

    /// Fast, non-strict extraction of table name from test_decoding WAL message
    /// Returns null if cannot extract (caller should include event for safety)
    /// False positives are OK (include event), false negatives are NOT OK
    fn extractTableNameFromWal(wal_data: []const u8) ?[]const u8 {
        // Expected format: "table schema.tablename: OPERATION: ..."
        // Example: "table public.users: INSERT: id[integer]:1"

        if (wal_data.len < 7) return null; // "table " = 6 chars minimum
        if (!std.mem.startsWith(u8, wal_data, "table ")) return null;

        const table_start = 6; // "table ".len

        // Find first colon after "table "
        const colon_pos = std.mem.indexOfScalar(u8, wal_data[table_start..], ':') orelse return null;

        // Extract "schema.tablename"
        const full_table_name = wal_data[table_start .. table_start + colon_pos];

        // Find dot separator
        const dot_pos = std.mem.indexOfScalar(u8, full_table_name, '.') orelse {
            // No schema? Treat whole thing as table name (permissive approach)
            return full_table_name;
        };

        // Return table name part (after dot)
        return full_table_name[dot_pos + 1 ..];
    }

    pub fn peekChanges(self: *Self, limit: u32) WalReaderError!std.ArrayList(WalEvent) {
        if (self.connection == null) return WalReaderError.ConnectionFailed;

        const sql = std.fmt.allocPrintSentinel(self.allocator, "SELECT lsn, xid, data FROM pg_logical_slot_peek_changes('{s}', NULL, NULL) LIMIT {d};", .{ self.slot_name, limit }, 0) catch return WalReaderError.OutOfMemory;
        defer self.allocator.free(sql);

        const result = c.PQexec(self.connection, sql.ptr);
        defer c.PQclear(result);

        const status = c.PQresultStatus(result);
        if (status != c.PGRES_TUPLES_OK) {
            const error_msg = c.PQresultErrorMessage(result);
            std.log.warn("Failed to peek changes: {s}", .{error_msg});
            return WalReaderError.ReplicationFailed;
        }

        const num_rows = c.PQntuples(result);

        var events = std.ArrayList(WalEvent){};

        var i: c_int = 0;
        while (i < num_rows) : (i += 1) {
            const lsn_cstr = c.PQgetvalue(result, i, 0);
            const data_cstr = c.PQgetvalue(result, i, 2);

            if (lsn_cstr == null or data_cstr == null) continue;

            const lsn = self.allocator.dupe(u8, std.mem.span(lsn_cstr)) catch continue;
            const data = self.allocator.dupe(u8, std.mem.span(data_cstr)) catch {
                self.allocator.free(lsn);
                continue;
            };

            // Fast filter: skip events for tables we don't monitor
            // test_decoding sends ALL tables, so we filter here
            if (extractTableNameFromWal(data)) |table_name| {
                if (!self.monitored_tables.contains(table_name)) {
                    // Not in monitored set - skip this event
                    std.log.debug("Fast filter: skipping table '{s}'", .{table_name});
                    self.allocator.free(lsn);
                    self.allocator.free(data);
                    continue;
                }
            }
            // If extraction failed (null), include event (permissive approach)

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

    pub fn advanceSlot(self: *Self, target_lsn: []const u8) WalReaderError!void {
        if (self.connection == null) return WalReaderError.ConnectionFailed;

        const sql = std.fmt.allocPrintSentinel(self.allocator, "SELECT pg_replication_slot_advance('{s}', '{s}');", .{ self.slot_name, target_lsn }, 0) catch return WalReaderError.OutOfMemory;
        defer self.allocator.free(sql);

        const result = c.PQexec(self.connection, sql.ptr);
        defer c.PQclear(result);

        const status = c.PQresultStatus(result);
        if (status != c.PGRES_TUPLES_OK) {
            const error_msg = c.PQresultErrorMessage(result);
            std.log.warn("Failed to advance slot to LSN {s}: {s}", .{ target_lsn, error_msg });
            return WalReaderError.ReplicationFailed;
        }

        std.log.debug("Advanced replication slot '{s}' to LSN: {s}", .{ self.slot_name, target_lsn });
    }
};

// Unit tests for private functions
const testing = std.testing;

test "extractTableNameFromWal: valid table with schema" {
    const wal_msg = "table public.users: INSERT: id[integer]:1 name[text]:'alice'";
    const result = WalReader.extractTableNameFromWal(wal_msg);
    try testing.expect(result != null);
    try testing.expectEqualStrings("users", result.?);
}

test "extractTableNameFromWal: valid table with different schema" {
    const wal_msg = "table myschema.orders: UPDATE: id[integer]:42";
    const result = WalReader.extractTableNameFromWal(wal_msg);
    try testing.expect(result != null);
    try testing.expectEqualStrings("orders", result.?);
}

test "extractTableNameFromWal: table without schema" {
    const wal_msg = "table users: DELETE: id[integer]:5";
    const result = WalReader.extractTableNameFromWal(wal_msg);
    try testing.expect(result != null);
    try testing.expectEqualStrings("users", result.?);
}

test "extractTableNameFromWal: invalid - doesn't start with 'table '" {
    const wal_msg = "BEGIN 12345";
    const result = WalReader.extractTableNameFromWal(wal_msg);
    try testing.expect(result == null);
}

test "extractTableNameFromWal: invalid - too short" {
    const wal_msg = "table";
    const result = WalReader.extractTableNameFromWal(wal_msg);
    try testing.expect(result == null);
}

test "extractTableNameFromWal: invalid - no colon" {
    const wal_msg = "table public.users";
    const result = WalReader.extractTableNameFromWal(wal_msg);
    try testing.expect(result == null);
}

test "extractTableNameFromWal: COMMIT message" {
    const wal_msg = "COMMIT 12345";
    const result = WalReader.extractTableNameFromWal(wal_msg);
    try testing.expect(result == null);
}

test "extractTableNameFromWal: table name with underscores" {
    const wal_msg = "table public.user_profiles: INSERT: user_id[integer]:1";
    const result = WalReader.extractTableNameFromWal(wal_msg);
    try testing.expect(result != null);
    try testing.expectEqualStrings("user_profiles", result.?);
}

test "extractTableNameFromWal: empty after 'table '" {
    const wal_msg = "table :";
    const result = WalReader.extractTableNameFromWal(wal_msg);
    try testing.expect(result != null);
    try testing.expectEqualStrings("", result.?); // Edge case - returns empty string
}
