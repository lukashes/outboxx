const std = @import("std");
const toml = @import("toml");

// Configuration validation limits and constants
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

// Supported enum values
pub const SupportedValues = struct {
    pub const SOURCE_TYPES = [_][]const u8{ "postgres", "mysql" };
    pub const SINK_TYPES = [_][]const u8{ "kafka", "webhook" };
    pub const OPERATIONS = [_][]const u8{ "insert", "update", "delete" };
    pub const FORMATS = [_][]const u8{"json"};
};

// Configuration structures matching TOML format

pub const Metadata = struct {
    version: []const u8,
};

pub const PostgresSource = struct {
    host: []const u8,
    port: u16,
    database: []const u8,
    user: []const u8,
    password_env: []const u8,
    slot_name: []const u8,
    publication_name: []const u8,
};

pub const MysqlSource = struct {
    host: []const u8,
    port: u16,
    database: []const u8,
    user: []const u8,
    password_env: []const u8,
    server_id: u32,
    binlog_format: []const u8,
};

pub const SourceConfig = struct {
    type: []const u8,
    postgres: ?PostgresSource = null,
    mysql: ?MysqlSource = null,
};

pub const KafkaSink = struct {
    brokers: []const []const u8,
};

pub const WebhookSink = struct {
    url: []const u8,
    method: []const u8,
};

pub const SinkConfig = struct {
    type: []const u8,
    kafka: ?KafkaSink = null,
    webhook: ?WebhookSink = null,
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
    routing_key: ?[]const u8 = null, // partition_key/routing
};

pub const Stream = struct {
    name: []const u8,
    source: StreamSource,
    flow: StreamFlow,
    sink: StreamSink,
};

pub const TableFilter = struct {
    include: []const []const u8,
    exclude: []const []const u8,
};

// Configuration data, and the TOML parse target. Strings point into the arena of the
// returned toml.Parsed(Config), so the caller keeps that value alive while using it.
pub const Config = struct {
    metadata: Metadata,
    source: SourceConfig,
    sink: SinkConfig,
    streams: []const Stream = &.{},
    tables: ?TableFilter = null,

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

    /// Read the configured source's password from the environment; caller owns the result.
    pub fn loadPassword(self: Config, allocator: std.mem.Allocator, environ_map: *std.process.Environ.Map) ![]u8 {
        const env_name = if (self.source.postgres) |postgres|
            postgres.password_env
        else if (self.source.mysql) |mysql|
            mysql.password_env
        else
            return error.PasswordNotConfigured;

        const value = environ_map.get(env_name) orelse {
            std.log.warn("Environment variable '{s}' not found", .{env_name});
            return error.EnvironmentVariableNotFound;
        };
        return allocator.dupe(u8, value);
    }

    /// Build the libpq connection string for the configured PostgreSQL source.
    pub fn postgresConnectionString(self: Config, allocator: std.mem.Allocator, password: []const u8) ![]u8 {
        const postgres = self.source.postgres orelse return error.PostgresNotConfigured;

        return std.fmt.allocPrint(
            allocator,
            "host={s} port={d} dbname={s} user={s} password={s} replication=database gssencmode=disable",
            .{ postgres.host, postgres.port, postgres.database, postgres.user, password },
        );
    }

    // Helper validation functions

    /// Validate that a string is in the allowed enum values
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

    /// Validate string length limits
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

    /// Validate port number range (1-65535)
    fn validatePort(port: u16, field_name: []const u8) !void {
        if (port == 0) {
            std.log.warn("Invalid {s}: {d} (must be 1-65535)", .{ field_name, port });
            return error.InvalidPort;
        }
        // u16 max is 65535, so no upper bound check needed
    }

    /// Validate array size limits
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

    /// Validate PostgreSQL identifier format (alphanumeric + underscore, must start with letter or underscore)
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

    /// Validate Kafka topic name format
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

    /// Validate hostname format (basic validation)
    fn validateHostname(value: []const u8, field_name: []const u8) !void {
        try validateStringLength(value, ValidationLimits.MAX_HOSTNAME_LEN, field_name);

        // Basic hostname validation: alphanumeric, dots, hyphens
        for (value) |char| {
            if (!std.ascii.isAlphanumeric(char) and char != '.' and char != '-') {
                std.log.warn("Invalid {s}: '{s}' contains invalid character '{c}'", .{ field_name, value, char });
                return error.InvalidHostnameFormat;
            }
        }
    }

    /// Validate stream operations array
    fn validateOperations(allocator: std.mem.Allocator, operations: []const []const u8) !void {
        try validateArraySize(operations.len, ValidationLimits.MAX_OPERATIONS_COUNT, "operations");

        for (operations) |operation| {
            try validateEnum(allocator, operation, &SupportedValues.OPERATIONS, "operation");
        }
    }

    /// Validate stream name format (allow dashes since they are sanitized in main.zig)
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

    /// Validate individual stream configuration
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
        if (stream.sink.routing_key) |routing_key| {
            try validateStringLength(routing_key, ValidationLimits.MAX_IDENTIFIER_LEN, "stream.sink.routing_key");
        }
    }

    /// Validate all streams
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
            if (postgres.host.len == 0) return error.MissingPostgresHost;
            if (postgres.database.len == 0) return error.MissingPostgresDatabase;
            if (postgres.user.len == 0) return error.MissingPostgresUser;
            if (postgres.slot_name.len == 0) return error.MissingPostgresSlotName;
        } else if (std.mem.eql(u8, self.source.type, "mysql")) {
            if (self.source.mysql == null) {
                return error.MissingMysqlConfig;
            }
            const mysql = self.source.mysql.?;
            if (mysql.host.len == 0) return error.MissingMysqlHost;
            if (mysql.database.len == 0) return error.MissingMysqlDatabase;
            if (mysql.user.len == 0) return error.MissingMysqlUser;
        }

        // Check sink configuration structure
        if (std.mem.eql(u8, self.sink.type, "kafka")) {
            if (self.sink.kafka == null) {
                return error.MissingKafkaConfig;
            }
            const kafka = self.sink.kafka.?;
            if (kafka.brokers.len == 0) return error.MissingKafkaBrokers;
        } else if (std.mem.eql(u8, self.sink.type, "webhook")) {
            if (self.sink.webhook == null) {
                return error.MissingWebhookConfig;
            }
        }

        // 4. DETAILED FIELD VALIDATION
        // Enhanced source validation with string limits and format checks
        if (std.mem.eql(u8, self.source.type, "postgres")) {
            const postgres = self.source.postgres.?;
            try validateHostname(postgres.host, "postgres.host");
            try validatePort(postgres.port, "postgres.port");
            try validatePostgresIdentifier(postgres.database, "postgres.database");
            try validatePostgresIdentifier(postgres.user, "postgres.user");
            try validatePostgresIdentifier(postgres.slot_name, "postgres.slot_name");
            try validatePostgresIdentifier(postgres.publication_name, "postgres.publication_name");
            try validateStringLength(postgres.password_env, ValidationLimits.MAX_IDENTIFIER_LEN, "postgres.password_env");
        } else if (std.mem.eql(u8, self.source.type, "mysql")) {
            const mysql = self.source.mysql.?;
            try validateHostname(mysql.host, "mysql.host");
            try validatePort(mysql.port, "mysql.port");
            try validatePostgresIdentifier(mysql.database, "mysql.database");
            try validatePostgresIdentifier(mysql.user, "mysql.user");
            try validateStringLength(mysql.password_env, ValidationLimits.MAX_IDENTIFIER_LEN, "mysql.password_env");
            try validateStringLength(mysql.binlog_format, ValidationLimits.MAX_IDENTIFIER_LEN, "mysql.binlog_format");
        }

        // Enhanced sink validation with string limits and format checks
        if (std.mem.eql(u8, self.sink.type, "kafka")) {
            const kafka = self.sink.kafka.?;
            try validateArraySize(kafka.brokers.len, ValidationLimits.MAX_BROKERS_COUNT, "kafka.brokers");
            for (kafka.brokers) |broker| {
                try validateStringLength(broker, ValidationLimits.MAX_HOSTNAME_LEN, "kafka.broker");
            }
        } else if (std.mem.eql(u8, self.sink.type, "webhook")) {
            const webhook = self.sink.webhook.?;
            try validateStringLength(webhook.url, ValidationLimits.MAX_URL_LEN, "webhook.url");
            try validateStringLength(webhook.method, ValidationLimits.MAX_IDENTIFIER_LEN, "webhook.method");
        }

        // 5. STREAMS VALIDATION
        if (self.streams.len == 0) {
            std.log.warn("No streams configured in config file", .{});
            return error.NoStreamsConfigured;
        }
        try validateStreams(allocator, self.streams);
    }
};
