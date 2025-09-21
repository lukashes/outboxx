const std = @import("std");

pub const Config = struct {
    host: []const u8,
    port: u16,
    database: []const u8,
    user: []const u8,
    password: []const u8,
    slot_name: []const u8,

    pub fn default() Config {
        return Config{
            .host = "localhost",
            .port = 5432,
            .database = "outboxx_test",
            .user = "postgres",
            .password = "password",
            .slot_name = "outboxx_slot",
        };
    }

    pub fn connectionString(self: Config, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(
            allocator,
            "host=127.0.0.1 port={d} dbname={s} user={s} password={s} replication=database gssencmode=disable",
            .{ self.port, self.database, self.user, self.password }
        );
    }
};