const std = @import("std");
const Observability = @import("observability.zig").Observability;

const metrics_content_type = "text/plain; version=0.0.4; charset=utf-8";

/// Serve `/metrics`, `/healthz` and `/readyz` until `stop` is set. Runs as an
/// `io.concurrent` worker alongside the receive loop; on shutdown the future is
/// cancelled, which unblocks `accept`. Errors are logged, never propagated —
/// observability must not take the pipeline down.
pub fn serve(io: std.Io, obs: *Observability, address: []const u8, port: u16, stop: *std.atomic.Value(bool)) void {
    serveImpl(io, obs, address, port, stop) catch |err| {
        std.log.warn("metrics server stopped: {}", .{err});
    };
}

fn serveImpl(io: std.Io, obs: *Observability, address: []const u8, port: u16, stop: *std.atomic.Value(bool)) !void {
    const addr = try std.Io.net.IpAddress.parse(address, port);
    var server = try addr.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    std.log.info("metrics server listening on http://{s}:{d}/metrics", .{ address, port });

    while (!stop.load(.monotonic)) {
        var stream = server.accept(io) catch |err| {
            if (stop.load(.monotonic)) break;
            std.log.debug("metrics accept failed: {}", .{err});
            continue;
        };
        defer stream.close(io);
        // One request per connection keeps scrapes serialized, so collect() never overlaps.
        handleConnection(io, obs, &stream) catch |err| {
            std.log.debug("metrics request failed: {}", .{err});
        };
    }
}

fn handleConnection(io: std.Io, obs: *Observability, stream: *std.Io.net.Stream) !void {
    var read_buffer: [4096]u8 = undefined;
    var write_buffer: [4096]u8 = undefined;
    var conn_reader = stream.reader(io, &read_buffer);
    var conn_writer = stream.writer(io, &write_buffer);
    var server = std.http.Server.init(&conn_reader.interface, &conn_writer.interface);

    var request = try server.receiveHead();
    const target = request.head.target;

    if (std.mem.eql(u8, target, "/metrics")) {
        try respondMetrics(obs, &request);
    } else if (std.mem.eql(u8, target, "/healthz")) {
        try respondHealth(&request, obs.liveness(io));
    } else if (std.mem.eql(u8, target, "/readyz")) {
        try respondHealth(&request, obs.readiness(io));
    } else {
        try request.respond("not found\n", .{ .status = .not_found });
    }
}

fn respondMetrics(obs: *Observability, request: *std.http.Server.Request) !void {
    var aw = std.Io.Writer.Allocating.init(obs.allocator);
    defer aw.deinit();

    obs.writeMetrics(&aw.writer) catch {
        try request.respond("metric collection failed\n", .{ .status = .internal_server_error });
        return;
    };
    const body = aw.toOwnedSlice() catch {
        try request.respond("out of memory\n", .{ .status = .internal_server_error });
        return;
    };
    defer obs.allocator.free(body);

    try request.respond(body, .{
        .status = .ok,
        .extra_headers = &.{.{ .name = "content-type", .value = metrics_content_type }},
    });
}

fn respondHealth(request: *std.http.Server.Request, healthy: bool) !void {
    if (healthy) {
        try request.respond("ok\n", .{ .status = .ok });
    } else {
        try request.respond("unavailable\n", .{ .status = .service_unavailable });
    }
}
