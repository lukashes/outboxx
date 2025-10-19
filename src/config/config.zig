const std = @import("std");

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
    pub const SOURCE_ENGINES = [_][]const u8{ "polling", "streaming" };
};

// PostgreSQL source engine type
pub const SourceEngine = enum {
    polling,
    streaming,

    pub fn fromString(str: []const u8) !SourceEngine {
        if (std.mem.eql(u8, str, "polling")) return .polling;
        if (std.mem.eql(u8, str, "streaming")) return .streaming;
        return error.InvalidSourceEngine;
    }

    pub fn toString(self: SourceEngine) []const u8 {
        return switch (self) {
            .polling => "polling",
            .streaming => "streaming",
        };
    }
};

// Configuration structures matching TOML format

pub const Metadata = struct {
    version: []const u8,
};

pub const PostgresSource = struct {
    engine: SourceEngine = .streaming, // Default to streaming source
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
    // Track if brokers array was dynamically allocated
    brokers_allocated: bool = false,
};

pub const WebhookSink = struct {
    url: []const u8,
    method: []const u8,
    headers: std.StringHashMap([]const u8),
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

pub const ParseError = error{
    InvalidToml,
    MissingSection,
    InvalidType,
    OutOfMemory,
};

pub const Config = struct {
    metadata: Metadata,
    source: SourceConfig,
    sink: SinkConfig,
    streams: []Stream,
    tables: TableFilter,

    // Runtime password storage (populated from ENV)
    runtime_passwords: std.StringHashMap([]const u8),

    // Track allocated strings for proper cleanup
    allocated_strings: [][]const u8,
    allocated_count: usize,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Config {
        return Config{
            .metadata = Metadata{
                .version = "", // Empty string, will be set by parser
            },
            .source = SourceConfig{ .type = "" }, // Empty, will be set by parser
            .sink = SinkConfig{ .type = "" },
            .streams = &.{},
            .tables = TableFilter{
                .include = &.{},
                .exclude = &.{},
            },
            .runtime_passwords = std.StringHashMap([]const u8).init(allocator),
            .allocated_strings = &[_][]const u8{},
            .allocated_count = 0,
            .allocator = allocator,
        };
    }

    /// Load passwords from environment variables based on config
    pub fn loadPasswords(self: *Config, allocator: std.mem.Allocator) !void {
        // Load PostgreSQL password if configured
        if (self.source.postgres) |postgres| {
            const password = std.process.getEnvVarOwned(allocator, postgres.password_env) catch |err| switch (err) {
                error.EnvironmentVariableNotFound => {
                    std.log.warn("Environment variable '{s}' not found", .{postgres.password_env});
                    return err;
                },
                else => return err,
            };
            try self.runtime_passwords.put("postgres", password);
        }

        // Load MySQL password if configured
        if (self.source.mysql) |mysql| {
            const password = std.process.getEnvVarOwned(allocator, mysql.password_env) catch |err| switch (err) {
                error.EnvironmentVariableNotFound => {
                    std.log.warn("Environment variable '{s}' not found", .{mysql.password_env});
                    return err;
                },
                else => return err,
            };
            try self.runtime_passwords.put("mysql", password);
        }
    }

    /// Get password for source type
    pub fn getPassword(self: Config, source_type: []const u8) ?[]const u8 {
        return self.runtime_passwords.get(source_type);
    }

    /// Generate PostgreSQL connection string
    pub fn postgresConnectionString(self: Config, allocator: std.mem.Allocator) ![]u8 {
        const postgres = self.source.postgres orelse return error.PostgresNotConfigured;
        const password = self.getPassword("postgres") orelse return error.PasswordNotLoaded;

        return std.fmt.allocPrint(
            allocator,
            "host={s} port={d} dbname={s} user={s} password={s} replication=database gssencmode=disable",
            .{ postgres.host, postgres.port, postgres.database, postgres.user, password },
        );
    }

    pub fn deinit(self: *Config, allocator: std.mem.Allocator) void {
        // Free runtime passwords
        var iterator = self.runtime_passwords.iterator();
        while (iterator.next()) |entry| {
            allocator.free(entry.value_ptr.*);
        }
        self.runtime_passwords.deinit();

        // Free all allocated strings
        for (self.allocated_strings[0..self.allocated_count]) |str| {
            allocator.free(str);
        }
        if (self.allocated_strings.len > 0) {
            allocator.free(self.allocated_strings);
        }

        // Free allocated arrays (only if they were dynamically allocated)
        if (self.sink.kafka) |*kafka| {
            if (kafka.brokers_allocated) {
                // Free individual broker strings
                for (kafka.brokers) |broker| {
                    allocator.free(broker);
                }
                // Free the brokers array itself
                allocator.free(kafka.brokers);
            }
        }

        // Free streams array and individual stream operation arrays
        if (self.streams.len > 0) {
            for (self.streams) |stream| {
                // Free operations array for each stream if it was allocated
                if (stream.source.operations.len > 0) {
                    for (stream.source.operations) |operation| {
                        allocator.free(operation);
                    }
                    allocator.free(stream.source.operations);
                }
            }
            allocator.free(self.streams);
        }
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
            // Validate engine field
            try validateEnum(allocator, postgres.engine.toString(), &SupportedValues.SOURCE_ENGINES, "postgres.engine");
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

    /// Load configuration from TOML file
    pub fn loadFromTomlFile(allocator: std.mem.Allocator, file_path: []const u8) !Config {
        var parser = ConfigParser.init(allocator);
        return parser.parseFile(file_path);
    }
};

// Internal configuration parser
pub const ConfigParser = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ConfigParser {
        return ConfigParser{
            .allocator = allocator,
        };
    }

    /// Parse TOML config file
    pub fn parseFile(self: *ConfigParser, file_path: []const u8) !Config {
        const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
            return err;
        };
        defer file.close();

        const file_content = file.readToEndAlloc(self.allocator, 1024 * 1024) catch |err| {
            std.log.warn("Failed to read config file: {}", .{err});
            return err;
        };
        defer self.allocator.free(file_content);

        return self.parseToml(file_content);
    }

    /// Parse TOML content string
    pub fn parseToml(self: *ConfigParser, content: []const u8) !Config {
        var result = Config.init(self.allocator);

        // Simple line-by-line parser for our specific TOML structure
        var lines = std.mem.splitSequence(u8, content, "\n");
        var current_section: ?[]const u8 = null;
        var current_subsection: ?[]const u8 = null;
        var streams_list = std.ArrayList(Stream).empty;
        defer streams_list.deinit(self.allocator);
        var current_stream_index: ?usize = null;

        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");

            // Skip empty lines and comments
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            // Parse array of tables [[streams]]
            if (trimmed.len >= 4 and std.mem.startsWith(u8, trimmed, "[[")) {
                // Find closing ]] (may have comments after)
                const closing_bracket = std.mem.indexOf(u8, trimmed, "]]") orelse continue;
                const array_section = trimmed[2..closing_bracket];

                if (std.mem.eql(u8, array_section, "streams")) {
                    // Create new stream entry
                    try streams_list.append(self.allocator, Stream{
                        .name = "",
                        .source = StreamSource{
                            .resource = "",
                            .operations = &.{},
                        },
                        .flow = StreamFlow{
                            .format = "",
                        },
                        .sink = StreamSink{
                            .destination = "",
                            .routing_key = null,
                        },
                    });
                    current_stream_index = streams_list.items.len - 1;
                    current_section = "streams";
                    current_subsection = null;
                }
                continue;
            }

            // Parse sections [section]
            if (trimmed[0] == '[' and trimmed[trimmed.len - 1] == ']') {
                const section_name = trimmed[1 .. trimmed.len - 1];

                if (std.mem.indexOf(u8, section_name, ".")) |dot_pos| {
                    current_section = section_name[0..dot_pos];
                    current_subsection = section_name[dot_pos + 1 ..];
                } else {
                    current_section = section_name;
                    current_subsection = null;
                }
                continue;
            }

            // Parse key-value pairs
            if (std.mem.indexOf(u8, trimmed, "=")) |eq_pos| {
                const key = std.mem.trim(u8, trimmed[0..eq_pos], " \t");
                const value_str = std.mem.trim(u8, trimmed[eq_pos + 1 ..], " \t");

                const current_stream = if (current_stream_index) |idx| &streams_list.items[idx] else null;
                try self.setConfigValue(&result, current_section, current_subsection, key, value_str, current_stream);
            }
        }

        // Convert streams list to owned slice
        if (streams_list.items.len > 0) {
            result.streams = try self.allocator.dupe(Stream, streams_list.items);
        }

        return result;
    }

    fn setConfigValue(
        self: *ConfigParser,
        config: *Config,
        section: ?[]const u8,
        subsection: ?[]const u8,
        key: []const u8,
        value_str: []const u8,
        current_stream: ?*Stream,
    ) !void {
        if (section == null) return;

        if (std.mem.eql(u8, section.?, "metadata")) {
            try self.parseMetadataValue(config, key, value_str);
        } else if (std.mem.eql(u8, section.?, "source")) {
            if (subsection == null) {
                try self.parseSourceValue(config, key, value_str);
            } else if (subsection != null) {
                if (std.mem.eql(u8, subsection.?, "postgres")) {
                    try self.parsePostgresValue(config, key, value_str);
                } else if (std.mem.eql(u8, subsection.?, "mysql")) {
                    try self.parseMysqlValue(config, key, value_str);
                }
            }
        } else if (std.mem.eql(u8, section.?, "sink")) {
            if (subsection == null) {
                try self.parseSinkValue(config, key, value_str);
            } else if (subsection != null) {
                if (std.mem.eql(u8, subsection.?, "kafka")) {
                    try self.parseKafkaValue(config, key, value_str);
                }
            }
        } else if (std.mem.eql(u8, section.?, "streams")) {
            if (current_stream) |stream| {
                try self.parseStreamValue(stream, subsection, key, value_str, config);
            }
        }
    }

    fn parseMetadataValue(self: *ConfigParser, config: *Config, key: []const u8, value_str: []const u8) !void {
        const value = try self.parseStringValue(config, value_str);

        if (std.mem.eql(u8, key, "version")) {
            config.metadata.version = value;
        }
    }

    fn parseSourceValue(self: *ConfigParser, config: *Config, key: []const u8, value_str: []const u8) !void {
        const value = try self.parseStringValue(config, value_str);

        if (std.mem.eql(u8, key, "type")) {
            config.source.type = value;
        }
    }

    fn parseSinkValue(self: *ConfigParser, config: *Config, key: []const u8, value_str: []const u8) !void {
        const value = try self.parseStringValue(config, value_str);

        if (std.mem.eql(u8, key, "type")) {
            config.sink.type = value;
        }
    }

    fn parsePostgresValue(self: *ConfigParser, config: *Config, key: []const u8, value_str: []const u8) !void {
        if (config.source.postgres == null) {
            config.source.postgres = PostgresSource{
                .engine = .streaming, // Default to streaming
                .host = "localhost",
                .port = 5432,
                .database = "outboxx_test",
                .user = "postgres",
                .password_env = "POSTGRES_PASSWORD",
                .slot_name = "outboxx_slot",
                .publication_name = "outboxx_publication",
            };
        }

        var postgres = &config.source.postgres.?;

        if (std.mem.eql(u8, key, "engine")) {
            const engine_str = try self.parseStringValue(config, value_str);
            postgres.engine = SourceEngine.fromString(engine_str) catch blk: {
                std.log.warn("Invalid postgres.engine value '{s}', using default 'streaming'", .{engine_str});
                break :blk .streaming;
            };
        } else if (std.mem.eql(u8, key, "host")) {
            postgres.host = try self.parseStringValue(config, value_str);
        } else if (std.mem.eql(u8, key, "port")) {
            postgres.port = self.parseIntValue(u16, value_str) catch |err| {
                std.log.warn("Invalid postgres.port value '{s}': {}, using default 5432", .{ value_str, err });
                return err;
            };
        } else if (std.mem.eql(u8, key, "database")) {
            postgres.database = try self.parseStringValue(config, value_str);
        } else if (std.mem.eql(u8, key, "user")) {
            postgres.user = try self.parseStringValue(config, value_str);
        } else if (std.mem.eql(u8, key, "password_env")) {
            postgres.password_env = try self.parseStringValue(config, value_str);
        } else if (std.mem.eql(u8, key, "slot_name")) {
            postgres.slot_name = try self.parseStringValue(config, value_str);
        } else if (std.mem.eql(u8, key, "publication_name")) {
            postgres.publication_name = try self.parseStringValue(config, value_str);
        }
    }

    fn parseMysqlValue(self: *ConfigParser, config: *Config, key: []const u8, value_str: []const u8) !void {
        if (config.source.mysql == null) {
            config.source.mysql = MysqlSource{
                .host = "localhost",
                .port = 3306,
                .database = "myapp",
                .user = "root",
                .password_env = "MYSQL_PASSWORD",
                .server_id = 1,
                .binlog_format = "ROW",
            };
        }

        var mysql = &config.source.mysql.?;

        if (std.mem.eql(u8, key, "host")) {
            mysql.host = try self.parseStringValue(config, value_str);
        } else if (std.mem.eql(u8, key, "port")) {
            mysql.port = self.parseIntValue(u16, value_str) catch |err| {
                std.log.warn("Invalid mysql.port value '{s}': {}, using default 3306", .{ value_str, err });
                return err;
            };
        } else if (std.mem.eql(u8, key, "database")) {
            mysql.database = try self.parseStringValue(config, value_str);
        } else if (std.mem.eql(u8, key, "user")) {
            mysql.user = try self.parseStringValue(config, value_str);
        } else if (std.mem.eql(u8, key, "password_env")) {
            mysql.password_env = try self.parseStringValue(config, value_str);
        } else if (std.mem.eql(u8, key, "server_id")) {
            mysql.server_id = self.parseIntValue(u32, value_str) catch |err| {
                std.log.warn("Invalid mysql.server_id value '{s}': {}, using default 1", .{ value_str, err });
                return err;
            };
        } else if (std.mem.eql(u8, key, "binlog_format")) {
            mysql.binlog_format = try self.parseStringValue(config, value_str);
        }
    }

    fn parseKafkaValue(self: *ConfigParser, config: *Config, key: []const u8, value_str: []const u8) !void {
        if (config.sink.kafka == null) {
            config.sink.kafka = KafkaSink{
                .brokers = &[_][]const u8{},
                .brokers_allocated = false,
            };
        }

        var kafka = &config.sink.kafka.?;

        if (std.mem.eql(u8, key, "brokers")) {
            kafka.brokers = try self.parseStringArray(value_str);
            kafka.brokers_allocated = true;
        }
    }

    fn parseIntValue(self: *ConfigParser, comptime T: type, value_str: []const u8) !T {
        _ = self;

        const clean_str = std.mem.trim(u8, value_str, " \t\"");
        return std.fmt.parseInt(T, clean_str, 10);
    }

    fn parseStringArray(self: *ConfigParser, value_str: []const u8) ![]const []const u8 {
        // Remove comments first
        const comment_pos = std.mem.indexOf(u8, value_str, "#");
        const value_without_comment = if (comment_pos) |pos|
            std.mem.trim(u8, value_str[0..pos], " \t")
        else
            value_str;

        // Simple array parsing for ["item1", "item2"]
        const clean_str = std.mem.trim(u8, value_without_comment, " \t");

        if (clean_str.len < 2 or clean_str[0] != '[' or clean_str[clean_str.len - 1] != ']') {
            return &[_][]const u8{};
        }

        const array_content = clean_str[1 .. clean_str.len - 1];

        // Handle empty array
        if (array_content.len == 0) {
            return &[_][]const u8{};
        }

        // Count commas to estimate size
        var count: usize = 1;
        for (array_content) |c| {
            if (c == ',') count += 1;
        }

        // Allocate array for items
        const items = try self.allocator.alloc([]const u8, count);
        var item_index: usize = 0;

        var parts = std.mem.splitSequence(u8, array_content, ",");
        while (parts.next()) |part| {
            const trimmed_part = std.mem.trim(u8, part, " \t\"");
            if (trimmed_part.len > 0 and item_index < items.len) {
                // Duplicate the string so it stays valid
                items[item_index] = try self.allocator.dupe(u8, trimmed_part);
                item_index += 1;
            }
        }

        // Resize to actual count
        return self.allocator.realloc(items, item_index);
    }

    fn parseStreamValue(
        self: *ConfigParser,
        stream: *Stream,
        subsection: ?[]const u8,
        key: []const u8,
        value_str: []const u8,
        config: *Config,
    ) !void {
        if (subsection == null) {
            // Direct stream properties
            if (std.mem.eql(u8, key, "name")) {
                stream.name = try self.parseStringValue(config, value_str);
            }
        } else if (std.mem.eql(u8, subsection.?, "source")) {
            // Stream source properties
            if (std.mem.eql(u8, key, "resource")) {
                stream.source.resource = try self.parseStringValue(config, value_str);
            } else if (std.mem.eql(u8, key, "operations")) {
                stream.source.operations = try self.parseStringArray(value_str);
            }
        } else if (std.mem.eql(u8, subsection.?, "flow")) {
            // Stream flow properties
            if (std.mem.eql(u8, key, "format")) {
                stream.flow.format = try self.parseStringValue(config, value_str);
            }
        } else if (std.mem.eql(u8, subsection.?, "sink")) {
            // Stream sink properties
            if (std.mem.eql(u8, key, "destination")) {
                stream.sink.destination = try self.parseStringValue(config, value_str);
            } else if (std.mem.eql(u8, key, "routing_key")) {
                stream.sink.routing_key = try self.parseStringValue(config, value_str);
            }
        }
    }

    fn parseStringValue(self: *ConfigParser, target: anytype, value_str: []const u8) ![]const u8 {
        // Remove comments first
        const comment_pos = std.mem.indexOf(u8, value_str, "#");
        const value_without_comment = if (comment_pos) |pos|
            std.mem.trim(u8, value_str[0..pos], " \t")
        else
            value_str;

        // Remove quotes if present
        const clean_value = if (value_without_comment.len >= 2 and value_without_comment[0] == '"' and value_without_comment[value_without_comment.len - 1] == '"')
            value_without_comment[1 .. value_without_comment.len - 1]
        else
            value_without_comment;

        // Make owned copy of the string
        const owned_string = try self.allocator.dupe(u8, clean_value);

        // Track for cleanup based on target type
        if (@TypeOf(target) == *Config) {
            const config = target;
            // Track for cleanup - grow array if needed
            if (config.allocated_count >= config.allocated_strings.len) {
                const new_size = if (config.allocated_strings.len == 0) 10 else config.allocated_strings.len * 2;
                config.allocated_strings = try config.allocator.realloc(config.allocated_strings, new_size);
            }
            config.allocated_strings[config.allocated_count] = owned_string;
            config.allocated_count += 1;
        }

        return owned_string;
    }
};
