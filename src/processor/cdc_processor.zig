const std = @import("std");
const WalReader = @import("../source/postgres/wal_reader.zig").WalReader;
const WalEvent = @import("../source/postgres/wal_reader.zig").WalEvent;
const WalReaderError = @import("../source/postgres/wal_reader.zig").WalReaderError;
const KafkaProducer = @import("../kafka/producer.zig").KafkaProducer;
const KafkaConfig = @import("../config/config.zig").KafkaSink;
const Stream = @import("../config/config.zig").Stream;

// New architecture imports
const domain = @import("domain");
const ChangeEvent = domain.ChangeEvent;
const postgres_parser = @import("postgres_wal_parser");
const WalParser = postgres_parser.WalParser;
const json_serializer = @import("json_serialization");
const JsonSerializer = json_serializer.JsonSerializer;

pub const CdcProcessor = struct {
    allocator: std.mem.Allocator,
    wal_reader: WalReader,
    kafka_producer: ?KafkaProducer,
    kafka_config: KafkaConfig,
    stream_config: Stream,
    wal_parser: WalParser,
    serializer: JsonSerializer,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, slot_name: []const u8, publication_name: []const u8, kafka_config: KafkaConfig, stream_config: Stream) Self {
        return Self{
            .allocator = allocator,
            .wal_reader = WalReader.init(allocator, slot_name, publication_name, stream_config.source.resource),
            .kafka_producer = null,
            .kafka_config = kafka_config,
            .stream_config = stream_config,
            .wal_parser = WalParser.init(allocator),
            .serializer = JsonSerializer.init(),
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.kafka_producer) |*producer| {
            producer.deinit();
        }
        self.wal_reader.deinit();
        self.wal_parser.deinit();
    }

    pub fn initialize(self: *Self, connection_string: []const u8) WalReaderError!void {
        // Initialize WAL reader (connect + create publication + create slot)
        try self.wal_reader.initialize(connection_string);

        // Initialize Kafka producer
        // Join brokers array into a single comma-separated string
        const brokers_str = try std.mem.join(self.allocator, ",", self.kafka_config.brokers);
        defer self.allocator.free(brokers_str);

        self.kafka_producer = KafkaProducer.init(self.allocator, brokers_str) catch |err| {
            std.log.err("Failed to initialize Kafka producer: {}", .{err});
            return WalReaderError.ConnectionFailed;
        };
        self.kafka_producer.?.flush(10_000); // Initial flush to ensure connection

        std.log.info("CDC processor initialized successfully", .{});
    }

    // Keep connect method for backward compatibility
    pub fn connect(self: *Self, connection_string: []const u8) WalReaderError!void {
        return self.initialize(connection_string);
    }

    pub fn createSlot(self: *Self) WalReaderError!void {
        return self.wal_reader.createSlot();
    }

    pub fn dropSlot(self: *Self) WalReaderError!void {
        return self.wal_reader.dropSlot();
    }

    pub fn processChangesToKafka(self: *Self, limit: u32) WalReaderError!void {
        // Read WAL changes
        var events = try self.wal_reader.readChanges(limit);
        defer {
            for (events.items) |*event| {
                event.deinit(self.allocator);
            }
            events.deinit(self.allocator);
        }

        var kafka_producer = &(self.kafka_producer orelse return WalReaderError.ConnectionFailed);

        if (events.items.len > 0) {
            std.log.info("Processing {} WAL events", .{events.items.len});
        }

        for (events.items) |wal_event| {
            // Parse WAL event into domain model using new architecture
            if (self.wal_parser.parse(wal_event.data, "postgres", self.stream_config.source.resource)) |change_event_opt| {
                if (change_event_opt) |domain_event| {
                    var event = domain_event;
                    defer event.deinit(self.allocator);

                    // Serialize domain event to JSON
                    const json_bytes = self.serializer.serialize(event, self.allocator) catch |err| {
                        std.log.err("Failed to serialize message to JSON: {}", .{err});
                        continue;
                    };
                    defer self.allocator.free(json_bytes);

                    // Extract partition key value from event data
                    const partition_key_field = self.stream_config.sink.routing_key orelse "id";
                    const partition_key = if (event.getPartitionKeyValue(self.allocator, partition_key_field)) |key_opt| blk: {
                        if (key_opt) |key| {
                            break :blk key;
                        } else {
                            // Field not found or complex type - fallback to table name
                            break :blk try self.allocator.dupe(u8, event.meta.resource);
                        }
                    } else |_| blk: {
                        // Error getting key - fallback to table name
                        break :blk try self.allocator.dupe(u8, event.meta.resource);
                    };
                    defer self.allocator.free(partition_key);

                    // Extract topic name from config
                    const topic_name = self.stream_config.sink.destination;

                    // Send to Kafka
                    kafka_producer.sendMessage(topic_name, partition_key, json_bytes) catch |err| {
                        std.log.err("Failed to send message to Kafka: {}", .{err});
                        continue;
                    };

                    std.log.info("Sent {s} message for {s}.{s} (partition key: {s})", .{ event.op, event.meta.schema, event.meta.resource, partition_key });
                }
            } else |err| {
                std.log.err("Failed to parse WAL message: {}", .{err});
                continue;
            }
        }

        // Flush Kafka producer to ensure messages are sent
        if (events.items.len > 0) {
            kafka_producer.flush(10_000); // 10 seconds timeout
        }
    }

    pub fn startStreaming(self: *Self) !void {
        std.log.info("Starting CDC streaming from PostgreSQL to Kafka", .{});

        while (true) {
            self.processChangesToKafka(100) catch |err| {
                std.log.err("Error in streaming: {}", .{err});
                // Continue streaming even if there's an error
            };

            // Sleep between polls
            std.Thread.sleep(1 * std.time.ns_per_s); // 10 seconds
        }
    }
};
