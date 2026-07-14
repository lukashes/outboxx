const std = @import("std");
const otel = @import("opentelemetry-sdk");
const constants = @import("constants");

const metrics = otel.metrics;

pub const serve = @import("http.zig").serve;

// Last rendered value of one metric series, kept between scrapes. The snapshot
// keys on the full Prometheus series (name plus any labels); `name` is retained
// so the `# TYPE` line can be grouped per metric.
const Sample = struct { name: []const u8, prom_type: []const u8, value: i64 };

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
    // full series string (name plus labels), which we own because the SDK frees the
    // measurements after each scrape.
    snapshot: std.StringHashMapUnmanaged(Sample) = .{},

    // Owns label-value strings handed to the SDK. Instruments borrow attribute
    // strings (they are not copied) and a series persists across scrapes, so a
    // label must outlive the per-batch memory a table name comes from.
    label_pool: std.StringHashMapUnmanaged(void) = .{},

    // Instruments; null when disabled.
    events: ?*metrics.Counter(u64) = null,
    produce_errors: ?*metrics.Counter(u64) = null,
    lag: ?*metrics.Gauge(i64) = null,

    // Health state, valid in both modes and read from the HTTP worker.
    last_progress_sec: std.atomic.Value(i64),
    connected: std.atomic.Value(bool),
    streaming: std.atomic.Value(bool),

    /// No-op instance: no OTel objects, no HTTP server; all record calls return early.
    pub fn noop() Self {
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
        //
        // Pass DefaultTemporality explicitly: InMemory otherwise defaults every
        // instrument to Cumulative, and the SDK's cumulative path *sums*
        // successive collected values (open-telemetry/opentelemetry-zig#36). That
        // is right for counters but wrong for the lag gauge — it would grow without
        // bound and never fall back to 0. DefaultTemporality keeps counters
        // Cumulative and gives the gauge Delta, so each scrape reports its last
        // recorded value, which is what Prometheus expects for each.
        const inmem = try metrics.MetricExporter.InMemory(allocator, io, metrics.View.DefaultTemporality, null);
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
            .produce_errors = try meter.createCounter(u64, .{
                .name = "outboxx_produce_errors_total",
                .description = "Kafka produce failures",
            }),
            .lag = try meter.createGauge(i64, .{
                .name = "outboxx_replication_lag_seconds",
                .description = "Seconds the last processed transaction's commit is behind now (0 when caught up)",
            }),
            // Seed the heartbeat so liveness holds through a slow startup/connect.
            .last_progress_sec = std.atomic.Value(i64).init(std.Io.Timestamp.now(io, .awake).toSeconds()),
            .connected = std.atomic.Value(bool).init(false),
            .streaming = std.atomic.Value(bool).init(false),
        };
    }

    pub fn deinit(self: *Self) void {
        if (!self.enabled) return;
        var keys = self.snapshot.keyIterator();
        while (keys.next()) |k| self.allocator.free(k.*);
        self.snapshot.deinit(self.allocator);
        var labels = self.label_pool.keyIterator();
        while (labels.next()) |k| self.allocator.free(k.*);
        self.label_pool.deinit(self.allocator);
        if (self.reader) |r| r.shutdown();
        if (self.mp) |p| p.shutdown();
        if (self.in_memory) |m| m.deinit();
    }

    // Return a copy of `s` owned for the lifetime of this Observability, so the SDK's
    // borrowed attribute pointer stays valid until the series is scraped. The set of
    // distinct label values is small (configured tables), so this stays bounded.
    fn intern(self: *Self, s: []const u8) ![]const u8 {
        const gop = try self.label_pool.getOrPut(self.allocator, s);
        if (!gop.found_existing) gop.key_ptr.* = try self.allocator.dupe(u8, s);
        return gop.key_ptr.*;
    }

    /// Count change events routed by a stream, tagged by the config stream name and operation.
    /// Callers aggregate per batch, so this runs once per distinct combo, not per change.
    /// The stream name is interned; `operation` is a static tag name and needs no copy.
    pub fn addEvents(self: *Self, n: u64, stream: []const u8, operation: []const u8) void {
        const c = self.events orelse return;
        const stream_owned = self.intern(stream) catch return;
        c.add(n, .{ "stream", stream_owned, "operation", operation }) catch {};
    }

    /// Count one Kafka produce failure.
    pub fn recordProduceError(self: *Self) void {
        const c = self.produce_errors orelse return;
        c.add(1, .{}) catch {};
    }

    /// Set the replication lag gauge to seconds behind source: wall clock minus the
    /// last processed transaction's commit time (0 when caught up). Source computes it.
    pub fn setLag(self: *Self, lag_seconds: i64) void {
        const g = self.lag orelse return;
        g.record(lag_seconds, .{}) catch {};
    }

    /// Record wire activity on the replication stream (a change or a server
    /// keepalive). Call only on real activity, not once per loop turn, or a dead
    /// stream would look alive.
    pub fn heartbeat(self: *Self, io: std.Io) void {
        self.last_progress_sec.store(std.Io.Timestamp.now(io, .awake).toSeconds(), .monotonic);
    }

    /// Record whether the Postgres replication connection is up (readiness input).
    pub fn markConnected(self: *Self, value: bool) void {
        self.connected.store(value, .monotonic);
    }

    /// Mark that the replication stream has delivered at least one batch (readiness input).
    pub fn markStreaming(self: *Self) void {
        self.streaming.store(true, .monotonic);
    }

    /// Liveness: the stream saw wire activity within LIVENESS_MAX_STALE_SEC.
    /// False means a stalled/dead stream — used by /healthz and to fail fast.
    pub fn liveness(self: *Self, io: std.Io) bool {
        const now = std.Io.Timestamp.now(io, .awake).toSeconds();
        return now - self.last_progress_sec.load(.monotonic) < constants.OBSERVABILITY.LIVENESS_MAX_STALE_SEC;
    }

    /// Readiness: connected to Postgres, streaming has begun, and still live.
    pub fn readiness(self: *Self, io: std.Io) bool {
        return self.connected.load(.monotonic) and self.streaming.load(.monotonic) and self.liveness(io);
    }

    /// Collect the current metrics and render them as Prometheus text. On scrape,
    /// `collect()` drives the aggregator and `fetch()` drains it; we render the text
    /// ourselves (the SDK's PrometheusFormatter is not public). Each (name, label set)
    /// is one series, kept in the snapshot so a series that did not change this cycle
    /// is still present on every scrape.
    pub fn writeMetrics(self: *Self, writer: *std.Io.Writer) !void {
        const reader = self.reader orelse return;
        const in_memory = self.in_memory orelse return;

        try reader.collect();
        const measurements = try in_memory.fetch(self.allocator);
        defer {
            for (measurements) |*m| m.deinit(self.allocator);
            self.allocator.free(measurements);
        }

        for (measurements) |m| {
            const prom_type: []const u8 = switch (m.instrumentKind) {
                .Counter, .ObservableCounter => "counter",
                else => "gauge",
            };
            const points = switch (m.data) {
                .int => |p| p,
                else => continue,
            };
            for (points) |point| {
                try self.upsertSeries(m.instrumentOptions.name, prom_type, point);
            }
        }

        try self.renderSnapshot(writer);
    }

    // Merge one data point into the snapshot under its full series key (name plus
    // rendered labels). A new series dupes its key into snapshot-owned memory, since
    // the SDK frees the measurements after the scrape; a known series updates value.
    fn upsertSeries(self: *Self, name: []const u8, prom_type: []const u8, point: anytype) !void {
        var series = std.ArrayList(u8).empty;
        errdefer series.deinit(self.allocator);
        try series.appendSlice(self.allocator, name);
        try appendLabels(self.allocator, &series, point.attributes);

        const gop = try self.snapshot.getOrPut(self.allocator, series.items);
        if (gop.found_existing) {
            series.deinit(self.allocator);
        } else {
            gop.key_ptr.* = try series.toOwnedSlice(self.allocator);
            gop.value_ptr.name = name;
            gop.value_ptr.prom_type = prom_type;
        }
        gop.value_ptr.value = point.value;
    }

    // Render the snapshot, grouped by metric name so each `# TYPE` line precedes its
    // series exactly once (Prometheus rejects a family split across the exposition).
    fn renderSnapshot(self: *Self, writer: *std.Io.Writer) !void {
        const Entry = struct { series: []const u8, name: []const u8, prom_type: []const u8, value: i64 };

        var entries = std.ArrayList(Entry).empty;
        defer entries.deinit(self.allocator);
        var it = self.snapshot.iterator();
        while (it.next()) |e| {
            try entries.append(self.allocator, .{
                .series = e.key_ptr.*,
                .name = e.value_ptr.name,
                .prom_type = e.value_ptr.prom_type,
                .value = e.value_ptr.value,
            });
        }

        std.mem.sort(Entry, entries.items, {}, struct {
            fn lessThan(_: void, a: Entry, b: Entry) bool {
                if (!std.mem.eql(u8, a.name, b.name)) return std.mem.lessThan(u8, a.name, b.name);
                return std.mem.lessThan(u8, a.series, b.series);
            }
        }.lessThan);

        var current_name: []const u8 = "";
        for (entries.items) |e| {
            if (!std.mem.eql(u8, e.name, current_name)) {
                try writer.print("# TYPE {s} {s}\n", .{ e.name, e.prom_type });
                current_name = e.name;
            }
            try writer.print("{s} {d}\n", .{ e.series, e.value });
        }
    }
};

// Append `{k="v",...}` for a data point's attributes, or nothing when it has none.
// Attribute order matches the add() call site, so a series renders identically each scrape.
fn appendLabels(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), attributes: anytype) !void {
    const attrs = attributes orelse return;
    if (attrs.len == 0) return;
    try buf.append(allocator, '{');
    for (attrs, 0..) |attr, i| {
        if (i > 0) try buf.append(allocator, ',');
        try buf.appendSlice(allocator, attr.key);
        try buf.appendSlice(allocator, "=\"");
        try appendLabelValue(allocator, buf, attr.value);
        try buf.append(allocator, '"');
    }
    try buf.append(allocator, '}');
}

// Render one attribute value into a label value, escaping the three characters the
// Prometheus exposition format requires inside a quoted string.
fn appendLabelValue(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), value: anytype) !void {
    switch (value) {
        .string => |s| for (s) |ch| switch (ch) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            else => try buf.append(allocator, ch),
        },
        .bool => |b| try buf.appendSlice(allocator, if (b) "true" else "false"),
        .int => |n| {
            var tmp: [32]u8 = undefined;
            try buf.appendSlice(allocator, std.fmt.bufPrint(&tmp, "{d}", .{n}) catch return);
        },
        .double => |d| {
            var tmp: [64]u8 = undefined;
            try buf.appendSlice(allocator, std.fmt.bufPrint(&tmp, "{d}", .{d}) catch return);
        },
        else => {},
    }
}
