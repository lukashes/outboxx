//! Test-only reflection helper.

const std = @import("std");
const builtin = @import("builtin");

/// Recursively reference every declaration of `T` so the compiler analyzes it.
/// Zig type-checks a `pub` decl only when something references it, so an unused
/// (or bench-only) `pub fn` can ship with a type error that `zig build test`
/// never catches. Calling this from a module's `*_test.zig` forces the whole
/// module, including struct methods, through analysis.
///
/// Reimplemented here because `std.testing` dropped `refAllDeclsRecursive`.
pub fn refAllDeclsRecursive(comptime T: type) void {
    if (!builtin.is_test) return;
    inline for (comptime std.meta.declarations(T)) |decl| {
        if (@TypeOf(@field(T, decl.name)) == type) {
            switch (@typeInfo(@field(T, decl.name))) {
                .@"struct", .@"enum", .@"union", .@"opaque" => refAllDeclsRecursive(@field(T, decl.name)),
                else => {},
            }
        }
        _ = &@field(T, decl.name);
    }
}
