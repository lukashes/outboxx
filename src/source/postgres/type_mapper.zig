const std = @import("std");
const domain = @import("domain");
const FieldValue = domain.FieldValue;
const FieldValueHelpers = domain.FieldValueHelpers;

/// PostgreSQL built-in type OIDs we upgrade from text to native JSON types.
/// Values are stable, from pg_type.dat. Non-exhaustive: any OID we don't list
/// stays a JSON string.
pub const Oid = enum(u32) {
    bool = 16,
    int8 = 20,
    int2 = 21,
    int4 = 23,
    float4 = 700,
    float8 = 701,
    numeric = 1700,
    _,
};

/// Map a text-format pgoutput value to a typed JSON value based on the column OID.
///
/// pgoutput always delivers values as text (`"1"`, `"t"`), so without this every
/// field would serialize as a JSON string. Here we promote the common scalar types
/// to real JSON numbers and booleans. Anything we can't map safely stays a string,
/// which keeps the output valid JSON and never loses precision.
///
/// Only the `.string` branch allocates (it dupes into caller-owned memory); the
/// numeric and boolean branches return by value.
pub fn mapTextValue(allocator: std.mem.Allocator, oid: u32, text: []const u8) !FieldValue {
    switch (@as(Oid, @enumFromInt(oid))) {
        .int2, .int4, .int8 => {
            const n = std.fmt.parseInt(i64, text, 10) catch return FieldValueHelpers.text(allocator, text);
            return FieldValueHelpers.integer(n);
        },
        .float4, .float8 => {
            const f = std.fmt.parseFloat(f64, text) catch return FieldValueHelpers.text(allocator, text);
            // NaN and +/-Infinity are valid Postgres floats but not valid JSON
            // numbers, so fall back to the text form for them.
            if (!std.math.isFinite(f)) return FieldValueHelpers.text(allocator, text);
            return FieldValueHelpers.float(f);
        },
        .bool => {
            if (std.mem.eql(u8, text, "t")) return FieldValueHelpers.boolean(true);
            if (std.mem.eql(u8, text, "f")) return FieldValueHelpers.boolean(false);
            return FieldValueHelpers.text(allocator, text);
        },
        // numeric carries arbitrary precision and can be NaN/Infinity; emitting it
        // as a JSON number would either lose digits or produce invalid JSON, so we
        // keep the exact text (same as Debezium's decimal.handling.mode=string).
        .numeric, _ => return FieldValueHelpers.text(allocator, text),
    }
}

const testing = std.testing;

test "mapTextValue: integer types become JSON integers" {
    const allocator = testing.allocator;
    for ([_]u32{ 21, 23, 20 }) |oid| {
        const v = try mapTextValue(allocator, oid, "42");
        try testing.expect(v == .integer);
        try testing.expectEqual(@as(i64, 42), v.integer);
    }

    const neg = try mapTextValue(allocator, 20, "-9223372036854775808");
    try testing.expectEqual(@as(i64, std.math.minInt(i64)), neg.integer);
}

test "mapTextValue: float types become JSON floats" {
    const allocator = testing.allocator;
    for ([_]u32{ 700, 701 }) |oid| {
        const v = try mapTextValue(allocator, oid, "3.5");
        try testing.expect(v == .float);
        try testing.expectEqual(@as(f64, 3.5), v.float);
    }
}

test "mapTextValue: non-finite floats fall back to string" {
    const allocator = testing.allocator;
    for ([_]u32{ 700, 701 }) |oid| {
        for ([_][]const u8{ "NaN", "Infinity", "-Infinity" }) |text| {
            const v = try mapTextValue(allocator, oid, text);
            defer allocator.free(v.string);
            try testing.expect(v == .string);
            try testing.expectEqualStrings(text, v.string);
        }
    }
}

test "mapTextValue: bool maps t/f to JSON boolean" {
    const allocator = testing.allocator;
    const t = try mapTextValue(allocator, 16, "t");
    try testing.expect(t == .bool and t.bool == true);
    const f = try mapTextValue(allocator, 16, "f");
    try testing.expect(f == .bool and f.bool == false);
}

test "mapTextValue: numeric stays a string" {
    const allocator = testing.allocator;
    const v = try mapTextValue(allocator, 1700, "12345.6789");
    defer allocator.free(v.string);
    try testing.expect(v == .string);
    try testing.expectEqualStrings("12345.6789", v.string);
}

test "mapTextValue: unknown OID stays a string" {
    const allocator = testing.allocator;
    // 25 = text
    const v = try mapTextValue(allocator, 25, "hello");
    defer allocator.free(v.string);
    try testing.expect(v == .string);
    try testing.expectEqualStrings("hello", v.string);
}

test "mapTextValue: unparseable integer falls back to string" {
    const allocator = testing.allocator;
    const v = try mapTextValue(allocator, 23, "not-a-number");
    defer allocator.free(v.string);
    try testing.expect(v == .string);
    try testing.expectEqualStrings("not-a-number", v.string);
}
