// Root of the integration-test binary (needs Postgres + Kafka): it spans
// several src/ subtrees, so its module root sits at src/. See src/unit_test_root.zig.
comptime {
    _ = @import("sink/kafka/producer.zig");
    _ = @import("sink/kafka/producer_test.zig");
    _ = @import("source/postgres/replication_protocol_test.zig");
    _ = @import("source/postgres/validator_test.zig");
    _ = @import("source/postgres/integration_test.zig");
    _ = @import("source/postgres/snapshot_test.zig");
    _ = @import("processor/routing_integration_test.zig");
}
