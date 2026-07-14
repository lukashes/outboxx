const std = @import("std");
const Observability = @import("observability.zig").Observability;
const constants = @import("constants");

test "writeMetrics renders counters and the lag gauge in Prometheus text" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var obs = try Observability.init(allocator, io);
    defer obs.deinit();

    obs.addEvents(3, "users", "INSERT");
    obs.addEvents(2, "users", "INSERT");
    obs.setLag(600);

    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    try obs.writeMetrics(&aw.writer);
    const out = try aw.toOwnedSlice();
    defer allocator.free(out);

    try std.testing.expect(std.mem.indexOf(u8, out, "outboxx_events_processed_total{stream=\"users\",operation=\"INSERT\"} 5") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "outboxx_replication_lag_seconds 600") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "# TYPE outboxx_events_processed_total counter") != null);
}

test "counters persist across scrapes without new activity" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var obs = try Observability.init(allocator, io);
    defer obs.deinit();

    obs.addEvents(7, "users", "INSERT");

    // First scrape emits the counter.
    {
        var aw = std.Io.Writer.Allocating.init(allocator);
        defer aw.deinit();
        try obs.writeMetrics(&aw.writer);
        const out = try aw.toOwnedSlice();
        defer allocator.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "outboxx_events_processed_total{stream=\"users\",operation=\"INSERT\"} 7") != null);
    }

    // Second scrape with no new events: the counter must still be present.
    {
        var aw = std.Io.Writer.Allocating.init(allocator);
        defer aw.deinit();
        try obs.writeMetrics(&aw.writer);
        const out = try aw.toOwnedSlice();
        defer allocator.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "outboxx_events_processed_total{stream=\"users\",operation=\"INSERT\"} 7") != null);
    }
}

fn scrapeLag(obs: *Observability, allocator: std.mem.Allocator) ![]u8 {
    var aw = std.Io.Writer.Allocating.init(allocator);
    defer aw.deinit();
    try obs.writeMetrics(&aw.writer);
    return aw.toOwnedSlice();
}

// The gauge must render the value from the most recent setLag, overwriting the
// previous one — never summing successive records (the cumulative-temporality
// bug: 19 then 600 would render 619). Walk a sequence that goes up, down to 0
// (the caught-up idle path, the load-stand symptom), and back up, asserting each
// scrape renders exactly the last value. Lines carry the trailing newline so a
// value can't match as a prefix of a longer number.
test "lag gauge renders the latest value on each scrape and never accumulates" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var obs = try Observability.init(allocator, io);
    defer obs.deinit();

    const steps = [_]struct { set: i64, want: []const u8 }{
        .{ .set = 19, .want = "outboxx_replication_lag_seconds 19\n" },
        .{ .set = 600, .want = "outboxx_replication_lag_seconds 600\n" }, // not 619
        .{ .set = 0, .want = "outboxx_replication_lag_seconds 0\n" },
        .{ .set = 5, .want = "outboxx_replication_lag_seconds 5\n" },
    };

    for (steps) |step| {
        obs.setLag(step.set);
        const out = try scrapeLag(&obs, allocator);
        defer allocator.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, step.want) != null);
    }
}

test "events counter keeps an independent series per stream and operation" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var obs = try Observability.init(allocator, io);
    defer obs.deinit();

    obs.addEvents(3, "users", "INSERT");
    obs.addEvents(1, "users", "UPDATE");
    obs.addEvents(4, "orders", "INSERT");
    {
        const out = try scrapeLag(&obs, allocator);
        defer allocator.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "outboxx_events_processed_total{stream=\"users\",operation=\"INSERT\"} 3") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "outboxx_events_processed_total{stream=\"users\",operation=\"UPDATE\"} 1") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "outboxx_events_processed_total{stream=\"orders\",operation=\"INSERT\"} 4") != null);
    }

    // Each series accumulates on its own; adding to one must not move the others.
    obs.addEvents(2, "users", "INSERT");
    {
        const out = try scrapeLag(&obs, allocator);
        defer allocator.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "outboxx_events_processed_total{stream=\"users\",operation=\"INSERT\"} 5") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "outboxx_events_processed_total{stream=\"users\",operation=\"UPDATE\"} 1") != null);
        try std.testing.expect(std.mem.indexOf(u8, out, "outboxx_events_processed_total{stream=\"orders\",operation=\"INSERT\"} 4") != null);
    }
}

test "event label survives the caller's buffer being reused" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;

    var obs = try Observability.init(allocator, io);
    defer obs.deinit();

    // The SDK borrows attribute strings rather than copying them, so a label passed
    // from a caller's buffer must be interned. Mimic a reused buffer, then clobber it.
    const name = "users";
    var buf: [16]u8 = undefined;
    @memcpy(buf[0..name.len], name);
    obs.addEvents(4, buf[0..name.len], "INSERT");
    @memset(&buf, 'Z');

    const out = try scrapeLag(&obs, allocator);
    defer allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "outboxx_events_processed_total{stream=\"users\",operation=\"INSERT\"} 4") != null);
}

test "disabled observability records nothing but keeps health state" {
    const io = std.testing.io;

    var obs = Observability.noop();
    // No-ops: must not touch the null OTel plumbing.
    obs.addEvents(10, "users", "INSERT");
    obs.recordProduceError();
    obs.setLag(1);

    // Health atomics are valid even when disabled.
    try std.testing.expect(!obs.liveness(io)); // heartbeat never fired
    obs.heartbeat(io);
    try std.testing.expect(obs.liveness(io));

    try std.testing.expect(!obs.readiness(io)); // not connected/streaming yet
    obs.markConnected(true);
    obs.markStreaming();
    try std.testing.expect(obs.readiness(io));

    obs.markConnected(false);
    try std.testing.expect(!obs.readiness(io));
}

test "liveness goes stale once wire activity is older than the window" {
    const io = std.testing.io;

    var obs = Observability.noop();
    obs.heartbeat(io);
    try std.testing.expect(obs.liveness(io));

    // Backdate the last activity past the window, as a stalled stream would.
    const now = std.Io.Timestamp.now(io, .awake).toSeconds();
    obs.last_progress_sec.store(now - constants.OBSERVABILITY.LIVENESS_MAX_STALE_SEC - 5, .monotonic);
    try std.testing.expect(!obs.liveness(io));
}
