const std = @import("std");
const otel = @import("opentelemetry-sdk");
const constants = @import("constants");

const metrics = otel.metrics;

pub const serve = @import("http.zig").serve;

// Last rendered value of a single metric series, kept between scrapes.
const Sample = struct { prom_type: []const u8, value: i64 };

/// Metric instruments plus liveness/readiness state for the pipeline, sitting
/// behind the OpenTelemetry SDK. Constructed either enabled (real OTel plumbing)
/// or disabled (every record call is a cheap no-op), so callers never branch on
/// whether observability is configured.
///
/// Metrics are pull-only: instruments are incremented on the hot path, and the
/// HTTP `/metrics` handler renders them on scrape via `writeMetrics`. Keeping the
/// SDK confined here means an alpha API break lands in one file.
pub const Observability = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    enabled: bool,

    // OpenTelemetry plumbing; null when disabled.
    mp: ?*metrics.MeterProvider = null,
    reader: ?*metrics.MetricReader = null,
    in_memory: ?*metrics.InMemoryExporter = null,

    // collect() only emits instruments touched since the last call; this holds the
    // latest value of every series so each scrape renders them all. Keyed by the
    // instrument name, which the SDK borrows for the instrument's lifetime.
    snapshot: std.StringHashMapUnmanaged(Sample) = .{},

    // Instruments; null when disabled.
    events: ?*metrics.Counter(u64) = null,
    decode_errors: ?*metrics.Counter(u64) = null,
    produce_errors: ?*metrics.Counter(u64) = null,
    lag: ?*metrics.Gauge(i64) = null,

    // Health state, valid in both modes and read from the HTTP worker.
    last_progress_sec: std.atomic.Value(i64),
    connected: std.atomic.Value(bool),
    streaming: std.atomic.Value(bool),

    /// No-op instance: no OTel objects, no HTTP server; all record calls return early.
    pub fn initDisabled() Self {
        return .{
            .allocator = undefined,
            .enabled = false,
            .last_progress_sec = std.atomic.Value(i64).init(0),
            .connected = std.atomic.Value(bool).init(false),
            .streaming = std.atomic.Value(bool).init(false),
        };
    }

    pub fn init(allocator: std.mem.Allocator, io: std.Io) !Self {
        const mp = try metrics.MeterProvider.init(allocator, io);
        errdefer mp.shutdown();

        // InMemory + manual collect() lets us render Prometheus text on scrape
        // instead of running the SDK's own background HTTP server/thread.
        const inmem = try metrics.MetricExporter.InMemory(allocator, io, null, null);
        errdefer inmem.in_memory.deinit();

        const reader = try metrics.MetricReader.init(allocator, io, inmem.exporter);
        errdefer reader.shutdown();
        try mp.addReader(reader);

        const meter = try mp.getMeter(.{ .name = "outboxx", .version = constants.VERSION });

        return .{
            .allocator = allocator,
            .enabled = true,
            .mp = mp,
            .reader = reader,
            .in_memory = inmem.in_memory,
            .events = try meter.createCounter(u64, .{
                .name = "outboxx_events_processed_total",
                .description = "WAL change events consumed from the replication stream",
            }),
            .decode_errors = try meter.createCounter(u64, .{
                .name = "outboxx_decode_errors_total",
                .description = "pgoutput decode/convert failures",
            }),
            .produce_errors = try meter.createCounter(u64, .{
                .name = "outboxx_produce_errors_total",
                .description = "Kafka produce failures",
            }),
            .lag = try meter.createGauge(i64, .{
                .name = "outboxx_replication_lag_bytes",
                .description = "WAL bytes the server head is ahead of the last processed change",
            }),
            // Seed the heartbeat so liveness holds through a slow startup/connect.
            .last_progress_sec = std.atomic.Value(i64).init(std.Io.Timestamp.now(io, .awake).toSeconds()),
            .connected = std.atomic.Value(bool).init(false),
            .streaming = std.atomic.Value(bool).init(false),
        };
    }

    pub fn deinit(self: *Self) void {
        if (!self.enabled) return;
        self.snapshot.deinit(self.allocator);
        if (self.reader) |r| r.shutdown();
        if (self.mp) |p| p.shutdown();
        if (self.in_memory) |m| m.deinit();
    }

    /// Count WAL change events consumed in a batch (n = batch.changes.len).
    pub fn addEvents(self: *Self, n: usize) void {
        const c = self.events orelse return;
        c.add(@intCast(n), .{}) catch {};
    }

    pub fn recordDecodeError(self: *Self) void {
        const c = self.decode_errors orelse return;
        c.add(1, .{}) catch {};
    }

    pub fn recordProduceError(self: *Self) void {
        const c = self.produce_errors orelse return;
        c.add(1, .{}) catch {};
    }

    /// Set the replication lag gauge to WAL bytes the server head is ahead of the
    /// last change we processed (0 when caught up). The source computes it per batch.
    pub fn setLag(self: *Self, lag_bytes: u64) void {
        const g = self.lag orelse return;
        g.record(@intCast(lag_bytes), .{}) catch {};
    }

    /// Mark the receive loop as alive; call once per batch iteration.
    pub fn heartbeat(self: *Self, io: std.Io) void {
        self.last_progress_sec.store(std.Io.Timestamp.now(io, .awake).toSeconds(), .monotonic);
    }

    pub fn markConnected(self: *Self, value: bool) void {
        self.connected.store(value, .monotonic);
    }

    pub fn markStreaming(self: *Self) void {
        self.streaming.store(true, .monotonic);
    }

    /// Liveness: the receive loop produced progress recently (not hung).
    pub fn liveness(self: *Self, io: std.Io) bool {
        const now = std.Io.Timestamp.now(io, .awake).toSeconds();
        return now - self.last_progress_sec.load(.monotonic) < constants.OBSERVABILITY.LIVENESS_MAX_STALE_SEC;
    }

    /// Readiness: connected to Postgres, streaming has begun, and still live.
    pub fn readiness(self: *Self, io: std.Io) bool {
        return self.connected.load(.monotonic) and self.streaming.load(.monotonic) and self.liveness(io);
    }

    /// Collect the current metric snapshot and render it as Prometheus text.
    /// On-scrape: `collect()` drives the aggregator, `fetch()` drains it, and we
    /// format the scalar (attribute-less) instruments ourselves — the SDK's
    /// PrometheusFormatter is not part of its public surface.
    pub fn writeMetrics(self: *Self, writer: *std.Io.Writer) !void {
        const reader = self.reader orelse return;
        const in_memory = self.in_memory orelse return;

        try reader.collect();
        const measurements = try in_memory.fetch(self.allocator);
        defer {
            for (measurements) |*m| m.deinit(self.allocator);
            self.allocator.free(measurements);
        }

        // Merge this collection into the persistent snapshot (scalar, unlabeled series only).
        for (measurements) |m| {
            const prom_type: []const u8 = switch (m.instrumentKind) {
                .Counter, .ObservableCounter => "counter",
                else => "gauge",
            };
            switch (m.data) {
                .int => |points| {
                    if (points.len == 0) continue;
                    try self.snapshot.put(self.allocator, m.instrumentOptions.name, .{
                        .prom_type = prom_type,
                        .value = points[points.len - 1].value,
                    });
                },
                else => {},
            }
        }

        var it = self.snapshot.iterator();
        while (it.next()) |entry| {
            const name = entry.key_ptr.*;
            try writer.print("# TYPE {s} {s}\n{s} {d}\n", .{ name, entry.value_ptr.prom_type, name, entry.value_ptr.value });
        }
    }
};
