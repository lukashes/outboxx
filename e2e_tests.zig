//! Aggregate root for the end-to-end test suite (full PostgreSQL -> CDC -> Kafka).
//!
//! Rooted at the repository root, like integration_tests.zig, because the suite
//! reaches both src/ and tests/. See src/unit_tests.zig for the rationale.
comptime {
    _ = @import("tests/e2e/cdc_test.zig");
}
