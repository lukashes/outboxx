const std = @import("std");
const toml = @import("toml");

/// Validation limits for configuration fields.
pub const ValidationLimits = struct {
    // String length limits
    pub const MAX_HOSTNAME_LEN = 253;
    pub const MAX_DATABASE_NAME_LEN = 63;
    pub const MAX_IDENTIFIER_LEN = 63;
    pub const MAX_KAFKA_TOPIC_LEN = 249;
    pub const MAX_URL_LEN = 2048;

    // Array size limits
    pub const MAX_BROKERS_COUNT = 50;
    pub const MAX_OPERATIONS_COUNT = 10;
    pub const MAX_STREAMS_COUNT = 100;
};

/// Allowed values for enum-like configuration fields.
pub const SupportedValues = struct {
    pub const SOURCE_TYPES = [_][]const u8{"postgres"};
    pub const SINK_TYPES = [_][]const u8{"kafka"};
    pub const OPERATIONS = [_][]const u8{ "insert", "update", "delete" };
    pub const FORMATS = [_][]const u8{"json"};
    // Only username/password mechanisms; GSSAPI/OAUTHBEARER need auth plumbing we don't expose yet.
    pub const KAFKA_SASL_MECHANISMS = [_][]const u8{ "PLAIN", "SCRAM-SHA-256", "SCRAM-SHA-512" };
};

// Configuration structures matching TOML format

pub const Metadata = struct {
    version: []const u8,
};

pub const PostgresSource = struct {
    // Name of the environment variable holding the libpq connection string (URL or DSN),
    // e.g. postgres://user:pass@host:5432/db?sslmode=verify-full&sslrootcert=/certs/ca.crt.
    // Kept out of the config file so the password never lands on disk; TLS is configured
    // through the string's sslmode/ssl* parameters.
    connection_env: []const u8,
    slot_name: []const u8,
    publication_name: []const u8,
};

pub const SourceConfig = struct {
    type: []const u8,
    postgres: ?PostgresSource = null,
};

// Read the named environment variable; caller owns the result.
fn readEnvVar(allocator: std.mem.Allocator, environ_map: *std.process.Environ.Map, env_name: []const u8) ![]u8 {
    const value = environ_map.get(env_name) orelse {
        std.log.warn("Environment variable '{s}' not found", .{env_name});
        return error.EnvironmentVariableNotFound;
    };
    return allocator.dupe(u8, value);
}

/// SASL authentication for the Kafka broker. Its presence enables SASL; all fields
/// are required once present. The password is read from the environment
/// (password_env), never stored in the config file, mirroring the source password.
pub const KafkaSasl = struct {
    mechanism: []const u8, // PLAIN | SCRAM-SHA-256 | SCRAM-SHA-512
    username: []const u8,
    password_env: []const u8,

    /// Read the SASL password from its configured environment variable; caller owns the result.
    pub fn loadPassword(self: KafkaSasl, allocator: std.mem.Allocator, environ_map: *std.process.Environ.Map) ![]u8 {
        return readEnvVar(allocator, environ_map, self.password_env);
    }
};

pub const KafkaSink = struct {
    brokers: []const []const u8,
    // Encryption on the wire; on by default, set false only for local/dev.
    tls: bool = true,
    tls_ca_location: ?[]const u8 = null, // CA bundle to verify the broker
    sasl: ?KafkaSasl = null,

    /// librdkafka security.protocol derived from the tls/sasl axes.
    pub fn securityProtocol(self: KafkaSink) []const u8 {
        if (self.sasl != null) {
            return if (self.tls) "sasl_ssl" else "sasl_plaintext";
        }
        return if (self.tls) "ssl" else "plaintext";
    }
};

pub const SinkConfig = struct {
    type: []const u8,
    kafka: ?KafkaSink = null,
};

pub const StreamSource = struct {
    resource: []const u8, // table/collection/index
    operations: []const []const u8, // ["insert", "update", "delete"]
};

pub const StreamFlow = struct {
    format: []const u8,
};

pub const StreamSink = struct {
    destination: []const u8, // topic/url/path/table
    routing_key: []const u8 = "id", // partition key column; defaults to the primary key
};

pub const Stream = struct {
    name: []const u8,
    source: StreamSource,
    flow: StreamFlow,
    sink: StreamSink,

    /// Whether this stream captures DELETE. Config validation restricts operations
    /// to the lowercase set, so an exact match is enough.
    pub fn hasDeleteOperation(self: Stream) bool {
        for (self.source.operations) |op| {
            if (std.mem.eql(u8, op, "delete")) return true;
        }
        return false;
    }
};

pub const TableFilter = struct {
    include: []const []const u8,
    exclude: []const []const u8,
};

/// Optional metrics/health HTTP server. Absent section -> observability disabled.
pub const ObservabilityConfig = struct {
    // 0.0.0.0 for container scraping; 127.0.0.1 to keep it local. No secrets on these endpoints.
    address: []const u8 = "0.0.0.0",
    port: u16 = 9464, // conventional OpenTelemetry Prometheus exporter port
};

/// Configuration data, and the TOML parse target. Strings point into the arena of the
/// returned toml.Parsed(Config), so the caller keeps that value alive while using it.
pub const Config = struct {
    metadata: Metadata,
    source: SourceConfig,
    sink: SinkConfig,
    streams: []const Stream = &.{},
    tables: ?TableFilter = null,
    observability: ?ObservabilityConfig = null,

    /// Parse a config file; caller owns and must deinit the returned result.
    pub fn loadFromTomlFile(io: std.Io, allocator: std.mem.Allocator, file_path: []const u8) !toml.Parsed(Config) {
        var parser = toml.Parser(Config).init(allocator);
        defer parser.deinit();
        return parser.parseFile(io, file_path) catch |err| {
            std.log.warn("Failed to parse config file '{s}': {}", .{ file_path, err });
            return err;
        };
    }

    /// Parse a config string; caller owns and must deinit the returned result.
    pub fn loadFromTomlString(allocator: std.mem.Allocator, content: []const u8) !toml.Parsed(Config) {
        var parser = toml.Parser(Config).init(allocator);
        defer parser.deinit();
        return parser.parseString(content);
    }

    /// Read the Kafka SASL password from the environment; caller owns the result.
    /// Returns null unless the sink actually negotiates SASL.
    pub fn loadKafkaSaslPassword(self: Config, allocator: std.mem.Allocator, environ_map: *std.process.Environ.Map) !?[]u8 {
        const kafka = self.sink.kafka orelse return null;
        const sasl = kafka.sasl orelse return null;

        return try sasl.loadPassword(allocator, environ_map);
    }

    /// Read the Postgres source's libpq connection string from its configured environment
    /// variable; caller owns the result. The value is a full conninfo (URL or DSN) and may
    /// carry the password, so callers must not log it verbatim.
    pub fn loadPostgresConninfo(self: Config, allocator: std.mem.Allocator, environ_map: *std.process.Environ.Map) ![]u8 {
        const postgres = self.source.postgres orelse return error.PostgresNotConfigured;
        return readEnvVar(allocator, environ_map, postgres.connection_env);
    }

    // Helper validation functions

    fn validateEnum(allocator: std.mem.Allocator, value: []const u8, allowed_values: []const []const u8, field_name: []const u8) !void {
        for (allowed_values) |allowed| {
            if (std.mem.eql(u8, value, allowed)) return;
        }

        // Build allowed values list as a single string
        var allowed_list = std.ArrayList(u8).empty;
        defer allowed_list.deinit(allocator);

        try allowed_list.appendSlice(allocator, "[");
        for (allowed_values, 0..) |allowed, i| {
            if (i > 0) try allowed_list.appendSlice(allocator, ", ");
            try allowed_list.appendSlice(allocator, "'");
            try allowed_list.appendSlice(allocator, allowed);
            try allowed_list.appendSlice(allocator, "'");
        }
        try allowed_list.appendSlice(allocator, "]");

        std.log.warn("Invalid {s}: '{s}'. Allowed values: {s}", .{ field_name, value, allowed_list.items });
        return error.InvalidEnumValue;
    }

    fn validateStringLength(value: []const u8, max_len: usize, field_name: []const u8) !void {
        if (value.len == 0) {
            std.log.warn("Empty {s} not allowed", .{field_name});
            return error.EmptyString;
        }
        if (value.len > max_len) {
            std.log.warn("{s} too long: {d} chars (max: {d})", .{ field_name, value.len, max_len });
            return error.StringTooLong;
        }
    }

    // Reject port 0; u16 already caps the upper bound at 65535.
    fn validatePort(port: u16, field_name: []const u8) !void {
        if (port == 0) {
            std.log.warn("Invalid {s}: port must be 1-65535", .{field_name});
            return error.InvalidPort;
        }
    }

    fn validateArraySize(len: usize, max_len: usize, field_name: []const u8) !void {
        if (len == 0) {
            std.log.warn("Empty {s} array not allowed", .{field_name});
            return error.EmptyArray;
        }
        if (len > max_len) {
            std.log.warn("{s} array too large: {d} items (max: {d})", .{ field_name, len, max_len });
            return error.ArrayTooLarge;
        }
    }

    // Alphanumeric plus underscore, must start with a letter or underscore.
    fn validatePostgresIdentifier(value: []const u8, field_name: []const u8) !void {
        try validateStringLength(value, ValidationLimits.MAX_IDENTIFIER_LEN, field_name);

        if (value.len == 0) return error.EmptyString;

        // First character must be letter or underscore
        const first_char = value[0];
        if (!std.ascii.isAlphabetic(first_char) and first_char != '_') {
            std.log.warn("Invalid {s}: '{s}' must start with letter or underscore", .{ field_name, value });
            return error.InvalidIdentifierFormat;
        }

        // Rest can be alphanumeric or underscore
        for (value[1..]) |char| {
            if (!std.ascii.isAlphanumeric(char) and char != '_') {
                std.log.warn("Invalid {s}: '{s}' contains invalid character '{c}'", .{ field_name, value, char });
                return error.InvalidIdentifierFormat;
            }
        }
    }

    // Kafka topic charset: a-z, A-Z, 0-9, '.', '_', '-'.
    fn validateKafkaTopicName(value: []const u8, field_name: []const u8) !void {
        try validateStringLength(value, ValidationLimits.MAX_KAFKA_TOPIC_LEN, field_name);

        // Kafka topic names can contain a-z, A-Z, 0-9, ., _, -
        for (value) |char| {
            if (!std.ascii.isAlphanumeric(char) and char != '.' and char != '_' and char != '-') {
                std.log.warn("Invalid {s}: '{s}' contains invalid character '{c}'", .{ field_name, value, char });
                return error.InvalidTopicFormat;
            }
        }
    }

    fn validateOperations(allocator: std.mem.Allocator, operations: []const []const u8) !void {
        try validateArraySize(operations.len, ValidationLimits.MAX_OPERATIONS_COUNT, "operations");

        for (operations) |operation| {
            try validateEnum(allocator, operation, &SupportedValues.OPERATIONS, "operation");
        }
    }

    // Like a Postgres identifier but also allows dashes (sanitized in main.zig).
    fn validateStreamName(value: []const u8, field_name: []const u8) !void {
        try validateStringLength(value, ValidationLimits.MAX_IDENTIFIER_LEN, field_name);

        if (value.len == 0) return error.EmptyString;

        // First character must be letter or underscore
        const first_char = value[0];
        if (!std.ascii.isAlphabetic(first_char) and first_char != '_') {
            std.log.warn("Invalid {s}: '{s}' must start with letter or underscore", .{ field_name, value });
            return error.InvalidIdentifierFormat;
        }

        // Rest can be alphanumeric, underscore, or dash
        for (value[1..]) |char| {
            if (!std.ascii.isAlphanumeric(char) and char != '_' and char != '-') {
                std.log.warn("Invalid {s}: '{s}' contains invalid character '{c}'", .{ field_name, value, char });
                return error.InvalidIdentifierFormat;
            }
        }
    }

    fn validateKafkaSasl(allocator: std.mem.Allocator, sasl: KafkaSasl) !void {
        try validateEnum(allocator, sasl.mechanism, &SupportedValues.KAFKA_SASL_MECHANISMS, "kafka.sasl.mechanism");
        try validateStringLength(sasl.username, ValidationLimits.MAX_HOSTNAME_LEN, "kafka.sasl.username");
        try validateStringLength(sasl.password_env, ValidationLimits.MAX_IDENTIFIER_LEN, "kafka.sasl.password_env");
    }

    fn validateStream(allocator: std.mem.Allocator, stream: Stream) !void {
        // Stream name validation (allow dashes)
        try validateStreamName(stream.name, "stream.name");

        // Source validation
        try validatePostgresIdentifier(stream.source.resource, "stream.source.resource");
        try validateOperations(allocator, stream.source.operations);

        // Flow validation
        try validateEnum(allocator, stream.flow.format, &SupportedValues.FORMATS, "stream.flow.format");

        // Sink validation
        try validateKafkaTopicName(stream.sink.destination, "stream.sink.destination");
        try validateStringLength(stream.sink.routing_key, ValidationLimits.MAX_IDENTIFIER_LEN, "stream.sink.routing_key");
    }

    fn validateStreams(allocator: std.mem.Allocator, streams: []const Stream) !void {
        try validateArraySize(streams.len, ValidationLimits.MAX_STREAMS_COUNT, "streams");

        // Validate each stream
        for (streams) |stream| {
            try validateStream(allocator, stream);
        }

        // Check for duplicate stream names
        for (streams, 0..) |stream1, i| {
            for (streams[i + 1 ..]) |stream2| {
                if (std.mem.eql(u8, stream1.name, stream2.name)) {
                    std.log.warn("Duplicate stream name: '{s}'", .{stream1.name});
                    return error.DuplicateStreamName;
                }
            }
        }
    }

    /// Validate configuration for completeness and correctness
    pub fn validate(self: Config, allocator: std.mem.Allocator) !void {
        // 1. METADATA VALIDATION
        if (self.metadata.version.len == 0) {
            return error.MissingConfigVersion;
        }
        if (!std.mem.eql(u8, self.metadata.version, "v0")) {
            return error.UnsupportedConfigVersion;
        }

        // 2. ENUM VALIDATION (with detailed error messages)
        // Validate source type first to get detailed error message
        if (self.source.type.len == 0) {
            return error.MissingSourceType;
        }
        try validateEnum(allocator, self.source.type, &SupportedValues.SOURCE_TYPES, "source.type");

        // Validate sink type with detailed error message
        if (self.sink.type.len == 0) {
            return error.MissingSinkType;
        }
        try validateEnum(allocator, self.sink.type, &SupportedValues.SINK_TYPES, "sink.type");

        // 3. STRUCTURAL INTEGRITY (after enum validation)
        // Check source configuration structure
        if (std.mem.eql(u8, self.source.type, "postgres")) {
            if (self.source.postgres == null) {
                return error.MissingPostgresConfig;
            }
            const postgres = self.source.postgres.?;
            if (postgres.connection_env.len == 0) return error.MissingPostgresConnectionEnv;
            if (postgres.slot_name.len == 0) return error.MissingPostgresSlotName;
        }

        // Check sink configuration structure
        if (std.mem.eql(u8, self.sink.type, "kafka")) {
            if (self.sink.kafka == null) {
                return error.MissingKafkaConfig;
            }
            const kafka = self.sink.kafka.?;
            if (kafka.brokers.len == 0) return error.MissingKafkaBrokers;
        }

        // 4. DETAILED FIELD VALIDATION
        // Enhanced source validation with string limits and format checks
        if (std.mem.eql(u8, self.source.type, "postgres")) {
            const postgres = self.source.postgres.?;
            try validateStringLength(postgres.connection_env, ValidationLimits.MAX_IDENTIFIER_LEN, "postgres.connection_env");
            try validatePostgresIdentifier(postgres.slot_name, "postgres.slot_name");
            try validatePostgresIdentifier(postgres.publication_name, "postgres.publication_name");
        }

        // Enhanced sink validation with string limits and format checks
        if (std.mem.eql(u8, self.sink.type, "kafka")) {
            const kafka = self.sink.kafka.?;
            try validateArraySize(kafka.brokers.len, ValidationLimits.MAX_BROKERS_COUNT, "kafka.brokers");
            for (kafka.brokers) |broker| {
                try validateStringLength(broker, ValidationLimits.MAX_HOSTNAME_LEN, "kafka.broker");
            }
            if (kafka.tls_ca_location) |ca_location| {
                try validateStringLength(ca_location, ValidationLimits.MAX_URL_LEN, "kafka.tls_ca_location");
            }
            if (kafka.sasl) |sasl| {
                try validateKafkaSasl(allocator, sasl);
            }
        }

        // 5. OBSERVABILITY VALIDATION
        if (self.observability) |obs| {
            try validatePort(obs.port, "observability.port");
            try validateStringLength(obs.address, ValidationLimits.MAX_HOSTNAME_LEN, "observability.address");
        }

        // 6. STREAMS VALIDATION
        if (self.streams.len == 0) {
            std.log.warn("No streams configured in config file", .{});
            return error.NoStreamsConfigured;
        }
        try validateStreams(allocator, self.streams);
    }
};

const testing = std.testing;

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
                .sink = .{ .destination = "test_topic", .routing_key = "id" },
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

test "Stream.hasDeleteOperation reflects the configured operations" {
    const base: Stream = .{
        .name = "s",
        .source = .{ .resource = "users", .operations = &.{} },
        .flow = .{ .format = "json" },
        .sink = .{ .destination = "t", .routing_key = "id" },
    };

    var insert_update = base;
    insert_update.source.operations = &.{ "insert", "update" };
    try testing.expect(!insert_update.hasDeleteOperation());

    var with_delete = base;
    with_delete.source.operations = &.{ "insert", "delete" };
    try testing.expect(with_delete.hasDeleteOperation());
}

test "supported adapter types are implemented" {
    try testing.expectEqual(@as(usize, 1), SupportedValues.SOURCE_TYPES.len);
    try testing.expectEqualStrings("postgres", SupportedValues.SOURCE_TYPES[0]);
    try testing.expectEqual(@as(usize, 1), SupportedValues.SINK_TYPES.len);
    try testing.expectEqualStrings("kafka", SupportedValues.SINK_TYPES[0]);
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
    try testing.expectEqualStrings("id", stream.sink.routing_key);
}

test "routing_key defaults to id when omitted" {
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
        \\[[streams]]
        \\name = "users-stream"
        \\
        \\[streams.source]
        \\resource = "users"
        \\operations = ["insert"]
        \\
        \\[streams.flow]
        \\format = "json"
        \\
        \\[streams.sink]
        \\destination = "outboxx.users"
    ;

    var parsed = try Config.loadFromTomlString(testing.allocator, toml_content);
    defer parsed.deinit();

    try testing.expectEqualStrings("id", parsed.value.streams[0].sink.routing_key);
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
    try testing.expectEqualStrings("id", stream1.sink.routing_key);

    const stream2 = cfg.streams[1];
    try testing.expectEqualStrings("orders-stream", stream2.name);
    try testing.expectEqualStrings("orders", stream2.source.resource);
    try testing.expect(stream2.source.operations.len == 3);
    try testing.expectEqualStrings("delete", stream2.source.operations[2]);
    try testing.expectEqualStrings("outboxx.orders", stream2.sink.destination);
    try testing.expectEqualStrings("order_id", stream2.sink.routing_key);
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
        .sink = .{ .destination = "test_topic", .routing_key = "id" },
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
    const testing_sasl: KafkaSasl = .{ .mechanism = "PLAIN", .username = "app", .password_env = "PW" };

    var kafka: KafkaSink = .{ .brokers = &.{"b:9092"}, .tls = false };
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
