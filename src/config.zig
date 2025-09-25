const std = @import("std");

pub const KafkaConfig = struct {
    brokers: []const u8,
    flush_timeout_ms: i32,
    poll_interval_ms: u64,

    pub fn default() KafkaConfig {
        return KafkaConfig{
            .brokers = "localhost:9092",
            .flush_timeout_ms = 5000,
            .poll_interval_ms = 3000,
        };
    }
};

pub const Config = struct {
    host: []const u8,
    port: u16,
    database: []const u8,
    user: []const u8,
    password: []const u8,
    slot_name: []const u8,
    kafka: KafkaConfig,

    pub fn default() Config {
        return Config{
            .host = "localhost",
            .port = 5432,
            .database = "outboxx_test",
            .user = "postgres",
            .password = "password", // Default test password - should be overridden in production
            .slot_name = "outboxx_slot",
            .kafka = KafkaConfig.default(),
        };
    }

    pub fn connectionString(self: Config, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "host=127.0.0.1 port={d} dbname={s} user={s} password={s} replication=database gssencmode=disable", .{ self.port, self.database, self.user, self.password });
    }
};
