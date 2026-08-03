const std = @import("std");
const print = std.debug.print;
const c = @import("c"); // C bindings (build-system translate-c)

pub const ValidationError = error{
    ConnectionFailed,
    InvalidPostgresVersion,
    InvalidWalLevel,
    SlotNotFound,
    TableNotFound,
    ColumnNotFound,
    InvalidReplicaIdentity,
    QueryFailed,
    OutOfMemory,
};

pub const PostgresValidator = struct {
    allocator: std.mem.Allocator,
    connection: ?*c.PGconn,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return Self{
            .allocator = allocator,
            .connection = null,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.connection) |conn| {
            c.PQfinish(conn);
            self.connection = null;
        }
    }

    pub fn connect(self: *Self, connection_string: []const u8) ValidationError!void {
        const conn_str = self.allocator.dupeZ(u8, connection_string) catch return ValidationError.OutOfMemory;
        defer self.allocator.free(conn_str);

        const conn = c.PQconnectdb(conn_str.ptr);

        if (conn == null) {
            std.log.warn("PostgreSQL validation: Failed to allocate connection", .{});
            return ValidationError.ConnectionFailed;
        }

        const status = c.PQstatus(conn);
        if (status != c.CONNECTION_OK) {
            const error_msg = c.PQerrorMessage(conn);
            std.log.warn("PostgreSQL validation: Connection failed - {s}", .{error_msg});
            c.PQfinish(conn);
            return ValidationError.ConnectionFailed;
        }

        self.connection = conn;
        print("PostgreSQL validation: Connection established\n", .{});
    }

    fn executeQuery(self: *Self, query: [*:0]const u8) ValidationError!*c.PGresult {
        const conn = self.connection orelse return ValidationError.ConnectionFailed;

        const result = c.PQexec(conn, query) orelse return ValidationError.QueryFailed;

        const status = c.PQresultStatus(result);
        if (status != c.PGRES_TUPLES_OK and status != c.PGRES_COMMAND_OK) {
            const error_msg = c.PQerrorMessage(conn);
            std.log.warn("Query failed: {s}", .{error_msg});
            c.PQclear(result);
            return ValidationError.QueryFailed;
        }

        return result;
    }

    pub fn checkPostgresVersion(self: *Self) ValidationError!void {
        const conn = self.connection orelse return ValidationError.ConnectionFailed;

        const result = try self.executeQuery("SHOW server_version;");
        defer c.PQclear(result);

        const version = c.PQgetvalue(result, 0, 0);
        const version_str = std.mem.span(version);

        const version_num = c.PQserverVersion(conn);
        if (version_num < 120000) {
            std.log.warn("PostgreSQL validation: Version {s} (code: {d}) is too old", .{ version_str, version_num });
            std.log.warn("Fix: PostgreSQL 12+ is required for logical replication", .{});
            return ValidationError.InvalidPostgresVersion;
        }

        print("PostgreSQL validation: Version {s} ✓\n", .{version_str});
    }

    pub fn checkWalLevel(self: *Self) ValidationError!void {
        const result = try self.executeQuery("SHOW wal_level;");
        defer c.PQclear(result);

        const wal_level = c.PQgetvalue(result, 0, 0);
        const wal_level_str = std.mem.span(wal_level);

        if (!std.mem.eql(u8, wal_level_str, "logical")) {
            std.log.warn("PostgreSQL validation: wal_level is '{s}', but 'logical' is required for CDC", .{wal_level_str});
            std.log.warn("Fix: Set wal_level = logical in postgresql.conf and restart PostgreSQL", .{});
            return ValidationError.InvalidWalLevel;
        }

        print("PostgreSQL validation: wal_level = '{s}' ✓\n", .{wal_level_str});
    }

    pub fn checkTableExists(self: *Self, resource: []const u8) ValidationError!void {
        // to_regclass resolves the whole `schema.table` name (a bare name via
        // search_path) and returns NULL when it does not exist, so the resource
        // stays one opaque string here.
        const query = std.fmt.allocPrintSentinel(self.allocator, "SELECT to_regclass('{s}') IS NOT NULL;", .{resource}, 0) catch return ValidationError.OutOfMemory;
        defer self.allocator.free(query);

        const result = try self.executeQuery(query.ptr);
        defer c.PQclear(result);

        const exists = std.mem.span(c.PQgetvalue(result, 0, 0));
        if (!std.mem.eql(u8, exists, "t")) {
            std.log.warn("PostgreSQL validation: Table '{s}' does not exist", .{resource});
            std.log.warn("Fix: create the table or check the resource name in configuration", .{});
            return ValidationError.TableNotFound;
        }

        print("PostgreSQL validation: Table '{s}' exists ✓\n", .{resource});
    }

    /// Check that a column exists on a table. Used for the stream's routing key:
    /// a typo (or the default `id` on a table without one) would otherwise route
    /// every change to the same partition, unnoticed.
    pub fn checkColumnExists(self: *Self, resource: []const u8, column_name: []const u8) ValidationError!void {
        const query = std.fmt.allocPrintSentinel(self.allocator, "SELECT EXISTS (SELECT FROM pg_attribute WHERE attrelid = to_regclass('{s}') AND attname = '{s}' AND attnum > 0 AND NOT attisdropped);", .{ resource, column_name }, 0) catch return ValidationError.OutOfMemory;
        defer self.allocator.free(query);

        const result = try self.executeQuery(query.ptr);
        defer c.PQclear(result);

        const exists = std.mem.span(c.PQgetvalue(result, 0, 0));
        if (!std.mem.eql(u8, exists, "t")) {
            std.log.warn("PostgreSQL validation: Column '{s}' does not exist on table '{s}'", .{ column_name, resource });
            std.log.warn("Fix: set stream.sink.routing_key to an existing column", .{});
            return ValidationError.ColumnNotFound;
        }

        print("PostgreSQL validation: Column '{s}.{s}' exists ✓\n", .{ resource, column_name });
    }

    /// Require REPLICA IDENTITY FULL on a table whose stream tracks DELETE, so the
    /// deleted row carries all columns. Any other identity (default/index/nothing)
    /// drops the non-key columns from the DELETE old row, breaking the documented
    /// format. Call only for delete-tracking streams: FULL is irrelevant otherwise
    /// and only inflates UPDATE WAL.
    pub fn checkReplicaIdentity(self: *Self, resource: []const u8) ValidationError!void {
        const query = try std.fmt.allocPrintSentinel(self.allocator, "SELECT relreplident FROM pg_class WHERE oid = to_regclass('{s}');", .{resource}, 0);
        defer self.allocator.free(query);

        const result = try self.executeQuery(query.ptr);
        defer c.PQclear(result);

        // checkTableExists runs first, so an empty result only happens on a race
        // (the table was dropped between the two queries).
        if (c.PQntuples(result) == 0) {
            std.log.warn("PostgreSQL validation: Table '{s}' not found while checking replica identity", .{resource});
            return ValidationError.TableNotFound;
        }

        const identity = std.mem.span(c.PQgetvalue(result, 0, 0));

        if (identity.len == 0 or identity[0] != 'f') {
            std.log.warn("PostgreSQL validation: Table '{s}' has REPLICA IDENTITY {s}, but this stream tracks DELETE and needs the full old row", .{ resource, replicaIdentityName(identity) });
            std.log.warn("Fix: ALTER TABLE {s} REPLICA IDENTITY FULL", .{resource});
            return ValidationError.InvalidReplicaIdentity;
        }

        print("PostgreSQL validation: Table '{s}' REPLICA IDENTITY FULL ✓\n", .{resource});
    }
};

// Human-readable name for a pg_class.relreplident value, for the error message.
fn replicaIdentityName(identity: []const u8) []const u8 {
    if (identity.len == 0) return "unknown";
    return switch (identity[0]) {
        'd' => "default (primary key only)",
        'i' => "index",
        'n' => "nothing",
        'f' => "full",
        else => "unknown",
    };
}
