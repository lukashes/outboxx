const std = @import("std");
const WalReader = @import("../wal/reader.zig").WalReader;
const WalEvent = @import("../wal/reader.zig").WalEvent;
const WalReaderError = @import("../wal/reader.zig").WalReaderError;
const KafkaProducer = @import("../kafka/producer.zig").KafkaProducer;
const StructuredWalMessageParser = @import("message.zig").StructuredWalMessageParser;
const KafkaConfig = @import("../config/config.zig").KafkaSink;
const Stream = @import("../config/config.zig").Stream;

pub const CdcProcessor = struct {
    allocator: std.mem.Allocator,
    wal_reader: WalReader,
    kafka_producer: ?KafkaProducer,
    structured_parser: StructuredWalMessageParser,
    kafka_config: KafkaConfig,
    stream_config: Stream,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, slot_name: []const u8, publication_name: []const u8, kafka_config: KafkaConfig, stream_config: Stream) Self {
        return Self{
            .allocator = allocator,
            .wal_reader = WalReader.init(allocator, slot_name, publication_name, stream_config.source.resource),
            .kafka_producer = null,
            .structured_parser = StructuredWalMessageParser.init(allocator),
            .kafka_config = kafka_config,
            .stream_config = stream_config,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.kafka_producer) |*producer| {
            producer.deinit();
        }
        self.wal_reader.deinit();
        self.structured_parser.deinit();
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

        std.log.info("Processing {} WAL events", .{events.items.len});

        for (events.items) |event| {
            std.log.debug("Processing WAL event: {s}", .{event.data});
            std.log.debug("Stream config - resource: {s}, sink: {s}", .{ self.stream_config.source.resource, self.stream_config.sink.destination });

            // Parse WAL event into structured message using new parser
            if (self.structured_parser.parseWalMessage(event.data, "postgres", self.stream_config.source.resource)) |message_opt| {
                if (message_opt) |msg| {
                    std.log.debug("Successfully parsed WAL message for operation: {s}", .{msg.op});

                    // Make mutable copy
                    var message = msg;
                    defer message.deinit(self.allocator);

                    // Filtering already done in parseWalMessage, so if message returned - it matches

                    // Convert to JSON using new structured format (op/data/meta)
                    const json_message = message.toJson(self.allocator) catch |err| {
                        std.log.err("Failed to serialize message to JSON: {}", .{err});
                        continue;
                    };
                    defer self.allocator.free(json_message);
                    std.log.debug("Generated JSON: {s}", .{json_message});

                    // Get topic name from stream config
                    const topic_name = self.allocator.dupe(u8, self.stream_config.sink.destination) catch |err| {
                        std.log.err("Failed to allocate topic name: {}", .{err});
                        continue;
                    };
                    defer self.allocator.free(topic_name);

                    // Get partition key from stream config (fallback to resource name if routing_key is null)
                    const partition_key = if (self.stream_config.sink.routing_key) |key|
                        self.allocator.dupe(u8, key) catch |err| {
                            std.log.err("Failed to allocate partition key: {}", .{err});
                            continue;
                        }
                    else
                        message.getPartitionKey(self.allocator) catch |err| {
                            std.log.err("Failed to generate partition key: {}", .{err});
                            continue;
                        };
                    defer self.allocator.free(partition_key);

                    // Send to Kafka
                    std.log.debug("About to send to Kafka - topic: {s}, partition_key: {s}", .{ topic_name, partition_key });
                    kafka_producer.sendMessage(topic_name, partition_key, json_message) catch |err| {
                        std.log.err("Failed to send message to Kafka: {}", .{err});
                        continue;
                    };
                    std.log.debug("Successfully sent message to Kafka", .{});

                    std.log.info("Sent {s} message for {s}.{s}", .{ message.op, message.meta.schema, message.meta.resource });
                } else {
                    std.log.debug("Parser returned null for WAL event (filtered out or not recognized)", .{});
                }
            } else |err| {
                std.log.err("Failed to parse WAL message: {}", .{err});
                continue;
            }
        }

        // Flush Kafka producer to ensure messages are sent
        kafka_producer.flush(10_000); // 10 seconds timeout
        std.log.info("Flushed messages to Kafka", .{});
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
