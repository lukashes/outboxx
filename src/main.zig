const std = @import("std");
const print = std.debug.print;
const Config = @import("config.zig").Config;
const WalReader = @import("wal/reader.zig").WalReader;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    print("Outboxx - PostgreSQL Change Data Capture\n", .{});
    print("Version: 0.1.0-dev\n", .{});
    print("Build: Debug\n\n", .{});

    // Load default configuration
    const config = Config.default();
    print("Configuration loaded:\n", .{});
    print("  Host: {s}:{}\n", .{ config.host, config.port });
    print("  Database: {s}\n", .{config.database});
    print("  User: {s}\n", .{config.user});
    print("  Slot: {s}\n\n", .{config.slot_name});

    // Initialize WAL reader
    var wal_reader = WalReader.init(allocator, config.slot_name);
    defer wal_reader.deinit();

    // Connect to PostgreSQL
    const conn_str = try config.connectionString(allocator);
    defer allocator.free(conn_str);

    print("Starting WAL reader...\n", .{});

    wal_reader.connect(conn_str) catch |err| {
        print("Failed to connect to PostgreSQL: {}\n", .{err});
        return;
    };

    // Clean up any existing slot (ignore errors)
    wal_reader.dropSlot() catch {};

    // Create replication slot
    wal_reader.createSlot() catch |err| {
        print("Failed to create replication slot: {}\n", .{err});
        return;
    };

    // Main CDC loop
    print("\n=== Starting CDC event monitoring ===\n", .{});
    print("Listening for changes... (Press Ctrl+C to stop)\n\n", .{});

    var iteration: u32 = 0;
    while (iteration < 100) : (iteration += 1) {  // Limit iterations for testing
        var events = wal_reader.readChanges(10) catch |err| {
            print("Error reading changes: {}\n", .{err});
            std.Thread.sleep(1000000000); // Sleep 1 second
            continue;
        };
        defer {
            for (events.items) |*event| {
                event.deinit(allocator);
            }
            events.deinit(allocator);
        }

        if (events.items.len > 0) {
            print("=== Found {} new events ===\n", .{events.items.len});
            for (events.items, 0..) |event, i| {
                print("Event {}: LSN={s}\n", .{ i + 1, event.lsn });
                print("  Data: {s}\n", .{event.data});
                print("\n", .{});
            }
        } else {
            print("No new changes detected (iteration {})\n", .{iteration + 1});
        }

        // Sleep for 2 seconds between checks
        std.Thread.sleep(2000000000);
    }

    // Clean up replication slot
    print("\nShutting down...\n", .{});
    wal_reader.dropSlot() catch {};
    print("WAL reader stopped.\n", .{});
}
