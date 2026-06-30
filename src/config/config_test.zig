const std = @import("std");
const testing = std.testing;

const config = @import("config.zig");
const Config = config.Config;

// Valid config built from static data. No allocations, so nothing to free.
fn createTestDefault() Config {
    return .{
        .metadata = .{ .version = "v0" },
        .source = .{
            .type = "postgres",
            .postgres = .{
                .host = "localhost",
                .port = 5432,
                .database = "outboxx_test",
                .user = "postgres",
                .password_env = "POSTGRES_PASSWORD",
                .slot_name = "outboxx_slot",
                .publication_name = "outboxx_publication",
            },
        },
        .sink = .{
            .type = "kafka",
            .kafka = .{ .brokers = &.{"localhost:9092"} },
        },
        .streams = &.{
            .{
                .name = "test_stream",
                .source = .{ .resource = "users", .operations = &.{"insert"} },
                .flow = .{ .format = "json" },
                .sink = .{ .destination = "test_topic", .routing_key = null },
            },
        },
    };
}

// Complete, valid configuration used by parsing tests.
const valid_config_toml =
    \\[metadata]
    \\version = "v0"
    \\
    \\[source]
    \\type = "postgres"
    \\
    \\[source.postgres]
    \\host = "pg.example.com"
    \\port = 5433
    \\database = "production_db"
    \\user = "app_user"
    \\password_env = "PROD_PASSWORD"
    \\slot_name = "prod_slot"
    \\publication_name = "prod_pub"
    \\
    \\[sink]
    \\type = "kafka"
    \\
    \\[sink.kafka]
    \\brokers = ["kafka1:9092"]
    \\
    \\[[streams]]
    \\name = "users-stream"
    \\
    \\[streams.source]
    \\resource = "users"
    \\operations = ["insert", "update"]
    \\
    \\[streams.flow]
    \\format = "json"
    \\
    \\[streams.sink]
    \\destination = "outboxx.users"
    \\routing_key = "id"
;

test "createTestDefault" {
    const cfg = createTestDefault();

    try testing.expect(cfg.source.postgres != null);
    const postgres = cfg.source.postgres.?;
    try testing.expectEqualStrings("localhost", postgres.host);
    try testing.expect(postgres.port == 5432);
    try testing.expectEqualStrings("outboxx_test", postgres.database);

    try testing.expect(cfg.sink.kafka != null);
    try testing.expect(cfg.sink.kafka.?.brokers.len == 1);
    try testing.expectEqualStrings("localhost:9092", cfg.sink.kafka.?.brokers[0]);
}

// TOML parsing tests
test "loadFromTomlFile - missing file fails fast" {
    const result = Config.loadFromTomlFile(testing.io, testing.allocator, "dummy_path");
    try testing.expectError(error.FileNotFound, result);
}

test "loadFromTomlFile - real file" {
    const allocator = testing.allocator;
    const io = testing.io;

    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "test_config.toml", .data = valid_config_toml });
    defer std.Io.Dir.cwd().deleteFile(io, "test_config.toml") catch {};

    var parsed = try Config.loadFromTomlFile(io, allocator, "test_config.toml");
    defer parsed.deinit();
    const cfg = parsed.value;

    try testing.expectEqualStrings("v0", cfg.metadata.version);
    try testing.expect(cfg.source.postgres != null);
    const postgres = cfg.source.postgres.?;
    try testing.expectEqualStrings("pg.example.com", postgres.host);
    try testing.expect(postgres.port == 5433);
    try testing.expectEqualStrings("production_db", postgres.database);
}

test "loadFromTomlString - empty document fails" {
    try testing.expectError(error.MissingRequiredField, Config.loadFromTomlString(testing.allocator, ""));
}

test "parse PostgreSQL config section" {
    var parsed = try Config.loadFromTomlString(testing.allocator, valid_config_toml);
    defer parsed.deinit();
    const cfg = parsed.value;

    try testing.expect(cfg.source.postgres != null);
    const postgres = cfg.source.postgres.?;
    try testing.expectEqualStrings("pg.example.com", postgres.host);
    try testing.expect(postgres.port == 5433);
    try testing.expectEqualStrings("production_db", postgres.database);
    try testing.expectEqualStrings("app_user", postgres.user);
    try testing.expectEqualStrings("PROD_PASSWORD", postgres.password_env);
    try testing.expectEqualStrings("prod_slot", postgres.slot_name);
    try testing.expectEqualStrings("prod_pub", postgres.publication_name);
}

test "parse Kafka config section with multiple brokers" {
    const toml_content =
        \\[metadata]
        \\version = "v0"
        \\
        \\[source]
        \\type = "postgres"
        \\
        \\[source.postgres]
        \\host = "localhost"
        \\port = 5432
        \\database = "db"
        \\user = "user"
        \\password_env = "PWD"
        \\slot_name = "slot"
        \\publication_name = "pub"
        \\
        \\[sink]
        \\type = "kafka"
        \\
        \\[sink.kafka]
        \\brokers = ["kafka1:9092", "kafka2:9092", "kafka3:9092"]
    ;

    var parsed = try Config.loadFromTomlString(testing.allocator, toml_content);
    defer parsed.deinit();
    const cfg = parsed.value;

    try testing.expect(cfg.sink.kafka != null);
    const kafka = cfg.sink.kafka.?;
    try testing.expect(kafka.brokers.len == 3);
    try testing.expectEqualStrings("kafka1:9092", kafka.brokers[0]);
    try testing.expectEqualStrings("kafka2:9092", kafka.brokers[1]);
    try testing.expectEqualStrings("kafka3:9092", kafka.brokers[2]);
}

test "parse integer values" {
    var parsed = try Config.loadFromTomlString(testing.allocator, valid_config_toml);
    defer parsed.deinit();

    try testing.expect(parsed.value.source.postgres.?.port == 5433);
}

test "parse stream with inline comments and optional routing_key" {
    var parsed = try Config.loadFromTomlString(testing.allocator, valid_config_toml);
    defer parsed.deinit();
    const cfg = parsed.value;

    try testing.expect(cfg.streams.len == 1);
    const stream = cfg.streams[0];
    try testing.expectEqualStrings("users-stream", stream.name);
    try testing.expectEqualStrings("users", stream.source.resource);
    try testing.expect(stream.source.operations.len == 2);
    try testing.expectEqualStrings("insert", stream.source.operations[0]);
    try testing.expectEqualStrings("update", stream.source.operations[1]);
    try testing.expectEqualStrings("json", stream.flow.format);
    try testing.expectEqualStrings("outboxx.users", stream.sink.destination);
    try testing.expectEqualStrings("id", stream.sink.routing_key.?);
}

test "parse multiple streams" {
    const toml_content =
        \\[metadata]
        \\version = "v0"
        \\
        \\[source]
        \\type = "postgres"
        \\
        \\[source.postgres]
        \\host = "localhost"
        \\port = 5432
        \\database = "db"
        \\user = "user"
        \\password_env = "PWD"
        \\slot_name = "slot"
        \\publication_name = "pub"
        \\
        \\[sink]
        \\type = "kafka"
        \\
        \\[sink.kafka]
        \\brokers = ["kafka1:9092"]
        \\
        \\# First stream for users
        \\[[streams]]
        \\name = "users-stream"
        \\
        \\[streams.source]
        \\resource = "users" # Table name
        \\operations = ["insert", "update"] # Supported operations
        \\
        \\[streams.flow]
        \\format = "json"
        \\
        \\[streams.sink]
        \\destination = "outboxx.users"
        \\routing_key = "id"
        \\
        \\# Second stream for orders
        \\[[streams]]
        \\name = "orders-stream"
        \\
        \\[streams.source]
        \\resource = "orders"
        \\operations = ["insert", "update", "delete"]
        \\
        \\[streams.flow]
        \\format = "json"
        \\
        \\[streams.sink]
        \\destination = "outboxx.orders"
        \\routing_key = "order_id"
    ;

    var parsed = try Config.loadFromTomlString(testing.allocator, toml_content);
    defer parsed.deinit();
    const cfg = parsed.value;

    try testing.expect(cfg.streams.len == 2);

    const stream1 = cfg.streams[0];
    try testing.expectEqualStrings("users-stream", stream1.name);
    try testing.expectEqualStrings("users", stream1.source.resource);
    try testing.expect(stream1.source.operations.len == 2);
    try testing.expectEqualStrings("json", stream1.flow.format);
    try testing.expectEqualStrings("outboxx.users", stream1.sink.destination);
    try testing.expectEqualStrings("id", stream1.sink.routing_key.?);

    const stream2 = cfg.streams[1];
    try testing.expectEqualStrings("orders-stream", stream2.name);
    try testing.expectEqualStrings("orders", stream2.source.resource);
    try testing.expect(stream2.source.operations.len == 3);
    try testing.expectEqualStrings("delete", stream2.source.operations[2]);
    try testing.expectEqualStrings("outboxx.orders", stream2.sink.destination);
    try testing.expectEqualStrings("order_id", stream2.sink.routing_key.?);
}

test "parse invalid port type fails" {
    const toml_content =
        \\[metadata]
        \\version = "v0"
        \\
        \\[source]
        \\type = "postgres"
        \\
        \\[source.postgres]
        \\host = "localhost"
        \\port = "not_a_number"
        \\database = "db"
        \\user = "user"
        \\password_env = "PWD"
        \\slot_name = "slot"
        \\publication_name = "pub"
        \\
        \\[sink]
        \\type = "kafka"
        \\
        \\[sink.kafka]
        \\brokers = ["kafka1:9092"]
    ;

    try testing.expectError(error.InvalidValueType, Config.loadFromTomlString(testing.allocator, toml_content));
}

// Validation tests
test "Config validation - valid config passes" {
    const cfg = createTestDefault();
    try cfg.validate(testing.allocator);
}

test "Config validation - missing version" {
    var cfg = createTestDefault();
    cfg.metadata.version = "";
    try testing.expectError(error.MissingConfigVersion, cfg.validate(testing.allocator));
}

test "Config validation - unsupported version" {
    var cfg = createTestDefault();
    cfg.metadata.version = "1";
    try testing.expectError(error.UnsupportedConfigVersion, cfg.validate(testing.allocator));
}

test "Config validation - unsupported format should fail" {
    var cfg = createTestDefault();
    cfg.streams = &.{.{
        .name = "test_stream",
        .source = .{ .resource = "users", .operations = &.{"insert"} },
        .flow = .{ .format = "avro" },
        .sink = .{ .destination = "test_topic", .routing_key = null },
    }};

    try testing.expectError(error.InvalidEnumValue, cfg.validate(testing.allocator));
}

test "Config validation - invalid source type shows proper error format" {
    var cfg = createTestDefault();
    cfg.source.type = "invalid_source_type";
    try testing.expectError(error.InvalidEnumValue, cfg.validate(testing.allocator));
}

test "Config validation - invalid sink type shows proper error format" {
    var cfg = createTestDefault();
    cfg.sink.type = "invalid_sink_type";
    try testing.expectError(error.InvalidEnumValue, cfg.validate(testing.allocator));
}

test "Config validation - port 0 should fail" {
    var cfg = createTestDefault();
    cfg.source.postgres.?.port = 0;
    try testing.expectError(error.InvalidPort, cfg.validate(testing.allocator));
}

test "Config validation - missing required PostgreSQL fields" {
    var cfg = createTestDefault();
    cfg.source.postgres.?.host = "";
    try testing.expectError(error.MissingPostgresHost, cfg.validate(testing.allocator));
}

test "Config validation - empty streams array should fail" {
    var cfg = createTestDefault();
    cfg.streams = &.{};
    try testing.expectError(error.NoStreamsConfigured, cfg.validate(testing.allocator));
}
