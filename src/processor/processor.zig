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

// Per-batch tally of routed change events by stream and operation, so the events
// counter is updated once per distinct combo instead of once per routed change.
const EventCount = struct { stream: []const u8, operation: []const u8, count: u64 };

fn tallyEvent(list: *std.ArrayList(EventCount), allocator: std.mem.Allocator, stream: []const u8, operation: []const u8) !void {
    for (list.items) |*e| {
        if (std.mem.eql(u8, e.stream, stream) and std.mem.eql(u8, e.operation, operation)) {
            e.count += 1;
            return;
        }
    }
    try list.append(allocator, .{ .stream = stream, .operation = operation, .count = 1 });
}

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

// Background worker: flush Kafka off the hot path and record how far we have
// flushed in flushed_lsn. It must NOT touch the Postgres connection -- libpq
// forbids using one PGconn from two threads, and the receive loop already owns
// it. The main thread reads flushed_lsn and confirms it to Postgres.
fn flushWorker(
    io: std.Io,
    producer: *KafkaProducer,
    pending_lsn: *std.atomic.Value(u64),
    flushed_lsn: *std.atomic.Value(u64),
    flush_interval_sec: u32,
) void {
    var iterations: u32 = 0;

    while (true) {
        // The worker's only cancelation point: on shutdown the future is
        // canceled, this returns error.Canceled, and we break to the final flush.
        io.sleep(.fromSeconds(1), .awake) catch break;
        iterations += 1;

        if (iterations < flush_interval_sec) {
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

        flushed_lsn.store(lsn, .release);
    }

    // No final flush on cancel: awaiting a flush into a wedged broker is what
    // hangs the shutdown. The graceful path flushes on the main thread instead;
    // on a fatal error we just exit.
    std.log.debug("Flush worker stopped", .{});
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
    // Staged by the main thread after producing a batch to Kafka's local queue.
    pending_lsn: std.atomic.Value(u64),
    // Set by the flush worker after a successful Kafka flush; read by the main
    // thread, which confirms it to Postgres. Keeps all libpq access single-threaded.
    flushed_lsn: std.atomic.Value(u64),
    // Seconds between background Kafka flushes. Defaults to the constant; tests
    // shorten it to exercise the periodic flush/commit path quickly.
    flush_interval_sec: u32,

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
            .flushed_lsn = std.atomic.Value(u64).init(0),
            .flush_interval_sec = @intCast(constants.CDC.KAFKA_FLUSH_INTERVAL_SEC),
        };
    }

    pub fn deinit(self: *Self) void {
        std.log.debug("processor.deinit: deinit producer", .{});
        self.producer.deinit();
        std.log.debug("processor.deinit: producer done, deinit source", .{});
        self.source.deinit();
        std.log.debug("processor.deinit: done", .{});
    }

    /// Receive one batch, route each change to its streams, and stage the batch LSN for commit.
    pub fn processChangesToKafka(self: *Self, io: std.Io, batch_allocator: std.mem.Allocator, limit: u32) !void {
        // Confirm how far the flush worker has flushed to Kafka; the source sends
        // it as standby feedback before reading the next batch.
        const confirmed_lsn = self.flushed_lsn.load(.acquire);
        var batch = try self.source.receiveBatch(io, batch_allocator, limit, confirmed_lsn);
        defer batch.deinit();

        // A successful receive (even an empty batch) means we are connected and
        // reading the replication stream — the signal readiness cares about.
        self.obs.markStreaming();

        const producer = &self.producer;

        if (batch.changes.len == 0) {
            self.pending_lsn.store(batch.last_lsn, .release);
            self.obs.setLag(0); // drained everything available -> caught up
            return;
        }

        std.log.debug("Processing {} changes from batch (LSN: {})", .{ batch.changes.len, batch.last_lsn });

        // Refresh lag once per batch; event counts are tallied per (stream, operation)
        // in the loop and emitted after it, so the counter costs one add() per distinct
        // combo per batch instead of one per routed change.
        self.obs.setLag(batch.replication_lag_seconds);
        var event_counts = std.ArrayList(EventCount).empty;
        defer event_counts.deinit(batch_allocator);

        for (batch.changes) |change_event| {
            var matched = try matchStreams(batch_allocator, self.streams, change_event.meta.resource, change_event.op);
            defer matched.deinit(batch_allocator);

            if (matched.items.len == 0) {
                continue;
            }

            const json_bytes = try self.serializer.serialize(change_event, batch_allocator);

            for (matched.items) |stream| {
                const topic_name = stream.sink.destination;
                const partition_key = try self.getPartitionKey(batch_allocator, change_event, stream);

                producer.sendMessage(topic_name, partition_key, json_bytes) catch |err| {
                    self.obs.recordProduceError();
                    std.log.debug("processChangesToKafka: sendMessage failed, propagating {} (fail-fast)", .{err});
                    return err;
                };

                try tallyEvent(&event_counts, batch_allocator, stream.name, change_event.op);

                self.events_processed += 1;
                if (self.events_processed % 10000 == 0) {
                    std.log.info("Processed {} CDC events", .{self.events_processed});
                }
            }
        }

        for (event_counts.items) |e| self.obs.addEvents(e.count, e.stream, e.operation);

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

    /// Run the batch loop until stop_signal is set, with a background Kafka flush worker.
    pub fn startStreaming(self: *Self, io: std.Io, stop_signal: *std.atomic.Value(bool)) !void {
        // The source is connected and validated before we get here, so readiness's
        // connection signal goes up now; markStreaming follows on the first batch.
        self.obs.markConnected(true);

        const producer = &self.producer;

        // Background flush loop. `concurrent` not `async`: it must run alongside
        // the receive loop, and `async` may defer the call until await. It only
        // touches Kafka; LSN feedback stays on this thread (see commitFlushed).
        var flush_future = try io.concurrent(flushWorker, .{
            io,
            producer,
            &self.pending_lsn,
            &self.flushed_lsn,
            self.flush_interval_sec,
        });
        // On a receive error, stop the worker before the error propagates (it uses
        // the producer, which processor.deinit destroys). The worker touches no
        // libpq and no longer flushes on cancel, so this returns promptly.
        errdefer {
            std.log.debug("startStreaming: error path, cancelling flush worker", .{});
            flush_future.cancel(io);
            std.log.debug("startStreaming: flush worker cancelled, propagating error", .{});
        }

        while (!stop_signal.load(.monotonic)) {
            self.obs.heartbeat(io);

            var batch_arena = std.heap.ArenaAllocator.init(self.allocator);
            defer batch_arena.deinit();

            const batch_alloc = batch_arena.allocator();

            try self.processChangesToKafka(io, batch_alloc, constants.CDC.BATCH_SIZE);
        }

        // Graceful stop: stop the worker, then flush everything staged and confirm
        // it, both on this thread. After a full flush pending_lsn is durable, so it
        // is safe to confirm (and covers the last batch the loop just produced).
        flush_future.cancel(io);
        producer.flush(constants.CDC.KAFKA_FLUSH_TIMEOUT_MS) catch |err| {
            std.log.warn("Final flush failed: {}", .{err});
        };
        const final_lsn = self.pending_lsn.load(.acquire);
        if (final_lsn > 0) {
            self.source.sendFeedback(io, final_lsn) catch |err| {
                std.log.warn("Final LSN feedback failed: {}", .{err});
            };
        }
        std.log.info("Streaming stopped gracefully", .{});
    }
};
