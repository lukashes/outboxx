// Root of the unit-test binary: it runs the inline tests of the source files
// below. Rooted at src/ because a Zig module can only import files under its
// root file's directory, so a deeper root could not reach the whole tree.
// Add a source file here when it gains its first inline test.
comptime {
    _ = @import("config/config.zig");
    _ = @import("observability/observability.zig");
    _ = @import("domain/change_event.zig");
    _ = @import("serialization/json.zig");
    _ = @import("source/postgres/pg_output_decoder.zig");
    _ = @import("source/postgres/relation_registry.zig");
    _ = @import("source/postgres/source.zig");
}
