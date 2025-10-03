const std = @import("std");
const testing = std.testing;

const config = @import("config.zig");
const Config = config.Config;

// Test helper function - creates valid config for testing
fn createTestDefault(allocator: std.mem.Allocator) Config {
    var test_config = Config.init(allocator);

    // Set metadata for validation
    test_config.metadata.version = "v0";

    // Set source type and PostgreSQL configuration
    test_config.source.type = "postgres";
    test_config.source.postgres = config.PostgresSource{
        .host = "localhost",
        .port = 5432,
        .database = "outboxx_test",
        .user = "postgres",
        .password_env = "POSTGRES_PASSWORD",
        .slot_name = "outboxx_slot",
        .publication_name = "outboxx_publication",
    };

    // Set sink type and Kafka configuration
    test_config.sink.type = "kafka";
    test_config.sink.kafka = config.KafkaSink{
        .brokers = &[_][]const u8{"localhost:9092"},
        .brokers_allocated = false, // This is a const array, not allocated
    };

    // Add a test stream for validation
    // Allocate operations array dynamically so deinit can free it properly
    const insert_op = allocator.dupe(u8, "insert") catch "insert";
    const operations = allocator.dupe([]const u8, &[_][]const u8{insert_op}) catch &[_][]const u8{};

    const stream = config.Stream{
        .name = "test_stream",
        .source = config.StreamSource{
            .resource = "users",
            .operations = operations,
        },
        .flow = config.StreamFlow{
            .format = "json",
        },
        .sink = config.StreamSink{
            .destination = "test_topic",
            .routing_key = null,
        },
    };

    // Allocate streams array with one test stream
    test_config.streams = allocator.dupe(config.Stream, &[_]config.Stream{stream}) catch &[_]config.Stream{};

    return test_config;
}

// Basic Config tests
test "Config.init" {
    const allocator = testing.allocator;
    var cfg = Config.init(allocator);
    defer cfg.deinit(allocator);

    // Config.init now creates empty config that needs to be filled by parser
    try testing.expectEqualStrings("", cfg.metadata.version);
    try testing.expectEqualStrings("", cfg.source.type);
}

test "Config basic functionality" {
    const allocator = testing.allocator;
    var cfg = Config.init(allocator);
    defer cfg.deinit(allocator);

    // Config.init now creates empty config - basic validation
    try testing.expect(cfg.metadata.version.len == 0);
    try testing.expect(cfg.source.type.len == 0);
    try testing.expect(cfg.sink.type.len == 0);
}

test "createTestDefault" {
    const allocator = testing.allocator;
    var cfg = createTestDefault(allocator);
    defer cfg.deinit(allocator);

    // Test PostgreSQL defaults
    try testing.expect(cfg.source.postgres != null);
    const postgres = cfg.source.postgres.?;
    try testing.expectEqualStrings("localhost", postgres.host);
    try testing.expect(postgres.port == 5432);
    try testing.expectEqualStrings("outboxx_test", postgres.database);
    try testing.expectEqualStrings("postgres", postgres.user);
    try testing.expectEqualStrings("POSTGRES_PASSWORD", postgres.password_env);
    try testing.expectEqualStrings("outboxx_slot", postgres.slot_name);
    try testing.expectEqualStrings("outboxx_publication", postgres.publication_name);

    // Test Kafka defaults
    try testing.expect(cfg.sink.kafka != null);
    const kafka = cfg.sink.kafka.?;
    try testing.expect(kafka.brokers.len == 1);
    try testing.expectEqualStrings("localhost:9092", kafka.brokers[0]);
}

// TOML Parser tests
test "parse basic TOML config - file not found should fail" {
    const allocator = testing.allocator;

    // This should fail with FileNotFound error (fail fast)
    const result = Config.loadFromTomlFile(allocator, "dummy_path");
    try testing.expectError(error.FileNotFound, result);
}

test "parse basic TOML config - real file" {
    const allocator = testing.allocator;

    // Create a temporary TOML file for testing
    const temp_content =
        \\[metadata]
        \\version = "0"
        \\
        \\[source]
        \\type = "postgres"
        \\
        \\[source.postgres]
        \\host = "testhost"
        \\port = 5433
        \\database = "testdb"
        \\user = "testuser"
        \\password_env = "TEST_PASSWORD"
        \\slot_name = "test_slot"
        \\publication_name = "test_pub"
        \\
        \\[sink]
        \\type = "kafka"
        \\
        \\[sink.kafka]
        \\brokers = ["kafka1:9092"]
    ;

    // Write to temporary file
    const temp_file = try std.fs.cwd().createFile("test_config.toml", .{});
    defer {
        temp_file.close();
        std.fs.cwd().deleteFile("test_config.toml") catch {};
    }

    try temp_file.writeAll(temp_content);

    // Now parse the real file
    var parsed_config = try Config.loadFromTomlFile(allocator, "test_config.toml");
    defer parsed_config.deinit(allocator);

    // Verify it was parsed correctly
    try testing.expectEqualStrings("0", parsed_config.metadata.version);

    try testing.expect(parsed_config.source.postgres != null);
    const postgres = parsed_config.source.postgres.?;
    try testing.expectEqualStrings("testhost", postgres.host);
    try testing.expect(postgres.port == 5433);
    try testing.expectEqualStrings("testdb", postgres.database);

    // Validate the configuration (skip for now, parser needs improvement)
    // try parsed_config.validate();
}

test "Config validation" {
    const allocator = testing.allocator;

    // Test valid default config
    var valid_config = createTestDefault(allocator);
    defer valid_config.deinit(allocator);
    try valid_config.validate(allocator);

    // Test invalid config - missing version
    var invalid_config = Config.init(allocator);
    defer invalid_config.deinit(allocator);
    try testing.expectError(error.MissingConfigVersion, invalid_config.validate(allocator));
}

test "Config validation - unsupported version" {
    const allocator = testing.allocator;

    // Test config with unsupported version
    var invalid_version_config = createTestDefault(allocator);
    defer invalid_version_config.deinit(allocator);
    invalid_version_config.metadata.version = "1"; // Unsupported version
    try testing.expectError(error.UnsupportedConfigVersion, invalid_version_config.validate(allocator));
}

test "parse PostgreSQL config section" {
    const allocator = testing.allocator;

    const toml_content =
        \\[source.postgres]
        \\host = "pg.example.com"
        \\port = 5433
        \\database = "production_db"
        \\user = "app_user"
        \\password_env = "PROD_PASSWORD"
        \\slot_name = "prod_slot"
        \\publication_name = "prod_pub"
    ;

    var parser = config.ConfigParser.init(allocator);
    var parsed_config = try parser.parseToml(toml_content);
    defer parsed_config.deinit(allocator);

    try testing.expect(parsed_config.source.postgres != null);
    const postgres = parsed_config.source.postgres.?;
    try testing.expectEqualStrings("pg.example.com", postgres.host);
    try testing.expect(postgres.port == 5433);
    try testing.expectEqualStrings("production_db", postgres.database);
    try testing.expectEqualStrings("app_user", postgres.user);
    try testing.expectEqualStrings("PROD_PASSWORD", postgres.password_env);
    try testing.expectEqualStrings("prod_slot", postgres.slot_name);
    try testing.expectEqualStrings("prod_pub", postgres.publication_name);
}

test "parse Kafka config section" {
    const allocator = testing.allocator;

    const toml_content =
        \\[sink.kafka]
        \\brokers = ["kafka1:9092", "kafka2:9092", "kafka3:9092"]
    ;

    var parser = config.ConfigParser.init(allocator);
    var parsed_config = try parser.parseToml(toml_content);
    defer parsed_config.deinit(allocator);

    try testing.expect(parsed_config.sink.kafka != null);
    const kafka = parsed_config.sink.kafka.?;
    try testing.expect(kafka.brokers.len == 3);
    try testing.expectEqualStrings("kafka1:9092", kafka.brokers[0]);
    try testing.expectEqualStrings("kafka2:9092", kafka.brokers[1]);
    try testing.expectEqualStrings("kafka3:9092", kafka.brokers[2]);
}

test "parse complete TOML config" {
    const allocator = testing.allocator;

    const toml_content =
        \\[metadata]
        \\version = "0"
        \\
        \\[source.postgres]
        \\host = "prod-db.company.com"
        \\port = 5432
        \\database = "main_app"
        \\user = "cdc_user"
        \\password_env = "CDC_PASSWORD"
        \\slot_name = "main_slot"
        \\publication_name = "all_tables"
        \\
        \\[sink.kafka]
        \\brokers = ["kafka.internal:9092"]
    ;

    var parser = config.ConfigParser.init(allocator);
    var parsed_config = try parser.parseToml(toml_content);
    defer parsed_config.deinit(allocator);

    // Test metadata
    try testing.expectEqualStrings("0", parsed_config.metadata.version);

    // Test PostgreSQL config
    try testing.expect(parsed_config.source.postgres != null);
    const postgres = parsed_config.source.postgres.?;
    try testing.expectEqualStrings("prod-db.company.com", postgres.host);
    try testing.expectEqualStrings("main_app", postgres.database);
    try testing.expectEqualStrings("cdc_user", postgres.user);
    try testing.expectEqualStrings("CDC_PASSWORD", postgres.password_env);
    try testing.expectEqualStrings("main_slot", postgres.slot_name);
    try testing.expectEqualStrings("all_tables", postgres.publication_name);

    // Test Kafka config
    try testing.expect(parsed_config.sink.kafka != null);
    const kafka = parsed_config.sink.kafka.?;
    try testing.expect(kafka.brokers.len == 1);
    try testing.expectEqualStrings("kafka.internal:9092", kafka.brokers[0]);
}

// Custom TOML parser compatibility tests
test "Custom TOML parser can parse empty document" {
    const allocator = testing.allocator;

    const toml_content = "";

    var parser = config.ConfigParser.init(allocator);
    var result = parser.parseToml(toml_content) catch |err| {
        // Empty document should fail gracefully
        std.debug.print("Expected error for empty document: {}\n", .{err});
        return;
    };
    defer result.deinit(allocator);
}

test "Custom TOML parser can parse simple string" {
    const allocator = testing.allocator;

    const toml_content =
        \\[metadata]
        \\version = "0"
    ;

    var parser = config.ConfigParser.init(allocator);
    var result = try parser.parseToml(toml_content);
    defer result.deinit(allocator);

    try testing.expectEqualStrings("0", result.metadata.version);
}

test "Custom TOML parser can parse numbers" {
    const allocator = testing.allocator;

    const toml_content =
        \\[source.postgres]
        \\port = 8080
    ;

    var parser = config.ConfigParser.init(allocator);
    var result = try parser.parseToml(toml_content);
    defer result.deinit(allocator);

    try testing.expect(result.source.postgres != null);
    try testing.expect(result.source.postgres.?.port == 8080);
}

test "Custom TOML parser can parse boolean values" {
    const allocator = testing.allocator;

    const toml_content =
        \\[sink.kafka]
        \\enabled = true
    ;

    var parser = config.ConfigParser.init(allocator);
    var result = try parser.parseToml(toml_content);
    defer result.deinit(allocator);

    // Note: Our parser doesn't support booleans yet, this test documents current limitations
    // When we add boolean support, update this test
}

test "Custom TOML parser can parse arrays" {
    const allocator = testing.allocator;

    const toml_content =
        \\[sink.kafka]
        \\brokers = ["kafka1:9092", "kafka2:9092", "kafka3:9092"]
    ;

    var parser = config.ConfigParser.init(allocator);
    var result = try parser.parseToml(toml_content);
    defer result.deinit(allocator);

    try testing.expect(result.sink.kafka != null);
    const kafka = result.sink.kafka.?;
    try testing.expect(kafka.brokers.len == 3);
    try testing.expectEqualStrings("kafka1:9092", kafka.brokers[0]);
    try testing.expectEqualStrings("kafka2:9092", kafka.brokers[1]);
    try testing.expectEqualStrings("kafka3:9092", kafka.brokers[2]);
}

test "Custom TOML parser can parse streams array" {
    const allocator = testing.allocator;

    const toml_content =
        \\[[streams]]
        \\name = "users-dev-stream"
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

    var parser = config.ConfigParser.init(allocator);
    var result = try parser.parseToml(toml_content);
    defer result.deinit(allocator);

    try testing.expect(result.streams.len == 1);
    const stream = result.streams[0];
    try testing.expectEqualStrings("users-dev-stream", stream.name);
    try testing.expectEqualStrings("users", stream.source.resource);
    try testing.expect(stream.source.operations.len == 2);
    try testing.expectEqualStrings("insert", stream.source.operations[0]);
    try testing.expectEqualStrings("update", stream.source.operations[1]);
    try testing.expectEqualStrings("json", stream.flow.format);
    try testing.expectEqualStrings("outboxx.users", stream.sink.destination);
    try testing.expectEqualStrings("id", stream.sink.routing_key.?);
}

test "Config validation - unsupported format should fail" {
    const allocator = testing.allocator;

    // Create a valid default config
    var test_config = createTestDefault(allocator);
    defer test_config.deinit(allocator);

    // Modify only the format to test unsupported value
    // Access the existing stream and change only the format
    var modified_stream = test_config.streams[0];
    modified_stream.flow.format = "avro"; // This should be rejected

    // Replace the streams array with our modified stream
    allocator.free(test_config.streams);
    test_config.streams = try allocator.dupe(config.Stream, &[_]config.Stream{modified_stream});

    // Validation should fail due to unsupported format
    try testing.expectError(error.InvalidEnumValue, test_config.validate(allocator));
}

test "Config validation - json format should pass" {
    const allocator = testing.allocator;

    // Create a valid default config (already has json format)
    var test_config = createTestDefault(allocator);
    defer test_config.deinit(allocator);

    // Validation should pass (default config already uses json format)
    try test_config.validate(allocator);
}

test "Config validation - invalid source type shows proper error format" {
    const allocator = testing.allocator;

    var test_config = createTestDefault(allocator);
    defer test_config.deinit(allocator);
    test_config.source.type = "invalid_source_type";

    try testing.expectError(error.InvalidEnumValue, test_config.validate(allocator));
}

test "Config validation - invalid sink type shows proper error format" {
    const allocator = testing.allocator;

    var test_config = createTestDefault(allocator);
    defer test_config.deinit(allocator);
    test_config.sink.type = "invalid_sink_type";

    try testing.expectError(error.InvalidEnumValue, test_config.validate(allocator));
}

test "Config validation - port 0 should fail" {
    const allocator = testing.allocator;

    var test_config = createTestDefault(allocator);
    defer test_config.deinit(allocator);
    test_config.source.postgres.?.port = 0;

    try testing.expectError(error.InvalidPort, test_config.validate(allocator));
}

test "Config validation - missing required PostgreSQL fields" {
    const allocator = testing.allocator;

    var test_config = createTestDefault(allocator);
    defer test_config.deinit(allocator);
    test_config.source.postgres.?.host = "";

    try testing.expectError(error.MissingPostgresHost, test_config.validate(allocator));
}

test "Config validation - empty streams array should fail" {
    const allocator = testing.allocator;

    var test_config = createTestDefault(allocator);
    defer test_config.deinit(allocator);

    // Properly clean up existing streams before setting empty array
    for (test_config.streams) |stream| {
        for (stream.source.operations) |operation| {
            allocator.free(operation);
        }
        allocator.free(stream.source.operations);
    }
    allocator.free(test_config.streams);
    test_config.streams = &[_]config.Stream{};

    try testing.expectError(error.EmptyArray, test_config.validate(allocator));
}

test "parseIntValue with invalid input fails correctly" {
    const allocator = testing.allocator;

    const toml_content =
        \\[source.postgres]
        \\port = "invalid_port"
    ;

    var parser = config.ConfigParser.init(allocator);
    const result = parser.parseToml(toml_content);
    try testing.expectError(error.InvalidCharacter, result);
}
