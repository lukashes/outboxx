const std = @import("std");
const domain = @import("../../domain/change_event.zig");
const ChangeEvent = domain.ChangeEvent;
const constants = @import("../../constants.zig");

const replication_protocol = @import("replication_protocol.zig");
const ReplicationProtocol = replication_protocol.ReplicationProtocol;
const ReplicationError = replication_protocol.ReplicationError;
const StandbyStatusUpdate = replication_protocol.StandbyStatusUpdate;

const pg_output_decoder = @import("pg_output_decoder.zig");
const PgOutputDecoder = pg_output_decoder.PgOutputDecoder;
const DecoderError = pg_output_decoder.DecoderError;

const relation_registry = @import("relation_registry.zig");

const converter = @import("converter.zig");
pub const Converter = converter.Converter;

const SnapshotSession = @import("snapshot.zig").SnapshotSession;

// Re-export types for benchmarks (public API)
pub const PgOutputMessage = pg_output_decoder.PgOutputMessage;
pub const InsertMessage = pg_output_decoder.InsertMessage;
pub const UpdateMessage = pg_output_decoder.UpdateMessage;
pub const DeleteMessage = pg_output_decoder.DeleteMessage;
pub const TupleMessage = pg_output_decoder.TupleMessage;
pub const TupleData = pg_output_decoder.TupleData;
pub const RelationMessage = pg_output_decoder.RelationMessage;
pub const RelationMessageColumn = pg_output_decoder.RelationMessageColumn;
pub const RelationRegistry = relation_registry.RelationRegistry;

const POSTGRES_EPOCH_UNIX_SECONDS = converter.POSTGRES_EPOCH_UNIX_SECONDS;

/// Batch of changes from PostgreSQL (streaming source)
pub const Batch = struct {
    /// Change events (flat list)
    changes: []ChangeEvent,

    /// LSN for feedback (last change in batch)
    last_lsn: u64,

    /// Seconds the last transaction in this batch is behind now (wall clock minus
    /// the transaction's commit time). 0 when the batch carried no data (caught up).
    replication_lag_seconds: i64,

    /// Whether a server keepalive arrived while building this batch. Together with
    /// a non-empty `changes`, it tells the processor the stream is alive so it can
    /// refresh the liveness heartbeat; an empty batch with neither is a dead stream.
    received_keepalive: bool,

    allocator: std.mem.Allocator,

    pub fn deinit(self: *Batch) void {
        for (self.changes) |*change| {
            change.deinit(self.allocator);
        }
        self.allocator.free(self.changes);
    }
};

pub const PostgresSourceError = error{
    ConnectionFailed,
    ReplicationFailed,
    DecodeFailed,
    ConversionFailed,
    OutOfMemory,
};

/// PostgreSQL streaming source adapter
/// Uses logical replication with pgoutput format
///
/// LSN Tracking Design:
/// - extractChangeFromMessage() returns LSN explicitly (or 0 on error)
/// - receiveBatchWithTimeout() tracks LSN locally and updates instance field
/// - last_lsn is used as starting point for next batch
pub const PostgresSource = struct {
    allocator: std.mem.Allocator,
    protocol: ReplicationProtocol,
    decoder: PgOutputDecoder,
    converter: Converter,
    last_lsn: u64, // Last confirmed LSN (starting point for next batch)
    // Commit timestamp (us since the Postgres epoch) of the last transaction seen.
    // The stream does not expose the server WAL head during a backlog, so lag is
    // measured as wall-clock time behind this commit, like Debezium.
    last_commit_time: i64,
    // Owned copy of the conninfo passed to connect. The initial snapshot needs a
    // second, regular connection (the replication one must stay idle until
    // START_REPLICATION), so the source keeps the string instead of asking for it
    // again. Never log it: it carries the password.
    conninfo: ?[]u8 = null,
    // Live only between openSnapshot and finishSnapshot.
    snapshot: ?SnapshotSession = null,
    // Backs the session's resource list: the caller's slice may go away as soon as
    // the snapshot is drained, while the session outlives it until finishSnapshot.
    snapshot_resources: ?[][]const u8 = null,

    const Self = @This();

    /// Initialize streaming source
    pub fn init(
        allocator: std.mem.Allocator,
        slot_name: []const u8,
        publication_name: []const u8,
    ) Self {
        return Self{
            .allocator = allocator,
            .protocol = ReplicationProtocol.init(allocator, slot_name, publication_name),
            .decoder = PgOutputDecoder.init(allocator),
            .converter = Converter.init(allocator),
            .last_lsn = 0,
            .last_commit_time = 0,
        };
    }

    pub fn deinit(self: *Self) void {
        self.closeSnapshot();
        if (self.conninfo) |conninfo| {
            self.allocator.free(conninfo);
            self.conninfo = null;
        }
        self.protocol.deinit();
        self.converter.deinit();
    }

    /// Connect to PostgreSQL and ensure the publication and replication slot exist,
    /// without starting the stream, so a caller can run an initial snapshot between
    /// slot creation and streaming. On a freshly created slot the start LSN and
    /// exported snapshot are captured here (see startLsn/snapshotName).
    ///
    /// `want_snapshot` says whether this run may run an initial snapshot, which
    /// drives interrupted-snapshot recovery (see ensureSlot).
    pub fn connect(self: *Self, connection_string: []const u8, want_snapshot: bool) PostgresSourceError!void {
        self.conninfo = self.allocator.dupe(u8, connection_string) catch return PostgresSourceError.OutOfMemory;

        self.protocol.connect(connection_string) catch |err| {
            std.log.warn("Failed to connect with replication protocol: {}", .{err});
            return PostgresSourceError.ConnectionFailed;
        };

        // The streaming publication must exist before the slot, so the slot's start
        // LSN falls after it and every streamed change decodes (see the protocol).
        self.protocol.createPublicationIfNotExists() catch |err| {
            std.log.warn("Failed to create publication: {}", .{err});
            return PostgresSourceError.ConnectionFailed;
        };

        try self.ensureSlot(want_snapshot);
    }

    // Reconcile the replication slot for this run using the snapshot marker as a
    // durable "snapshot in progress" flag (see the protocol's createSnapshotMarker):
    // - snapshot run, slot present, no marker: a prior bootstrap completed, resume.
    // - snapshot run, slot present, marker present: the snapshot was interrupted,
    //   drop the orphaned slot and redo from a fresh consistent point.
    // - snapshot run, no slot: fresh bootstrap.
    // - no snapshot: resume an existing slot, create one if absent, and clear any
    //   stale marker so steady state keeps a single publication.
    // The marker is created before the slot, so a crash between the two leaves
    // "no slot, marker present", which reads as a fresh bootstrap, never a false
    // "completed".
    fn ensureSlot(self: *Self, want_snapshot: bool) PostgresSourceError!void {
        const slot_exists = self.protocol.slotExists() catch return PostgresSourceError.ConnectionFailed;

        if (!want_snapshot) {
            self.protocol.dropSnapshotMarker() catch return PostgresSourceError.ConnectionFailed;
            if (!slot_exists) self.protocol.createSlot() catch return PostgresSourceError.ConnectionFailed;
            return;
        }

        if (slot_exists) {
            const marker = self.protocol.snapshotMarkerExists() catch return PostgresSourceError.ConnectionFailed;
            if (!marker) return; // completed bootstrap: resume, no snapshot

            std.log.warn("Snapshot marker present: a prior initial snapshot was interrupted; restarting the bootstrap", .{});
            self.protocol.dropSlot() catch return PostgresSourceError.ConnectionFailed;
        }

        self.protocol.createSnapshotMarker() catch return PostgresSourceError.ConnectionFailed;
        self.protocol.createSlot() catch return PostgresSourceError.ConnectionFailed;
    }

    /// Open an initial-snapshot session over `resources` and report whether one is
    /// running. False means this run has nothing to bootstrap, so the caller goes
    /// straight to streaming: either the slot already existed (no exported snapshot)
    /// or no resource was asked for. The `resources` slice is copied; the names in it
    /// are borrowed and must outlive the snapshot.
    pub fn openSnapshot(self: *Self, io: std.Io, resources: []const []const u8) PostgresSourceError!bool {
        const snapshot_name = self.protocol.snapshotName() orelse return false;
        if (resources.len == 0) return false;

        const conninfo = self.conninfo orelse return PostgresSourceError.ConnectionFailed;

        const owned_resources = self.allocator.dupe([]const u8, resources) catch return PostgresSourceError.OutOfMemory;
        errdefer self.allocator.free(owned_resources);

        // Every READ row is stamped with the snapshot's wall-clock start and the slot's
        // start LSN, so a snapshot row and the first streamed change share the dedup
        // boundary.
        var session = SnapshotSession.init(
            self.allocator,
            snapshot_name,
            self.protocol.startLsn() orelse "0/0",
            std.Io.Timestamp.now(io, .real).toSeconds(),
            owned_resources,
        );
        session.connect(conninfo) catch |err| {
            std.log.warn("Failed to open the snapshot session: {}", .{err});
            return PostgresSourceError.ConnectionFailed;
        };

        self.snapshot_resources = owned_resources;
        self.snapshot = session;
        return true;
    }

    /// Receive a batch of snapshot rows as READ changes, shaped like receiveBatch. An
    /// empty batch means every resource has been read out, so the caller can finish the
    /// snapshot and move on to streaming. Call only while openSnapshot reported a
    /// running session.
    pub fn receiveSnapshotBatch(self: *Self, allocator: std.mem.Allocator, limit: usize) PostgresSourceError!Batch {
        const session = if (self.snapshot) |*s| s else return PostgresSourceError.ConnectionFailed;

        const changes = session.next(allocator, limit) catch |err| switch (err) {
            error.OutOfMemory => return PostgresSourceError.OutOfMemory,
            else => {
                std.log.warn("Failed to read the initial snapshot: {}", .{err});
                return PostgresSourceError.ConnectionFailed;
            },
        };

        // A snapshot batch carries no WAL position: the slot advances only once the
        // stream is confirmed, so last_lsn stays 0 and lag/keepalive do not apply.
        return .{
            .changes = changes,
            .last_lsn = 0,
            .replication_lag_seconds = 0,
            .received_keepalive = false,
            .allocator = allocator,
        };
    }

    /// Close the snapshot session and drop the marker, returning steady state to a
    /// single publication. Idempotent, so it is safe to call even when this run ran no
    /// snapshot.
    pub fn finishSnapshot(self: *Self) PostgresSourceError!void {
        self.closeSnapshot();
        self.protocol.dropSnapshotMarker() catch return PostgresSourceError.ConnectionFailed;
    }

    fn closeSnapshot(self: *Self) void {
        if (self.snapshot) |*session| {
            session.deinit();
            self.snapshot = null;
        }
        if (self.snapshot_resources) |resources| {
            self.allocator.free(resources);
            self.snapshot_resources = null;
        }
    }

    /// Finish the bootstrap and start streaming changes: close any snapshot session,
    /// drop the marker, then replicate from the slot's start LSN (or from its confirmed
    /// position when the slot already existed). Call only once the snapshot is flushed,
    /// since starting the stream invalidates the exported snapshot.
    pub fn startStreaming(self: *Self) PostgresSourceError!void {
        try self.finishSnapshot();
        try self.startReplication(self.protocol.startLsn() orelse "0/0");
    }

    /// Start logical replication from start_lsn. Call after connect.
    pub fn startReplication(self: *Self, start_lsn: []const u8) PostgresSourceError!void {
        self.protocol.startReplication(start_lsn) catch |err| {
            std.log.warn("Failed to start replication: {}", .{err});
            return PostgresSourceError.ReplicationFailed;
        };

        std.log.info("Streaming replication started from LSN: {s}", .{start_lsn});
    }

    /// The slot's start LSN when it was created in this run, or null if the slot
    /// already existed (pass "0/0" to resume from its confirmed position).
    pub fn startLsn(self: *const Self) ?[]const u8 {
        return self.protocol.startLsn();
    }

    /// The slot's exported snapshot name when it was created in this run, or null
    /// if the slot already existed. Present only alongside a fresh startLsn, so it
    /// gates the initial snapshot. Valid until streaming starts on this connection.
    pub fn snapshotName(self: *const Self) ?[]const u8 {
        return self.protocol.snapshotName();
    }

    /// Receive batch of changes from PostgreSQL (default wait time from constants)
    /// Wrapper for compatibility with polling source API
    pub fn receiveBatch(self: *Self, io: std.Io, batch_allocator: std.mem.Allocator, limit: usize) PostgresSourceError!Batch {
        return self.receiveBatchWithWaitTime(io, batch_allocator, limit, constants.CDC.BATCH_WAIT_MS);
    }

    /// Receive batch of changes from PostgreSQL (with wait time)
    /// limit: desired batch size (soft limit)
    /// wait_time_ms: max time to wait for batch
    pub fn receiveBatchWithWaitTime(self: *Self, io: std.Io, batch_allocator: std.mem.Allocator, limit: usize, wait_time_ms: i32) PostgresSourceError!Batch {
        var changes = std.ArrayList(ChangeEvent).empty;
        errdefer {
            for (changes.items) |*change| {
                change.deinit(batch_allocator);
            }
            changes.deinit(batch_allocator);
        }

        var last_confirmed_lsn: u64 = self.last_lsn; // Track LSN locally
        var received_keepalive = false;

        // Monotonic deadline (`.awake`), so a wall-clock jump can't skew the wait.
        const deadline = std.Io.Timestamp.now(io, .awake).addDuration(.fromMilliseconds(wait_time_ms));

        while (changes.items.len < limit and std.Io.Timestamp.now(io, .awake).nanoseconds < deadline.nanoseconds) {
            const remaining = std.Io.Timestamp.now(io, .awake).durationTo(deadline);
            const wait_time: i32 = @intCast(@max(remaining.toMilliseconds(), 0));

            // Step 1: Blocking receive (poll() inside)
            const repl_msg = self.protocol.receiveMessage(io, wait_time) catch |err| {
                std.log.warn("Failed to receive replication message: {}", .{err});
                return PostgresSourceError.ReplicationFailed;
            };

            if (repl_msg == null) {
                // Wait time elapsed - no message available
                if (changes.items.len > 0) {
                    // Return what we have
                    break;
                }
                continue;
            }

            // Extract change from the first message
            var msg = repl_msg.?;
            defer msg.deinit(self.allocator);

            // A server keepalive carries no change but proves the stream is alive;
            // changes prove it too, so liveness is refreshed on either (processor).
            if (std.meta.activeTag(msg) == .keepalive) received_keepalive = true;

            const msg_lsn = try self.extractChangeFromMessage(batch_allocator, msg, &changes);
            last_confirmed_lsn = msg_lsn; // Update LSN (always > 0 on success)

            // Step 2: DRAIN all buffered messages (non-blocking)
            while (changes.items.len < limit) {
                const next_msg = self.protocol.receiveMessage(io, 0) catch break; // 0ms wait time = non-blocking
                if (next_msg == null) break; // No more buffered data

                var buffered_msg = next_msg.?;
                defer buffered_msg.deinit(self.allocator);

                if (std.meta.activeTag(buffered_msg) == .keepalive) received_keepalive = true;

                const buffered_lsn = try self.extractChangeFromMessage(batch_allocator, buffered_msg, &changes);
                last_confirmed_lsn = buffered_lsn; // Update LSN (always > 0 on success)
            }
        }

        // Update instance LSN for next batch
        self.last_lsn = last_confirmed_lsn;

        // Time behind source: wall clock minus the last transaction's commit time.
        // Postgres commit timestamps are microseconds since 2000-01-01, so shift to
        // the Unix epoch before comparing. 0 until we have seen a commit.
        const lag_seconds: i64 = if (self.last_commit_time == 0) 0 else blk: {
            const commit_unix = @divFloor(self.last_commit_time, std.time.us_per_s) + POSTGRES_EPOCH_UNIX_SECONDS;
            const now_unix = std.Io.Timestamp.now(io, .real).toSeconds();
            break :blk @max(now_unix - commit_unix, 0);
        };

        return .{
            .changes = try changes.toOwnedSlice(batch_allocator),
            .last_lsn = last_confirmed_lsn,
            .replication_lag_seconds = lag_seconds,
            .received_keepalive = received_keepalive,
            .allocator = batch_allocator,
        };
    }

    // Extract a change from a replication message and return its LSN for confirmation.
    // The LSN is returned even for messages that produce no ChangeEvent
    // (BEGIN/COMMIT/RELATION) - they still count as processed.
    //
    // Error handling strategy (fail-stop): decode/convert errors propagate up to main(),
    // the app exits non-zero, and the supervisor (systemd/k8s) restarts it. The LSN is
    // not confirmed, so PostgreSQL re-sends the same message; a persistent error becomes
    // a crash loop that needs operator intervention.
    fn extractChangeFromMessage(self: *Self, batch_allocator: std.mem.Allocator, msg: replication_protocol.ReplicationMessage, changes: *std.ArrayList(ChangeEvent)) !u64 {
        switch (msg) {
            .xlog_data => |xlog| {
                var pg_msg = self.decoder.decode(batch_allocator, xlog.wal_data) catch |err| {
                    std.log.warn("Failed to decode pgoutput message at LSN {}: {}", .{ xlog.server_wal_end, err });
                    return PostgresSourceError.DecodeFailed; // Propagate error up
                };
                defer pg_msg.deinit(batch_allocator);

                // BEGIN/COMMIT carry the transaction's commit timestamp, used for the lag metric.
                switch (pg_msg) {
                    .begin => |b| self.last_commit_time = b.commit_time,
                    .commit => |c| self.last_commit_time = c.commit_time,
                    else => {},
                }

                const change_opt = self.converter.convert(batch_allocator, pg_msg, xlog.wal_start) catch |err| {
                    std.log.warn("Failed to convert message to ChangeEvent at LSN {}: {}", .{ xlog.server_wal_end, err });
                    return PostgresSourceError.ConversionFailed; // Propagate error up
                };

                // Add ChangeEvent to batch if present
                if (change_opt) |change_event| {
                    try changes.append(batch_allocator, change_event);
                    // If append fails (OOM), error propagates up
                    // → batch won't be returned → LSN won't be confirmed → no data loss
                }

                // Successfully processed - return LSN for confirmation
                return xlog.server_wal_end;
            },
            .keepalive => |keepalive| {
                // Do NOT send reply here (even if reply_requested=true)
                // Reason: We must maintain at-least-once guarantee
                // - Sending reply here would confirm LSN before Kafka flush
                // - If Kafka flush fails, data would be lost
                // - Processor will send feedback after successful Kafka flush
                //
                // Note: PostgreSQL may wait for reply, but our batch wait time (~6 sec)
                // is much shorter than wal_sender_timeout (default 60 sec)
                return keepalive.server_wal_end;
            },
        }
    }

    /// Send LSN feedback to PostgreSQL (confirm processing)
    pub fn sendFeedback(self: *Self, io: std.Io, lsn: u64) PostgresSourceError!void {
        const status = StandbyStatusUpdate{
            .wal_write_position = lsn,
            .wal_flush_position = lsn,
            .wal_apply_position = lsn,
            .client_time = std.Io.Timestamp.now(io, .real).toSeconds(),
            // Request an immediate keepalive back. Our regular feedback keeps the
            // walsender quiet (it only probes after wal_sender_timeout/2 of client
            // silence), so an idle stream would carry no inbound traffic and trip
            // the liveness deadline (#111). The requested reply feeds liveness on
            // every feedback cycle; a frozen peer cannot answer, so stall
            // detection still fires.
            .reply_requested = true,
        };

        self.protocol.sendStatusUpdate(io, status) catch |err| {
            std.log.warn("Failed to send feedback: {}", .{err});
            return PostgresSourceError.ReplicationFailed;
        };
    }
};

const testing = std.testing;

test "PostgresSource: init and deinit" {
    const allocator = testing.allocator;

    var source = PostgresSource.init(allocator, "test_slot", "test_pub");
    defer source.deinit();

    try testing.expectEqual(@as(u64, 0), source.last_lsn);
}

test "Batch: deinit with empty changes" {
    const allocator = testing.allocator;

    const changes = try allocator.alloc(@import("../../domain/change_event.zig").ChangeEvent, 0);

    var batch = Batch{
        .changes = changes,
        .last_lsn = 12345,
        .replication_lag_seconds = 0,
        .received_keepalive = false,
        .allocator = allocator,
    };
    defer batch.deinit();

    try testing.expectEqual(@as(u64, 12345), batch.last_lsn);
    try testing.expectEqual(@as(usize, 0), batch.changes.len);
}
