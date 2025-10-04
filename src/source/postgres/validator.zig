const std = @import("std");
const c = @cImport({
    @cInclude("libpq-fe.h");
});

pub const ValidationError = error{
    ConnectionFailed,
    InvalidPostgresVersion,
    InvalidWalLevel,
    SlotNotFound,
    TableNotFound,
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
        std.log.info("PostgreSQL validation: Connection established", .{});
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
        if (version_num < 100000) {
            std.log.warn("PostgreSQL validation: Version {s} (code: {d}) is too old", .{ version_str, version_num });
            std.log.warn("Fix: PostgreSQL 10+ is required for logical replication", .{});
            return ValidationError.InvalidPostgresVersion;
        }

        std.log.info("PostgreSQL validation: Version {s} ✓", .{version_str});
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

        std.log.info("PostgreSQL validation: wal_level = '{s}' ✓", .{wal_level_str});
    }

    pub fn checkTableExists(self: *Self, schema: []const u8, table_name: []const u8) ValidationError!void {
        const query = std.fmt.allocPrintSentinel(self.allocator, "SELECT EXISTS (SELECT FROM information_schema.tables WHERE table_schema = '{s}' AND table_name = '{s}');", .{ schema, table_name }, 0) catch return ValidationError.OutOfMemory;
        defer self.allocator.free(query);

        const result = try self.executeQuery(query.ptr);
        defer c.PQclear(result);

        const exists = c.PQgetvalue(result, 0, 0);
        const exists_str = std.mem.span(exists);

        if (!std.mem.eql(u8, exists_str, "t")) {
            std.log.warn("PostgreSQL validation: Table '{s}.{s}' does not exist", .{ schema, table_name });
            std.log.warn("Fix: Create the table or check the table name in configuration", .{});
            return ValidationError.TableNotFound;
        }

        std.log.info("PostgreSQL validation: Table '{s}.{s}' exists ✓", .{ schema, table_name });
    }

    pub fn validateAll(self: *Self, tables: []const struct { schema: []const u8, name: []const u8 }) ValidationError!void {
        std.log.info("=== PostgreSQL Validation ===", .{});

        try self.checkPostgresVersion();
        try self.checkWalLevel();

        for (tables) |table| {
            try self.checkTableExists(table.schema, table.name);
        }

        std.log.info("PostgreSQL validation: All checks passed ✓", .{});
    }
};
