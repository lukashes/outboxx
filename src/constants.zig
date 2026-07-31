const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

pub const VERSION = build_options.version;
/// Minimum log level compiled in; set with -Dlog_level=debug|info|warn|err.
/// addOption emits its own copy of the enum, so map it back onto std.log.Level by tag.
pub const LOG_LEVEL: std.log.Level = std.meta.stringToEnum(std.log.Level, @tagName(build_options.log_level)).?;
pub const APP_NAME = "Outboxx";
pub const DESCRIPTION = "PostgreSQL Change Data Capture with Kafka";

pub const BUILD_MODE = builtin.mode;

/// Placeholder for an unchanged TOAST value that Postgres didn't resend, so the
/// column stays in the event instead of being dropped or shown as a real NULL.
pub const UNKNOWN_VALUE_PLACEHOLDER = "__outboxx_unknown_value__";

/// CDC processing tuning constants, optimized for throughput.
pub const CDC = struct {
    // PostgreSQL batch settings
    pub const BATCH_SIZE: u32 = 5000; // Events per batch - larger batches = higher throughput
    pub const BATCH_WAIT_MS: i32 = 100; // Short timeout to quickly move full batches

    // Kafka settings
    pub const KAFKA_FLUSH_TIMEOUT_MS: i32 = 5000; // Flush timeout
    pub const KAFKA_FLUSH_INTERVAL_SEC: i64 = 10; // Flush every N seconds (reduces blocking)
    pub const KAFKA_LINGER_MS = "50"; // Optimal for throughput (balance batching vs latency)
    pub const KAFKA_BATCH_SIZE = "262144"; // 256KB batches for better network utilization
    pub const KAFKA_POLL_INTERVAL: u32 = 100; // Poll every N messages (reduces syscall overhead)

    // Backpressure on a full producer queue. The synchronous pipeline blocks the
    // WAL read here, so Postgres slows too: block on poll (it wakes up as soon as
    // a delivery report lands, not just on timeout) and retry produce. No deadline
    // of our own is needed: a message can't sit in the queue past
    // delivery.timeout.ms (30s) before its delivery report fires, so a wedged
    // broker surfaces as deliveryErrorCount > 0 well within that window.
    pub const KAFKA_BACKPRESSURE_POLL_MS: i32 = 5000;
};

/// Observability tuning constants.
pub const OBSERVABILITY = struct {
    // Max time with no activity on the replication wire (a change or a server
    // keepalive) before the stream is considered dead. One signal, two readers:
    // the /healthz probe and the receive loop's fail-fast on a silently stalled
    // stream (a frozen or dead peer sends no FIN/RST, so it looks idle, not
    // broken). On an idle stream the wire is fed by the keepalive the server
    // returns to each feedback's reply request (every KAFKA_FLUSH_INTERVAL_SEC),
    // with the server's own probe (~wal_sender_timeout/2, default 30s) as the
    // fallback before the first confirmed LSN. Must exceed both with margin.
    pub const LIVENESS_MAX_STALE_SEC: i64 = 90;
};
