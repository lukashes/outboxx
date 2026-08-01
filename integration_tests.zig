//! Aggregate root for the integration test suite (needs Postgres + Kafka).
//!
//! Rooted at the repository root, not src/, because these tests reach both
//! src/ and tests/test_helpers.zig; a module is confined to its root file's
//! directory, so the root must be a common ancestor of both. See
//! src/unit_tests.zig for the rationale behind aggregating.
comptime {
    _ = @import("src/sink/kafka/producer.zig");
    _ = @import("src/sink/kafka/producer_test.zig");
    _ = @import("src/source/postgres/replication_protocol_test.zig");
    _ = @import("src/source/postgres/validator_test.zig");
    _ = @import("src/source/postgres/integration_test.zig");
    _ = @import("src/processor/routing_integration_test.zig");
}
