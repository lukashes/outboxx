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

// Kafka flush timeout: 30 seconds is a balance between:
// - Allowing enough time for Kafka brokers to acknowledge messages
// - Not blocking CDC processing for too long on Kafka issues
const KAFKA_FLUSH_TIMEOUT_MS: i32 = 30_000;

pub const CdcProcessor = struct {
    allocator: std.mem.Allocator,
    wal_reader: WalReader,
    kafka_producer: ?KafkaProducer,
    kafka_config: KafkaConfig,
    stream_config: Stream,
    wal_parser: WalParser,
    serializer: JsonSerializer,

    last_sent_lsn: ?[]const u8,

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
            .last_sent_lsn = null,
        };
    }

    pub fn shutdown(self: *Self) void {
        std.log.info("Shutting down stream {s} processor...", .{self.stream_config.name});

        self.flushAndCommit() catch |err| {
            std.log.err("Failed to flush and commit on shutdown: {}", .{err});
        };

        std.log.info("...Finished", .{});
    }

    pub fn deinit(self: *Self) void {
        if (self.last_sent_lsn) |lsn| {
            self.allocator.free(lsn);
        }
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

        // Test Kafka connection at startup (fail-fast if unavailable)
        var producer = &self.kafka_producer.?;
        producer.testConnection() catch |err| {
            std.log.err("Kafka connection test failed: {}", .{err});
            return WalReaderError.ConnectionFailed;
        };

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

    pub fn flushAndCommit(self: *Self) WalReaderError!void {
        if (self.last_sent_lsn == null) {
            return;
        }

        var kafka_producer = &(self.kafka_producer orelse return WalReaderError.ConnectionFailed);

        std.log.debug("Flushing Kafka messages (timeout: {}ms)...", .{KAFKA_FLUSH_TIMEOUT_MS});
        kafka_producer.flush(KAFKA_FLUSH_TIMEOUT_MS);

        const lsn = self.last_sent_lsn.?;
        std.log.debug("Committing WAL position to LSN: {s}", .{lsn});
        try self.wal_reader.advanceSlot(lsn);

        std.log.debug("Successfully committed LSN: {s}", .{lsn});
    }

    pub fn processChangesToKafka(self: *Self, limit: u32) WalReaderError!void {
        // Always peek from current slot position
        var events = try self.wal_reader.peekChanges(limit);
        defer {
            for (events.items) |*event| {
                event.deinit(self.allocator);
            }
            events.deinit(self.allocator);
        }

        // If no events, nothing to do
        if (events.items.len == 0) {
            return;
        }

        var kafka_producer = &(self.kafka_producer orelse return WalReaderError.ConnectionFailed);

        // Process entire batch asynchronously
        for (events.items) |wal_event| {
            // Track LSN for ALL events (including BEGIN/COMMIT)
            // This ensures slot advances even if batch has no parseable events
            const new_lsn = try self.allocator.dupe(u8, wal_event.lsn);
            if (self.last_sent_lsn) |old_lsn| {
                self.allocator.free(old_lsn);
            }
            self.last_sent_lsn = new_lsn;

            // Try to parse and send to Kafka
            if (self.wal_parser.parse(wal_event.data, "postgres", self.stream_config.source.resource)) |change_event_opt| {
                if (change_event_opt) |domain_event| {
                    var event = domain_event;
                    defer event.deinit(self.allocator);

                    const json_bytes = self.serializer.serialize(event, self.allocator) catch |err| {
                        std.log.err("Failed to serialize message to JSON: {}", .{err});
                        continue;
                    };
                    defer self.allocator.free(json_bytes);

                    const partition_key_field = self.stream_config.sink.routing_key orelse "id";
                    const partition_key = if (event.getPartitionKeyValue(self.allocator, partition_key_field)) |key_opt| blk: {
                        if (key_opt) |key| {
                            break :blk key;
                        } else {
                            break :blk try self.allocator.dupe(u8, event.meta.resource);
                        }
                    } else |_| blk: {
                        break :blk try self.allocator.dupe(u8, event.meta.resource);
                    };
                    defer self.allocator.free(partition_key);

                    const topic_name = self.stream_config.sink.destination;

                    kafka_producer.sendMessage(topic_name, partition_key, json_bytes) catch |err| {
                        std.log.err("Failed to send message to Kafka: {}", .{err});
                        continue;
                    };

                    std.log.debug("Sent {s} message for {s}.{s} (partition key: {s})", .{ event.op, event.meta.schema, event.meta.resource, partition_key });
                }
            } else |err| {
                std.log.warn("Skipped WAL event (parse error): {}", .{err});
            }
        }

        // Flush and commit after processing entire batch
        if (self.last_sent_lsn != null) {
            try self.flushAndCommit();
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
