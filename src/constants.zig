const builtin = @import("builtin");
const build_options = @import("build_options");

pub const VERSION = build_options.version;
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
};

/// Observability tuning constants.
pub const OBSERVABILITY = struct {
    // Liveness turns unhealthy if the receive loop makes no progress for this long.
    // Must exceed BATCH_WAIT and the flush interval; keepalives keep it fresh when idle.
    pub const LIVENESS_MAX_STALE_SEC: i64 = 30;
};
