const std = @import("std");

const PostgresSource = @import("postgres_source").PostgresSource;
const Batch = @import("postgres_source").Batch;

const KafkaProducer = @import("kafka_producer").KafkaProducer;
const Stream = @import("config").Stream;

const domain = @import("domain");
const ChangeEvent = domain.ChangeEvent;
const json_serializer = @import("json_serialization");
const JsonSerializer = json_serializer.JsonSerializer;
const constants = @import("constants");
pub const Observability = @import("observability").Observability;

/// Return the streams whose resource and operations match a given table change; caller owns the list.
pub fn matchStreams(allocator: std.mem.Allocator, streams: []const Stream, table_name: []const u8, operation: []const u8) !std.ArrayList(Stream) {
    var matched = std.ArrayList(Stream).empty;

    for (streams) |stream| {
        if (!std.mem.eql(u8, stream.source.resource, table_name)) {
            continue;
        }

        for (stream.source.operations) |op| {
            if (std.ascii.eqlIgnoreCase(op, operation)) {
                try matched.append(allocator, stream);
                break;
            }
        }
    }

    return matched;
}

fn flushCommitWorker(
    io: std.Io,
    producer: *KafkaProducer,
    source: *PostgresSource,
    pending_lsn: *std.atomic.Value(u64),
    confirmed_lsn: *std.atomic.Value(u64),
) void {
    var iterations: u32 = 0;
    const flush_interval_iterations: u32 = @intCast(constants.CDC.KAFKA_FLUSH_INTERVAL_SEC);

    while (true) {
        // The worker's only cancelation point: on shutdown the future is
        // canceled, this returns error.Canceled, and we break to the final flush.
        io.sleep(.fromSeconds(1), .awake) catch break;
        iterations += 1;

        if (iterations < flush_interval_iterations) {
            continue;
        }

        iterations = 0;

        producer.flush(constants.CDC.KAFKA_FLUSH_TIMEOUT_MS) catch |err| {
            std.log.err("Background flush failed: {}", .{err});
            continue;
        };

        const lsn = pending_lsn.load(.acquire);
        if (lsn == 0) {
            continue;
        }

        source.sendFeedback(io, lsn) catch |err| {
            std.log.err("Background LSN commit failed: {}", .{err});
            continue;
        };
        // Latest LSN acknowledged to Postgres; the replication-lag gauge reads it.
        confirmed_lsn.store(lsn, .release);
    }

    producer.flush(constants.CDC.KAFKA_FLUSH_TIMEOUT_MS) catch |err| {
        std.log.warn("Final background flush failed: {}", .{err});
    };

    const lsn = pending_lsn.load(.acquire);
    if (lsn > 0) {
        source.sendFeedback(io, lsn) catch |err| {
            std.log.warn("Final background LSN commit failed: {}", .{err});
        };
        confirmed_lsn.store(lsn, .release);
    }

    std.log.debug("Flush/commit worker stopped", .{});
}

/// CDC Processor that works with PostgreSQL streaming replication
pub const Processor = struct {
    allocator: std.mem.Allocator,
    source: PostgresSource,
    producer: KafkaProducer,
    streams: []const Stream,
    serializer: JsonSerializer,
    obs: *Observability,

    events_processed: usize,
    pending_lsn: std.atomic.Value(u64),
    // LSN last confirmed to Postgres by the flush worker; drives the lag gauge.
    confirmed_lsn: std.atomic.Value(u64),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, source: PostgresSource, producer: KafkaProducer, streams: []const Stream, obs: *Observability) Self {
        return Self{
            .allocator = allocator,
            .source = source,
            .producer = producer,
            .streams = streams,
            .serializer = JsonSerializer.init(),
            .obs = obs,
            .events_processed = 0,
            .pending_lsn = std.atomic.Value(u64).init(0),
            .confirmed_lsn = std.atomic.Value(u64).init(0),
        };
    }

    pub fn deinit(self: *Self) void {
        self.producer.deinit();
        self.source.deinit();
    }

    /// Receive one batch, route each change to its streams, and stage the batch LSN for commit.
    pub fn processChangesToKafka(self: *Self, io: std.Io, batch_allocator: std.mem.Allocator, limit: u32) !void {
        var batch = self.source.receiveBatch(io, batch_allocator, limit) catch |err| {
            switch (err) {
                error.DecodeFailed, error.ConversionFailed => self.obs.recordDecodeError(),
                else => {},
            }
            return err;
        };
        defer batch.deinit();

        // A successful receive (even an empty batch) means we are connected and
        // reading the replication stream — the signal readiness cares about.
        self.obs.markStreaming();

        const producer = &self.producer;

        if (batch.changes.len == 0) {
            self.pending_lsn.store(batch.last_lsn, .release);
            self.obs.setLag(batch.last_lsn, self.confirmed_lsn.load(.acquire));
            return;
        }

        std.log.debug("Processing {} changes from batch (LSN: {})", .{ batch.changes.len, batch.last_lsn });

        // Count consumed WAL changes and refresh the lag gauge once per batch.
        self.obs.addEvents(batch.changes.len);
        self.obs.setLag(batch.last_lsn, self.confirmed_lsn.load(.acquire));

        for (batch.changes) |change_event| {
            var matched = try matchStreams(batch_allocator, self.streams, change_event.meta.resource, change_event.op);
            defer matched.deinit(batch_allocator);

            if (matched.items.len == 0) {
                std.log.debug("No matching streams for {s}.{s} ({s})", .{
                    change_event.meta.schema,
                    change_event.meta.resource,
                    change_event.op,
                });
                continue;
            }

            const json_bytes = try self.serializer.serialize(change_event, batch_allocator);

            for (matched.items) |stream| {
                const topic_name = stream.sink.destination;
                const partition_key = try self.getPartitionKey(batch_allocator, change_event, stream);

                producer.sendMessage(topic_name, partition_key, json_bytes) catch |err| {
                    self.obs.recordProduceError();
                    return err;
                };

                self.events_processed += 1;
                if (self.events_processed % 10000 == 0) {
                    std.log.info("Processed {} CDC events", .{self.events_processed});
                }

                std.log.debug("Sent {s} message for {s}.{s} to topic '{s}' (key: {s})", .{
                    change_event.op,
                    change_event.meta.schema,
                    change_event.meta.resource,
                    topic_name,
                    partition_key,
                });
            }
        }

        producer.poll();

        self.pending_lsn.store(batch.last_lsn, .release);
    }

    fn getPartitionKey(
        self: *Self,
        allocator: std.mem.Allocator,
        change_event: ChangeEvent,
        stream: Stream,
    ) ![]const u8 {
        _ = self;

        const key_field = stream.sink.routing_key orelse "id";

        if (change_event.getPartitionKeyValue(allocator, key_field)) |key_opt| {
            if (key_opt) |key| {
                return key;
            }
        } else |_| {}

        return try allocator.dupe(u8, change_event.meta.resource);
    }

    /// Run the batch loop until stop_signal is set, with a background flush/commit worker.
    pub fn startStreaming(self: *Self, io: std.Io, stop_signal: *std.atomic.Value(bool)) !void {
        const producer = &self.producer;

        // Background flush/commit loop. `concurrent` not `async`: it must run
        // alongside the receive loop, and `async` may defer the call until await.
        var flush_future = try io.concurrent(flushCommitWorker, .{
            io,
            producer,
            &self.source,
            &self.pending_lsn,
            &self.confirmed_lsn,
        });
        // On a receive error, still stop the worker (wakes its sleep for the
        // final flush, and awaits) before the error propagates.
        errdefer flush_future.cancel(io);

        while (!stop_signal.load(.monotonic)) {
            self.obs.heartbeat(io);

            var batch_arena = std.heap.ArenaAllocator.init(self.allocator);
            defer batch_arena.deinit();

            const batch_alloc = batch_arena.allocator();

            try self.processChangesToKafka(io, batch_alloc, constants.CDC.BATCH_SIZE);
        }

        // Graceful stop: cancel and await the worker (runs its final flush/commit)
        // before reporting the stream stopped.
        flush_future.cancel(io);
        std.log.info("Streaming stopped gracefully", .{});
    }
};
