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
                .connection_env = "POSTGRES_URL",
                .slot_name = "outboxx_slot",
                .publication_name = "outboxx_publication",
            },
        },
        .sink = .{
            .type = "kafka",
            .kafka = .{
                .brokers = &.{"localhost:9092"},
                .tls = false,
            },
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
    \\connection_env = "PROD_POSTGRES_URL"
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
    try testing.expectEqualStrings("POSTGRES_URL", postgres.connection_env);
    try testing.expectEqualStrings("outboxx_slot", postgres.slot_name);

    try testing.expect(cfg.sink.kafka != null);
    try testing.expect(cfg.sink.kafka.?.brokers.len == 1);
    try testing.expectEqualStrings("localhost:9092", cfg.sink.kafka.?.brokers[0]);
}

test "Stream.tracksDelete reflects the configured operations" {
    const Stream = config.Stream;
    const base: Stream = .{
        .name = "s",
        .source = .{ .resource = "users", .operations = &.{} },
        .flow = .{ .format = "json" },
        .sink = .{ .destination = "t", .routing_key = null },
    };

    var insert_update = base;
    insert_update.source.operations = &.{ "insert", "update" };
    try testing.expect(!insert_update.tracksDelete());

    var with_delete = base;
    with_delete.source.operations = &.{ "insert", "delete" };
    try testing.expect(with_delete.tracksDelete());
}

test "supported adapter types are implemented" {
    try testing.expectEqual(@as(usize, 1), config.SupportedValues.SOURCE_TYPES.len);
    try testing.expectEqualStrings("postgres", config.SupportedValues.SOURCE_TYPES[0]);
    try testing.expectEqual(@as(usize, 1), config.SupportedValues.SINK_TYPES.len);
    try testing.expectEqualStrings("kafka", config.SupportedValues.SINK_TYPES[0]);
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
    try testing.expectEqualStrings("PROD_POSTGRES_URL", postgres.connection_env);
    try testing.expectEqualStrings("prod_slot", postgres.slot_name);
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
    try testing.expectEqualStrings("PROD_POSTGRES_URL", postgres.connection_env);
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
        \\connection_env = "PG_URL"
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

test "parse Kafka tls and sasl sections" {
    const toml_content =
        \\[metadata]
        \\version = "v0"
        \\
        \\[source]
        \\type = "postgres"
        \\
        \\[source.postgres]
        \\connection_env = "PG_URL"
        \\slot_name = "slot"
        \\publication_name = "pub"
        \\
        \\[sink]
        \\type = "kafka"
        \\
        \\[sink.kafka]
        \\brokers = ["kafka1:9092"]
        \\tls = true
        \\tls_ca_location = "/etc/ssl/certs/ca.pem"
        \\
        \\[sink.kafka.sasl]
        \\mechanism = "SCRAM-SHA-512"
        \\username = "app"
        \\password_env = "KAFKA_PASSWORD"
    ;

    var parsed = try Config.loadFromTomlString(testing.allocator, toml_content);
    defer parsed.deinit();
    const cfg = parsed.value;

    const kafka = cfg.sink.kafka.?;
    try testing.expect(kafka.tls);
    try testing.expectEqualStrings("/etc/ssl/certs/ca.pem", kafka.tls_ca_location.?);
    try testing.expectEqualStrings("SCRAM-SHA-512", kafka.sasl.?.mechanism);
    try testing.expectEqualStrings("app", kafka.sasl.?.username);
    try testing.expectEqualStrings("KAFKA_PASSWORD", kafka.sasl.?.password_env);
    try testing.expectEqualStrings("sasl_ssl", kafka.securityProtocol());
}

test "default tls is enabled" {
    const toml_content =
        \\[metadata]
        \\version = "v0"
        \\
        \\[source]
        \\type = "postgres"
        \\
        \\[source.postgres]
        \\connection_env = "PG_URL"
        \\slot_name = "slot"
        \\publication_name = "pub"
        \\
        \\[sink]
        \\type = "kafka"
        \\
        \\[sink.kafka]
        \\brokers = ["kafka1:9092"]
    ;

    var parsed = try Config.loadFromTomlString(testing.allocator, toml_content);
    defer parsed.deinit();
    const kafka = parsed.value.sink.kafka.?;

    try testing.expect(kafka.tls);
    try testing.expect(kafka.sasl == null);
    try testing.expectEqualStrings("ssl", kafka.securityProtocol());
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
        \\connection_env = "PG_URL"
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

test "parse invalid boolean type fails" {
    const toml_content =
        \\[metadata]
        \\version = "v0"
        \\
        \\[source]
        \\type = "postgres"
        \\
        \\[source.postgres]
        \\connection_env = "PG_URL"
        \\slot_name = "slot"
        \\publication_name = "pub"
        \\
        \\[sink]
        \\type = "kafka"
        \\
        \\[sink.kafka]
        \\brokers = ["kafka1:9092"]
        \\tls = "not_a_bool"
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

test "Config validation - empty streams array should fail" {
    var cfg = createTestDefault();
    cfg.streams = &.{};
    try testing.expectError(error.NoStreamsConfigured, cfg.validate(testing.allocator));
}

test "Config validation - plaintext Kafka passes" {
    var cfg = createTestDefault();
    cfg.sink.kafka.?.tls = false;
    try cfg.validate(testing.allocator);
}

test "Config validation - TLS-only Kafka passes" {
    var cfg = createTestDefault();
    cfg.sink.kafka.?.tls = true;
    cfg.sink.kafka.?.tls_ca_location = "/etc/ssl/certs/ca.pem";
    try cfg.validate(testing.allocator);
}

test "Config validation - invalid SASL mechanism fails" {
    var cfg = createTestDefault();
    cfg.sink.kafka.?.sasl = .{ .mechanism = "GSSAPI", .username = "app", .password_env = "KAFKA_PASSWORD" };
    try testing.expectError(error.InvalidEnumValue, cfg.validate(testing.allocator));
}

test "Config validation - full SASL over TLS passes" {
    var cfg = createTestDefault();
    cfg.sink.kafka.?.tls = true;
    cfg.sink.kafka.?.tls_ca_location = "/etc/ssl/certs/ca.pem";
    cfg.sink.kafka.?.sasl = .{ .mechanism = "SCRAM-SHA-512", .username = "app", .password_env = "KAFKA_PASSWORD" };
    try cfg.validate(testing.allocator);
}

test "securityProtocol derives from tls and sasl" {
    const testing_sasl: config.KafkaSasl = .{ .mechanism = "PLAIN", .username = "app", .password_env = "PW" };

    var kafka: config.KafkaSink = .{ .brokers = &.{"b:9092"}, .tls = false };
    try testing.expectEqualStrings("plaintext", kafka.securityProtocol());

    kafka.tls = true;
    try testing.expectEqualStrings("ssl", kafka.securityProtocol());

    kafka.sasl = testing_sasl;
    try testing.expectEqualStrings("sasl_ssl", kafka.securityProtocol());

    kafka.tls = false;
    try testing.expectEqualStrings("sasl_plaintext", kafka.securityProtocol());
}

test "parse postgres connection_env" {
    const toml_content =
        \\[metadata]
        \\version = "v0"
        \\
        \\[source]
        \\type = "postgres"
        \\
        \\[source.postgres]
        \\connection_env = "POSTGRES_URL"
        \\slot_name = "slot"
        \\publication_name = "pub"
        \\
        \\[sink]
        \\type = "kafka"
        \\
        \\[sink.kafka]
        \\brokers = ["kafka1:9092"]
    ;

    var parsed = try Config.loadFromTomlString(testing.allocator, toml_content);
    defer parsed.deinit();
    const postgres = parsed.value.source.postgres.?;

    try testing.expectEqualStrings("POSTGRES_URL", postgres.connection_env);
    try testing.expectEqualStrings("slot", postgres.slot_name);
    try testing.expectEqualStrings("pub", postgres.publication_name);
}

test "Config validation - empty postgres connection_env fails" {
    var cfg = createTestDefault();
    cfg.source.postgres.?.connection_env = "";
    try testing.expectError(error.MissingPostgresConnectionEnv, cfg.validate(testing.allocator));
}
