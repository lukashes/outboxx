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
    table_name: []const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, slot_name: []const u8, publication_name: []const u8, table_name: []const u8) Self {
        return Self{
            .allocator = allocator,
            .connection = null,
            .slot_name = slot_name,
            .publication_name = publication_name,
            .table_name = table_name,
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

        std.log.info("Connecting to PostgreSQL: {s}", .{connection_string});

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

        std.log.info("Connected to PostgreSQL successfully", .{});
    }

    /// Initialize PostgreSQL connection, publication and replication slot
    pub fn initialize(self: *Self, connection_string: []const u8) WalReaderError!void {
        // Connect to PostgreSQL
        try self.connect(connection_string);

        // Create publication (will be idempotent - no error if exists)
        try self.createPublication();

        // Create replication slot (will be idempotent in the future)
        try self.createSlot();

        std.log.info("PostgreSQL WAL reader initialized successfully", .{});
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

    pub fn createPublication(self: *Self) WalReaderError!void {
        if (self.connection == null) return WalReaderError.ConnectionFailed;

        // Create SQL command for creating publication for specific table
        const sql = std.fmt.allocPrintSentinel(self.allocator, "CREATE PUBLICATION {s} FOR TABLE {s};", .{ self.publication_name, self.table_name }, 0) catch return WalReaderError.OutOfMemory;
        defer self.allocator.free(sql);

        std.log.info("Creating publication: {s}", .{self.publication_name});

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
