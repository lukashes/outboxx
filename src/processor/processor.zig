const std = @import("std");

const PostgresSource = @import("postgres_source").PostgresSource;
const Batch = @import("postgres_source").Batch;

const KafkaProducer = @import("kafka_producer").KafkaProducer;
const config_module = @import("config");
const KafkaConfig = config_module.KafkaSink;
const Stream = config_module.Stream;

const domain = @import("domain");
const ChangeEvent = domain.ChangeEvent;
const json_serializer = @import("json_serialization");
const JsonSerializer = json_serializer.JsonSerializer;
const constants = @import("constants");

pub const ProcessorError = error{
    ConnectionFailed,
    InitializationFailed,
    OutOfMemory,
};

pub fn matchStreams(allocator: std.mem.Allocator, streams: []const Stream, table_name: []const u8, operation: []const u8) std.ArrayList(Stream) {
    var matched = std.ArrayList(Stream).empty;

    for (streams) |stream| {
        if (!std.mem.eql(u8, stream.source.resource, table_name)) {
            continue;
        }

        var operation_matched = false;
        for (stream.source.operations) |op| {
            if (std.ascii.eqlIgnoreCase(op, operation)) {
                operation_matched = true;
                break;
            }
        }

        if (operation_matched) {
            matched.append(allocator, stream) catch continue;
        }
    }

    return matched;
}

/// CDC Processor that works with PostgreSQL streaming replication
pub const Processor = struct {
    allocator: std.mem.Allocator,
    source: PostgresSource,
    kafka_producer: ?KafkaProducer,
    kafka_config: KafkaConfig,
    streams: []const Stream,
    serializer: JsonSerializer,

    events_processed: usize,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, source: PostgresSource, streams: []const Stream, kafka_config: KafkaConfig) Self {
        return Self{
            .allocator = allocator,
            .source = source,
            .kafka_producer = null,
            .kafka_config = kafka_config,
            .streams = streams,
            .serializer = JsonSerializer.init(),
            .events_processed = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.kafka_producer) |*producer| {
            producer.deinit();
        }
        self.source.deinit();
    }

    pub fn initialize(self: *Self) ProcessorError!void {
        const brokers_str = try std.mem.join(self.allocator, ",", self.kafka_config.brokers);
        defer self.allocator.free(brokers_str);

        self.kafka_producer = KafkaProducer.init(self.allocator, brokers_str) catch |err| {
            std.log.warn("Failed to initialize Kafka producer: {}", .{err});
            return ProcessorError.ConnectionFailed;
        };

        // Test Kafka connection at startup (fail-fast if unavailable)
        var producer = &self.kafka_producer.?;
        producer.testConnection() catch |err| {
            std.log.warn("Kafka connection test failed: {}", .{err});
            return ProcessorError.ConnectionFailed;
        };

        std.log.info("Processor initialized successfully", .{});
    }

    pub fn processChangesToKafka(self: *Self, batch_allocator: std.mem.Allocator, limit: u32) anyerror!void {
        var batch = try self.source.receiveBatch(batch_allocator, limit);
        defer batch.deinit();

        // If no events, confirm last LSN and return (avoid re-reading same events)
        if (batch.changes.len == 0) {
            if (batch.last_lsn > 0) {
                try self.source.sendFeedback(batch.last_lsn);
            }
            return;
        }

        var kafka_producer = &(self.kafka_producer orelse return ProcessorError.ConnectionFailed);

        std.log.debug("Processing {} changes from batch (LSN: {})", .{ batch.changes.len, batch.last_lsn });

        for (batch.changes, 0..) |change_event, batch_index| {
            var matched_streams = matchStreams(batch_allocator, self.streams, change_event.meta.resource, change_event.op);
            defer matched_streams.deinit(batch_allocator);

            if (matched_streams.items.len == 0) {
                std.log.debug("No matching streams for {s}.{s} ({s})", .{ change_event.meta.schema, change_event.meta.resource, change_event.op });
                continue;
            }

            // Serialize once, send to all matching streams
            const json_bytes = try self.serializer.serialize(change_event, batch_allocator);
            defer batch_allocator.free(json_bytes);

            for (matched_streams.items) |stream| {
                const partition_key_field = stream.sink.routing_key orelse "id";
                const partition_key = if (change_event.getPartitionKeyValue(batch_allocator, partition_key_field)) |key_opt| blk: {
                    if (key_opt) |key| {
                        break :blk key;
                    } else {
                        break :blk try batch_allocator.dupe(u8, change_event.meta.resource);
                    }
                } else |_| blk: {
                    break :blk try batch_allocator.dupe(u8, change_event.meta.resource);
                };
                defer batch_allocator.free(partition_key);

                const topic_name = stream.sink.destination;

                try kafka_producer.sendMessage(topic_name, partition_key, json_bytes);

                self.events_processed += 1;

                if (self.events_processed % 10000 == 0) {
                    std.log.info("Processed {} CDC events", .{self.events_processed});
                }

                std.log.debug("Sent {s} message for {s}.{s} to topic '{s}' (partition key: {s})", .{ change_event.op, change_event.meta.schema, change_event.meta.resource, topic_name, partition_key });
            }

            // Poll every N messages to process callbacks and send queued messages
            if (batch_index > 0 and batch_index % constants.CDC.KAFKA_POLL_INTERVAL == 0) {
                kafka_producer.poll();
            }
        }

        // Final poll before flush to process any remaining callbacks
        kafka_producer.poll();

        // CRITICAL: Kafka flush BEFORE LSN feedback (no data loss guarantee)
        try kafka_producer.flush(constants.CDC.KAFKA_FLUSH_TIMEOUT_MS);

        // Confirm LSN to PostgreSQL ONLY after Kafka flush succeeds
        try self.source.sendFeedback(batch.last_lsn);

        std.log.debug("Successfully committed LSN: {}", .{batch.last_lsn});
    }

    pub fn startStreaming(self: *Self, stop_signal: *std.atomic.Value(bool)) !void {
        while (!stop_signal.load(.monotonic)) {
            // Create arena for this batch (all temporary allocations freed at end of iteration)
            var batch_arena = std.heap.ArenaAllocator.init(self.allocator);
            defer batch_arena.deinit();

            const batch_alloc = batch_arena.allocator();

            // Fail-fast: any error propagates up → app exits → supervisor restarts
            try self.processChangesToKafka(batch_alloc, constants.CDC.BATCH_SIZE);

            // No sleep needed - receiveBatchWithTimeout() blocks on poll() when no data
            // batch_arena.deinit() automatically called here - frees ALL batch allocations
        }

        std.log.info("Streaming stopped gracefully", .{});
    }
};
