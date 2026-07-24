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

/// Return the streams whose resource and operations match a given change; caller owns the list.
pub fn matchStreams(allocator: std.mem.Allocator, streams: []const Stream, change: ChangeEvent) !std.ArrayList(Stream) {
    var matched = std.ArrayList(Stream).empty;

    // Streams target the public schema (startup validation enforces it), so a
    // change from any other schema must not match even when the table name
    // collides. Routing tables from other schemas is #50.
    if (!std.mem.eql(u8, change.meta.schema, "public")) return matched;

    for (streams) |stream| {
        if (!std.mem.eql(u8, stream.source.resource, change.meta.resource)) {
            continue;
        }

        for (stream.source.operations) |op| {
            if (std.ascii.eqlIgnoreCase(op, change.op)) {
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

        const lsn = pending_lsn.load(.acquire);
        if (lsn == 0) {
            continue;
        }

        producer.flush(constants.CDC.KAFKA_FLUSH_TIMEOUT_MS) catch |err| {
            std.log.err("Background flush failed: {}", .{err});
            continue;
        };

        // A drained queue is not a delivered queue: a message can leave it by
        // permanently failing. Hold the LSN if any did; the receive loop turns
        // this into a fail-fast.
        if (producer.deliveryErrorCount() > 0) {
            continue;
        }

        source.sendFeedback(io, lsn) catch |err| {
            std.log.err("Background LSN commit failed: {}", .{err});
            continue;
        };
    }

    const lsn = pending_lsn.load(.acquire);

    producer.flush(constants.CDC.KAFKA_FLUSH_TIMEOUT_MS) catch |err| {
        std.log.warn("Final background flush failed: {}", .{err});
    };

    if (lsn > 0 and producer.deliveryErrorCount() == 0) {
        source.sendFeedback(io, lsn) catch |err| {
            std.log.warn("Final background LSN commit failed: {}", .{err});
        };
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
    // Reused per message to format integer partition keys: an i64 is at most 20
    // bytes, and librdkafka copies the key on produce, so no per-message alloc.
    partition_key_buf: [20]u8,

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
            .partition_key_buf = undefined,
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
        var batch = try self.source.receiveBatch(io, batch_allocator, limit);
        defer batch.deinit();

        // A successful receive (even an empty batch) means we are connected and
        // reading the replication stream — the signal readiness cares about.
        self.obs.markStreaming();

        // Liveness follows real wire activity (a change or a keepalive), not the
        // loop turning: an empty batch on a dead stream must not refresh it.
        if (batch.changes.len > 0 or batch.received_keepalive) self.obs.heartbeat(io);

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

        // With dr_msg_cb registered, a produced message counts against
        // queue.buffering.max.messages until its delivery report is served by a
        // poll. Serve them every KAFKA_POLL_INTERVAL sends so a large batch does
        // not fill the queue before the single poll at the end.
        var sent_since_poll: u32 = 0;

        for (batch.changes) |change_event| {
            var matched = try matchStreams(batch_allocator, self.streams, change_event);
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

                sent_since_poll += 1;
                if (sent_since_poll >= constants.CDC.KAFKA_POLL_INTERVAL) {
                    producer.poll();
                    sent_since_poll = 0;
                }

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
        const key_field = stream.sink.routing_key;

        // Integer keys are the common case: format into a reusable buffer instead of
        // allocating per message. librdkafka copies the key on produce, so the
        // borrow only needs to outlive the sendMessage call, not the batch.
        if (change_event.partitionKeyInt(&self.partition_key_buf, key_field)) |key| {
            return key;
        }

        // Startup validation guarantees the key column exists (and REPLICA IDENTITY
        // FULL for delete-tracking streams), so a missing value here is not a
        // misconfiguration to route around but an unexpected row shape. Fail fast
        // rather than collapse the change onto a table-name partition.
        return try change_event.getPartitionKeyValue(allocator, key_field) orelse
            error.PartitionKeyUnavailable;
    }

    /// Run the batch loop until stop_signal is set, with a background flush/commit worker.
    pub fn startStreaming(self: *Self, io: std.Io, stop_signal: *std.atomic.Value(bool)) !void {
        // The source is connected and validated before we get here, so readiness's
        // connection signal goes up now; markStreaming follows on the first batch.
        self.obs.markConnected(true);
        // Seed liveness so it does not read stale before the first message; from
        // here it is refreshed only by real wire activity (see processChangesToKafka).
        self.obs.heartbeat(io);

        const producer = &self.producer;

        // Background flush/commit loop. `concurrent` not `async`: it must run
        // alongside the receive loop, and `async` may defer the call until await.
        var flush_future = try io.concurrent(flushCommitWorker, .{
            io,
            producer,
            &self.source,
            &self.pending_lsn,
        });
        // On a receive error, still stop the worker (wakes its sleep for the
        // final flush, and awaits) before the error propagates.
        errdefer {
            std.log.debug("startStreaming: error path, cancelling flush worker", .{});
            flush_future.cancel(io);
            std.log.debug("startStreaming: flush worker cancelled, propagating error", .{});
        }

        while (!stop_signal.load(.monotonic)) {
            var batch_arena = std.heap.ArenaAllocator.init(self.allocator);
            defer batch_arena.deinit();

            const batch_alloc = batch_arena.allocator();

            try self.processChangesToKafka(io, batch_alloc, constants.CDC.BATCH_SIZE);

            // A permanent delivery failure (or fatal producer error) means data
            // never reached Kafka. Fail fast so the slot re-sends from the last
            // confirmed LSN after restart.
            if (self.producer.deliveryErrorCount() > 0 or self.producer.fatalError()) {
                std.log.warn("Kafka delivery failed; exiting for restart", .{});
                return error.DeliveryFailed;
            }

            // A stream quiet past the liveness window (no change and no keepalive)
            // is dead: a frozen or black-holed peer sends no FIN/RST, so reads just
            // time out and look idle. Fail fast so the supervisor reconnects.
            if (!self.obs.liveness(io)) {
                std.log.warn("Replication stream stalled: no wire activity within the liveness window; exiting for restart", .{});
                return error.StreamStalled;
            }
        }

        // Graceful stop: cancel and await the worker (runs its final flush/commit)
        // before reporting the stream stopped.
        flush_future.cancel(io);
        std.log.info("Streaming stopped gracefully", .{});
    }
};
