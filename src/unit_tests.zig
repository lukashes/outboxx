//! Aggregate root for the unit test suite.
//!
//! Unit tests live inline in the business-logic file (project convention);
//! *_test.zig is reserved for tests that need external services. This root
//! pulls in the source files that carry inline tests so `zig build test` runs
//! them as one binary. Zig confines a module to its root file's directory, so
//! rooting here (src/) lets each file reach the rest of the tree by relative
//! import with a single instance per type. Same pattern as TigerBeetle's
//! src/unit_tests.zig; add a source file here when it gains its first inline test.
comptime {
    _ = @import("config/config.zig");
    _ = @import("observability/observability.zig");
    _ = @import("domain/change_event.zig");
    _ = @import("serialization/json.zig");
    _ = @import("source/postgres/pg_output_decoder.zig");
    _ = @import("source/postgres/relation_registry.zig");
    _ = @import("source/postgres/source.zig");
}
