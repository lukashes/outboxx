// Root of the e2e-test binary (Postgres -> CDC -> Kafka). Rooted at src/ like
// the other suite roots; see src/unit_tests.zig.
comptime {
    _ = @import("e2e/cdc_test.zig");
}
