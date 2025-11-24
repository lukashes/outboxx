const builtin = @import("builtin");

pub const VERSION = "0.1.0-dev";
pub const APP_NAME = "Outboxx";
pub const DESCRIPTION = "PostgreSQL Change Data Capture with Kafka";

pub const BUILD_MODE = builtin.mode;

// CDC Processing Configuration
// Optimized for maximum throughput
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
